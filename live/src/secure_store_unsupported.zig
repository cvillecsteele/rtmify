const std = @import("std");
const Allocator = std.mem.Allocator;

const secure_store = @import("secure_store.zig");

const UnsupportedStore = struct {};

pub fn init(alloc: Allocator) !secure_store.Store {
    const ctx = try alloc.create(UnsupportedStore);
    ctx.* = .{};
    return .{
        .ctx = ctx,
        .vtable = &vtable,
        .backend = .unsupported,
    };
}

fn put(ctx: *anyopaque, alloc: Allocator, ref: []const u8, secret_json: []const u8) !void {
    _ = ctx;
    _ = alloc;
    _ = ref;
    _ = secret_json;
    return error.Unsupported;
}

fn get(ctx: *anyopaque, alloc: Allocator, ref: []const u8) secure_store.LoadError![]u8 {
    _ = ctx;
    _ = alloc;
    _ = ref;
    return error.Unsupported;
}

fn delete(ctx: *anyopaque, alloc: Allocator, ref: []const u8) !void {
    _ = ctx;
    _ = alloc;
    _ = ref;
    return error.Unsupported;
}

fn deinit(ctx: *anyopaque, alloc: Allocator) void {
    const store_ctx: *UnsupportedStore = @ptrCast(@alignCast(ctx));
    alloc.destroy(store_ctx);
}

const vtable = secure_store.Store.VTable{
    .put = put,
    .get = get,
    .delete = delete,
    .deinit = deinit,
};

const testing = std.testing;

test "unsupported backend rejects reads and writes" {
    var store = try init(testing.allocator);
    defer store.deinit(testing.allocator);

    try testing.expectError(error.Unsupported, store.put(testing.allocator, "cred_x", "{}"));
    try testing.expectError(error.Unsupported, store.get(testing.allocator, "cred_x"));
}
