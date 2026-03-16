const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const profile_mod = @import("profile.zig");
const chain_mod = @import("chain.zig");

pub const TraceGapSeverity = enum {
    hard,
    advisory,
    err,
    warn,

    pub fn toString(self: TraceGapSeverity) []const u8 {
        return @tagName(self);
    }
};

pub const TraceGapSource = enum {
    generic,
    profile,
};

pub const TraceGap = struct {
    severity: TraceGapSeverity,
    code: ?u16 = null,
    kind: []const u8,
    primary_id: []const u8,
    related_id: ?[]const u8 = null,
    message: []const u8,
    profile_rule: ?[]const u8 = null,
    clause: ?[]const u8 = null,
    source: TraceGapSource,
};

pub const ReportContext = struct {
    profile: profile_mod.ProfileId,
    profile_name: []const u8,
    profile_standards: []const u8,
    generic_gaps: []const graph.GapFinding,
    profile_gaps: []const chain_mod.Gap,
    merged_gaps: []const TraceGap,
};

pub fn deinitReportContext(ctx: ReportContext, alloc: Allocator) void {
    for (ctx.generic_gaps) |gap| {
        alloc.free(gap.primary_id);
        if (gap.related_id) |id| alloc.free(id);
    }
    alloc.free(ctx.generic_gaps);

    for (ctx.profile_gaps) |gap| {
        alloc.free(gap.title);
        alloc.free(gap.gap_type);
        alloc.free(gap.node_id);
        alloc.free(gap.message);
        alloc.free(gap.profile_rule);
        if (gap.clause) |clause| alloc.free(clause);
    }
    alloc.free(ctx.profile_gaps);

    for (ctx.merged_gaps) |gap| {
        alloc.free(gap.kind);
        alloc.free(gap.primary_id);
        if (gap.related_id) |id| alloc.free(id);
        alloc.free(gap.message);
        if (gap.profile_rule) |rule| alloc.free(rule);
        if (gap.clause) |clause| alloc.free(clause);
    }
    alloc.free(ctx.merged_gaps);
}

pub fn buildReportContext(g: *const graph.Graph, profile_id: profile_mod.ProfileId, alloc: Allocator) !ReportContext {
    const profile = profile_mod.get(profile_id);

    var generic_gaps: std.ArrayList(graph.GapFinding) = .empty;
    try g.collectGapFindings(alloc, &generic_gaps);

    const profile_gaps = if (profile_id == .generic)
        &[_]chain_mod.Gap{}
    else blk: {
        const chain_gaps = try chain_mod.walkChain(g, profile, alloc);
        defer alloc.free(chain_gaps);
        const special_gaps = try chain_mod.walkSpecialGaps(g, profile, alloc);
        defer alloc.free(special_gaps);
        var merged: std.ArrayList(chain_mod.Gap) = .empty;
        try merged.appendSlice(alloc, chain_gaps);
        try merged.appendSlice(alloc, special_gaps);
        std.mem.sort(chain_mod.Gap, merged.items, {}, struct {
            fn lt(_: void, a: chain_mod.Gap, b: chain_mod.Gap) bool {
                const code_cmp = std.math.order(a.code, b.code);
                if (code_cmp != .eq) return code_cmp == .lt;
                const type_cmp = std.mem.order(u8, a.gap_type, b.gap_type);
                if (type_cmp != .eq) return type_cmp == .lt;
                return std.mem.order(u8, a.node_id, b.node_id) == .lt;
            }
        }.lt);
        break :blk try merged.toOwnedSlice(alloc);
    };

    var merged_gaps: std.ArrayList(TraceGap) = .empty;
    for (generic_gaps.items) |gap| {
        try merged_gaps.append(alloc, try normalizeGenericGap(gap, alloc));
    }
    for (profile_gaps) |gap| {
        try merged_gaps.append(alloc, try normalizeProfileGap(gap, alloc));
    }
    std.mem.sort(TraceGap, merged_gaps.items, {}, traceGapLt);

    return .{
        .profile = profile_id,
        .profile_name = profile.name,
        .profile_standards = profile.standards,
        .generic_gaps = try generic_gaps.toOwnedSlice(alloc),
        .profile_gaps = profile_gaps,
        .merged_gaps = try merged_gaps.toOwnedSlice(alloc),
    };
}

