// tray_log.zig — Diagnostic log for the Windows tray shell itself.
// Writes to %LOCALAPPDATA%\RTMify Live\logs\tray.log so we can debug the
// tray's view of startup/probe behavior independently of the server log.

const std = @import("std");

var g_mutex: std.Thread.Mutex = .{};

fn ensureDirPath(path: []const u8) void {
    // makeDirAbsolute creates only the leaf, not parents. On a fresh install
    // %LOCALAPPDATA%\RTMify Live does not exist yet, so we walk components.
    // (Mirrors workbook/paths.zig:ensureDirPath; duplicated here so the tray
    // shell stays free of cross-module imports outside live/windows/.)
    if (!std.fs.path.isAbsolute(path)) {
        std.fs.cwd().makePath(path) catch {};
        return;
    }
    var it = std.fs.path.componentIterator(path) catch return;
    var comp = it.first();
    while (comp) |c| : (comp = it.next()) {
        std.fs.makeDirAbsolute(c.path) catch {};
    }
}

fn appendLine(line: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();

    var alloc_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const alloc = fba.allocator();

    const local_app_data = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return;
    const log_dir = std.fs.path.join(alloc, &.{ local_app_data, "RTMify Live", "logs" }) catch return;
    ensureDirPath(log_dir);
    const log_path = std.fs.path.join(alloc, &.{ log_dir, "tray.log" }) catch return;

    const file = std.fs.createFileAbsolute(log_path, .{ .read = false, .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;

    var ts_buf: [64]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d} ", .{std.time.timestamp()}) catch "";
    _ = file.writeAll(ts) catch {};
    _ = file.writeAll(line) catch {};
    _ = file.writeAll("\r\n") catch {};
}

pub fn log(msg: []const u8) void {
    appendLine(msg);
}

pub fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    appendLine(line);
}
