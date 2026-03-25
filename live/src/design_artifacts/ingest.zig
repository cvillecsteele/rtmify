const std = @import("std");

const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const diagnostics = @import("diagnostics.zig");
const ids = @import("ids.zig");
const json = @import("json.zig");
const parser_docx = @import("parser_docx.zig");
const parser_rtm_workbook = @import("parser_rtm_workbook.zig");
const snapshot = @import("snapshot.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn migrateLegacyRequirementStatements(
    db: *graph_live.GraphDb,
    workbook_slug: []const u8,
    display_name: []const u8,
    path: []const u8,
    alloc: Allocator,
) !bool {
    var legacy_count: usize = 0;
    {
        var st = try db.db.prepare(
            \\SELECT COUNT(*) FROM nodes
            \\WHERE type='Requirement'
            \\  AND json_extract(properties, '$.statement') IS NOT NULL
        );
        defer st.finalize();
        if (try st.step()) legacy_count = @intCast(st.columnInt(0));
    }
    if (legacy_count == 0) return false;

    const artifact_id = try ids.artifactIdFor(.rtm_workbook, workbook_slug, alloc);
    defer alloc.free(artifact_id);

    var existing_assertions: usize = 0;
    {
        var st = try db.db.prepare(
            \\SELECT COUNT(*) FROM nodes
            \\WHERE type='RequirementText'
            \\  AND json_extract(properties, '$.artifact_id') = ?
        );
        defer st.finalize();
        try st.bindText(1, artifact_id);
        if (try st.step()) existing_assertions = @intCast(st.columnInt(0));
    }
    if (existing_assertions > 0) return false;

    var assertions: std.ArrayList(types.ParsedRequirementAssertion) = .empty;
    defer {
        for (assertions.items) |item| {
            alloc.free(item.req_id);
            alloc.free(item.section);
            if (item.text) |value| alloc.free(value);
            if (item.normalized_text) |value| alloc.free(value);
            alloc.free(item.parse_status);
        }
        assertions.deinit(alloc);
    }

    var req_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (req_ids.items) |value| alloc.free(value);
        req_ids.deinit(alloc);
    }

    var st = try db.db.prepare(
        \\SELECT id, properties
        \\FROM nodes
        \\WHERE type='Requirement'
        \\  AND json_extract(properties, '$.statement') IS NOT NULL
        \\ORDER BY id
    );
    defer st.finalize();
    while (try st.step()) {
        const req_id = st.columnText(0);
        const properties = st.columnText(1);
        const statement = util.extractStringField(properties, "statement");
        try assertions.append(alloc, .{
            .req_id = try alloc.dupe(u8, req_id),
            .section = try alloc.dupe(u8, "Requirements"),
            .text = if (statement) |value| try alloc.dupe(u8, value) else null,
            .normalized_text = if (statement) |value| try util.normalizeText(value, alloc) else null,
            .parse_status = try alloc.dupe(u8, "ok"),
            .occurrence_count = 1,
        });
        try req_ids.append(alloc, try alloc.dupe(u8, req_id));
    }

    var ingest_result = try applyArtifactSnapshot(db, artifact_id, .rtm_workbook, display_name, path, workbook_slug, "migration", .migration, assertions.items, alloc);
    defer ingest_result.deinit(alloc);
    for (req_ids.items) |req_id| {
        try state.clearLegacyRequirementStatement(db, req_id);
        _ = try state.recomputeRequirementState(db, req_id, alloc);
    }
    return true;
}

pub fn ingestDocxPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    kind: types.ArtifactKind,
    logical_key: []const u8,
    display_name: []const u8,
    ingest_source: []const u8,
    alloc: Allocator,
) !types.ArtifactIngestResult {
    const artifact_id = try ids.artifactIdFor(kind, logical_key, alloc);
    defer alloc.free(artifact_id);

    var assertions = try parser_docx.parseDocxAssertions(path, alloc);
    defer {
        for (assertions.items) |item| {
            alloc.free(item.req_id);
            alloc.free(item.section);
            if (item.text) |value| alloc.free(value);
            if (item.normalized_text) |value| alloc.free(value);
            alloc.free(item.parse_status);
        }
        assertions.deinit(alloc);
    }

    return applyArtifactSnapshot(db, artifact_id, kind, display_name, path, logical_key, ingest_source, ids.inferDisposition(ingest_source), assertions.items, alloc);
}

