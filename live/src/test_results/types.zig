const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PostStatus = enum {
    passed,
    failed,
    partial,
};

pub const VerificationState = enum {
    VERIFIED,
    VERIFY_FAILED,
    VERIFY_PARTIAL,
    VERIFY_NONE,
};

pub const ValidationError = error{
    InvalidJson,
    MissingExecutionId,
    MissingExecutedAt,
    InvalidExecutedAt,
    InvalidFullProductIdentifier,
    MissingTestCases,
    EmptyTestCases,
    InvalidExecutor,
    InvalidSource,
    MissingResultId,
    MissingTestCaseRef,
    MissingCaseStatus,
    InvalidCaseStatus,
    InvalidDurationMs,
    InvalidMeasurements,
    InvalidAttachments,
};

pub const IngestError = error{
    ExecutionSuperseded,
};

pub const TestCaseInput = struct {
    result_id: []const u8,
    test_case_ref: []const u8,
    status: []const u8,
    duration_ms: ?i64,
    notes: ?[]const u8,
    measurements_json: []const u8,
    attachments_json: []const u8,

    pub fn deinit(self: *TestCaseInput, alloc: Allocator) void {
        alloc.free(self.result_id);
        alloc.free(self.test_case_ref);
        alloc.free(self.status);
        if (self.notes) |value| alloc.free(value);
        alloc.free(self.measurements_json);
        alloc.free(self.attachments_json);
    }
};

pub const ExecutionInput = struct {
    execution_id: []const u8,
    executed_at: []const u8,
    serial_number: ?[]const u8,
    full_product_identifier: ?[]const u8,
    executor_json: ?[]const u8,
    source_json: ?[]const u8,
    test_cases: []TestCaseInput,

    pub fn deinit(self: *ExecutionInput, alloc: Allocator) void {
        alloc.free(self.execution_id);
        alloc.free(self.executed_at);
        if (self.serial_number) |value| alloc.free(value);
        if (self.full_product_identifier) |value| alloc.free(value);
        if (self.executor_json) |value| alloc.free(value);
        if (self.source_json) |value| alloc.free(value);
        for (self.test_cases) |*test_case| test_case.deinit(alloc);
        alloc.free(self.test_cases);
    }
};

pub const IngestWarning = struct {
    result_id: []const u8,
    test_case_ref: []const u8,
    full_product_identifier: ?[]const u8,
    code: []const u8,
    message: []const u8,

    pub fn deinit(self: *IngestWarning, alloc: Allocator) void {
        alloc.free(self.result_id);
        alloc.free(self.test_case_ref);
        if (self.full_product_identifier) |value| alloc.free(value);
        alloc.free(self.code);
        alloc.free(self.message);
    }
};

pub const IngestResponse = struct {
    execution_id: []const u8,
    computed_status: PostStatus,
    inserted: usize,
    warnings: []IngestWarning,

    pub fn deinit(self: *IngestResponse, alloc: Allocator) void {
        alloc.free(self.execution_id);
        for (self.warnings) |*warning| warning.deinit(alloc);
        alloc.free(self.warnings);
    }
};

pub const StoredResult = struct {
    result_id: []const u8,
    test_case_ref: []const u8,
    status: []const u8,
    duration_ms: ?i64,
    notes: ?[]const u8,
    measurements_json: []const u8,
    attachments_json: []const u8,
    resolution_state: []const u8,

    pub fn deinit(self: *StoredResult, alloc: Allocator) void {
        alloc.free(self.result_id);
        alloc.free(self.test_case_ref);
        alloc.free(self.status);
        if (self.notes) |value| alloc.free(value);
        alloc.free(self.measurements_json);
        alloc.free(self.attachments_json);
        alloc.free(self.resolution_state);
    }
};

