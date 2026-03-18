const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const prompts = @import("../prompts.zig");
const support = @import("support.zig");

test "prompts list returns expected names" {
    const resp = try prompts.promptsListResult(testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_requirement") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "impact_of_change") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "inspect_bom_item_traceability") != null);
}

test "prompts get interpolates arguments" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "REQ-001" });
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try prompts.promptGetResult("trace_requirement", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "design-history://REQ-001") != null);
}

test "bom trace prompt references get_bom_item and bom-item resource" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A" });
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try prompts.promptGetResult("inspect_bom_item_traceability", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "get_bom_item") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Unresolved Declared Refs") != null);
}

test "bom coverage prompt references design bom tools" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("full_product_identifier", .{ .string = "ASM-1000-REV-C" });
    try args_obj.put("bom_name", .{ .string = "pcba" });
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try prompts.promptGetResult("bom_coverage", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "list_design_boms") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "bom_gaps") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "bom_impact_analysis") != null);
}
