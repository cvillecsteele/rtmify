const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");

pub const DispatchCtx = struct {
    db: *graph_live.GraphDb,
    inbox_dir: []const u8,
    alloc: Allocator,
};
