const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn appendJsonEscaped(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

pub fn appendJsonQuoted(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
    try buf.append(alloc, '"');
    try appendJsonEscaped(buf, s, alloc);
    try buf.append(alloc, '"');
}

pub fn allocJsonQuoted(s: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try appendJsonQuoted(&buf, s, alloc);
    return buf.toOwnedSlice(alloc);
}

pub fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getObjectField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

pub fn extractJsonFieldStatic(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = key_pos + needle.len;
    while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
    if (pos >= json.len or json[pos] != ':') return null;
    pos += 1;
    while (pos < json.len and std.ascii.isWhitespace(json[pos])) : (pos += 1) {}
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;
    const start = pos;
    while (pos < json.len) : (pos += 1) {
        if (json[pos] == '"' and (pos == start or json[pos - 1] != '\\')) {
            return json[start..pos];
        }
    }
    return null;
}

const testing = std.testing;

test "appendJsonQuoted escapes quotes and slashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const out = try allocJsonQuoted("a\"b\\c", alloc);
    defer alloc.free(out);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", out);
}

test "getString returns string field" {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"x\":\"y\"}", .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("y", getString(parsed.value, "x").?);
}

test "extractJsonFieldStatic tolerates whitespace after colon" {
    const value = extractJsonFieldStatic("{\"x\" : \"y\"}", "x");
    try testing.expect(value != null);
    try testing.expectEqualStrings("y", value.?);
}
