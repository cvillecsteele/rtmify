const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const prompts = @import("../prompts.zig");
const support = @import("support.zig");

test "prompts list returns expected names" {
    const resp = try prompts.promptsListResult(testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_requirement") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_design_artifact") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_user_need") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_test") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_risk") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_unit") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "which_requirements_for_user_need") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "which_tests_for_requirement") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "product_execution_summary") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "open_risk_summary") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "part_blast_radius") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "soup_component_review") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "requirement_change_review") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "impact_of_change") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "inspect_bom_item_traceability") != null);
}

test "design artifact trace prompt references artifact resources" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("artifact_id", .{ .string = "artifact://srs_docx/core" });
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
    const resp = try prompts.promptGetResult("trace_design_artifact", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "artifact://artifact://srs_docx/core") == null);
    try testing.expect(std.mem.indexOf(u8, resp, "artifact://srs_docx/core") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "artifacts://") != null);
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

test "user need trace prompt references user-need resource and impact analysis" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "UN-002" });
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
    const resp = try prompts.promptGetResult("trace_user_need", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "UN-002") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "user-need://UN-002") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "impact://UN-002") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Derived Requirements") != null);
}

test "test trace prompt references test resources and latest results" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "TC-ATP-004" });
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
    const resp = try prompts.promptGetResult("trace_test", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "test://TC-ATP-004") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "test-group://TC-ATP-004") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "get_test_results") != null);
}

test "risk trace prompt references risk resource and impact analysis" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "RSK-010" });
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
    const resp = try prompts.promptGetResult("trace_risk", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "risk://RSK-010") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "impact://RSK-010") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Residual Exposure") != null);
}

test "unit trace prompt references unit history and execution drill-down" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("serial_number", .{ .string = "UNIT-1246" });
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
    const resp = try prompts.promptGetResult("trace_unit", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "get_unit_history") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "get_execution") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "UNIT-1246") != null);
}

test "requirement verification prompt references verification status" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "SRS-015" });
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
    const resp = try prompts.promptGetResult("which_tests_for_requirement", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "requirement://SRS-015") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "get_verification_status") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Verification Gaps") != null);
}

test "product execution summary prompt references serial resources" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("full_product_identifier", .{ .string = "VS-200-REV-C" });
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
    const resp = try prompts.promptGetResult("product_execution_summary", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "serials://VS-200-REV-C") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "get_product_serials") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Known Serials") != null);
}

test "user need direct requirement prompt answers from user-need resource" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "UN-002" });
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
    const resp = try prompts.promptGetResult("which_requirements_for_user_need", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "user-need://UN-002") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "derived requirements first") != null);
}

test "open risk summary prompt references risk inventory" {
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
    const resp = try prompts.promptGetResult("open_risk_summary", null, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "get_risks") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Open Risks") != null);
}

test "part blast radius prompt references usage and impact tools" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("part", .{ .string = "BSS138LT1G" });
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
    const resp = try prompts.promptGetResult("part_blast_radius", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "find_part_usage") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "bom_impact_analysis") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "What Breaks or Needs Review") != null);
}

test "soup component review prompt references soup surfaces" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("full_product_identifier", .{ .string = "VS-200-REV-C" });
    try args_obj.put("part", .{ .string = "mbedTLS" });
    try args_obj.put("bom_name", .{ .string = "SOUP Components" });
    try args_obj.put("revision", .{ .string = "3.4.0" });
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
    const resp = try prompts.promptGetResult("soup_component_review", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "get_soup_components") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "soup-component://VS-200-REV-C/SOUP Components/mbedTLS@3.4.0") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "adequately documented") != null);
}

test "requirement change review prompt references impact history and verification" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "SRS-015" });
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
    const resp = try prompts.promptGetResult("requirement_change_review", .{ .object = args_obj }, &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "design-history://SRS-015") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "impact://SRS-015") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "get_verification_status") != null);
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
