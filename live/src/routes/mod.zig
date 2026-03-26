const shared = @import("shared.zig");
const query = @import("query.zig");
const status = @import("status.zig");
const license_routes = @import("license.zig");
const connection = @import("connection.zig");
const provision = @import("provision.zig");
const diagnostics = @import("diagnostics.zig");
const repo = @import("repo.zig");
const design_history = @import("design_history.zig");
const reports = @import("reports.zig");
const test_results = @import("test_results.zig");
const design_artifacts_api = @import("design_artifacts_api.zig");
const bom = @import("bom.zig");
const soup_api = @import("soup_api.zig");

pub const index_html = @embedFile("../static/index.html");
pub const app_js = @embedFile("../static/app.js");
pub const init_js = @embedFile("../static/modules/init.js");
pub const state_js = @embedFile("../static/modules/state.js");
pub const helpers_js = @embedFile("../static/modules/helpers.js");
pub const graph_edges_js = @embedFile("../static/modules/graph-edges.js");
pub const guide_js = @embedFile("../static/modules/guide.js");
pub const impact_js = @embedFile("../static/modules/impact.js");
pub const suspects_js = @embedFile("../static/modules/suspects.js");
pub const bom_queries_js = @embedFile("../static/modules/bom-queries.js");
pub const sync_settings_js = @embedFile("../static/modules/sync-settings.js");
pub const rtm_tables_js = @embedFile("../static/modules/rtm-tables.js");
pub const node_render_js = @embedFile("../static/modules/node-render.js");
pub const node_drawer_js = @embedFile("../static/modules/node-drawer.js");
pub const row_expand_js = @embedFile("../static/modules/row-expand.js");
pub const workbooks_js = @embedFile("../static/modules/workbooks.js");
pub const artifacts_js = @embedFile("../static/modules/artifacts.js");
pub const uploads_js = @embedFile("../static/modules/uploads.js");
pub const design_bom_js = @embedFile("../static/modules/design-bom.js");
pub const soup_js = @embedFile("../static/modules/soup.js");
pub const chain_gaps_js = @embedFile("../static/modules/chain-gaps.js");
pub const code_js = @embedFile("../static/modules/code.js");
pub const status_js = @embedFile("../static/modules/status.js");
pub const license_js = @embedFile("../static/modules/license.js");
pub const lobby_js = @embedFile("../static/modules/lobby.js");
pub const nav_js = @embedFile("../static/modules/nav.js");

pub const StaticAsset = struct {
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
};

