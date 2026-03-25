const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("graph_live.zig");
const profile_mod = @import("rtmify").profile;
const chain_mod = @import("chain.zig");

pub const ChainGapSummary = chain_mod.Gap;

pub const RequirementHistory = struct {
    requirement: ?graph_live.Node,
    user_needs: []graph_live.Node,
    risks: []graph_live.Node,
    design_inputs: []graph_live.Node,
    design_outputs: []graph_live.Node,
    configuration_items: []graph_live.Node,
    source_files: []graph_live.Node,
    test_files: []graph_live.Node,
    annotations: []graph_live.Node,
    commits: []graph_live.Node,
    chain_gaps: []ChainGapSummary,
    profile: profile_mod.ProfileId,
};

pub const UserNeedHistory = struct {
    user_need: graph_live.Node,
    requirements: []RequirementHistory,
};

pub const DhrReport = struct {
    profile: profile_mod.ProfileId,
    user_need_sections: []UserNeedHistory,
    unlinked_requirements: []RequirementHistory,
};

pub fn deinitRequirementHistory(history: *RequirementHistory, alloc: Allocator) void {
    if (history.requirement) |node| freeNode(node, alloc);
    freeNodeSlice(history.user_needs, alloc);
    freeNodeSlice(history.risks, alloc);
    freeNodeSlice(history.design_inputs, alloc);
    freeNodeSlice(history.design_outputs, alloc);
    freeNodeSlice(history.configuration_items, alloc);
    freeNodeSlice(history.source_files, alloc);
    freeNodeSlice(history.test_files, alloc);
    freeNodeSlice(history.annotations, alloc);
    freeNodeSlice(history.commits, alloc);
    freeGapSlice(history.chain_gaps, alloc);
}

pub fn deinitDhrReport(report: *DhrReport, alloc: Allocator) void {
    for (report.user_need_sections) |*section| {
        freeNode(section.user_need, alloc);
        for (section.requirements) |*history| deinitRequirementHistory(history, alloc);
        alloc.free(section.requirements);
    }
    alloc.free(report.user_need_sections);
    for (report.unlinked_requirements) |*history| deinitRequirementHistory(history, alloc);
    alloc.free(report.unlinked_requirements);
}

pub fn buildRequirementHistory(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) !?RequirementHistory {
    return buildRequirementHistoryForProfile(db, .generic, req_id, alloc);
}

pub fn buildRequirementHistoryForProfile(db: *graph_live.GraphDb, pid: profile_mod.ProfileId, req_id: []const u8, alloc: Allocator) !?RequirementHistory {
    const requirement = try db.getNode(req_id, alloc);
    if (requirement == null) return null;
    return try buildRequirementHistoryFromNode(db, requirement.?, pid, alloc);
}

pub fn buildDhrReport(db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) !DhrReport {
    const pid = profile_mod.fromString(profile_name) orelse .generic;

    var user_needs: std.ArrayList(graph_live.Node) = .empty;
    try db.nodesByType("UserNeed", alloc, &user_needs);

    var sections: std.ArrayList(UserNeedHistory) = .empty;
    errdefer {
        for (sections.items) |*section| {
            freeNode(section.user_need, alloc);
            for (section.requirements) |*history| deinitRequirementHistory(history, alloc);
            alloc.free(section.requirements);
        }
        sections.deinit(alloc);
    }

    for (user_needs.items) |user_need| {
        var req_nodes: std.ArrayList(graph_live.Node) = .empty;
        try collectNodesViaIncomingEdge(db, user_need.id, "DERIVES_FROM", "Requirement", alloc, &req_nodes);

        var req_histories: std.ArrayList(RequirementHistory) = .empty;
        errdefer {
            for (req_histories.items) |*history| deinitRequirementHistory(history, alloc);
            req_histories.deinit(alloc);
        }
        for (req_nodes.items) |req_node| {
            try req_histories.append(alloc, try buildRequirementHistoryFromNode(db, req_node, pid, alloc));
        }
        req_nodes.deinit(alloc);

        try sections.append(alloc, .{
            .user_need = user_need,
            .requirements = try req_histories.toOwnedSlice(alloc),
        });
    }
    user_needs.deinit(alloc);

    var unlinked_nodes: std.ArrayList(graph_live.Node) = .empty;
    defer unlinked_nodes.deinit(alloc);
    try collectUnlinkedRequirements(db, alloc, &unlinked_nodes);

    var unlinked_histories: std.ArrayList(RequirementHistory) = .empty;
    errdefer {
        for (unlinked_histories.items) |*history| deinitRequirementHistory(history, alloc);
        unlinked_histories.deinit(alloc);
    }
    for (unlinked_nodes.items) |req_node| {
        try unlinked_histories.append(alloc, try buildRequirementHistoryFromNode(db, req_node, pid, alloc));
    }

    return .{
        .profile = pid,
        .user_need_sections = try sections.toOwnedSlice(alloc),
        .unlinked_requirements = try unlinked_histories.toOwnedSlice(alloc),
    };
}

