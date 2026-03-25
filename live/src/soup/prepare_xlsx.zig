const std = @import("std");
const Allocator = std.mem.Allocator;

const bom = @import("../bom.zig");
const item_specs = @import("item_specs.zig");
const prepare_common = @import("prepare_common.zig");
const trace_refs = @import("trace_refs.zig");
const types = @import("types.zig");

pub fn parseSoupRows(
    rows: []const []const []const u8,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    source_format: bom.BomFormat,
    alloc: Allocator,
) !types.ParseResult {
    if (rows.len < 1) return error.EmptyBomItems;
    const header = rows[0];
    const name_col = resolveCol(header, "component_name") orelse return error.MissingRequiredField;
    const version_col = resolveCol(header, "version") orelse return error.MissingRequiredField;
    const supplier_col = resolveCol(header, "supplier");
    const category_col = resolveCol(header, "category");
    const license_col = resolveCol(header, "license");
    const purl_col = resolveCol(header, "purl");
    const safety_class_col = resolveCol(header, "safety_class");
    const anomalies_col = resolveCol(header, "known_anomalies");
    const evaluation_col = resolveCol(header, "anomaly_evaluation");
    const requirement_ids_col = resolveCol(header, "requirement_ids");
    const test_ids_col = resolveCol(header, "test_ids");

    var items = std.StringHashMap(item_specs.SoupItemSpec).init(alloc);
    defer item_specs.deinitSoupItemMap(&items, alloc);
    var warnings: std.ArrayList(bom.BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var row_errors: std.ArrayList(types.SoupRowError) = .empty;
    errdefer {
        for (row_errors.items) |*row_error| row_error.deinit(alloc);
        row_errors.deinit(alloc);
    }

    var rows_received: usize = 0;
    var rows_ingested: usize = 0;
    for (rows[1..], 0..) |row, idx| {
        if (rowIsBlank(row)) continue;
        rows_received += 1;
        const row_number = idx + 2;
        const component_name = try cellAt(row, name_col, alloc);
        defer alloc.free(component_name);
        const version = try cellAt(row, version_col, alloc);
        defer alloc.free(version);
        if (component_name.len == 0 or version.len == 0) {
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_MISSING_REQUIRED_FIELD", "component_name and version are required.", alloc);
            continue;
        }

        const key = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ component_name, version });
        defer alloc.free(key);
        try item_specs.upsertSoupItemSpec(
            &items,
            key,
            .{
                .component_name = try alloc.dupe(u8, component_name),
                .version = try alloc.dupe(u8, version),
                .supplier = try optionalCellAtAllowBlank(row, supplier_col, alloc),
                .category = try optionalCellAtAllowBlank(row, category_col, alloc),
                .license = try optionalCellAtAllowBlank(row, license_col, alloc),
                .purl = try optionalCellAtAllowBlank(row, purl_col, alloc),
                .safety_class = try optionalCellAtAllowBlank(row, safety_class_col, alloc),
                .known_anomalies = try optionalCellAtAllowBlank(row, anomalies_col, alloc),
                .anomaly_evaluation = try optionalCellAtAllowBlank(row, evaluation_col, alloc),
                .requirement_ids = if (requirement_ids_col) |col| try trace_refs.parseTraceRefCell(if (col < row.len) row[col] else "", alloc) else null,
                .test_ids = if (test_ids_col) |col| try trace_refs.parseTraceRefCell(if (col < row.len) row[col] else "", alloc) else null,
            },
            alloc,
        );
        rows_ingested += 1;
    }

    if (rows_ingested == 0) return error.EmptyBomItems;
    try item_specs.appendSoupItemWarnings(&warnings, &items, alloc);
    const submission = try prepare_common.soupSubmissionFromItems(items, full_product_identifier, bom_name_override, source_format, alloc);
    return .{
        .submission = submission,
        .warnings = warnings,
        .row_errors = row_errors,
        .rows_received = rows_received,
        .rows_ingested = rows_ingested,
    };
}

pub fn resolveCol(header: []const []const u8, want: []const u8) ?usize {
    for (header, 0..) |cell, idx| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, cell, " \r\n\t"), want)) return idx;
    }
    return null;
}

pub fn rowIsBlank(row: []const []const u8) bool {
    for (row) |cell| {
        if (std.mem.trim(u8, cell, " \r\n\t").len != 0) return false;
    }
    return true;
}

pub fn cellAt(row: []const []const u8, idx: usize, alloc: Allocator) ![]u8 {
    if (idx >= row.len) return alloc.dupe(u8, "");
    return alloc.dupe(u8, std.mem.trim(u8, row[idx], " \r\n\t"));
}

pub fn optionalCellAtAllowBlank(row: []const []const u8, idx: ?usize, alloc: Allocator) !?[]const u8 {
    if (idx == null or idx.? >= row.len) return null;
    return @as([]const u8, try alloc.dupe(u8, std.mem.trim(u8, row[idx.?], " \r\n\t")));
}
