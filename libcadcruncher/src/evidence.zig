const detect = @import("detect.zig");

pub const ScopeKind = enum {
    document,
    component,
    net,
    rule,
    layer_stack_region,
    model,
    unknown,
};

pub const ExtractionMethod = enum {
    altium_pipe_record,
    altium_schdoc_file_header_record,
};

pub const MatchedId = struct {
    id: []const u8,
    source_property: []const u8,
    matched_from_value: []const u8,
};

pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const Provenance = struct {
    storage_name: []const u8,
    stream_name: []const u8,
    record_index: usize,
    extraction_method: ExtractionMethod,
};

pub const EvidenceRecord = struct {
    artifact_kind: detect.ArtifactKind,
    source_path: []const u8,

    scope_kind: ScopeKind,
    scope_identifier: ?[]const u8,
    display_name: ?[]const u8,

    properties: []const Property,
    matched_requirement_ids: []const MatchedId,

    provenance: Provenance,
};
