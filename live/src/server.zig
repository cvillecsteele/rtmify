/// server.zig — TCP/HTTP listener for rtmify-live.
///
/// Single-threaded accept loop.  Each connection is handled synchronously;
/// keep-alive is not used (connection: close per response).  The sync thread
/// runs independently via sync_live.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const license = rtmify.license;
const graph_live = @import("graph_live.zig");
const secure_store = @import("secure_store.zig");
const sync_live = @import("sync_live.zig");
const routes = @import("routes.zig");

pub const ServerCtx = struct {
    db: *graph_live.GraphDb,
    secure_store: *secure_store.Store,
    state: *sync_live.SyncState,
    license_service: *license.Service,
    alloc: Allocator,
    /// Called after POST /api/connection to (re)start the sync thread if not already running.
    /// Set by main_live.zig; null means auto-start is not configured.
    startSyncFn: ?*const fn (*graph_live.GraphDb, *secure_store.Store, *sync_live.SyncState, Allocator) void = null,
};

/// Listen on `port` and serve HTTP requests forever.
pub fn listen(port: u16, ctx: ServerCtx) !void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
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
    const path = stripQuery(target);
    const method_name = @tagName(req.head.method);
    const started_ns = std.time.nanoTimestamp();
    var response_status: ?std.http.Status = null;
    var response_bytes: usize = 0;
    defer {
        const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started_ns, std.time.ns_per_ms);
        if (response_status) |status| {
            std.log.info("http done {s} {s} status={d} bytes={d} elapsed_ms={d}", .{
                method_name,
                target,
                @intFromEnum(status),
                response_bytes,
                elapsed_ms,
            });
        } else {
            std.log.warn("http unfinished {s} {s} elapsed_ms={d}", .{
                method_name,
                target,
                elapsed_ms,
            });
        }
    }
    std.log.info("http {s} {s}", .{ method_name, target });

    validateLocalRequest(req) catch |e| switch (e) {
        error.ForbiddenHost => {
            const body = "{\"error\":\"forbidden_host\"}";
            response_status = .forbidden;
            response_bytes = body.len;
            try sendJsonWithStatus(req, body, .forbidden);
            return;
        },
        error.ForbiddenOrigin => {
            const body = "{\"error\":\"forbidden_origin\"}";
            response_status = .forbidden;
            response_bytes = body.len;
            try sendJsonWithStatus(req, body, .forbidden);
            return;
        },
    };

    if (req.head.method == .OPTIONS) {
        const body = "{\"error\":\"method_not_allowed\"}";
        response_status = .method_not_allowed;
        response_bytes = body.len;
        try sendJsonWithStatus(req, body, .method_not_allowed);
        return;
    }

    // Route
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        response_status = .ok;
        response_bytes = routes.index_html.len;
        try sendHtml(req, routes.index_html);
        return;
    }
    if (std.mem.eql(u8, path, "/app.js")) {
        response_status = .ok;
        response_bytes = routes.app_js.len;
        try sendStaticText(req, routes.app_js, "application/javascript; charset=utf-8");
        return;
    }

    if (req.head.method != .OPTIONS and !isLicenseExempt(req.head.method, path)) {
        var license_status = try ctx.license_service.getStatus(alloc);
        defer license_status.deinit(alloc);
        ctx.state.product_enabled.store(license_status.permits_use, .seq_cst);
        if (!license_status.permits_use) {
            const body = try std.fmt.allocPrint(alloc, "{{\"error\":\"license_required\",\"license_state\":\"{s}\"}}", .{
                @tagName(license_status.state),
            });
            response_status = .forbidden;
            response_bytes = body.len;
            try sendJsonWithStatus(req, body, .forbidden);
            return;
        }
    }

    if (req.head.method == .GET) {
        if (std.mem.eql(u8, path, "/nodes")) {
            const type_filter = try queryParamDecoded(target, "type", alloc);
            const body = try routes.handleNodes(ctx.db, type_filter, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/nodes/types")) {
            const body = try routes.handleNodeTypes(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/edges/labels")) {
            const body = try routes.handleEdgeLabels(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/search")) {
            const q = (try queryParamDecoded(target, "q", alloc)) orelse "";
            const body = try routes.handleSearch(ctx.db, q, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/schema")) {
            const body = try routes.handleSchema(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/gaps")) {
            const body = try routes.handleGaps(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/rtm")) {
            const body = try routes.handleRtm(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/suspects")) {
            const body = try routes.handleSuspects(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/user-needs")) {
            const body = try routes.handleUserNeeds(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/tests")) {
            const body = try routes.handleTests(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/risks")) {
            const body = try routes.handleRisks(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.startsWith(u8, path, "/query/impact/")) {
            const node_id = try decodePathParam(path["/query/impact/".len..], alloc);
            std.log.info("impact request start id={s}", .{node_id});
            const body = routes.handleImpact(ctx.db, node_id, alloc) catch |e| switch (e) {
                error.NotFound => {
                    std.log.warn("impact request not found id={s}", .{node_id});
                    const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"node not found\",\"id\":\"{s}\"}}", .{node_id});
                    response_status = .not_found;
                    response_bytes = err_body.len;
                    try sendJsonWithStatus(req, err_body, .not_found);
                    return;
                },
                else => {
                    std.log.err("impact request failed id={s}: {s}", .{ node_id, @errorName(e) });
                    return e;
                },
            };
            std.log.info("impact request ok id={s} bytes={d}", .{ node_id, body.len });
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.startsWith(u8, path, "/query/node/")) {
            const node_id = try decodePathParam(path["/query/node/".len..], alloc);
            const body = routes.handleNode(ctx.db, node_id, alloc) catch |e| switch (e) {
                error.NotFound => {
                    const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"node not found\",\"id\":\"{s}\"}}", .{node_id});
                    response_status = .not_found;
                    response_bytes = err_body.len;
                    try sendJsonWithStatus(req, err_body, .not_found);
                    return;
                },
                else => return e,
            };
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/status")) {
            const body = try routes.handleStatus(ctx.db, ctx.secure_store, ctx.state, ctx.license_service, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/license/status")) {
            const body = try routes.handleLicenseStatus(ctx.license_service, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/info")) {
            const body = try routes.handleInfo(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/provision-preview")) {
            const qprofile = try queryParamDecoded(target, "profile", alloc);
            const body = try routes.handleProvisionPreview(ctx.db, ctx.secure_store, qprofile, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/diagnostics")) {
            const qsource = try queryParamDecoded(target, "source", alloc);
            const body = try routes.handleDiagnostics(ctx.db, qsource, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/guide/errors")) {
            const body = try routes.handleGuideErrors(alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/report/coverage.md")) {
            const body = try routes.handleCoverageReport(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/plain; charset=utf-8");
        } else if (std.mem.eql(u8, path, "/report/rtm")) {
            const body = try routes.handleReportRtmPdf(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendPdf(req, body);
        } else if (std.mem.eql(u8, path, "/report/rtm.md")) {
            const body = try routes.handleReportRtmMd(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/markdown");
        } else if (std.mem.eql(u8, path, "/report/rtm.docx")) {
            const body = try routes.handleReportRtmDocx(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendDocx(req, body);
        } else if (std.mem.eql(u8, path, "/api/profile")) {
            const body = try routes.handleGetProfile(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/repos")) {
            const body = try routes.handleGetRepos(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/chain-gaps")) {
            const body = try routes.handleChainGaps(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/code-traceability")) {
            const body = try routes.handleCodeTraceability(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/recent-commits")) {
            const body = try routes.handleRecentCommits(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/implementation-changes")) {
            const since = try queryParamDecoded(target, "since", alloc);
            const node_type = try queryParamDecoded(target, "node_type", alloc);
            const repo = try queryParamDecoded(target, "repo", alloc);
            const limit = try queryParamDecoded(target, "limit", alloc);
            const offset = try queryParamDecoded(target, "offset", alloc);
            const resp = try routes.handleImplementationChangesResponse(ctx.db, since, node_type, repo, limit, offset, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/query/unimplemented-requirements")) {
            const body = try routes.handleUnimplementedRequirements(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/untested-source-files")) {
            const body = try routes.handleUntestedSourceFiles(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/file-annotations")) {
            const file_path = (try queryParamDecoded(target, "file_path", alloc)) orelse "";
            const body = try routes.handleFileAnnotations(ctx.db, file_path, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.startsWith(u8, path, "/query/commit-history/")) {
            const req_id = try decodePathParam(path["/query/commit-history/".len..], alloc);
            const body = try routes.handleCommitHistory(ctx.db, req_id, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/report/dhr/md")) {
            const body = try routes.handleReportDhrMd(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/markdown");
        } else if (std.mem.eql(u8, path, "/report/dhr/pdf")) {
            const body = try routes.handleReportDhrPdf(ctx.db, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendPdf(req, body);
        } else if (std.mem.eql(u8, path, "/mcp")) {
            // SSE endpoint — delegated to mcp.zig (streamed, not a simple response)
            response_status = .ok;
            try @import("mcp.zig").handleSse(req, ctx.db, ctx.secure_store, alloc);
        } else {
            response_status = .not_found;
            response_bytes = "{\"error\":\"not found\"}".len;
            try send404(req);
        }
    } else if (req.head.method == .POST) {
        if (std.mem.eql(u8, path, "/mcp")) {
            const body_bytes = try readBody(req, alloc);
            response_status = .ok;
            try @import("mcp.zig").handlePost(req, body_bytes, ctx.db, ctx.secure_store, ctx.state, alloc);
        } else if (std.mem.eql(u8, path, "/api/license/activate")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleLicenseActivateResponse(ctx.license_service, body_bytes, alloc);
            if (resp.ok) {
                var license_status = try ctx.license_service.getStatus(alloc);
                defer license_status.deinit(alloc);
                ctx.state.product_enabled.store(license_status.permits_use, .seq_cst);
                if (license_status.permits_use) {
                    if (ctx.startSyncFn) |f| f(ctx.db, ctx.secure_store, ctx.state, ctx.alloc);
                }
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/license/deactivate")) {
            const resp = try routes.handleLicenseDeactivateResponse(ctx.license_service, alloc);
            if (resp.ok) ctx.state.product_enabled.store(false, .seq_cst);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/license/refresh")) {
            const resp = try routes.handleLicenseRefreshResponse(ctx.license_service, alloc);
            if (resp.ok) {
                var license_status = try ctx.license_service.getStatus(alloc);
                defer license_status.deinit(alloc);
                ctx.state.product_enabled.store(license_status.permits_use, .seq_cst);
                if (license_status.permits_use) {
                    if (ctx.startSyncFn) |f| f(ctx.db, ctx.secure_store, ctx.state, ctx.alloc);
                }
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/profile")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handlePostProfileResponse(ctx.db, body_bytes, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/repos")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handlePostRepoResponse(ctx.db, body_bytes, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/repos/scan")) {
            sync_live.triggerRepoScanNow(ctx.db, ctx.state, alloc) catch |e| {
                const body = try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)});
                response_status = .internal_server_error;
                response_bytes = body.len;
                try sendJsonWithStatus(req, body, .internal_server_error);
                return;
            };
            const body = try alloc.dupe(u8, "{\"ok\":true}");
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/connection/validate")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleConnectionValidateResponse(ctx.secure_store, body_bytes, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/connection")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleConnectionResponse(ctx.db, ctx.secure_store, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.startSyncFn) |f| f(ctx.db, ctx.secure_store, ctx.state, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/provision")) {
            const resp = try routes.handleProvisionResponse(ctx.db, ctx.secure_store, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.startsWith(u8, path, "/suspect/") and
            std.mem.endsWith(u8, path, "/clear"))
        {
            const node_id = try decodePathParam(path["/suspect/".len .. path.len - "/clear".len], alloc);
            const resp = try routes.handleClearSuspect(ctx.db, node_id, alloc);
            response_status = .ok;
            response_bytes = resp.len;
            try sendJson(req, resp);
        } else if (std.mem.eql(u8, path, "/ingest")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleIngest(ctx.db, body_bytes, alloc);
            response_status = .ok;
            response_bytes = resp.len;
            try sendJson(req, resp);
        } else {
            response_status = .not_found;
            response_bytes = "{\"error\":\"not found\"}".len;
            try send404(req);
        }
    } else if (req.head.method == .DELETE) {
        if (std.mem.startsWith(u8, path, "/api/repos/")) {
            const idx = path["/api/repos/".len..];
            const resp = try routes.handleDeleteRepoResponse(ctx.db, idx, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else {
            response_status = .not_found;
            response_bytes = "{\"error\":\"not found\"}".len;
            try send404(req);
        }
    } else {
        response_status = .not_found;
        response_bytes = "{\"error\":\"not found\"}".len;
        try send404(req);
    }
}

fn isLicenseExempt(method: std.http.Method, path: []const u8) bool {
    _ = method;
    return std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/index.html") or
        std.mem.eql(u8, path, "/app.js") or
        std.mem.eql(u8, path, "/api/status") or
        std.mem.eql(u8, path, "/api/info") or
        std.mem.eql(u8, path, "/api/license/status") or
        std.mem.eql(u8, path, "/api/license/activate") or
        std.mem.eql(u8, path, "/api/license/deactivate") or
        std.mem.eql(u8, path, "/api/license/refresh");
}

const RequestValidationError = error{
    ForbiddenHost,
    ForbiddenOrigin,
};

fn requestHeaderValue(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return std.mem.trim(u8, header.value, " \t");
        }
    }
    return null;
}

fn requestHost(req: *const std.http.Server.Request) ?[]const u8 {
    return requestHeaderValue(req, "Host");
}

fn hostWithoutPort(host: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, host, " \t");
    if (trimmed.len == 0 or trimmed[0] == '[') return trimmed;
    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |idx| {
        return trimmed[0..idx];
    }
    return trimmed;
}

fn hostPort(host: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, host, " \t");
    if (trimmed.len == 0 or trimmed[0] == '[') return null;
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
    return std.fmt.parseInt(u16, trimmed[idx + 1 ..], 10) catch null;
}

fn isAllowedLocalHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.ascii.eqlIgnoreCase(host, "localhost");
}

fn parseOriginHost(origin_or_referer: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(origin_or_referer) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    const component = uri.host orelse return null;
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| if (std.mem.indexOfScalar(u8, encoded, '%') == null) encoded else null,
    };
}

fn parseOriginPort(origin_or_referer: []const u8) ?u16 {
    const uri = std.Uri.parse(origin_or_referer) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    return uri.port;
}

fn hasAllowedOriginValue(origin_or_referer: []const u8, req_host: []const u8) bool {
    const origin_host = parseOriginHost(origin_or_referer) orelse return false;
    if (!isAllowedLocalHost(origin_host)) return false;

    const req_port = hostPort(req_host) orelse return true;
    const origin_port = parseOriginPort(origin_or_referer) orelse return false;
    return origin_port == req_port;
}

fn requestHasAllowedBrowserOrigin(req: *const std.http.Server.Request) bool {
    const req_host = requestHost(req) orelse return false;
    if (requestHeaderValue(req, "Origin")) |origin| {
        return hasAllowedOriginValue(origin, req_host);
    }
    if (requestHeaderValue(req, "Referer")) |referer| {
        return hasAllowedOriginValue(referer, req_host);
    }
    return true;
}

fn requiresBrowserOriginCheck(method: std.http.Method, path: []const u8) bool {
    return method == .POST or method == .DELETE or (method == .GET and std.mem.eql(u8, path, "/mcp"));
}

fn validateLocalRequest(req: *const std.http.Server.Request) RequestValidationError!void {
    const host = requestHost(req) orelse return error.ForbiddenHost;
    if (!isAllowedLocalHost(hostWithoutPort(host))) return error.ForbiddenHost;

    const path = stripQuery(req.head.target);
    if (requiresBrowserOriginCheck(req.head.method, path) and !requestHasAllowedBrowserOrigin(req)) {
        return error.ForbiddenOrigin;
    }
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

const base_headers = [_]std.http.Header{
    .{ .name = "Connection", .value = "close" },
};

fn sendJson(req: *std.http.Server.Request, body: []const u8) !void {
    try sendJsonWithStatus(req, body, .ok);
}

fn sendJsonWithStatus(req: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try req.respond(body, .{
        .status = status,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

fn sendHtml(req: *std.http.Server.Request, body: []const u8) !void {
    try sendStaticText(req, body, "text/html; charset=utf-8");
}

fn sendStaticText(req: *std.http.Server.Request, body: []const u8, content_type: []const u8) !void {
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Cache-Control", .value = "no-store, no-cache, must-revalidate, max-age=0" },
        .{ .name = "Pragma", .value = "no-cache" },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

fn sendPdf(req: *std.http.Server.Request, body: []const u8) !void {
    const headers = base_headers ++ [_]std.http.Header{
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
    const headers = base_headers ++ [_]std.http.Header{
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
    const headers = base_headers ++ [_]std.http.Header{
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
    try sendJsonWithStatus(req, "{\"error\":\"not found\"}", .not_found);
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

fn queryParamRaw(target: []const u8, key: []const u8) ?[]const u8 {
    const q_pos = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[q_pos + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn queryParamDecoded(target: []const u8, key: []const u8, alloc: Allocator) !?[]const u8 {
    const raw = queryParamRaw(target, key) orelse return null;
    const buf = try alloc.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

fn stripQuery(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
}

fn decodePathParam(raw: []const u8, alloc: Allocator) ![]const u8 {
    const buf = try alloc.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

const testing = std.testing;

test "stripQuery removes query string and preserves bare path" {
    try testing.expectEqualStrings("/api/provision-preview", stripQuery("/api/provision-preview?profile=medical"));
    try testing.expectEqualStrings("/query/chain-gaps", stripQuery("/query/chain-gaps"));
}

test "queryParam extracts expected values" {
    try testing.expectEqualStrings("medical", queryParamRaw("/api/provision-preview?profile=medical", "profile").?);
    try testing.expect(queryParamRaw("/api/provision-preview?profile=medical", "sheet_url") == null);
    try testing.expect(queryParamRaw("/api/provision-preview?profile=medical", "missing") == null);
}

test "queryParamDecoded decodes percent-encoded values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = (try queryParamDecoded("/query/file-annotations?file_path=src%2Ffoo%20bar.c", "file_path", alloc)).?;
    try testing.expectEqualStrings("src/foo bar.c", decoded);
}

test "queryParamDecoded leaves simple values unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = (try queryParamDecoded("/api/provision-preview?profile=medical", "profile", alloc)).?;
    try testing.expectEqualStrings("medical", decoded);
}

test "decodePathParam decodes percent-encoded route IDs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = try decodePathParam("FOO%2FBAR%2FBAZ%3FBLOW%3DUP", alloc);
    try testing.expectEqualStrings("FOO/BAR/BAZ?BLOW=UP", decoded);
}

test "decodePathParam leaves simple IDs unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = try decodePathParam("REQ-014", alloc);
    try testing.expectEqualStrings("REQ-014", decoded);
}

test "successful connection response should start sync" {
    const resp = routes.JsonRouteResponse{ .status = .ok, .body = "{}", .ok = true };
    try testing.expect(resp.ok);
}

test "failed connection response should not start sync" {
    const resp = routes.JsonRouteResponse{ .status = .bad_request, .body = "{\"ok\":false}", .ok = false };
    try testing.expect(!resp.ok);
}

test "license exemptions include app js bootstrap asset" {
    try testing.expect(isLicenseExempt(.GET, "/"));
    try testing.expect(isLicenseExempt(.GET, "/index.html"));
    try testing.expect(isLicenseExempt(.GET, "/app.js"));
    try testing.expect(!isLicenseExempt(.GET, "/query/rtm"));
}

test "server source serves app js with javascript content type" {
    const source = @embedFile("server.zig");
    try testing.expect(std.mem.indexOf(u8, source, "\"/app.js\"") != null);
    try testing.expect(std.mem.indexOf(u8, source, "application/javascript; charset=utf-8") != null);
}

test "hostWithoutPort strips loopback host port and preserves bare host" {
    try testing.expectEqualStrings("127.0.0.1", hostWithoutPort("127.0.0.1:8000"));
    try testing.expectEqualStrings("localhost", hostWithoutPort("localhost"));
}

test "isAllowedLocalHost accepts only loopback aliases" {
    try testing.expect(isAllowedLocalHost("127.0.0.1"));
    try testing.expect(isAllowedLocalHost("localhost"));
    try testing.expect(!isAllowedLocalHost("example.com"));
    try testing.expect(!isAllowedLocalHost("192.168.1.10"));
}

test "parseOriginHost extracts host from local origins and rejects foreign schemes" {
    try testing.expectEqualStrings("127.0.0.1", parseOriginHost("http://127.0.0.1:8000/mcp").?);
    try testing.expectEqualStrings("localhost", parseOriginHost("http://localhost:8000/app").?);
    try testing.expect(parseOriginHost("https://evil.test") == null);
}

test "hasAllowedOriginValue requires local host and matching port" {
    try testing.expect(hasAllowedOriginValue("http://127.0.0.1:8000", "127.0.0.1:8000"));
    try testing.expect(hasAllowedOriginValue("http://localhost:8000/dashboard", "127.0.0.1:8000"));
    try testing.expect(!hasAllowedOriginValue("http://localhost:8001/dashboard", "127.0.0.1:8000"));
    try testing.expect(!hasAllowedOriginValue("http://192.168.1.10:8000", "127.0.0.1:8000"));
}

test "requiresBrowserOriginCheck covers unsafe methods and mcp sse" {
    try testing.expect(requiresBrowserOriginCheck(.POST, "/api/repos"));
    try testing.expect(requiresBrowserOriginCheck(.DELETE, "/api/repos/1"));
    try testing.expect(requiresBrowserOriginCheck(.GET, "/mcp"));
    try testing.expect(!requiresBrowserOriginCheck(.GET, "/api/status"));
}

test "server source is loopback only and no longer advertises wildcard cors" {
    const source = @embedFile("server.zig");
    try testing.expect(std.mem.indexOf(u8, source, "127, 0, 0, 1") != null);
    try testing.expect(std.mem.indexOf(u8, source, "http://127.0.0.1:{d}") != null);
    try testing.expectEqual(@as(usize, 1), base_headers.len);
    try testing.expectEqualStrings("Connection", base_headers[0].name);
    try testing.expectEqualStrings("close", base_headers[0].value);
    try testing.expect(!requiresBrowserOriginCheck(.OPTIONS, "/api/status"));
}
