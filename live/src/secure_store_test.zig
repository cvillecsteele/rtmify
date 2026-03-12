const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("json_util.zig");
const secure_store = @import("secure_store.zig");

const TestStore = struct {
    map: std.StringHashMap([]u8),
    file_path: ?[]u8,
};

pub fn init(alloc: Allocator, file_path: ?[]const u8) !secure_store.Store {
    const ctx = try alloc.create(TestStore);
    ctx.* = .{
        .map = std.StringHashMap([]u8).init(alloc),
        .file_path = if (file_path) |value| try alloc.dupe(u8, value) else null,
    };
    if (ctx.file_path) |_| try loadFromDisk(ctx, alloc);
    return .{
        .ctx = ctx,
        .vtable = &vtable,
        .backend = .test_memory,
    };
}

pub fn initFromEnv(alloc: Allocator) !secure_store.Store {
    const file_path = std.process.getEnvVarOwned(alloc, "RTMIFY_SECURE_STORE_TEST_FILE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (file_path) |value| alloc.free(value);
    return init(alloc, file_path);
}

fn put(ctx: *anyopaque, alloc: Allocator, ref: []const u8, secret_json: []const u8) !void {
    const store_ctx: *TestStore = @ptrCast(@alignCast(ctx));
    const gop = try store_ctx.map.getOrPut(ref);
    if (gop.found_existing) {
        alloc.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try alloc.dupe(u8, ref);
    }
    gop.value_ptr.* = try alloc.dupe(u8, secret_json);
    try saveToDisk(store_ctx, alloc);
}

fn get(ctx: *anyopaque, alloc: Allocator, ref: []const u8) secure_store.LoadError![]u8 {
    const store_ctx: *TestStore = @ptrCast(@alignCast(ctx));
    const value = store_ctx.map.get(ref) orelse return error.NotFound;
    return alloc.dupe(u8, value) catch return error.BackendFailure;
}

fn delete(ctx: *anyopaque, alloc: Allocator, ref: []const u8) !void {
    const store_ctx: *TestStore = @ptrCast(@alignCast(ctx));
    if (store_ctx.map.fetchRemove(ref)) |entry| {
        alloc.free(entry.key);
        alloc.free(entry.value);
    }
    try saveToDisk(store_ctx, alloc);
}

fn deinit(ctx: *anyopaque, alloc: Allocator) void {
    const store_ctx: *TestStore = @ptrCast(@alignCast(ctx));
    var it = store_ctx.map.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.*);
    }
    store_ctx.map.deinit();
    if (store_ctx.file_path) |value| alloc.free(value);
    alloc.destroy(store_ctx);
}

fn loadFromDisk(ctx: *TestStore, alloc: Allocator) !void {
    const file_path = ctx.file_path orelse return;
    const bytes = std.fs.cwd().readFileAlloc(alloc, file_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer alloc.free(bytes);
    if (bytes.len == 0) return;

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try ctx.map.put(try alloc.dupe(u8, entry.key_ptr.*), try alloc.dupe(u8, entry.value_ptr.*.string));
    }
}

fn saveToDisk(ctx: *TestStore, alloc: Allocator) !void {
    const file_path = ctx.file_path orelse return;
    const dir_name = std.fs.path.dirname(file_path) orelse ".";
    try std.fs.cwd().makePath(dir_name);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '{');
    var it = ctx.map.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try json_util.appendJsonQuoted(&buf, entry.key_ptr.*, alloc);
        try buf.append(alloc, ':');
        try json_util.appendJsonQuoted(&buf, entry.value_ptr.*, alloc);
    }
    try buf.append(alloc, '}');
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = buf.items });
}

const vtable = secure_store.Store.VTable{
    .put = put,
    .get = get,
    .delete = delete,
    .deinit = deinit,
};

const testing = std.testing;

test "test backend round trips secret bytes" {
    var store = try init(testing.allocator, null);
    defer store.deinit(testing.allocator);

    try store.put(testing.allocator, "cred_abc", "{\"secret\":\"value\"}");
    const loaded = try store.get(testing.allocator, "cred_abc");
    defer testing.allocator.free(loaded);

    try testing.expectEqualStrings("{\"secret\":\"value\"}", loaded);
}

test "test backend persists through file when configured" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "secure-store.json" });
    defer testing.allocator.free(file_path);

    {
        var store = try init(testing.allocator, file_path);
        defer store.deinit(testing.allocator);
        try store.put(testing.allocator, "cred_seed", "{\"platform\":\"google\"}");
    }

    {
        var store = try init(testing.allocator, file_path);
        defer store.deinit(testing.allocator);
        const loaded = try store.get(testing.allocator, "cred_seed");
        defer testing.allocator.free(loaded);
        try testing.expectEqualStrings("{\"platform\":\"google\"}", loaded);
    }
}
