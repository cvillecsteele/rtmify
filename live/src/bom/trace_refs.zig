const std = @import("std");
const json_util = @import("../json_util.zig");
const shared = @import("../routes/shared.zig");
const graph_live = @import("../graph_live.zig");
const util = @import("util.zig");
const ids = @import("ids.zig");

pub const Allocator = std.mem.Allocator;

pub fn stringSliceContains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn mergeTraceRefLists(existing: *?[]const []const u8, incoming: ?[]const []const u8, alloc: Allocator) !void {
    if (incoming == null) return;
    if (existing.* == null) {
        existing.* = incoming;
        return;
    }

    const old_items = existing.*.?;
    const incoming_items = incoming.?;

    var merged = try alloc.alloc([]const u8, old_items.len + incoming_items.len);
    var count: usize = 0;
    for (old_items) |item| {
        merged[count] = item;
        count += 1;
    }
    for (incoming_items) |item| {
        if (stringSliceContains(merged[0..count], item)) {
            alloc.free(item);
            continue;
        }
        merged[count] = item;
        count += 1;
    }

    alloc.free(old_items);
    alloc.free(incoming_items);
    existing.* = merged[0..count];
}

pub fn parseTraceRefCell(value: []const u8, alloc: Allocator) !?[]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |item| alloc.free(item);
        refs.deinit(alloc);
    }

    var it = std.mem.tokenizeAny(u8, value, ",;|");
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \r\n\t");
        if (trimmed.len == 0 or stringSliceContains(refs.items, trimmed)) continue;
        try refs.append(alloc, try alloc.dupe(u8, trimmed));
    }

    if (refs.items.len == 0) {
        refs.deinit(alloc);
        return null;
    }
    return @constCast(try refs.toOwnedSlice(alloc));
}

pub fn parseTraceRefJsonField(item: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const []const u8 {
    const field = json_util.getObjectField(item, field_name) orelse return null;

    var refs: ?[]const []const u8 = null;
    switch (field) {
        .string => refs = try parseTraceRefCell(field.string, alloc),
        .array => {
            for (field.array.items) |entry| {
                if (entry != .string) {
                    if (refs) |items| util.freeStringSlice(items, alloc);
                    return error.InvalidJson;
                }
                const parsed = try parseTraceRefCell(entry.string, alloc);
                errdefer if (parsed) |items| util.freeStringSlice(items, alloc);
                try mergeTraceRefLists(&refs, parsed, alloc);
            }
        },
        else => return error.InvalidJson,
    }
    return refs;
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

pub fn unresolvedTraceRefs(
    properties_json: []const u8,
    field_name: []const u8,
    linked_nodes: []const graph_live.Node,
    alloc: Allocator,
) ![]const []const u8 {
    const declared = try parseStringArrayProperty(properties_json, field_name, alloc);
    errdefer util.freeStringSlice(declared, alloc);

    var unresolved: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unresolved.items) |item| alloc.free(item);
        unresolved.deinit(alloc);
    }
    for (declared) |declared_id| {
        var matched = false;
        for (linked_nodes) |node| {
            if (std.mem.eql(u8, node.id, declared_id)) {
                matched = true;
                break;
            }
        }
        if (!matched) try unresolved.append(alloc, try alloc.dupe(u8, declared_id));
    }
    util.freeStringSlice(declared, alloc);
    return unresolved.toOwnedSlice(alloc);
}

pub fn referenceEdgePropertiesJson(source_format: @import("types.zig").BomFormat, declared_field: []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"relation_source\":");
    try shared.appendJsonStr(&buf, ids.bomFormatString(source_format), alloc);
    try buf.appendSlice(alloc, ",\"declared_field\":");
    try shared.appendJsonStr(&buf, declared_field, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}
