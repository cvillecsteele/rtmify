const std = @import("std");
const Allocator = std.mem.Allocator;

const db_mod = @import("db.zig");
const graph_live = @import("graph_live.zig");
const json_util = @import("json_util.zig");
const shared = @import("routes/shared.zig");

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

pub fn parsePayload(body: []const u8, alloc: Allocator) (ValidationError || error{OutOfMemory})!ExecutionInput {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    const execution_id = json_util.getString(root, "execution_id") orelse return error.MissingExecutionId;
    const executed_at = json_util.getString(root, "executed_at") orelse return error.MissingExecutedAt;
    if (!isLikelyIso8601Timestamp(executed_at)) return error.InvalidExecutedAt;
    const full_product_identifier = if (json_util.getObjectField(root, "full_product_identifier")) |value| blk: {
        if (value != .string) return error.InvalidFullProductIdentifier;
        break :blk try alloc.dupe(u8, value.string);
    } else null;
    errdefer if (full_product_identifier) |value| alloc.free(value);

    const test_cases_value = json_util.getObjectField(root, "test_cases") orelse return error.MissingTestCases;
    if (test_cases_value != .array) return error.MissingTestCases;
    if (test_cases_value.array.items.len == 0) return error.EmptyTestCases;

    const executor_json = if (json_util.getObjectField(root, "executor")) |value| blk: {
        if (value != .object) return error.InvalidExecutor;
        break :blk try std.json.Stringify.valueAlloc(alloc, value, .{});
    } else null;
    errdefer if (executor_json) |value| alloc.free(value);

    const source_json = if (json_util.getObjectField(root, "source")) |value| blk: {
        if (value != .object) return error.InvalidSource;
        break :blk try std.json.Stringify.valueAlloc(alloc, value, .{});
    } else null;
    errdefer if (source_json) |value| alloc.free(value);

    var test_cases = try alloc.alloc(TestCaseInput, test_cases_value.array.items.len);
    errdefer {
        for (test_cases, 0..) |*test_case, idx| {
            if (idx >= test_cases_value.array.items.len) break;
            test_case.deinit(alloc);
        }
        alloc.free(test_cases);
    }

    for (test_cases_value.array.items, 0..) |item, idx| {
        if (item != .object) return error.MissingResultId;
        const result_id = json_util.getString(item, "result_id") orelse return error.MissingResultId;
        const test_case_ref = json_util.getString(item, "test_case_ref") orelse return error.MissingTestCaseRef;
        const status = json_util.getString(item, "status") orelse return error.MissingCaseStatus;
        if (!isAllowedCaseStatus(status)) return error.InvalidCaseStatus;

        const duration_ms: ?i64 = if (json_util.getObjectField(item, "duration_ms")) |value| blk: {
            if (value == .integer) break :blk value.integer;
            return error.InvalidDurationMs;
        } else null;

        const notes = if (json_util.getString(item, "notes")) |value| try alloc.dupe(u8, value) else null;
        errdefer if (notes) |value| alloc.free(value);

        const measurements_json = if (json_util.getObjectField(item, "measurements")) |value| blk: {
            if (value != .array) return error.InvalidMeasurements;
            break :blk try std.json.Stringify.valueAlloc(alloc, value, .{});
        } else try alloc.dupe(u8, "[]");
        errdefer alloc.free(measurements_json);

        const attachments_json = if (json_util.getObjectField(item, "attachments")) |value| blk: {
            if (value != .array) return error.InvalidAttachments;
            break :blk try std.json.Stringify.valueAlloc(alloc, value, .{});
        } else try alloc.dupe(u8, "[]");
        errdefer alloc.free(attachments_json);

        test_cases[idx] = .{
            .result_id = try alloc.dupe(u8, result_id),
            .test_case_ref = try alloc.dupe(u8, test_case_ref),
            .status = try alloc.dupe(u8, status),
            .duration_ms = duration_ms,
            .notes = notes,
            .measurements_json = measurements_json,
            .attachments_json = attachments_json,
        };
    }

    return .{
        .execution_id = try alloc.dupe(u8, execution_id),
        .executed_at = try alloc.dupe(u8, executed_at),
        .serial_number = if (json_util.getString(root, "serial_number")) |value| try alloc.dupe(u8, value) else null,
        .full_product_identifier = full_product_identifier,
        .executor_json = executor_json,
        .source_json = source_json,
        .test_cases = test_cases,
    };
}

