const std = @import("std");
const testing = std.testing;
const graph = @import("../mod.zig");

test "impact forward propagation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");

    var result: std.ArrayList(graph.ImpactNode) = .empty;
    defer result.deinit(alloc);
    try g.impact("REQ-001", alloc, &result);
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("TG-001", result.items[0].id);
    try testing.expectEqualStrings("→", result.items[0].dir);
}

test "impact from user need includes derived requirements and downstream tests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("UN-001", "UserNeed", "{}", null);
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addNode("TEST-001", "Test", "{}", null);
    try g.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("TG-001", "TEST-001", "HAS_TEST");

    var result: std.ArrayList(graph.ImpactNode) = .empty;
    defer result.deinit(alloc);
    try g.impact("UN-001", alloc, &result);
    try testing.expectEqual(@as(usize, 3), result.items.len);
    try testing.expectEqualStrings("REQ-001", result.items[0].id);
    try testing.expectEqualStrings("←", result.items[0].dir);
    try testing.expectEqualStrings("TG-001", result.items[1].id);
    try testing.expectEqualStrings("→", result.items[1].dir);
    try testing.expectEqualStrings("TEST-001", result.items[2].id);
}

test "impact from requirement includes backward mitigations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("RSK-001", "Risk", "{}", null);
    try g.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");

    var result: std.ArrayList(graph.ImpactNode) = .empty;
    defer result.deinit(alloc);
    try g.impact("REQ-001", alloc, &result);
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("RSK-001", result.items[0].id);
    try testing.expectEqualStrings("←", result.items[0].dir);
}
