const mod = @import("routes/mod.zig");

pub const index_html = mod.index_html;
pub const app_js = mod.app_js;
pub const JsonRouteResponse = mod.JsonRouteResponse;

pub const handleNodes = mod.handleNodes;
pub const handleNodeTypes = mod.handleNodeTypes;
pub const handleEdgeLabels = mod.handleEdgeLabels;
pub const handleSearch = mod.handleSearch;
pub const handleSchema = mod.handleSchema;
pub const handleGaps = mod.handleGaps;
pub const handleRtm = mod.handleRtm;
pub const handleImpact = mod.handleImpact;
pub const handleSuspects = mod.handleSuspects;
pub const handleUserNeeds = mod.handleUserNeeds;
pub const handleTests = mod.handleTests;
pub const handleRisks = mod.handleRisks;
pub const handleNode = mod.handleNode;

pub const handleStatus = mod.handleStatus;
pub const handleLicenseStatus = mod.handleLicenseStatus;
pub const handleLicenseInfo = mod.handleLicenseInfo;
pub const handleLicenseImportResponse = mod.handleLicenseImportResponse;
pub const handleLicenseClearResponse = mod.handleLicenseClearResponse;
pub const handleInfo = mod.handleInfo;
pub const handlePostTestResults = mod.handlePostTestResults;
pub const handlePostTestResultsResponse = mod.handlePostTestResultsResponse;
pub const handleGetExecution = mod.handleGetExecution;
pub const handleGetExecutionResponse = mod.handleGetExecutionResponse;
pub const handleRegenerateTestResultsToken = mod.handleRegenerateTestResultsToken;
pub const handleRegenerateTestResultsTokenResponse = mod.handleRegenerateTestResultsTokenResponse;
pub const handlePostBomResponse = mod.handlePostBomResponse;
pub const handleGetBomResponse = mod.handleGetBomResponse;

pub const handleConnectionValidate = mod.handleConnectionValidate;
pub const handleConnectionValidateResponse = mod.handleConnectionValidateResponse;
pub const handleConnection = mod.handleConnection;
pub const handleConnectionResponse = mod.handleConnectionResponse;
pub const handleProvisionPreview = mod.handleProvisionPreview;
pub const handleProvision = mod.handleProvision;
pub const handleProvisionResponse = mod.handleProvisionResponse;
pub const handleDeleteRepo = mod.handleDeleteRepo;
pub const handleDeleteRepoResponse = mod.handleDeleteRepoResponse;
pub const handleGetProfile = mod.handleGetProfile;
pub const handlePostProfile = mod.handlePostProfile;
pub const handlePostProfileResponse = mod.handlePostProfileResponse;
pub const handleGetRepos = mod.handleGetRepos;
pub const handlePostRepo = mod.handlePostRepo;
pub const handlePostRepoResponse = mod.handlePostRepoResponse;

pub const handleCoverageReport = mod.handleCoverageReport;
pub const handleClearSuspect = mod.handleClearSuspect;
pub const handleIngest = mod.handleIngest;
pub const handleDiagnostics = mod.handleDiagnostics;
pub const handleGuideErrors = mod.handleGuideErrors;
pub const handleChainGaps = mod.handleChainGaps;

pub const handleCodeTraceability = mod.handleCodeTraceability;
pub const handleImplementationChangesResponse = mod.handleImplementationChangesResponse;
pub const handleImplementationChanges = mod.handleImplementationChanges;
pub const handleUnimplementedRequirements = mod.handleUnimplementedRequirements;
pub const handleUntestedSourceFiles = mod.handleUntestedSourceFiles;
pub const handleFileAnnotations = mod.handleFileAnnotations;
pub const handleCommitHistory = mod.handleCommitHistory;
pub const handleRecentCommits = mod.handleRecentCommits;
pub const handleBlameForRequirement = mod.handleBlameForRequirement;

pub const handleDesignHistory = mod.handleDesignHistory;
pub const handleReportDhrMd = mod.handleReportDhrMd;
pub const handleReportDhrPdf = mod.handleReportDhrPdf;
pub const handleReportRtmPdf = mod.handleReportRtmPdf;
pub const handleReportRtmMd = mod.handleReportRtmMd;
pub const handleReportRtmDocx = mod.handleReportRtmDocx;
