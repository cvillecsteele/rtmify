const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("shared.zig");

pub fn handleNodes(db: *graph_live.GraphDb, type_filter: ?[]const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);
    if (type_filter) |t| {
        try db.nodesByType(t, alloc, &nodes);
    } else {
        try db.allNodes(alloc, &nodes);
    }
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleNodeTypes(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var types: std.ArrayList([]const u8) = .empty;
    defer {
        for (types.items) |t| alloc.free(t);
        types.deinit(alloc);
    }
    try db.allNodeTypes(alloc, &types);
    return shared.jsonStringArray(types.items, alloc);
}

pub fn handleEdgeLabels(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (labels.items) |l| alloc.free(l);
        labels.deinit(alloc);
    }
    try db.allEdgeLabels(alloc, &labels);
    return shared.jsonStringArray(labels.items, alloc);
}

pub fn handleSearch(db: *graph_live.GraphDb, q: []const u8, alloc: Allocator) ![]const u8 {
    var results: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&results, alloc);
    try db.search(q, alloc, &results);
    return shared.jsonNodeArray(results.items, alloc);
}

pub fn handleSchema(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var types: std.ArrayList([]const u8) = .empty;
    defer {
        for (types.items) |t| alloc.free(t);
        types.deinit(alloc);
    }
    var labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (labels.items) |l| alloc.free(l);
        labels.deinit(alloc);
    }
    try db.allNodeTypes(alloc, &types);
    try db.allEdgeLabels(alloc, &labels);

    const types_json = try shared.jsonStringArray(types.items, alloc);
    defer alloc.free(types_json);
    const labels_json = try shared.jsonStringArray(labels.items, alloc);
    defer alloc.free(labels_json);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"node_types\":");
    try buf.appendSlice(alloc, types_json);
    try buf.appendSlice(alloc, ",\"edge_labels\":");
    try buf.appendSlice(alloc, labels_json);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn handleGaps(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var reqs: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&reqs, alloc);
    try db.nodesMissingEdge("Requirement", "TESTED_BY", alloc, &reqs);
    return shared.jsonNodeArray(reqs.items, alloc);
}

pub fn handleRtm(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var rows: std.ArrayList(graph_live.RtmRow) = .empty;
    defer {
        for (rows.items) |r| shared.freeRtmRow(r, alloc);
        rows.deinit(alloc);
    }
    try db.rtm(alloc, &rows);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (rows.items, 0..) |row, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"req_id\":");
        try shared.appendJsonStr(&buf, row.req_id, alloc);
        try buf.appendSlice(alloc, ",\"statement\":");
        try shared.appendJsonStrOpt(&buf, row.statement, alloc);
        try buf.appendSlice(alloc, ",\"status\":");
        try shared.appendJsonStrOpt(&buf, row.status, alloc);
        try buf.appendSlice(alloc, ",\"user_need_id\":");
        try shared.appendJsonStrOpt(&buf, row.user_need_id, alloc);
        try buf.appendSlice(alloc, ",\"test_group_id\":");
        try shared.appendJsonStrOpt(&buf, row.test_group_id, alloc);
        try buf.appendSlice(alloc, ",\"test_id\":");
        try shared.appendJsonStrOpt(&buf, row.test_id, alloc);
        try buf.appendSlice(alloc, ",\"test_type\":");
        try shared.appendJsonStrOpt(&buf, row.test_type, alloc);
        try buf.appendSlice(alloc, ",\"test_method\":");
        try shared.appendJsonStrOpt(&buf, row.test_method, alloc);
        try buf.appendSlice(alloc, ",\"result\":");
        try shared.appendJsonStrOpt(&buf, row.result, alloc);
        try buf.appendSlice(alloc, ",\"suspect\":");
        try buf.appendSlice(alloc, if (row.req_suspect) "true" else "false");
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

pub fn handleImpact(db: *graph_live.GraphDb, node_id: []const u8, alloc: Allocator) ![]const u8 {
    const node = try db.getNode(node_id, alloc);
    if (node == null) return error.NotFound;
    defer shared.freeNode(node.?, alloc);

    var impacts: std.ArrayList(graph_live.ImpactNode) = .empty;
    defer {
        for (impacts.items) |imp| {
            alloc.free(imp.id);
            alloc.free(imp.type);
            alloc.free(imp.properties);
            alloc.free(imp.via);
        }
        impacts.deinit(alloc);
    }
    try db.impact(node_id, alloc, &impacts);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (impacts.items, 0..) |imp, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, imp.id, alloc);
        try buf.appendSlice(alloc, ",\"type\":");
        try shared.appendJsonStr(&buf, imp.type, alloc);
        try buf.appendSlice(alloc, ",\"via\":");
        try shared.appendJsonStr(&buf, imp.via, alloc);
        try buf.appendSlice(alloc, ",\"dir\":");
        try shared.appendJsonStr(&buf, imp.dir, alloc);
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

