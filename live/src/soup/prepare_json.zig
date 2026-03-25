const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("../json_util.zig");
const bom = @import("../bom.zig");
const item_specs = @import("item_specs.zig");
const prepare_common = @import("prepare_common.zig");
const trace_refs = @import("trace_refs.zig");
const types = @import("types.zig");

pub fn parseSoupJson(root: std.json.Value, alloc: Allocator) !types.ParseResult {
    const full_product_identifier = json_util.getString(root, "full_product_identifier") orelse return error.MissingFullProductIdentifier;
    const components = json_util.getObjectField(root, "components") orelse return error.EmptyBomItems;
    if (components != .array) return error.InvalidJson;
    return parseSoupComponentArray(
        components.array.items,
        full_product_identifier,
        json_util.getString(root, "bom_name"),
        .soup_json,
        1,
        alloc,
    );
}

pub fn parseSoupComponentArray(
    components: []const std.json.Value,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    source_format: bom.BomFormat,
    row_base: usize,
    alloc: Allocator,
) !types.ParseResult {
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
    for (components, 0..) |component, idx| {
        rows_received += 1;
        const row_number = row_base + idx;
        if (component != .object) {
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "Each components[] entry must be an object.", alloc);
            continue;
        }
        const component_name = dupRequiredString(component, "component_name", alloc) catch {
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_MISSING_REQUIRED_FIELD", "component_name is required.", alloc);
            continue;
        };
        defer alloc.free(component_name);
        const version = dupRequiredString(component, "version", alloc) catch {
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_MISSING_REQUIRED_FIELD", "version is required.", alloc);
            continue;
        };
        defer alloc.free(version);

        var requirement_ids = trace_refs.parseTraceRefJsonField(component, "requirement_ids", alloc) catch {
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "requirement_ids must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (requirement_ids) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
        const requirement_id = trace_refs.parseTraceRefJsonField(component, "requirement_id", alloc) catch {
            if (requirement_ids) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "requirement_id must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (requirement_id) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
        try item_specs.mergeTraceRefLists(&requirement_ids, requirement_id, alloc);

        var test_ids = trace_refs.parseTraceRefJsonField(component, "test_ids", alloc) catch {
            if (requirement_ids) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "test_ids must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (test_ids) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
        const test_id = trace_refs.parseTraceRefJsonField(component, "test_id", alloc) catch {
            if (requirement_ids) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
            if (test_ids) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
            try prepare_common.appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "test_id must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (test_id) |items_ref| item_specs.freeStringSlice(items_ref, alloc);
        try item_specs.mergeTraceRefLists(&test_ids, test_id, alloc);

        const key = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ component_name, version });
        defer alloc.free(key);
        try item_specs.upsertSoupItemSpec(
            &items,
            key,
            .{
                .component_name = try alloc.dupe(u8, component_name),
                .version = try alloc.dupe(u8, version),
                .supplier = try dupOptionalStringAllowBlank(component, "supplier", alloc),
                .category = try dupOptionalStringAllowBlank(component, "category", alloc),
                .license = try dupOptionalStringAllowBlank(component, "license", alloc),
                .purl = try dupOptionalStringAllowBlank(component, "purl", alloc),
                .safety_class = try dupOptionalStringAllowBlank(component, "safety_class", alloc),
                .known_anomalies = try dupOptionalStringAllowBlank(component, "known_anomalies", alloc),
                .anomaly_evaluation = try dupOptionalStringAllowBlank(component, "anomaly_evaluation", alloc),
                .requirement_ids = requirement_ids,
                .test_ids = test_ids,
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

pub fn dupRequiredString(value: std.json.Value, field_name: []const u8, alloc: Allocator) ![]u8 {
    const raw = json_util.getString(value, field_name) orelse return error.MissingRequiredField;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return error.MissingRequiredField;
    return alloc.dupe(u8, trimmed);
}

pub fn dupOptionalStringAllowBlank(value: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const u8 {
    const field = json_util.getObjectField(value, field_name) orelse return null;
    return switch (field) {
        .null => null,
        .string => try alloc.dupe(u8, std.mem.trim(u8, field.string, " \r\n\t")),
        else => return error.InvalidJson,
    };
}
