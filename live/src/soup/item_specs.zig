const std = @import("std");
const Allocator = std.mem.Allocator;

const bom = @import("../bom.zig");

pub const SoupItemSpec = struct {
    component_name: []const u8,
    version: []const u8,
    supplier: ?[]const u8 = null,
    category: ?[]const u8 = null,
    license: ?[]const u8 = null,
    purl: ?[]const u8 = null,
    safety_class: ?[]const u8 = null,
    known_anomalies: ?[]const u8 = null,
    anomaly_evaluation: ?[]const u8 = null,
    requirement_ids: ?[]const []const u8 = null,
    test_ids: ?[]const []const u8 = null,

    pub fn deinit(self: *SoupItemSpec, alloc: Allocator) void {
        alloc.free(self.component_name);
        alloc.free(self.version);
        if (self.supplier) |value| alloc.free(value);
        if (self.category) |value| alloc.free(value);
        if (self.license) |value| alloc.free(value);
        if (self.purl) |value| alloc.free(value);
        if (self.safety_class) |value| alloc.free(value);
        if (self.known_anomalies) |value| alloc.free(value);
        if (self.anomaly_evaluation) |value| alloc.free(value);
        if (self.requirement_ids) |values| freeStringSlice(values, alloc);
        if (self.test_ids) |values| freeStringSlice(values, alloc);
    }
};

pub fn appendSoupItemWarnings(
    warnings: *std.ArrayList(bom.BomWarning),
    items: *std.StringHashMap(SoupItemSpec),
    alloc: Allocator,
) !void {
    var it = items.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        const subject = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ item.component_name, item.version });
        defer alloc.free(subject);
        const known = item.known_anomalies orelse "";
        const evaluation = item.anomaly_evaluation orelse "";
        const known_trimmed = std.mem.trim(u8, known, " \r\n\t");
        const evaluation_trimmed = std.mem.trim(u8, evaluation, " \r\n\t");
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item.version, " \r\n\t"), "unknown")) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has version 'unknown'.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_VERSION_UNKNOWN", message, subject, alloc);
        }
        if (known_trimmed.len == 0 and evaluation_trimmed.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has no anomalies documented.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_ANOMALIES_DOCUMENTED", message, subject, alloc);
        } else if (known_trimmed.len > 0 and evaluation_trimmed.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' is missing anomaly evaluation.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_ANOMALY_EVALUATION", message, subject, alloc);
        }
        if (item.requirement_ids == null or item.requirement_ids.?.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has no requirement linkage.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_REQUIREMENT_LINKAGE", message, subject, alloc);
        }
        if (item.test_ids == null or item.test_ids.?.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has no test linkage.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_TEST_LINKAGE", message, subject, alloc);
        }
    }
}

fn appendWarning(
    warnings: *std.ArrayList(bom.BomWarning),
    code: []const u8,
    message: []const u8,
    subject: ?[]const u8,
    alloc: Allocator,
) !void {
    try warnings.append(alloc, .{
        .code = try alloc.dupe(u8, code),
        .message = try alloc.dupe(u8, message),
        .subject = if (subject) |value| try alloc.dupe(u8, value) else null,
    });
}

pub fn upsertSoupItemSpec(items: *std.StringHashMap(SoupItemSpec), key: []const u8, incoming: SoupItemSpec, alloc: Allocator) !void {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const gop = try items.getOrPut(key_copy);
    if (!gop.found_existing) {
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = incoming;
        return;
    }
    alloc.free(key_copy);
    alloc.free(incoming.component_name);
    alloc.free(incoming.version);
    mergeOptionalString(&gop.value_ptr.supplier, incoming.supplier, alloc);
    mergeOptionalString(&gop.value_ptr.category, incoming.category, alloc);
    mergeOptionalString(&gop.value_ptr.license, incoming.license, alloc);
    mergeOptionalString(&gop.value_ptr.purl, incoming.purl, alloc);
    mergeOptionalString(&gop.value_ptr.safety_class, incoming.safety_class, alloc);
    mergeOptionalString(&gop.value_ptr.known_anomalies, incoming.known_anomalies, alloc);
    mergeOptionalString(&gop.value_ptr.anomaly_evaluation, incoming.anomaly_evaluation, alloc);
    try mergeTraceRefLists(&gop.value_ptr.requirement_ids, incoming.requirement_ids, alloc);
    try mergeTraceRefLists(&gop.value_ptr.test_ids, incoming.test_ids, alloc);
}

pub fn mergeOptionalString(target: *?[]const u8, incoming: ?[]const u8, alloc: Allocator) void {
    if (incoming) |value| {
        if (target.* == null) {
            target.* = value;
        } else {
            alloc.free(value);
        }
    }
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
    const finalized = if (count == merged.len)
        merged
    else blk: {
        const shrunk = try alloc.alloc([]const u8, count);
        @memcpy(shrunk, merged[0..count]);
        alloc.free(merged);
        break :blk shrunk;
    };
    alloc.free(old_items);
    alloc.free(incoming_items);
    existing.* = finalized;
}

pub fn stringSliceContains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn dupStringSlice(items: []const []const u8, alloc: Allocator) ![]const []const u8 {
    var duped = try alloc.alloc([]const u8, items.len);
    var count: usize = 0;
    errdefer {
        for (duped[0..count]) |item| alloc.free(item);
        alloc.free(duped);
    }
    for (items, 0..) |item, idx| {
        duped[idx] = try alloc.dupe(u8, item);
        count = idx + 1;
    }
    return duped;
}

pub fn freeStringSlice(items: []const []const u8, alloc: Allocator) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

pub fn deinitSoupItemMap(items: *std.StringHashMap(SoupItemSpec), alloc: Allocator) void {
    var it = items.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        entry.value_ptr.deinit(alloc);
    }
    items.deinit();
}

const testing = std.testing;

test "mergeTraceRefLists deduplicates incoming refs" {
    var existing: ?[]const []const u8 = null;
    const first = try testing.allocator.alloc([]const u8, 2);
    first[0] = try testing.allocator.dupe(u8, "REQ-1");
    first[1] = try testing.allocator.dupe(u8, "REQ-2");
    existing = first;

    const incoming = try testing.allocator.alloc([]const u8, 2);
    incoming[0] = try testing.allocator.dupe(u8, "REQ-2");
    incoming[1] = try testing.allocator.dupe(u8, "REQ-3");

    try mergeTraceRefLists(&existing, incoming, testing.allocator);
    defer freeStringSlice(existing.?, testing.allocator);

    try testing.expectEqual(@as(usize, 3), existing.?.len);
    try testing.expectEqualStrings("REQ-1", existing.?[0]);
    try testing.expectEqualStrings("REQ-2", existing.?[1]);
    try testing.expectEqualStrings("REQ-3", existing.?[2]);
}
