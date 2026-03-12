const std = @import("std");
const Allocator = std.mem.Allocator;

const secure_store = @import("secure_store.zig");

const c = @cImport({
    @cInclude("Security/Security.h");
});

const keychain_service = "io.rtmify.live.provider-credentials";

const KeychainStore = struct {};

pub fn init(alloc: Allocator) !secure_store.Store {
    const ctx = try alloc.create(KeychainStore);
    ctx.* = .{};
    return .{
        .ctx = ctx,
        .vtable = &vtable,
        .backend = .macos_keychain,
    };
}

fn put(ctx: *anyopaque, alloc: Allocator, ref: []const u8, secret_json: []const u8) !void {
    _ = alloc;
    const store_ctx: *KeychainStore = @ptrCast(@alignCast(ctx));
    _ = store_ctx;

    var existing_item: c.SecKeychainItemRef = null;
    var password_len: u32 = 0;
    var password_data: ?*anyopaque = null;
    const find_status = c.SecKeychainFindGenericPassword(
        null,
        @intCast(keychain_service.len),
        keychain_service.ptr,
        @intCast(ref.len),
        ref.ptr,
        &password_len,
        &password_data,
        &existing_item,
    );
    if (password_data) |value| {
        _ = c.SecKeychainItemFreeContent(null, value);
    }

    if (find_status == c.errSecSuccess) {
        defer if (existing_item != null) c.CFRelease(existing_item);
        const update_status = c.SecKeychainItemModifyAttributesAndData(existing_item, null, @intCast(secret_json.len), secret_json.ptr);
        if (update_status != c.errSecSuccess) return error.BackendFailure;
        return;
    }
    if (find_status != c.errSecItemNotFound) return error.BackendFailure;

    var created_item: c.SecKeychainItemRef = null;
    defer if (created_item != null) c.CFRelease(created_item);
    const add_status = c.SecKeychainAddGenericPassword(
        null,
        @intCast(keychain_service.len),
        keychain_service.ptr,
        @intCast(ref.len),
        ref.ptr,
        @intCast(secret_json.len),
        secret_json.ptr,
        &created_item,
    );
    if (add_status != c.errSecSuccess) return error.BackendFailure;
}

fn get(ctx: *anyopaque, alloc: Allocator, ref: []const u8) secure_store.LoadError![]u8 {
    const store_ctx: *KeychainStore = @ptrCast(@alignCast(ctx));
    _ = store_ctx;

    var password_len: u32 = 0;
    var password_data: ?*anyopaque = null;
    var item: c.SecKeychainItemRef = null;
    defer if (item != null) c.CFRelease(item);
    const status = c.SecKeychainFindGenericPassword(
        null,
        @intCast(keychain_service.len),
        keychain_service.ptr,
        @intCast(ref.len),
        ref.ptr,
        &password_len,
        &password_data,
        &item,
    );
    switch (status) {
        c.errSecSuccess => {},
        c.errSecItemNotFound => return error.NotFound,
        c.errSecAuthFailed => return error.AccessDenied,
        else => return error.BackendFailure,
    }
    defer {
        if (password_data) |value| _ = c.SecKeychainItemFreeContent(null, value);
    }
    const bytes: [*]const u8 = @ptrCast(password_data.?);
    return alloc.dupe(u8, bytes[0..password_len]) catch error.BackendFailure;
}

fn delete(ctx: *anyopaque, alloc: Allocator, ref: []const u8) !void {
    _ = alloc;
    const store_ctx: *KeychainStore = @ptrCast(@alignCast(ctx));
    _ = store_ctx;

    var item: c.SecKeychainItemRef = null;
    const status = c.SecKeychainFindGenericPassword(
        null,
        @intCast(keychain_service.len),
        keychain_service.ptr,
        @intCast(ref.len),
        ref.ptr,
        null,
        null,
        &item,
    );
    switch (status) {
        c.errSecSuccess => {
            defer if (item != null) c.CFRelease(item);
            const delete_status = c.SecKeychainItemDelete(item);
            if (delete_status != c.errSecSuccess) return error.BackendFailure;
        },
        c.errSecItemNotFound => return,
        else => return error.BackendFailure,
    }
}

fn deinit(ctx: *anyopaque, alloc: Allocator) void {
    const store_ctx: *KeychainStore = @ptrCast(@alignCast(ctx));
    alloc.destroy(store_ctx);
}

const vtable = secure_store.Store.VTable{
    .put = put,
    .get = get,
    .delete = delete,
    .deinit = deinit,
};
