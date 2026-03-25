const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Node = struct {
    id: []const u8,
    type: []const u8,
    properties: []const u8,
    suspect: bool,
    suspect_reason: ?[]const u8,
};

pub const Edge = struct {
    id: []const u8,
    from_id: []const u8,
    to_id: []const u8,
    label: []const u8,
    properties: ?[]const u8,
};

pub const RuntimeDiagnostic = struct {
    dedupe_key: []const u8,
    code: u16,
    severity: []const u8,
    title: []const u8,
    message: []const u8,
    source: []const u8,
    subject: ?[]const u8,
    details_json: []const u8,
    updated_at: i64,
};

pub const RtmRow = struct {
    req_id: []const u8,
    statement: ?[]const u8,
    status: ?[]const u8,
    user_need_id: ?[]const u8,
    user_need_statement: ?[]const u8,
    test_group_id: ?[]const u8,
    test_id: ?[]const u8,
    test_type: ?[]const u8,
    test_method: ?[]const u8,
    result: ?[]const u8,
    req_suspect: bool,
    req_suspect_reason: ?[]const u8,
};

pub const RiskRow = struct {
    risk_id: []const u8,
    description: ?[]const u8,
    initial_severity: ?[]const u8,
    initial_likelihood: ?[]const u8,
    mitigation: ?[]const u8,
    residual_severity: ?[]const u8,
    residual_likelihood: ?[]const u8,
    req_id: ?[]const u8,
    req_statement: ?[]const u8,
};

pub const TestRow = struct {
    test_group_id: []const u8,
    test_id: ?[]const u8,
    test_type: ?[]const u8,
    test_method: ?[]const u8,
    req_ids: [][]const u8,
    req_statements: [][]const u8,
    req_id: ?[]const u8,
    req_statement: ?[]const u8,
    test_suspect: bool,
    test_suspect_reason: ?[]const u8,
};

pub const ImpactNode = struct {
    id: []const u8,
    type: []const u8,
    properties: []const u8,
    via: []const u8,
    dir: []const u8,
};

pub const ImplementationChangeEvidence = struct {
    node_id: []const u8,
    node_type: []const u8,
    requirement_id: []const u8,
    file_id: []const u8,
    commit_id: []const u8,
    commit_short_hash: ?[]const u8,
    commit_date: ?[]const u8,
    commit_message: ?[]const u8,
};

pub const GraphCounts = struct {
    nodes: i64,
    edges: i64,
};

pub const RequirementSourceAssertion = struct {
    text_id: []const u8,
    artifact_id: ?[]const u8,
    source_kind: ?[]const u8,
    section: ?[]const u8,
    text: ?[]const u8,
    normalized_text: ?[]const u8,
    hash: ?[]const u8,
    parse_status: ?[]const u8,
    occurrence_count: usize,
};

pub const RequirementTextResolution = struct {
    effective_statement: ?[]const u8,
    authoritative_source: ?[]const u8,
    text_status: []const u8,
    source_count: usize,
    assertions: []RequirementSourceAssertion,

    pub fn deinit(self: *RequirementTextResolution, alloc: Allocator) void {
        if (self.effective_statement) |value| alloc.free(value);
        if (self.authoritative_source) |value| alloc.free(value);
        alloc.free(self.text_status);
        for (self.assertions) |assertion| {
            alloc.free(assertion.text_id);
            if (assertion.artifact_id) |value| alloc.free(value);
            if (assertion.source_kind) |value| alloc.free(value);
            if (assertion.section) |value| alloc.free(value);
            if (assertion.text) |value| alloc.free(value);
            if (assertion.normalized_text) |value| alloc.free(value);
            if (assertion.hash) |value| alloc.free(value);
            if (assertion.parse_status) |value| alloc.free(value);
        }
        alloc.free(self.assertions);
    }
};
