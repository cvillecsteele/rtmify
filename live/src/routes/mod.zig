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

pub const index_html = @embedFile("../static/index.html");
pub const app_js = @embedFile("../static/app.js");
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
pub const handleLicenseStatus = license_routes.handleLicenseStatus;
pub const handleLicenseInfo = license_routes.handleLicenseInfo;
pub const handleLicenseImportResponse = license_routes.handleLicenseImportResponse;
pub const handleLicenseClearResponse = license_routes.handleLicenseClearResponse;

pub const handleConnectionValidate = connection.handleConnectionValidate;
pub const handleConnectionValidateResponse = connection.handleConnectionValidateResponse;
pub const handleConnection = connection.handleConnection;
pub const handleConnectionResponse = connection.handleConnectionResponse;
pub const handleGetProfile = connection.handleGetProfile;
pub const handlePostProfile = connection.handlePostProfile;
pub const handlePostProfileResponse = connection.handlePostProfileResponse;
pub const handleGetRepos = connection.handleGetRepos;
pub const handlePostRepo = connection.handlePostRepo;
pub const handlePostRepoResponse = connection.handlePostRepoResponse;
pub const handleDeleteRepo = connection.handleDeleteRepo;
pub const handleDeleteRepoResponse = connection.handleDeleteRepoResponse;

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

pub const handlePostTestResults = test_results.handlePostTestResults;
pub const handlePostTestResultsResponse = test_results.handlePostTestResultsResponse;
pub const handleGetExecution = test_results.handleGetExecution;
pub const handleGetExecutionResponse = test_results.handleGetExecutionResponse;
pub const handleRegenerateTestResultsToken = test_results.handleRegenerateTestResultsToken;
pub const handleRegenerateTestResultsTokenResponse = test_results.handleRegenerateTestResultsTokenResponse;

const std = @import("std");
const testing = std.testing;

test "index_html smoke covers onboarding and external js bootstrap" {
    try testing.expect(std.mem.indexOf(u8, index_html, ">Guide<") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Error Codes Explained") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "MCP &amp; AI") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, ">Info<") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Tray App Version") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "rtmify-live Version") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Database Path") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Log File Path") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "What RTMify Exposes") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "requirement://REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "gap://1203/REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "trace_requirement(id=\"REQ-001\")") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "audit_readiness_summary(profile=\"aerospace\")") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Create Missing Tabs") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Code Traceability") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Design History Record (DHR)") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "id=\"lobby-share-hint\"") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "sa-upload-zone") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "src=\"/app.js\"") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "function humanEdgeLabel(") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "openGuideForCode(") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "window.location.origin + '/mcp'") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "deleteRepo(${Number.isInteger(r.slot) ? r.slot : 0})") == null);
}

test "app_js smoke covers dashboard behavior and moved api bindings" {
    try testing.expect(app_js.len > 0);
    try testing.expect(std.mem.indexOf(u8, app_js, "/api/profile") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/api/provision") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/query/chain-gaps") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/api/repos") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/api/diagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/api/guide/errors") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/query/recent-commits") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "/api/info") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "claude mcp add --transport http rtmify-live") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "codex mcp add rtmify-live --url") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "\"httpUrl\":") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "window.location.origin + '/mcp'") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "What RTMify Checked") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "const { node, edges_out, edges_in } = data;") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "function humanEdgeLabel(") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "openGuideForCode(") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "uploadSaFile") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "clearCredential") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "data-action=\"toggle-row\"") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "data-action=\"open-guide\"") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "data-action=\"select-profile\"") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "data-action=\"delete-repo\"") != null);
    try testing.expect(std.mem.indexOf(u8, app_js, "function explainGap(") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "toggleGapHelp(") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "onclick=") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "onkeydown=") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "JSON.parse(f.properties") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "JSON.parse(a.properties") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "JSON.parse(c.properties") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "r.test_suspect") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "r.req_suspect") == null);
    try testing.expect(std.mem.indexOf(u8, app_js, "${arrow} ${esc(e.label)}") == null);
}