pub const static_assets = [_]StaticAsset{
    .{ .path = "/app.js", .content_type = "application/javascript; charset=utf-8", .body = app_js },
    .{ .path = "/modules/init.js", .content_type = "application/javascript; charset=utf-8", .body = init_js },
    .{ .path = "/modules/state.js", .content_type = "application/javascript; charset=utf-8", .body = state_js },
    .{ .path = "/modules/helpers.js", .content_type = "application/javascript; charset=utf-8", .body = helpers_js },
    .{ .path = "/modules/graph-edges.js", .content_type = "application/javascript; charset=utf-8", .body = graph_edges_js },
    .{ .path = "/modules/guide.js", .content_type = "application/javascript; charset=utf-8", .body = guide_js },
    .{ .path = "/modules/impact.js", .content_type = "application/javascript; charset=utf-8", .body = impact_js },
    .{ .path = "/modules/suspects.js", .content_type = "application/javascript; charset=utf-8", .body = suspects_js },
    .{ .path = "/modules/bom-queries.js", .content_type = "application/javascript; charset=utf-8", .body = bom_queries_js },
    .{ .path = "/modules/sync-settings.js", .content_type = "application/javascript; charset=utf-8", .body = sync_settings_js },
    .{ .path = "/modules/rtm-tables.js", .content_type = "application/javascript; charset=utf-8", .body = rtm_tables_js },
    .{ .path = "/modules/node-render.js", .content_type = "application/javascript; charset=utf-8", .body = node_render_js },
    .{ .path = "/modules/node-drawer.js", .content_type = "application/javascript; charset=utf-8", .body = node_drawer_js },
    .{ .path = "/modules/row-expand.js", .content_type = "application/javascript; charset=utf-8", .body = row_expand_js },
    .{ .path = "/modules/workbooks.js", .content_type = "application/javascript; charset=utf-8", .body = workbooks_js },
    .{ .path = "/modules/artifacts.js", .content_type = "application/javascript; charset=utf-8", .body = artifacts_js },
    .{ .path = "/modules/uploads.js", .content_type = "application/javascript; charset=utf-8", .body = uploads_js },
    .{ .path = "/modules/design-bom.js", .content_type = "application/javascript; charset=utf-8", .body = design_bom_js },
    .{ .path = "/modules/soup.js", .content_type = "application/javascript; charset=utf-8", .body = soup_js },
    .{ .path = "/modules/chain-gaps.js", .content_type = "application/javascript; charset=utf-8", .body = chain_gaps_js },
    .{ .path = "/modules/code.js", .content_type = "application/javascript; charset=utf-8", .body = code_js },
    .{ .path = "/modules/status.js", .content_type = "application/javascript; charset=utf-8", .body = status_js },
    .{ .path = "/modules/license.js", .content_type = "application/javascript; charset=utf-8", .body = license_js },
    .{ .path = "/modules/lobby.js", .content_type = "application/javascript; charset=utf-8", .body = lobby_js },
    .{ .path = "/modules/nav.js", .content_type = "application/javascript; charset=utf-8", .body = nav_js },
};
pub const JsonRouteResponse = shared.JsonRouteResponse;

pub const handleNodes = query.handleNodes;
pub const handleNodeTypes = query.handleNodeTypes;
pub const handleEdgeLabels = query.handleEdgeLabels;
pub const handleSearch = query.handleSearch;
pub const handleSchema = query.handleSchema;
pub const handleGaps = query.handleGaps;
pub const handleRtm = query.handleRtm;
pub const handleImpact = query.handleImpact;
pub const handleSuspects = query.handleSuspects;
pub const handleUserNeeds = query.handleUserNeeds;
pub const handleTests = query.handleTests;
pub const handleRisks = query.handleRisks;
pub const handleNode = query.handleNode;

pub const handleStatus = status.handleStatus;
pub const handleInfo = status.handleInfo;
pub const handlePostWorkspacePrefsResponse = status.handlePostWorkspacePrefsResponse;
pub const handleLicenseStatus = license_routes.handleLicenseStatus;
pub const handleLicenseInfo = license_routes.handleLicenseInfo;
pub const handleLicenseImportResponse = license_routes.handleLicenseImportResponse;
pub const handleLicenseClearResponse = license_routes.handleLicenseClearResponse;

