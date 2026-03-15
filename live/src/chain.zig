/// chain.zig — Traceability gap walker for industry profiles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rtmify = @import("rtmify");
const GraphDb = @import("graph_live.zig").GraphDb;
const profile_mod = rtmify.profile;
const adapter = @import("adapter.zig");
const Profile = profile_mod.Profile;
const Direction = profile_mod.Direction;
const GapSeverity = profile_mod.GapSeverity;
const SpecialGapKind = profile_mod.SpecialGapKind;
const SpecialGapCheck = profile_mod.SpecialGapCheck;
const shared_chain = rtmify.chain;

pub const Gap = struct {
    code: u16,
    title: []const u8,
    gap_type: []const u8,
    node_id: []const u8,
    severity: GapSeverity,
    message: []const u8,
};

pub fn walkChain(db: *GraphDb, profile: Profile, alloc: Allocator) ![]Gap {
    var gaps: std.ArrayList(Gap) = .empty;

    for (profile.chain_steps) |step| {
        if (!step.required) continue;

        const sql: [:0]const u8 = switch (step.direction) {
            .outgoing =>
                \\SELECT n.id FROM nodes n
                \\WHERE n.type=?
                \\  AND NOT EXISTS (
                \\      SELECT 1 FROM edges e
                \\      JOIN nodes dst ON dst.id = e.to_id
                \\      WHERE e.from_id = n.id AND e.label = ? AND dst.type = ?
                \\  )
                \\ORDER BY n.id
            ,
            .incoming =>
                \\SELECT n.id FROM nodes n
                \\WHERE n.type=?
                \\  AND NOT EXISTS (
                \\      SELECT 1 FROM edges e
                \\      JOIN nodes src ON src.id = e.from_id
                \\      WHERE e.to_id = n.id AND e.label = ? AND src.type = ?
                \\  )
                \\ORDER BY n.id
            ,
        };

        var st = try db.db.prepare(sql);
        defer st.finalize();
        try st.bindText(1, step.from_type.toString());
        try st.bindText(2, step.edge_label.toString());
        try st.bindText(3, step.to_type.toString());

        while (try st.step()) {
            const node_id = st.columnText(0);
            const message = switch (step.direction) {
                .outgoing => try std.fmt.allocPrint(
                    alloc,
                    "{s} '{s}' has no {s} edge to a {s}",
                    .{ step.from_type.toString(), node_id, step.edge_label.toString(), step.to_type.toString() },
                ),
                .incoming => if (step.from_type == .user_need and step.edge_label == .derives_from and step.to_type == .requirement)
                    try std.fmt.allocPrint(
                        alloc,
                        "UserNeed '{s}' has no downstream Requirements",
                        .{node_id},
                    )
                else
                    try std.fmt.allocPrint(
                        alloc,
                        "{s} '{s}' has no incoming {s} edge from a {s}",
                        .{ step.from_type.toString(), node_id, step.edge_label.toString(), step.to_type.toString() },
                    ),
            };
            try gaps.append(alloc, .{
                .code = step.code,
                .title = try alloc.dupe(u8, step.title),
                .gap_type = try alloc.dupe(u8, step.gap_type),
                .node_id = try alloc.dupe(u8, node_id),
                .severity = step.severity,
                .message = message,
            });
        }
    }

    return gaps.toOwnedSlice(alloc);
}

pub fn walkSpecialGaps(db: *GraphDb, profile: Profile, alloc: Allocator) ![]Gap {
    var gaps: std.ArrayList(Gap) = .empty;
    for (profile.special_checks) |check| {
        try appendSpecialGaps(db, check, alloc, &gaps);
    }
    return gaps.toOwnedSlice(alloc);
}

