const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AuthState = struct {
    token_file_path: []u8,
    token: []u8,
    mu: std.Thread.Mutex = .{},

    pub fn initDefault(alloc: Allocator) !AuthState {
        const override = std.process.getEnvVarOwned(alloc, "RTMIFY_TEST_RESULTS_TOKEN_FILE") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (override) |value| alloc.free(value);

        const token_path = if (override) |value|
            try alloc.dupe(u8, value)
        else
            try defaultTokenPath(alloc);
        const token = try ensureTokenFile(token_path, alloc);
        return .{
            .token_file_path = token_path,
            .token = token,
        };
    }

    pub fn initForPath(token_file_path: []const u8, alloc: Allocator) !AuthState {
        const path = try alloc.dupe(u8, token_file_path);
        const token = try ensureTokenFile(path, alloc);
        return .{
            .token_file_path = path,
            .token = token,
        };
    }

    pub fn deinit(self: *AuthState, alloc: Allocator) void {
        alloc.free(self.token_file_path);
        alloc.free(self.token);
    }

    pub fn currentToken(self: *AuthState, alloc: Allocator) ![]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return alloc.dupe(u8, self.token);
    }

    pub fn validateBearerHeader(self: *AuthState, header_value: ?[]const u8) bool {
        const header = header_value orelse return false;
        const trimmed = std.mem.trim(u8, header, " \t");
        if (trimmed.len <= "Bearer ".len) return false;
        if (!std.ascii.eqlIgnoreCase(trimmed[0.."Bearer".len], "Bearer")) return false;
        if (trimmed["Bearer".len] != ' ') return false;
        const candidate = std.mem.trim(u8, trimmed["Bearer ".len..], " \t");

        self.mu.lock();
        defer self.mu.unlock();
        return std.mem.eql(u8, candidate, self.token);
    }

    pub fn regenerate(self: *AuthState, alloc: Allocator) ![]u8 {
        const fresh = try generateToken(alloc);
        errdefer alloc.free(fresh);

        self.mu.lock();
        defer self.mu.unlock();
        try writeTokenFile(self.token_file_path, fresh);
        alloc.free(self.token);
        self.token = fresh;
        return alloc.dupe(u8, self.token);
    }
};

fn defaultTokenPath(alloc: Allocator) ![]u8 {
    const home = try homeDir(alloc);
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".rtmify", "api-token" });
}

pub fn defaultInboxDir(alloc: Allocator) ![]u8 {
    const override = std.process.getEnvVarOwned(alloc, "RTMIFY_TEST_RESULTS_INBOX_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (override) |value| alloc.free(value);
    if (override) |value| return alloc.dupe(u8, value);

    const home = try homeDir(alloc);
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".rtmify", "inbox" });
}

fn homeDir(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "HOME")) |home| return home else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return std.process.getEnvVarOwned(alloc, "USERPROFILE");
}

fn ensureTokenFile(token_file_path: []const u8, alloc: Allocator) ![]u8 {
    const file = readTokenFile(token_file_path, alloc) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (file) |existing| {
        errdefer alloc.free(existing);
        if (isValidToken(existing)) return existing;
        alloc.free(existing);
    }

    const fresh = try generateToken(alloc);
    errdefer alloc.free(fresh);
    try writeTokenFile(token_file_path, fresh);
    return fresh;
}

fn readTokenFile(token_file_path: []const u8, alloc: Allocator) !?[]u8 {
    const bytes = std.fs.cwd().readFileAlloc(alloc, token_file_path, 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer alloc.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.ptr == bytes.ptr and trimmed.len == bytes.len) return bytes;
    const copy = try alloc.dupe(u8, trimmed);
    alloc.free(bytes);
    return copy;
}

fn writeTokenFile(token_file_path: []const u8, token: []const u8) !void {
    const dir_name = std.fs.path.dirname(token_file_path) orelse ".";
    try std.fs.cwd().makePath(dir_name);

    const base_name = std.fs.path.basename(token_file_path);
    const tmp_name = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{base_name});
    defer std.heap.page_allocator.free(tmp_name);

    var dir = if (std.fs.path.isAbsolute(dir_name))
        try std.fs.openDirAbsolute(dir_name, .{})
    else
        try std.fs.cwd().openDir(dir_name, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = tmp_name, .data = token });
    dir.rename(tmp_name, base_name) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try dir.deleteFile(base_name);
            try dir.rename(tmp_name, base_name);
        },
        else => return err,
    };
}

fn generateToken(alloc: Allocator) ![]u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return alloc.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

fn isValidToken(token: []const u8) bool {
    if (token.len != 64) return false;
    for (token) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const testing = std.testing;

test "generates token when file missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);

    var auth = try AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 64), auth.token.len);
}

test "loads existing token unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);

    try writeTokenFile(token_path, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    var auth = try AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);

    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", auth.token);
}

test "regenerate replaces token" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);

    var auth = try AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const old = try testing.allocator.dupe(u8, auth.token);
    defer testing.allocator.free(old);

    const regenerated = try auth.regenerate(testing.allocator);
    defer testing.allocator.free(regenerated);
    const header = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{regenerated});
    defer testing.allocator.free(header);

    try testing.expect(!std.mem.eql(u8, old, regenerated));
    try testing.expect(auth.validateBearerHeader(header));
}

test "validates bearer header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);

    try writeTokenFile(token_path, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    var auth = try AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);

    try testing.expect(auth.validateBearerHeader("Bearer bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try testing.expect(!auth.validateBearerHeader("Bearer nope"));
    try testing.expect(!auth.validateBearerHeader(null));
}

test "default inbox dir can be overridden" {
    try testing.expect(std.process.can_spawn);
}