pub const ExecutionEnvelope = struct {
    execution_id: []const u8,
    executed_at: []const u8,
    computed_status: []const u8,
    serial_number: ?[]const u8,
    full_product_identifier: ?[]const u8,
    product_resolution_state: ?[]const u8,
    executor_json: ?[]const u8,
    source_json: ?[]const u8,
    test_cases: []StoredResult,

    pub fn deinit(self: *ExecutionEnvelope, alloc: Allocator) void {
        alloc.free(self.execution_id);
        alloc.free(self.executed_at);
        alloc.free(self.computed_status);
        if (self.serial_number) |value| alloc.free(value);
        if (self.full_product_identifier) |value| alloc.free(value);
        if (self.product_resolution_state) |value| alloc.free(value);
        if (self.executor_json) |value| alloc.free(value);
        if (self.source_json) |value| alloc.free(value);
        for (self.test_cases) |*test_case| test_case.deinit(alloc);
        alloc.free(self.test_cases);
    }
};

pub const LatestResult = struct {
    test_id: []const u8,
    execution_id: ?[]const u8,
    result_id: ?[]const u8,
    status: ?[]const u8,
    executed_at: ?[]const u8,
    resolution_state: ?[]const u8,

    pub fn deinit(self: *LatestResult, alloc: Allocator) void {
        alloc.free(self.test_id);
        if (self.execution_id) |value| alloc.free(value);
        if (self.result_id) |value| alloc.free(value);
        if (self.status) |value| alloc.free(value);
        if (self.executed_at) |value| alloc.free(value);
        if (self.resolution_state) |value| alloc.free(value);
    }
};

pub const RequirementVerification = struct {
    requirement_ref: []const u8,
    state: VerificationState,
    linked_test_groups: []const []const u8,
    linked_tests: []LatestResult,

    pub fn deinit(self: *RequirementVerification, alloc: Allocator) void {
        alloc.free(self.requirement_ref);
        for (self.linked_test_groups) |value| alloc.free(value);
        alloc.free(self.linked_test_groups);
        for (self.linked_tests) |*value| value.deinit(alloc);
        alloc.free(self.linked_tests);
    }
};

const testing = std.testing;

test "ExecutionInput.deinit frees optional executor source and product fields safely" {
    var payload = ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "exec-1"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-12T14:32:00Z"),
        .serial_number = try testing.allocator.dupe(u8, "SN-1"),
        .full_product_identifier = try testing.allocator.dupe(u8, "ASM-1"),
        .executor_json = try testing.allocator.dupe(u8, "{\"name\":\"station\"}"),
        .source_json = try testing.allocator.dupe(u8, "{\"kind\":\"api\"}"),
        .test_cases = try testing.allocator.alloc(TestCaseInput, 1),
    };
    payload.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "r-1"),
        .test_case_ref = try testing.allocator.dupe(u8, "T-1"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[]"),
        .attachments_json = try testing.allocator.dupe(u8, "[]"),
    };

    payload.deinit(testing.allocator);
}

test "IngestResponse.deinit frees nested warnings" {
    var response = IngestResponse{
        .execution_id = try testing.allocator.dupe(u8, "exec-1"),
        .computed_status = .passed,
        .inserted = 1,
        .warnings = try testing.allocator.alloc(IngestWarning, 1),
    };
    response.warnings[0] = .{
        .result_id = try testing.allocator.dupe(u8, "r-1"),
        .test_case_ref = try testing.allocator.dupe(u8, "T-1"),
        .full_product_identifier = try testing.allocator.dupe(u8, "ASM-1"),
        .code = try testing.allocator.dupe(u8, "WARN"),
        .message = try testing.allocator.dupe(u8, "warning"),
    };

    response.deinit(testing.allocator);
}

test "RequirementVerification.deinit frees linked tests and groups" {
    var groups = try testing.allocator.alloc([]const u8, 1);
    groups[0] = try testing.allocator.dupe(u8, "TG-1");
    var verification = RequirementVerification{
        .requirement_ref = try testing.allocator.dupe(u8, "REQ-1"),
        .state = .VERIFIED,
        .linked_test_groups = groups,
        .linked_tests = try testing.allocator.alloc(LatestResult, 1),
    };
    verification.linked_tests[0] = .{
        .test_id = try testing.allocator.dupe(u8, "T-1"),
        .execution_id = try testing.allocator.dupe(u8, "exec-1"),
        .result_id = try testing.allocator.dupe(u8, "r-1"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-12T14:32:00Z"),
        .resolution_state = try testing.allocator.dupe(u8, "resolved"),
    };

    verification.deinit(testing.allocator);
}
