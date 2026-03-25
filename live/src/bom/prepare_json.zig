const std = @import("std");
const json_util = @import("../json_util.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const ids = @import("ids.zig");
const trace_refs = @import("trace_refs.zig");
const item_specs = @import("item_specs.zig");

pub const Allocator = std.mem.Allocator;

pub fn prepareHardwareJson(root: std.json.Value, alloc: Allocator) (types.BomError || error{OutOfMemory})!types.PreparedBom {
    const bom_name = json_util.getString(root, "bom_name") orelse return error.MissingBomName;
    const full_identifier = json_util.getString(root, "full_product_identifier") orelse return error.MissingFullProductIdentifier;
    const items_value = json_util.getObjectField(root, "bom_items") orelse return error.EmptyBomItems;
    if (items_value != .array or items_value.array.items.len == 0) return error.EmptyBomItems;

    var warnings: std.ArrayList(types.BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var item_seen = std.StringHashMap(types.ItemSpec).init(alloc);
    defer item_specs.deinitItemMap(&item_seen, alloc);
    var relation_seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = relation_seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        relation_seen.deinit();
    }
    var relations: std.ArrayList(types.RelationSpec) = .empty;
    defer {
        for (relations.items) |relation| {
            if (relation.parent_key) |value| alloc.free(value);
            alloc.free(relation.child_key);
            if (relation.quantity) |value| alloc.free(value);
            if (relation.ref_designator) |value| alloc.free(value);
            if (relation.supplier) |value| alloc.free(value);
        }
        relations.deinit(alloc);
    }

    for (items_value.array.items) |item| {
        if (item != .object) return error.InvalidJson;
        const parent_part = json_util.getString(item, "parent_part") orelse return error.MissingRequiredField;
        const parent_revision = util.defaultJsonString(json_util.getString(item, "parent_revision"), "-");
        const child_part = json_util.getString(item, "child_part") orelse return error.MissingRequiredField;
        const child_revision = util.defaultJsonString(json_util.getString(item, "child_revision"), "-");
        const quantity = json_util.getString(item, "quantity") orelse return error.MissingRequiredField;

        const parent_key = try ids.partRevisionKey(parent_part, parent_revision, alloc);
        defer alloc.free(parent_key);
        const child_key = try ids.partRevisionKey(child_part, child_revision, alloc);
        defer alloc.free(child_key);

        try item_specs.ensureItemSpec(&item_seen, parent_key, parent_part, parent_revision, alloc);
        try item_specs.upsertItemSpecExplicit(
            &item_seen,
            child_key,
            .{
                .part = try alloc.dupe(u8, child_part),
                .revision = try alloc.dupe(u8, child_revision),
                .description = if (json_util.getString(item, "description")) |value| try alloc.dupe(u8, value) else null,
                .category = if (json_util.getString(item, "category")) |value| try alloc.dupe(u8, value) else null,
                .supplier = if (json_util.getString(item, "supplier")) |value| try alloc.dupe(u8, value) else null,
                .requirement_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    const plural = try trace_refs.parseTraceRefJsonField(item, "requirement_ids", alloc);
                    errdefer if (plural) |items| util.freeStringSlice(items, alloc);
                    try trace_refs.mergeTraceRefLists(&refs, plural, alloc);
                    const singular = try trace_refs.parseTraceRefJsonField(item, "requirement_id", alloc);
                    errdefer if (singular) |items| util.freeStringSlice(items, alloc);
                    try trace_refs.mergeTraceRefLists(&refs, singular, alloc);
                    break :blk refs;
                },
                .test_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    const plural = try trace_refs.parseTraceRefJsonField(item, "test_ids", alloc);
                    errdefer if (plural) |items| util.freeStringSlice(items, alloc);
                    try trace_refs.mergeTraceRefLists(&refs, plural, alloc);
                    const singular = try trace_refs.parseTraceRefJsonField(item, "test_id", alloc);
                    errdefer if (singular) |items| util.freeStringSlice(items, alloc);
                    try trace_refs.mergeTraceRefLists(&refs, singular, alloc);
                    break :blk refs;
                },
                .purl = null,
                .license = null,
                .hashes_json = null,
                .safety_class = null,
                .known_anomalies = null,
                .anomaly_evaluation = null,
            },
            alloc,
        );

        const relation_key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ parent_key, child_key });
        if (relation_seen.contains(relation_key)) {
            alloc.free(relation_key);
            try util.appendWarning(&warnings, "BOM_DUPLICATE_CHILD", "Duplicate child under same parent skipped", child_part, alloc);
            continue;
        }
        try relation_seen.put(relation_key, {});
        try relations.append(alloc, .{
            .parent_key = try alloc.dupe(u8, parent_key),
            .child_key = try alloc.dupe(u8, child_key),
            .quantity = try alloc.dupe(u8, quantity),
            .ref_designator = if (json_util.getString(item, "ref_designator")) |value| try alloc.dupe(u8, value) else null,
            .supplier = if (json_util.getString(item, "supplier")) |value| try alloc.dupe(u8, value) else null,
        });
    }

    const occurrences = try item_specs.finalizeOccurrences(item_seen, relations.items, null, .hardware_json, alloc);
    return .{
        .submission = .{
            .full_product_identifier = try alloc.dupe(u8, full_identifier),
            .bom_name = try alloc.dupe(u8, bom_name),
            .bom_type = .hardware,
            .source_format = .hardware_json,
            .root_key = null,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}
