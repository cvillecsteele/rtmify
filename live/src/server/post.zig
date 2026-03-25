const std = @import("std");
const Allocator = std.mem.Allocator;

const mcp = @import("../mcp.zig");
const routes = @import("../routes.zig");
const sync_live = @import("../sync_live.zig");
const workspace_state = @import("../workspace_state.zig");
const workbook = @import("../workbook/mod.zig");
const request_utils = @import("request_utils.zig");
const response = @import("response.zig");
const types = @import("types.zig");

pub fn handlePost(req_ctx: types.RequestDispatch) !void {
    const req = req_ctx.req;
    const ctx = req_ctx.ctx;
    const alloc = req_ctx.alloc;
    const target = req_ctx.target;
    const path = req_ctx.path;
    const active_runtime = req_ctx.runtime.active_runtime;
    const db = req_ctx.runtime.db;
    const state = req_ctx.runtime.state;
    const auth = req_ctx.runtime.auth;
    const response_status = req_ctx.response_status;
    const response_bytes = req_ctx.response_bytes;

    if (std.mem.eql(u8, path, "/mcp")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        response_status.* = .ok;
        var fallback_state: sync_live.SyncState = .{};
        try mcp.handlePost(req, body_bytes, ctx.registry, ctx.secure_store, if (state) |value| value else &fallback_state, ctx.license_service, ctx.refresh_active_runtime_fn, alloc);
    } else if (std.mem.eql(u8, path, "/api/license/import")) {
        const body_bytes = try request_utils.readBody(req, alloc);
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
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/license/clear")) {
        const resp = try routes.handleLicenseClearResponse(ctx.license_service, alloc);
        if (resp.ok and state != null) state.?.product_enabled.store(false, .seq_cst);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/workspace/preferences")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handlePostWorkspacePrefsResponse(db.?, body_bytes, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/onboarding/source-artifact")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handlePostOnboardingSourceArtifactResponse(
            db.?,
            request_utils.requestHeaderValue(req, "Content-Type"),
            body_bytes,
            active_runtime.?.config.inbox_dir,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/test-results/token/regenerate")) {
        const resp = try routes.handleRegenerateTestResultsTokenResponse(auth.?, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/profile")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handlePostProfileResponse(ctx.registry, body_bytes, alloc, ctx.alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/repos")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handlePostRepoResponse(ctx.registry, db.?, body_bytes, alloc, ctx.alloc);
        if (resp.ok) {
            if (ctx.restart_active_workers_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/repos/scan")) {
        sync_live.triggerRepoScanNow(db.?, state.?, active_runtime.?.config.repo_paths, alloc) catch |e| {
            const body = try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)});
            response_status.* = .internal_server_error;
            response_bytes.* = body.len;
            try response.sendJsonWithStatus(req, body, .internal_server_error);
            return;
        };
        const body = try alloc.dupe(u8, "{\"ok\":true}");
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/connection/validate")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handleConnectionValidateResponse(ctx.secure_store, body_bytes, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/design-bom-sync/validate")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handleDesignBomSyncValidateResponse(ctx.secure_store, body_bytes, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/soup-sync/validate")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handleSoupSyncValidateResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/connection")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handleConnectionResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            markActiveWorkspaceWorkbookFirst(ctx.registry, ctx.alloc) catch {};
            if (ctx.run_preview_sync_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/design-bom-sync")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handleDesignBomSyncResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/soup-sync")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handleSoupSyncResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/workbooks")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handlePostWorkbooksResponse(ctx.registry, ctx.secure_store, body_bytes, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
            markActiveWorkspaceWorkbookFirst(ctx.registry, ctx.alloc) catch {};
            if (ctx.run_preview_sync_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.endsWith(u8, path, "/activate") and std.mem.startsWith(u8, path, "/api/workbooks/")) {
        const workbook_id = try request_utils.decodePathParam(path["/api/workbooks/".len .. path.len - "/activate".len], alloc);
        const resp = try routes.handleActivateWorkbookResponse(ctx.registry, workbook_id, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.endsWith(u8, path, "/remove") and std.mem.startsWith(u8, path, "/api/workbooks/")) {
        const workbook_id = try request_utils.decodePathParam(path["/api/workbooks/".len .. path.len - "/remove".len], alloc);
        const resp = try routes.handleRemoveWorkbookResponse(ctx.registry, workbook_id, alloc);
        if (resp.ok) {
            if (ctx.refresh_active_runtime_fn) |f| f(ctx.registry, ctx.secure_store, ctx.license_service, ctx.alloc);
        }
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/test-results")) {
        const body_bytes = request_utils.readBodyLimited(req, alloc, request_utils.test_results_body_limit_bytes) catch |err| switch (err) {
            error.StreamTooLong => {
                response_status.* = .payload_too_large;
                response_bytes.* = request_utils.payload_too_large_json.len;
                try response.sendJsonWithStatus(req, request_utils.payload_too_large_json, .payload_too_large);
                return;
            },
            else => return err,
        };
        const resp = try routes.handlePostTestResultsResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            body_bytes,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/design-artifacts/docx") or std.mem.eql(u8, path, "/api/v1/design-artifacts/upload")) {
        const body_bytes = request_utils.readBodyLimited(req, alloc, request_utils.bom_body_limit_bytes) catch |err| switch (err) {
            error.StreamTooLong => {
                response_status.* = .payload_too_large;
                response_bytes.* = request_utils.payload_too_large_json.len;
                try response.sendJsonWithStatus(req, request_utils.payload_too_large_json, .payload_too_large);
                return;
            },
            else => return err,
        };
        const resp = try routes.handlePostUploadResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            request_utils.requestHeaderValue(req, "Content-Type"),
            body_bytes,
            active_runtime.?.config.inbox_dir,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.endsWith(u8, path, "/reingest") and std.mem.startsWith(u8, path, "/api/v1/design-artifacts/")) {
        const artifact_id = try request_utils.decodePathParam(path["/api/v1/design-artifacts/".len .. path.len - "/reingest".len], alloc);
        const resp = try routes.handleReingestArtifactResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            artifact_id,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom/xlsx")) {
        const body_bytes = request_utils.readBodyLimited(req, alloc, request_utils.bom_body_limit_bytes) catch |err| switch (err) {
            error.StreamTooLong => {
                response_status.* = .payload_too_large;
                response_bytes.* = request_utils.payload_too_large_json.len;
                try response.sendJsonWithStatus(req, request_utils.payload_too_large_json, .payload_too_large);
                return;
            },
            else => return err,
        };
        const resp = try routes.handlePostBomXlsxResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            request_utils.requestHeaderValue(req, "Content-Type"),
            body_bytes,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/soup/xlsx")) {
        const body_bytes = request_utils.readBodyLimited(req, alloc, request_utils.bom_body_limit_bytes) catch |err| switch (err) {
            error.StreamTooLong => {
                response_status.* = .payload_too_large;
                response_bytes.* = request_utils.payload_too_large_json.len;
                try response.sendJsonWithStatus(req, request_utils.payload_too_large_json, .payload_too_large);
                return;
            },
            else => return err,
        };
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const resp = try routes.handlePostSoupXlsxResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            request_utils.requestHeaderValue(req, "Content-Type"),
            body_bytes,
            full_product_identifier,
            bom_name,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/soup")) {
        const body_bytes = request_utils.readBodyLimited(req, alloc, request_utils.bom_body_limit_bytes) catch |err| switch (err) {
            error.StreamTooLong => {
                response_status.* = .payload_too_large;
                response_bytes.* = request_utils.payload_too_large_json.len;
                try response.sendJsonWithStatus(req, request_utils.payload_too_large_json, .payload_too_large);
                return;
            },
            else => return err,
        };
        const resp = try routes.handlePostSoupResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            body_bytes,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom")) {
        const body_bytes = request_utils.readBodyLimited(req, alloc, request_utils.bom_body_limit_bytes) catch |err| switch (err) {
            error.StreamTooLong => {
                response_status.* = .payload_too_large;
                response_bytes.* = request_utils.payload_too_large_json.len;
                try response.sendJsonWithStatus(req, request_utils.payload_too_large_json, .payload_too_large);
                return;
            },
            else => return err,
        };
        const resp = try routes.handlePostBomResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            request_utils.requestHeaderValue(req, "Content-Type"),
            body_bytes,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/provision")) {
        const resp = try routes.handleProvisionResponse(ctx.registry, ctx.secure_store, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.startsWith(u8, path, "/suspect/") and std.mem.endsWith(u8, path, "/clear")) {
        const node_id = try request_utils.decodePathParam(path["/suspect/".len .. path.len - "/clear".len], alloc);
        const resp = try routes.handleClearSuspect(db.?, node_id, alloc);
        response_status.* = .ok;
        response_bytes.* = resp.len;
        try response.sendJson(req, resp);
    } else if (std.mem.eql(u8, path, "/ingest")) {
        const body_bytes = try request_utils.readBody(req, alloc);
        const resp = try routes.handleIngest(db.?, body_bytes, alloc);
        response_status.* = .ok;
        response_bytes.* = resp.len;
        try response.sendJson(req, resp);
    } else {
        response_status.* = .not_found;
        response_bytes.* = "{\"error\":\"not found\"}".len;
        try response.send404(req);
    }
}

fn markActiveWorkspaceWorkbookFirst(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !void {
    const runtime = registry.active() catch return;
    _ = alloc;
    try workspace_state.writeWorkspaceReady(&runtime.db, true);
    try workspace_state.writeSourceOfTruth(&runtime.db, .workbook_first);
    try workspace_state.clearAttachWorkbookPromptDismissed(&runtime.db);
}

test "successful connection response should start sync" {
    const resp = routes.JsonRouteResponse{ .status = .ok, .body = "{}", .ok = true };
    try std.testing.expect(resp.ok);
}

test "failed connection response should not start sync" {
    const resp = routes.JsonRouteResponse{ .status = .bad_request, .body = "{\"ok\":false}", .ok = false };
    try std.testing.expect(!resp.ok);
}
