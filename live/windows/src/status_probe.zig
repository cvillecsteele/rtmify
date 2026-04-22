const std = @import("std");
const builtin = @import("builtin");
const tray_log = @import("tray_log.zig");

// We call ws2_32.recv directly instead of std.net.Stream.read.
//
// Background: Zig's std.net.Stream.read on Windows goes through ReadFile on
// the socket handle, not recv/WSARecv. ReadFile-on-socket can return Win32
// error codes that aren't in Zig's WSA error mapping table, surfacing as
// error.Unexpected. We observed every probe attempt failing with
// error.Unexpected even though the server was responding 200 to each request
// (verified by server-side logging); switching this single read to ws2_32.recv
// fixes it.
//
// State-of-the-art Zig socket-read patterns on Windows in 2026:
//   1. Call ws2_32.recv directly (this file)
//   2. Platform abstraction: recv on Windows, posix.read elsewhere
//   3. WSARecv with overlapped I/O (for async / IOCP systems)
//
// This file is Windows-only, so option 1 is the right choice here. If you
// add socket-read code to cross-platform modules (e.g. lib/, live/src/), use
// option 2.
const SOCKET = if (builtin.os.tag == .windows) std.os.windows.ws2_32.SOCKET else void;
const SOCKET_ERROR: c_int = -1;

extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

pub fn probeStatus(allocator: std.mem.Allocator, port: u16) bool {
    _ = allocator;
    const addr = std.net.Address.parseIp4("127.0.0.1", port) catch |err| {
        tray_log.logf("probe: parseIp4 failed: {s}", .{@errorName(err)});
        return false;
    };
    var stream = std.net.tcpConnectToAddress(addr) catch |err| {
        tray_log.logf("probe: tcpConnectToAddress failed: {s}", .{@errorName(err)});
        return false;
    };
    defer stream.close();

    const req = "GET /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    stream.writeAll(req) catch |err| {
        tray_log.logf("probe: writeAll failed: {s}", .{@errorName(err)});
        return false;
    };

    var buf: [512]u8 = undefined;
    const sock: SOCKET = @ptrCast(stream.handle);
    const n = recv(sock, &buf, buf.len, 0);
    if (n == SOCKET_ERROR) {
        const code = WSAGetLastError();
        tray_log.logf("probe: raw recv failed, WSAGetLastError={d}", .{code});
        return false;
    }
    if (n == 0) {
        tray_log.log("probe: raw recv returned 0 bytes (clean EOF)");
        return false;
    }
    const body = buf[0..@intCast(n)];
    const matched = std.mem.indexOf(u8, body, "HTTP/1.1 200") != null or std.mem.indexOf(u8, body, "HTTP/1.0 200") != null;
    if (!matched) {
        const preview_len = @min(body.len, 80);
        tray_log.logf("probe: read {d} bytes, no 200 match. head={s}", .{ n, body[0..preview_len] });
        return false;
    }
    tray_log.logf("probe: ok ({d} bytes)", .{n});
    return true;
}

pub fn waitUntilReady(allocator: std.mem.Allocator, port: u16, timeout_ms: u64, interval_ms: u64) bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (probeStatus(allocator, port)) return true;
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }
    return false;
}

test "probe fails when nothing is listening" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(!probeStatus(std.testing.allocator, 1));
}
