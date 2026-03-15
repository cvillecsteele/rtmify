const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("graph.zig");
const profile_mod = @import("profile.zig");

const Graph = graph.Graph;
const Node = graph.Node;
const NodeType = graph.NodeType;
const EdgeLabel = graph.EdgeLabel;
const Profile = profile_mod.Profile;
const Direction = profile_mod.Direction;
const GapSeverity = profile_mod.GapSeverity;
const SpecialGapKind = profile_mod.SpecialGapKind;
const SpecialGapCheck = profile_mod.SpecialGapCheck;

pub const Gap = struct {
    code: u16,
    title: []const u8,
    gap_type: []const u8,
    node_id: []const u8,
    severity: GapSeverity,
    message: []const u8,
    profile_rule: []const u8,
    clause: ?[]const u8 = null,
};

pub fn walkChain(g: *const Graph, profile: Profile, alloc: Allocator) ![]Gap {
    var gaps: std.ArrayList(Gap) = .empty;

    for (profile.chain_steps) |step| {
        if (!step.required) continue;

        var nodes: std.ArrayList(*const Node) = .empty;
        defer nodes.deinit(alloc);
        try g.nodesByType(step.from_type, alloc, &nodes);
        std.mem.sort(*const Node, nodes.items, {}, struct {
            fn lt(_: void, a: *const Node, b: *const Node) bool {
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.lt);

        for (nodes.items) |node| {
            if (hasMatchingEdge(g, node.id, step.direction, step.edge_label, step.to_type)) continue;

            const message = switch (step.direction) {
                .outgoing => try std.fmt.allocPrint(
                    alloc,
                    "{s} '{s}' has no {s} edge to a {s}",
                    .{ step.from_type.toString(), node.id, step.edge_label.toString(), step.to_type.toString() },
                ),
                .incoming => if (step.from_type == .user_need and step.edge_label == .derives_from and step.to_type == .requirement)
                    try std.fmt.allocPrint(alloc, "UserNeed '{s}' has no downstream Requirements", .{node.id})
                else
                    try std.fmt.allocPrint(
                        alloc,
                        "{s} '{s}' has no incoming {s} edge from a {s}",
                        .{ step.from_type.toString(), node.id, step.edge_label.toString(), step.to_type.toString() },
                    ),
            };

            try gaps.append(alloc, .{
                .code = step.code,
                .title = try alloc.dupe(u8, step.title),
                .gap_type = try alloc.dupe(u8, step.gap_type),
                .node_id = try alloc.dupe(u8, node.id),
                .severity = step.severity,
                .message = message,
                .profile_rule = try alloc.dupe(u8, step.profile_rule),
                .clause = if (step.clause) |clause| try alloc.dupe(u8, clause) else null,
            });
        }
    }

    std.mem.sort(Gap, gaps.items, {}, gapLt);
    return gaps.toOwnedSlice(alloc);
}

pub fn walkSpecialGaps(g: *const Graph, profile: Profile, alloc: Allocator) ![]Gap {
    var gaps: std.ArrayList(Gap) = .empty;
    for (profile.special_checks) |check| {
        try appendSpecialGaps(g, check, alloc, &gaps);
    }
    std.mem.sort(Gap, gaps.items, {}, gapLt);
    return gaps.toOwnedSlice(alloc);
}

fn hasMatchingEdge(g: *const Graph, node_id: []const u8, direction: Direction, label: EdgeLabel, other_type: NodeType) bool {
    for (g.edges.items) |e| {
        switch (direction) {
            .outgoing => {
                if (!std.mem.eql(u8, e.from_id, node_id) or e.label != label) continue;
                if (g.getNode(e.to_id)) |other| {
                    if (other.node_type == other_type) return true;
                }
            },
            .incoming => {
                if (!std.mem.eql(u8, e.to_id, node_id) or e.label != label) continue;
                if (g.getNode(e.from_id)) |other| {
                    if (other.node_type == other_type) return true;
                }
            },
        }
    }
    return false;
}

fn appendSpecialGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    switch (check.kind) {
        .unimplemented_requirement => try appendMissingEdgeGap(g, .requirement, .implemented_in, check, "Requirement '{s}' has no current source implementation evidence", alloc, gaps),
        .untested_source_file => try appendMissingEdgeGap(g, .source_file, .verified_by_code, check, "SourceFile '{s}' has no VERIFIED_BY_CODE edge to a test file", alloc, gaps),
        .req_without_design_input => try appendMissingEdgeGap(g, .requirement, .allocated_to, check, "Requirement '{s}' has no ALLOCATED_TO edge to a design input", alloc, gaps),
        .design_input_without_design_output => try appendMissingEdgeGap(g, .design_input, .satisfied_by, check, "DesignInput '{s}' has no SATISFIED_BY edge to a design output", alloc, gaps),
        .design_output_without_source => try appendMissingEdgeGap(g, .design_output, .implemented_in, check, "DesignOutput '{s}' has no IMPLEMENTED_IN edge to a source file", alloc, gaps),
        .design_output_without_config_control => try appendMissingEdgeGap(g, .design_output, .controlled_by, check, "DesignOutput '{s}' has no CONTROLLED_BY edge to a configuration item", alloc, gaps),
        .uncommitted_requirement => try appendUncommittedRequirementGaps(g, check, alloc, gaps),
        .unattributed_annotation => try appendUnattributedAnnotationGaps(g, check, alloc, gaps),
        .hlr_without_llr => try appendHlrWithoutLlrGaps(g, check, alloc, gaps),
        .llr_without_source => try appendLlrWithoutSourceGaps(g, check, alloc, gaps),
        .source_without_structural_coverage => try appendSourceWithoutStructuralCoverageGaps(g, check, alloc, gaps),
        .missing_asil => try appendMissingAsilGaps(g, check, alloc, gaps),
        .asil_inheritance => try appendAsilInheritanceGaps(g, check, alloc, gaps),
    }
}

fn appendGap(check: SpecialGapCheck, node_id: []const u8, message: []const u8, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    try gaps.append(alloc, .{
        .code = check.code,
        .title = try alloc.dupe(u8, check.title),
        .gap_type = try alloc.dupe(u8, check.gap_type),
        .node_id = try alloc.dupe(u8, node_id),
        .severity = check.severity,
        .message = try alloc.dupe(u8, message),
        .profile_rule = try alloc.dupe(u8, check.profile_rule),
        .clause = if (check.clause) |clause| try alloc.dupe(u8, clause) else null,
    });
}

fn appendMissingEdgeGap(
    g: *const Graph,
    node_type: NodeType,
    edge_label: EdgeLabel,
    check: SpecialGapCheck,
    comptime fmt: []const u8,
    alloc: Allocator,
    gaps: *std.ArrayList(Gap),
) !void {
    var nodes: std.ArrayList(*const Node) = .empty;
    defer nodes.deinit(alloc);
    try g.nodesByType(node_type, alloc, &nodes);
    std.mem.sort(*const Node, nodes.items, {}, struct {
        fn lt(_: void, a: *const Node, b: *const Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    for (nodes.items) |node| {
        var found = false;
        for (g.edges.items) |e| {
            if (e.label == edge_label and std.mem.eql(u8, e.from_id, node.id)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        const message = try std.fmt.allocPrint(alloc, fmt, .{node.id});
        try appendGap(check, node.id, message, alloc, gaps);
    }
}

fn appendUncommittedRequirementGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    var reqs: std.ArrayList(*const Node) = .empty;
    defer reqs.deinit(alloc);
    try g.nodesByType(.requirement, alloc, &reqs);
    std.mem.sort(*const Node, reqs.items, {}, struct {
        fn lt(_: void, a: *const Node, b: *const Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    for (reqs.items) |req| {
        var has_impl = false;
        var has_commit = false;
        for (g.edges.items) |e| {
            if (!std.mem.eql(u8, e.from_id, req.id)) continue;
            if (e.label == .implemented_in) has_impl = true;
            if (e.label == .committed_in) has_commit = true;
        }
        if (has_impl and !has_commit) {
            const message = try std.fmt.allocPrint(alloc, "Requirement '{s}' has implementation evidence but no explicit commit-message trace", .{req.id});
            try appendGap(check, req.id, message, alloc, gaps);
        }
    }
}

fn appendUnattributedAnnotationGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    var nodes: std.ArrayList(*const Node) = .empty;
    defer nodes.deinit(alloc);
    try g.nodesByType(.code_annotation, alloc, &nodes);
    std.mem.sort(*const Node, nodes.items, {}, struct {
        fn lt(_: void, a: *const Node, b: *const Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    for (nodes.items) |node| {
        const blame_author = node.get("blame_author") orelse "";
        const author_time = node.get("author_time") orelse "";
        if (blame_author.len > 0 and author_time.len > 0 and !std.mem.eql(u8, author_time, "0")) continue;
        const message = try std.fmt.allocPrint(alloc, "RTMify found a requirement tag at {s}, but could not determine who last changed that line", .{node.id});
        try appendGap(check, node.id, message, alloc, gaps);
    }
}

fn appendHlrWithoutLlrGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    var reqs: std.ArrayList(*const Node) = .empty;
    defer reqs.deinit(alloc);
    try g.nodesByType(.requirement, alloc, &reqs);
    std.mem.sort(*const Node, reqs.items, {}, struct {
        fn lt(_: void, a: *const Node, b: *const Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    for (reqs.items) |req| {
        var derives_from_user_need = false;
        var has_child_requirement = false;
        for (g.edges.items) |e| {
            if (std.mem.eql(u8, e.from_id, req.id) and e.label == .derives_from) {
                if (g.getNode(e.to_id)) |n| {
                    if (n.node_type == .user_need) derives_from_user_need = true;
                }
            }
            if (std.mem.eql(u8, e.from_id, req.id) and e.label == .refined_by) {
                if (g.getNode(e.to_id)) |n| {
                    if (n.node_type == .requirement) has_child_requirement = true;
                }
            }
        }
        if (derives_from_user_need and !has_child_requirement) {
            const message = try std.fmt.allocPrint(alloc, "Requirement '{s}' has no downstream lower-level Requirements", .{req.id});
            try appendGap(check, req.id, message, alloc, gaps);
        }
    }
}

fn appendLlrWithoutSourceGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    var reqs: std.ArrayList(*const Node) = .empty;
    defer reqs.deinit(alloc);
    try g.nodesByType(.requirement, alloc, &reqs);
    std.mem.sort(*const Node, reqs.items, {}, struct {
        fn lt(_: void, a: *const Node, b: *const Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    for (reqs.items) |req| {
        var is_child = false;
        var has_source = false;
        for (g.edges.items) |e| {
            if (e.label == .refined_by and std.mem.eql(u8, e.to_id, req.id)) {
                if (g.getNode(e.from_id)) |parent| {
                    if (parent.node_type == .requirement) is_child = true;
                }
            }
            if (e.label == .implemented_in and std.mem.eql(u8, e.from_id, req.id)) {
                has_source = true;
            }
        }
        if (is_child and !has_source) {
            const message = try std.fmt.allocPrint(alloc, "Requirement '{s}' is decomposed but has no current source implementation evidence", .{req.id});
            try appendGap(check, req.id, message, alloc, gaps);
        }
    }
}

fn appendSourceWithoutStructuralCoverageGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    var files: std.ArrayList(*const Node) = .empty;
    defer files.deinit(alloc);
    try g.nodesByType(.source_file, alloc, &files);
    std.mem.sort(*const Node, files.items, {}, struct {
        fn lt(_: void, a: *const Node, b: *const Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    for (files.items) |file| {
        var has_impl_evidence = false;
        var has_test_evidence = false;
        for (g.edges.items) |e| {
            if (std.mem.eql(u8, e.to_id, file.id) and e.label == .implemented_in) has_impl_evidence = true;
            if (std.mem.eql(u8, e.from_id, file.id) and e.label == .contains) has_impl_evidence = true;
            if (std.mem.eql(u8, e.from_id, file.id) and e.label == .verified_by_code) has_test_evidence = true;
        }
        if (has_impl_evidence and !has_test_evidence) {
            const message = try std.fmt.allocPrint(alloc, "SourceFile '{s}' has implementation evidence but no current test evidence", .{file.id});
            try appendGap(check, file.id, message, alloc, gaps);
        }
    }
}

fn appendMissingAsilGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    var reqs: std.ArrayList(*const Node) = .empty;
    defer reqs.deinit(alloc);
    try g.nodesByType(.requirement, alloc, &reqs);
    std.mem.sort(*const Node, reqs.items, {}, struct {
        fn lt(_: void, a: *const Node, b: *const Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lt);
    for (reqs.items) |req| {
        const asil = std.mem.trim(u8, req.get("asil") orelse "", " \t\r\n\"");
        if (asil.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "Requirement '{s}' is missing required property 'asil'", .{req.id});
            try appendGap(check, req.id, message, alloc, gaps);
        }
    }
}

fn appendAsilInheritanceGaps(g: *const Graph, check: SpecialGapCheck, alloc: Allocator, gaps: *std.ArrayList(Gap)) !void {
    for (g.edges.items) |e| {
        if (e.label != .refined_by) continue;
        const parent = g.getNode(e.from_id) orelse continue;
        const child = g.getNode(e.to_id) orelse continue;
        if (parent.node_type != .requirement or child.node_type != .requirement) continue;
        const parent_asil = parent.get("asil") orelse continue;
        const child_asil = child.get("asil") orelse continue;
        const parent_rank = asilRank(parent_asil) orelse continue;
        const child_rank = asilRank(child_asil) orelse continue;
        if (child_rank < parent_rank) {
            const message = try std.fmt.allocPrint(alloc, "Requirement '{s}' has ASIL {s} lower than parent '{s}' ASIL {s}", .{ child.id, child_asil, parent.id, parent_asil });
            try appendGap(check, child.id, message, alloc, gaps);
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

fn gapLt(_: void, a: Gap, b: Gap) bool {
    const code_cmp = std.math.order(a.code, b.code);
    if (code_cmp != .eq) return code_cmp == .lt;
    const type_cmp = std.mem.order(u8, a.gap_type, b.gap_type);
    if (type_cmp != .eq) return type_cmp == .lt;
    return std.mem.order(u8, a.node_id, b.node_id) == .lt;
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
        try w.print(",\"profile_rule\":\"{s}\"", .{gap.profile_rule});
        if (gap.clause) |clause| {
            try w.writeAll(",\"clause\":\"");
            try writeJsonStr(w, clause);
            try w.writeAll("\"");
        } else {
            try w.writeAll(",\"clause\":null");
        }
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

test "walkChain handles incoming derives_from for user needs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("UN-001", .user_need, &.{});
    try g.addNode("UN-002", .user_need, &.{});
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addEdge("REQ-001", "UN-001", .derives_from);

    const gaps = try walkChain(&g, profile_mod.get(.aerospace), alloc);
    try testing.expect(gaps.len > 0);
}

test "walkSpecialGaps includes clause and profile rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("DO-001", .design_output, &.{});

    const gaps = try walkSpecialGaps(&g, profile_mod.get(.medical), alloc);
    var found = false;
    for (gaps) |gap| {
        if (std.mem.eql(u8, gap.gap_type, "design_output_without_config_control")) {
            found = true;
            try testing.expect(gap.clause != null);
            try testing.expect(gap.profile_rule.len > 0);
        }
    }
    try testing.expect(found);
}
