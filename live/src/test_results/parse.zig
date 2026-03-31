const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("../json_util.zig");
const types = @import("types.zig");

pub fn parsePayload(body: []const u8, alloc: Allocator) (types.ValidationError || error{OutOfMemory})!types.ExecutionInput {
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

    var initialized_test_cases: usize = 0;
    var test_cases = try alloc.alloc(types.TestCaseInput, test_cases_value.array.items.len);
    errdefer {
        for (test_cases[0..initialized_test_cases]) |*test_case| {
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
        initialized_test_cases += 1;
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

const testing = std.testing;

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

test "invalid root JSON returns InvalidJson" {
    try testing.expectError(error.InvalidJson, parsePayload("{", testing.allocator));
}

test "missing test cases returns MissingTestCases" {
    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z"
        \\}
    ;
    try testing.expectError(error.MissingTestCases, parsePayload(body, testing.allocator));
}

test "empty test cases returns EmptyTestCases" {
    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "test_cases": []
        \\}
    ;
    try testing.expectError(error.EmptyTestCases, parsePayload(body, testing.allocator));
}

test "non array measurements returns InvalidMeasurements" {
    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "test_cases": [{"result_id":"r-1","test_case_ref":"T-1","status":"passed","measurements":{}}]
        \\}
    ;
    try testing.expectError(error.InvalidMeasurements, parsePayload(body, testing.allocator));
}

test "non array attachments returns InvalidAttachments" {
    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "test_cases": [{"result_id":"r-1","test_case_ref":"T-1","status":"passed","attachments":{}}]
        \\}
    ;
    try testing.expectError(error.InvalidAttachments, parsePayload(body, testing.allocator));
}

test "invalid status returns InvalidCaseStatus" {
    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "test_cases": [{"result_id":"r-1","test_case_ref":"T-1","status":"meh"}]
        \\}
    ;
    try testing.expectError(error.InvalidCaseStatus, parsePayload(body, testing.allocator));
}

test "invalid duration type returns InvalidDurationMs" {
    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "test_cases": [{"result_id":"r-1","test_case_ref":"T-1","status":"passed","duration_ms":"fast"}]
        \\}
    ;
    try testing.expectError(error.InvalidDurationMs, parsePayload(body, testing.allocator));
}

test "invalid executor and source object types return existing errors" {
    const executor_body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "executor": "robot",
        \\  "test_cases": [{"result_id":"r-1","test_case_ref":"T-1","status":"passed"}]
        \\}
    ;
    try testing.expectError(error.InvalidExecutor, parsePayload(executor_body, testing.allocator));

    const source_body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-14T14:32:00Z",
        \\  "source": "api",
        \\  "test_cases": [{"result_id":"r-1","test_case_ref":"T-1","status":"passed"}]
        \\}
    ;
    try testing.expectError(error.InvalidSource, parsePayload(source_body, testing.allocator));
}

test "invalid timestamp returns InvalidExecutedAt" {
    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "03/14/2026",
        \\  "test_cases": [{"result_id":"r-1","test_case_ref":"T-1","status":"passed"}]
        \\}
    ;
    try testing.expectError(error.InvalidExecutedAt, parsePayload(body, testing.allocator));
}