fn buildRequirementHistoryFromNode(db: *graph_live.GraphDb, requirement: graph_live.Node, pid: profile_mod.ProfileId, alloc: Allocator) !RequirementHistory {
    const prof = profile_mod.get(pid);

    var user_needs: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&user_needs, alloc);
    var risks: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&risks, alloc);
    var design_inputs: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&design_inputs, alloc);
    var design_outputs: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&design_outputs, alloc);
    var configuration_items: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&configuration_items, alloc);
    var source_files: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&source_files, alloc);
    var test_files: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&test_files, alloc);
    var annotations: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&annotations, alloc);
    var commits: std.ArrayList(graph_live.Node) = .empty;
    errdefer freeNodeList(&commits, alloc);

    try collectNodesViaOutgoingEdge(db, requirement.id, "DERIVES_FROM", "UserNeed", alloc, &user_needs);
    try collectNodesViaIncomingEdge(db, requirement.id, "MITIGATED_BY", "Risk", alloc, &risks);
    try collectNodesViaOutgoingEdge(db, requirement.id, "ALLOCATED_TO", "DesignInput", alloc, &design_inputs);
    try collectNodesViaOutgoingEdge(db, requirement.id, "IMPLEMENTED_IN", "SourceFile", alloc, &source_files);
    try collectNodesViaOutgoingEdge(db, requirement.id, "VERIFIED_BY_CODE", "TestFile", alloc, &test_files);
    try collectNodesViaOutgoingEdge(db, requirement.id, "ANNOTATED_AT", "CodeAnnotation", alloc, &annotations);
    try collectNodesViaOutgoingEdge(db, requirement.id, "COMMITTED_IN", "Commit", alloc, &commits);

    for (design_inputs.items) |di| {
        try collectNodesViaOutgoingEdge(db, di.id, "SATISFIED_BY", "DesignOutput", alloc, &design_outputs);
    }
    for (design_outputs.items) |do_node| {
        try collectNodesViaOutgoingEdge(db, do_node.id, "CONTROLLED_BY", "ConfigurationItem", alloc, &configuration_items);
        try collectNodesViaOutgoingEdge(db, do_node.id, "IMPLEMENTED_IN", "SourceFile", alloc, &source_files);
    }
    for (source_files.items) |src| {
        try collectNodesViaOutgoingEdge(db, src.id, "VERIFIED_BY_CODE", "TestFile", alloc, &test_files);
    }

    const edge_gaps = try chain_mod.walkChain(db, prof, alloc);
    defer freeGapSlice(edge_gaps, alloc);
    const special_gaps = try chain_mod.walkSpecialGaps(db, prof, alloc);
    defer freeGapSlice(special_gaps, alloc);

    var related_ids = std.StringHashMap(void).init(alloc);
    defer {
        var it = related_ids.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        related_ids.deinit();
    }
    try relatedIdsPut(&related_ids, requirement.id, alloc);
    try addNodeIdsToSet(user_needs.items, &related_ids, alloc);
    try addNodeIdsToSet(risks.items, &related_ids, alloc);
    try addNodeIdsToSet(design_inputs.items, &related_ids, alloc);
    try addNodeIdsToSet(design_outputs.items, &related_ids, alloc);
    try addNodeIdsToSet(configuration_items.items, &related_ids, alloc);
    try addNodeIdsToSet(source_files.items, &related_ids, alloc);
    try addNodeIdsToSet(test_files.items, &related_ids, alloc);
    try addNodeIdsToSet(annotations.items, &related_ids, alloc);
    try addNodeIdsToSet(commits.items, &related_ids, alloc);

    var filtered_gaps: std.ArrayList(chain_mod.Gap) = .empty;
    errdefer freeGapList(&filtered_gaps, alloc);
    try appendMatchingGaps(edge_gaps, &related_ids, alloc, &filtered_gaps);
    try appendMatchingGaps(special_gaps, &related_ids, alloc, &filtered_gaps);
    std.mem.sort(chain_mod.Gap, filtered_gaps.items, {}, gapLessThan);

    return .{
        .requirement = requirement,
        .user_needs = try user_needs.toOwnedSlice(alloc),
        .risks = try risks.toOwnedSlice(alloc),
        .design_inputs = try design_inputs.toOwnedSlice(alloc),
        .design_outputs = try design_outputs.toOwnedSlice(alloc),
        .configuration_items = try configuration_items.toOwnedSlice(alloc),
        .source_files = try source_files.toOwnedSlice(alloc),
        .test_files = try test_files.toOwnedSlice(alloc),
        .annotations = try annotations.toOwnedSlice(alloc),
        .commits = try commits.toOwnedSlice(alloc),
        .chain_gaps = try filtered_gaps.toOwnedSlice(alloc),
        .profile = pid,
    };
}

