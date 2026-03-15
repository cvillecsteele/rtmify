const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const test_results = @import("../test_results.zig");
const test_results_auth = @import("../test_results_auth.zig");
const shared = @import("shared.zig");

fn validationErrorField(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingExecutionId => "execution_id",
        error.MissingExecutedAt, error.InvalidExecutedAt => "executed_at",
        error.InvalidFullProductIdentifier => "full_product_identifier",
        error.MissingTestCases, error.EmptyTestCases => "test_cases",
        error.InvalidExecutor => "executor",
        error.InvalidSource => "source",
        error.MissingResultId => "test_cases[].result_id",
        error.MissingTestCaseRef => "test_cases[].test_case_ref",
        error.MissingCaseStatus, error.InvalidCaseStatus => "test_cases[].status",
        error.InvalidDurationMs => "test_cases[].duration_ms",
        error.InvalidMeasurements => "test_cases[].measurements",
        error.InvalidAttachments => "test_cases[].attachments",
        error.InvalidJson, error.OutOfMemory => null,
        else => null,
    };
}

fn validationErrorDetail(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidJson => "Invalid JSON body.",
        error.MissingExecutionId => "Missing execution_id.",
        error.MissingExecutedAt => "Missing executed_at.",
        error.InvalidExecutedAt => "executed_at must be an ISO-8601 timestamp.",
        error.InvalidFullProductIdentifier => "full_product_identifier must be a string.",
        error.MissingTestCases => "Missing test_cases array.",
        error.EmptyTestCases => "test_cases must contain at least one item.",
        error.InvalidExecutor => "executor must be an object.",
        error.InvalidSource => "source must be an object.",
        error.MissingResultId => "Each test case must include result_id.",
        error.MissingTestCaseRef => "Each test case must include test_case_ref.",
        error.MissingCaseStatus => "Each test case must include status.",
        error.InvalidCaseStatus => "status must be one of passed, failed, skipped, error, or blocked.",
        error.InvalidDurationMs => "duration_ms must be an integer.",
        error.InvalidMeasurements => "measurements must be an array.",
        error.InvalidAttachments => "attachments must be an array.",
        error.OutOfMemory => "Request body could not be processed.",
        else => "Invalid test result payload.",
    };
}

fn validationErrorJson(err: anyerror, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"error\":\"invalid_payload\",\"detail\":");
    try shared.appendJsonStr(&buf, validationErrorDetail(err), alloc);
    try buf.appendSlice(alloc, ",\"field\":");
    try shared.appendJsonStrOpt(&buf, validationErrorField(err), alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn handlePostTestResults(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    body: []const u8,
    alloc: Allocator,
) ![]const u8 {
    const resp = try handlePostTestResultsResponse(db, auth, authorization, body, alloc);
    return resp.body;
}

pub fn handlePostTestResultsResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    body: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    var payload = test_results.parsePayload(body, alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            return shared.jsonRouteResponse(
                .bad_request,
                try validationErrorJson(err, alloc),
                false,
            );
        },
    };
    defer payload.deinit(alloc);

    var response = test_results.ingest(db, payload, alloc) catch |err| switch (err) {
        error.ExecutionSuperseded => {
            return shared.jsonRouteResponse(
                .conflict,
                try std.fmt.allocPrint(alloc, "{{\"error\":\"execution_superseded\",\"execution_id\":\"{s}\"}}", .{payload.execution_id}),
                false,
            );
        },
        else => {
            std.log.err("test result ingestion failed: {s}", .{@errorName(err)});
            return shared.jsonRouteResponse(.internal_server_error, try alloc.dupe(u8, "{\"error\":\"ingest_failed\"}"), false);
        },
    };
    defer response.deinit(alloc);

    return shared.jsonRouteResponse(.ok, try test_results.ingestResponseJson(response, alloc), true);
}

pub fn handleGetExecution(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    execution_id: []const u8,
    alloc: Allocator,
) ![]const u8 {
    const resp = try handleGetExecutionResponse(db, auth, authorization, execution_id, alloc);
    return resp.body;
}

pub fn handleGetExecutionResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    execution_id: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const body = (try test_results.getExecutionJson(db, execution_id, alloc)) orelse
        return shared.jsonRouteResponse(.not_found, try alloc.dupe(u8, "{\"error\":\"execution_not_found\"}"), false);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleRegenerateTestResultsToken(auth: *test_results_auth.AuthState, alloc: Allocator) ![]const u8 {
    const resp = try handleRegenerateTestResultsTokenResponse(auth, alloc);
    return resp.body;
}

pub fn handleRegenerateTestResultsTokenResponse(auth: *test_results_auth.AuthState, alloc: Allocator) !shared.JsonRouteResponse {
    const token = try auth.regenerate(alloc);
    defer alloc.free(token);
    return shared.jsonRouteResponse(
        .ok,
        try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"test_results_token\":\"{s}\"}}", .{token}),
        true,
    );
}

const testing = std.testing;

test "POST without token returns 401" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);

    const resp = try handlePostTestResultsResponse(&db, &auth, null, "{}", testing.allocator);
    try testing.expectEqual(std.http.Status.unauthorized, resp.status);
}

test "GET without token returns 401" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);

    const resp = try handleGetExecutionResponse(&db, &auth, null, "build-1", testing.allocator);
    try testing.expectEqual(std.http.Status.unauthorized, resp.status);
}

test "token regenerate route returns new token" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);

    const before = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(before);
    const resp = try handleRegenerateTestResultsTokenResponse(&auth, testing.allocator);
    defer testing.allocator.free(resp.body);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, before) == null);
}

test "invalid payload returns structured validation error" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const header = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(header);

    const resp = try handlePostTestResultsResponse(&db, &auth, header, "{\"execution_id\":\"x\"}", testing.allocator);
    defer testing.allocator.free(resp.body);
    try testing.expectEqual(std.http.Status.bad_request, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"invalid_payload\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"field\":\"executed_at\"") != null);
}
