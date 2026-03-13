const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const store_mod = @import("license_store.zig");
const types = @import("license_types.zig");
const license_file = @import("license_file.zig");

pub const Config = struct {
    path: ?[]const u8 = null,
};

const FsStoreCtx = struct {
    path: ?[]const u8,
};

pub fn create(alloc: Allocator, cfg: Config) !store_mod.Store {
    const ctx = try alloc.create(FsStoreCtx);
    ctx.* = .{
        .path = if (cfg.path) |path| try alloc.dupe(u8, path) else null,
    };
    return .{
        .ctx = ctx,
        .vtable = &vtable,
    };
}

pub fn defaultLicensePath(alloc: Allocator) ![]u8 {
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = try std.process.getEnvVarOwned(alloc, home_var);
    defer alloc.free(home);
    const dir = try std.fs.path.join(alloc, &.{ home, ".rtmify" });
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "license.json" });
}

fn storePath(alloc: Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| return try alloc.dupe(u8, path);
    if (std.process.getEnvVarOwned(alloc, "RTMIFY_LICENSE")) |env_path| {
        return env_path;
    } else |_| {}
    return try defaultLicensePath(alloc);
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}

fn readEnvelope(ctx_ptr: *anyopaque, alloc: Allocator) !?types.LicenseEnvelope {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try storePath(alloc, ctx.path);
    defer alloc.free(path);
    const data = std.fs.cwd().readFileAlloc(alloc, path, 128 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(data);
    return license_file.parseEnvelope(alloc, data) catch error.InvalidLicenseFile;
}

fn writeEnvelope(ctx_ptr: *anyopaque, alloc: Allocator, envelope: types.LicenseEnvelope) !void {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try storePath(alloc, ctx.path);
    defer alloc.free(path);
    try ensureParentDir(path);
    const json_bytes = try license_file.envelopeJsonAlloc(alloc, envelope);
    defer alloc.free(json_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_bytes });
}

fn clearEnvelope(ctx_ptr: *anyopaque, alloc: Allocator) !void {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try storePath(alloc, ctx.path);
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.path) |path| alloc.free(path);
    alloc.destroy(ctx);
}

const vtable = store_mod.Store.VTable{
    .readEnvelope = readEnvelope,
    .writeEnvelope = writeEnvelope,
    .clearEnvelope = clearEnvelope,
    .deinit = deinit,
};
