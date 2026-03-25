const std = @import("std");
const testing = std.testing;
const graph = @import("../mod.zig");

fn freeTestRows(rows: *std.ArrayList(graph.TestRow), alloc: std.mem.Allocator) void {
    for (rows.items) |row| {
        alloc.free(row.test_group_id);
        if (row.test_id) |v| alloc.free(v);
        if (row.test_type) |v| alloc.free(v);
        if (row.test_method) |v| alloc.free(v);
        for (row.req_ids) |v| alloc.free(v);
        if (row.req_ids.len > 0) alloc.free(row.req_ids);
        for (row.req_statements) |v| alloc.free(v);
        if (row.req_statements.len > 0) alloc.free(row.req_statements);
        if (row.test_suspect_reason) |v| alloc.free(v);
    }
    rows.deinit(alloc);
}

test "rtm basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"SHALL work\",\"status\":\"approved\"}", null);
    try g.addNode("UN-001", "UserNeed", "{\"statement\":\"I need it\"}", null);
    try g.addEdge("REQ-001", "UN-001", "DERIVES_FROM");

    var rows: std.ArrayList(graph.RtmRow) = .empty;
    defer rows.deinit(alloc);
    try g.rtm(alloc, &rows);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_id);
    try testing.expectEqualStrings("UN-001", rows.items[0].user_need_id.?);
}

test "rtm emits multiple rows for multiple linked test groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"SHALL work\",\"status\":\"approved\"}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addNode("TG-002", "TestGroup", "{}", null);
    try g.addNode("T-001", "Test", "{\"result\":\"PASS\"}", null);
    try g.addNode("T-002", "Test", "{\"result\":\"PENDING\"}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("REQ-001", "TG-002", "TESTED_BY");
    try g.addEdge("TG-001", "T-001", "HAS_TEST");
    try g.addEdge("TG-002", "T-002", "HAS_TEST");

    var rows: std.ArrayList(graph.RtmRow) = .empty;
    defer rows.deinit(alloc);
    try g.rtm(alloc, &rows);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("TG-001", rows.items[0].test_group_id.?);
    try testing.expectEqualStrings("TG-002", rows.items[1].test_group_id.?);
}

test "tests aggregates multiple linked requirements for shared test group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"One\"}", null);
    try g.addNode("REQ-002", "Requirement", "{\"statement\":\"Two\"}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addNode("TEST-001", "Test", "{\"test_type\":\"Verification\",\"test_method\":\"Test\"}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("REQ-002", "TG-001", "TESTED_BY");
    try g.addEdge("TG-001", "TEST-001", "HAS_TEST");

    var rows: std.ArrayList(graph.TestRow) = .empty;
    defer freeTestRows(&rows, alloc);
    try g.tests(alloc, &rows);

    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqual(@as(usize, 2), rows.items[0].req_ids.len);
    try testing.expect(rows.items[0].req_id == null);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_ids[0]);
    try testing.expectEqualStrings("REQ-002", rows.items[0].req_ids[1]);
}

test "risks basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("RSK-001", "Risk", "{\"description\":\"GPS loss\",\"initial_severity\":\"4\"}", null);
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");

    var rows: std.ArrayList(graph.RiskRow) = .empty;
    defer rows.deinit(alloc);
    try g.risks(alloc, &rows);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("RSK-001", rows.items[0].risk_id);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_id.?);
}
