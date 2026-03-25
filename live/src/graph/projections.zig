const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const require_text = @import("require_text.zig");

pub fn rtm(g: anytype, alloc: Allocator, result: *std.ArrayList(types.RtmRow)) !void {
    var st = try g.db.prepare(
        \\SELECT
        \\    r.id                                             AS req_id,
        \\    json_extract(r.properties, '$.statement')        AS statement,
        \\    json_extract(r.properties, '$.status')           AS status,
        \\    un.id                                            AS user_need_id,
        \\    json_extract(un.properties, '$.statement')       AS user_need_statement,
        \\    tg.id                                            AS test_group_id,
        \\    t.id                                             AS test_id,
        \\    json_extract(t.properties, '$.test_type')        AS test_type,
        \\    json_extract(t.properties, '$.test_method')      AS test_method,
        \\    CASE
        \\        WHEN json_extract(tr.properties, '$.result') IS NOT NULL THEN json_extract(tr.properties, '$.result')
        \\        WHEN json_extract(tr.properties, '$.status') = 'passed' THEN 'PASS'
        \\        WHEN json_extract(tr.properties, '$.status') IN ('failed', 'error', 'blocked') THEN 'FAIL'
        \\        WHEN json_extract(tr.properties, '$.status') = 'skipped' THEN 'SKIP'
        \\        ELSE NULL
        \\    END                                              AS result,
        \\    r.suspect                                        AS req_suspect,
        \\    r.suspect_reason                                 AS req_suspect_reason
        \\FROM nodes r
        \\LEFT JOIN edges e_df  ON e_df.from_id = r.id AND e_df.label = 'DERIVES_FROM'
        \\LEFT JOIN nodes un    ON un.id = e_df.to_id
        \\LEFT JOIN edges e_tb  ON e_tb.from_id = r.id AND e_tb.label = 'TESTED_BY'
        \\LEFT JOIN nodes tg    ON tg.id = e_tb.to_id
        \\LEFT JOIN edges e_ht  ON e_ht.from_id = tg.id AND e_ht.label = 'HAS_TEST'
        \\LEFT JOIN nodes t     ON t.id = e_ht.to_id
        \\LEFT JOIN nodes tr    ON tr.id = (
        \\    SELECT r2.id
        \\    FROM edges eo2
        \\    JOIN nodes r2 ON r2.id = eo2.from_id AND r2.type = 'TestResult'
        \\    LEFT JOIN edges hr2 ON hr2.to_id = r2.id AND hr2.label = 'HAS_RESULT'
        \\    LEFT JOIN nodes e2 ON e2.id = hr2.from_id AND e2.type = 'TestExecution'
        \\    WHERE eo2.label = 'EXECUTION_OF' AND eo2.to_id = t.id
        \\    ORDER BY json_extract(e2.properties, '$.executed_at') DESC, json_extract(r2.properties, '$.result_id') DESC
        \\    LIMIT 1
        \\)
        \\WHERE r.type = 'Requirement'
        \\ORDER BY r.id, tg.id, t.id
    );
    defer st.finalize();
    while (try st.step()) {
        var row: types.RtmRow = .{
            .req_id = try alloc.dupe(u8, st.columnText(0)),
            .statement = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
            .status = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
            .user_need_id = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
            .user_need_statement = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
            .test_group_id = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
            .test_id = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
            .test_type = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
            .test_method = if (st.columnIsNull(8)) null else try alloc.dupe(u8, st.columnText(8)),
            .result = if (st.columnIsNull(9)) null else try alloc.dupe(u8, st.columnText(9)),
            .req_suspect = st.columnInt(10) != 0,
            .req_suspect_reason = if (st.columnIsNull(11)) null else try alloc.dupe(u8, st.columnText(11)),
        };
        var resolution = try require_text.resolveRequirementText(g, row.req_id, alloc);
        defer resolution.deinit(alloc);
        if (row.statement) |value| alloc.free(value);
        row.statement = if (resolution.effective_statement) |statement| try alloc.dupe(u8, statement) else null;
        try result.append(alloc, row);
    }
}

pub fn risks(g: anytype, alloc: Allocator, result: *std.ArrayList(types.RiskRow)) !void {
    var st = try g.db.prepare(
        \\SELECT
        \\    r.id                                                AS risk_id,
        \\    json_extract(r.properties, '$.description')        AS description,
        \\    json_extract(r.properties, '$.initial_severity')   AS initial_severity,
        \\    json_extract(r.properties, '$.initial_likelihood') AS initial_likelihood,
        \\    json_extract(r.properties, '$.mitigation')         AS mitigation,
        \\    json_extract(r.properties, '$.residual_severity')  AS residual_severity,
        \\    json_extract(r.properties, '$.residual_likelihood') AS residual_likelihood,
        \\    req.id                                             AS req_id,
        \\    json_extract(req.properties, '$.statement')        AS req_statement
        \\FROM nodes r
        \\LEFT JOIN edges e    ON e.from_id = r.id AND e.label = 'MITIGATED_BY'
        \\LEFT JOIN nodes req  ON req.id = e.to_id
        \\WHERE r.type = 'Risk'
        \\ORDER BY r.id
    );
    defer st.finalize();
    while (try st.step()) {
        var row: types.RiskRow = .{
            .risk_id = try alloc.dupe(u8, st.columnText(0)),
            .description = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
            .initial_severity = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
            .initial_likelihood = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
            .mitigation = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
            .residual_severity = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
            .residual_likelihood = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
            .req_id = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
            .req_statement = if (st.columnIsNull(8)) null else try alloc.dupe(u8, st.columnText(8)),
        };
        if (row.req_id) |req_id| {
            var resolution = try require_text.resolveRequirementText(g, req_id, alloc);
            defer resolution.deinit(alloc);
            if (row.req_statement) |value| alloc.free(value);
            row.req_statement = if (resolution.effective_statement) |statement| try alloc.dupe(u8, statement) else null;
        }
        try result.append(alloc, row);
    }
}

