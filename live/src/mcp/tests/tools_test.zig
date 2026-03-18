const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const support = @import("support.zig");

test "get_node honors include_edges and include_properties flags" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"One\",\"status\":\"Approved\"}", null);
    try db.addNode("TEST-001", "Test", "{\"result\":\"PASS\"}", null);
    try db.addEdge("REQ-001", "TEST-001", "TESTED_BY");

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    var args_default = std.json.ObjectMap.init(testing.allocator);
    defer args_default.deinit();
    try args_default.put("id", .{ .string = "REQ-001" });
    const dispatch_default = try support.buildToolPayloadForTest("get_node", .{ .object = args_default }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch_default.deinit(testing.allocator);
    const payload_default = switch (dispatch_default) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    var parsed_default = try support.parseJsonForTest(payload_default.structured_json.?, testing.allocator);
    defer parsed_default.deinit();
    try testing.expect(internal.json_util.getObjectField(parsed_default.value, "edges_out") != null);
    try testing.expect(internal.json_util.getObjectField(internal.json_util.getObjectField(parsed_default.value, "node").?, "properties") != null);

    var args_no_edges = std.json.ObjectMap.init(testing.allocator);
    defer args_no_edges.deinit();
    try args_no_edges.put("id", .{ .string = "REQ-001" });
    try args_no_edges.put("include_edges", .{ .bool = false });
    const dispatch_no_edges = try support.buildToolPayloadForTest("get_node", .{ .object = args_no_edges }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch_no_edges.deinit(testing.allocator);
    const payload_no_edges = switch (dispatch_no_edges) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    var parsed_no_edges = try support.parseJsonForTest(payload_no_edges.structured_json.?, testing.allocator);
    defer parsed_no_edges.deinit();
    try testing.expect(internal.json_util.getObjectField(parsed_no_edges.value, "edges_out") == null);
    try testing.expect(internal.json_util.getObjectField(parsed_no_edges.value, "edges_in") == null);

    var args_no_props = std.json.ObjectMap.init(testing.allocator);
    defer args_no_props.deinit();
    try args_no_props.put("id", .{ .string = "REQ-001" });
    try args_no_props.put("include_properties", .{ .bool = false });
    const dispatch_no_props = try support.buildToolPayloadForTest("get_node", .{ .object = args_no_props }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch_no_props.deinit(testing.allocator);
    const payload_no_props = switch (dispatch_no_props) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    var parsed_no_props = try support.parseJsonForTest(payload_no_props.structured_json.?, testing.allocator);
    defer parsed_no_props.deinit();
    try testing.expect(internal.json_util.getObjectField(internal.json_util.getObjectField(parsed_no_props.value, "node").?, "properties") == null);
}

test "get_bom_item invalid selector returns specific message" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("bom_name", .{ .string = "pcba" });
    const dispatch = try support.buildToolPayloadForTest("get_bom_item", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    switch (dispatch) {
        .invalid_arguments => |msg| try testing.expectEqualStrings("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", msg),
        else => return error.TestUnexpectedResult,
    }
}

test "implementation changes tool validates required arguments explicitly" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("since", .{ .string = "2026-03-05T00:00:00Z" });
    const dispatch = try support.buildToolPayloadForTest("implementation_changes_since", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    switch (dispatch) {
        .invalid_arguments => |msg| try testing.expectEqualStrings("implementation_changes_since requires 'since' and 'node_type'", msg),
        else => return error.TestUnexpectedResult,
    }
}

test "implementation changes tool returns bounded rows" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("src/foo.c", "SourceFile", "{\"repo\":\"/repo\",\"present\":true}", null);
    try db.addNode("commit-1", "Commit", "{\"short_hash\":\"abc1234\",\"date\":\"2026-03-06T12:30:00Z\",\"message\":\"refactor\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("REQ-001", "src/foo.c", "IMPLEMENTED_IN");
    try db.addEdge("src/foo.c", "commit-1", "CHANGED_IN");
    try db.addEdge("commit-1", "src/foo.c", "CHANGES");

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("since", .{ .string = "2026-03-05T00:00:00Z" });
    try args_obj.put("node_type", .{ .string = "Requirement" });
    try args_obj.put("limit", .{ .integer = 1 });

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const dispatch = try support.buildToolPayloadForTest("implementation_changes_since", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    const payload = switch (dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"node_id\":\"REQ-001\"") != null);
    try testing.expect(payload.note != null);
    try testing.expect(payload.structured_json != null);
}

test "get_bom tool returns product bom tree" {
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
        \\      "quantity": "4",
        \\      "supplier": "Murata"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("full_product_identifier", .{ .string = "ASM-1000-REV-C" });
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    const dispatch = try support.buildToolPayloadForTest("get_bom", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    const payload = switch (dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"bom_name\":\"pcba\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"quantity\":\"4\"") != null);
    try testing.expect(payload.structured_json != null);
}

test "get_bom_item returns linked requirements and tests" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req\"}", null);
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

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A" });
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    const dispatch = try support.buildToolPayloadForTest("get_bom_item", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    const payload = switch (dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"linked_requirements\":[") != null);
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"linked_tests\":[") != null);
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"unresolved_requirement_ids\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"unresolved_test_ids\":[]") != null);
}

