const std = @import("std");

var log_file: ?std.fs.File = null;
var init_attempted = false;
var mutex: std.Thread.Mutex = .{};

fn homeDir(alloc: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "HOME")) |home| return home else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return std.process.getEnvVarOwned(alloc, "USERPROFILE");
}

pub fn defaultLogPath(alloc: std.mem.Allocator) ![]u8 {
    const home = try homeDir(alloc);
    errdefer alloc.free(home);
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.rtmify/log/server.log", .{home});
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    writer.print("{s}", .{levelText(level)}) catch return;
    if (scope != .default) {
        writer.print("({s})", .{@tagName(scope)}) catch return;
    }
    writer.print(": ", .{}) catch return;
    writer.print(format, args) catch return;
    writer.print("\n", .{}) catch return;

    const line = fbs.getWritten();

    std.fs.File.stderr().writeAll(line) catch {};

    mutex.lock();
    defer mutex.unlock();
    ensureOpenLocked();
    if (log_file) |*file| {
        file.writeAll(line) catch {};
        file.sync() catch {};
    }
}

fn ensureOpenLocked() void {
    if (init_attempted) return;
    init_attempted = true;

    const alloc = std.heap.page_allocator;
    const home = homeDir(alloc) catch null;
    defer if (home) |h| alloc.free(h);

    if (home) |h| {
        const dir_path = std.fmt.allocPrint(alloc, "{s}/.rtmify/log", .{h}) catch return;
        defer alloc.free(dir_path);
        std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };
        const file_path = std.fmt.allocPrint(alloc, "{s}/server.log", .{dir_path}) catch return;
        defer alloc.free(file_path);
        log_file = std.fs.openFileAbsolute(file_path, .{ .mode = .read_write }) catch blk: {
            break :blk std.fs.createFileAbsolute(file_path, .{ .read = true, .truncate = false }) catch return;
        };
        if (log_file) |*file| {
            file.seekFromEnd(0) catch {};
        }
        return;
    }

    log_file = std.fs.cwd().createFile("rtmify-live.log", .{ .read = true, .truncate = false }) catch null;
    if (log_file) |*file| {
        file.seekFromEnd(0) catch {};
    }
}

fn levelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}
