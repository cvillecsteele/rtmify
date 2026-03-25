const std = @import("std");

const routes = @import("../routes.zig");
const mcp = @import("../mcp.zig");
const sync_live = @import("../sync_live.zig");
const test_results_auth = @import("../test_results_auth.zig");
const request_utils = @import("request_utils.zig");
const response = @import("response.zig");
const types = @import("types.zig");

pub fn handleGet(req_ctx: types.RequestDispatch) !void {
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

    if (std.mem.eql(u8, path, "/nodes")) {
        const type_filter = try request_utils.queryParamDecoded(target, "type", alloc);
        const body = try routes.handleNodes(db.?, type_filter, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/nodes/types")) {
        const body = try routes.handleNodeTypes(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/edges/labels")) {
        const body = try routes.handleEdgeLabels(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/search")) {
        const q = (try request_utils.queryParamDecoded(target, "q", alloc)) orelse "";
        const body = try routes.handleSearch(db.?, q, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/schema")) {
        const body = try routes.handleSchema(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/gaps")) {
        const body = try routes.handleGaps(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/rtm")) {
        const body = try routes.handleRtm(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/suspects")) {
        const body = try routes.handleSuspects(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/user-needs")) {
        const body = try routes.handleUserNeeds(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/tests")) {
        const body = try routes.handleTests(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/risks")) {
        const body = try routes.handleRisks(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.startsWith(u8, path, "/query/impact/")) {
        const node_id = try request_utils.decodePathParam(path["/query/impact/".len..], alloc);
        std.log.info("impact request start id={s}", .{node_id});
        const body = routes.handleImpact(db.?, node_id, alloc) catch |e| switch (e) {
            error.NotFound => {
                std.log.warn("impact request not found id={s}", .{node_id});
                const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"node not found\",\"id\":\"{s}\"}}", .{node_id});
                response_status.* = .not_found;
                response_bytes.* = err_body.len;
                try response.sendJsonWithStatus(req, err_body, .not_found);
                return;
            },
            else => {
                std.log.err("impact request failed id={s}: {s}", .{ node_id, @errorName(e) });
                return e;
            },
        };
        std.log.info("impact request ok id={s} bytes={d}", .{ node_id, body.len });
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.startsWith(u8, path, "/query/node/")) {
        const node_id = try request_utils.decodePathParam(path["/query/node/".len..], alloc);
        const body = routes.handleNode(db.?, node_id, alloc) catch |e| switch (e) {
            error.NotFound => {
                const err_body = try std.fmt.allocPrint(alloc, "{{\"error\":\"node not found\",\"id\":\"{s}\"}}", .{node_id});
                response_status.* = .not_found;
                response_bytes.* = err_body.len;
                try response.sendJsonWithStatus(req, err_body, .not_found);
                return;
            },
            else => return e,
        };
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/status")) {
        var fallback_state: sync_live.SyncState = .{};
        const body = try routes.handleStatus(ctx.registry, ctx.secure_store, if (state) |value| value else &fallback_state, ctx.license_service, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/license/status")) {
        const body = try routes.handleLicenseStatus(ctx.license_service, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/info")) {
        var fallback_auth = try test_results_auth.AuthState.initForWorkbookSlug("inactive", alloc);
        defer fallback_auth.deinit(alloc);
        const body = try routes.handleInfo(ctx.registry, if (auth) |value| value else &fallback_auth, ctx.license_service, ctx.instance_info, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/workbooks")) {
        const body = try routes.handleGetWorkbooks(ctx.registry, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/design-bom-sync")) {
        const resp = try routes.handleGetDesignBomSyncResponse(ctx.registry, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/soup-sync")) {
        const resp = try routes.handleGetSoupSyncResponse(ctx.registry, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/license/info")) {
        const resp = try routes.handleLicenseInfo(ctx.license_service, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.startsWith(u8, path, "/api/v1/test-results/")) {
        const execution_id = try request_utils.decodePathParam(path["/api/v1/test-results/".len..], alloc);
        const resp = try routes.handleGetExecutionResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            execution_id,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.startsWith(u8, path, "/api/v1/bom/design/") and std.mem.endsWith(u8, path, "/items")) {
        const bom_name = try request_utils.decodePathParam(path["/api/v1/bom/design/".len .. path.len - "/items".len], alloc);
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetDesignBomItemsResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.startsWith(u8, path, "/api/v1/bom/design/")) {
        const bom_name = try request_utils.decodePathParam(path["/api/v1/bom/design/".len..], alloc);
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetDesignBomTreeResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom/design")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetDesignBomListResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/soup")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetSoupListResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/soup/components")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetSoupComponentsResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/soup/gaps")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_inactive = request_utils.queryParamBool(target, "include_inactive");
        const resp = try routes.handleGetSoupGapsResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_inactive,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/soup/licenses")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const license_filter = try request_utils.queryParamDecoded(target, "license", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetSoupLicensesResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            license_filter,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/soup/safety-classes")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const safety_class = try request_utils.queryParamDecoded(target, "safety_class", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetSoupSafetyClassesResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            safety_class,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/design-artifacts")) {
        const resp = try routes.handleListArtifactsResponse(db.?, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.startsWith(u8, path, "/api/v1/design-artifacts/")) {
        const artifact_id = try request_utils.decodePathParam(path["/api/v1/design-artifacts/".len..], alloc);
        const resp = try routes.handleGetArtifactResponse(db.?, artifact_id, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom/components")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetDesignBomComponentsResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom/coverage")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetDesignBomCoverageResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom/part-usage")) {
        const part = try request_utils.queryParamDecoded(target, "part", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleFindPartUsageResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            part,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom/gaps")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_inactive = request_utils.queryParamBool(target, "include_inactive");
        const resp = try routes.handleBomGapsResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_inactive,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/v1/bom/impact-analysis")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleBomImpactAnalysisResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.startsWith(u8, path, "/api/v1/bom/")) {
        const full_product_identifier = try request_utils.decodePathParam(path["/api/v1/bom/".len..], alloc);
        const bom_type = try request_utils.queryParamDecoded(target, "bom_type", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const resp = try routes.handleGetBomResponse(
            db.?,
            auth.?,
            request_utils.requestHeaderValue(req, "Authorization"),
            full_product_identifier,
            bom_type,
            bom_name,
            include_obsolete,
            alloc,
        );
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/api/provision-preview")) {
        const qprofile = try request_utils.queryParamDecoded(target, "profile", alloc);
        const body = try routes.handleProvisionPreview(ctx.registry, ctx.secure_store, qprofile, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/diagnostics")) {
        const qsource = try request_utils.queryParamDecoded(target, "source", alloc);
        const body = try routes.handleDiagnostics(db.?, qsource, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/guide/errors")) {
        const body = try routes.handleGuideErrors(alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/report/coverage.md")) {
        const body = try routes.handleCoverageReport(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendText(req, body, "text/plain; charset=utf-8");
    } else if (std.mem.eql(u8, path, "/report/design-bom.md")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        if (full_product_identifier == null or bom_name == null) {
            const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier_or_bom_name\"}");
            response_status.* = .bad_request;
            response_bytes.* = err_body.len;
            try response.sendJsonWithStatus(req, err_body, .bad_request);
            return;
        }
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const body = try routes.handleReportDesignBomMd(db.?, full_product_identifier.?, bom_name.?, include_obsolete, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendText(req, body, "text/markdown");
    } else if (std.mem.eql(u8, path, "/report/design-bom")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        if (full_product_identifier == null or bom_name == null) {
            const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier_or_bom_name\"}");
            response_status.* = .bad_request;
            response_bytes.* = err_body.len;
            try response.sendJsonWithStatus(req, err_body, .bad_request);
            return;
        }
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const body = try routes.handleReportDesignBomPdf(db.?, full_product_identifier.?, bom_name.?, include_obsolete, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendPdfNamed(req, body, "design-bom.pdf");
    } else if (std.mem.eql(u8, path, "/report/design-bom.docx")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        if (full_product_identifier == null or bom_name == null) {
            const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier_or_bom_name\"}");
            response_status.* = .bad_request;
            response_bytes.* = err_body.len;
            try response.sendJsonWithStatus(req, err_body, .bad_request);
            return;
        }
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const body = try routes.handleReportDesignBomDocx(db.?, full_product_identifier.?, bom_name.?, include_obsolete, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendDocxNamed(req, body, "design-bom.docx");
    } else if (std.mem.eql(u8, path, "/report/soup.md")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        if (full_product_identifier == null) {
            const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier\"}");
            response_status.* = .bad_request;
            response_bytes.* = err_body.len;
            try response.sendJsonWithStatus(req, err_body, .bad_request);
            return;
        }
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const body = try routes.handleReportSoupMd(db.?, full_product_identifier.?, bom_name orelse "SOUP Components", include_obsolete, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendText(req, body, "text/markdown");
    } else if (std.mem.eql(u8, path, "/report/soup")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        if (full_product_identifier == null) {
            const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier\"}");
            response_status.* = .bad_request;
            response_bytes.* = err_body.len;
            try response.sendJsonWithStatus(req, err_body, .bad_request);
            return;
        }
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const body = try routes.handleReportSoupPdf(db.?, full_product_identifier.?, bom_name orelse "SOUP Components", include_obsolete, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendPdfNamed(req, body, "soup-register.pdf");
    } else if (std.mem.eql(u8, path, "/report/soup.docx")) {
        const full_product_identifier = try request_utils.queryParamDecoded(target, "full_product_identifier", alloc);
        const bom_name = try request_utils.queryParamDecoded(target, "bom_name", alloc);
        if (full_product_identifier == null) {
            const err_body = try alloc.dupe(u8, "{\"error\":\"missing_full_product_identifier\"}");
            response_status.* = .bad_request;
            response_bytes.* = err_body.len;
            try response.sendJsonWithStatus(req, err_body, .bad_request);
            return;
        }
        const include_obsolete = request_utils.queryParamBool(target, "include_obsolete");
        const body = try routes.handleReportSoupDocx(db.?, full_product_identifier.?, bom_name orelse "SOUP Components", include_obsolete, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendDocxNamed(req, body, "soup-register.docx");
    } else if (std.mem.eql(u8, path, "/report/rtm")) {
        const body = try routes.handleReportRtmPdf(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendPdf(req, body);
    } else if (std.mem.eql(u8, path, "/report/rtm.md")) {
        const body = try routes.handleReportRtmMd(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendText(req, body, "text/markdown");
    } else if (std.mem.eql(u8, path, "/report/rtm.docx")) {
        const body = try routes.handleReportRtmDocx(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendDocx(req, body);
    } else if (std.mem.eql(u8, path, "/api/profile")) {
        const body = try routes.handleGetProfile(ctx.registry, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/api/repos")) {
        const body = try routes.handleGetRepos(ctx.registry, db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/chain-gaps")) {
        const body = try routes.handleChainGaps(db.?, active_runtime.?.config.profile, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/code-traceability")) {
        const body = try routes.handleCodeTraceability(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/recent-commits")) {
        const body = try routes.handleRecentCommits(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/implementation-changes")) {
        const since = try request_utils.queryParamDecoded(target, "since", alloc);
        const node_type = try request_utils.queryParamDecoded(target, "node_type", alloc);
        const repo = try request_utils.queryParamDecoded(target, "repo", alloc);
        const limit = try request_utils.queryParamDecoded(target, "limit", alloc);
        const offset = try request_utils.queryParamDecoded(target, "offset", alloc);
        const resp = try routes.handleImplementationChangesResponse(db.?, since, node_type, repo, limit, offset, alloc);
        response_status.* = resp.status;
        response_bytes.* = resp.body.len;
        try response.sendJsonWithStatus(req, resp.body, resp.status);
    } else if (std.mem.eql(u8, path, "/query/unimplemented-requirements")) {
        const body = try routes.handleUnimplementedRequirements(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/untested-source-files")) {
        const body = try routes.handleUntestedSourceFiles(db.?, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/query/file-annotations")) {
        const file_path = (try request_utils.queryParamDecoded(target, "file_path", alloc)) orelse "";
        const body = try routes.handleFileAnnotations(db.?, file_path, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.startsWith(u8, path, "/query/commit-history/")) {
        const req_id = try request_utils.decodePathParam(path["/query/commit-history/".len..], alloc);
        const body = try routes.handleCommitHistory(db.?, req_id, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendJson(req, body);
    } else if (std.mem.eql(u8, path, "/report/dhr/md")) {
        const body = try routes.handleReportDhrMd(db.?, active_runtime.?.config.profile, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendText(req, body, "text/markdown");
    } else if (std.mem.eql(u8, path, "/report/dhr/pdf")) {
        const body = try routes.handleReportDhrPdf(db.?, active_runtime.?.config.profile, alloc);
        response_status.* = .ok;
        response_bytes.* = body.len;
        try response.sendPdf(req, body);
    } else if (std.mem.eql(u8, path, "/mcp")) {
        response_status.* = .ok;
        try mcp.handleSse(req, ctx.registry, ctx.secure_store, alloc);
    } else {
        response_status.* = .not_found;
        response_bytes.* = "{\"error\":\"not found\"}".len;
        try response.send404(req);
    }
}
