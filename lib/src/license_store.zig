const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("license_types.zig");

pub const Store = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readEnvelope: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!?types.LicenseEnvelope,
        writeEnvelope: *const fn (ctx: *anyopaque, alloc: Allocator, envelope: types.LicenseEnvelope) anyerror!void,
        clearEnvelope: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!void,
        deinit: *const fn (ctx: *anyopaque, alloc: Allocator) void,
    };

    pub fn readEnvelope(self: Store, alloc: Allocator) !?types.LicenseEnvelope {
        return self.vtable.readEnvelope(self.ctx, alloc);
    }

    pub fn writeEnvelope(self: Store, alloc: Allocator, envelope: types.LicenseEnvelope) !void {
        return self.vtable.writeEnvelope(self.ctx, alloc, envelope);
    }

    pub fn clearEnvelope(self: Store, alloc: Allocator) !void {
        return self.vtable.clearEnvelope(self.ctx, alloc);
    }

    pub fn deinit(self: Store, alloc: Allocator) void {
        self.vtable.deinit(self.ctx, alloc);
    }
};
