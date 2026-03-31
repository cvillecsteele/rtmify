const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const ingest_mod = @import("ingest.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub fn getExecution(db: *graph_live.GraphDb, execution_id: []const u8, alloc: Allocator) !?types.ExecutionEnvelope {
    const execution_node_id = try ids.executionNodeId(execution_id, alloc);
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

    var results: std.ArrayList(types.StoredResult) = .empty;
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

pub fn latestResultForTest(db: *graph_live.GraphDb, test_id: []const u8, alloc: Allocator) !types.LatestResult {
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

pub fn executionJson(execution: types.ExecutionEnvelope, alloc: Allocator) ![]const u8 {
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

pub fn ingestResponseJson(response: types.IngestResponse, alloc: Allocator) ![]const u8 {
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

fn listExecutionResults(
    db: *graph_live.GraphDb,
    execution_id: []const u8,
    alloc: Allocator,
    result: *std.ArrayList(types.StoredResult),
) !void {
    const execution_node_id = try ids.executionNodeId(execution_id, alloc);
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

const testing = std.testing;

fn seedTestNode(db: *graph_live.GraphDb, test_id: []const u8) !void {
    try db.addNode(test_id, "Test", "{}", null);
}

fn seedExecution(
    db: *graph_live.GraphDb,
    execution_id: []const u8,
    executed_at: []const u8,
    serial_number: ?[]const u8,
    full_product_identifier: ?[]const u8,
    executor_json: ?[]const u8,
    source_json: ?[]const u8,
    cases: []const struct { result_id: []const u8, test_case_ref: []const u8, status: []const u8 },
) !void {
    var payload = types.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, execution_id),
        .executed_at = try testing.allocator.dupe(u8, executed_at),
        .serial_number = if (serial_number) |value| try testing.allocator.dupe(u8, value) else null,
        .full_product_identifier = if (full_product_identifier) |value| try testing.allocator.dupe(u8, value) else null,
        .executor_json = if (executor_json) |value| try testing.allocator.dupe(u8, value) else null,
        .source_json = if (source_json) |value| try testing.allocator.dupe(u8, value) else null,
        .test_cases = try testing.allocator.alloc(types.TestCaseInput, cases.len),
    };
    defer payload.deinit(testing.allocator);
    for (cases, 0..) |item, idx| {
        payload.test_cases[idx] = .{
            .result_id = try testing.allocator.dupe(u8, item.result_id),
            .test_case_ref = try testing.allocator.dupe(u8, item.test_case_ref),
            .status = try testing.allocator.dupe(u8, item.status),
            .duration_ms = null,
            .notes = null,
            .measurements_json = try testing.allocator.dupe(u8, "[]"),
            .attachments_json = try testing.allocator.dupe(u8, "[]"),
        };
    }

    var response = try ingest_mod.ingest(db, payload, testing.allocator);
    defer response.deinit(testing.allocator);
}

test "getExecution returns null when execution missing" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try testing.expect((try getExecution(&db, "missing", testing.allocator)) == null);
}

test "latestResultForTest returns null payload fields when no result exists" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var latest = try latestResultForTest(&db, "TST-404", testing.allocator);
    defer latest.deinit(testing.allocator);
    try testing.expectEqualStrings("TST-404", latest.test_id);
    try testing.expect(latest.execution_id == null);
    try testing.expect(latest.result_id == null);
    try testing.expect(latest.status == null);
    try testing.expect(latest.executed_at == null);
    try testing.expect(latest.resolution_state == null);
}

test "ingestResponseJson preserves warnings array shape and enum serialization" {
    var response = types.IngestResponse{
        .execution_id = try testing.allocator.dupe(u8, "exec-1"),
        .computed_status = .partial,
        .inserted = 2,
        .warnings = try testing.allocator.alloc(types.IngestWarning, 1),
    };
    defer response.deinit(testing.allocator);
    response.warnings[0] = .{
        .result_id = try testing.allocator.dupe(u8, "r-1"),
        .test_case_ref = try testing.allocator.dupe(u8, "T-1"),
        .full_product_identifier = null,
        .code = try testing.allocator.dupe(u8, "DANGLING_REF"),
        .message = try testing.allocator.dupe(u8, "No Test node found"),
    };

    const json = try ingestResponseJson(response, testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"computed_status\":\"partial\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"warnings\":[{") != null);
}

test "executionJson preserves arrays not stringified strings" {
    var execution = types.ExecutionEnvelope{
        .execution_id = try testing.allocator.dupe(u8, "exec-1"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-12T14:32:00Z"),
        .computed_status = try testing.allocator.dupe(u8, "passed"),
        .serial_number = null,
        .full_product_identifier = null,
        .product_resolution_state = null,
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(types.StoredResult, 1),
    };
    defer execution.deinit(testing.allocator);
    execution.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "r-1"),
        .test_case_ref = try testing.allocator.dupe(u8, "T-1"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[{\"name\":\"v\"}]"),
        .attachments_json = try testing.allocator.dupe(u8, "[{\"name\":\"log\"}]"),
        .resolution_state = try testing.allocator.dupe(u8, "resolved"),
    };

    const json = try executionJson(execution, testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"measurements\":[{\"name\":\"v\"}]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"attachments\":[{\"name\":\"log\"}]") != null);
}

test "getExecutionJson preserves null serial full product identifier executor and source" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedTestNode(&db, "TEST-001");
    try seedExecution(&db, "exec-1", "2026-03-31T12:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
    });

    const json = (try getExecutionJson(&db, "exec-1", testing.allocator)).?;
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"serial_number\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"full_product_identifier\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"executor\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source\":null") != null);
}