pub fn ingest(db: *graph_live.GraphDb, payload: ExecutionInput, alloc: Allocator) (IngestError || error{OutOfMemory} || db_mod.DbError)!IngestResponse {
    var existing = try getExecution(db, payload.execution_id, alloc);
    defer if (existing) |*execution| execution.deinit(alloc);
    if (existing) |execution| {
        try rejectIfSuperseded(db, execution);
    }

    var warnings: std.ArrayList(IngestWarning) = .empty;
    defer warnings.deinit(alloc);

    db.db.write_mu.lock();
    defer db.db.write_mu.unlock();

    if (existing) |_| {
        try deleteExecutionSubtreeLocked(db, payload.execution_id);
    }

    var product_node_id: ?[]u8 = null;
    defer if (product_node_id) |value| alloc.free(value);
    const product_resolution_state: ?[]const u8 = blk: {
        if (payload.full_product_identifier) |full_product_identifier| {
            product_node_id = try productNodeId(full_product_identifier, alloc);
            const maybe_product = try db.getNode(product_node_id.?, alloc);
            defer if (maybe_product) |node| shared.freeNode(node, alloc);
            break :blk if (maybe_product != null) "resolved" else "dangling";
        }
        break :blk null;
    };

    const execution_node_id = try executionNodeId(payload.execution_id, alloc);
    defer alloc.free(execution_node_id);
    const execution_props = try executionPropertiesJson(payload, product_resolution_state, alloc);
    defer alloc.free(execution_props);
    try upsertNodeLocked(db, execution_node_id, "TestExecution", execution_props);

    var inserted: usize = 1;
    if (payload.full_product_identifier) |full_product_identifier| {
        if (product_resolution_state != null and std.mem.eql(u8, product_resolution_state.?, "resolved")) {
            try addEdgeLocked(db, execution_node_id, product_node_id.?, "FOR_PRODUCT");
        } else {
            try warnings.append(alloc, .{
                .result_id = try alloc.dupe(u8, ""),
                .test_case_ref = try alloc.dupe(u8, ""),
                .full_product_identifier = try alloc.dupe(u8, full_product_identifier),
                .code = try alloc.dupe(u8, "DANGLING_PRODUCT_REF"),
                .message = try std.fmt.allocPrint(alloc, "No Product node found for {s}", .{full_product_identifier}),
            });
        }
    }
    for (payload.test_cases) |test_case| {
        const resolution_state = blk: {
            const maybe_node = try db.getNode(test_case.test_case_ref, alloc);
            defer if (maybe_node) |node| shared.freeNode(node, alloc);
            break :blk if (maybe_node != null) "resolved" else "dangling";
        };
        if (std.mem.eql(u8, resolution_state, "dangling")) {
            try warnings.append(alloc, .{
                .result_id = try alloc.dupe(u8, test_case.result_id),
                .test_case_ref = try alloc.dupe(u8, test_case.test_case_ref),
                .full_product_identifier = null,
                .code = try alloc.dupe(u8, "DANGLING_REF"),
                .message = try std.fmt.allocPrint(alloc, "No Test node found for {s}", .{test_case.test_case_ref}),
            });
        }

        const result_node_id = try resultNodeId(test_case.result_id, alloc);
        defer alloc.free(result_node_id);
        const result_props = try resultPropertiesJson(payload.execution_id, test_case, resolution_state, alloc);
        defer alloc.free(result_props);
        try upsertNodeLocked(db, result_node_id, "TestResult", result_props);
        try addEdgeLocked(db, execution_node_id, result_node_id, "HAS_RESULT");
        try addEdgeLocked(db, result_node_id, test_case.test_case_ref, "EXECUTION_OF");
        inserted += 1;
    }

    return .{
        .execution_id = try alloc.dupe(u8, payload.execution_id),
        .computed_status = computeStatus(payload.test_cases),
        .inserted = inserted,
        .warnings = try warnings.toOwnedSlice(alloc),
    };
}

pub fn getExecution(db: *graph_live.GraphDb, execution_id: []const u8, alloc: Allocator) !?ExecutionEnvelope {
    const execution_node_id = try executionNodeId(execution_id, alloc);
    defer alloc.free(execution_node_id);

    var st = try db.db.prepare(
        \\SELECT
        \\    json_extract(properties, '$.execution_id'),
        \\    json_extract(properties, '$.executed_at'),
        \\    json_extract(properties, '$.computed_status'),
        \\    json_extract(properties, '$.serial_number'),
        \\    json_extract(properties, '$.full_product_identifier'),
        \\    json_extract(properties, '$.product_resolution_state'),
        \\    json_extract(properties, '$.executor'),
        \\    json_extract(properties, '$.source')
        \\FROM nodes
        \\WHERE id=? AND type='TestExecution'
    );
    defer st.finalize();
    try st.bindText(1, execution_node_id);
    if (!try st.step()) return null;

    var results: std.ArrayList(StoredResult) = .empty;
    defer results.deinit(alloc);
    try listExecutionResults(db, execution_id, alloc, &results);

    return .{
        .execution_id = try alloc.dupe(u8, st.columnText(0)),
        .executed_at = try alloc.dupe(u8, st.columnText(1)),
        .computed_status = try alloc.dupe(u8, st.columnText(2)),
        .serial_number = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
        .full_product_identifier = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        .product_resolution_state = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
        .executor_json = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
        .source_json = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
        .test_cases = try results.toOwnedSlice(alloc),
    };
}

pub fn getExecutionJson(db: *graph_live.GraphDb, execution_id: []const u8, alloc: Allocator) !?[]const u8 {
    var execution = (try getExecution(db, execution_id, alloc)) orelse return null;
    defer execution.deinit(alloc);
    return try executionJson(execution, alloc);
}

