/// server.zig — TCP/HTTP listener for rtmify-live.
///
/// Single-threaded accept loop.  Each connection is handled synchronously;
/// keep-alive is not used (connection: close per response).  The sync thread
/// runs independently via sync_live.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("graph_live.zig");
const sync_live = @import("sync_live.zig");
const routes = @import("routes.zig");

pub const ServerCtx = struct {
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    alloc: Allocator,
    /// Called after POST /api/config to (re)start the sync thread if not already running.
    /// Set by main_live.zig; null means auto-start is not configured.
    startSyncFn: ?*const fn (*graph_live.GraphDb, *sync_live.SyncState, Allocator) void = null,
};

/// Listen on `port` and serve HTTP requests forever.
pub fn listen(port: u16, ctx: ServerCtx) !void {
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("rtmify-live HTTP server listening on http://localhost:{d}", .{port});

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

fn handleConnection(stream: std.net.Stream, ctx: ServerCtx) !void {
    var read_buf: [16384]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var net_reader = stream.reader(&read_buf);
    var net_writer = stream.writer(&write_buf);
    var http_srv = std.http.Server.init(net_reader.interface(), &net_writer.interface);

    // We handle at most one request per connection (no keep-alive).
    var req = http_srv.receiveHead() catch |e| switch (e) {
        error.HttpConnectionClosing => return,
        else => return e,
    };

    handleRequest(&req, ctx) catch |e| {
        std.log.debug("request handler error: {s}", .{@errorName(e)});
    };
}

fn handleRequest(req: *std.http.Server.Request, ctx: ServerCtx) !void {
    // Arena per request
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = req.head.target;

    // Strip query string for routing
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    // Route
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        try sendHtml(req, routes.index_html);
        return;
    }

    if (req.head.method == .GET) {
        if (std.mem.eql(u8, path, "/nodes")) {
            const type_filter = queryParam(target, "type");
            const body = try routes.handleNodes(ctx.db, type_filter, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/nodes/types")) {
            const body = try routes.handleNodeTypes(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/edges/labels")) {
            const body = try routes.handleEdgeLabels(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/search")) {
            const q = queryParam(target, "q") orelse "";
            const body = try routes.handleSearch(ctx.db, q, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/schema")) {
            const body = try routes.handleSchema(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/gaps")) {
            const body = try routes.handleGaps(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/rtm")) {
            const body = try routes.handleRtm(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/suspects")) {
            const body = try routes.handleSuspects(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/user-needs")) {
            const body = try routes.handleUserNeeds(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/tests")) {
            const body = try routes.handleTests(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/risks")) {
            const body = try routes.handleRisks(ctx.db, alloc);
            try sendJson(req, body);
        } else if (std.mem.startsWith(u8, path, "/query/impact/")) {
            const node_id = path["/query/impact/".len..];
            const body = try routes.handleImpact(ctx.db, node_id, alloc);
            try sendJson(req, body);
        } else if (std.mem.startsWith(u8, path, "/query/node/")) {
            const node_id = path["/query/node/".len..];
            const body = try routes.handleNode(ctx.db, node_id, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/status")) {
            const body = try routes.handleStatus(ctx.db, ctx.state, alloc);
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/report/rtm")) {
            const body = try routes.handleReportRtmPdf(ctx.db, alloc);
            try sendPdf(req, body);
        } else if (std.mem.eql(u8, path, "/report/rtm.md")) {
            const body = try routes.handleReportRtmMd(ctx.db, alloc);
            try sendText(req, body, "text/markdown");
        } else if (std.mem.eql(u8, path, "/report/rtm.docx")) {
            const body = try routes.handleReportRtmDocx(ctx.db, alloc);
            try sendDocx(req, body);
        } else if (std.mem.eql(u8, path, "/mcp")) {
            // SSE endpoint — delegated to mcp.zig (streamed, not a simple response)
            try @import("mcp.zig").handleSse(req, ctx.db, alloc);
        } else {
            try send404(req);
        }
    } else if (req.head.method == .POST) {
        if (std.mem.eql(u8, path, "/mcp")) {
            const body_bytes = try readBody(req, alloc);
            try @import("mcp.zig").handlePost(req, body_bytes, ctx.db, ctx.state, alloc);
        } else if (std.mem.eql(u8, path, "/api/service-account")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleServiceAccount(ctx.db, body_bytes, alloc);
            try sendJson(req, resp);
        } else if (std.mem.eql(u8, path, "/api/config")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleConfig(ctx.db, body_bytes, alloc);
            // Trigger sync thread start if credentials + sheet_id are now available
            if (ctx.startSyncFn) |f| f(ctx.db, ctx.state, ctx.alloc);
            try sendJson(req, resp);
        } else if (std.mem.startsWith(u8, path, "/suspect/") and
            std.mem.endsWith(u8, path, "/clear"))
        {
            const node_id = path["/suspect/".len .. path.len - "/clear".len];
            const resp = try routes.handleClearSuspect(ctx.db, node_id, alloc);
            try sendJson(req, resp);
        } else if (std.mem.eql(u8, path, "/ingest")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleIngest(ctx.db, body_bytes, alloc);
            try sendJson(req, resp);
        } else {
            try send404(req);
        }
    } else if (req.head.method == .OPTIONS) {
        // Simple CORS preflight
        try sendOptions(req);
    } else {
        try send404(req);
    }
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

const cors_headers = [_]std.http.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
    .{ .name = "Connection", .value = "close" },
};

fn sendJson(req: *std.http.Server.Request, body: []const u8) !void {
    const headers = cors_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

fn sendHtml(req: *std.http.Server.Request, body: []const u8) !void {
    const headers = cors_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

fn sendPdf(req: *std.http.Server.Request, body: []const u8) !void {
    const headers = cors_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/pdf" },
        .{ .name = "Content-Disposition", .value = "attachment; filename=\"rtm.pdf\"" },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

fn sendText(req: *std.http.Server.Request, body: []const u8, content_type: []const u8) !void {
    const headers = cors_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = content_type },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

fn sendDocx(req: *std.http.Server.Request, body: []const u8) !void {
    const mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    const headers = cors_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = mime },
        .{ .name = "Content-Disposition", .value = "attachment; filename=\"rtm.docx\"" },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

fn send404(req: *std.http.Server.Request) !void {
    try req.respond("{\"error\":\"not found\"}", .{
        .status = .not_found,
        .extra_headers = &cors_headers,
        .keep_alive = false,
    });
}

fn sendOptions(req: *std.http.Server.Request) !void {
    try req.respond("", .{
        .status = .no_content,
        .extra_headers = &cors_headers,
        .keep_alive = false,
    });
}

// ---------------------------------------------------------------------------
// Request body reading
// ---------------------------------------------------------------------------

fn readBody(req: *std.http.Server.Request, alloc: Allocator) ![]u8 {
    var body_buf: [1024 * 1024]u8 = undefined; // 1 MB max
    const reader = req.readerExpectNone(&body_buf);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    _ = reader.streamRemaining(&out.writer) catch {};
    return alloc.dupe(u8, out.writer.buffer[0..out.writer.end]);
}

// ---------------------------------------------------------------------------
// Query string parsing
// ---------------------------------------------------------------------------

fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const q_pos = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[q_pos + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}