fn appendSpecialGaps(db: *GraphDb, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    switch (check.kind) {
        .unimplemented_requirement => try appendMissingEdgeGap(db, "Requirement", "IMPLEMENTED_IN", check, "Requirement '{s}' has no current source implementation evidence", alloc, gaps),
        .untested_source_file => try appendMissingEdgeGap(db, "SourceFile", "VERIFIED_BY_CODE", check, "SourceFile '{s}' has no VERIFIED_BY_CODE edge to a test file", alloc, gaps),
        .req_without_design_input => try appendMissingEdgeGap(db, "Requirement", "ALLOCATED_TO", check, "Requirement '{s}' has no ALLOCATED_TO edge to a design input", alloc, gaps),
        .design_input_without_design_output => try appendMissingEdgeGap(db, "DesignInput", "SATISFIED_BY", check, "DesignInput '{s}' has no SATISFIED_BY edge to a design output", alloc, gaps),
        .design_output_without_source => try appendMissingEdgeGap(db, "DesignOutput", "IMPLEMENTED_IN", check, "DesignOutput '{s}' has no IMPLEMENTED_IN edge to a source file", alloc, gaps),
        .design_output_without_config_control => try appendMissingEdgeGap(db, "DesignOutput", "CONTROLLED_BY", check, "DesignOutput '{s}' has no CONTROLLED_BY edge to a configuration item", alloc, gaps),
        .uncommitted_requirement => try appendQueryGaps(db,
            \\SELECT n.id FROM nodes n
            \\WHERE n.type='Requirement'
            \\  AND EXISTS (SELECT 1 FROM edges e WHERE e.from_id=n.id AND e.label='IMPLEMENTED_IN')
            \\  AND NOT EXISTS (SELECT 1 FROM edges e WHERE e.from_id=n.id AND e.label='COMMITTED_IN')
            \\ORDER BY n.id
        , check, "Requirement '{s}' has implementation evidence but no explicit commit-message trace", alloc, gaps),
        .unattributed_annotation => try appendQueryGaps(db,
            \\SELECT id FROM nodes
            \\WHERE type='CodeAnnotation'
            \\  AND (
            \\      json_extract(properties,'$.blame_author') IS NULL OR
            \\      json_extract(properties,'$.blame_author') = '' OR
            \\      json_extract(properties,'$.author_time') IS NULL OR
            \\      json_extract(properties,'$.author_time') = 0
            \\  )
            \\ORDER BY id
        , check, "RTMify found a requirement tag at {s}, but could not determine who last changed that line", alloc, gaps),
        .hlr_without_llr => try appendQueryGaps(db,
            \\SELECT n.id FROM nodes n
            \\WHERE n.type='Requirement'
            \\  AND EXISTS (
            \\      SELECT 1 FROM edges e JOIN nodes un ON un.id = e.to_id
            \\      WHERE e.from_id = n.id AND e.label='DERIVES_FROM' AND un.type='UserNeed'
            \\  )
            \\  AND NOT EXISTS (
            \\      SELECT 1 FROM edges e JOIN nodes child ON child.id = e.to_id
            \\      WHERE e.from_id = n.id AND e.label='REFINED_BY' AND child.type='Requirement'
            \\  )
            \\ORDER BY n.id
        , check, "Requirement '{s}' has no downstream lower-level Requirements", alloc, gaps),
        .llr_without_source => try appendQueryGaps(db,
            \\SELECT child.id FROM nodes child
            \\WHERE child.type='Requirement'
            \\  AND EXISTS (
            \\      SELECT 1 FROM edges e JOIN nodes parent ON parent.id = e.from_id
            \\      WHERE e.to_id = child.id AND e.label='REFINED_BY' AND parent.type='Requirement'
            \\  )
            \\  AND NOT EXISTS (
            \\      SELECT 1 FROM edges e WHERE e.from_id = child.id AND e.label='IMPLEMENTED_IN'
            \\  )
            \\ORDER BY child.id
        , check, "Requirement '{s}' is decomposed but has no current source implementation evidence", alloc, gaps),
        .source_without_structural_coverage => try appendQueryGaps(db,
            \\SELECT s.id FROM nodes s
            \\WHERE s.type='SourceFile'
            \\  AND (
            \\      EXISTS (SELECT 1 FROM edges e WHERE e.to_id=s.id AND e.label='IMPLEMENTED_IN') OR
            \\      EXISTS (SELECT 1 FROM edges e WHERE e.from_id=s.id AND e.label='CONTAINS')
            \\  )
            \\  AND NOT EXISTS (SELECT 1 FROM edges e WHERE e.from_id=s.id AND e.label='VERIFIED_BY_CODE')
            \\ORDER BY s.id
        , check, "SourceFile '{s}' has implementation evidence but no current test evidence", alloc, gaps),
        .missing_asil => try appendQueryGaps(db,
            \\SELECT id FROM nodes
            \\WHERE type='Requirement'
            \\  AND (
            \\      json_extract(properties,'$.asil') IS NULL OR
            \\      json_extract(properties,'$.asil') = ''
            \\  )
            \\ORDER BY id
        , check, "Requirement '{s}' is missing required property 'asil'", alloc, gaps),
        .asil_inheritance => try appendAsilInheritanceGaps(db, check, alloc, gaps),
    }
}

