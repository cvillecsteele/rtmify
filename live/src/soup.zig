const ingest = @import("soup/ingest.zig");
const json_mod = @import("soup/json.zig");
const query = @import("soup/query.zig");
const report = @import("soup/report.zig");
const types = @import("soup/types.zig");

pub const default_bom_name = types.default_bom_name;
pub const SoupRowError = types.SoupRowError;
pub const SoupIngestResponse = types.SoupIngestResponse;

pub const ingestJsonBody = ingest.ingestJsonBody;
pub const ingestXlsxBody = ingest.ingestXlsxBody;
pub const ingestXlsxPath = ingest.ingestXlsxPath;
pub const ingestXlsxInboxPath = ingest.ingestXlsxInboxPath;
pub const ingestSheetRows = ingest.ingestSheetRows;

pub const ingestResponseJson = json_mod.ingestResponseJson;

pub const listSoftwareBomsJson = query.listSoftwareBomsJson;
pub const getSoupComponentsJson = query.getSoupComponentsJson;
pub const soupGapsJson = query.soupGapsJson;
pub const soupLicensesJson = query.soupLicensesJson;
pub const soupSafetyClassesJson = query.soupSafetyClassesJson;

pub const soupRegisterMarkdown = report.soupRegisterMarkdown;
