const std = @import("std");

const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn listArtifactsJson(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var summaries: std.ArrayList(types.ArtifactSummary) = .empty;
    defer {
        for (summaries.items) |item| {
            alloc.free(item.artifact_id);
            alloc.free(item.kind);
            alloc.free(item.display_name);
            alloc.free(item.path);
            alloc.free(item.logical_key);
            alloc.free(item.last_ingested_at);
            alloc.free(item.ingest_source);
        }
        summaries.deinit(alloc);
    }
    try listArtifacts(db, alloc, &summaries);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (summaries.items, 0..) |item, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"artifact_id\":");
        try shared.appendJsonStr(&buf, item.artifact_id, alloc);
        try buf.appendSlice(alloc, ",\"kind\":");
        try shared.appendJsonStr(&buf, item.kind, alloc);
        try buf.appendSlice(alloc, ",\"display_name\":");
        try shared.appendJsonStr(&buf, item.display_name, alloc);
        try buf.appendSlice(alloc, ",\"path\":");
        try shared.appendJsonStr(&buf, item.path, alloc);
        try buf.appendSlice(alloc, ",\"logical_key\":");
        try shared.appendJsonStr(&buf, item.logical_key, alloc);
        try buf.appendSlice(alloc, ",\"last_ingested_at\":");
        try shared.appendJsonStr(&buf, item.last_ingested_at, alloc);
        try buf.appendSlice(alloc, ",\"ingest_source\":");
        try shared.appendJsonStr(&buf, item.ingest_source, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"requirement_count\":{d},\"conflict_count\":{d},\"null_text_count\":{d},\"low_confidence_count\":{d},\"reingestable\":{s}}}", .{
            item.requirement_count,
            item.conflict_count,
            item.null_text_count,
            item.low_confidence_count,
            if (item.reingestable) "true" else "false",
        });
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