pub fn getTestResultsJson(db: *graph_live.GraphDb, test_case_ref: []const u8, alloc: Allocator) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\    json_extract(r.properties, '$.result_id'),
        \\    json_extract(r.properties, '$.test_case_ref'),
        \\    json_extract(r.properties, '$.status'),
        \\    json_extract(r.properties, '$.duration_ms'),
        \\    json_extract(r.properties, '$.notes'),
        \\    json_extract(r.properties, '$.measurements'),
        \\    json_extract(r.properties, '$.attachments'),
        \\    json_extract(r.properties, '$.resolution_state'),
        \\    json_extract(e.properties, '$.execution_id'),
        \\    json_extract(e.properties, '$.executed_at')
        \\FROM nodes r
        \\JOIN edges eo ON eo.from_id = r.id AND eo.label = 'EXECUTION_OF'
        \\LEFT JOIN edges hr ON hr.to_id = r.id AND hr.label = 'HAS_RESULT'
        \\LEFT JOIN nodes e ON e.id = hr.from_id AND e.type = 'TestExecution'
        \\WHERE r.type = 'TestResult' AND eo.to_id = ?
        \\ORDER BY json_extract(e.properties, '$.executed_at') DESC, json_extract(r.properties, '$.result_id') ASC
    );
    defer st.finalize();
    try st.bindText(1, test_case_ref);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"test_case_ref\":");
    try shared.appendJsonStr(&buf, test_case_ref, alloc);
    try buf.appendSlice(alloc, ",\"results\":[");
    var first = true;
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"result_id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"test_case_ref\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"status\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"duration_ms\":");
        try shared.appendJsonIntOpt(&buf, if (st.columnIsNull(3)) null else st.columnInt(3), alloc);
        try buf.appendSlice(alloc, ",\"notes\":");
        try shared.appendJsonStrOpt(&buf, if (st.columnIsNull(4)) null else st.columnText(4), alloc);
        try buf.appendSlice(alloc, ",\"measurements\":");
        try buf.appendSlice(alloc, if (st.columnIsNull(5)) "[]" else st.columnText(5));
        try buf.appendSlice(alloc, ",\"attachments\":");
        try buf.appendSlice(alloc, if (st.columnIsNull(6)) "[]" else st.columnText(6));
        try buf.appendSlice(alloc, ",\"resolution_state\":");
        try shared.appendJsonStr(&buf, st.columnText(7), alloc);
        try buf.appendSlice(alloc, ",\"execution_id\":");
        try shared.appendJsonStrOpt(&buf, if (st.columnIsNull(8)) null else st.columnText(8), alloc);
        try buf.appendSlice(alloc, ",\"executed_at\":");
        try shared.appendJsonStrOpt(&buf, if (st.columnIsNull(9)) null else st.columnText(9), alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn verificationForRequirement(db: *graph_live.GraphDb, requirement_ref: []const u8, alloc: Allocator) !RequirementVerification {
    var groups: std.ArrayList([]const u8) = .empty;
    defer groups.deinit(alloc);
    var tests: std.ArrayList([]const u8) = .empty;
    defer {
        for (tests.items) |value| alloc.free(value);
        tests.deinit(alloc);
    }

    var st = try db.db.prepare(
        \\SELECT DISTINCT tg.id, t.id
        \\FROM edges e_tb
        \\JOIN nodes tg ON tg.id = e_tb.to_id AND tg.type = 'TestGroup'
        \\LEFT JOIN edges e_ht ON e_ht.from_id = tg.id AND e_ht.label = 'HAS_TEST'
        \\LEFT JOIN nodes t ON t.id = e_ht.to_id AND t.type = 'Test'
        \\WHERE e_tb.from_id = ? AND e_tb.label = 'TESTED_BY'
        \\ORDER BY tg.id, t.id
    );
    defer st.finalize();
    try st.bindText(1, requirement_ref);
    while (try st.step()) {
        if (!st.columnIsNull(0)) try appendUniqueString(&groups, st.columnText(0), alloc);
        if (!st.columnIsNull(1)) try appendUniqueString(&tests, st.columnText(1), alloc);
    }

    var latest_results = try alloc.alloc(LatestResult, tests.items.len);
    var passed_count: usize = 0;
    var missing_or_skipped_count: usize = 0;
    var has_failure = false;
    for (tests.items, 0..) |test_id, idx| {
        const latest = try latestResultForTest(db, test_id, alloc);
        latest_results[idx] = latest;
        if (latest.status) |status| {
            if (std.mem.eql(u8, status, "passed")) {
                passed_count += 1;
            } else if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "error") or std.mem.eql(u8, status, "blocked")) {
                has_failure = true;
            } else if (std.mem.eql(u8, status, "skipped")) {
                missing_or_skipped_count += 1;
            } else {
                missing_or_skipped_count += 1;
            }
        } else {
            missing_or_skipped_count += 1;
        }
    }

    const state: VerificationState = if (has_failure)
        .VERIFY_FAILED
    else if (tests.items.len == 0)
        .VERIFY_NONE
    else if (passed_count == tests.items.len)
        .VERIFIED
    else if (passed_count > 0)
        .VERIFY_PARTIAL
    else
        .VERIFY_NONE;

    return .{
        .requirement_ref = try alloc.dupe(u8, requirement_ref),
        .state = state,
        .linked_test_groups = try groups.toOwnedSlice(alloc),
        .linked_tests = latest_results,
    };
}

