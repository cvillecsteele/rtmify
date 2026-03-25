const std = @import("std");
const types = @import("types.zig");

pub const Allocator = std.mem.Allocator;

pub fn partRevisionKey(part: []const u8, revision: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ part, revision });
}

pub fn splitPartRevisionKey(key: []const u8, alloc: Allocator) !types.PartRevision {
    const idx = std.mem.lastIndexOfScalar(u8, key, '@') orelse return .{
        .part = try alloc.dupe(u8, key),
        .revision = try alloc.dupe(u8, ""),
    };
    return .{
        .part = try alloc.dupe(u8, key[0..idx]),
        .revision = try alloc.dupe(u8, key[idx + 1 ..]),
    };
}

pub fn bomNodeId(full_product_identifier: []const u8, bom_type: types.BomType, bom_name: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "bom://{s}/{s}/{s}", .{ full_product_identifier, bomTypeString(bom_type), bom_name });
}

pub fn bomItemPrefix(full_product_identifier: []const u8, bom_type: types.BomType, bom_name: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "bom-item://{s}/{s}/{s}/", .{ full_product_identifier, bomTypeString(bom_type), bom_name });
}

pub fn bomItemNodeId(
    full_product_identifier: []const u8,
    bom_type: types.BomType,
    bom_name: []const u8,
    part: []const u8,
    revision: []const u8,
    alloc: Allocator,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "bom-item://{s}/{s}/{s}/{s}@{s}", .{
        full_product_identifier,
        bomTypeString(bom_type),
        bom_name,
        part,
        revision,
    });
}

pub fn bomTypeString(value: types.BomType) []const u8 {
    return switch (value) {
        .hardware => "hardware",
        .software => "software",
    };
}

pub fn bomFormatString(value: types.BomFormat) []const u8 {
    return switch (value) {
        .hardware_csv => "hardware_csv",
        .hardware_json => "hardware_json",
        .cyclonedx => "cyclonedx",
        .spdx => "spdx",
        .xlsx => "xlsx",
        .sheets => "sheets",
        .soup_json => "soup_json",
        .soup_xlsx => "soup_xlsx",
    };
}