fn freeNode(node: graph_live.Node, alloc: Allocator) void {
    alloc.free(node.id);
    alloc.free(node.type);
    alloc.free(node.properties);
    if (node.suspect_reason) |reason| alloc.free(reason);
}

fn freeNodeSlice(nodes: []graph_live.Node, alloc: Allocator) void {
    for (nodes) |node| freeNode(node, alloc);
    alloc.free(nodes);
}

fn freeNodeList(nodes: *std.ArrayList(graph_live.Node), alloc: Allocator) void {
    for (nodes.items) |node| freeNode(node, alloc);
    nodes.deinit(alloc);
}

fn freeGapSlice(gaps: []const chain_mod.Gap, alloc: Allocator) void {
    for (gaps) |gap| {
        alloc.free(gap.title);
        alloc.free(gap.gap_type);
        alloc.free(gap.node_id);
        alloc.free(gap.message);
    }
    alloc.free(gaps);
}

fn freeGapList(gaps: *std.ArrayList(chain_mod.Gap), alloc: Allocator) void {
    for (gaps.items) |gap| {
        alloc.free(gap.title);
        alloc.free(gap.gap_type);
        alloc.free(gap.node_id);
        alloc.free(gap.message);
    }
    gaps.deinit(alloc);
}

fn nodeLessThan(_: void, a: graph_live.Node, b: graph_live.Node) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn gapLessThan(_: void, a: chain_mod.Gap, b: chain_mod.Gap) bool {
    if (a.code != b.code) return a.code < b.code;
    const node_cmp = std.mem.order(u8, a.node_id, b.node_id);
    if (node_cmp != .eq) return node_cmp == .lt;
    return std.mem.order(u8, a.title, b.title) == .lt;
}