pub fn verificationJson(db: *graph_live.GraphDb, requirement_ref: []const u8, alloc: Allocator) ![]const u8 {
    var verification = try verificationForRequirement(db, requirement_ref, alloc);
    defer verification.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"requirement_ref\":");
    try shared.appendJsonStr(&buf, verification.requirement_ref, alloc);
    try buf.appendSlice(alloc, ",\"verification_state\":");
    try shared.appendJsonStr(&buf, @tagName(verification.state), alloc);
    try buf.appendSlice(alloc, ",\"linked_test_groups\":");
    const groups_json = try shared.jsonStringArray(verification.linked_test_groups, alloc);
    defer alloc.free(groups_json);
    try buf.appendSlice(alloc, groups_json);
    try buf.appendSlice(alloc, ",\"linked_tests\":[");
    for (verification.linked_tests, 0..) |latest, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"test_id\":");
        try shared.appendJsonStr(&buf, latest.test_id, alloc);
        try buf.appendSlice(alloc, ",\"execution_id\":");
        try shared.appendJsonStrOpt(&buf, latest.execution_id, alloc);
        try buf.appendSlice(alloc, ",\"result_id\":");
        try shared.appendJsonStrOpt(&buf, latest.result_id, alloc);
        try buf.appendSlice(alloc, ",\"status\":");
        try shared.appendJsonStrOpt(&buf, latest.status, alloc);
        try buf.appendSlice(alloc, ",\"executed_at\":");
        try shared.appendJsonStrOpt(&buf, latest.executed_at, alloc);
        try buf.appendSlice(alloc, ",\"resolution_state\":");
        try shared.appendJsonStrOpt(&buf, latest.resolution_state, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn danglingResultsJson(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\    json_extract(properties, '$.result_id'),
        \\    json_extract(properties, '$.test_case_ref'),
        \\    json_extract(properties, '$.execution_id'),
        \\    json_extract(properties, '$.status')
        \\FROM nodes
        \\WHERE type='TestResult' AND json_extract(properties, '$.resolution_state')='dangling'
        \\ORDER BY json_extract(properties, '$.execution_id'), json_extract(properties, '$.result_id')
    );
    defer st.finalize();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"results\":[");
    var first = true;
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"result_id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"test_case_ref\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"execution_id\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"status\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn unitHistoryJson(db: *graph_live.GraphDb, serial_number: []const u8, alloc: Allocator) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\    json_extract(properties, '$.execution_id'),
        \\    json_extract(properties, '$.executed_at'),
        \\    json_extract(properties, '$.computed_status')
        \\FROM nodes
        \\WHERE type='TestExecution' AND json_extract(properties, '$.serial_number')=?
        \\ORDER BY json_extract(properties, '$.executed_at') DESC, json_extract(properties, '$.execution_id') DESC
    );
    defer st.finalize();
    try st.bindText(1, serial_number);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"serial_number\":");
    try shared.appendJsonStr(&buf, serial_number, alloc);
    try buf.appendSlice(alloc, ",\"executions\":[");
    var first = true;
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"execution_id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"executed_at\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"computed_status\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn latestResultForTest(db: *graph_live.GraphDb, test_id: []const u8, alloc: Allocator) !LatestResult {
    var st = try db.db.prepare(
        \\SELECT
        \\    json_extract(r.properties, '$.result_id'),
        \\    json_extract(r.properties, '$.status'),
        \\    json_extract(r.properties, '$.resolution_state'),
        \\    json_extract(e.properties, '$.execution_id'),
        \\    json_extract(e.properties, '$.executed_at')
        \\FROM edges eo
        \\JOIN nodes r ON r.id = eo.from_id AND r.type='TestResult'
        \\LEFT JOIN edges hr ON hr.to_id = r.id AND hr.label = 'HAS_RESULT'
        \\LEFT JOIN nodes e ON e.id = hr.from_id AND e.type='TestExecution'
        \\WHERE eo.label='EXECUTION_OF' AND eo.to_id=?
        \\ORDER BY json_extract(e.properties, '$.executed_at') DESC, json_extract(r.properties, '$.result_id') DESC
        \\LIMIT 1
    );
    defer st.finalize();
    try st.bindText(1, test_id);
    if (!try st.step()) {
        return .{
            .test_id = try alloc.dupe(u8, test_id),
            .execution_id = null,
            .result_id = null,
            .status = null,
            .executed_at = null,
            .resolution_state = null,
        };
    }

    return .{
        .test_id = try alloc.dupe(u8, test_id),
        .execution_id = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
        .result_id = if (st.columnIsNull(0)) null else try alloc.dupe(u8, st.columnText(0)),
        .status = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
        .executed_at = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        .resolution_state = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
    };
}