fn appendMissingEdgeGap(
    db: *GraphDb,
    node_type: []const u8,
    edge_label: []const u8,
    check: SpecialGapCheck,
    comptime fmt: []const u8,
    alloc: Allocator,
    gaps: *std.ArrayList(Gap),
) !void {
    var st = try db.db.prepare(
        \\SELECT n.id FROM nodes n
        \\WHERE n.type=?
        \\  AND NOT EXISTS (
        \\      SELECT 1 FROM edges e
        \\      WHERE e.from_id = n.id AND e.label = ?
        \\  )
        \\ORDER BY n.id
    );
    defer st.finalize();
    try st.bindText(1, node_type);
    try st.bindText(2, edge_label);
    while (try st.step()) {
        const node_id = st.columnText(0);
        const message = try std.fmt.allocPrint(alloc, fmt, .{node_id});
        try gaps.append(alloc, .{
            .code = check.code,
            .title = try alloc.dupe(u8, check.title),
            .gap_type = try alloc.dupe(u8, check.gap_type),
            .node_id = try alloc.dupe(u8, node_id),
            .severity = check.severity,
            .message = message,
        });
    }
}

fn appendQueryGaps(
    db: *GraphDb,
    sql: [:0]const u8,
    check: SpecialGapCheck,
    comptime fmt: []const u8,
    alloc: Allocator,
    gaps: *std.ArrayList(Gap),
) !void {
    var st = try db.db.prepare(sql);
    defer st.finalize();
    while (try st.step()) {
        const node_id = st.columnText(0);
        const message = try std.fmt.allocPrint(alloc, fmt, .{node_id});
        try gaps.append(alloc, .{
            .code = check.code,
            .title = try alloc.dupe(u8, check.title),
            .gap_type = try alloc.dupe(u8, check.gap_type),
            .node_id = try alloc.dupe(u8, node_id),
            .severity = check.severity,
            .message = message,
        });
    }
}

fn appendAsilInheritanceGaps(db: *GraphDb, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    var st = try db.db.prepare(
        \\SELECT parent.id, json_extract(parent.properties,'$.asil'), child.id, json_extract(child.properties,'$.asil')
        \\FROM edges e
        \\JOIN nodes parent ON parent.id = e.from_id
        \\JOIN nodes child ON child.id = e.to_id
        \\WHERE e.label='REFINED_BY' AND parent.type='Requirement' AND child.type='Requirement'
        \\ORDER BY parent.id, child.id
    );
    defer st.finalize();
    while (try st.step()) {
        if (st.columnIsNull(1) or st.columnIsNull(3)) continue;
        const parent_id = st.columnText(0);
        const parent_asil = st.columnText(1);
        const child_id = st.columnText(2);
        const child_asil = st.columnText(3);
        const parent_rank = asilRank(parent_asil) orelse continue;
        const child_rank = asilRank(child_asil) orelse continue;
        if (child_rank < parent_rank) {
            const message = try std.fmt.allocPrint(
                alloc,
                "Requirement '{s}' has ASIL {s} lower than parent '{s}' ASIL {s}",
                .{ child_id, child_asil, parent_id, parent_asil },
            );
            try gaps.append(alloc, .{
                .code = check.code,
                .title = try alloc.dupe(u8, check.title),
                .gap_type = try alloc.dupe(u8, check.gap_type),
                .node_id = try alloc.dupe(u8, child_id),
                .severity = check.severity,
                .message = message,
            });
        }
    }
}

fn asilRank(raw: []const u8) ?u8 {
    var buf: [8]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"");
    if (trimmed.len == 0) return null;
    const len = @min(trimmed.len, buf.len);
    for (trimmed[0..len], 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    const s = buf[0..len];
    if (std.mem.eql(u8, s, "QM")) return 0;
    if (std.mem.eql(u8, s, "A") or std.mem.eql(u8, s, "ASIL-A")) return 1;
    if (std.mem.eql(u8, s, "B") or std.mem.eql(u8, s, "ASIL-B")) return 2;
    if (std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "ASIL-C")) return 3;
    if (std.mem.eql(u8, s, "D") or std.mem.eql(u8, s, "ASIL-D")) return 4;
    return null;
}

pub fn gapsToJson(gap_list: []const Gap, alloc: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = out.writer(alloc);
    try w.writeAll("[");
    for (gap_list, 0..) |gap, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try w.print("\"code\":{d}", .{gap.code});
        try w.writeAll(",\"title\":\"");
        try writeJsonStr(w, gap.title);
        try w.writeAll("\"");
        try w.print(",\"gap_type\":\"{s}\"", .{gap.gap_type});
        try w.print(",\"node_id\":\"{s}\"", .{gap.node_id});
        try w.print(",\"severity\":\"{s}\"", .{@tagName(gap.severity)});
        try w.writeAll(",\"message\":\"");
        try writeJsonStr(w, gap.message);
        try w.writeAll("\"}");
    }
    try w.writeAll("]");
    return out.toOwnedSlice(alloc);
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
}