pub fn hardGapCount(gaps: []const TraceGap) usize {
    var count: usize = 0;
    for (gaps) |gap| {
        switch (gap.severity) {
            .hard, .err => count += 1,
            else => {},
        }
    }
    return count;
}

pub fn genericGapForNode(findings: []const graph.GapFinding, id: []const u8) bool {
    for (findings) |finding| {
        if (!std.mem.eql(u8, finding.primary_id, id)) continue;
        switch (finding.kind) {
            .requirement_no_user_need_link,
            .requirement_no_test_group_link,
            .requirement_only_unresolved_test_group_refs,
            .requirement_linked_to_empty_test_group,
            .risk_without_mitigation_requirement,
            .risk_unresolved_mitigation_requirement,
            => return true,
            else => {},
        }
    }
    return false;
}

pub fn traceGapForNode(gaps: []const TraceGap, id: []const u8) bool {
    for (gaps) |gap| {
        if (std.mem.eql(u8, gap.primary_id, id)) return true;
    }
    return false;
}

fn normalizeGenericGap(gap: graph.GapFinding, alloc: Allocator) !TraceGap {
    return .{
        .severity = switch (gap.severity) {
            .hard => .hard,
            .advisory => .advisory,
        },
        .kind = try alloc.dupe(u8, gap.kind.toString()),
        .primary_id = try alloc.dupe(u8, gap.primary_id),
        .related_id = if (gap.related_id) |id| try alloc.dupe(u8, id) else null,
        .message = try genericGapMessage(gap, alloc),
        .source = .generic,
    };
}

fn normalizeProfileGap(gap: chain_mod.Gap, alloc: Allocator) !TraceGap {
    return .{
        .severity = switch (gap.severity) {
            .err => .err,
            .warn => .warn,
        },
        .code = gap.code,
        .kind = try alloc.dupe(u8, gap.gap_type),
        .primary_id = try alloc.dupe(u8, gap.node_id),
        .message = try alloc.dupe(u8, gap.message),
        .profile_rule = try alloc.dupe(u8, gap.profile_rule),
        .clause = if (gap.clause) |clause| try alloc.dupe(u8, clause) else null,
        .source = .profile,
    };
}

fn genericGapMessage(gap: graph.GapFinding, alloc: Allocator) ![]const u8 {
    return switch (gap.kind) {
        .requirement_no_user_need_link => std.fmt.allocPrint(alloc, "Requirement '{s}' has no linked User Need", .{gap.primary_id}),
        .requirement_no_test_group_link => std.fmt.allocPrint(alloc, "Requirement '{s}' has no linked Test Group", .{gap.primary_id}),
        .requirement_only_unresolved_test_group_refs => std.fmt.allocPrint(alloc, "Requirement '{s}' only references unresolved Test Groups", .{gap.primary_id}),
        .requirement_linked_to_empty_test_group => std.fmt.allocPrint(alloc, "Requirement '{s}' is linked to an empty Test Group", .{gap.primary_id}),
        .user_need_without_requirements => std.fmt.allocPrint(alloc, "User Need '{s}' has no linked Requirements", .{gap.primary_id}),
        .test_group_without_requirements => std.fmt.allocPrint(alloc, "Test Group '{s}' has no linked Requirements", .{gap.primary_id}),
        .risk_without_mitigation_requirement => std.fmt.allocPrint(alloc, "Risk '{s}' has no mitigation Requirement", .{gap.primary_id}),
        .risk_unresolved_mitigation_requirement => std.fmt.allocPrint(alloc, "Risk '{s}' references an unresolved mitigation Requirement", .{gap.primary_id}),
    };
}