fn addUniqueNode(result: *std.ArrayList(graph_live.Node), node: graph_live.Node, alloc: Allocator) !void {
    for (result.items) |existing| {
        if (std.mem.eql(u8, existing.id, node.id)) {
            freeNode(node, alloc);
            return;
        }
    }
    try result.append(alloc, node);
    std.mem.sort(graph_live.Node, result.items, {}, nodeLessThan);
}

fn collectNodesViaOutgoingEdge(
    db: *graph_live.GraphDb,
    from_id: []const u8,
    edge_label: []const u8,
    node_type: []const u8,
    alloc: Allocator,
    result: *std.ArrayList(graph_live.Node),
) !void {
    var st = try db.db.prepare(
        \\SELECT n.id
        \\FROM nodes n JOIN edges e ON e.to_id = n.id
        \\WHERE e.from_id = ? AND e.label = ? AND n.type = ?
        \\ORDER BY n.id
    );
    defer st.finalize();
    try st.bindText(1, from_id);
    try st.bindText(2, edge_label);
    try st.bindText(3, node_type);
    while (try st.step()) {
        if (try db.getNode(st.columnText(0), alloc)) |node| {
            try addUniqueNode(result, node, alloc);
        }
    }
}

fn collectNodesViaIncomingEdge(
    db: *graph_live.GraphDb,
    to_id: []const u8,
    edge_label: []const u8,
    node_type: []const u8,
    alloc: Allocator,
    result: *std.ArrayList(graph_live.Node),
) !void {
    var st = try db.db.prepare(
        \\SELECT n.id
        \\FROM nodes n JOIN edges e ON e.from_id = n.id
        \\WHERE e.to_id = ? AND e.label = ? AND n.type = ?
        \\ORDER BY n.id
    );
    defer st.finalize();
    try st.bindText(1, to_id);
    try st.bindText(2, edge_label);
    try st.bindText(3, node_type);
    while (try st.step()) {
        if (try db.getNode(st.columnText(0), alloc)) |node| {
            try addUniqueNode(result, node, alloc);
        }
    }
}

fn collectUnlinkedRequirements(
    db: *graph_live.GraphDb,
    alloc: Allocator,
    result: *std.ArrayList(graph_live.Node),
) !void {
    var st = try db.db.prepare(
        \\SELECT n.id
        \\FROM nodes n
        \\WHERE n.type = 'Requirement'
        \\  AND NOT EXISTS (
        \\      SELECT 1 FROM edges e
        \\      JOIN nodes un ON un.id = e.to_id
        \\      WHERE e.from_id = n.id AND e.label = 'DERIVES_FROM' AND un.type = 'UserNeed'
        \\  )
        \\ORDER BY n.id
    );
    defer st.finalize();
    while (try st.step()) {
        if (try db.getNode(st.columnText(0), alloc)) |node| {
            try result.append(alloc, node);
        }
    }
}

fn relatedIdsPut(set: *std.StringHashMap(void), id: []const u8, alloc: Allocator) !void {
    if (set.contains(id)) return;
    try set.put(try alloc.dupe(u8, id), {});
}

fn addNodeIdsToSet(nodes: []const graph_live.Node, set: *std.StringHashMap(void), alloc: Allocator) !void {
    for (nodes) |node| try relatedIdsPut(set, node.id, alloc);
}

fn appendMatchingGaps(
    source_gaps: []const chain_mod.Gap,
    related_ids: *const std.StringHashMap(void),
    alloc: Allocator,
    dest: *std.ArrayList(chain_mod.Gap),
) !void {
    for (source_gaps) |gap| {
        if (!related_ids.contains(gap.node_id)) continue;
        try dest.append(alloc, .{
            .code = gap.code,
            .title = try alloc.dupe(u8, gap.title),
            .gap_type = try alloc.dupe(u8, gap.gap_type),
            .node_id = try alloc.dupe(u8, gap.node_id),
            .severity = gap.severity,
            .message = try alloc.dupe(u8, gap.message),
        });
    }
}

const testing = std.testing;