pub fn handleSuspects(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);
    try db.suspects(alloc, &nodes);
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleUserNeeds(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&nodes, alloc);
    try db.nodesByType("UserNeed", alloc, &nodes);
    return shared.jsonNodeArray(nodes.items, alloc);
}

pub fn handleTests(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var rows: std.ArrayList(graph_live.TestRow) = .empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.test_group_id);
            if (r.test_id) |v| alloc.free(v);
            if (r.test_type) |v| alloc.free(v);
            if (r.test_method) |v| alloc.free(v);
            for (r.req_ids) |v| alloc.free(v);
            if (r.req_ids.len > 0) alloc.free(r.req_ids);
            for (r.req_statements) |v| alloc.free(v);
            if (r.req_statements.len > 0) alloc.free(r.req_statements);
            if (r.test_suspect_reason) |v| alloc.free(v);
        }
        rows.deinit(alloc);
    }
    try db.tests(alloc, &rows);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (rows.items, 0..) |row, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"test_group_id\":");
        try shared.appendJsonStr(&buf, row.test_group_id, alloc);
        try buf.appendSlice(alloc, ",\"test_id\":");
        try shared.appendJsonStrOpt(&buf, row.test_id, alloc);
        try buf.appendSlice(alloc, ",\"test_type\":");
        try shared.appendJsonStrOpt(&buf, row.test_type, alloc);
        try buf.appendSlice(alloc, ",\"test_method\":");
        try shared.appendJsonStrOpt(&buf, row.test_method, alloc);
        try buf.appendSlice(alloc, ",\"req_ids\":");
        const req_ids_json = try shared.jsonStringArray(row.req_ids, alloc);
        defer alloc.free(req_ids_json);
        try buf.appendSlice(alloc, req_ids_json);
        try buf.appendSlice(alloc, ",\"req_statements\":");
        const req_statements_json = try shared.jsonStringArray(row.req_statements, alloc);
        defer alloc.free(req_statements_json);
        try buf.appendSlice(alloc, req_statements_json);
        try buf.appendSlice(alloc, ",\"req_id\":");
        try shared.appendJsonStrOpt(&buf, row.req_id, alloc);
        try buf.appendSlice(alloc, ",\"req_statement\":");
        try shared.appendJsonStrOpt(&buf, row.req_statement, alloc);
        try buf.appendSlice(alloc, ",\"suspect\":");
        try buf.appendSlice(alloc, if (row.test_suspect) "true" else "false");
        try buf.appendSlice(alloc, ",\"suspect_reason\":");
        try shared.appendJsonStrOpt(&buf, row.test_suspect_reason, alloc);
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

pub fn handleRisks(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var rows: std.ArrayList(graph_live.RiskRow) = .empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.risk_id);
            if (r.description) |v| alloc.free(v);
            if (r.initial_severity) |v| alloc.free(v);
            if (r.initial_likelihood) |v| alloc.free(v);
            if (r.mitigation) |v| alloc.free(v);
            if (r.residual_severity) |v| alloc.free(v);
            if (r.residual_likelihood) |v| alloc.free(v);
            if (r.req_id) |v| alloc.free(v);
            if (r.req_statement) |v| alloc.free(v);
        }
        rows.deinit(alloc);
    }
    try db.risks(alloc, &rows);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (rows.items, 0..) |row, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"risk_id\":");
        try shared.appendJsonStr(&buf, row.risk_id, alloc);
        try buf.appendSlice(alloc, ",\"description\":");
        try shared.appendJsonStrOpt(&buf, row.description, alloc);
        try buf.appendSlice(alloc, ",\"initial_severity\":");
        try shared.appendJsonStrOpt(&buf, row.initial_severity, alloc);
        try buf.appendSlice(alloc, ",\"initial_likelihood\":");
        try shared.appendJsonStrOpt(&buf, row.initial_likelihood, alloc);
        try buf.appendSlice(alloc, ",\"mitigation\":");
        try shared.appendJsonStrOpt(&buf, row.mitigation, alloc);
        try buf.appendSlice(alloc, ",\"req_id\":");
        try shared.appendJsonStrOpt(&buf, row.req_id, alloc);
        try buf.appendSlice(alloc, ",\"residual_severity\":");
        try shared.appendJsonStrOpt(&buf, row.residual_severity, alloc);
        try buf.appendSlice(alloc, ",\"residual_likelihood\":");
        try shared.appendJsonStrOpt(&buf, row.residual_likelihood, alloc);
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

