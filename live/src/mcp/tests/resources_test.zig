const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const resources = @import("../resources.zig");
const support = @import("support.zig");

test "resources list returns curated resources" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", null);
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode(
        "execution://exec-001",
        "TestExecution",
        "{\"execution_id\":\"exec-001\",\"executed_at\":\"2026-03-17T08:44:00Z\",\"computed_status\":\"passed\",\"serial_number\":\"UNIT-0001\",\"full_product_identifier\":\"ASM-1000-REV-C\"}",
        null,
    );
    try db.addEdge("execution://exec-001", "product://ASM-1000-REV-C", "FOR_PRODUCT");
    try db.addNode("bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A", "BOMItem", "{\"part\":\"C0805-10UF\",\"revision\":\"A\",\"requirement_ids\":[\"REQ-001\"],\"test_ids\":[\"TEST-001\"]}", null);
    const resp = try resources.resourcesListResult(&db, testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "report://status") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "requirements://") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "user-needs://") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "tests://") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "risks://") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "suspects://") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "requirement://REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "user-need://UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "serials://") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "serials://ASM-1000-REV-C") != null);
}

test "resources read returns requirements index markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Implemented and tested\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"No implementation\"}", null);
    try db.addNode("TG-001", "TestGroup", "{\"name\":\"Group\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("REQ-002", "UN-001", "DERIVES_FROM");
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addNode("src/main.c", "SourceFile", "{\"path\":\"src/main.c\"}", null);
    try db.addEdge("REQ-001", "src/main.c", "IMPLEMENTED_IN");

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("requirements://", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Requirements") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Requirements without implementation evidence: 1") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "`REQ-002`") != null);
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

test "resources read returns bom item trace markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("TEST-001", "Test", "{\"name\":\"Test\"}", null);
    var ingest = try internal.bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4",
        \\      "requirement_id": "REQ-001",
        \\      "test_id": "TEST-001"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# BOM Item C0805-10UF@A") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Linked Requirements") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Linked Tests") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "TEST-001") != null);
}

test "resources read returns design bom markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    var ingest = try internal.bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("design-bom://ASM-1000-REV-C/pcba", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Design BOM ASM-1000-REV-C / pcba") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Roots") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "C0805-10UF@A") != null);
}

test "resources read returns product serial markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode(
        "execution://exec-001",
        "TestExecution",
        "{\"execution_id\":\"exec-001\",\"executed_at\":\"2026-03-17T08:44:00Z\",\"computed_status\":\"passed\",\"serial_number\":\"UNIT-0001\",\"full_product_identifier\":\"ASM-1000-REV-C\"}",
        null,
    );
    try db.addEdge("execution://exec-001", "product://ASM-1000-REV-C", "FOR_PRODUCT");

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("serials://ASM-1000-REV-C", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Known Serials for ASM-1000-REV-C") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "UNIT-0001") != null);
}

test "resources read accepts verbose soup component uri form" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://VS-200-REV-C", "Product", "{\"full_identifier\":\"VS-200-REV-C\"}", null);
    var ingest = try internal.soup.ingestJsonBody(
        &db,
        \\{
        \\  "full_product_identifier": "VS-200-REV-C",
        \\  "bom_name": "SOUP Components",
        \\  "components": [
        \\    {
        \\      "component_name": "FreeRTOS",
        \\      "version": "10.5.1",
        \\      "safety_class": "B",
        \\      "known_anomalies": "None known",
        \\      "anomaly_evaluation": "Reviewed",
        \\      "requirement_ids": ["SRS-001"],
        \\      "test_ids": ["TG-001"]
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("soup-component://VS-200-REV-C/SOUP Components/FreeRTOS/FreeRTOS@10.5.1", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# BOM Item FreeRTOS@10.5.1") != null);
}

test "resources read returns user needs index markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need one\"}", null);
    try db.addNode("UN-002", "UserNeed", "{\"statement\":\"Need two\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Derived\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("user-needs://", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# User Needs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "User needs without linked requirements: 1") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "`UN-002`") != null);
}

test "resources read returns user need markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Derived\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("user-need://UN-001", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# User Need UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Derived Requirements") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
}

test "resources read returns tests index markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Need evidence\"}", null);
    try db.addNode("TG-001", "TestGroup", "{\"name\":\"Verification\"}", null);
    try db.addNode("TC-001", "Test", "{\"name\":\"Concrete test\"}", null);
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addEdge("TG-001", "TC-001", "HAS_TEST");

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("tests://", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Tests") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "test-group://TG-001") != null or std.mem.indexOf(u8, resp, "test://TC-001") != null);
}

test "resources read returns risks index markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("RSK-010", "Risk", "{\"description\":\"Open risk\",\"status\":\"Open\",\"residual_severity\":\"5\",\"residual_likelihood\":\"3\"}", null);

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("risks://", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Risks") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "risk://RSK-010") != null);
}

test "resources read returns suspects index markdown" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Changed\"}", null);
    {
        var st = try db.db.prepare("UPDATE nodes SET suspect=1, suspect_reason='stale verification' WHERE id='REQ-001'");
        defer st.finalize();
        _ = try st.step();
    }

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    var license_service = try internal.license.initDefaultStub(testing.allocator, .{});
    defer license_service.deinit(testing.allocator);
    const req_ctx = internal.RequestContext{ .registry = &registry, .secure_store_ref = &store, .state = &state, .license_service = &license_service, .refresh_active_runtime_fn = null, .alloc = testing.allocator };
    const runtime_ctx = internal.RuntimeContext{ .db = &db, .profile_name = "generic" };
    const resp = try resources.resourceReadResult("suspects://", &req_ctx, &runtime_ctx);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Suspects") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "suspect://REQ-001") != null);
}
