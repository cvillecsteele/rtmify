const std = @import("std");
const json_util = @import("../json_util.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const ids = @import("ids.zig");
const item_specs = @import("item_specs.zig");

pub const Allocator = std.mem.Allocator;

pub fn spdxPurl(pkg: std.json.Value, alloc: Allocator) !?[]const u8 {
    const refs = json_util.getObjectField(pkg, "externalRefs") orelse return null;
    if (refs != .array) return null;
    for (refs.array.items) |ref| {
        if (ref != .object) continue;
        if (json_util.getString(ref, "referenceType")) |ref_type| {
            if (std.mem.eql(u8, ref_type, "purl")) {
                if (json_util.getString(ref, "referenceLocator")) |value| {
                    const dup = try alloc.dupe(u8, value);
                    return dup;
                }
            }
        }
        if (json_util.getString(ref, "referenceLocator")) |value| {
            if (std.mem.startsWith(u8, value, "pkg:")) {
                const dup = try alloc.dupe(u8, value);
                return dup;
            }
        }
    }
    return null;
}

pub fn spdxItemSpec(pkg: std.json.Value, alloc: Allocator) !types.ItemSpec {
    const name = json_util.getString(pkg, "name") orelse return error.InvalidJson;
    const version = json_util.getString(pkg, "versionInfo") orelse "";
    return .{
        .part = try alloc.dupe(u8, name),
        .revision = try alloc.dupe(u8, version),
        .description = if (json_util.getString(pkg, "description")) |value| try alloc.dupe(u8, value) else try alloc.dupe(u8, name),
        .category = null,
        .supplier = null,
        .requirement_ids = null,
        .test_ids = null,
        .purl = try spdxPurl(pkg, alloc),
        .license = if (json_util.getString(pkg, "licenseConcluded")) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = try util.hashesJson(pkg, "checksums", alloc),
        .safety_class = null,
        .known_anomalies = null,
        .anomaly_evaluation = null,
    };
}

pub fn prepareSpdx(root: std.json.Value, alloc: Allocator) (types.BomError || error{OutOfMemory})!types.PreparedBom {
    const bom_name = json_util.getString(root, "bom_name") orelse return error.MissingBomName;
    const packages = json_util.getObjectField(root, "packages") orelse return error.InvalidJson;
    if (packages != .array or packages.array.items.len == 0) return error.InvalidJson;

    var warnings: std.ArrayList(types.BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var item_seen = std.StringHashMap(types.ItemSpec).init(alloc);
    defer item_specs.deinitItemMap(&item_seen, alloc);
    var ref_map = std.StringHashMap([]const u8).init(alloc);
    defer {
        var it = ref_map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        ref_map.deinit();
    }
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

    var root_key_owned: ?[]const u8 = null;
    errdefer if (root_key_owned) |value| alloc.free(value);

    for (packages.array.items, 0..) |pkg, idx| {
        if (pkg != .object) return error.InvalidJson;
        const name = json_util.getString(pkg, "name") orelse return error.InvalidJson;
        const version = json_util.getString(pkg, "versionInfo") orelse "";
        const key = try ids.partRevisionKey(name, version, alloc);
        defer alloc.free(key);
        try item_specs.upsertItemSpecExplicit(&item_seen, key, try spdxItemSpec(pkg, alloc), alloc);
        const ref_value = if (json_util.getString(pkg, "SPDXID")) |value| value else key;
        if (!ref_map.contains(ref_value)) {
            try ref_map.put(try alloc.dupe(u8, ref_value), try alloc.dupe(u8, key));
        }
        if (idx == 0) root_key_owned = try alloc.dupe(u8, key);
    }

    const full_product_identifier = if (json_util.getString(root, "full_product_identifier")) |value|
        try alloc.dupe(u8, value)
    else blk: {
        const root_pkg = packages.array.items[0];
        const root_name = json_util.getString(root_pkg, "name") orelse return error.InvalidJson;
        const root_version = json_util.getString(root_pkg, "versionInfo") orelse "";
        break :blk try std.fmt.allocPrint(alloc, "{s} {s}", .{ root_name, root_version });
    };
    errdefer alloc.free(full_product_identifier);

    var saw_rel = false;
    if (json_util.getObjectField(root, "relationships")) |relationships| {
        if (relationships != .array) return error.InvalidJson;
        for (relationships.array.items) |rel| {
            if (rel != .object) return error.InvalidJson;
            const rel_type = json_util.getString(rel, "relationshipType") orelse continue;
            if (!std.mem.eql(u8, rel_type, "DEPENDS_ON") and !std.mem.eql(u8, rel_type, "CONTAINS")) continue;
            const parent_ref = json_util.getString(rel, "spdxElementId") orelse continue;
            const child_ref = json_util.getString(rel, "relatedSpdxElement") orelse continue;
            const parent_key = ref_map.get(parent_ref) orelse {
                try util.appendWarning(&warnings, "BOM_ORPHAN_CHILD", "SPDX parent was not found in this BOM", parent_ref, alloc);
                continue;
            };
            const child_key = ref_map.get(child_ref) orelse {
                try util.appendWarning(&warnings, "BOM_ORPHAN_CHILD", "SPDX child was not found in this BOM", child_ref, alloc);
                continue;
            };
            saw_rel = true;
            try item_specs.appendRelation(&relation_seen, &relations, parent_key, child_key, alloc, &warnings, child_ref);
        }
    }

    if (!saw_rel) {
        var item_it = item_seen.iterator();
        while (item_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, root_key_owned.?)) continue;
            try item_specs.appendRelation(&relation_seen, &relations, root_key_owned.?, entry.key_ptr.*, alloc, &warnings, entry.value_ptr.part);
        }
    }

    const occurrences = try item_specs.finalizeOccurrences(item_seen, relations.items, root_key_owned.?, .spdx, alloc);
    return .{
        .submission = .{
            .full_product_identifier = full_product_identifier,
            .bom_name = try alloc.dupe(u8, bom_name),
            .bom_type = .software,
            .source_format = .spdx,
            .root_key = root_key_owned,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}
