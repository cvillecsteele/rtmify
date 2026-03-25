const std = @import("std");

const routes = @import("../routes.zig");
const request_utils = @import("request_utils.zig");
const response = @import("response.zig");
const types = @import("types.zig");

pub fn handleDelete(req_ctx: types.RequestDispatch) !void {
    const req = req_ctx.req;
    const ctx = req_ctx.ctx;
    const alloc = req_ctx.alloc;
    const path = req_ctx.path;
    const response_status = req_ctx.response_status;
    const response_bytes = req_ctx.response_bytes;

    if (std.mem.startsWith(u8, path, "/api/repos/")) {
        const idx = path["/api/repos/".len..];
        const resp = try routes.handleDeleteRepoResponse(ctx.registry, idx, alloc, ctx.alloc);
        if (resp.ok) {
            if (ctx.restart_active_workers_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.startsWith(u8, path, "/api/workbooks/")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const workbook_id = try request_utils.decodePathParam(path["/api/workbooks/".len..], alloc);
        const resp = try routes.handleDeleteWorkbookResponse(ctx.registry, workbook_id, body_bytes, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/design-bom-sync")) {
        const resp = try routes.handleDeleteDesignBomSyncResponse(ctx.registry, ctx.secure_store, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/soup-sync")) {
        const resp = try routes.handleDeleteSoupSyncResponse(ctx.registry, ctx.secure_store, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else {
        response_status.* = .not_found;
        response_bytes.* = "{\"error\":\"not found\"}".len;
        try response.send404(req);
    }
}

pub fn handlePatch(req_ctx: types.RequestDispatch) !void {
    const req = req_ctx.req;
    const ctx = req_ctx.ctx;
    const alloc = req_ctx.alloc;
    const path = req_ctx.path;
    const response_status = req_ctx.response_status;
    const response_bytes = req_ctx.response_bytes;

    if (std.mem.startsWith(u8, path, "/api/workbooks/")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const workbook_id = try request_utils.decodePathParam(path["/api/workbooks/".len..], alloc);
        const resp = try routes.handlePatchWorkbookResponse(ctx.registry, workbook_id, body_bytes, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else {
        response_status.* = .not_found;
        response_bytes.* = "{\"error\":\"not found\"}".len;
        try response.send404(req);
    }
}
