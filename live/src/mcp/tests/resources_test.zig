const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const resources = @import("../resources.zig");
const support = @import("support.zig");

test "resources list returns curated resources" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", null);
    const resp = try resources.resourcesListResult(&db, testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "report://status") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "requirement://REQ-001") != null);
}

test "resources read returns requirement markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", null);
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = undefined, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("requirement://REQ-001", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Requirement REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "User Needs") != null);
}

test "resources read returns impact markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = undefined, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("impact://UN-001", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Impact Analysis for UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
}

test "resources read returns gap markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "aerospace");
    defer registry.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = undefined, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "aerospace" };
    const resp = try resources.resourceReadResult("gap://1203/REQ-001", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "What RTMify Checked") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
}

test "resources read invalid uri returns error" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = undefined, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    try testing.expectError(error.NotFound, resources.resourceReadResult("unknown://x", &req_ctx, &runtime_ctx));
}
