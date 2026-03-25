const types = @import("design_artifacts/types.zig");
const ids = @import("design_artifacts/ids.zig");
const query = @import("design_artifacts/query.zig");
const ingest = @import("design_artifacts/ingest.zig");
const parser_docx = @import("design_artifacts/parser_docx.zig");
const parser_rtm_workbook = @import("design_artifacts/parser_rtm_workbook.zig");

pub const ArtifactKind = types.ArtifactKind;
pub const ParsedRequirementAssertion = types.ParsedRequirementAssertion;
pub const IngestDisposition = types.IngestDisposition;
pub const IngestSummary = types.IngestSummary;
pub const ArtifactIngestResult = types.ArtifactIngestResult;
pub const ArtifactSummary = types.ArtifactSummary;

pub const artifactIdFor = ids.artifactIdFor;

pub const migrateLegacyRequirementStatements = ingest.migrateLegacyRequirementStatements;
pub const ingestDocxPath = ingest.ingestDocxPath;
pub const ingestRtmWorkbookPath = ingest.ingestRtmWorkbookPath;
pub const reingestArtifact = ingest.reingestArtifact;
pub const applyArtifactSnapshot = ingest.applyArtifactSnapshot;

pub const listArtifactsJson = query.listArtifactsJson;
pub const getArtifactJson = query.getArtifactJson;
pub const listArtifacts = query.listArtifacts;

pub const parseDocxAssertions = parser_docx.parseDocxAssertions;
pub const extractDocxAllText = parser_docx.extractDocxAllText;
pub const validateRtmWorkbookShape = parser_rtm_workbook.validateRtmWorkbookShape;
