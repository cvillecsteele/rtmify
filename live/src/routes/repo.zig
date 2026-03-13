const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("shared.zig");

const ImplementationChangesGroup = struct {
    node_id: []const u8,
    node_type: []const u8,
    changed_requirements: std.ArrayList([]const u8),
    changed_files: std.ArrayList([]const u8),
    commits: std.ArrayList(graph_live.ImplementationChangeEvidence),
    seen_requirements: std.StringHashMapUnmanaged(void) = .{},
    seen_files: std.StringHashMapUnmanaged(void) = .{},
    seen_commits: std.StringHashMapUnmanaged(void) = .{},

    fn init(node_id: []const u8, node_type: []const u8) ImplementationChangesGroup {
        return .{
            .node_id = node_id,
            .node_type = node_type,
            .changed_requirements = .empty,
            .changed_files = .empty,
            .commits = .empty,
        };
    }

    fn deinit(self: *ImplementationChangesGroup, alloc: Allocator) void {
        self.changed_requirements.deinit(alloc);
        self.changed_files.deinit(alloc);
        self.commits.deinit(alloc);
        self.seen_requirements.deinit(alloc);
        self.seen_files.deinit(alloc);
        self.seen_commits.deinit(alloc);
    }
};

pub fn handleCodeTraceability(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var src_nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&src_nodes, alloc);
    var tst_nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&tst_nodes, alloc);
    try db.nodesByTypePresent("SourceFile", alloc, &src_nodes);
    try db.nodesByTypePresent("TestFile", alloc, &tst_nodes);
    try refreshAnnotationCounts(db, src_nodes.items, alloc);
    try refreshAnnotationCounts(db, tst_nodes.items, alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"source_files\":");
    const src_json = try shared.jsonNodeArray(src_nodes.items, alloc);
    defer alloc.free(src_json);
    try buf.appendSlice(alloc, src_json);
    try buf.appendSlice(alloc, ",\"test_files\":");
    const tst_json = try shared.jsonNodeArray(tst_nodes.items, alloc);
    defer alloc.free(tst_json);
    try buf.appendSlice(alloc, tst_json);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn refreshAnnotationCounts(db: *graph_live.GraphDb, nodes: []graph_live.Node, alloc: Allocator) !void {
    for (nodes) |*node| {
        const count = try shared.countAnnotationsForFile(db, node.id);
        const updated = try replaceAnnotationCount(node.properties, count, alloc);
        alloc.free(node.properties);
        node.properties = updated;
    }
}

fn replaceAnnotationCount(props_json: []const u8, count: i64, alloc: Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, props_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, props_json);

    try parsed.value.object.put("annotation_count", std.json.Value{ .integer = count });

    var out: std.io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return alloc.dupe(u8, out.written());
}

fn isLikelyIso8601Timestamp(s: []const u8) bool {
    if (s.len < 20) return false;
    return std.ascii.isDigit(s[0]) and
        std.ascii.isDigit(s[1]) and
        std.ascii.isDigit(s[2]) and
        std.ascii.isDigit(s[3]) and
        s[4] == '-' and
        s[7] == '-' and
        s[10] == 'T' and
        s[13] == ':' and
        s[16] == ':';
}