const testing = std.testing;

const ComparableGap = struct {
    code: u16,
    gap_type: []const u8,
    node_id: []const u8,
    severity: GapSeverity,
    message: []const u8,
};

fn comparableGapLt(_: void, a: ComparableGap, b: ComparableGap) bool {
    const code_cmp = std.math.order(a.code, b.code);
    if (code_cmp != .eq) return code_cmp == .lt;
    const type_cmp = std.mem.order(u8, a.gap_type, b.gap_type);
    if (type_cmp != .eq) return type_cmp == .lt;
    return std.mem.order(u8, a.node_id, b.node_id) == .lt;
}

fn normalizeLiveGaps(gaps: []const Gap, alloc: Allocator) ![]ComparableGap {
    var out: std.ArrayList(ComparableGap) = .empty;
    for (gaps) |gap| {
        try out.append(alloc, .{
            .code = gap.code,
            .gap_type = try alloc.dupe(u8, gap.gap_type),
            .node_id = try alloc.dupe(u8, gap.node_id),
            .severity = gap.severity,
            .message = try alloc.dupe(u8, gap.message),
        });
    }
    std.mem.sort(ComparableGap, out.items, {}, comparableGapLt);
    return out.toOwnedSlice(alloc);
}

fn normalizeSharedGaps(gaps: []const shared_chain.Gap, alloc: Allocator) ![]ComparableGap {
    var out: std.ArrayList(ComparableGap) = .empty;
    for (gaps) |gap| {
        try out.append(alloc, .{
            .code = gap.code,
            .gap_type = try alloc.dupe(u8, gap.gap_type),
            .node_id = try alloc.dupe(u8, gap.node_id),
            .severity = gap.severity,
            .message = try alloc.dupe(u8, gap.message),
        });
    }
    std.mem.sort(ComparableGap, out.items, {}, comparableGapLt);
    return out.toOwnedSlice(alloc);
}

test "gapsToJson produces valid JSON for empty slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json = try gapsToJson(&.{}, arena.allocator());
    try testing.expectEqualStrings("[]", json);
}

test "asilRank order" {
    try testing.expectEqual(@as(?u8, 0), asilRank("QM"));
    try testing.expectEqual(@as(?u8, 1), asilRank("A"));
    try testing.expectEqual(@as(?u8, 4), asilRank("ASIL-D"));
}

test "walk special gaps finds uncommitted requirement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("src/foo.c", "SourceFile", "{}", null);
    try db.addEdge("REQ-001", "src/foo.c", "IMPLEMENTED_IN");

    const gaps = try walkSpecialGaps(&db, profile_mod.Profile{
        .id = .aerospace,
        .name = "Aerospace",
        .chain_steps = &.{},
        .special_checks = &.{.{ .kind = .uncommitted_requirement, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "uncommitted_requirement" }},
        .tabs = &.{},
    }, alloc);
    try testing.expectEqual(@as(usize, 1), gaps.len);
    try testing.expectEqualStrings("uncommitted_requirement", gaps[0].gap_type);
}

test "walk special gaps finds unattributed annotation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("src/foo.c:10", "CodeAnnotation", "{\"req_id\":\"REQ-001\"}", null);

    const gaps = try walkSpecialGaps(&db, profile_mod.Profile{
        .id = .aerospace,
        .name = "Aerospace",
        .chain_steps = &.{},
        .special_checks = &.{.{ .kind = .unattributed_annotation, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "unattributed_annotation" }},
        .tabs = &.{},
    }, alloc);
    try testing.expectEqual(@as(usize, 1), gaps.len);
    try testing.expectEqualStrings("unattributed_annotation", gaps[0].gap_type);
}

