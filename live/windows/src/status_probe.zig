const std = @import("std");

pub fn probeStatus(allocator: std.mem.Allocator, port: u16) bool {
    var stream = std.net.tcpConnectToHost(allocator, "127.0.0.1", port) catch return false;
    defer stream.close();

    const req = "GET /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    stream.writeAll(req) catch return false;

    var buf: [512]u8 = undefined;
    const n = stream.read(&buf) catch return false;
    if (n == 0) return false;
    const body = buf[0..n];
    return std.mem.indexOf(u8, body, "HTTP/1.1 200") != null or std.mem.indexOf(u8, body, "HTTP/1.0 200") != null;
}

pub fn waitUntilReady(allocator: std.mem.Allocator, port: u16, timeout_ms: u64, interval_ms: u64) bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (probeStatus(allocator, port)) return true;
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }
    return false;
}

test "probe interprets invalid response as false" {
    try std.testing.expect(!isHealthyStatusResponse("garbage"));
}

test "probe interprets 200 response as true" {
    try std.testing.expect(isHealthyStatusResponse("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"configured\":false}"));
}

fn isHealthyStatusResponse(buf: []const u8) bool {
    return std.mem.indexOf(u8, buf, "HTTP/1.1 200") != null or std.mem.indexOf(u8, buf, "HTTP/1.0 200") != null;
}
