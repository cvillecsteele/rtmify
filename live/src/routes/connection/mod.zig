const provider_connection = @import("provider_connection.zig");
const workbook_sync = @import("workbook_sync.zig");
const profile_config = @import("profile_config.zig");
const repo_registry = @import("repo_registry.zig");
const workbook_registry = @import("workbook_registry.zig");

pub const handleConnectionValidate = provider_connection.handleConnectionValidate;
pub const handleConnectionValidateResponse = provider_connection.handleConnectionValidateResponse;
pub const handleConnection = provider_connection.handleConnection;
pub const handleConnectionResponse = provider_connection.handleConnectionResponse;

pub const handleDesignBomSyncValidateResponse = workbook_sync.handleDesignBomSyncValidateResponse;
pub const handleDesignBomSyncResponse = workbook_sync.handleDesignBomSyncResponse;
pub const handleGetDesignBomSyncResponse = workbook_sync.handleGetDesignBomSyncResponse;
pub const handleDeleteDesignBomSyncResponse = workbook_sync.handleDeleteDesignBomSyncResponse;
pub const handleSoupSyncValidateResponse = workbook_sync.handleSoupSyncValidateResponse;
pub const handleSoupSyncResponse = workbook_sync.handleSoupSyncResponse;
pub const handleGetSoupSyncResponse = workbook_sync.handleGetSoupSyncResponse;
pub const handleDeleteSoupSyncResponse = workbook_sync.handleDeleteSoupSyncResponse;

pub const handleGetProfile = profile_config.handleGetProfile;
pub const handlePostProfile = profile_config.handlePostProfile;
pub const handlePostProfileResponse = profile_config.handlePostProfileResponse;

pub const handleGetRepos = repo_registry.handleGetRepos;
pub const handlePostRepo = repo_registry.handlePostRepo;
pub const handlePostRepoResponse = repo_registry.handlePostRepoResponse;
pub const handleDeleteRepo = repo_registry.handleDeleteRepo;
pub const handleDeleteRepoResponse = repo_registry.handleDeleteRepoResponse;

pub const handleGetWorkbooks = workbook_registry.handleGetWorkbooks;
pub const handleGetWorkbooksResponse = workbook_registry.handleGetWorkbooksResponse;
pub const handlePostWorkbooks = workbook_registry.handlePostWorkbooks;
pub const handlePostWorkbooksResponse = workbook_registry.handlePostWorkbooksResponse;
pub const handlePatchWorkbookResponse = workbook_registry.handlePatchWorkbookResponse;
pub const handleActivateWorkbookResponse = workbook_registry.handleActivateWorkbookResponse;
pub const handleRemoveWorkbookResponse = workbook_registry.handleRemoveWorkbookResponse;
pub const handleDeleteWorkbookResponse = workbook_registry.handleDeleteWorkbookResponse;
