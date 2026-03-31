const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
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
    var items: std.ArrayList([]const u8) = .empty;
    defer {
        for (items.items) |value| testing.allocator.free(value);
        items.deinit(testing.allocator);
    }

    try appendUniqueString(&items, "TG-2", testing.allocator);
    try appendUniqueString(&items, "TG-1", testing.allocator);
    try appendUniqueString(&items, "TG-2", testing.allocator);
    try testing.expectEqual(@as(usize, 2), items.items.len);
    try testing.expectEqualStrings("TG-2", items.items[0]);
    try testing.expectEqualStrings("TG-1", items.items[1]);
}
