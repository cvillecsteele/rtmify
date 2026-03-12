const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const secure_store = @import("secure_store.zig");

const c = @cImport({
    @cInclude("windows.h");
    @cInclude("dpapi.h");
});

const WindowsStore = struct {
    root_dir: []u8,
};

pub fn init(alloc: Allocator) !secure_store.Store {
    const local_app_data = try std.process.getEnvVarOwned(alloc, "LOCALAPPDATA");
    errdefer alloc.free(local_app_data);
    const root_dir = try std.fs.path.join(alloc, &.{ local_app_data, "RTMify", "secrets" });
    alloc.free(local_app_data);
    errdefer alloc.free(root_dir);
    try std.fs.cwd().makePath(root_dir);

    const ctx = try alloc.create(WindowsStore);
    ctx.* = .{ .root_dir = root_dir };
    return .{
        .ctx = ctx,
        .vtable = &vtable,
        .backend = .windows_dpapi,
    };
}

fn put(ctx: *anyopaque, alloc: Allocator, ref: []const u8, secret_json: []const u8) !void {
    const store_ctx: *WindowsStore = @ptrCast(@alignCast(ctx));
    const path = try secretPath(store_ctx, alloc, ref);
    defer alloc.free(path);

    var input = blobFromSlice(secret_json);
    var output: c.DATA_BLOB = undefined;
    if (c.CryptProtectData(&input, null, null, null, null, 0, &output) == 0) return error.BackendFailure;
    defer _ = c.LocalFree(output.pbData);

    const bytes: [*]const u8 = @ptrCast(output.pbData);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes[0..output.cbData] });
}

fn get(ctx: *anyopaque, alloc: Allocator, ref: []const u8) secure_store.LoadError![]u8 {
    const store_ctx: *WindowsStore = @ptrCast(@alignCast(ctx));
    const path = secretPath(store_ctx, alloc, ref) catch return error.BackendFailure;
    defer alloc.free(path);

    const ciphertext = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return error.BackendFailure,
    };
    defer alloc.free(ciphertext);

    var input = blobFromSlice(ciphertext);
    var output: c.DATA_BLOB = undefined;
    if (c.CryptUnprotectData(&input, null, null, null, null, 0, &output) == 0) return error.BackendFailure;
    defer _ = c.LocalFree(output.pbData);

    const bytes: [*]const u8 = @ptrCast(output.pbData);
    return alloc.dupe(u8, bytes[0..output.cbData]) catch error.BackendFailure;
}

fn delete(ctx: *anyopaque, alloc: Allocator, ref: []const u8) !void {
    const store_ctx: *WindowsStore = @ptrCast(@alignCast(ctx));
    const path = try secretPath(store_ctx, alloc, ref);
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deinit(ctx: *anyopaque, alloc: Allocator) void {
    const store_ctx: *WindowsStore = @ptrCast(@alignCast(ctx));
    alloc.free(store_ctx.root_dir);
    alloc.destroy(store_ctx);
}

fn secretPath(store_ctx: *WindowsStore, alloc: Allocator, ref: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(alloc, "{s}.bin", .{ref});
    defer alloc.free(file_name);
    return std.fs.path.join(alloc, &.{ store_ctx.root_dir, file_name });
}

fn blobFromSlice(bytes: []const u8) c.DATA_BLOB {
    return .{
        .cbData = @intCast(bytes.len),
        .pbData = @constCast(bytes.ptr),
    };
}

const vtable = secure_store.Store.VTable{
    .put = put,
    .get = get,
    .delete = delete,
    .deinit = deinit,
};

const testing = std.testing;

test "windows backend round trips encrypted blob" {
    if (builtin.target.os.tag != .windows) return error.SkipZigTest;

    var store = try init(testing.allocator);
    defer store.deinit(testing.allocator);

    try store.put(testing.allocator, "cred_win", "{\"secret\":\"value\"}");
    const loaded = try store.get(testing.allocator, "cred_win");
    defer testing.allocator.free(loaded);

    try testing.expectEqualStrings("{\"secret\":\"value\"}", loaded);
}
