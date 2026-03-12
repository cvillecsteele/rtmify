const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const test_backend = @import("secure_store_test.zig");
const unsupported_backend = @import("secure_store_unsupported.zig");
const macos_backend = if (builtin.target.os.tag == .macos) @import("secure_store_macos.zig") else struct {};
const windows_backend = if (builtin.target.os.tag == .windows) @import("secure_store_windows.zig") else struct {};

pub const Backend = enum {
    macos_keychain,
    windows_dpapi,
    unsupported,
    test_memory,
};

pub const LoadError = error{
    Unsupported,
    NotFound,
    AccessDenied,
    CorruptSecret,
    BackendFailure,
};

pub const Store = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    backend: Backend,

    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, alloc: Allocator, ref: []const u8, secret_json: []const u8) anyerror!void,
        get: *const fn (ctx: *anyopaque, alloc: Allocator, ref: []const u8) LoadError![]u8,
        delete: *const fn (ctx: *anyopaque, alloc: Allocator, ref: []const u8) anyerror!void,
        deinit: *const fn (ctx: *anyopaque, alloc: Allocator) void,
    };

    pub fn put(self: *Store, alloc: Allocator, ref: []const u8, secret_json: []const u8) !void {
        return self.vtable.put(self.ctx, alloc, ref, secret_json);
    }

    pub fn get(self: *Store, alloc: Allocator, ref: []const u8) LoadError![]u8 {
        return self.vtable.get(self.ctx, alloc, ref);
    }

    pub fn delete(self: *Store, alloc: Allocator, ref: []const u8) !void {
        return self.vtable.delete(self.ctx, alloc, ref);
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.vtable.deinit(self.ctx, alloc);
        self.ctx = undefined;
    }
};

pub fn initDefault(alloc: Allocator) !Store {
    const override = std.process.getEnvVarOwned(alloc, "RTMIFY_SECURE_STORE_BACKEND") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (override) |value| alloc.free(value);

    if (override) |value| {
        if (std.ascii.eqlIgnoreCase(value, "test-memory")) {
            return test_backend.initFromEnv(alloc);
        }
        if (std.ascii.eqlIgnoreCase(value, "unsupported")) {
            return unsupported_backend.init(alloc);
        }
    }

    return switch (builtin.target.os.tag) {
        .macos => macos_backend.init(alloc),
        .windows => windows_backend.init(alloc),
        else => unsupported_backend.init(alloc),
    };
}

pub fn initTestMemory(alloc: Allocator) !Store {
    return test_backend.init(alloc, null);
}

pub fn backendSupported(store: Store) bool {
    return store.backend != .unsupported;
}

pub fn backendName(backend: Backend) []const u8 {
    return @tagName(backend);
}

pub fn generateCredentialRef(alloc: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return std.fmt.allocPrint(alloc, "cred_{s}", .{hex});
}

const testing = std.testing;

test "generated credential refs are opaque and unique" {
    const a = try generateCredentialRef(testing.allocator);
    defer testing.allocator.free(a);
    const b = try generateCredentialRef(testing.allocator);
    defer testing.allocator.free(b);

    try testing.expect(std.mem.startsWith(u8, a, "cred_"));
    try testing.expect(std.mem.startsWith(u8, b, "cred_"));
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqual(@as(usize, 37), a.len);
}

test "initTestMemory uses supported backend" {
    var store = try initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);

    try testing.expect(backendSupported(store));
    try testing.expectEqual(Backend.test_memory, store.backend);
}