test "buildRequirementHistory returns null for unknown requirement" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try testing.expect((try buildRequirementHistory(&db, "REQ-404", testing.allocator)) == null);
}

test "buildRequirementHistory builds full bundle and dedupes downstream nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need GPS\",\"source\":\"Customer\",\"priority\":\"High\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Detect GPS loss\",\"status\":\"Approved\"}", null);
    try db.addNode("RSK-001", "Risk", "{\"description\":\"Clock drift\"}", null);
    try db.addNode("DI-001", "DesignInput", "{\"description\":\"Timing spec\"}", null);
    try db.addNode("DO-001", "DesignOutput", "{\"description\":\"GPS firmware\"}", null);
    try db.addNode("CI-001", "ConfigurationItem", "{\"description\":\"Main ECU\"}", null);
    try db.addNode("src/gps.c", "SourceFile", "{\"path\":\"src/gps.c\",\"repo\":\"/tmp/repo\"}", null);
    try db.addNode("test/gps_test.c", "TestFile", "{\"path\":\"test/gps_test.c\",\"repo\":\"/tmp/repo\"}", null);
    try db.addNode("src/gps.c:10", "CodeAnnotation", "{\"req_id\":\"REQ-001\",\"file_path\":\"src/gps.c\",\"line_number\":10}", null);
    try db.addNode("abc123", "Commit", "{\"short_hash\":\"abc123\",\"date\":\"2026-03-09T00:00:00Z\",\"message\":\"Implement GPS trace\"}", null);

    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");
    try db.addEdge("REQ-001", "DI-001", "ALLOCATED_TO");
    try db.addEdge("DI-001", "DO-001", "SATISFIED_BY");
    try db.addEdge("DO-001", "CI-001", "CONTROLLED_BY");
    try db.addEdge("REQ-001", "src/gps.c", "IMPLEMENTED_IN");
    try db.addEdge("DO-001", "src/gps.c", "IMPLEMENTED_IN");
    try db.addEdge("REQ-001", "test/gps_test.c", "VERIFIED_BY_CODE");
    try db.addEdge("src/gps.c", "test/gps_test.c", "VERIFIED_BY_CODE");
    try db.addEdge("REQ-001", "src/gps.c:10", "ANNOTATED_AT");
    try db.addEdge("REQ-001", "abc123", "COMMITTED_IN");

    var history = (try buildRequirementHistoryForProfile(&db, .medical, "REQ-001", alloc)).?;
    defer deinitRequirementHistory(&history, alloc);

    try testing.expectEqual(profile_mod.ProfileId.medical, history.profile);
    try testing.expect(history.requirement != null);
    try testing.expectEqual(@as(usize, 1), history.user_needs.len);
    try testing.expectEqual(@as(usize, 1), history.risks.len);
    try testing.expectEqual(@as(usize, 1), history.design_inputs.len);
    try testing.expectEqual(@as(usize, 1), history.design_outputs.len);
    try testing.expectEqual(@as(usize, 1), history.configuration_items.len);
    try testing.expectEqual(@as(usize, 1), history.source_files.len);
    try testing.expectEqual(@as(usize, 1), history.test_files.len);
    try testing.expectEqual(@as(usize, 1), history.annotations.len);
    try testing.expectEqual(@as(usize, 1), history.commits.len);
}

test "buildDhrReport includes unlinked requirements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need GPS\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Linked req\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Orphan req\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");

    var report = try buildDhrReport(&db, "medical", alloc);
    defer deinitDhrReport(&report, alloc);

    try testing.expectEqual(profile_mod.ProfileId.medical, report.profile);
    try testing.expectEqual(@as(usize, 1), report.user_need_sections.len);
    try testing.expectEqual(@as(usize, 1), report.user_need_sections[0].requirements.len);
    try testing.expectEqual(@as(usize, 1), report.unlinked_requirements.len);
    try testing.expectEqualStrings("REQ-002", report.unlinked_requirements[0].requirement.?.id);
}