pub fn executionJson(execution: ExecutionEnvelope, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"execution_id\":");
    try shared.appendJsonStr(&buf, execution.execution_id, alloc);
    try buf.appendSlice(alloc, ",\"executed_at\":");
    try shared.appendJsonStr(&buf, execution.executed_at, alloc);
    try buf.appendSlice(alloc, ",\"computed_status\":");
    try shared.appendJsonStr(&buf, execution.computed_status, alloc);
    try buf.appendSlice(alloc, ",\"serial_number\":");
    try shared.appendJsonStrOpt(&buf, execution.serial_number, alloc);
    try buf.appendSlice(alloc, ",\"full_product_identifier\":");
    try shared.appendJsonStrOpt(&buf, execution.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"product_resolution_state\":");
    try shared.appendJsonStrOpt(&buf, execution.product_resolution_state, alloc);
    try buf.appendSlice(alloc, ",\"executor\":");
    try buf.appendSlice(alloc, execution.executor_json orelse "null");
    try buf.appendSlice(alloc, ",\"source\":");
    try buf.appendSlice(alloc, execution.source_json orelse "null");
    try buf.appendSlice(alloc, ",\"test_cases\":[");
    for (execution.test_cases, 0..) |test_case, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"result_id\":");
        try shared.appendJsonStr(&buf, test_case.result_id, alloc);
        try buf.appendSlice(alloc, ",\"test_case_ref\":");
        try shared.appendJsonStr(&buf, test_case.test_case_ref, alloc);
        try buf.appendSlice(alloc, ",\"status\":");
        try shared.appendJsonStr(&buf, test_case.status, alloc);
        try buf.appendSlice(alloc, ",\"duration_ms\":");
        try shared.appendJsonIntOpt(&buf, test_case.duration_ms, alloc);
        try buf.appendSlice(alloc, ",\"notes\":");
        try shared.appendJsonStrOpt(&buf, test_case.notes, alloc);
        try buf.appendSlice(alloc, ",\"measurements\":");
        try buf.appendSlice(alloc, test_case.measurements_json);
        try buf.appendSlice(alloc, ",\"attachments\":");
        try buf.appendSlice(alloc, test_case.attachments_json);
        try buf.appendSlice(alloc, ",\"resolution_state\":");
        try shared.appendJsonStr(&buf, test_case.resolution_state, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn ingestResponseJson(response: IngestResponse, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"execution_id\":");
    try shared.appendJsonStr(&buf, response.execution_id, alloc);
    try buf.appendSlice(alloc, ",\"computed_status\":");
    try shared.appendJsonStr(&buf, @tagName(response.computed_status), alloc);
    try std.fmt.format(buf.writer(alloc), ",\"inserted\":{d},\"warnings\":[", .{response.inserted});
    for (response.warnings, 0..) |warning, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"result_id\":");
        try shared.appendJsonStr(&buf, warning.result_id, alloc);
        try buf.appendSlice(alloc, ",\"test_case_ref\":");
        try shared.appendJsonStr(&buf, warning.test_case_ref, alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStrOpt(&buf, warning.full_product_identifier, alloc);
        try buf.appendSlice(alloc, ",\"code\":");
        try shared.appendJsonStr(&buf, warning.code, alloc);
        try buf.appendSlice(alloc, ",\"message\":");
        try shared.appendJsonStr(&buf, warning.message, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

fn listExecutionResults(db: *graph_live.GraphDb, execution_id: []const u8, alloc: Allocator, result: *std.ArrayList(StoredResult)) !void {
    const execution_node_id = try executionNodeId(execution_id, alloc);
    defer alloc.free(execution_node_id);
    var st = try db.db.prepare(
        \\SELECT
        \\    json_extract(r.properties, '$.result_id'),
        \\    json_extract(r.properties, '$.test_case_ref'),
        \\    json_extract(r.properties, '$.status'),
        \\    json_extract(r.properties, '$.duration_ms'),
        \\    json_extract(r.properties, '$.notes'),
        \\    json_extract(r.properties, '$.measurements'),
        \\    json_extract(r.properties, '$.attachments'),
        \\    json_extract(r.properties, '$.resolution_state')
        \\FROM edges hr
        \\JOIN nodes r ON r.id = hr.to_id AND r.type='TestResult'
        \\WHERE hr.from_id = ? AND hr.label='HAS_RESULT'
        \\ORDER BY json_extract(r.properties, '$.result_id')
    );
    defer st.finalize();
    try st.bindText(1, execution_node_id);
    while (try st.step()) {
        try result.append(alloc, .{
            .result_id = try alloc.dupe(u8, st.columnText(0)),
            .test_case_ref = try alloc.dupe(u8, st.columnText(1)),
            .status = try alloc.dupe(u8, st.columnText(2)),
            .duration_ms = if (st.columnIsNull(3)) null else st.columnInt(3),
            .notes = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
            .measurements_json = if (st.columnIsNull(5)) try alloc.dupe(u8, "[]") else try alloc.dupe(u8, st.columnText(5)),
            .attachments_json = if (st.columnIsNull(6)) try alloc.dupe(u8, "[]") else try alloc.dupe(u8, st.columnText(6)),
            .resolution_state = try alloc.dupe(u8, st.columnText(7)),
        });
    }
}

fn rejectIfSuperseded(db: *graph_live.GraphDb, existing: ExecutionEnvelope) (IngestError || db_mod.DbError)!void {
    for (existing.test_cases) |test_case| {
        var st = try db.db.prepare(
            \\SELECT json_extract(e.properties, '$.executed_at'), json_extract(e.properties, '$.execution_id')
            \\FROM edges eo
            \\JOIN nodes r ON r.id = eo.from_id AND r.type='TestResult'
            \\LEFT JOIN edges hr ON hr.to_id = r.id AND hr.label='HAS_RESULT'
            \\LEFT JOIN nodes e ON e.id = hr.from_id AND e.type='TestExecution'
            \\WHERE eo.label='EXECUTION_OF' AND eo.to_id=?
            \\ORDER BY json_extract(e.properties, '$.executed_at') DESC, json_extract(e.properties, '$.execution_id') DESC
            \\LIMIT 1
        );
        defer st.finalize();
        try st.bindText(1, test_case.test_case_ref);
        if (!(try st.step())) continue;
        const latest_executed_at = st.columnText(0);
        const latest_execution_id = st.columnText(1);
        if (!std.mem.eql(u8, latest_execution_id, existing.execution_id) and std.mem.order(u8, latest_executed_at, existing.executed_at) == .gt) {
            return error.ExecutionSuperseded;
        }
    }
}

fn deleteExecutionSubtreeLocked(db: *graph_live.GraphDb, execution_id: []const u8) !void {
    const execution_node_id = try executionNodeId(execution_id, std.heap.page_allocator);
    defer std.heap.page_allocator.free(execution_node_id);

    var result_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (result_ids.items) |value| std.heap.page_allocator.free(value);
        result_ids.deinit(std.heap.page_allocator);
    }

    {
        var st = try db.db.prepare("SELECT to_id FROM edges WHERE from_id=? AND label='HAS_RESULT'");
        defer st.finalize();
        try st.bindText(1, execution_node_id);
        while (try st.step()) {
            try result_ids.append(std.heap.page_allocator, try std.heap.page_allocator.dupe(u8, st.columnText(0)));
        }
    }

    for (result_ids.items) |result_node_id| {
        try deleteNodeLocked(db, result_node_id);
    }
    try deleteNodeLocked(db, execution_node_id);
}

fn deleteNodeLocked(db: *graph_live.GraphDb, node_id: []const u8) !void {
    {
        var st = try db.db.prepare("DELETE FROM edges WHERE from_id=? OR to_id=?");
        defer st.finalize();
        try st.bindText(1, node_id);
        try st.bindText(2, node_id);
        _ = try st.step();
    }
    {
        var st = try db.db.prepare("DELETE FROM nodes WHERE id=?");
        defer st.finalize();
        try st.bindText(1, node_id);
        _ = try st.step();
    }
}

fn upsertNodeLocked(db: *graph_live.GraphDb, node_id: []const u8, node_type: []const u8, properties_json: []const u8) !void {
    const now = std.time.timestamp();
    var st = try db.db.prepare(
        \\INSERT INTO nodes (id, type, properties, row_hash, created_at, updated_at, suspect, suspect_reason)
        \\VALUES (?, ?, ?, NULL, ?, ?, 0, NULL)
        \\ON CONFLICT(id) DO UPDATE SET type=excluded.type, properties=excluded.properties, updated_at=excluded.updated_at
    );
    defer st.finalize();
    try st.bindText(1, node_id);
    try st.bindText(2, node_type);
    try st.bindText(3, properties_json);
    try st.bindInt(4, now);
    try st.bindInt(5, now);
    _ = try st.step();
}

fn addEdgeLocked(db: *graph_live.GraphDb, from_id: []const u8, to_id: []const u8, label: []const u8) !void {
    var chk = try db.db.prepare("SELECT 1 FROM edges WHERE from_id=? AND to_id=? AND label=?");
    defer chk.finalize();
    try chk.bindText(1, from_id);
    try chk.bindText(2, to_id);
    try chk.bindText(3, label);
    if (try chk.step()) return;

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(from_id);
    h.update("|");
    h.update(to_id);
    h.update("|");
    h.update(label);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const edge_id = std.fmt.bytesToHex(digest, .lower);

    var st = try db.db.prepare(
        "INSERT INTO edges (id, from_id, to_id, label, properties, created_at) VALUES (?, ?, ?, ?, NULL, ?)"
    );
    defer st.finalize();
    try st.bindText(1, &edge_id);
    try st.bindText(2, from_id);
    try st.bindText(3, to_id);
    try st.bindText(4, label);
    try st.bindInt(5, std.time.timestamp());
    _ = try st.step();
}

fn executionPropertiesJson(payload: ExecutionInput, product_resolution_state: ?[]const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"execution_id\":");
    try shared.appendJsonStr(&buf, payload.execution_id, alloc);
    try buf.appendSlice(alloc, ",\"executed_at\":");
    try shared.appendJsonStr(&buf, payload.executed_at, alloc);
    try buf.appendSlice(alloc, ",\"computed_status\":");
    try shared.appendJsonStr(&buf, @tagName(computeStatus(payload.test_cases)), alloc);
    try buf.appendSlice(alloc, ",\"serial_number\":");
    try shared.appendJsonStrOpt(&buf, payload.serial_number, alloc);
    try buf.appendSlice(alloc, ",\"full_product_identifier\":");
    try shared.appendJsonStrOpt(&buf, payload.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"product_resolution_state\":");
    try shared.appendJsonStrOpt(&buf, product_resolution_state, alloc);
    try buf.appendSlice(alloc, ",\"executor\":");
    try buf.appendSlice(alloc, payload.executor_json orelse "null");
    try buf.appendSlice(alloc, ",\"source\":");
    try buf.appendSlice(alloc, payload.source_json orelse "null");
    try std.fmt.format(buf.writer(alloc), ",\"ingested_at\":{d}}}", .{std.time.timestamp()});
    return alloc.dupe(u8, buf.items);
}