fn traceGapLt(_: void, a: TraceGap, b: TraceGap) bool {
    const source_cmp = std.math.order(@intFromEnum(a.source), @intFromEnum(b.source));
    if (source_cmp != .eq) return source_cmp == .lt;
    if (a.code != null or b.code != null) {
        const ac = a.code orelse 0;
        const bc = b.code orelse 0;
        const cmp = std.math.order(ac, bc);
        if (cmp != .eq) return cmp == .lt;
    }
    const kind_cmp = std.mem.order(u8, a.kind, b.kind);
    if (kind_cmp != .eq) return kind_cmp == .lt;
    return std.mem.order(u8, a.primary_id, b.primary_id) == .lt;
}

const testing = std.testing;

fn addNode(g: *graph.Graph, id: []const u8, node_type: graph.NodeType) !void {
    try g.addNode(id, node_type, &.{});
}

fn addReqWithAsil(g: *graph.Graph, id: []const u8, asil: []const u8) !void {
    try g.addNode(id, .requirement, &.{
        .{ .key = "asil", .value = asil },
    });
}

test "buildReportContext generic has no profile gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    const ctx = try buildReportContext(&g, .generic, alloc);
    try testing.expectEqual(profile_mod.ProfileId.generic, ctx.profile);
    try testing.expectEqual(@as(usize, 0), ctx.profile_gaps.len);
}

test "buildReportContext medical merges generic and profile hard gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    try addNode(&g, "REQ-001", .requirement);

    const generic_ctx = try buildReportContext(&g, .generic, alloc);
    try testing.expectEqual(@as(usize, 0), generic_ctx.profile_gaps.len);

    const ctx = try buildReportContext(&g, .medical, alloc);
    try testing.expect(ctx.generic_gaps.len >= 2);
    try testing.expect(ctx.profile_gaps.len >= 2);
    try testing.expect(hardGapCount(ctx.merged_gaps) >= 4);

    var found_profile_rule = false;
    for (ctx.merged_gaps) |gap| {
        if (gap.profile_rule) |rule| {
            if (std.mem.eql(u8, rule, "iso13485_requirement_design_input_chain")) {
                found_profile_rule = true;
                try testing.expectEqualStrings("REQ-001", gap.primary_id);
                try testing.expectEqualStrings("ISO 13485 §7.3.3", gap.clause.?);
            }
        }
    }
    try testing.expect(found_profile_rule);
}

test "buildReportContext aerospace emits decomposition profile gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    try addNode(&g, "UN-001", .user_need);
    try addNode(&g, "REQ-001", .requirement);
    try g.addEdge("REQ-001", "UN-001", .derives_from);

    const ctx = try buildReportContext(&g, .aerospace, alloc);
    var found_hlr_gap = false;
    for (ctx.profile_gaps) |gap| {
        if (std.mem.eql(u8, gap.profile_rule, "do178c_hlr_llr_decomposition")) {
            found_hlr_gap = true;
            try testing.expectEqualStrings("REQ-001", gap.node_id);
            try testing.expectEqualStrings("DO-178C Table A-4", gap.clause.?);
        }
    }
    try testing.expect(found_hlr_gap);
}

test "buildReportContext automotive emits ASIL inheritance gap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    try addReqWithAsil(&g, "REQ-P", "D");
    try addReqWithAsil(&g, "REQ-C", "B");
    try g.addEdge("REQ-P", "REQ-C", .refined_by);

    const ctx = try buildReportContext(&g, .automotive, alloc);
    var found_asil_gap = false;
    for (ctx.profile_gaps) |gap| {
        if (std.mem.eql(u8, gap.profile_rule, "iso26262_asil_inheritance")) {
            found_asil_gap = true;
            try testing.expectEqualStrings("REQ-C", gap.node_id);
            try testing.expectEqualStrings("ISO 26262 Part 9 §5", gap.clause.?);
        }
    }
    try testing.expect(found_asil_gap);
}
