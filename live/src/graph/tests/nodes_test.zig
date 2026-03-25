const std = @import("std");
const testing = std.testing;
const graph = @import("../mod.zig");
const graph_live = @import("../../graph_live.zig");

test "shim imports still expose graph db surface" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph_live.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.storeConfig("profile", "medical_device");

    var rows: std.ArrayList(graph_live.RtmRow) = .empty;
    defer rows.deinit(alloc);
    try g.rtm(alloc, &rows);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer diags.deinit(alloc);
    try g.listRuntimeDiagnostics(null, alloc, &diags);
}

test "addNode and getNode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();

    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"The system SHALL work\"}", "hash1");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expect(node != null);
    try testing.expectEqualStrings("REQ-001", node.?.id);
    try testing.expectEqualStrings("Requirement", node.?.type);
    try testing.expect(!node.?.suspect);
    try testing.expect(node.?.suspect_reason == null);
}

test "addNode idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();

    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"first\"}", "h1");
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"second\"}", "h2");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expectEqualStrings(
        "{\"statement\":null,\"effective_statement\":null,\"effective_statement_source\":null,\"text_status\":\"no_source\",\"authoritative_source\":null,\"source_count\":0,\"source_assertions\":[]}",
        node.?.properties,
    );
}

test "getNode missing returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try testing.expect(try g.getNode("DOES-NOT-EXIST", alloc) == null);
}

test "upsertNode creates on first call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v1\"}", "hash1");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expect(node != null);
    try testing.expectEqualStrings(
        "{\"statement\":null,\"effective_statement\":null,\"effective_statement_source\":null,\"text_status\":\"no_source\",\"authoritative_source\":null,\"source_count\":0,\"source_assertions\":[]}",
        node.?.properties,
    );
}

test "upsertNode updates on hash change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v1\"}", "hash1");
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v2\"}", "hash2");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expectEqualStrings(
        "{\"statement\":null,\"effective_statement\":null,\"effective_statement_source\":null,\"text_status\":\"no_source\",\"authoritative_source\":null,\"source_count\":0,\"source_assertions\":[]}",
        node.?.properties,
    );
}

test "upsertNode no-op on same hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v1\"}", "hash1");
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v2\"}", "hash1");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expectEqualStrings(
        "{\"statement\":null,\"effective_statement\":null,\"effective_statement_source\":null,\"text_status\":\"no_source\",\"authoritative_source\":null,\"source_count\":0,\"source_assertions\":[]}",
        node.?.properties,
    );
}

test "upsertNode updates hashless nodes on later overwrite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode("file.zig:42", "CodeAnnotation", "{\"req_id\":\"REQ-001\",\"line_number\":42}", null);
    try g.upsertNode(
        "file.zig:42",
        "CodeAnnotation",
        "{\"req_id\":\"REQ-001\",\"line_number\":42,\"blame_author\":\"alice\",\"author_time\":123}",
        null,
    );
    const node = try g.getNode("file.zig:42", alloc);
    try testing.expect(node != null);
    try testing.expect(std.mem.indexOf(u8, node.?.properties, "\"blame_author\":\"alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, node.?.properties, "\"author_time\":123") != null);
}

test "allNodes and allNodeTypes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("UN-001", "UserNeed", "{}", null);

    var all: std.ArrayList(graph.Node) = .empty;
    defer all.deinit(alloc);
    try g.allNodes(alloc, &all);
    try testing.expectEqual(@as(usize, 2), all.items.len);

    var types_list: std.ArrayList([]const u8) = .empty;
    defer types_list.deinit(alloc);
    try g.allNodeTypes(alloc, &types_list);
    try testing.expectEqual(@as(usize, 2), types_list.items.len);
}

test "upsertNode hash change populates node_history" {
    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();

    try g.upsertNode("REQ-001", "Requirement", "{\"text\":\"v1\"}", "h1");
    try g.upsertNode("REQ-001", "Requirement", "{\"text\":\"v2\"}", "h2");

    var st = try g.db.prepare("SELECT COUNT(*) FROM node_history WHERE node_id='REQ-001'");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 1), st.columnInt(0));

    try g.upsertNode("REQ-001", "Requirement", "{\"text\":\"v3\"}", "h2");
    var st2 = try g.db.prepare("SELECT COUNT(*) FROM node_history WHERE node_id='REQ-001'");
    defer st2.finalize();
    _ = try st2.step();
    try testing.expectEqual(@as(i64, 1), st2.columnInt(0));
}

test "hashRow stable" {
    const cells = [_][]const u8{ "REQ-001", "The system SHALL work", "approved" };
    const h1 = graph.hashRow(&cells);
    const h2 = graph.hashRow(&cells);
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "hashRow different input" {
    const a = [_][]const u8{ "REQ-001", "v1" };
    const b = [_][]const u8{ "REQ-001", "v2" };
    const h1 = graph.hashRow(&a);
    const h2 = graph.hashRow(&b);
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}