pub const handleConnectionValidate = connection.handleConnectionValidate;
pub const handleConnectionValidateResponse = connection.handleConnectionValidateResponse;
pub const handleConnection = connection.handleConnection;
pub const handleConnectionResponse = connection.handleConnectionResponse;
pub const handleDesignBomSyncValidateResponse = connection.handleDesignBomSyncValidateResponse;
pub const handleDesignBomSyncResponse = connection.handleDesignBomSyncResponse;
pub const handleGetDesignBomSyncResponse = connection.handleGetDesignBomSyncResponse;
pub const handleDeleteDesignBomSyncResponse = connection.handleDeleteDesignBomSyncResponse;
pub const handleSoupSyncValidateResponse = connection.handleSoupSyncValidateResponse;
pub const handleSoupSyncResponse = connection.handleSoupSyncResponse;
pub const handleGetSoupSyncResponse = connection.handleGetSoupSyncResponse;
pub const handleDeleteSoupSyncResponse = connection.handleDeleteSoupSyncResponse;
pub const handleGetProfile = connection.handleGetProfile;
pub const handlePostProfile = connection.handlePostProfile;
pub const handlePostProfileResponse = connection.handlePostProfileResponse;
pub const handleGetRepos = connection.handleGetRepos;
pub const handlePostRepo = connection.handlePostRepo;
pub const handlePostRepoResponse = connection.handlePostRepoResponse;
pub const handleDeleteRepo = connection.handleDeleteRepo;
pub const handleDeleteRepoResponse = connection.handleDeleteRepoResponse;
pub const handleGetWorkbooks = connection.handleGetWorkbooks;
pub const handleGetWorkbooksResponse = connection.handleGetWorkbooksResponse;
pub const handlePostWorkbooks = connection.handlePostWorkbooks;
pub const handlePostWorkbooksResponse = connection.handlePostWorkbooksResponse;
pub const handlePatchWorkbookResponse = connection.handlePatchWorkbookResponse;
pub const handleActivateWorkbookResponse = connection.handleActivateWorkbookResponse;
pub const handleRemoveWorkbookResponse = connection.handleRemoveWorkbookResponse;
pub const handleDeleteWorkbookResponse = connection.handleDeleteWorkbookResponse;

pub const handleProvisionPreview = provision.handleProvisionPreview;
pub const handleProvision = provision.handleProvision;
pub const handleProvisionResponse = provision.handleProvisionResponse;

pub const handleCoverageReport = diagnostics.handleCoverageReport;
pub const handleClearSuspect = diagnostics.handleClearSuspect;
pub const handleIngest = diagnostics.handleIngest;
pub const handleDiagnostics = diagnostics.handleDiagnostics;
pub const handleGuideErrors = diagnostics.handleGuideErrors;
pub const handleChainGaps = diagnostics.handleChainGaps;

pub const handleCodeTraceability = repo.handleCodeTraceability;
pub const handleImplementationChangesResponse = repo.handleImplementationChangesResponse;
pub const handleImplementationChanges = repo.handleImplementationChanges;
pub const handleUnimplementedRequirements = repo.handleUnimplementedRequirements;
pub const handleUntestedSourceFiles = repo.handleUntestedSourceFiles;
pub const handleFileAnnotations = repo.handleFileAnnotations;
pub const handleCommitHistory = repo.handleCommitHistory;
pub const handleRecentCommits = repo.handleRecentCommits;
pub const handleBlameForRequirement = repo.handleBlameForRequirement;

pub const handleDesignHistory = design_history.handleDesignHistory;

pub const handleReportDhrMd = reports.handleReportDhrMd;
pub const handleReportDhrPdf = reports.handleReportDhrPdf;
pub const handleReportRtmPdf = reports.handleReportRtmPdf;
pub const handleReportRtmMd = reports.handleReportRtmMd;
pub const handleReportRtmDocx = reports.handleReportRtmDocx;
pub const handleReportDesignBomMd = reports.handleReportDesignBomMd;
pub const handleReportDesignBomPdf = reports.handleReportDesignBomPdf;
pub const handleReportDesignBomDocx = reports.handleReportDesignBomDocx;
pub const handleReportSoupMd = reports.handleReportSoupMd;
pub const handleReportSoupPdf = reports.handleReportSoupPdf;
pub const handleReportSoupDocx = reports.handleReportSoupDocx;

