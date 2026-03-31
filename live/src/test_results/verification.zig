const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const ingest_mod = @import("ingest.zig");
const query = @import("query.zig");
const types = @import("types.zig");

pub fn verificationForRequirement(
    db: *graph_live.GraphDb,
    requirement_ref: []const u8,
    alloc: Allocator,
) !types.RequirementVerification {
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

    var latest_results = try alloc.alloc(types.LatestResult, tests.items.len);
    var passed_count: usize = 0;
    var has_failure = false;
    for (tests.items, 0..) |test_id, idx| {
        const latest = try query.latestResultForTest(db, test_id, alloc);
        latest_results[idx] = latest;
        if (latest.status) |status| {
            if (std.mem.eql(u8, status, "passed")) {
                passed_count += 1;
            } else if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "error") or std.mem.eql(u8, status, "blocked")) {
                has_failure = true;
            }
        }
    }

    const state: types.VerificationState = if (has_failure)
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

pub fn computeStatus(test_cases: []const types.TestCaseInput) types.PostStatus {
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

fn appendUniqueString(items: *std.ArrayList([]const u8), value: []const u8, alloc: Allocator) !void {
    for (items.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try items.append(alloc, try alloc.dupe(u8, value));
}

const testing = std.testing;

fn seedRequirementGraph(db: *graph_live.GraphDb) !void {
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addNode("TG-002", "TestGroup", "{}", null);
    try db.addNode("TEST-001", "Test", "{}", null);
    try db.addNode("TEST-002", "Test", "{}", null);
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addEdge("REQ-001", "TG-002", "TESTED_BY");
    try db.addEdge("TG-001", "TEST-001", "HAS_TEST");
    try db.addEdge("TG-002", "TEST-002", "HAS_TEST");
}

fn ingestExecution(
    db: *graph_live.GraphDb,
    execution_id: []const u8,
    executed_at: []const u8,
    cases: []const struct { result_id: []const u8, test_case_ref: []const u8, status: []const u8 },
) !void {
    var payload = types.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, execution_id),
        .executed_at = try testing.allocator.dupe(u8, executed_at),
        .serial_number = null,
        .full_product_identifier = null,
        .executor_json = null,
        .source_json = null,
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

test "computed status passed" {
    const items = [_]types.TestCaseInput{
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
    };
    try testing.expectEqual(types.PostStatus.passed, computeStatus(&items));
}

test "computed status failed" {
    const items = [_]types.TestCaseInput{
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
        .{ .result_id = "", .test_case_ref = "", .status = "blocked", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
    };
    try testing.expectEqual(types.PostStatus.failed, computeStatus(&items));
}

test "computed status partial" {
    const items = [_]types.TestCaseInput{
        .{ .result_id = "", .test_case_ref = "", .status = "passed", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
        .{ .result_id = "", .test_case_ref = "", .status = "skipped", .duration_ms = null, .notes = null, .measurements_json = "[]", .attachments_json = "[]" },
    };
    try testing.expectEqual(types.PostStatus.partial, computeStatus(&items));
}

test "verification state yields none for no linked tests" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var verification = try verificationForRequirement(&db, "REQ-1", testing.allocator);
    defer verification.deinit(testing.allocator);
    try testing.expectEqual(types.VerificationState.VERIFY_NONE, verification.state);
}

test "verification deduplicates linked groups and tests in stable order" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TG-002", "TestGroup", "{}", null);
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addNode("TEST-001", "Test", "{}", null);
    try db.addNode("TEST-002", "Test", "{}", null);
    try db.addEdge("REQ-001", "TG-002", "TESTED_BY");
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addEdge("TG-002", "TEST-001", "HAS_TEST");
    try db.addEdge("TG-001", "TEST-001", "HAS_TEST");
    try db.addEdge("TG-001", "TEST-002", "HAS_TEST");

    var verification = try verificationForRequirement(&db, "REQ-001", testing.allocator);
    defer verification.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), verification.linked_test_groups.len);
    try testing.expectEqual(@as(usize, 2), verification.linked_tests.len);
    try testing.expectEqualStrings("TG-001", verification.linked_test_groups[0]);
    try testing.expectEqualStrings("TG-002", verification.linked_test_groups[1]);
    try testing.expectEqualStrings("TEST-001", verification.linked_tests[0].test_id);
    try testing.expectEqualStrings("TEST-002", verification.linked_tests[1].test_id);
}

test "verification state is VERIFIED when all linked tests latest results passed" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedRequirementGraph(&db);
    try ingestExecution(&db, "exec-1", "2026-03-31T12:00:00Z", &.{
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
        .{ .result_id = "r-2", .test_case_ref = "TEST-002", .status = "passed" },
    });

    var verification = try verificationForRequirement(&db, "REQ-001", testing.allocator);
    defer verification.deinit(testing.allocator);
    try testing.expectEqual(types.VerificationState.VERIFIED, verification.state);
}

test "verification state is VERIFY_PARTIAL when one linked test passed and another is missing" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedRequirementGraph(&db);
    try ingestExecution(&db, "exec-1", "2026-03-31T12:00:00Z", &.{
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
    });

    var verification = try verificationForRequirement(&db, "REQ-001", testing.allocator);
    defer verification.deinit(testing.allocator);
    try testing.expectEqual(types.VerificationState.VERIFY_PARTIAL, verification.state);
}

test "verification state is VERIFY_FAILED when any linked test latest result failed" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedRequirementGraph(&db);
    try ingestExecution(&db, "exec-1", "2026-03-31T12:00:00Z", &.{
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
        .{ .result_id = "r-2", .test_case_ref = "TEST-002", .status = "failed" },
    });

    var verification = try verificationForRequirement(&db, "REQ-001", testing.allocator);
    defer verification.deinit(testing.allocator);
    try testing.expectEqual(types.VerificationState.VERIFY_FAILED, verification.state);
}

test "verificationJson preserves requirement ref verification state linked groups and linked latest results" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedRequirementGraph(&db);
    try ingestExecution(&db, "exec-1", "2026-03-31T12:00:00Z", &.{
        .{ .result_id = "r-1", .test_case_ref = "TEST-001", .status = "passed" },
        .{ .result_id = "r-2", .test_case_ref = "TEST-002", .status = "skipped" },
    });

    const json = try verificationJson(&db, "REQ-001", testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"requirement_ref\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"verification_state\":\"VERIFY_PARTIAL\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"linked_test_groups\":[\"TG-001\",\"TG-002\"]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"test_id\":\"TEST-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":\"passed\"") != null);
}
