const std = @import("std");
const Allocator = std.mem.Allocator;
const store_mod = @import("license_store.zig");
const types = @import("license_types.zig");

const MemoryStoreCtx = struct {
    record: ?types.CacheRecord = null,
};

pub fn create(alloc: Allocator) !store_mod.Store {
    const ctx = try alloc.create(MemoryStoreCtx);
    ctx.* = .{};
    return .{
        .ctx = ctx,
        .vtable = &vtable,
    };
}

fn read(ctx_ptr: *anyopaque, alloc: Allocator) !?types.CacheRecord {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.record) |record| return try record.clone(alloc);
    return null;
}

fn write(ctx_ptr: *anyopaque, alloc: Allocator, record: types.CacheRecord) !void {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.record) |*existing| existing.deinit(alloc);
    ctx.record = try record.clone(alloc);
}

fn clear(ctx_ptr: *anyopaque, alloc: Allocator) !void {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.record) |*existing| {
        existing.deinit(alloc);
        ctx.record = null;
    }
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *MemoryStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.record) |*existing| existing.deinit(alloc);
    alloc.destroy(ctx);
}

const vtable = store_mod.Store.VTable{
    .read = read,
    .write = write,
    .clear = clear,
    .deinit = deinit,
};