test "getExecution returns results ordered by result id ascending inside a single execution" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedTestNode(&db, "TEST-001");
    try seedTestNode(&db, "TEST-002");
    try seedExecution(&db, "exec-1", "2026-03-31T12:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-2", .test_case_ref = "TEST-002", .status = "passed" },
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
    });

    var execution = (try getExecution(&db, "exec-1", testing.allocator)).?;
    defer execution.deinit(testing.allocator);
    try testing.expectEqualStrings("r-1", execution.test_cases[0].result_id);
    try testing.expectEqualStrings("r-2", execution.test_cases[1].result_id);
}

test "getTestResultsJson orders by executed_at desc then result_id asc" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedTestNode(&db, "TEST-001");
    try seedExecution(&db, "exec-older", "2026-03-31T10:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-9", .test_case_ref = "TEST-001", .status = "passed" },
    });
    try seedExecution(&db, "exec-newer", "2026-03-31T11:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-2", .test_case_ref = "TEST-001", .status = "failed" },
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
    });

    const json = try getTestResultsJson(&db, "TEST-001", testing.allocator);
    defer testing.allocator.free(json);
    const r1_idx = std.mem.indexOf(u8, json, "\"result_id\":\"r-1\"").?;
    const r2_idx = std.mem.indexOf(u8, json, "\"result_id\":\"r-2\"").?;
    const r9_idx = std.mem.indexOf(u8, json, "\"result_id\":\"r-9\"").?;
    try testing.expect(r1_idx < r2_idx);
    try testing.expect(r2_idx < r9_idx);
}

test "danglingResultsJson includes only results with resolution_state dangling" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try seedExecution(&db, "exec-dangling", "2026-03-31T10:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-d", .test_case_ref = "TEST-404", .status = "passed" },
    });
    try seedTestNode(&db, "TEST-001");
    try seedExecution(&db, "exec-resolved", "2026-03-31T11:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-ok", .test_case_ref = "TEST-001", .status = "passed" },
    });

    const json = try danglingResultsJson(&db, testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"result_id\":\"r-d\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"result_id\":\"r-ok\"") == null);
}

test "unitHistoryJson orders executions by executed_at desc then execution_id desc" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedTestNode(&db, "TEST-001");
    try seedExecution(&db, "exec-a", "2026-03-31T10:00:00Z", "SN-1", null, null, null, &.{
        .{ .result_id = "r-a", .test_case_ref = "TEST-001", .status = "passed" },
    });
    try seedExecution(&db, "exec-c", "2026-03-31T11:00:00Z", "SN-1", null, null, null, &.{
        .{ .result_id = "r-c", .test_case_ref = "TEST-001", .status = "passed" },
    });
    try seedExecution(&db, "exec-b", "2026-03-31T11:00:00Z", "SN-1", null, null, null, &.{
        .{ .result_id = "r-b", .test_case_ref = "TEST-001", .status = "passed" },
    });

    const json = try unitHistoryJson(&db, "SN-1", testing.allocator);
    defer testing.allocator.free(json);
    const c_idx = std.mem.indexOf(u8, json, "\"execution_id\":\"exec-c\"").?;
    const b_idx = std.mem.indexOf(u8, json, "\"execution_id\":\"exec-b\"").?;
    const a_idx = std.mem.indexOf(u8, json, "\"execution_id\":\"exec-a\"").?;
    try testing.expect(c_idx < b_idx);
    try testing.expect(b_idx < a_idx);
}

test "getExecutionJson preserves measurements and attachments as raw arrays" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const execution_node_id = try ids.executionNodeId("exec-1", testing.allocator);
    defer testing.allocator.free(execution_node_id);
    try db.addNode(execution_node_id, "TestExecution", "{\"execution_id\":\"exec-1\",\"executed_at\":\"2026-03-31T12:00:00Z\",\"computed_status\":\"passed\",\"serial_number\":null,\"full_product_identifier\":null,\"product_resolution_state\":null,\"executor\":null,\"source\":null}", null);
    try db.addNode("result-node-1", "TestResult", "{\"result_id\":\"r-1\",\"test_case_ref\":\"TEST-1\",\"status\":\"passed\",\"duration_ms\":null,\"notes\":null,\"measurements\":[{\"name\":\"v\"}],\"attachments\":[{\"name\":\"a\"}],\"resolution_state\":\"resolved\"}", null);
    try db.addEdge(execution_node_id, "result-node-1", "HAS_RESULT");

    const json = (try getExecutionJson(&db, "exec-1", testing.allocator)).?;
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"measurements\":[{\"name\":\"v\"}]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"attachments\":[{\"name\":\"a\"}]") != null);
}

test "latestResultForTest chooses newest execution then highest result id tie breaker" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedTestNode(&db, "TEST-001");
    try seedExecution(&db, "exec-1", "2026-03-31T10:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
    });
    try seedExecution(&db, "exec-2", "2026-03-31T11:00:00Z", null, null, null, null, &.{
        .{ .result_id = "r-2", .test_case_ref = "TEST-001", .status = "skipped" },
        .{ .result_id = "r-3", .test_case_ref = "TEST-001", .status = "failed" },
    });

    var latest = try latestResultForTest(&db, "TEST-001", testing.allocator);
    defer latest.deinit(testing.allocator);
    try testing.expectEqualStrings("exec-2", latest.execution_id.?);
    try testing.expectEqualStrings("r-3", latest.result_id.?);
    try testing.expectEqualStrings("failed", latest.status.?);
}
