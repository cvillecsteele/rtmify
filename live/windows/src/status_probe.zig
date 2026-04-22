const std = @import("std");
const builtin = @import("builtin");
const socket_read = @import("socket_read");
const tray_log = @import("tray_log.zig");

// Do not call std.net.Stream.read directly here. See live/src/socket_read.zig
// for the Windows-safe raw socket read policy and rationale.

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
    var windows_error: std.os.windows.ws2_32.WinsockError = .WSAEINVAL;
    const n = socket_read.read(stream, &buf, &windows_error) catch |err| {
        if (builtin.os.tag == .windows) {
            tray_log.logf("probe: socket_read failed: {s} (WSA={d})", .{ @errorName(err), @intFromEnum(windows_error) });
        } else {
            tray_log.logf("probe: socket_read failed: {s}", .{@errorName(err)});
        }
        return false;
    };
    if (n == 0) {
        tray_log.log("probe: socket_read returned 0 bytes (clean EOF)");
        return false;
    }
    const body = buf[0..n];
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