fn resultPropertiesJson(execution_id: []const u8, test_case: TestCaseInput, resolution_state: []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"result_id\":");
    try shared.appendJsonStr(&buf, test_case.result_id, alloc);
    try buf.appendSlice(alloc, ",\"execution_id\":");
    try shared.appendJsonStr(&buf, execution_id, alloc);
    try buf.appendSlice(alloc, ",\"test_case_ref\":");
    try shared.appendJsonStr(&buf, test_case.test_case_ref, alloc);
    try buf.appendSlice(alloc, ",\"status\":");
    try shared.appendJsonStr(&buf, test_case.status, alloc);
    try buf.appendSlice(alloc, ",\"duration_ms\":");
    try shared.appendJsonIntOpt(&buf, test_case.duration_ms, alloc);
    try buf.appendSlice(alloc, ",\"notes\":");
    try shared.appendJsonStrOpt(&buf, test_case.notes, alloc);
    try buf.appendSlice(alloc, ",\"measurements\":");
    try buf.appendSlice(alloc, test_case.measurements_json);
    try buf.appendSlice(alloc, ",\"attachments\":");
    try buf.appendSlice(alloc, test_case.attachments_json);
    try buf.appendSlice(alloc, ",\"resolution_state\":");
    try shared.appendJsonStr(&buf, resolution_state, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn computeStatus(test_cases: []const TestCaseInput) PostStatus {
    var saw_non_pass = false;
    for (test_cases) |test_case| {
        if (std.mem.eql(u8, test_case.status, "failed") or
            std.mem.eql(u8, test_case.status, "error") or
            std.mem.eql(u8, test_case.status, "blocked"))
        {
            return .failed;
        }
        if (!std.mem.eql(u8, test_case.status, "passed")) saw_non_pass = true;
    }
    return if (saw_non_pass) .partial else .passed;
}

fn isAllowedCaseStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "passed") or
        std.mem.eql(u8, status, "failed") or
        std.mem.eql(u8, status, "skipped") or
        std.mem.eql(u8, status, "error") or
        std.mem.eql(u8, status, "blocked");
}