pub fn ingestRtmWorkbookPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    logical_key: []const u8,
    display_name: []const u8,
    ingest_source: []const u8,
    alloc: Allocator,
) !types.ArtifactIngestResult {
    const artifact_id = try ids.artifactIdFor(.rtm_workbook, logical_key, alloc);
    defer alloc.free(artifact_id);

    var assertions = try parser_rtm_workbook.parseRtmWorkbookAssertions(path, alloc);
    defer {
        for (assertions.items) |item| {
            alloc.free(item.req_id);
            alloc.free(item.section);
            if (item.text) |value| alloc.free(value);
            if (item.normalized_text) |value| alloc.free(value);
            alloc.free(item.parse_status);
        }
        assertions.deinit(alloc);
    }

    return applyArtifactSnapshot(db, artifact_id, .rtm_workbook, display_name, path, logical_key, ingest_source, ids.inferDisposition(ingest_source), assertions.items, alloc);
}

pub fn reingestArtifact(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) !types.ArtifactIngestResult {
    var st = try db.db.prepare(
        \\SELECT
        \\  json_extract(properties, '$.kind'),
        \\  json_extract(properties, '$.path'),
        \\  json_extract(properties, '$.display_name'),
        \\  json_extract(properties, '$.logical_key')
        \\FROM nodes
        \\WHERE id=? AND type='Artifact'
    );
    defer st.finalize();
    try st.bindText(1, artifact_id);
    if (!try st.step()) return error.NotFound;
    const kind_str = if (st.columnIsNull(0)) return error.NotFound else st.columnText(0);
    const path = if (st.columnIsNull(1)) return error.NotFound else st.columnText(1);
    const display_name = if (st.columnIsNull(2)) std.fs.path.basename(path) else st.columnText(2);
    const logical_key = if (st.columnIsNull(3)) std.fs.path.stem(std.fs.path.basename(path)) else st.columnText(3);
    const kind = types.ArtifactKind.fromString(kind_str) orelse return error.NotFound;
    return switch (kind) {
        .srs_docx, .sysrd_docx => ingestDocxPath(db, path, kind, logical_key, display_name, "reingest", alloc),
        .rtm_workbook => ingestRtmWorkbookPath(db, path, logical_key, display_name, "reingest", alloc),
    };
}

