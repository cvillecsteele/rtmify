const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ArtifactKind = enum {
    rtm_workbook,
    srs_docx,
    sysrd_docx,

    pub fn fromString(value: []const u8) ?ArtifactKind {
        if (std.mem.eql(u8, value, "rtm_workbook")) return .rtm_workbook;
        if (std.mem.eql(u8, value, "srs_docx")) return .srs_docx;
        if (std.mem.eql(u8, value, "sysrd_docx")) return .sysrd_docx;
        return null;
    }

    pub fn toString(self: ArtifactKind) []const u8 {
        return switch (self) {
            .rtm_workbook => "rtm_workbook",
            .srs_docx => "srs_docx",
            .sysrd_docx => "sysrd_docx",
        };
    }
};

pub const ParsedRequirementAssertion = struct {
    req_id: []const u8,
    section: []const u8,
    text: ?[]const u8,
    normalized_text: ?[]const u8,
    parse_status: []const u8,
    occurrence_count: usize,
};

pub const IngestDisposition = enum {
    uploaded,
    reingested,
    external_inbox,
    sync_cycle,
    migration,

    pub fn toString(self: IngestDisposition) []const u8 {
        return switch (self) {
            .uploaded => "uploaded",
            .reingested => "reingested",
            .external_inbox => "external_inbox",
            .sync_cycle => "sync_cycle",
            .migration => "migration",
        };
    }
};

pub const IngestSummary = struct {
    artifact_id: []const u8,
    kind: ArtifactKind,
    requirements_seen: usize,
    nodes_added: usize,
    nodes_updated: usize,
    nodes_deleted: usize,
    unchanged: usize,
    conflicts_detected: usize,
    null_text_count: usize,
    low_confidence_count: usize,
    diagnostics_emitted: usize,
    timestamp: i64,
    disposition: IngestDisposition,
    new_since_last_ingest: []const []const u8,

    pub fn deinit(self: *IngestSummary, alloc: Allocator) void {
        alloc.free(self.artifact_id);
        for (self.new_since_last_ingest) |value| alloc.free(value);
        alloc.free(self.new_since_last_ingest);
    }
};

pub const ArtifactIngestResult = struct {
    artifact_id: []const u8,
    summary: IngestSummary,

    pub fn deinit(self: *ArtifactIngestResult, alloc: Allocator) void {
        alloc.free(self.artifact_id);
        self.summary.deinit(alloc);
    }
};

pub const ArtifactSummary = struct {
    artifact_id: []const u8,
    kind: []const u8,
    display_name: []const u8,
    path: []const u8,
    logical_key: []const u8,
    last_ingested_at: []const u8,
    ingest_source: []const u8,
    requirement_count: usize,
    conflict_count: usize,
    null_text_count: usize,
    low_confidence_count: usize,
    reingestable: bool,
};

pub const PreviousArtifactAssertion = struct {
    req_id: []const u8,
    hash: []const u8,

    pub fn deinit(self: *PreviousArtifactAssertion, alloc: Allocator) void {
        alloc.free(self.req_id);
        alloc.free(self.hash);
    }
};

pub const PreviousArtifactSnapshot = struct {
    assertions: []PreviousArtifactAssertion,
    req_ids: []const []const u8,

    pub fn deinit(self: PreviousArtifactSnapshot, alloc: Allocator) void {
        for (self.assertions) |*item| item.deinit(alloc);
        alloc.free(self.assertions);
        for (self.req_ids) |value| alloc.free(value);
        alloc.free(self.req_ids);
    }
};

pub const ArtifactConflictRow = struct {
    req_id: []const u8,
    other_artifact_id: []const u8,
    other_source_kind: []const u8,
    other_text: []const u8,
};