pub fn getArtifactJson(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT properties
        \\FROM nodes
        \\WHERE id=? AND type='Artifact'
    );
    defer st.finalize();
    try st.bindText(1, artifact_id);
    if (!try st.step()) return error.NotFound;
    const properties = st.columnText(0);

    var assertions: std.ArrayList(graph_live.RequirementSourceAssertion) = .empty;
    defer {
        for (assertions.items) |item| {
            alloc.free(item.text_id);
            if (item.artifact_id) |value| alloc.free(value);
            if (item.source_kind) |value| alloc.free(value);
            if (item.section) |value| alloc.free(value);
            if (item.text) |value| alloc.free(value);
            if (item.normalized_text) |value| alloc.free(value);
            if (item.hash) |value| alloc.free(value);
            if (item.parse_status) |value| alloc.free(value);
        }
        assertions.deinit(alloc);
    }
    {
        var ast = try db.db.prepare(
            \\SELECT
            \\  rt.id,
            \\  json_extract(rt.properties, '$.artifact_id'),
            \\  json_extract(rt.properties, '$.source_kind'),
            \\  json_extract(rt.properties, '$.section'),
            \\  json_extract(rt.properties, '$.text'),
            \\  json_extract(rt.properties, '$.normalized_text'),
            \\  json_extract(rt.properties, '$.hash'),
            \\  json_extract(rt.properties, '$.parse_status'),
            \\  COALESCE(CAST(json_extract(rt.properties, '$.occurrence_count') AS INTEGER), 0)
            \\FROM nodes rt
            \\JOIN edges e ON e.to_id = rt.id AND e.from_id = ? AND e.label='CONTAINS'
            \\WHERE rt.type='RequirementText'
            \\ORDER BY rt.id
        );
        defer ast.finalize();
        try ast.bindText(1, artifact_id);
        while (try ast.step()) {
            try assertions.append(alloc, .{
                .text_id = try alloc.dupe(u8, ast.columnText(0)),
                .artifact_id = if (ast.columnIsNull(1)) null else try alloc.dupe(u8, ast.columnText(1)),
                .source_kind = if (ast.columnIsNull(2)) null else try alloc.dupe(u8, ast.columnText(2)),
                .section = if (ast.columnIsNull(3)) null else try alloc.dupe(u8, ast.columnText(3)),
                .text = if (ast.columnIsNull(4)) null else try alloc.dupe(u8, ast.columnText(4)),
                .normalized_text = if (ast.columnIsNull(5)) null else try alloc.dupe(u8, ast.columnText(5)),
                .hash = if (ast.columnIsNull(6)) null else try alloc.dupe(u8, ast.columnText(6)),
                .parse_status = if (ast.columnIsNull(7)) null else try alloc.dupe(u8, ast.columnText(7)),
                .occurrence_count = @intCast(ast.columnInt(8)),
            });
        }
    }

    const conflict_rows = try buildArtifactConflictRows(db, artifact_id, alloc);
    defer {
        for (conflict_rows) |row| {
            alloc.free(row.req_id);
            alloc.free(row.other_artifact_id);
            alloc.free(row.other_source_kind);
            alloc.free(row.other_text);
        }
        alloc.free(conflict_rows);
    }

    const null_text_count = util.countAssertionsWithStatus(assertions.items, "null_text", true);
    const ambiguous_within_artifact_count = util.countAssertionsWithStatus(assertions.items, "ambiguous_within_artifact", false);
    const low_confidence_count = util.countLowConfidenceAssertions(assertions.items);
    const latest_new_ids = try util.extractJsonStringArray(properties, "latest_new_requirement_ids", alloc);
    defer {
        for (latest_new_ids) |value| alloc.free(value);
        alloc.free(latest_new_ids);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"artifact_id\":");
    try shared.appendJsonStr(&buf, artifact_id, alloc);
    try buf.appendSlice(alloc, ",\"properties\":");
    try buf.appendSlice(alloc, properties);
    try buf.appendSlice(alloc, ",\"assertions\":[");
    for (assertions.items, 0..) |item, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, item.text_id, alloc);
        try buf.appendSlice(alloc, ",\"req_id\":");
        try shared.appendJsonStr(&buf, ids.reqIdFromTextId(item.text_id), alloc);
        try buf.appendSlice(alloc, ",\"artifact_id\":");
        try shared.appendJsonStrOpt(&buf, item.artifact_id, alloc);
        try buf.appendSlice(alloc, ",\"source_kind\":");
        try shared.appendJsonStrOpt(&buf, item.source_kind, alloc);
        try buf.appendSlice(alloc, ",\"section\":");
        try shared.appendJsonStrOpt(&buf, item.section, alloc);
        try buf.appendSlice(alloc, ",\"text\":");
        try shared.appendJsonStrOpt(&buf, item.text, alloc);
        try buf.appendSlice(alloc, ",\"normalized_text\":");
        try shared.appendJsonStrOpt(&buf, item.normalized_text, alloc);
        try buf.appendSlice(alloc, ",\"hash\":");
        try shared.appendJsonStrOpt(&buf, item.hash, alloc);
        try buf.appendSlice(alloc, ",\"parse_status\":");
        try shared.appendJsonStrOpt(&buf, item.parse_status, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"occurrence_count\":{d}}}", .{item.occurrence_count});
    }
    try buf.appendSlice(alloc, "],\"conflicts\":[");
    for (conflict_rows, 0..) |row, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"req_id\":");
        try shared.appendJsonStr(&buf, row.req_id, alloc);
        try buf.appendSlice(alloc, ",\"other_artifact_id\":");
        try shared.appendJsonStr(&buf, row.other_artifact_id, alloc);
        try buf.appendSlice(alloc, ",\"other_source_kind\":");
        try shared.appendJsonStr(&buf, row.other_source_kind, alloc);
        try buf.appendSlice(alloc, ",\"other_text\":");
        try shared.appendJsonStr(&buf, row.other_text, alloc);
        try buf.append(alloc, '}');
    }
    try std.fmt.format(buf.writer(alloc), "],\"extraction_summary\":{{\"requirements_seen\":{d},\"null_text_count\":{d},\"low_confidence_count\":{d},\"ambiguous_within_artifact_count\":{d}}},\"new_since_last_ingest\":[", .{
        assertions.items.len,
        null_text_count,
        low_confidence_count,
        ambiguous_within_artifact_count,
    });
    for (latest_new_ids, 0..) |req_id, i| {
        if (i > 0) try buf.append(alloc, ',');
        try shared.appendJsonStr(&buf, req_id, alloc);
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn listArtifacts(db: *graph_live.GraphDb, alloc: Allocator, result: *std.ArrayList(types.ArtifactSummary)) !void {
    var st = try db.db.prepare(
        \\SELECT
        \\  n.id,
        \\  COALESCE(json_extract(n.properties, '$.kind'), ''),
        \\  COALESCE(json_extract(n.properties, '$.display_name'), n.id),
        \\  COALESCE(json_extract(n.properties, '$.path'), ''),
        \\  COALESCE(json_extract(n.properties, '$.logical_key'), ''),
        \\  COALESCE(json_extract(n.properties, '$.last_ingested_at'), ''),
        \\  COALESCE(json_extract(n.properties, '$.ingest_source'), ''),
        \\  (
        \\    SELECT COUNT(*) FROM edges e
        \\    JOIN nodes rt ON rt.id = e.to_id AND rt.type='RequirementText'
        \\    WHERE e.from_id = n.id AND e.label='CONTAINS'
        \\  ) AS requirement_count,
        \\  (
        \\    SELECT COUNT(*) FROM edges e
        \\    JOIN nodes rt ON rt.id = e.to_id AND rt.type='RequirementText'
        \\    WHERE e.from_id = n.id AND e.label='CONTAINS'
        \\      AND (json_extract(rt.properties, '$.text') IS NULL OR json_extract(rt.properties, '$.text') = '')
        \\  ) AS null_text_count
        \\FROM nodes n
        \\WHERE n.type='Artifact'
        \\ORDER BY n.id
    );
    defer st.finalize();
    while (try st.step()) {
        try result.append(alloc, .{
            .artifact_id = try alloc.dupe(u8, st.columnText(0)),
            .kind = try alloc.dupe(u8, st.columnText(1)),
            .display_name = try alloc.dupe(u8, st.columnText(2)),
            .path = try alloc.dupe(u8, st.columnText(3)),
            .logical_key = try alloc.dupe(u8, st.columnText(4)),
            .last_ingested_at = try alloc.dupe(u8, st.columnText(5)),
            .ingest_source = try alloc.dupe(u8, st.columnText(6)),
            .requirement_count = @intCast(st.columnInt(7)),
            .conflict_count = 0,
            .null_text_count = @intCast(st.columnInt(8)),
            .low_confidence_count = 0,
            .reingestable = false,
        });
    }

    for (result.items) |*item| {
        item.conflict_count = try countArtifactCrossSourceConflicts(db, item.artifact_id, alloc);
        item.low_confidence_count = try countArtifactLowConfidence(db, item.artifact_id);
        item.reingestable = artifactIsReingestable(item.kind, item.ingest_source, item.path);
    }
}

pub fn artifactIsReingestable(kind: []const u8, ingest_source: []const u8, path: []const u8) bool {
    if (!std.mem.eql(u8, kind, "rtm_workbook")) return true;
    if (std.mem.eql(u8, ingest_source, "workbook_sync") or std.mem.eql(u8, ingest_source, "migration")) return false;
    return std.mem.endsWith(u8, path, ".xlsx");
}

pub fn countArtifactLowConfidence(db: *graph_live.GraphDb, artifact_id: []const u8) !usize {
    var st = try db.db.prepare(
        \\SELECT COUNT(*) FROM edges e
        \\JOIN nodes rt ON rt.id = e.to_id AND rt.type='RequirementText'
        \\WHERE e.from_id = ? AND e.label='CONTAINS'
        \\  AND (
        \\    json_extract(rt.properties, '$.parse_status') = 'low_confidence_long_text'
        \\    OR json_extract(rt.properties, '$.parse_status') = 'low_confidence_nested_ids'
        \\    OR json_extract(rt.properties, '$.parse_status') = 'low_confidence_empty_after_trim'
        \\  )
    );
    defer st.finalize();
    try st.bindText(1, artifact_id);
    return if (try st.step()) @intCast(st.columnInt(0)) else 0;
}

pub fn countArtifactCrossSourceConflicts(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) !usize {
    const rows = try buildArtifactConflictRows(db, artifact_id, alloc);
    defer {
        for (rows) |row| {
            alloc.free(row.req_id);
            alloc.free(row.other_artifact_id);
            alloc.free(row.other_source_kind);
            alloc.free(row.other_text);
        }
        alloc.free(rows);
    }
    var unique: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = unique.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        unique.deinit();
    }
    for (rows) |row| {
        if (!unique.contains(row.req_id)) try unique.put(try alloc.dupe(u8, row.req_id), {});
    }
    return unique.count();
}

