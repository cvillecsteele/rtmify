const std = @import("std");
const types = @import("types.zig");
const ids = @import("ids.zig");
const util = @import("util.zig");
const trace_refs = @import("trace_refs.zig");

pub const Allocator = std.mem.Allocator;

pub fn occurrenceFromItem(parent_key: ?[]const u8, item: types.ItemSpec, alloc: Allocator) !types.BomOccurrenceInput {
    return .{
        .parent_key = if (parent_key) |value| try alloc.dupe(u8, value) else null,
        .child_part = try alloc.dupe(u8, item.part),
        .child_revision = try alloc.dupe(u8, item.revision),
        .description = if (item.description) |value| try alloc.dupe(u8, value) else null,
        .category = if (item.category) |value| try alloc.dupe(u8, value) else null,
        .supplier = if (item.supplier) |value| try alloc.dupe(u8, value) else null,
        .requirement_ids = if (item.requirement_ids) |values| try util.dupStringSlice(values, alloc) else null,
        .test_ids = if (item.test_ids) |values| try util.dupStringSlice(values, alloc) else null,
        .quantity = null,
        .ref_designator = null,
        .purl = if (item.purl) |value| try alloc.dupe(u8, value) else null,
        .license = if (item.license) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = if (item.hashes_json) |value| try alloc.dupe(u8, value) else null,
        .safety_class = if (item.safety_class) |value| try alloc.dupe(u8, value) else null,
        .known_anomalies = if (item.known_anomalies) |value| try alloc.dupe(u8, value) else null,
        .anomaly_evaluation = if (item.anomaly_evaluation) |value| try alloc.dupe(u8, value) else null,
    };
}

pub fn ensureItemSpec(items: *std.StringHashMap(types.ItemSpec), key: []const u8, part: []const u8, revision: []const u8, alloc: Allocator) !void {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const gop = try items.getOrPut(key_copy);
    if (gop.found_existing) {
        alloc.free(key_copy);
        return;
    }
    gop.key_ptr.* = key_copy;
    gop.value_ptr.* = .{
        .part = try alloc.dupe(u8, part),
        .revision = try alloc.dupe(u8, revision),
        .requirement_ids = null,
        .test_ids = null,
    };
}

pub fn upsertItemSpec(items: *std.StringHashMap(types.ItemSpec), key: []const u8, occurrence: types.BomOccurrenceInput, alloc: Allocator) !void {
    try upsertItemSpecExplicit(items, key, .{
        .part = try alloc.dupe(u8, occurrence.child_part),
        .revision = try alloc.dupe(u8, occurrence.child_revision),
        .description = if (occurrence.description) |value| try alloc.dupe(u8, value) else null,
        .category = if (occurrence.category) |value| try alloc.dupe(u8, value) else null,
        .supplier = if (occurrence.supplier) |value| try alloc.dupe(u8, value) else null,
        .requirement_ids = if (occurrence.requirement_ids) |values| try util.dupStringSlice(values, alloc) else null,
        .test_ids = if (occurrence.test_ids) |values| try util.dupStringSlice(values, alloc) else null,
        .purl = if (occurrence.purl) |value| try alloc.dupe(u8, value) else null,
        .license = if (occurrence.license) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = if (occurrence.hashes_json) |value| try alloc.dupe(u8, value) else null,
        .safety_class = if (occurrence.safety_class) |value| try alloc.dupe(u8, value) else null,
        .known_anomalies = if (occurrence.known_anomalies) |value| try alloc.dupe(u8, value) else null,
        .anomaly_evaluation = if (occurrence.anomaly_evaluation) |value| try alloc.dupe(u8, value) else null,
    }, alloc);
}