pub fn handleNode(db: *graph_live.GraphDb, node_id: []const u8, alloc: Allocator) ![]const u8 {
    const node = try db.getNode(node_id, alloc);
    if (node == null) return error.NotFound;
    defer shared.freeNode(node.?, alloc);

    var edges_from: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges_from.items) |e| shared.freeEdge(e, alloc);
        edges_from.deinit(alloc);
    }
    var edges_to: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges_to.items) |e| shared.freeEdge(e, alloc);
        edges_to.deinit(alloc);
    }
    try db.edgesFrom(node_id, alloc, &edges_from);
    try db.edgesTo(node_id, alloc, &edges_to);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const n = node.?;
    try buf.appendSlice(alloc, "{\"node\":{\"id\":");
    try shared.appendJsonStr(&buf, n.id, alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try shared.appendJsonStr(&buf, n.type, alloc);
    try buf.appendSlice(alloc, ",\"properties\":");
    try buf.appendSlice(alloc, n.properties);
    try buf.appendSlice(alloc, ",\"suspect\":");
    try buf.appendSlice(alloc, if (n.suspect) "true" else "false");
    try buf.appendSlice(alloc, ",\"suspect_reason\":");
    try shared.appendJsonStrOpt(&buf, n.suspect_reason, alloc);
    try buf.appendSlice(alloc, "},\"edges_out\":");
    try shared.appendEdgeArrayWithNode(&buf, db, edges_from.items, .out, alloc);
    try buf.appendSlice(alloc, ",\"edges_in\":");
    try shared.appendEdgeArrayWithNode(&buf, db, edges_to.items, .in, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

const testing = std.testing;

test "handleNode returns node wrapper plus edge arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("TEST-001", "Test", "{\"result\":\"PASS\"}", null);
    try db.addEdge("REQ-001", "TEST-001", "TESTED_BY");

    const resp = try handleNode(&db, "REQ-001", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"node\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"edges_out\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"edges_in\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":\"REQ-001\"") != null);
}

test "handleNode matches dashboard contract structurally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("TEST-001", "Test", "{\"result\":\"PASS\"}", null);
    try db.addEdge("REQ-001", "TEST-001", "TESTED_BY");
    {
        var st = try db.db.prepare("UPDATE nodes SET suspect=1, suspect_reason='changed' WHERE id='REQ-001'");
        defer st.finalize();
        _ = try st.step();
    }

    const resp = try handleNode(&db, "REQ-001", alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.get("node") != null);
    try testing.expect(root.get("edges_out") != null);
    try testing.expect(root.get("edges_in") != null);

    const node = root.get("node").?.object;
    try testing.expectEqualStrings("REQ-001", node.get("id").?.string);
    try testing.expectEqualStrings("Requirement", node.get("type").?.string);
    try testing.expectEqualStrings("Example", node.get("properties").?.object.get("statement").?.string);
    try testing.expect(node.get("suspect").?.bool);
    try testing.expectEqualStrings("changed", node.get("suspect_reason").?.string);

    const edges_out = root.get("edges_out").?.array.items;
    const edges_in = root.get("edges_in").?.array.items;
    try testing.expectEqual(@as(usize, 1), edges_out.len);
    try testing.expectEqual(@as(usize, 0), edges_in.len);
    try testing.expectEqualStrings("TESTED_BY", edges_out[0].object.get("label").?.string);
    try testing.expect(edges_out[0].object.get("node") != null);
    try testing.expectEqualStrings("TEST-001", edges_out[0].object.get("node").?.object.get("id").?.string);
    try testing.expectEqualStrings("Test", edges_out[0].object.get("node").?.object.get("type").?.string);
}

test "handleNode missing node returns not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try testing.expectError(error.NotFound, handleNode(&db, "REQ-404", alloc));
}