pub fn applyArtifactSnapshot(
    db: *graph_live.GraphDb,
    artifact_id: []const u8,
    kind: types.ArtifactKind,
    display_name: []const u8,
    path: []const u8,
    logical_key: []const u8,
    ingest_source: []const u8,
    disposition: types.IngestDisposition,
    assertions: []const types.ParsedRequirementAssertion,
    alloc: Allocator,
) !types.ArtifactIngestResult {
    try snapshot.validateUniqueAssertionIds(assertions, alloc);

    var touched_ids: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = touched_ids.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        touched_ids.deinit();
    }

    const previous_snapshot = try snapshot.loadPreviousArtifactSnapshot(db, artifact_id, alloc);
    defer previous_snapshot.deinit(alloc);

    try deleteArtifactAssertions(db, artifact_id, alloc, &touched_ids);

    const now_text = try std.fmt.allocPrint(alloc, "{d}", .{std.time.timestamp()});
    defer alloc.free(now_text);
    const new_since_last_ingest = try snapshot.computeNewSinceLastIngest(previous_snapshot.req_ids, assertions, alloc);
    defer {
        for (new_since_last_ingest) |value| alloc.free(value);
        alloc.free(new_since_last_ingest);
    }
    var artifact_props_buf: std.ArrayList(u8) = .empty;
    defer artifact_props_buf.deinit(alloc);
    try artifact_props_buf.appendSlice(alloc, "{\"kind\":");
    try shared.appendJsonStr(&artifact_props_buf, kind.toString(), alloc);
    try artifact_props_buf.appendSlice(alloc, ",\"path\":");
    try shared.appendJsonStr(&artifact_props_buf, path, alloc);
    try artifact_props_buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(&artifact_props_buf, display_name, alloc);
    try artifact_props_buf.appendSlice(alloc, ",\"last_ingested_at\":");
    try shared.appendJsonStr(&artifact_props_buf, now_text, alloc);
    try artifact_props_buf.appendSlice(alloc, ",\"ingest_source\":");
    try shared.appendJsonStr(&artifact_props_buf, ingest_source, alloc);
    try artifact_props_buf.appendSlice(alloc, ",\"logical_key\":");
    try shared.appendJsonStr(&artifact_props_buf, logical_key, alloc);
    try artifact_props_buf.appendSlice(alloc, ",\"latest_new_requirement_ids\":[");
    for (new_since_last_ingest, 0..) |req_id, idx| {
        if (idx > 0) try artifact_props_buf.append(alloc, ',');
        try shared.appendJsonStr(&artifact_props_buf, req_id, alloc);
    }
    try artifact_props_buf.append(alloc, ']');
    try artifact_props_buf.append(alloc, '}');
    try db.upsertNode(artifact_id, "Artifact", artifact_props_buf.items, null);

    var diagnostics_emitted: usize = 0;
    var null_text_count: usize = 0;
    var low_confidence_count: usize = 0;
    for (assertions) |assertion| {
        try state.ensureCanonicalRequirement(db, assertion.req_id, alloc);
        const text_id = try ids.buildRequirementTextId(artifact_id, assertion.req_id, alloc);
        defer alloc.free(text_id);
        const props = try json.buildRequirementTextProperties(
            artifact_id,
            kind,
            assertion,
            now_text,
            alloc,
        );
        defer alloc.free(props);
        try db.upsertNode(text_id, "RequirementText", props, null);
        try db.addEdge(artifact_id, text_id, "CONTAINS");
        try db.addEdge(text_id, assertion.req_id, "ASSERTS");
        if (!touched_ids.contains(assertion.req_id)) try touched_ids.put(try alloc.dupe(u8, assertion.req_id), {});
        if (std.mem.eql(u8, assertion.parse_status, "ambiguous_within_artifact")) {
            try diagnostics.upsertArtifactDiagnostic(db, artifact_id, assertion.req_id, 9604, "REQ_TEXT_AMBIGUOUS_WITHIN_SOURCE", "warn", "Requirement text ambiguous within artifact", alloc);
            diagnostics_emitted += 1;
        } else if (std.mem.eql(u8, assertion.parse_status, "null_text") or assertion.text == null or assertion.text.?.len == 0) {
            try diagnostics.upsertArtifactDiagnostic(db, artifact_id, assertion.req_id, 9603, "REQ_TEXT_NULL", "warn", "Requirement text missing in design artifact", alloc);
            diagnostics_emitted += 1;
            null_text_count += 1;
        } else if (util.isLowConfidenceStatus(assertion.parse_status)) {
            try diagnostics.upsertArtifactDiagnostic(db, artifact_id, assertion.req_id, 9605, "REQ_TEXT_LOW_CONFIDENCE", "warn", "Requirement text extracted with low confidence", alloc);
            diagnostics_emitted += 1;
            low_confidence_count += 1;
        }
    }

    var touched_it = touched_ids.iterator();
    while (touched_it.next()) |entry| {
        try state.rebuildConflictEdgesForRequirement(db, entry.key_ptr.*, alloc);
        diagnostics_emitted += try state.recomputeRequirementState(db, entry.key_ptr.*, alloc);
    }

    const summary = try snapshot.buildIngestSummary(db, artifact_id, kind, disposition, previous_snapshot, assertions, null_text_count, low_confidence_count, diagnostics_emitted, new_since_last_ingest, alloc);
    snapshot.logIngestSummary(summary);
    return .{
        .artifact_id = try alloc.dupe(u8, artifact_id),
        .summary = summary,
    };
}

pub fn deleteArtifactAssertions(
    db: *graph_live.GraphDb,
    artifact_id: []const u8,
    alloc: Allocator,
    touched_ids: *std.StringHashMap(void),
) !void {
    var st = try db.db.prepare(
        \\SELECT
        \\  rt.id,
        \\  COALESCE(json_extract(rt.properties, '$.req_id'), '')
        \\FROM nodes rt
        \\JOIN edges e ON e.to_id = rt.id AND e.from_id = ? AND e.label='CONTAINS'
        \\WHERE rt.type='RequirementText'
    );
    defer st.finalize();
    try st.bindText(1, artifact_id);
    while (try st.step()) {
        const text_id = st.columnText(0);
        const req_id = st.columnText(1);
        if (req_id.len > 0 and !touched_ids.contains(req_id)) {
            try touched_ids.put(try alloc.dupe(u8, req_id), {});
        }
        try db.deleteNode(text_id);
    }
    try db.clearRuntimeDiagnosticsBySubjectPrefix("design_artifacts", artifact_id);
}