pub fn upsertItemSpecExplicit(items: *std.StringHashMap(types.ItemSpec), key: []const u8, incoming: types.ItemSpec, alloc: Allocator) !void {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const gop = try items.getOrPut(key_copy);
    if (!gop.found_existing) {
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = incoming;
        return;
    }
    alloc.free(key_copy);
    alloc.free(incoming.part);
    alloc.free(incoming.revision);

    if (incoming.description) |value| {
        if (gop.value_ptr.description == null) {
            gop.value_ptr.description = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.category) |value| {
        if (gop.value_ptr.category == null) {
            gop.value_ptr.category = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.supplier) |value| {
        if (gop.value_ptr.supplier == null) {
            gop.value_ptr.supplier = value;
        } else {
            alloc.free(value);
        }
    }
    try trace_refs.mergeTraceRefLists(&gop.value_ptr.requirement_ids, incoming.requirement_ids, alloc);
    try trace_refs.mergeTraceRefLists(&gop.value_ptr.test_ids, incoming.test_ids, alloc);
    if (incoming.purl) |value| {
        if (gop.value_ptr.purl == null) {
            gop.value_ptr.purl = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.license) |value| {
        if (gop.value_ptr.license == null) {
            gop.value_ptr.license = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.hashes_json) |value| {
        if (gop.value_ptr.hashes_json == null) {
            gop.value_ptr.hashes_json = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.safety_class) |value| {
        if (gop.value_ptr.safety_class == null) {
            gop.value_ptr.safety_class = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.known_anomalies) |value| {
        if (gop.value_ptr.known_anomalies == null) {
            gop.value_ptr.known_anomalies = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.anomaly_evaluation) |value| {
        if (gop.value_ptr.anomaly_evaluation == null) {
            gop.value_ptr.anomaly_evaluation = value;
        } else {
            alloc.free(value);
        }
    }
}

pub fn deinitItemMap(items: *std.StringHashMap(types.ItemSpec), alloc: Allocator) void {
    var it = items.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.part);
        alloc.free(entry.value_ptr.revision);
        if (entry.value_ptr.description) |value| alloc.free(value);
        if (entry.value_ptr.category) |value| alloc.free(value);
        if (entry.value_ptr.supplier) |value| alloc.free(value);
        if (entry.value_ptr.requirement_ids) |values| util.freeStringSlice(values, alloc);
        if (entry.value_ptr.test_ids) |values| util.freeStringSlice(values, alloc);
        if (entry.value_ptr.purl) |value| alloc.free(value);
        if (entry.value_ptr.license) |value| alloc.free(value);
        if (entry.value_ptr.hashes_json) |value| alloc.free(value);
        if (entry.value_ptr.safety_class) |value| alloc.free(value);
        if (entry.value_ptr.known_anomalies) |value| alloc.free(value);
        if (entry.value_ptr.anomaly_evaluation) |value| alloc.free(value);
    }
    items.deinit();
}

pub fn appendRelation(
    seen: *std.StringHashMap(void),
    relations: *std.ArrayList(types.RelationSpec),
    parent_key: []const u8,
    child_key: []const u8,
    alloc: Allocator,
    warnings: *std.ArrayList(types.BomWarning),
    subject: []const u8,
) !void {
    const relation_key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ parent_key, child_key });
    if (seen.contains(relation_key)) {
        alloc.free(relation_key);
        try util.appendWarning(warnings, "BOM_DUPLICATE_CHILD", "Duplicate child under same parent skipped", subject, alloc);
        return;
    }
    try seen.put(relation_key, {});
    try relations.append(alloc, .{
        .parent_key = try alloc.dupe(u8, parent_key),
        .child_key = try alloc.dupe(u8, child_key),
    });
}

pub fn finalizeOccurrences(
    items: std.StringHashMap(types.ItemSpec),
    relations: []const types.RelationSpec,
    preferred_root_key: ?[]const u8,
    source_format: types.BomFormat,
    alloc: Allocator,
) ![]types.BomOccurrenceInput {
    var incoming = std.StringHashMap(void).init(alloc);
    defer {
        var it = incoming.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        incoming.deinit();
    }
    for (relations) |relation| {
        if (!incoming.contains(relation.child_key)) {
            try incoming.put(try alloc.dupe(u8, relation.child_key), {});
        }
    }

    var occurrences: std.ArrayList(types.BomOccurrenceInput) = .empty;
    errdefer {
        for (occurrences.items) |*occurrence| occurrence.deinit(alloc);
        occurrences.deinit(alloc);
    }

    var item_it = items.iterator();
    while (item_it.next()) |entry| {
        const is_preferred_root = preferred_root_key != null and std.mem.eql(u8, entry.key_ptr.*, preferred_root_key.?);
        if (is_preferred_root or (!incoming.contains(entry.key_ptr.*) and !is_preferred_root)) {
            try occurrences.append(alloc, try occurrenceFromItem(null, entry.value_ptr.*, alloc));
        }
    }

    for (relations) |relation| {
        const item = items.get(relation.child_key).?;
        var occurrence = try occurrenceFromItem(relation.parent_key, item, alloc);
        if (relation.quantity) |value| occurrence.quantity = try alloc.dupe(u8, value);
        if (relation.ref_designator) |value| occurrence.ref_designator = try alloc.dupe(u8, value);
        if (relation.supplier) |value| {
            if (occurrence.supplier) |existing| alloc.free(existing);
            occurrence.supplier = try alloc.dupe(u8, value);
        }
        _ = source_format;
        try occurrences.append(alloc, occurrence);
    }

    if (occurrences.items.len == 0) return error.EmptyBomItems;
    return occurrences.toOwnedSlice(alloc);
}

pub fn validateNoCycles(occurrences: []const types.BomOccurrenceInput) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var adjacency = std.StringHashMap(std.ArrayList([]const u8)).init(alloc);
    var state = std.StringHashMap(u8).init(alloc);

    for (occurrences) |occurrence| {
        const child_key = try ids.partRevisionKey(occurrence.child_part, occurrence.child_revision, alloc);
        if (!state.contains(child_key)) try state.put(child_key, 0);
        if (occurrence.parent_key) |parent_key| {
            if (!state.contains(parent_key)) try state.put(try alloc.dupe(u8, parent_key), 0);
            const gop = try adjacency.getOrPut(try alloc.dupe(u8, parent_key));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, child_key);
        }
    }

    var it = state.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            try dfsCycle(entry.key_ptr.*, &adjacency, &state);
        }
    }
}

pub fn dfsCycle(
    key: []const u8,
    adjacency: *std.StringHashMap(std.ArrayList([]const u8)),
    state: *std.StringHashMap(u8),
) !void {
    state.getPtr(key).?.* = 1;
    if (adjacency.getPtr(key)) |children| {
        for (children.items) |child| {
            const child_state = state.get(child) orelse 0;
            if (child_state == 1) return error.CircularReference;
            if (child_state == 0) try dfsCycle(child, adjacency, state);
        }
    }
    state.getPtr(key).?.* = 2;
}
