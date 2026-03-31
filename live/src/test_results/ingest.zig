const std = @import("std");
const Allocator = std.mem.Allocator;

const db_mod = @import("../db.zig");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const ids = @import("ids.zig");
const query = @import("query.zig");
const types = @import("types.zig");
const verification = @import("verification.zig");

pub fn ingest(
    db: *graph_live.GraphDb,
    payload: types.ExecutionInput,
    alloc: Allocator,
) (types.IngestError || error{OutOfMemory} || db_mod.DbError)!types.IngestResponse {
    var existing = try query.getExecution(db, payload.execution_id, alloc);
    defer if (existing) |*execution| execution.deinit(alloc);
    if (existing) |execution| {
        try rejectIfSuperseded(db, execution);
    }

    var warnings: std.ArrayList(types.IngestWarning) = .empty;
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
            product_node_id = try ids.productNodeId(full_product_identifier, alloc);
            const maybe_product = try db.getNode(product_node_id.?, alloc);
            defer if (maybe_product) |node| shared.freeNode(node, alloc);
            break :blk if (maybe_product != null) "resolved" else "dangling";
        }
        break :blk null;
    };

    const execution_node_id = try ids.executionNodeId(payload.execution_id, alloc);
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

        const result_node_id = try ids.resultNodeId(test_case.result_id, alloc);
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
        .computed_status = verification.computeStatus(payload.test_cases),
        .inserted = inserted,
        .warnings = try warnings.toOwnedSlice(alloc),
    };
}

fn rejectIfSuperseded(
    db: *graph_live.GraphDb,
    existing: types.ExecutionEnvelope,
) (types.IngestError || db_mod.DbError)!void {
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
    const execution_node_id = try ids.executionNodeId(execution_id, std.heap.page_allocator);
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

fn executionPropertiesJson(
    payload: types.ExecutionInput,
    product_resolution_state: ?[]const u8,
    alloc: Allocator,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"execution_id\":");
    try shared.appendJsonStr(&buf, payload.execution_id, alloc);
    try buf.appendSlice(alloc, ",\"executed_at\":");
    try shared.appendJsonStr(&buf, payload.executed_at, alloc);
    try buf.appendSlice(alloc, ",\"computed_status\":");
    try shared.appendJsonStr(&buf, @tagName(verification.computeStatus(payload.test_cases)), alloc);
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

fn resultPropertiesJson(
    execution_id: []const u8,
    test_case: types.TestCaseInput,
    resolution_state: []const u8,
    alloc: Allocator,
) ![]const u8 {
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

const testing = std.testing;

test "ingest creates FOR_PRODUCT edge when full_product_identifier resolves" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    {
        db.db.write_mu.lock();
        defer db.db.write_mu.unlock();
        try upsertNodeLocked(&db, "product://ASM-001-A", "Product", "{\"full_identifier\":\"ASM-001-A\"}");
        try upsertNodeLocked(&db, "TST-001", "Test", "{\"id\":\"TST-001\"}");
    }

    var payload = types.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "build-9002"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-14T14:32:00Z"),
        .serial_number = null,
        .full_product_identifier = try testing.allocator.dupe(u8, "ASM-001-A"),
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(types.TestCaseInput, 1),
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

    var execution = (try query.getExecution(&db, "build-9002", testing.allocator)).?;
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

    var payload = types.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "build-9003"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-14T14:32:00Z"),
        .serial_number = null,
        .full_product_identifier = try testing.allocator.dupe(u8, "ASM-404-Z"),
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(types.TestCaseInput, 1),
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

    var execution = (try query.getExecution(&db, "build-9003", testing.allocator)).?;
    defer execution.deinit(testing.allocator);
    try testing.expectEqualStrings("ASM-404-Z", execution.full_product_identifier.?);
    try testing.expectEqualStrings("dangling", execution.product_resolution_state.?);
}

test "ingest rejects when newer execution already exists for same test" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    {
        db.db.write_mu.lock();
        defer db.db.write_mu.unlock();
        try upsertNodeLocked(&db, "TST-001", "Test", "{\"id\":\"TST-001\"}");
    }

    var older = types.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "build-old"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-14T14:32:00Z"),
        .serial_number = null,
        .full_product_identifier = null,
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(types.TestCaseInput, 1),
    };
    older.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "build-old-TC-001"),
        .test_case_ref = try testing.allocator.dupe(u8, "TST-001"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[]"),
        .attachments_json = try testing.allocator.dupe(u8, "[]"),
    };
    defer older.deinit(testing.allocator);
    var older_response = try ingest(&db, older, testing.allocator);
    defer older_response.deinit(testing.allocator);

    var newer = types.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "build-new"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-15T14:32:00Z"),
        .serial_number = null,
        .full_product_identifier = null,
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(types.TestCaseInput, 1),
    };
    newer.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "build-new-TC-001"),
        .test_case_ref = try testing.allocator.dupe(u8, "TST-001"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[]"),
        .attachments_json = try testing.allocator.dupe(u8, "[]"),
    };
    defer newer.deinit(testing.allocator);
    var newer_response = try ingest(&db, newer, testing.allocator);
    defer newer_response.deinit(testing.allocator);

    var older_reingest = types.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "build-old"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-14T14:32:00Z"),
        .serial_number = null,
        .full_product_identifier = null,
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(types.TestCaseInput, 1),
    };
    older_reingest.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "build-old-TC-001"),
        .test_case_ref = try testing.allocator.dupe(u8, "TST-001"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[]"),
        .attachments_json = try testing.allocator.dupe(u8, "[]"),
    };
    defer older_reingest.deinit(testing.allocator);

    try testing.expectError(error.ExecutionSuperseded, ingest(&db, older_reingest, testing.allocator));
}
