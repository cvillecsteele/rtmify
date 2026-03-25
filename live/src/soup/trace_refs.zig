const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const json_util = @import("../json_util.zig");
const item_specs = @import("item_specs.zig");

pub fn parseTraceRefCell(value: []const u8, alloc: Allocator) !?[]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |item| alloc.free(item);
        refs.deinit(alloc);
    }
    var it = std.mem.tokenizeAny(u8, value, ",;|");
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \r\n\t");
        if (trimmed.len == 0 or item_specs.stringSliceContains(refs.items, trimmed)) continue;
        try refs.append(alloc, try alloc.dupe(u8, trimmed));
    }
    if (refs.items.len == 0) {
        refs.deinit(alloc);
        return null;
    }
    return @constCast(try refs.toOwnedSlice(alloc));
}

pub fn parseTraceRefJsonField(value: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const []const u8 {
    const field = json_util.getObjectField(value, field_name) orelse return null;
    var refs: ?[]const []const u8 = null;
    switch (field) {
        .null => return null,
        .string => refs = try parseTraceRefCell(field.string, alloc),
        .array => {
            for (field.array.items) |entry| {
                if (entry != .string) return error.InvalidJson;
                const parsed = try parseTraceRefCell(entry.string, alloc);
                errdefer if (parsed) |items| item_specs.freeStringSlice(items, alloc);
                try item_specs.mergeTraceRefLists(&refs, parsed, alloc);
            }
        },
        else => return error.InvalidJson,
    }
    return refs;
}

pub fn unresolvedTraceRefs(
    declared_ids: []const []const u8,
    linked_nodes: []const graph_live.Node,
    alloc: Allocator,
) ![]const []const u8 {
    var unresolved: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unresolved.items) |item| alloc.free(item);
        unresolved.deinit(alloc);
    }
    for (declared_ids) |declared_id| {
        var matched = false;
        for (linked_nodes) |node| {
            if (std.mem.eql(u8, node.id, declared_id)) {
                matched = true;
                break;
            }
        }
        if (!matched) try unresolved.append(alloc, try alloc.dupe(u8, declared_id));
    }
    return unresolved.toOwnedSlice(alloc);
}

pub fn parseStringArrayProperty(properties_json: []const u8, field_name: []const u8, alloc: Allocator) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, properties_json, .{});
    defer parsed.deinit();
    const field = json_util.getObjectField(parsed.value, field_name) orelse return try alloc.alloc([]const u8, 0);
    if (field != .array) return error.InvalidJson;

    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |item| alloc.free(item);
        items.deinit(alloc);
    }
    for (field.array.items) |entry| {
        if (entry != .string) return error.InvalidJson;
        try items.append(alloc, try alloc.dupe(u8, entry.string));
    }
    return items.toOwnedSlice(alloc);
}

pub fn extractJsonField(properties_json: []const u8, field_name: []const u8) ?[]const u8 {
    return json_util.extractJsonFieldStatic(properties_json, field_name);
}

const testing = std.testing;

test "parseTraceRefCell tokenizes trims and deduplicates refs" {
    const refs = (try parseTraceRefCell(" REQ-1,REQ-2 ; REQ-2 | TG-1 ", testing.allocator)).?;
    defer item_specs.freeStringSlice(refs, testing.allocator);

    try testing.expectEqual(@as(usize, 3), refs.len);
    try testing.expectEqualStrings("REQ-1", refs[0]);
    try testing.expectEqualStrings("REQ-2", refs[1]);
    try testing.expectEqualStrings("TG-1", refs[2]);
}
