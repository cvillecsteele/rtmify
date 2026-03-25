const std = @import("std");
const json_util = @import("../json_util.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const ids = @import("ids.zig");
const item_specs = @import("item_specs.zig");

pub const Allocator = std.mem.Allocator;

pub fn cyclonedxLicense(component: std.json.Value, alloc: Allocator) !?[]const u8 {
    const licenses = json_util.getObjectField(component, "licenses") orelse return null;
    if (licenses != .array or licenses.array.items.len == 0) return null;
    const first = licenses.array.items[0];
    if (first == .object) {
        if (json_util.getString(first, "expression")) |value| {
            const dup = try alloc.dupe(u8, value);
            return dup;
        }
        if (json_util.getObjectField(first, "license")) |license_obj| {
            if (json_util.getString(license_obj, "id")) |value| {
                const dup = try alloc.dupe(u8, value);
                return dup;
            }
            if (json_util.getString(license_obj, "name")) |value| {
                const dup = try alloc.dupe(u8, value);
                return dup;
            }
        }
    }
    return null;
}

pub fn cycloneDxItemSpec(component: std.json.Value, alloc: Allocator) !types.ItemSpec {
    const name = json_util.getString(component, "name") orelse return error.InvalidJson;
    const version = json_util.getString(component, "version") orelse "";
    return .{
        .part = try alloc.dupe(u8, name),
        .revision = try alloc.dupe(u8, version),
        .description = if (json_util.getString(component, "description")) |value| try alloc.dupe(u8, value) else try alloc.dupe(u8, name),
        .category = if (json_util.getString(component, "type")) |value| try alloc.dupe(u8, value) else null,
        .supplier = null,
        .requirement_ids = null,
        .test_ids = null,
        .purl = if (json_util.getString(component, "purl")) |value| try alloc.dupe(u8, value) else null,
        .license = try cyclonedxLicense(component, alloc),
        .hashes_json = try util.hashesJson(component, "hashes", alloc),
        .safety_class = null,
        .known_anomalies = null,
        .anomaly_evaluation = null,
    };
}

pub fn prepareCycloneDx(root: std.json.Value, alloc: Allocator) (types.BomError || error{OutOfMemory})!types.PreparedBom {
    const bom_name = json_util.getString(root, "bom_name") orelse return error.MissingBomName;
    const metadata = json_util.getObjectField(root, "metadata") orelse return error.InvalidJson;
    const root_component = json_util.getObjectField(metadata, "component") orelse return error.InvalidJson;
    if (root_component != .object) return error.InvalidJson;
    const root_name = json_util.getString(root_component, "name") orelse return error.InvalidJson;
    const root_version = json_util.getString(root_component, "version") orelse return error.InvalidJson;
    const full_product_identifier = if (json_util.getString(root, "full_product_identifier")) |value|
        try alloc.dupe(u8, value)
    else
        try std.fmt.allocPrint(alloc, "{s} {s}", .{ root_name, root_version });
    errdefer alloc.free(full_product_identifier);

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

    const root_key_owned = try ids.partRevisionKey(root_name, root_version, alloc);
    errdefer alloc.free(root_key_owned);
    try item_specs.upsertItemSpecExplicit(&item_seen, root_key_owned, try cycloneDxItemSpec(root_component, alloc), alloc);
    const root_ref = if (json_util.getString(root_component, "bom-ref")) |value| value else root_key_owned;
    try ref_map.put(try alloc.dupe(u8, root_ref), try alloc.dupe(u8, root_key_owned));

    if (json_util.getObjectField(root, "components")) |components| {
        if (components != .array) return error.InvalidJson;
        for (components.array.items) |component| {
            if (component != .object) return error.InvalidJson;
            const name = json_util.getString(component, "name") orelse return error.InvalidJson;
            const version = json_util.getString(component, "version") orelse "";
            const key = try ids.partRevisionKey(name, version, alloc);
            defer alloc.free(key);
            try item_specs.upsertItemSpecExplicit(&item_seen, key, try cycloneDxItemSpec(component, alloc), alloc);
            const ref_value = if (json_util.getString(component, "bom-ref")) |value| value else key;
            if (!ref_map.contains(ref_value)) {
                try ref_map.put(try alloc.dupe(u8, ref_value), try alloc.dupe(u8, key));
            }
        }
    }

    var saw_dependencies = false;
    if (json_util.getObjectField(root, "dependencies")) |deps| {
        if (deps != .array) return error.InvalidJson;
        for (deps.array.items) |dep| {
            if (dep != .object) return error.InvalidJson;
            const parent_ref = json_util.getString(dep, "ref") orelse continue;
            const parent_key = ref_map.get(parent_ref) orelse {
                try util.appendWarning(&warnings, "BOM_ORPHAN_CHILD", "Dependency parent was not found in this SBOM", parent_ref, alloc);
                continue;
            };
            const depends_on = json_util.getObjectField(dep, "dependsOn") orelse continue;
            if (depends_on != .array) return error.InvalidJson;
            for (depends_on.array.items) |child_ref_value| {
                if (child_ref_value != .string) return error.InvalidJson;
                const child_key = ref_map.get(child_ref_value.string) orelse {
                    try util.appendWarning(&warnings, "BOM_ORPHAN_CHILD", "Dependency child was not found in this SBOM", child_ref_value.string, alloc);
                    continue;
                };
                saw_dependencies = true;
                try item_specs.appendRelation(&relation_seen, &relations, parent_key, child_key, alloc, &warnings, child_ref_value.string);
            }
        }
    }

    if (!saw_dependencies) {
        var item_it = item_seen.iterator();
        while (item_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, root_key_owned)) continue;
            try item_specs.appendRelation(&relation_seen, &relations, root_key_owned, entry.key_ptr.*, alloc, &warnings, entry.value_ptr.part);
        }
    }

    const occurrences = try item_specs.finalizeOccurrences(item_seen, relations.items, root_key_owned, .cyclonedx, alloc);
    return .{
        .submission = .{
            .full_product_identifier = full_product_identifier,
            .bom_name = try alloc.dupe(u8, bom_name),
            .bom_type = .software,
            .source_format = .cyclonedx,
            .root_key = root_key_owned,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}
