const std = @import("std");
const Allocator = std.mem.Allocator;
const store_mod = @import("license_store.zig");
const types = @import("license_types.zig");

const MemoryStoreCtx = struct {
    envelope: ?types.LicenseEnvelope = null,
};

pub fn create(alloc: Allocator) !store_mod.Store {
    const ctx = try alloc.create(MemoryStoreCtx);
    ctx.* = .{};
    return .{
        .ctx = ctx,
        .vtable = &vtable,
    };
}

fn readEnvelope(ctx_ptr: *anyopaque, alloc: Allocator) !?types.LicenseEnvelope {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.envelope) |envelope| return try envelope.clone(alloc);
    return null;
}

fn writeEnvelope(ctx_ptr: *anyopaque, alloc: Allocator, envelope: types.LicenseEnvelope) !void {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.envelope) |*existing| existing.deinit(alloc);
    ctx.envelope = try envelope.clone(alloc);
}

fn clearEnvelope(ctx_ptr: *anyopaque, alloc: Allocator) !void {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.envelope) |*existing| {
        existing.deinit(alloc);
        ctx.envelope = null;
    }
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.envelope) |*existing| existing.deinit(alloc);
    alloc.destroy(ctx);
}

const vtable = store_mod.Store.VTable{
    .readEnvelope = readEnvelope,
    .writeEnvelope = writeEnvelope,
    .clearEnvelope = clearEnvelope,
    .deinit = deinit,
};
