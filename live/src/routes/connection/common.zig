const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("../../json_util.zig");

pub fn parseRequiredStringField(body: []const u8, key: []const u8, alloc: Allocator) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const value = json_util.getString(parsed.value, key) orelse return error.InvalidJson;
    return alloc.dupe(u8, value);
}

pub fn parseOptionalStringArrayField(body: []const u8, key: []const u8, alloc: Allocator) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const field = json_util.getObjectField(parsed.value, key) orelse return alloc.alloc([]const u8, 0);
    if (field != .array) return error.InvalidJson;
    const out = try alloc.alloc([]const u8, field.array.items.len);
    errdefer alloc.free(out);
    for (field.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidJson;
        out[idx] = try alloc.dupe(u8, item.string);
    }
    return out;
}

pub fn freeStringSlice(values: []const []const u8, alloc: Allocator) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}
