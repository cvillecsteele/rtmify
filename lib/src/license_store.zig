const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("license_types.zig");

pub const Store = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!?types.CacheRecord,
        write: *const fn (ctx: *anyopaque, alloc: Allocator, record: types.CacheRecord) anyerror!void,
        clear: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!void,
        deinit: *const fn (ctx: *anyopaque, alloc: Allocator) void,
    };

    pub fn read(self: Store, alloc: Allocator) !?types.CacheRecord {
        return self.vtable.read(self.ctx, alloc);
    }

    pub fn write(self: Store, alloc: Allocator, record: types.CacheRecord) !void {
        return self.vtable.write(self.ctx, alloc, record);
    }

    pub fn clear(self: Store, alloc: Allocator) !void {
        return self.vtable.clear(self.ctx, alloc);
    }

    pub fn deinit(self: Store, alloc: Allocator) void {
        self.vtable.deinit(self.ctx, alloc);
    }
};