test "walk special gaps finds design output without config control" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("DO-001", "DesignOutput", "{}", null);

    const gaps = try walkSpecialGaps(&db, profile_mod.get(.medical), alloc);
    var found = false;
    for (gaps) |gap| {
        if (std.mem.eql(u8, gap.gap_type, "design_output_without_config_control")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "walk special gaps finds HLR without LLR and LLR without source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("REQ-002", "Requirement", "{}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("REQ-001", "REQ-002", "REFINED_BY");

    var gaps = try walkSpecialGaps(&db, profile_mod.get(.aerospace), alloc);
    var found_hlr = false;
    var found_llr = false;
    for (gaps) |gap| {
        if (std.mem.eql(u8, gap.gap_type, "hlr_without_llr") and std.mem.eql(u8, gap.node_id, "REQ-002")) {
            try testing.expect(false);
        }
        if (std.mem.eql(u8, gap.gap_type, "llr_without_source") and std.mem.eql(u8, gap.node_id, "REQ-002")) found_llr = true;
        if (std.mem.eql(u8, gap.gap_type, "hlr_without_llr") and std.mem.eql(u8, gap.node_id, "REQ-001")) found_hlr = true;
    }
    try testing.expect(!found_hlr);
    try testing.expect(found_llr);

    try db.addNode("REQ-003", "Requirement", "{}", null);
    try db.addEdge("REQ-003", "UN-001", "DERIVES_FROM");
    gaps = try walkSpecialGaps(&db, profile_mod.get(.aerospace), alloc);
    var found_hlr_gap = false;
    for (gaps) |gap| {
        if (std.mem.eql(u8, gap.gap_type, "hlr_without_llr") and std.mem.eql(u8, gap.node_id, "REQ-003")) found_hlr_gap = true;
    }
    try testing.expect(found_hlr_gap);
}

test "walk special gaps finds ASIL inheritance violations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-P", "Requirement", "{\"asil\":\"D\"}", null);
    try db.addNode("REQ-C", "Requirement", "{\"asil\":\"B\"}", null);
    try db.addEdge("REQ-P", "REQ-C", "REFINED_BY");

    const gaps = try walkSpecialGaps(&db, profile_mod.get(.automotive), alloc);
    var found = false;
    for (gaps) |gap| {
        if (std.mem.eql(u8, gap.gap_type, "asil_inheritance")) found = true;
    }
    try testing.expect(found);
}

test "generic profile has no special code-traceability gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    const gaps = try walkSpecialGaps(&db, profile_mod.get(.generic), alloc);
    try testing.expectEqual(@as(usize, 0), gaps.len);
}

test "walkChain handles incoming derives_from for user needs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addNode("UN-002", "UserNeed", "{}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");

    const gaps = try walkChain(&db, profile_mod.get(.aerospace), alloc);

    var found_un1 = false;
    var found_un2 = false;
    for (gaps) |gap| {
        if (std.mem.eql(u8, gap.gap_type, "orphan_requirement") and std.mem.eql(u8, gap.node_id, "UN-001")) {
            found_un1 = true;
        }
        if (std.mem.eql(u8, gap.gap_type, "orphan_requirement") and std.mem.eql(u8, gap.node_id, "UN-002")) {
            found_un2 = true;
            try testing.expectEqualStrings("UserNeed 'UN-002' has no downstream Requirements", gap.message);
        }
    }
    try testing.expect(!found_un1);
    try testing.expect(found_un2);
}

test "shared in-memory walker matches live SQL walker for medical gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("RISK-001", "Risk", "{}", null);

    const profile = profile_mod.get(.medical);
    const live_chain_gaps = try walkChain(&db, profile, alloc);
    const live_special_gaps = try walkSpecialGaps(&db, profile, alloc);

    var g = try adapter.buildGraphFromSqlite(&db, alloc);
    defer g.deinit();

    const shared_chain_gaps = try shared_chain.walkChain(&g, profile, alloc);
    const shared_special_gaps = try shared_chain.walkSpecialGaps(&g, profile, alloc);

    var live_all: std.ArrayList(Gap) = .empty;
    try live_all.appendSlice(alloc, live_chain_gaps);
    try live_all.appendSlice(alloc, live_special_gaps);

    var shared_all: std.ArrayList(shared_chain.Gap) = .empty;
    try shared_all.appendSlice(alloc, shared_chain_gaps);
    try shared_all.appendSlice(alloc, shared_special_gaps);

    const live_norm = try normalizeLiveGaps(live_all.items, alloc);
    const shared_norm = try normalizeSharedGaps(shared_all.items, alloc);

    try testing.expectEqual(live_norm.len, shared_norm.len);
    for (live_norm, shared_norm) |lhs, rhs| {
        try testing.expectEqual(lhs.code, rhs.code);
        try testing.expectEqual(lhs.severity, rhs.severity);
        try testing.expectEqualStrings(lhs.gap_type, rhs.gap_type);
        try testing.expectEqualStrings(lhs.node_id, rhs.node_id);
        try testing.expectEqualStrings(lhs.message, rhs.message);
    }
}