pub fn handleImplementationChangesResponse(
    db: *graph_live.GraphDb,
    since: ?[]const u8,
    node_type: ?[]const u8,
    repo: ?[]const u8,
    limit: ?[]const u8,
    offset: ?[]const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    const since_value = since orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing since\"}"), false);
    if (!isLikelyIso8601Timestamp(since_value)) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid since\"}"), false);
    }
    const node_type_value = node_type orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing node_type\"}"), false);
    if (!std.mem.eql(u8, node_type_value, "Requirement") and !std.mem.eql(u8, node_type_value, "UserNeed")) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid node_type\"}"), false);
    }

    const limit_value: usize = blk: {
        if (limit) |v| {
            const parsed = std.fmt.parseInt(usize, v, 10) catch
                return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid limit\"}"), false);
            break :blk parsed;
        }
        break :blk 50;
    };
    const offset_value: usize = blk: {
        if (offset) |v| {
            const parsed = std.fmt.parseInt(usize, v, 10) catch
                return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid offset\"}"), false);
            break :blk parsed;
        }
        break :blk 0;
    };

    var evidence: std.ArrayList(graph_live.ImplementationChangeEvidence) = .empty;
    defer {
        for (evidence.items) |row| {
            alloc.free(row.node_id);
            alloc.free(row.node_type);
            alloc.free(row.requirement_id);
            alloc.free(row.file_id);
            alloc.free(row.commit_id);
            if (row.commit_short_hash) |v| alloc.free(v);
            if (row.commit_date) |v| alloc.free(v);
            if (row.commit_message) |v| alloc.free(v);
        }
        evidence.deinit(alloc);
    }

    if (std.mem.eql(u8, node_type_value, "Requirement")) {
        try db.requirementsWithImplementationChangesSince(since_value, repo, alloc, &evidence);
    } else {
        try db.userNeedsWithImplementationChangesSince(since_value, repo, alloc, &evidence);
    }

    var groups: std.ArrayList(ImplementationChangesGroup) = .empty;
    defer {
        for (groups.items) |*g| g.deinit(alloc);
        groups.deinit(alloc);
    }

    for (evidence.items) |row| {
        var found_index: ?usize = null;
        for (groups.items, 0..) |g, i| {
            if (std.mem.eql(u8, g.node_id, row.node_id)) {
                found_index = i;
                break;
            }
        }
        const gi = if (found_index) |i| i else blk: {
            try groups.append(alloc, ImplementationChangesGroup.init(row.node_id, row.node_type));
            break :blk groups.items.len - 1;
        };
        var group = &groups.items[gi];
        if (!group.seen_requirements.contains(row.requirement_id)) {
            try group.seen_requirements.put(alloc, row.requirement_id, {});
            try group.changed_requirements.append(alloc, row.requirement_id);
        }
        if (!group.seen_files.contains(row.file_id)) {
            try group.seen_files.put(alloc, row.file_id, {});
            try group.changed_files.append(alloc, row.file_id);
        }
        if (!group.seen_commits.contains(row.commit_id)) {
            try group.seen_commits.put(alloc, row.commit_id, {});
            try group.commits.append(alloc, row);
        }
    }

    const start = @min(offset_value, groups.items.len);
    const end = @min(start + limit_value, groups.items.len);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (groups.items[start..end], 0..) |g, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"node_id\":");
        try shared.appendJsonStr(&buf, g.node_id, alloc);
        try buf.appendSlice(alloc, ",\"node_type\":");
        try shared.appendJsonStr(&buf, g.node_type, alloc);
        try buf.appendSlice(alloc, ",\"changed_requirements\":");
        const reqs_json = try shared.jsonStringArray(g.changed_requirements.items, alloc);
        defer alloc.free(reqs_json);
        try buf.appendSlice(alloc, reqs_json);
        try buf.appendSlice(alloc, ",\"changed_files\":");
        const files_json = try shared.jsonStringArray(g.changed_files.items, alloc);
        defer alloc.free(files_json);
        try buf.appendSlice(alloc, files_json);
        try buf.appendSlice(alloc, ",\"commits\":[");
        for (g.commits.items, 0..) |commit, ci| {
            if (ci > 0) try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"id\":");
            try shared.appendJsonStr(&buf, commit.commit_id, alloc);
            try buf.appendSlice(alloc, ",\"short_hash\":");
            try shared.appendJsonStr(&buf, commit.commit_short_hash orelse "", alloc);
            try buf.appendSlice(alloc, ",\"date\":");
            try shared.appendJsonStr(&buf, commit.commit_date orelse "", alloc);
            try buf.appendSlice(alloc, ",\"message\":");
            try shared.appendJsonStr(&buf, commit.commit_message orelse "", alloc);
            try buf.append(alloc, '}');
        }
        try buf.appendSlice(alloc, "]}");
    }
    try buf.append(alloc, ']');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleImplementationChanges(
    db: *graph_live.GraphDb,
    since: ?[]const u8,
    node_type: ?[]const u8,
    repo: ?[]const u8,
    limit: ?[]const u8,
    offset: ?[]const u8,
    alloc: Allocator,
) ![]const u8 {
    const resp = try handleImplementationChangesResponse(db, since, node_type, repo, limit, offset, alloc);
    return resp.body;
}

