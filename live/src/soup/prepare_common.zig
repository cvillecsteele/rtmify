const std = @import("std");
const Allocator = std.mem.Allocator;

const bom = @import("../bom.zig");
const item_specs = @import("item_specs.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn soupSubmissionFromItems(
    items: std.StringHashMap(item_specs.SoupItemSpec),
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    source_format: bom.BomFormat,
    alloc: Allocator,
) !bom.BomSubmission {
    var occurrences: std.ArrayList(bom.BomOccurrenceInput) = .empty;
    errdefer {
        for (occurrences.items) |*occurrence| occurrence.deinit(alloc);
        occurrences.deinit(alloc);
    }

    var it = items.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        try occurrences.append(alloc, .{
            .parent_key = null,
            .child_part = try alloc.dupe(u8, item.component_name),
            .child_revision = try alloc.dupe(u8, item.version),
            .description = null,
            .category = if (item.category) |value| try alloc.dupe(u8, value) else null,
            .requirement_ids = if (item.requirement_ids) |values| try item_specs.dupStringSlice(values, alloc) else null,
            .test_ids = if (item.test_ids) |values| try item_specs.dupStringSlice(values, alloc) else null,
            .quantity = null,
            .ref_designator = null,
            .supplier = if (item.supplier) |value| try alloc.dupe(u8, value) else null,
            .purl = if (item.purl) |value| try alloc.dupe(u8, value) else null,
            .license = if (item.license) |value| try alloc.dupe(u8, value) else null,
            .hashes_json = null,
            .safety_class = if (item.safety_class) |value| try alloc.dupe(u8, value) else null,
            .known_anomalies = if (item.known_anomalies) |value| try alloc.dupe(u8, value) else null,
            .anomaly_evaluation = if (item.anomaly_evaluation) |value| try alloc.dupe(u8, value) else null,
        });
    }

    return .{
        .full_product_identifier = try alloc.dupe(u8, full_product_identifier),
        .bom_name = try alloc.dupe(u8, util.normalizedBomName(bom_name_override)),
        .bom_type = .software,
        .source_format = source_format,
        .root_key = null,
        .occurrences = try occurrences.toOwnedSlice(alloc),
    };
}

pub fn appendRowError(row_errors: *std.ArrayList(types.SoupRowError), row: usize, code: []const u8, message: []const u8, alloc: Allocator) !void {
    try row_errors.append(alloc, .{
        .row = row,
        .code = try alloc.dupe(u8, code),
        .message = try alloc.dupe(u8, message),
    });
}

pub fn appendWarning(
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
