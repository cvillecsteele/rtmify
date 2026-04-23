const std = @import("std");

const dispatch = @import("dispatch.zig");
const types = @import("types.zig");

const loopback_ip = .{ 127, 0, 0, 1 };

pub const BoundServer = struct {
    server: std.net.Server,
    port: u16,

    pub fn deinit(self: *BoundServer) void {
        self.server.deinit();
    }
};

/// Walks ports from start_port for up to max_attempts and returns the first
/// one that exclusively binds. Caller owns the returned BoundServer.
///
/// Uses reuse_address=false to avoid the Windows SO_REUSEADDR "first wins"
/// hazard where another listener already owns the port and we'd bind on top.
/// Loopback-only dev tool doesn't need TIME_WAIT recovery, so exclusive
/// bind is the safer default on every platform.
pub fn bindLoopbackPort(start_port: u16, max_attempts: u16) !BoundServer {
    var attempt: u16 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const port = start_port + attempt;
        const addr = std.net.Address.initIp4(loopback_ip, port);
        const server = addr.listen(.{ .reuse_address = false }) catch |e| {
            if (e == error.AddressInUse and attempt + 1 < max_attempts) {
                std.log.warn("port {d} in use, trying {d}...", .{ port, port + 1 });
                continue;
            }
            return e;
        };
        return .{ .server = server, .port = port };
    }
    return error.AddressInUse;
}

/// Atomically writes the bound port to a file the parent process can read
/// to discover what port we actually bound. Used by native tray shells to
/// avoid pre-probing (which is unsafe on Windows due to SO_REUSEADDR).
pub fn announcePort(port_file_path: []const u8, port: u16) !void {
    try writePortFile(port_file_path, port);
}

/// Runs the accept loop. Holds the BoundServer until the loop exits (which,
/// today, is never — the server runs until process termination).
pub fn serve(bound: *BoundServer, ctx: types.ServerCtx) !void {
    std.log.info("rtmify-live HTTP server listening on http://127.0.0.1:{d}", .{bound.port});

    while (true) {
        const conn = bound.server.accept() catch |e| {
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

/// Writes `port` (decimal ASCII) to `path` atomically: write a sibling .tmp,
/// then rename. The atomic rename ensures readers never see a partial value.
fn writePortFile(path: []const u8, port: u16) !void {
    var alloc_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const alloc = fba.allocator();

    const dir_name = std.fs.path.dirname(path) orelse ".";
    const base_name = std.fs.path.basename(path);
    const tmp_name = try std.fmt.allocPrint(alloc, "{s}.tmp", .{base_name});

    var dir = if (std.fs.path.isAbsolute(dir_name))
        try std.fs.openDirAbsolute(dir_name, .{})
    else
        try std.fs.cwd().openDir(dir_name, .{});
    defer dir.close();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    try dir.writeFile(.{ .sub_path = tmp_name, .data = port_str });
    dir.rename(tmp_name, base_name) catch |e| switch (e) {
        error.PathAlreadyExists => {
            try dir.deleteFile(base_name);
            try dir.rename(tmp_name, base_name);
        },
        else => return e,
    };
}

const testing = std.testing;

test "server listener stays loopback only" {
    try testing.expectEqual(@as(u8, 127), loopback_ip[0]);
    try testing.expectEqual(@as(u8, 0), loopback_ip[1]);
    try testing.expectEqual(@as(u8, 0), loopback_ip[2]);
    try testing.expectEqual(@as(u8, 1), loopback_ip[3]);
}
