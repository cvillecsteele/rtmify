const std = @import("std");
const testing = std.testing;
const graph = @import("../mod.zig");

test "suspect propagation forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", "h1");
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");

    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"changed\"}", "h2");

    const tg = try g.getNode("TG-001", alloc);
    try testing.expect(tg.?.suspect);
    try testing.expect(tg.?.suspect_reason != null);
}

test "clearSuspect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", "h1");
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v2\"}", "h2");

    try g.clearSuspect("TG-001");
    const tg = try g.getNode("TG-001", alloc);
    try testing.expect(!tg.?.suspect);
}
