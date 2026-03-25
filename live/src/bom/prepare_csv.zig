const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const ids = @import("ids.zig");
const trace_refs = @import("trace_refs.zig");
const item_specs = @import("item_specs.zig");

pub const Allocator = std.mem.Allocator;

pub fn prepareHardwareCsv(body: []const u8, alloc: Allocator) (types.BomError || error{OutOfMemory})!types.PreparedBom {
    var warnings: std.ArrayList(types.BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| {
            for (row) |cell| alloc.free(cell);
            alloc.free(row);
        }
        rows.deinit(alloc);
    }

    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.trim(u8, line, " ").len == 0) continue;
        try rows.append(alloc, try util.parseCsvLine(line, alloc));
    }
    if (rows.items.len < 2) return error.EmptyBomItems;

    const header = rows.items[0];
    const bom_name_col = util.resolveCol(header, "bom_name") orelse return error.MissingRequiredField;
    const full_identifier_col = util.resolveCol(header, "full_identifier") orelse util.resolveCol(header, "full_product_identifier") orelse return error.MissingRequiredField;
    const parent_part_col = util.resolveCol(header, "parent_part") orelse return error.MissingRequiredField;
    const parent_revision_col = util.resolveCol(header, "parent_revision");
    const child_part_col = util.resolveCol(header, "child_part") orelse return error.MissingRequiredField;
    const child_revision_col = util.resolveCol(header, "child_revision");
    const quantity_col = util.resolveCol(header, "quantity") orelse return error.MissingRequiredField;
    const ref_designator_col = util.resolveCol(header, "ref_designator");
    const description_col = util.resolveCol(header, "description");
    const supplier_col = util.resolveCol(header, "supplier");
    const category_col = util.resolveCol(header, "category");
    const requirement_ids_col = util.resolveCol(header, "requirement_ids");
    const requirement_id_col = util.resolveCol(header, "requirement_id");
    const test_ids_col = util.resolveCol(header, "test_ids");
    const test_id_col = util.resolveCol(header, "test_id");

    var relation_seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = relation_seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        relation_seen.deinit();
    }

    var item_seen = std.StringHashMap(types.ItemSpec).init(alloc);
    defer item_specs.deinitItemMap(&item_seen, alloc);

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

    var bom_name_value: ?[]const u8 = null;
    errdefer if (bom_name_value) |value| alloc.free(value);
    var full_product_identifier_value: ?[]const u8 = null;
    errdefer if (full_product_identifier_value) |value| alloc.free(value);

    for (rows.items[1..]) |row| {
        const bom_name = try util.cellAt(row, bom_name_col, alloc);
        defer alloc.free(bom_name);
        const full_identifier = try util.cellAt(row, full_identifier_col, alloc);
        defer alloc.free(full_identifier);
        const parent_part = try util.cellAt(row, parent_part_col, alloc);
        defer alloc.free(parent_part);
        const parent_revision = try util.defaultCellAt(row, parent_revision_col, "-", alloc);
        defer alloc.free(parent_revision);
        const child_part = try util.cellAt(row, child_part_col, alloc);
        defer alloc.free(child_part);
        const child_revision = try util.defaultCellAt(row, child_revision_col, "-", alloc);
        defer alloc.free(child_revision);
        const quantity = try util.cellAt(row, quantity_col, alloc);
        defer alloc.free(quantity);
        if (bom_name.len == 0) return error.MissingBomName;
        if (full_identifier.len == 0) return error.MissingFullProductIdentifier;
        if (parent_part.len == 0 or child_part.len == 0 or quantity.len == 0) {
            return error.MissingRequiredField;
        }

        if (bom_name_value == null) bom_name_value = try alloc.dupe(u8, bom_name) else if (!std.mem.eql(u8, bom_name_value.?, bom_name)) return error.InvalidCsv;
        if (full_product_identifier_value == null) full_product_identifier_value = try alloc.dupe(u8, full_identifier) else if (!std.mem.eql(u8, full_product_identifier_value.?, full_identifier)) return error.InvalidCsv;

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
                .description = try util.optionalCellAt(row, description_col, alloc),
                .category = try util.optionalCellAt(row, category_col, alloc),
                .supplier = try util.optionalCellAt(row, supplier_col, alloc),
                .requirement_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    if (requirement_ids_col) |idx| {
                        const parsed = try trace_refs.parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| util.freeStringSlice(items, alloc);
                        try trace_refs.mergeTraceRefLists(&refs, parsed, alloc);
                    }
                    if (requirement_id_col) |idx| {
                        const parsed = try trace_refs.parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| util.freeStringSlice(items, alloc);
                        try trace_refs.mergeTraceRefLists(&refs, parsed, alloc);
                    }
                    break :blk refs;
                },
                .test_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    if (test_ids_col) |idx| {
                        const parsed = try trace_refs.parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| util.freeStringSlice(items, alloc);
                        try trace_refs.mergeTraceRefLists(&refs, parsed, alloc);
                    }
                    if (test_id_col) |idx| {
                        const parsed = try trace_refs.parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| util.freeStringSlice(items, alloc);
                        try trace_refs.mergeTraceRefLists(&refs, parsed, alloc);
                    }
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
            .ref_designator = try util.optionalCellAt(row, ref_designator_col, alloc),
            .supplier = try util.optionalCellAt(row, supplier_col, alloc),
        });
    }

    const occurrences = try item_specs.finalizeOccurrences(item_seen, relations.items, null, .hardware_csv, alloc);
    return .{
        .submission = .{
            .full_product_identifier = full_product_identifier_value.?,
            .bom_name = bom_name_value.?,
            .bom_type = .hardware,
            .source_format = .hardware_csv,
            .root_key = null,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}