fn isLikelyIso8601Timestamp(value: []const u8) bool {
    if (value.len < 20) return false;
    return std.ascii.isDigit(value[0]) and
        std.ascii.isDigit(value[1]) and
        std.ascii.isDigit(value[2]) and
        std.ascii.isDigit(value[3]) and
        value[4] == '-' and
        value[7] == '-' and
        value[10] == 'T' and
        value[13] == ':' and
        value[16] == ':';
}

fn executionNodeId(execution_id: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "execution://{s}", .{execution_id});
}

fn resultNodeId(result_id: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "test-result://{s}", .{result_id});
}

fn productNodeId(full_product_identifier: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "product://{s}", .{full_product_identifier});
}

fn appendUniqueString(items: *std.ArrayList([]const u8), value: []const u8, alloc: Allocator) !void {
    for (items.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try items.append(alloc, try alloc.dupe(u8, value));
}

const testing = std.testing;

test "computed status passed" {
    const items = [_]TestCaseInput{
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
    };
    try testing.expectEqual(PostStatus.passed, computeStatus(&items));
}

test "computed status failed" {
    const items = [_]TestCaseInput{
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
        .{ .result_id = "", .test_case_ref = "", .status = "blocked", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
    };
    try testing.expectEqual(PostStatus.failed, computeStatus(&items));
}

test "computed status partial" {
    const items = [_]TestCaseInput{
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
        .{ .result_id = "", .test_case_ref = "", .status = "skipped", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
    };
    try testing.expectEqual(PostStatus.partial, computeStatus(&items));
}

test "payload parse round trips measurements and attachments" {
    const body =
        \\{
        \\  "execution_id": "build-4821",
        \\  "executed_at": "2026-03-12T14:32:00Z",
        \\  "test_cases": [
        \\    {
        \\      "result_id": "build-4821-TC-001",
        \\      "test_case_ref": "TC-001",
        \\      "status": "passed",
        \\      "duration_ms": 483,
        \\      "measurements": [{"name":"voltage","value":5.1}],
        \\      "attachments": [{"name":"log","url":"https://example.com/log"}]
        \\    }
        \\  ]
        \\}
    ;
    var payload = try parsePayload(body, testing.allocator);
    defer payload.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, payload.test_cases[0].measurements_json, "\"voltage\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload.test_cases[0].attachments_json, "\"log\"") != null);
}

test "payload parse accepts optional full_product_identifier" {
    const body =
        \\{
        \\  "execution_id": "build-9001",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "full_product_identifier": "ASM-001-A",
        \\  "test_cases": [
        \\    {
        \\      "result_id": "build-9001-TC-001",
        \\      "test_case_ref": "TC-001",
        \\      "status": "passed"
        \\    }
        \\  ]
        \\}
    ;
    var payload = try parsePayload(body, testing.allocator);
    defer payload.deinit(testing.allocator);
    try testing.expectEqualStrings("ASM-001-A", payload.full_product_identifier.?);
}

test "ingest creates FOR_PRODUCT edge when full_product_identifier resolves" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    {
        db.db.write_mu.lock();
        defer db.db.write_mu.unlock();
        try upsertNodeLocked(&db, "product://ASM-001-A", "Product", "{\"full_identifier\":\"ASM-001-A\"}");
        try upsertNodeLocked(&db, "TST-001", "Test", "{\"id\":\"TST-001\"}");
    }

    var payload = ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "build-9002"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-14T14:32:00Z"),
        .serial_number = null,
        .full_product_identifier = try testing.allocator.dupe(u8, "ASM-001-A"),
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(TestCaseInput, 1),
    };
    payload.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "build-9002-TC-001"),
        .test_case_ref = try testing.allocator.dupe(u8, "TST-001"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[]"),
        .attachments_json = try testing.allocator.dupe(u8, "[]"),
    };
    defer payload.deinit(testing.allocator);

    var response = try ingest(&db, payload, testing.allocator);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), response.warnings.len);

    var execution = (try getExecution(&db, "build-9002", testing.allocator)).?;
    defer execution.deinit(testing.allocator);
    try testing.expectEqualStrings("ASM-001-A", execution.full_product_identifier.?);
    try testing.expectEqualStrings("resolved", execution.product_resolution_state.?);

    var edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges.items) |edge| {
            testing.allocator.free(edge.id);
            testing.allocator.free(edge.from_id);
            testing.allocator.free(edge.to_id);
            testing.allocator.free(edge.label);
        }
        edges.deinit(testing.allocator);
    }
    try db.edgesFrom("execution://build-9002", testing.allocator, &edges);
    var found = false;
    for (edges.items) |edge| {
        if (std.mem.eql(u8, edge.label, "FOR_PRODUCT") and std.mem.eql(u8, edge.to_id, "product://ASM-001-A")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ingest stores dangling product resolution warning when full_product_identifier is unresolved" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    {
        db.db.write_mu.lock();
        defer db.db.write_mu.unlock();
        try upsertNodeLocked(&db, "TST-001", "Test", "{\"id\":\"TST-001\"}");
    }

    var payload = ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "build-9003"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-14T14:32:00Z"),
        .serial_number = null,
        .full_product_identifier = try testing.allocator.dupe(u8, "ASM-404-Z"),
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(TestCaseInput, 1),
    };
    payload.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "build-9003-TC-001"),
        .test_case_ref = try testing.allocator.dupe(u8, "TST-001"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[]"),
        .attachments_json = try testing.allocator.dupe(u8, "[]"),
    };
    defer payload.deinit(testing.allocator);

    var response = try ingest(&db, payload, testing.allocator);
    defer response.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), response.warnings.len);
    try testing.expectEqualStrings("DANGLING_PRODUCT_REF", response.warnings[0].code);
    try testing.expectEqualStrings("ASM-404-Z", response.warnings[0].full_product_identifier.?);

    var execution = (try getExecution(&db, "build-9003", testing.allocator)).?;
    defer execution.deinit(testing.allocator);
    try testing.expectEqualStrings("ASM-404-Z", execution.full_product_identifier.?);
    try testing.expectEqualStrings("dangling", execution.product_resolution_state.?);

    var edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges.items) |edge| {
            testing.allocator.free(edge.id);
            testing.allocator.free(edge.from_id);
            testing.allocator.free(edge.to_id);
            testing.allocator.free(edge.label);
        }
        edges.deinit(testing.allocator);
    }
    try db.edgesFrom("execution://build-9003", testing.allocator, &edges);
    for (edges.items) |edge| {
        try testing.expect(!std.mem.eql(u8, edge.label, "FOR_PRODUCT"));
    }
}
