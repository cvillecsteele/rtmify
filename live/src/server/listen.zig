const std = @import("std");

const dispatch = @import("dispatch.zig");
const types = @import("types.zig");

const loopback_ip = .{ 127, 0, 0, 1 };

pub fn listen(port: u16, ctx: types.ServerCtx) !void {
    const addr = std.net.Address.initIp4(loopback_ip, port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("rtmify-live HTTP server listening on http://127.0.0.1:{d}", .{port});

    while (true) {
        const conn = server.accept() catch |e| {
            std.log.err("accept error: {s}", .{@errorName(e)});
            continue;
        };
        handleConnection(conn.stream, ctx) catch |e| {
            std.log.debug("connection error: {s}", .{@errorName(e)});
        };
        conn.stream.close();
    }
}

fn handleConnection(stream: std.net.Stream, ctx: types.ServerCtx) !void {
    var read_buf: [16384]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var net_reader = stream.reader(&read_buf);
    var net_writer = stream.writer(&write_buf);
    var http_srv = std.http.Server.init(net_reader.interface(), &net_writer.interface);

    var req = http_srv.receiveHead() catch |e| switch (e) {
        error.HttpConnectionClosing => return,
        else => return e,
    };

    dispatch.handleRequest(&req, ctx) catch |e| {
        std.log.debug("request handler error: {s}", .{@errorName(e)});
    };
}

const testing = std.testing;

test "server listener stays loopback only" {
    try testing.expectEqual(@as(u8, 127), loopback_ip[0]);
    try testing.expectEqual(@as(u8, 0), loopback_ip[1]);
    try testing.expectEqual(@as(u8, 0), loopback_ip[2]);
    try testing.expectEqual(@as(u8, 1), loopback_ip[3]);
}