pub fn handleUnimplementedRequirements(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);
    try db.nodesMissingEdge("Requirement", "IMPLEMENTED_IN", alloc, &nodes);
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleUntestedSourceFiles(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);
    try db.nodesMissingEdge("SourceFile", "VERIFIED_BY_CODE", alloc, &nodes);
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleFileAnnotations(db: *graph_live.GraphDb, file_path: []const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);

    var st = try db.db.prepare(
        "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE type='CodeAnnotation' AND json_extract(properties,'$.file_path')=? ORDER BY id"
    );
    defer st.finalize();
    try st.bindText(1, file_path);
    while (try st.step()) {
        const n = graph_live.Node{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        };
        try nodes.append(alloc, n);
    }
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleCommitHistory(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);

    var st = try db.db.prepare(
        \\SELECT n.id, n.type, n.properties, n.suspect, n.suspect_reason
        \\FROM nodes n JOIN edges e ON e.to_id=n.id
        \\WHERE e.from_id=? AND e.label='COMMITTED_IN' AND n.type='Commit'
        \\ORDER BY n.id DESC
    );
    defer st.finalize();
    try st.bindText(1, req_id);
    while (try st.step()) {
        const n = graph_live.Node{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        };
        try nodes.append(alloc, n);
    }
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleRecentCommits(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);
    var st = try db.db.prepare(
        \\SELECT id, type, properties, suspect, suspect_reason
        \\FROM nodes
        \\WHERE type='Commit'
        \\ORDER BY json_extract(properties,'$.date') DESC, id DESC
        \\LIMIT 20
    );
    defer st.finalize();
    while (try st.step()) {
        try nodes.append(alloc, .{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        });
    }
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleBlameForRequirement(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);

    var st = try db.db.prepare(
        \\SELECT n.id, n.type, n.properties, n.suspect, n.suspect_reason
        \\FROM nodes n JOIN edges e ON e.to_id=n.id
        \\WHERE e.from_id=? AND e.label='ANNOTATED_AT' AND n.type='CodeAnnotation'
        \\ORDER BY n.id
    );
    defer st.finalize();
    try st.bindText(1, req_id);
    while (try st.step()) {
        const n = graph_live.Node{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        };
        try nodes.append(alloc, n);
    }
    return shared.jsonNodeArray(nodes.items, alloc);
}

const testing = std.testing;

test "handleImplementationChanges returns requirement and user need rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("src/foo.c", "SourceFile", "{\"repo\":\"/repo\",\"present\":true}", null);
    try db.addNode("commit-1", "Commit", "{\"short_hash\":\"abc1234\",\"date\":\"2026-03-06T12:30:00Z\",\"message\":\"refactor\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("REQ-001", "src/foo.c", "IMPLEMENTED_IN");
    try db.addEdge("src/foo.c", "commit-1", "CHANGED_IN");
    try db.addEdge("commit-1", "src/foo.c", "CHANGES");

    const req_resp = try handleImplementationChangesResponse(&db, "2026-03-05T00:00:00Z", "Requirement", null, null, null, alloc);
    defer alloc.free(req_resp.body);
    try testing.expectEqual(std.http.Status.ok, req_resp.status);
    try testing.expect(std.mem.indexOf(u8, req_resp.body, "\"node_id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, req_resp.body, "\"changed_files\":[\"src/foo.c\"]") != null);

    const need_resp = try handleImplementationChangesResponse(&db, "2026-03-05T00:00:00Z", "UserNeed", null, null, null, alloc);
    defer alloc.free(need_resp.body);
    try testing.expectEqual(std.http.Status.ok, need_resp.status);
    try testing.expect(std.mem.indexOf(u8, need_resp.body, "\"node_id\":\"UN-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, need_resp.body, "\"changed_requirements\":[\"REQ-001\"]") != null);
}

