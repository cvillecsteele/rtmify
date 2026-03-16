const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const http = @import("../http.zig");
const support = @import("support.zig");

test "json rpc parsing tolerates whitespace after colon" {
    var parsed = try support.parseJsonForTest("{\"jsonrpc\" : \"2.0\", \"method\" : \"tools/call\", \"id\" : 1}", testing.allocator);
    defer parsed.deinit();
    try testing.expectEqualStrings("2.0", internal.json_util.getString(parsed.value, "jsonrpc").?);
    try testing.expectEqualStrings("tools/call", internal.json_util.getString(parsed.value, "method").?);
}

test "json rpc id serialization tolerates whitespace around field" {
    var parsed = try support.parseJsonForTest("{\"jsonrpc\":\"2.0\", \"id\" : 42, \"method\":\"ping\"}", testing.allocator);
    defer parsed.deinit();
    const id_value = internal.json_util.getObjectField(parsed.value, "id").?;
    const id_raw = try std.json.Stringify.valueAlloc(testing.allocator, id_value, .{});
    defer testing.allocator.free(id_raw);
    try testing.expectEqualStrings("42", id_raw);
}

test "json rpc id string serialization preserves raw JSON string" {
    var parsed = try support.parseJsonForTest("{\"jsonrpc\":\"2.0\", \"id\" : \"req-1\", \"method\":\"ping\"}", testing.allocator);
    defer parsed.deinit();
    const id_value = internal.json_util.getObjectField(parsed.value, "id").?;
    const id_raw = try std.json.Stringify.valueAlloc(testing.allocator, id_value, .{});
    defer testing.allocator.free(id_raw);
    try testing.expectEqualStrings("\"req-1\"", id_raw);
}

test "json rpc notification detection tolerates legal spacing" {
    var parsed = try support.parseJsonForTest("{\"method\" : \"notifications/initialized\"}", testing.allocator);
    defer parsed.deinit();
    try testing.expect(internal.json_util.getObjectField(parsed.value, "id") == null);
}

test "large output tools honor limit with truncation note" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"One\",\"status\":\"Approved\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Two\",\"status\":\"Approved\"}", null);
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("limit", .{ .integer = 1 });
    var state: internal.sync_live.SyncState = .{};
    var store = try internal.secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try support.makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const dispatch = try support.buildToolPayloadForTest("get_rtm", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    const payload = switch (dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(payload.note != null);
    try testing.expect(payload.structured_json != null);
    const resp = try http.toolPayloadResultJson("1", "get_rtm", &registry, payload, testing.allocator);
    defer testing.allocator.free(resp);
    var parsed = try support.parseJsonForTest(resp, testing.allocator);
    defer parsed.deinit();
    const result = internal.json_util.getObjectField(parsed.value, "result") orelse return error.TestUnexpectedResult;
    const structured = internal.json_util.getObjectField(result, "structuredContent") orelse return error.TestUnexpectedResult;
    try testing.expect(structured == .object);
    try testing.expect(internal.json_util.getObjectField(structured, "workbook") != null);
    try testing.expect(internal.json_util.getObjectField(structured, "data") != null);
}
