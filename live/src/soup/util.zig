const std = @import("std");
const Allocator = std.mem.Allocator;

const bom = @import("../bom.zig");
const xlsx = @import("rtmify").xlsx;
const types = @import("types.zig");

pub fn normalizedBomName(value: ?[]const u8) []const u8 {
    const raw = value orelse return types.default_bom_name;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return types.default_bom_name;
    return trimmed;
}

pub fn findSheetRowsTrimmed(sheets: []const xlsx.SheetData, want: []const u8) ?[]const []const []const u8 {
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, sheet.name, " \r\n\t"), want)) return sheet.rows;
    }
    return null;
}

pub fn bindOptionalFilter(st: anytype, first_idx: usize, value: ?[]const u8) void {
    if (value) |actual| {
        st.bindText(@intCast(first_idx), actual) catch unreachable;
        st.bindText(@intCast(first_idx + 1), actual) catch unreachable;
    } else {
        st.bindNull(@intCast(first_idx)) catch unreachable;
        st.bindNull(@intCast(first_idx + 1)) catch unreachable;
    }
}

pub fn writeTempXlsx(body: []const u8, alloc: Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/rtmify-soup-{d}.xlsx", .{std.time.nanoTimestamp()});
    errdefer alloc.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
    return path;
}

pub fn classifyProductStatus(raw_value: ?[]const u8) enum { active, in_development, superseded, eol, obsolete, unknown } {
    const raw = raw_value orelse return .active;
    const value = std.mem.trim(u8, raw, " \r\n\t");
    if (value.len == 0) return .active;
    if (std.ascii.eqlIgnoreCase(value, "Active")) return .active;
    if (std.ascii.eqlIgnoreCase(value, "In Development") or std.ascii.eqlIgnoreCase(value, "Development")) return .in_development;
    if (std.ascii.eqlIgnoreCase(value, "Superseded")) return .superseded;
    if (std.ascii.eqlIgnoreCase(value, "EOL") or std.ascii.eqlIgnoreCase(value, "End of Life")) return .eol;
    if (std.ascii.eqlIgnoreCase(value, "Obsolete")) return .obsolete;
    return .unknown;
}

pub fn productStatusExcludedFromGapAnalysis(status: @TypeOf(classifyProductStatus(null))) bool {
    return switch (status) {
        .superseded, .eol, .obsolete => true,
        else => false,
    };
}

pub fn bomFormatString(value: bom.BomFormat) []const u8 {
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

const testing = std.testing;

test "normalizedBomName falls back to default for null and blank" {
    try testing.expectEqualStrings(types.default_bom_name, normalizedBomName(null));
    try testing.expectEqualStrings(types.default_bom_name, normalizedBomName("   "));
    try testing.expectEqualStrings("Custom", normalizedBomName(" Custom "));
}

test "classifyProductStatus preserves current mappings" {
    try testing.expectEqual(.active, classifyProductStatus("Active"));
    try testing.expectEqual(.in_development, classifyProductStatus("Development"));
    try testing.expectEqual(.superseded, classifyProductStatus("Superseded"));
    try testing.expectEqual(.eol, classifyProductStatus("End of Life"));
    try testing.expectEqual(.obsolete, classifyProductStatus("Obsolete"));
    try testing.expectEqual(.unknown, classifyProductStatus("Retired?"));
}

test "productStatusExcludedFromGapAnalysis excludes only superseded eol obsolete" {
    try testing.expect(!productStatusExcludedFromGapAnalysis(.active));
    try testing.expect(!productStatusExcludedFromGapAnalysis(.in_development));
    try testing.expect(productStatusExcludedFromGapAnalysis(.superseded));
    try testing.expect(productStatusExcludedFromGapAnalysis(.eol));
    try testing.expect(productStatusExcludedFromGapAnalysis(.obsolete));
    try testing.expect(!productStatusExcludedFromGapAnalysis(.unknown));
}