test "handleImplementationChanges validates since and node_type" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const bad_since = try handleImplementationChangesResponse(&db, "yesterday", "Requirement", null, null, null, testing.allocator);
    defer testing.allocator.free(bad_since.body);
    try testing.expectEqual(std.http.Status.bad_request, bad_since.status);
    try testing.expect(std.mem.indexOf(u8, bad_since.body, "invalid since") != null);

    const bad_type = try handleImplementationChangesResponse(&db, "2026-03-05T00:00:00Z", "Commit", null, null, null, testing.allocator);
    defer testing.allocator.free(bad_type.body);
    try testing.expectEqual(std.http.Status.bad_request, bad_type.status);
    try testing.expect(std.mem.indexOf(u8, bad_type.body, "invalid node_type") != null);
}

test "handleImplementationChanges honors repo limit and offset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("REQ-002", "Requirement", "{}", null);
    try db.addNode("repoA/src/a.c", "SourceFile", "{\"repo\":\"/repoA\",\"present\":true}", null);
    try db.addNode("repoB/src/b.c", "SourceFile", "{\"repo\":\"/repoB\",\"present\":true}", null);
    try db.addNode("commit-a", "Commit", "{\"short_hash\":\"aaaaaaa\",\"date\":\"2026-03-06T12:30:00Z\",\"message\":\"A\"}", null);
    try db.addNode("commit-b", "Commit", "{\"short_hash\":\"bbbbbbb\",\"date\":\"2026-03-07T12:30:00Z\",\"message\":\"B\"}", null);
    try db.addEdge("REQ-001", "repoA/src/a.c", "IMPLEMENTED_IN");
    try db.addEdge("REQ-002", "repoB/src/b.c", "IMPLEMENTED_IN");
    try db.addEdge("repoA/src/a.c", "commit-a", "CHANGED_IN");
    try db.addEdge("repoB/src/b.c", "commit-b", "CHANGED_IN");
    try db.addEdge("commit-a", "repoA/src/a.c", "CHANGES");
    try db.addEdge("commit-b", "repoB/src/b.c", "CHANGES");

    const repo_filtered = try handleImplementationChangesResponse(&db, "2026-03-05T00:00:00Z", "Requirement", "/repoA", null, null, alloc);
    defer alloc.free(repo_filtered.body);
    try testing.expect(std.mem.indexOf(u8, repo_filtered.body, "\"node_id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, repo_filtered.body, "\"node_id\":\"REQ-002\"") == null);

    const limited = try handleImplementationChangesResponse(&db, "2026-03-05T00:00:00Z", "Requirement", null, "1", "1", alloc);
    defer alloc.free(limited.body);
    try testing.expect(std.mem.indexOf(u8, limited.body, "\"node_id\":\"REQ-001\"") != null or std.mem.indexOf(u8, limited.body, "\"node_id\":\"REQ-002\"") != null);
    const has_req_1: usize = if (std.mem.indexOf(u8, limited.body, "\"node_id\":\"REQ-001\"") != null) 1 else 0;
    const has_req_2: usize = if (std.mem.indexOf(u8, limited.body, "\"node_id\":\"REQ-002\"") != null) 1 else 0;
    const count = has_req_1 + has_req_2;
    try testing.expectEqual(@as(usize, 1), count);
}

test "handleCodeTraceability excludes historical only files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("src/current.c", "SourceFile", "{\"repo\":\"/repo\",\"present\":true}", null);
    try db.addNode("src/old_deleted.c", "SourceFile", "{\"repo\":\"/repo\",\"present\":false}", null);
    try db.addNode("tests/current_test.c", "TestFile", "{\"repo\":\"/repo\",\"present\":true}", null);
    try db.addNode("tests/old_test.c", "TestFile", "{\"repo\":\"/repo\",\"present\":false}", null);

    const resp = try handleCodeTraceability(&db, alloc);
    defer alloc.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "src/current.c") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "tests/current_test.c") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "src/old_deleted.c") == null);
    try testing.expect(std.mem.indexOf(u8, resp, "tests/old_test.c") == null);
}

test "handleCodeTraceability refreshes stale annotation_count from current annotations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("/repo/src/example.c", "SourceFile", "{\"path\":\"/repo/src/example.c\",\"repo\":\"/repo\",\"annotation_count\":1,\"present\":true}", null);

    const resp = try handleCodeTraceability(&db, alloc);
    defer alloc.free(resp);

    try testing.expect(std.mem.indexOf(u8, resp, "\"annotation_count\":0") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"annotation_count\":1") == null);
}
