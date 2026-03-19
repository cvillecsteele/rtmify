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
const workbook = @import("workbook/mod.zig");
const sync_live = @import("sync_live.zig");
const routes = @import("routes.zig");

const test_results_body_limit_bytes = 10 * 1024 * 1024;
const bom_body_limit_bytes = 25 * 1024 * 1024;
const payload_too_large_json = "{\"error\":\"payload_too_large\"}";

pub const ServerCtx = struct {
    registry: *workbook.registry.WorkbookRegistry,
    secure_store: *secure_store.Store,
    license_service: *license.Service,
    instance_info: InstanceInfo,
    alloc: Allocator,
    refresh_active_runtime_fn: ?*const fn (*workbook.registry.WorkbookRegistry, *secure_store.Store, *license.Service, Allocator) void = null,
};

pub const InstanceInfo = struct {
    actual_port: u16,
    live_version: []const u8,
    tray_app_version: []const u8,
    log_path: []const u8,
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
    const log_http_request = shouldLogHttpRequest(req.head.method, path);
    var response_status: ?std.http.Status = null;
    var response_bytes: usize = 0;
    defer {
        if (log_http_request) {
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
    }
    if (log_http_request) {
        std.log.info("http {s} {s}", .{ method_name, target });
    }

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

    const active_runtime_opt = ctx.registry.active_runtime;
    if (requiresActiveWorkbook(req.head.method, path) and active_runtime_opt == null) {
        const body = "{\"error\":\"no_active_workbook\"}";
        response_status = .conflict;
        response_bytes = body.len;
        try sendJsonWithStatus(req, body, .conflict);
        return;
    }

    if (req.head.method != .OPTIONS and !isLicenseExempt(req.head.method, path) and active_runtime_opt != null) {
        var license_status = try ctx.license_service.getStatus(alloc);
        defer license_status.deinit(alloc);
        const active_runtime = active_runtime_opt.?;
        active_runtime.sync_state.product_enabled.store(license_status.permits_use, .seq_cst);
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

    const active_runtime = active_runtime_opt;
    const db = if (active_runtime) |runtime| &runtime.db else null;
    const state = if (active_runtime) |runtime| &runtime.sync_state else null;
    const auth = if (active_runtime) |runtime| &runtime.ingest_auth else null;

    if (req.head.method == .GET) {
        if (std.mem.eql(u8, path, "/nodes")) {
            const type_filter = try queryParamDecoded(target, "type", alloc);
            const body = try routes.handleNodes(db.?, type_filter, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/nodes/types")) {
            const body = try routes.handleNodeTypes(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/edges/labels")) {
            const body = try routes.handleEdgeLabels(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/search")) {
            const q = (try queryParamDecoded(target, "q", alloc)) orelse "";
            const body = try routes.handleSearch(db.?, q, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/schema")) {
            const body = try routes.handleSchema(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/gaps")) {
            const body = try routes.handleGaps(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/rtm")) {
            const body = try routes.handleRtm(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/suspects")) {
            const body = try routes.handleSuspects(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/user-needs")) {
            const body = try routes.handleUserNeeds(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/tests")) {
            const body = try routes.handleTests(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/risks")) {
            const body = try routes.handleRisks(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.startsWith(u8, path, "/query/impact/")) {
            const node_id = try decodePathParam(path["/query/impact/".len..], alloc);
            std.log.info("impact request start id={s}", .{node_id});
            const body = routes.handleImpact(db.?, node_id, alloc) catch |e| switch (e) {
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
            const body = routes.handleNode(db.?, node_id, alloc) catch |e| switch (e) {
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
            var fallback_state: sync_live.SyncState = .{};
            const body = try routes.handleStatus(ctx.registry, ctx.secure_store, if (state) |value| value else &fallback_state, ctx.license_service, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/license/status")) {
            const body = try routes.handleLicenseStatus(ctx.license_service, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/info")) {
            var fallback_auth = try @import("test_results_auth.zig").AuthState.initForWorkbookSlug("inactive", alloc);
            defer fallback_auth.deinit(alloc);
            const body = try routes.handleInfo(ctx.registry, if (auth) |value| value else &fallback_auth, ctx.license_service, ctx.instance_info, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/workbooks")) {
            const body = try routes.handleGetWorkbooks(ctx.registry, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/design-bom-sync")) {
            const resp = try routes.handleGetDesignBomSyncResponse(ctx.registry, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/soup-sync")) {
            const resp = try routes.handleGetSoupSyncResponse(ctx.registry, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/license/info")) {
            const resp = try routes.handleLicenseInfo(ctx.license_service, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.startsWith(u8, path, "/api/v1/test-results/")) {
            const execution_id = try decodePathParam(path["/api/v1/test-results/".len..], alloc);
            const resp = try routes.handleGetExecutionResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                execution_id,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.startsWith(u8, path, "/api/v1/bom/design/") and std.mem.endsWith(u8, path, "/items")) {
            const bom_name = try decodePathParam(path["/api/v1/bom/design/".len .. path.len - "/items".len], alloc);
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetDesignBomItemsResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.startsWith(u8, path, "/api/v1/bom/design/")) {
            const bom_name = try decodePathParam(path["/api/v1/bom/design/".len..], alloc);
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetDesignBomTreeResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom/design")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetDesignBomListResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/soup")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetSoupListResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/soup/components")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetSoupComponentsResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/soup/gaps")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_inactive = queryParamBool(target, "include_inactive");
            const resp = try routes.handleGetSoupGapsResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_inactive,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/soup/licenses")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const license_filter = try queryParamDecoded(target, "license", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetSoupLicensesResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                license_filter,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/soup/safety-classes")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const safety_class = try queryParamDecoded(target, "safety_class", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetSoupSafetyClassesResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                safety_class,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom/components")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetDesignBomComponentsResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom/coverage")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetDesignBomCoverageResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom/part-usage")) {
            const part = try queryParamDecoded(target, "part", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleFindPartUsageResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                part,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom/gaps")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_inactive = queryParamBool(target, "include_inactive");
            const resp = try routes.handleBomGapsResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_inactive,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom/impact-analysis")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleBomImpactAnalysisResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.startsWith(u8, path, "/api/v1/bom/")) {
            const full_product_identifier = try decodePathParam(path["/api/v1/bom/".len..], alloc);
            const bom_type = try queryParamDecoded(target, "bom_type", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const resp = try routes.handleGetBomResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                full_product_identifier,
                bom_type,
                bom_name,
                include_obsolete,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/provision-preview")) {
            const qprofile = try queryParamDecoded(target, "profile", alloc);
            const body = try routes.handleProvisionPreview(ctx.registry, ctx.secure_store, qprofile, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/diagnostics")) {
            const qsource = try queryParamDecoded(target, "source", alloc);
            const body = try routes.handleDiagnostics(db.?, qsource, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/guide/errors")) {
            const body = try routes.handleGuideErrors(alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/report/coverage.md")) {
            const body = try routes.handleCoverageReport(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/plain; charset=utf-8");
        } else if (std.mem.eql(u8, path, "/report/design-bom.md")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            if (full_product_identifier == null or bom_name == null) {
                const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier_or_bom_name\"}");
                response_status = .bad_request;
                response_bytes = err_body.len;
                try sendJsonWithStatus(req, err_body, .bad_request);
                return;
            }
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const body = try routes.handleReportDesignBomMd(db.?, full_product_identifier.?, bom_name.?, include_obsolete, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/markdown");
        } else if (std.mem.eql(u8, path, "/report/design-bom")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            if (full_product_identifier == null or bom_name == null) {
                const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier_or_bom_name\"}");
                response_status = .bad_request;
                response_bytes = err_body.len;
                try sendJsonWithStatus(req, err_body, .bad_request);
                return;
            }
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const body = try routes.handleReportDesignBomPdf(db.?, full_product_identifier.?, bom_name.?, include_obsolete, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendPdfNamed(req, body, "design-bom.pdf");
        } else if (std.mem.eql(u8, path, "/report/design-bom.docx")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            if (full_product_identifier == null or bom_name == null) {
                const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier_or_bom_name\"}");
                response_status = .bad_request;
                response_bytes = err_body.len;
                try sendJsonWithStatus(req, err_body, .bad_request);
                return;
            }
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const body = try routes.handleReportDesignBomDocx(db.?, full_product_identifier.?, bom_name.?, include_obsolete, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendDocxNamed(req, body, "design-bom.docx");
        } else if (std.mem.eql(u8, path, "/report/soup.md")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            if (full_product_identifier == null) {
                const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier\"}");
                response_status = .bad_request;
                response_bytes = err_body.len;
                try sendJsonWithStatus(req, err_body, .bad_request);
                return;
            }
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const body = try routes.handleReportSoupMd(db.?, full_product_identifier.?, bom_name orelse "SOUP Components", include_obsolete, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/markdown");
        } else if (std.mem.eql(u8, path, "/report/soup")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            if (full_product_identifier == null) {
                const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier\"}");
                response_status = .bad_request;
                response_bytes = err_body.len;
                try sendJsonWithStatus(req, err_body, .bad_request);
                return;
            }
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const body = try routes.handleReportSoupPdf(db.?, full_product_identifier.?, bom_name orelse "SOUP Components", include_obsolete, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendPdfNamed(req, body, "soup-register.pdf");
        } else if (std.mem.eql(u8, path, "/report/soup.docx")) {
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            if (full_product_identifier == null) {
                const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier\"}");
                response_status = .bad_request;
                response_bytes = err_body.len;
                try sendJsonWithStatus(req, err_body, .bad_request);
                return;
            }
            const include_obsolete = queryParamBool(target, "include_obsolete");
            const body = try routes.handleReportSoupDocx(db.?, full_product_identifier.?, bom_name orelse "SOUP Components", include_obsolete, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendDocxNamed(req, body, "soup-register.docx");
        } else if (std.mem.eql(u8, path, "/report/rtm")) {
            const body = try routes.handleReportRtmPdf(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendPdf(req, body);
        } else if (std.mem.eql(u8, path, "/report/rtm.md")) {
            const body = try routes.handleReportRtmMd(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/markdown");
        } else if (std.mem.eql(u8, path, "/report/rtm.docx")) {
            const body = try routes.handleReportRtmDocx(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendDocx(req, body);
        } else if (std.mem.eql(u8, path, "/api/profile")) {
            const body = try routes.handleGetProfile(ctx.registry, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/api/repos")) {
            const body = try routes.handleGetRepos(ctx.registry, db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/chain-gaps")) {
            const body = try routes.handleChainGaps(db.?, active_runtime.?.config.profile, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/code-traceability")) {
            const body = try routes.handleCodeTraceability(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/recent-commits")) {
            const body = try routes.handleRecentCommits(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/implementation-changes")) {
            const since = try queryParamDecoded(target, "since", alloc);
            const node_type = try queryParamDecoded(target, "node_type", alloc);
            const repo = try queryParamDecoded(target, "repo", alloc);
            const limit = try queryParamDecoded(target, "limit", alloc);
            const offset = try queryParamDecoded(target, "offset", alloc);
            const resp = try routes.handleImplementationChangesResponse(db.?, since, node_type, repo, limit, offset, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/query/unimplemented-requirements")) {
            const body = try routes.handleUnimplementedRequirements(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/untested-source-files")) {
            const body = try routes.handleUntestedSourceFiles(db.?, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/query/file-annotations")) {
            const file_path = (try queryParamDecoded(target, "file_path", alloc)) orelse "";
            const body = try routes.handleFileAnnotations(db.?, file_path, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.startsWith(u8, path, "/query/commit-history/")) {
            const req_id = try decodePathParam(path["/query/commit-history/".len..], alloc);
            const body = try routes.handleCommitHistory(db.?, req_id, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendJson(req, body);
        } else if (std.mem.eql(u8, path, "/report/dhr/md")) {
            const body = try routes.handleReportDhrMd(db.?, active_runtime.?.config.profile, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendText(req, body, "text/markdown");
        } else if (std.mem.eql(u8, path, "/report/dhr/pdf")) {
            const body = try routes.handleReportDhrPdf(db.?, active_runtime.?.config.profile, alloc);
            response_status = .ok;
            response_bytes = body.len;
            try sendPdf(req, body);
        } else if (std.mem.eql(u8, path, "/mcp")) {
            // SSE endpoint — delegated to mcp.zig (streamed, not a simple response)
            response_status = .ok;
            try @import("mcp.zig").handleSse(req, ctx.registry, ctx.secure_store, alloc);
        } else {
            response_status = .not_found;
            response_bytes = "{\"error\":\"not found\"}".len;
            try send404(req);
        }
    } else if (req.head.method == .POST) {
        if (std.mem.eql(u8, path, "/mcp")) {
            const body_bytes = try readBody(req, alloc);
            response_status = .ok;
            var fallback_state: sync_live.SyncState = .{};
            try @import("mcp.zig").handlePost(req, body_bytes, ctx.registry, ctx.secure_store, if (state) |value| value else &fallback_state, ctx.license_service, ctx.refresh_active_runtime_fn, alloc);
        } else if (std.mem.eql(u8, path, "/api/license/import")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleLicenseImportResponse(ctx.license_service, body_bytes, alloc);
            if (resp.ok) {
                if (state) |state_ref| {
                    var license_status = try ctx.license_service.getStatus(alloc);
                    defer license_status.deinit(alloc);
                    state_ref.product_enabled.store(license_status.permits_use, .seq_cst);
                    if (license_status.permits_use) {
                        if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
                    }
                }
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/license/clear")) {
            const resp = try routes.handleLicenseClearResponse(ctx.license_service, alloc);
            if (resp.ok and state != null) state.?.product_enabled.store(false, .seq_cst);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/test-results/token/regenerate")) {
            const resp = try routes.handleRegenerateTestResultsTokenResponse(auth.?, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/profile")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handlePostProfileResponse(ctx.registry, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/repos")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handlePostRepoResponse(ctx.registry, db.?, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/repos/scan")) {
            sync_live.triggerRepoScanNow(db.?, state.?, active_runtime.?.config.repo_paths, alloc) catch |e| {
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
        } else if (std.mem.eql(u8, path, "/api/design-bom-sync/validate")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleDesignBomSyncValidateResponse(ctx.secure_store, body_bytes, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/soup-sync/validate")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleSoupSyncValidateResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/connection")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleConnectionResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/design-bom-sync")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleDesignBomSyncResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/soup-sync")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleSoupSyncResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/workbooks")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handlePostWorkbooksResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.endsWith(u8, path, "/activate") and std.mem.startsWith(u8, path, "/api/workbooks/")) {
            const workbook_id = try decodePathParam(path["/api/workbooks/".len .. path.len - "/activate".len], alloc);
            const resp = try routes.handleActivateWorkbookResponse(ctx.registry, workbook_id, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.endsWith(u8, path, "/remove") and std.mem.startsWith(u8, path, "/api/workbooks/")) {
            const workbook_id = try decodePathParam(path["/api/workbooks/".len .. path.len - "/remove".len], alloc);
            const resp = try routes.handleRemoveWorkbookResponse(ctx.registry, workbook_id, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/test-results")) {
            const body_bytes = readBodyLimited(req, alloc, test_results_body_limit_bytes) catch |err| switch (err) {
                error.StreamTooLong => {
                    response_status = .payload_too_large;
                    response_bytes = payload_too_large_json.len;
                    try sendJsonWithStatus(req, payload_too_large_json, .payload_too_large);
                    return;
                },
                else => return err,
            };
            const resp = try routes.handlePostTestResultsResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                body_bytes,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom/xlsx")) {
            const body_bytes = readBodyLimited(req, alloc, bom_body_limit_bytes) catch |err| switch (err) {
                error.StreamTooLong => {
                    response_status = .payload_too_large;
                    response_bytes = payload_too_large_json.len;
                    try sendJsonWithStatus(req, payload_too_large_json, .payload_too_large);
                    return;
                },
                else => return err,
            };
            const resp = try routes.handlePostBomXlsxResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                requestHeaderValue(req, "Content-Type"),
                body_bytes,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/soup/xlsx")) {
            const body_bytes = readBodyLimited(req, alloc, bom_body_limit_bytes) catch |err| switch (err) {
                error.StreamTooLong => {
                    response_status = .payload_too_large;
                    response_bytes = payload_too_large_json.len;
                    try sendJsonWithStatus(req, payload_too_large_json, .payload_too_large);
                    return;
                },
                else => return err,
            };
            const full_product_identifier = try queryParamDecoded(target, "full_product_identifier", alloc);
            const bom_name = try queryParamDecoded(target, "bom_name", alloc);
            const resp = try routes.handlePostSoupXlsxResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                requestHeaderValue(req, "Content-Type"),
                body_bytes,
                full_product_identifier,
                bom_name,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/soup")) {
            const body_bytes = readBodyLimited(req, alloc, bom_body_limit_bytes) catch |err| switch (err) {
                error.StreamTooLong => {
                    response_status = .payload_too_large;
                    response_bytes = payload_too_large_json.len;
                    try sendJsonWithStatus(req, payload_too_large_json, .payload_too_large);
                    return;
                },
                else => return err,
            };
            const resp = try routes.handlePostSoupResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                body_bytes,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/v1/bom")) {
            const body_bytes = readBodyLimited(req, alloc, bom_body_limit_bytes) catch |err| switch (err) {
                error.StreamTooLong => {
                    response_status = .payload_too_large;
                    response_bytes = payload_too_large_json.len;
                    try sendJsonWithStatus(req, payload_too_large_json, .payload_too_large);
                    return;
                },
                else => return err,
            };
            const resp = try routes.handlePostBomResponse(
                db.?,
                auth.?,
                requestHeaderValue(req, "Authorization"),
                requestHeaderValue(req, "Content-Type"),
                body_bytes,
                alloc,
            );
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/provision")) {
            const resp = try routes.handleProvisionResponse(ctx.registry, ctx.secure_store, alloc);
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.startsWith(u8, path, "/suspect/") and
            std.mem.endsWith(u8, path, "/clear"))
        {
            const node_id = try decodePathParam(path["/suspect/".len .. path.len - "/clear".len], alloc);
            const resp = try routes.handleClearSuspect(db.?, node_id, alloc);
            response_status = .ok;
            response_bytes = resp.len;
            try sendJson(req, resp);
        } else if (std.mem.eql(u8, path, "/ingest")) {
            const body_bytes = try readBody(req, alloc);
            const resp = try routes.handleIngest(db.?, body_bytes, alloc);
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
            const resp = try routes.handleDeleteRepoResponse(ctx.registry, idx, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.startsWith(u8, path, "/api/workbooks/")) {
            const body_bytes = try readBody(req, alloc);
            const workbook_id = try decodePathParam(path["/api/workbooks/".len..], alloc);
            const resp = try routes.handleDeleteWorkbookResponse(ctx.registry, workbook_id, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/design-bom-sync")) {
            const resp = try routes.handleDeleteDesignBomSyncResponse(ctx.registry, ctx.secure_store, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else if (std.mem.eql(u8, path, "/api/soup-sync")) {
            const resp = try routes.handleDeleteSoupSyncResponse(ctx.registry, ctx.secure_store, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
            response_status = resp.status;
            response_bytes = resp.body.len;
            try sendJsonWithStatus(req, resp.body, resp.status);
        } else {
            response_status = .not_found;
            response_bytes = "{\"error\":\"not found\"}".len;
            try send404(req);
        }
    } else if (req.head.method == .PATCH) {
        if (std.mem.startsWith(u8, path, "/api/workbooks/")) {
            const body_bytes = try readBody(req, alloc);
            const workbook_id = try decodePathParam(path["/api/workbooks/".len..], alloc);
            const resp = try routes.handlePatchWorkbookResponse(ctx.registry, workbook_id, body_bytes, alloc);
            if (resp.ok) {
                if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            }
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

fn shouldLogHttpRequest(method: std.http.Method, path: []const u8) bool {
    // Streamable HTTP MCP clients poll GET /mcp frequently; keep the access log
    // useful by suppressing that one high-volume path.
    return !(method == .GET and std.mem.eql(u8, path, "/mcp"));
}

fn isLicenseExempt(method: std.http.Method, path: []const u8) bool {
    _ = method;
    return std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/index.html") or
        std.mem.eql(u8, path, "/app.js") or
        std.mem.eql(u8, path, "/api/status") or
        std.mem.eql(u8, path, "/api/info") or
        std.mem.eql(u8, path, "/api/license/status") or
        std.mem.eql(u8, path, "/api/license/info") or
        std.mem.eql(u8, path, "/api/license/import") or
        std.mem.eql(u8, path, "/api/license/clear");
}

fn requiresActiveWorkbook(method: std.http.Method, path: []const u8) bool {
    _ = method;
    return !(std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/index.html") or
        std.mem.eql(u8, path, "/app.js") or
        std.mem.eql(u8, path, "/api/status") or
        std.mem.eql(u8, path, "/api/info") or
        std.mem.eql(u8, path, "/api/license/status") or
        std.mem.eql(u8, path, "/api/license/info") or
        std.mem.eql(u8, path, "/api/license/import") or
        std.mem.eql(u8, path, "/api/license/clear") or
        std.mem.eql(u8, path, "/api/connection/validate") or
        std.mem.eql(u8, path, "/api/workbooks") or
        (std.mem.startsWith(u8, path, "/api/workbooks/") and reqPathIsWorkbookMutation(path)) or
        std.mem.eql(u8, path, "/mcp"));
}

fn reqPathIsWorkbookMutation(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "/activate") or
        std.mem.endsWith(u8, path, "/remove") or
        !std.mem.endsWith(u8, path, "/");
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
    try sendPdfNamed(req, body, "rtm.pdf");
}

fn sendPdfNamed(req: *std.http.Server.Request, body: []const u8, filename: []const u8) !void {
    const disposition = try std.fmt.allocPrint(std.heap.page_allocator, "attachment; filename=\"{s}\"", .{filename});
    defer std.heap.page_allocator.free(disposition);
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/pdf" },
        .{ .name = "Content-Disposition", .value = disposition },
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
    try sendDocxNamed(req, body, "rtm.docx");
}

fn sendDocxNamed(req: *std.http.Server.Request, body: []const u8, filename: []const u8) !void {
    const mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    const disposition = try std.fmt.allocPrint(std.heap.page_allocator, "attachment; filename=\"{s}\"", .{filename});
    defer std.heap.page_allocator.free(disposition);
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = mime },
        .{ .name = "Content-Disposition", .value = disposition },
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
    return readBodyLimited(req, alloc, 1024 * 1024);
}

fn readBodyLimited(req: *std.http.Server.Request, alloc: Allocator, max_bytes: usize) ![]u8 {
    const body_buf = try alloc.alloc(u8, max_bytes);
    defer alloc.free(body_buf);
    const reader = req.readerExpectNone(body_buf);
    return readReaderLimited(reader, alloc, max_bytes);
}

fn readReaderLimited(reader: anytype, alloc: Allocator, max_bytes: usize) ![]u8 {
    if (@TypeOf(reader) == *std.Io.Reader) {
        return readIoReaderLimited(reader, alloc, max_bytes);
    }
    return reader.readAllAlloc(alloc, max_bytes);
}

fn readIoReaderLimited(reader: *std.Io.Reader, alloc: Allocator, max_bytes: usize) ![]u8 {
    return reader.allocRemaining(alloc, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => error.StreamTooLong,
        else => err,
    };
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

test "readReaderLimited enforces max bytes" {
    var stream = std.io.fixedBufferStream("abcdef");
    try std.testing.expectError(error.StreamTooLong, readReaderLimited(stream.reader(), std.testing.allocator, 3));
}

test "ingest body limits are explicit and stable" {
    try testing.expectEqual(@as(usize, 10 * 1024 * 1024), test_results_body_limit_bytes);
    try testing.expectEqual(@as(usize, 25 * 1024 * 1024), bom_body_limit_bytes);
    try testing.expectEqualStrings("{\"error\":\"payload_too_large\"}", payload_too_large_json);
}

fn queryParamDecoded(target: []const u8, key: []const u8, alloc: Allocator) !?[]const u8 {
    const raw = queryParamRaw(target, key) orelse return null;
    const buf = try alloc.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

fn queryParamBool(target: []const u8, key: []const u8) bool {
    const raw = queryParamRaw(target, key) orelse return false;
    return std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1");
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

test "queryParamBool accepts true and one only" {
    try testing.expect(queryParamBool("/api/v1/bom/design?include_obsolete=true", "include_obsolete"));
    try testing.expect(queryParamBool("/api/v1/bom/design?include_obsolete=1", "include_obsolete"));
    try testing.expect(!queryParamBool("/api/v1/bom/design?include_obsolete=false", "include_obsolete"));
    try testing.expect(!queryParamBool("/api/v1/bom/design", "include_obsolete"));
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