test "design bom tools expose list usage and gaps" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\",\"product_status\":\"Active\"}", null);
    try db.addNode("product://ASM-2000-REV-A", "Product", "{\"full_identifier\":\"ASM-2000-REV-A\",\"product_status\":\"Obsolete\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req\"}", null);
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
        \\      "child_part": "FBRFET-3300",
        \\      "child_revision": "A",
        \\      "quantity": "1",
        \\      "requirement_ids": "REQ-001;REQ-404"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);
    var obsolete_ingest = try internal.bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "legacy",
        \\  "full_product_identifier": "ASM-2000-REV-A",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-2000",
        \\      "child_part": "FBRFET-3300",
        \\      "quantity": "1",
        \\      "requirement_ids": "REQ-404"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer obsolete_ingest.deinit(testing.allocator);

    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    var list_args = std.json.ObjectMap.init(testing.allocator);
    defer list_args.deinit();
    try list_args.put("full_product_identifier", .{ .string = "ASM-1000-REV-C" });
    const list_dispatch = try support.buildToolPayloadForTest("list_design_boms", .{ .object = list_args }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer list_dispatch.deinit(testing.allocator);
    const list_payload = switch (list_dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, list_payload.text, "\"design_boms\":[") != null);
    try testing.expect(std.mem.indexOf(u8, list_payload.text, "\"item_count\":") != null);
    try testing.expect(std.mem.indexOf(u8, list_payload.text, "\"ASM-2000-REV-A\"") == null);

    var list_all_args = std.json.ObjectMap.init(testing.allocator);
    defer list_all_args.deinit();
    try list_all_args.put("include_obsolete", .{ .bool = true });
    const list_all_dispatch = try support.buildToolPayloadForTest("list_design_boms", .{ .object = list_all_args }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer list_all_dispatch.deinit(testing.allocator);
    const list_all_payload = switch (list_all_dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, list_all_payload.text, "\"ASM-2000-REV-A\"") != null);

    var usage_args = std.json.ObjectMap.init(testing.allocator);
    defer usage_args.deinit();
    try usage_args.put("part", .{ .string = "FBRFET-3300" });
    const usage_dispatch = try support.buildToolPayloadForTest("find_part_usage", .{ .object = usage_args }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer usage_dispatch.deinit(testing.allocator);
    const usage_payload = switch (usage_dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, usage_payload.text, "\"usages\":[") != null);
    try testing.expect(std.mem.indexOf(u8, usage_payload.text, "FBRFET-3300") != null);
    try testing.expect(std.mem.indexOf(u8, usage_payload.text, "\"ASM-2000-REV-A\"") == null);

    var gaps_args = std.json.ObjectMap.init(testing.allocator);
    defer gaps_args.deinit();
    const gaps_dispatch = try support.buildToolPayloadForTest("bom_gaps", .{ .object = gaps_args }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer gaps_dispatch.deinit(testing.allocator);
    const gaps_payload = switch (gaps_dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, gaps_payload.text, "\"gaps\":[") != null);
    try testing.expect(std.mem.indexOf(u8, gaps_payload.text, "\"REQ-404\"") != null);
    try testing.expect(std.mem.indexOf(u8, gaps_payload.text, "\"ASM-2000-REV-A\"") == null);

    var gaps_all_args = std.json.ObjectMap.init(testing.allocator);
    defer gaps_all_args.deinit();
    try gaps_all_args.put("include_inactive", .{ .bool = true });
    const gaps_all_dispatch = try support.buildToolPayloadForTest("bom_gaps", .{ .object = gaps_all_args }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer gaps_all_dispatch.deinit(testing.allocator);
    const gaps_all_payload = switch (gaps_all_dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, gaps_all_payload.text, "\"ASM-2000-REV-A\"") != null);
}