pub fn buildArtifactConflictRows(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) ![]types.ArtifactConflictRow {
    var req_ids: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = req_ids.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        req_ids.deinit();
    }
    {
        var st = try db.db.prepare(
            \\SELECT COALESCE(json_extract(rt.properties, '$.req_id'), '')
            \\FROM nodes rt
            \\JOIN edges e ON e.to_id = rt.id AND e.from_id = ? AND e.label='CONTAINS'
            \\WHERE rt.type='RequirementText'
        );
        defer st.finalize();
        try st.bindText(1, artifact_id);
        while (try st.step()) {
            const req_id = st.columnText(0);
            if (req_id.len == 0 or req_ids.contains(req_id)) continue;
            try req_ids.put(try alloc.dupe(u8, req_id), {});
        }
    }

    var rows: std.ArrayList(types.ArtifactConflictRow) = .empty;
    var it = req_ids.iterator();
    while (it.next()) |entry| {
        var assertions: std.ArrayList(graph_live.RequirementSourceAssertion) = .empty;
        defer {
            for (assertions.items) |item| {
                alloc.free(item.text_id);
                if (item.artifact_id) |value| alloc.free(value);
                if (item.source_kind) |value| alloc.free(value);
                if (item.section) |value| alloc.free(value);
                if (item.text) |value| alloc.free(value);
                if (item.normalized_text) |value| alloc.free(value);
                if (item.hash) |value| alloc.free(value);
                if (item.parse_status) |value| alloc.free(value);
            }
            assertions.deinit(alloc);
        }
        try db.requirementSourceAssertions(entry.key_ptr.*, alloc, &assertions);
        var local_assertion: ?graph_live.RequirementSourceAssertion = null;
        for (assertions.items) |assertion| {
            if (assertion.artifact_id) |candidate| {
                if (std.mem.eql(u8, candidate, artifact_id)) {
                    local_assertion = assertion;
                    break;
                }
            }
        }
        if (local_assertion == null) continue;
        const left_hash = local_assertion.?.hash orelse "";
        const left_text = local_assertion.?.normalized_text orelse local_assertion.?.text orelse "";
        if (left_text.len == 0) continue;
        for (assertions.items) |assertion| {
            const other_artifact_id = assertion.artifact_id orelse continue;
            if (std.mem.eql(u8, other_artifact_id, artifact_id)) continue;
            const right_hash = assertion.hash orelse "";
            const right_text = assertion.normalized_text orelse assertion.text orelse "";
            if (right_text.len == 0) continue;
            if (left_hash.len > 0 and right_hash.len > 0 and std.mem.eql(u8, left_hash, right_hash)) continue;
            if (std.mem.eql(u8, left_text, right_text)) continue;
            try rows.append(alloc, .{
                .req_id = try alloc.dupe(u8, entry.key_ptr.*),
                .other_artifact_id = try alloc.dupe(u8, other_artifact_id),
                .other_source_kind = try alloc.dupe(u8, assertion.source_kind orelse ""),
                .other_text = try alloc.dupe(u8, assertion.text orelse ""),
            });
        }
    }
    return rows.toOwnedSlice(alloc);
}
