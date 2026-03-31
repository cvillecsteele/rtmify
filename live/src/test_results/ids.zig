const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn executionNodeId(execution_id: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "execution://{s}", .{execution_id});
}

pub fn resultNodeId(result_id: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "test-result://{s}", .{result_id});
}

pub fn productNodeId(full_product_identifier: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "product://{s}", .{full_product_identifier});
}
