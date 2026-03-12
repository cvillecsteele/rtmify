const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const store_mod = @import("license_store.zig");
const types = @import("license_types.zig");

pub const Config = struct {
    dir: ?[]const u8 = null,
};

const FsStoreCtx = struct {
    dir: ?[]const u8,
};

pub fn create(alloc: Allocator, cfg: Config) !store_mod.Store {
    const ctx = try alloc.create(FsStoreCtx);
    ctx.* = .{
        .dir = if (cfg.dir) |value| try alloc.dupe(u8, value) else null,
    };
    return .{
        .ctx = ctx,
        .vtable = &vtable,
    };
}

fn cacheFilePath(alloc: Allocator, dir_override: ?[]const u8) ![]u8 {
    const dir = if (dir_override) |d| try alloc.dupe(u8, d) else blk: {
        const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
        const home = try std.process.getEnvVarOwned(alloc, home_var);
        defer alloc.free(home);
        break :blk try std.fs.path.join(alloc, &.{ home, ".rtmify" });
    };
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "license.json" });
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}

const LegacyRecord = struct {
    license_key: []const u8,
    activated_at: i64,
    fingerprint: []const u8,
    expires_at: ?i64 = null,
    last_validated_at: ?i64 = null,
};

fn parseRecord(alloc: Allocator, data: []const u8) !types.CacheRecord {
    if (std.json.parseFromSlice(types.CacheRecord, alloc, data, .{
        .ignore_unknown_fields = true,
    })) |parsed_v2| {
        defer parsed_v2.deinit();
        return .{
            .schema_version = parsed_v2.value.schema_version,
            .provider_id = try alloc.dupe(u8, parsed_v2.value.provider_id),
            .license_key = try alloc.dupe(u8, parsed_v2.value.license_key),
            .fingerprint = try alloc.dupe(u8, parsed_v2.value.fingerprint),
            .activated_at = parsed_v2.value.activated_at,
            .expires_at = parsed_v2.value.expires_at,
            .last_validated_at = parsed_v2.value.last_validated_at,
            .provider_instance_id = if (parsed_v2.value.provider_instance_id) |value| try alloc.dupe(u8, value) else null,
            .provider_payload_json = try alloc.dupe(u8, parsed_v2.value.provider_payload_json),
        };
    } else |_| {
        var legacy = try std.json.parseFromSlice(LegacyRecord, alloc, data, .{
            .ignore_unknown_fields = true,
        });
        defer legacy.deinit();
        return .{
            .schema_version = 2,
            .provider_id = try alloc.dupe(u8, "lemonsqueezy"),
            .license_key = try alloc.dupe(u8, legacy.value.license_key),
            .fingerprint = try alloc.dupe(u8, legacy.value.fingerprint),
            .activated_at = legacy.value.activated_at,
            .expires_at = legacy.value.expires_at,
            .last_validated_at = legacy.value.last_validated_at,
            .provider_instance_id = null,
            .provider_payload_json = try alloc.dupe(u8, "{}"),
        };
    }
}

fn read(ctx_ptr: *anyopaque, alloc: Allocator) !?types.CacheRecord {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try cacheFilePath(alloc, ctx.dir);
    defer alloc.free(path);

    const data = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(data);

    return parseRecord(alloc, data) catch error.InvalidCache;
}

fn write(ctx_ptr: *anyopaque, alloc: Allocator, record: types.CacheRecord) !void {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try cacheFilePath(alloc, ctx.dir);
    defer alloc.free(path);
    try ensureParentDir(path);
    const json_bytes = try std.json.Stringify.valueAlloc(alloc, record, .{});
    defer alloc.free(json_bytes);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_bytes });
}

fn clear(ctx_ptr: *anyopaque, alloc: Allocator) !void {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    const path = try cacheFilePath(alloc, ctx.dir);
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *FsStoreCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.dir) |value| alloc.free(value);
    alloc.destroy(ctx);
}

const vtable = store_mod.Store.VTable{
    .read = read,
    .write = write,
    .clear = clear,
    .deinit = deinit,
};
