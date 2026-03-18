const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const writeback = @import("../writeback.zig");
const support = @import("support.zig");

test "colLetter single" {
    const a = writeback.colLetter(0);
    try testing.expectEqual(@as(u8, 'A'), a[0]);
    const z = writeback.colLetter(25);
    try testing.expectEqual(@as(u8, 'Z'), z[0]);
}

test "colLetter double" {
    const aa = writeback.colLetter(26);
    try testing.expectEqual(@as(u8, 'A'), aa[0]);
    try testing.expectEqual(@as(u8, 'A'), aa[1]);
    const ab = writeback.colLetter(27);
    try testing.expectEqual(@as(u8, 'A'), ab[0]);
    try testing.expectEqual(@as(u8, 'B'), ab[1]);
}

test "findCol" {
    var h = [_][]const u8{ "ID", "Statement", "Status" };
    try testing.expectEqual(@as(?usize, 0), writeback.findCol(&h, "ID"));
    try testing.expectEqual(@as(?usize, 2), writeback.findCol(&h, "Status"));
    try testing.expectEqual(@as(?usize, null), writeback.findCol(&h, "Missing"));
}

test "appendProductWriteback writes empty tab advisory to F2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
    };

    var value_updates: std.ArrayList(internal.ValueUpdate) = .empty;
    defer support.freeValueUpdates(&value_updates, alloc);
    var row_formats: std.ArrayList(internal.RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    try writeback.appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    try testing.expectEqualStrings("NO_PRODUCT_DECLARED", support.findSingleValueUpdate(value_updates.items, "Product!F2").?);
    try testing.expectEqual(@as(usize, 0), row_formats.items.len);
}

test "appendProductWriteback sets product row statuses and fills" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
        &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Active", "" },
        &.{ "ASM-1000", "Rev D", "", "Sensor Controller Unit Rev D", "Development", "" },
        &.{ "ASM-1000", "Rev E", "ASM-1000 Rev C", "Sensor Controller Unit Rev E", "Development", "" },
    };

    var value_updates: std.ArrayList(internal.ValueUpdate) = .empty;
    defer support.freeValueUpdates(&value_updates, alloc);
    var row_formats: std.ArrayList(internal.RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    try writeback.appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    try testing.expectEqualStrings("OK", support.findSingleValueUpdate(value_updates.items, "Product!F2").?);
    try testing.expectEqualStrings("MISSING_FULL_IDENTIFIER", support.findSingleValueUpdate(value_updates.items, "Product!F3").?);
    try testing.expectEqualStrings("DUPLICATE_FULL_IDENTIFIER", support.findSingleValueUpdate(value_updates.items, "Product!F4").?);
    try testing.expectEqual(@as(usize, 3), row_formats.items.len);
    try testing.expectEqualStrings("#B6E1CD", row_formats.items[0].fill_hex);
    try testing.expectEqualStrings("#FCE8B2", row_formats.items[1].fill_hex);
    try testing.expectEqualStrings("#F4C7C3", row_formats.items[2].fill_hex);
}

test "appendProductWriteback recreates missing RTMify Status header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status" },
        &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Active" },
    };

    var value_updates: std.ArrayList(internal.ValueUpdate) = .empty;
    defer support.freeValueUpdates(&value_updates, alloc);
    var row_formats: std.ArrayList(internal.RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    try writeback.appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    try testing.expectEqualStrings("RTMify Status", support.findSingleValueUpdate(value_updates.items, "Product!F1").?);
    try testing.expectEqualStrings("OK", support.findSingleValueUpdate(value_updates.items, "Product!F2").?);
}

test "appendProductWriteback flags unknown product status as warning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
        &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Shipping Now", "" },
    };

    var value_updates: std.ArrayList(internal.ValueUpdate) = .empty;
    defer support.freeValueUpdates(&value_updates, alloc);
    var row_formats: std.ArrayList(internal.RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    try writeback.appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    try testing.expectEqualStrings("PRODUCT_UNKNOWN_STATUS", support.findSingleValueUpdate(value_updates.items, "Product!F2").?);
    try testing.expectEqual(@as(usize, 1), row_formats.items.len);
    try testing.expectEqualStrings("#FCE8B2", row_formats.items[0].fill_hex);
}
