const std = @import("std");

const routes = @import("../routes.zig");
const assets = @import("assets.zig");
const get = @import("get.zig");
const mutations = @import("mutations.zig");
const policy = @import("policy.zig");
const post = @import("post.zig");
const request_utils = @import("request_utils.zig");
const response = @import("response.zig");
const security = @import("security.zig");
const types = @import("types.zig");

pub fn handleRequest(req: *std.http.Server.Request, ctx: types.ServerCtx) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = req.head.target;
    const path = request_utils.stripQuery(target);
    const method_name = @tagName(req.head.method);
    const started_ns = std.time.nanoTimestamp();
    const log_http_request = policy.shouldLogHttpRequest(req.head.method, path);
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

    security.validateLocalRequest(req) catch |e| switch (e) {
        error.ForbiddenHost => {
            const body = "{\"error\":\"forbidden_host\"}";
            response_status = .forbidden;
            response_bytes = body.len;
            try response.sendJsonWithStatus(req, body, .forbidden);
            return;
        },
        error.ForbiddenOrigin => {
            const body = "{\"error\":\"forbidden_origin\"}";
            response_status = .forbidden;
            response_bytes = body.len;
            try response.sendJsonWithStatus(req, body, .forbidden);
            return;
        },
    };

    if (req.head.method == .OPTIONS) {
        const body = "{\"error\":\"method_not_allowed\"}";
        response_status = .method_not_allowed;
        response_bytes = body.len;
        try response.sendJsonWithStatus(req, body, .method_not_allowed);
        return;
    }

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        response_status = .ok;
        response_bytes = routes.index_html.len;
        try response.sendHtml(req, routes.index_html);
        return;
    }
    if (assets.staticAssetForPath(path)) |asset| {
        response_status = .ok;
        response_bytes = asset.body.len;
        try response.sendStaticText(req, asset.body, asset.content_type);
        return;
    }

    const active_runtime_opt = ctx.registry.active_runtime;
    if (policy.requiresActiveWorkbook(req.head.method, path) and active_runtime_opt == null) {
        const body = "{\"error\":\"no_active_workbook\"}";
        response_status = .conflict;
        response_bytes = body.len;
        try response.sendJsonWithStatus(req, body, .conflict);
        return;
    }

    const access = policy.routeAccess(req.head.method, path);
    if (req.head.method != .OPTIONS and access == .requires_license and active_runtime_opt != null) {
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
            try response.sendJsonWithStatus(req, body, .forbidden);
            return;
        }
    }

    const runtime = types.RuntimeRefs{
        .active_runtime = active_runtime_opt,
        .db = if (active_runtime_opt) |runtime_ref| &runtime_ref.db else null,
        .state = if (active_runtime_opt) |runtime_ref| &runtime_ref.sync_state else null,
        .auth = if (active_runtime_opt) |runtime_ref| &runtime_ref.ingest_auth else null,
    };
    const req_ctx = types.RequestDispatch{
        .req = req,
        .ctx = ctx,
        .alloc = alloc,
        .target = target,
        .path = path,
        .runtime = runtime,
        .response_status = &response_status,
        .response_bytes = &response_bytes,
    };

    switch (req.head.method) {
        .GET => try get.handleGet(req_ctx),
        .POST => try post.handlePost(req_ctx),
        .DELETE => try mutations.handleDelete(req_ctx),
        .PATCH => try mutations.handlePatch(req_ctx),
        else => {
            response_status = .not_found;
            response_bytes = "{\"error\":\"not found\"}".len;
            try response.send404(req);
        },
    }
}
