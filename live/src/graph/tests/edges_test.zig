const std = @import("std");
const testing = std.testing;
const graph = @import("../mod.zig");

test "addEdge idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");

    var edges: std.ArrayList(graph.Edge) = .empty;
    defer edges.deinit(alloc);
    try g.edgesFrom("REQ-001", alloc, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("TESTED_BY", edges.items[0].label);
}

test "nodesMissingEdge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("REQ-002", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");

    var gaps: std.ArrayList(graph.Node) = .empty;
    defer gaps.deinit(alloc);
    try g.nodesMissingEdge("Requirement", "TESTED_BY", alloc, &gaps);
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectEqualStrings("REQ-002", gaps.items[0].id);
}