pub fn tests(g: anytype, alloc: Allocator, result: *std.ArrayList(types.TestRow)) !void {
    const JoinRow = struct {
        test_group_id: []const u8,
        test_id: ?[]const u8,
        test_type: ?[]const u8,
        test_method: ?[]const u8,
        req_id: ?[]const u8,
        req_statement: ?[]const u8,
        test_suspect: bool,
        test_suspect_reason: ?[]const u8,
    };

    var join_rows: std.ArrayList(JoinRow) = .empty;
    defer {
        for (join_rows.items) |row| {
            alloc.free(row.test_group_id);
            if (row.test_id) |v| alloc.free(v);
            if (row.test_type) |v| alloc.free(v);
            if (row.test_method) |v| alloc.free(v);
            if (row.req_id) |v| alloc.free(v);
            if (row.req_statement) |v| alloc.free(v);
            if (row.test_suspect_reason) |v| alloc.free(v);
        }
        join_rows.deinit(alloc);
    }

    var st = try g.db.prepare(
        \\SELECT
        \\    tg.id                                            AS test_group_id,
        \\    t.id                                             AS test_id,
        \\    json_extract(t.properties, '$.test_type')        AS test_type,
        \\    json_extract(t.properties, '$.test_method')      AS test_method,
        \\    r.id                                             AS req_id,
        \\    json_extract(r.properties, '$.statement')        AS req_statement,
        \\    COALESCE(t.suspect, 0)                           AS test_suspect,
        \\    t.suspect_reason                                 AS test_suspect_reason
        \\FROM nodes tg
        \\LEFT JOIN edges e_ht ON e_ht.from_id = tg.id AND e_ht.label = 'HAS_TEST'
        \\LEFT JOIN nodes t    ON t.id = e_ht.to_id
        \\LEFT JOIN edges e_tb ON e_tb.to_id = tg.id AND e_tb.label = 'TESTED_BY'
        \\LEFT JOIN nodes r    ON r.id = e_tb.from_id
        \\WHERE tg.type = 'TestGroup'
        \\ORDER BY tg.id, t.id
    );
    defer st.finalize();
    while (try st.step()) {
        var row: JoinRow = .{
            .test_group_id = try alloc.dupe(u8, st.columnText(0)),
            .test_id = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
            .test_type = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
            .test_method = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
            .req_id = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
            .req_statement = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
            .test_suspect = st.columnInt(6) != 0,
            .test_suspect_reason = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
        };
        if (row.req_id) |req_id| {
            var resolution = try require_text.resolveRequirementText(g, req_id, alloc);
            defer resolution.deinit(alloc);
            if (row.req_statement) |value| alloc.free(value);
            row.req_statement = if (resolution.effective_statement) |statement| try alloc.dupe(u8, statement) else null;
        }
        try join_rows.append(alloc, row);
    }

    for (join_rows.items) |row| {
        var existing: ?*types.TestRow = null;
        for (result.items) |*candidate| {
            const same_group = std.mem.eql(u8, candidate.test_group_id, row.test_group_id);
            const same_test = if (candidate.test_id == null and row.test_id == null)
                true
            else if (candidate.test_id) |candidate_id|
                if (row.test_id) |row_id| std.mem.eql(u8, candidate_id, row_id) else false
            else
                false;
            if (same_group and same_test) {
                existing = candidate;
                break;
            }
        }

        if (existing == null) {
            try result.append(alloc, .{
                .test_group_id = try alloc.dupe(u8, row.test_group_id),
                .test_id = if (row.test_id) |v| try alloc.dupe(u8, v) else null,
                .test_type = if (row.test_type) |v| try alloc.dupe(u8, v) else null,
                .test_method = if (row.test_method) |v| try alloc.dupe(u8, v) else null,
                .req_ids = &.{},
                .req_statements = &.{},
                .req_id = null,
                .req_statement = null,
                .test_suspect = row.test_suspect,
                .test_suspect_reason = if (row.test_suspect_reason) |v| try alloc.dupe(u8, v) else null,
            });
            existing = &result.items[result.items.len - 1];
        }

        if (row.req_id) |req_id| {
            var seen = false;
            for (existing.?.req_ids) |existing_req_id| {
                if (std.mem.eql(u8, existing_req_id, req_id)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                const next_ids = try alloc.alloc([]const u8, existing.?.req_ids.len + 1);
                @memcpy(next_ids[0..existing.?.req_ids.len], existing.?.req_ids);
                next_ids[existing.?.req_ids.len] = try alloc.dupe(u8, req_id);
                if (existing.?.req_ids.len > 0) alloc.free(existing.?.req_ids);
                existing.?.req_ids = next_ids;

                const next_statements = try alloc.alloc([]const u8, existing.?.req_statements.len + 1);
                @memcpy(next_statements[0..existing.?.req_statements.len], existing.?.req_statements);
                next_statements[existing.?.req_statements.len] = if (row.req_statement) |statement|
                    try alloc.dupe(u8, statement)
                else
                    try alloc.dupe(u8, "");
                if (existing.?.req_statements.len > 0) alloc.free(existing.?.req_statements);
                existing.?.req_statements = next_statements;
            }
        }
    }

    for (result.items) |*row| {
        if (row.req_ids.len == 1) {
            row.req_id = row.req_ids[0];
            row.req_statement = row.req_statements[0];
        } else {
            row.req_id = null;
            row.req_statement = null;
        }
    }
}