pub const handlePostTestResults = test_results.handlePostTestResults;
pub const handlePostTestResultsResponse = test_results.handlePostTestResultsResponse;
pub const handleGetExecution = test_results.handleGetExecution;
pub const handleGetExecutionResponse = test_results.handleGetExecutionResponse;
pub const handleRegenerateTestResultsToken = test_results.handleRegenerateTestResultsToken;
pub const handleRegenerateTestResultsTokenResponse = test_results.handleRegenerateTestResultsTokenResponse;
pub const handleListArtifactsResponse = design_artifacts_api.handleListArtifactsResponse;
pub const handleGetArtifactResponse = design_artifacts_api.handleGetArtifactResponse;
pub const handlePostUploadResponse = design_artifacts_api.handlePostUploadResponse;
pub const handlePostOnboardingSourceArtifactResponse = design_artifacts_api.handlePostOnboardingSourceArtifactResponse;
pub const handleReingestArtifactResponse = design_artifacts_api.handleReingestArtifactResponse;
pub const handlePostBomResponse = bom.handlePostBomResponse;
pub const handlePostBomXlsxResponse = bom.handlePostBomXlsxResponse;
pub const handleGetBomResponse = bom.handleGetBomResponse;
pub const handleGetDesignBomListResponse = bom.handleGetDesignBomListResponse;
pub const handleGetDesignBomTreeResponse = bom.handleGetDesignBomTreeResponse;
pub const handleGetDesignBomItemsResponse = bom.handleGetDesignBomItemsResponse;
pub const handleFindPartUsageResponse = bom.handleFindPartUsageResponse;
pub const handleBomGapsResponse = bom.handleBomGapsResponse;
pub const handleBomImpactAnalysisResponse = bom.handleBomImpactAnalysisResponse;
pub const handleGetDesignBomComponentsResponse = bom.handleGetDesignBomComponentsResponse;
pub const handleGetDesignBomCoverageResponse = bom.handleGetDesignBomCoverageResponse;
pub const handlePostSoupResponse = soup_api.handlePostSoupResponse;
pub const handlePostSoupXlsxResponse = soup_api.handlePostSoupXlsxResponse;
pub const handleGetSoupListResponse = soup_api.handleGetSoupListResponse;
pub const handleGetSoupComponentsResponse = soup_api.handleGetSoupComponentsResponse;
pub const handleGetSoupGapsResponse = soup_api.handleGetSoupGapsResponse;
pub const handleGetSoupLicensesResponse = soup_api.handleGetSoupLicensesResponse;
pub const handleGetSoupSafetyClassesResponse = soup_api.handleGetSoupSafetyClassesResponse;

const std = @import("std");
const testing = std.testing;

test "index_html smoke covers onboarding and external js bootstrap" {
    try testing.expect(std.mem.indexOf(u8, index_html, ">Guide / Help<") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Error Codes Explained") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "MCP &amp; AI") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, ">Info<") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Tray App Version") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "rtmify-live Version") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Database Path") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Log File Path") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "External Evidence Ingestion") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "BOM Endpoint") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "What RTMify Exposes") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "requirement://REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "gap://1203/REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "trace_requirement(id=\"REQ-001\")") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "audit_readiness_summary(profile=\"aerospace\")") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Create Missing Tabs") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Code Traceability") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Full Traceability Report") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "id=\"lobby-share-hint\"") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "sa-upload-zone") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "type=\"module\"") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "src=\"/app.js\"") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "function humanEdgeLabel(") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "openGuideForCode(") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "window.location.origin + '/mcp'") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "deleteRepo(${Number.isInteger(r.slot) ? r.slot : 0})") == null);
}

test "app_js smoke covers dashboard behavior and moved api bindings" {
    try testing.expect(app_js.len > 0);
    try testing.expect(std.mem.indexOf(u8, app_js, "import { initApp } from '/modules/init.js';") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/api/profile") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "function humanEdgeLabel(") == null);
}

test "static module asset manifest includes representative frontend modules" {
    try testing.expect(static_assets.len >= 5);
    var saw_init = false;
    var saw_helpers = false;
    for (static_assets) |asset| {
        if (std.mem.eql(u8, asset.path, "/modules/init.js")) saw_init = true;
        if (std.mem.eql(u8, asset.path, "/modules/helpers.js")) saw_helpers = true;
    }
    try testing.expect(saw_init);
    try testing.expect(saw_helpers);
    try testing.expect(std.mem.indexOf(u8, init_js, "createNavigationController") != null);
    try testing.expect(std.mem.indexOf(u8, helpers_js, "rowSeverity") != null);
}
