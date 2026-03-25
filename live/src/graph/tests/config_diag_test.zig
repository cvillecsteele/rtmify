const std = @import("std");
const testing = std.testing;
const graph = @import("../mod.zig");

test "storeCredential and getLatestCredential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.storeCredential("{\"client_email\":\"test@example.com\"}");
    const content = try g.getLatestCredential(alloc);
    try testing.expect(content != null);
    try testing.expectEqualStrings("{\"client_email\":\"test@example.com\"}", content.?);
}

test "hasLegacyCredential and clearLegacyCredentials" {
    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();

    try testing.expect(!(try g.hasLegacyCredential()));
    try g.storeCredential("{\"client_email\":\"test@example.com\"}");
    try testing.expect(try g.hasLegacyCredential());
    try g.clearLegacyCredentials();
    try testing.expect(!(try g.hasLegacyCredential()));
}

test "storeConfig and getConfig" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.storeConfig("sheet_id", "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms");
    const val = try g.getConfig("sheet_id", alloc);
    try testing.expect(val != null);
    try testing.expectEqualStrings("1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms", val.?);
}

test "getConfig missing returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    const val = try g.getConfig("nonexistent", alloc);
    try testing.expect(val == null);
}

test "runtime diagnostics round-trip and clear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();

    try g.upsertRuntimeDiagnostic(
        "git:/tmp/repo:1001",
        1001,
        "warn",
        "git log command failed",
        "git log failed for /tmp/repo",
        "git",
        "/tmp/repo",
        "{}",
    );

    var diags: std.ArrayList(graph.RuntimeDiagnostic) = .empty;
    defer diags.deinit(alloc);
    try g.listRuntimeDiagnostics(null, alloc, &diags);
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(@as(u16, 1001), diags.items[0].code);
    try testing.expectEqualStrings("git", diags.items[0].source);

    try g.clearRuntimeDiagnosticsBySubjectPrefix("git", "/tmp/repo");

    diags.clearRetainingCapacity();
    try g.listRuntimeDiagnostics(null, alloc, &diags);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}