test "handleImpact missing node returns not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try testing.expectError(error.NotFound, handleImpact(&db, "REQ-404", alloc));
}

test "handleImpact returns downstream nodes without crashing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Example req\"}", null);
    try db.addNode("TG-002", "TestGroup", "{\"name\":\"Example group\"}", null);
    try db.addEdge("REQ-002", "TG-002", "TESTED_BY");

    const resp = try handleImpact(&db, "REQ-002", alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    const row = rows[0].object;
    try testing.expectEqualStrings("TG-002", row.get("id").?.string);
    try testing.expectEqualStrings("TestGroup", row.get("type").?.string);
    try testing.expectEqualStrings("TESTED_BY", row.get("via").?.string);
    try testing.expectEqualStrings("→", row.get("dir").?.string);
}

test "handleImpact on user need returns derived downstream chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Req\"}", null);
    try db.addNode("TG-002", "TestGroup", "{\"name\":\"Group\"}", null);
    try db.addNode("TEST-002", "Test", "{\"name\":\"Test\"}", null);
    try db.addEdge("REQ-002", "UN-001", "DERIVES_FROM");
    try db.addEdge("REQ-002", "TG-002", "TESTED_BY");
    try db.addEdge("TG-002", "TEST-002", "HAS_TEST");

    const resp = try handleImpact(&db, "UN-001", alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("REQ-002", rows[0].object.get("id").?.string);
    try testing.expectEqualStrings("TG-002", rows[1].object.get("id").?.string);
    try testing.expectEqualStrings("TEST-002", rows[2].object.get("id").?.string);
}

test "handleRisks includes score fields used by dashboard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("RSK-001", "Risk", "{\"description\":\"Example\",\"initial_severity\":\"4\",\"initial_likelihood\":\"3\",\"mitigation\":\"Mitigate\",\"residual_severity\":\"2\",\"residual_likelihood\":\"1\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example req\"}", null);
    try db.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");

    const resp = try handleRisks(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    const row = rows[0].object;
    try testing.expect(row.get("initial_severity") != null);
    try testing.expect(row.get("initial_likelihood") != null);
    try testing.expect(row.get("residual_severity") != null);
    try testing.expect(row.get("residual_likelihood") != null);
}

test "handleRtm uses canonical suspect field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", "changed");

    const resp = try handleRtm(&db, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"suspect\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"req_suspect\":") == null);
}

test "handleTests uses canonical suspect field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addNode("TEST-001", "Test", "{\"test_group_id\":\"TG-001\",\"test_id\":\"TEST-001\",\"test_type\":\"Functional\",\"test_method\":\"Manual\"}", "changed");
    try db.addEdge("TG-001", "TEST-001", "HAS_TEST");

    const resp = try handleTests(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    const row = rows[0].object;
    try testing.expect(row.get("suspect") != null);
    try testing.expect(row.get("test_suspect") == null);
}

test "handleRtm includes multiple linked test groups for one requirement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", null);
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addNode("TG-002", "TestGroup", "{}", null);
    try db.addNode("TEST-001", "Test", "{\"result\":\"PASS\"}", null);
    try db.addNode("TEST-002", "Test", "{\"result\":\"PENDING\"}", null);
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addEdge("REQ-001", "TG-002", "TESTED_BY");
    try db.addEdge("TG-001", "TEST-001", "HAS_TEST");
    try db.addEdge("TG-002", "TEST-002", "HAS_TEST");

    const resp = try handleRtm(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("TG-001", rows[0].object.get("test_group_id").?.string);
    try testing.expectEqualStrings("TG-002", rows[1].object.get("test_group_id").?.string);
}

test "handleTests returns plural linked requirements for shared test groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"One\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Two\"}", null);
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addNode("TEST-001", "Test", "{\"test_type\":\"Functional\",\"test_method\":\"Manual\"}", null);
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addEdge("REQ-002", "TG-001", "TESTED_BY");
    try db.addEdge("TG-001", "TEST-001", "HAS_TEST");

    const resp = try handleTests(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    const row = rows[0].object;
    try testing.expectEqual(@as(usize, 2), row.get("req_ids").?.array.items.len);
    try testing.expectEqualStrings("REQ-001", row.get("req_ids").?.array.items[0].string);
    try testing.expectEqualStrings("REQ-002", row.get("req_ids").?.array.items[1].string);
    try testing.expect(row.get("req_id").? == .null);
    try testing.expect(row.get("req_statement").? == .null);
}
