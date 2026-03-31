const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("../json_util.zig");
const testing = std.testing;

pub fn extractJsonString(json: []const u8, key: []const u8, alloc: Allocator) ?[]u8 {
    const slice = json_util.extractJsonFieldStatic(json, key) orelse return null;
    return alloc.dupe(u8, slice) catch null;
}

pub fn extractJsonFieldStatic(json: []const u8, key: []const u8) ?[]const u8 {
    return json_util.extractJsonFieldStatic(json, key);
}

pub fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{}) catch return null;
    defer parsed.deinit();
    const field = json_util.getObjectField(parsed.value, key) orelse return null;
    return switch (field) {
        .integer => |v| v,
        else => null,
    };
}

test "extractJsonString found" {
    const json =
        \\{"access_token":"ya29.token_here","expires_in":3599}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tok = extractJsonString(json, "access_token", arena.allocator());
    try testing.expect(tok != null);
    try testing.expectEqualStrings("ya29.token_here", tok.?);
}

test "extractJsonString not found" {
    const json = "{\"foo\":\"bar\"}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tok = extractJsonString(json, "baz", arena.allocator());
    try testing.expect(tok == null);
}

test "extractJsonInt" {
    const json = "{\"expires_in\":3599,\"token_type\":\"Bearer\"}";
    const v = extractJsonInt(json, "expires_in");
    try testing.expect(v != null);
    try testing.expectEqual(@as(i64, 3599), v.?);
}

test "extractJsonInt tolerates whitespace after colon" {
    const json = "{\"expires_in\" : 3599,\"token_type\":\"Bearer\"}";
    const v = extractJsonInt(json, "expires_in");
    try testing.expect(v != null);
    try testing.expectEqual(@as(i64, 3599), v.?);
}

test "extractJsonFieldStatic tolerates whitespace after colon" {
    const json = "{\"properties\":{\"title\": \"User Needs\",\"sheetId\":0}}";
    const title = extractJsonFieldStatic(json, "title");
    try testing.expect(title != null);
    try testing.expectEqualStrings("User Needs", title.?);
}
