const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const graph_live = @import("graph_live.zig");
const json_util = @import("json_util.zig");
const shared = @import("routes/shared.zig");
const xlsx = @import("rtmify").xlsx;
const schema = @import("rtmify").schema;

pub const ArtifactKind = enum {
    rtm_workbook,
    srs_docx,
    sysrd_docx,

    pub fn fromString(value: []const u8) ?ArtifactKind {
        if (std.mem.eql(u8, value, "rtm_workbook")) return .rtm_workbook;
        if (std.mem.eql(u8, value, "srs_docx")) return .srs_docx;
        if (std.mem.eql(u8, value, "sysrd_docx")) return .sysrd_docx;
        return null;
    }

    pub fn toString(self: ArtifactKind) []const u8 {
        return switch (self) {
            .rtm_workbook => "rtm_workbook",
            .srs_docx => "srs_docx",
            .sysrd_docx => "sysrd_docx",
        };
    }
};

pub const ParsedRequirementAssertion = struct {
    req_id: []const u8,
    section: []const u8,
    text: ?[]const u8,
    normalized_text: ?[]const u8,
    parse_status: []const u8,
    occurrence_count: usize,
};

pub const IngestDisposition = enum {
    uploaded,
    reingested,
    external_inbox,
    sync_cycle,
    migration,

    pub fn toString(self: IngestDisposition) []const u8 {
        return switch (self) {
            .uploaded => "uploaded",
            .reingested => "reingested",
            .external_inbox => "external_inbox",
            .sync_cycle => "sync_cycle",
            .migration => "migration",
        };
    }
};

pub const IngestSummary = struct {
    artifact_id: []const u8,
    kind: ArtifactKind,
    requirements_seen: usize,
    nodes_added: usize,
    nodes_updated: usize,
    nodes_deleted: usize,
    unchanged: usize,
    conflicts_detected: usize,
    null_text_count: usize,
    low_confidence_count: usize,
    diagnostics_emitted: usize,
    timestamp: i64,
    disposition: IngestDisposition,
    new_since_last_ingest: []const []const u8,

    pub fn deinit(self: *IngestSummary, alloc: Allocator) void {
        alloc.free(self.artifact_id);
        for (self.new_since_last_ingest) |value| alloc.free(value);
        alloc.free(self.new_since_last_ingest);
    }
};

pub const ArtifactIngestResult = struct {
    artifact_id: []const u8,
    summary: IngestSummary,

    pub fn deinit(self: *ArtifactIngestResult, alloc: Allocator) void {
        alloc.free(self.artifact_id);
        self.summary.deinit(alloc);
    }
};

pub const ArtifactSummary = struct {
    artifact_id: []const u8,
    kind: []const u8,
    display_name: []const u8,
    path: []const u8,
    logical_key: []const u8,
    last_ingested_at: []const u8,
    ingest_source: []const u8,
    requirement_count: usize,
    conflict_count: usize,
    null_text_count: usize,
    low_confidence_count: usize,
    reingestable: bool,
};

const PreviousArtifactAssertion = struct {
    req_id: []const u8,
    hash: []const u8,

    fn deinit(self: *PreviousArtifactAssertion, alloc: Allocator) void {
        alloc.free(self.req_id);
        alloc.free(self.hash);
    }
};

const PreviousArtifactSnapshot = struct {
    assertions: []PreviousArtifactAssertion,
    req_ids: []const []const u8,

    fn deinit(self: PreviousArtifactSnapshot, alloc: Allocator) void {
        for (self.assertions) |*item| item.deinit(alloc);
        alloc.free(self.assertions);
        for (self.req_ids) |value| alloc.free(value);
        alloc.free(self.req_ids);
    }
};

pub fn artifactIdFor(kind: ArtifactKind, logical_key: []const u8, alloc: Allocator) ![]u8 {
    return switch (kind) {
        .rtm_workbook => std.fmt.allocPrint(alloc, "artifact://rtm/{s}", .{logical_key}),
        else => std.fmt.allocPrint(alloc, "artifact://{s}/{s}", .{ kind.toString(), logical_key }),
    };
}

fn buildRequirementTextId(artifact_id: []const u8, req_id: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}:{s}", .{ artifact_id, req_id });
}

fn inferDisposition(ingest_source: []const u8) IngestDisposition {
    if (std.mem.eql(u8, ingest_source, "migration")) return .migration;
    if (std.mem.eql(u8, ingest_source, "external_inbox")) return .external_inbox;
    if (std.mem.eql(u8, ingest_source, "reingest")) return .reingested;
    if (std.mem.eql(u8, ingest_source, "workbook_sync") or std.mem.eql(u8, ingest_source, "sync_cycle")) return .sync_cycle;
    return .uploaded;
}

fn isLowConfidenceStatus(parse_status: []const u8) bool {
    return std.mem.eql(u8, parse_status, "low_confidence_long_text") or
        std.mem.eql(u8, parse_status, "low_confidence_nested_ids") or
        std.mem.eql(u8, parse_status, "low_confidence_empty_after_trim");
}

fn hashNormalizedText(normalized_text: ?[]const u8) [64]u8 {
    if (normalized_text == null or normalized_text.?.len == 0) return std.mem.zeroes([64]u8);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(normalized_text.?);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

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

    const artifact_id = try artifactIdFor(.rtm_workbook, workbook_slug, alloc);
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

    var assertions: std.ArrayList(ParsedRequirementAssertion) = .empty;
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
        const statement = extractStringField(properties, "statement");
        try assertions.append(alloc, .{
            .req_id = try alloc.dupe(u8, req_id),
            .section = try alloc.dupe(u8, "Requirements"),
            .text = if (statement) |value| try alloc.dupe(u8, value) else null,
            .normalized_text = if (statement) |value| try normalizeText(value, alloc) else null,
            .parse_status = try alloc.dupe(u8, "ok"),
            .occurrence_count = 1,
        });
        try req_ids.append(alloc, try alloc.dupe(u8, req_id));
    }

    var ingest_result = try applyArtifactSnapshot(db, artifact_id, .rtm_workbook, display_name, path, workbook_slug, "migration", .migration, assertions.items, alloc);
    defer ingest_result.deinit(alloc);
    for (req_ids.items) |req_id| {
        try clearLegacyRequirementStatement(db, req_id);
        _ = try recomputeRequirementState(db, req_id, alloc);
    }
    return true;
}

pub fn ingestDocxPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    kind: ArtifactKind,
    logical_key: []const u8,
    display_name: []const u8,
    ingest_source: []const u8,
    alloc: Allocator,
) !ArtifactIngestResult {
    const artifact_id = try artifactIdFor(kind, logical_key, alloc);
    defer alloc.free(artifact_id);

    var assertions = try parseDocxAssertions(path, alloc);
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

    return applyArtifactSnapshot(db, artifact_id, kind, display_name, path, logical_key, ingest_source, inferDisposition(ingest_source), assertions.items, alloc);
}

pub fn ingestRtmWorkbookPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    logical_key: []const u8,
    display_name: []const u8,
    ingest_source: []const u8,
    alloc: Allocator,
) !ArtifactIngestResult {
    const artifact_id = try artifactIdFor(.rtm_workbook, logical_key, alloc);
    defer alloc.free(artifact_id);

    var assertions = try parseRtmWorkbookAssertions(path, alloc);
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

    return applyArtifactSnapshot(db, artifact_id, .rtm_workbook, display_name, path, logical_key, ingest_source, inferDisposition(ingest_source), assertions.items, alloc);
}

pub fn reingestArtifact(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) !ArtifactIngestResult {
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
    const kind = ArtifactKind.fromString(kind_str) orelse return error.NotFound;
    return switch (kind) {
        .srs_docx, .sysrd_docx => ingestDocxPath(db, path, kind, logical_key, display_name, "reingest", alloc),
        .rtm_workbook => ingestRtmWorkbookPath(db, path, logical_key, display_name, "reingest", alloc),
    };
}

pub fn listArtifactsJson(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var summaries: std.ArrayList(ArtifactSummary) = .empty;
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

    const null_text_count = countAssertionsWithStatus(assertions.items, "null_text", true);
    const ambiguous_within_artifact_count = countAssertionsWithStatus(assertions.items, "ambiguous_within_artifact", false);
    const low_confidence_count = countLowConfidenceAssertions(assertions.items);
    const latest_new_ids = try extractJsonStringArray(properties, "latest_new_requirement_ids", alloc);
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
        try shared.appendJsonStr(&buf, reqIdFromTextId(item.text_id), alloc);
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

fn reqIdFromTextId(text_id: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, text_id, ':') orelse return text_id;
    return text_id[idx + 1 ..];
}

pub fn listArtifacts(db: *graph_live.GraphDb, alloc: Allocator, result: *std.ArrayList(ArtifactSummary)) !void {
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

const ArtifactConflictRow = struct {
    req_id: []const u8,
    other_artifact_id: []const u8,
    other_source_kind: []const u8,
    other_text: []const u8,
};

fn artifactIsReingestable(kind: []const u8, ingest_source: []const u8, path: []const u8) bool {
    if (!std.mem.eql(u8, kind, "rtm_workbook")) return true;
    if (std.mem.eql(u8, ingest_source, "workbook_sync") or std.mem.eql(u8, ingest_source, "migration")) return false;
    return std.mem.endsWith(u8, path, ".xlsx");
}

fn countArtifactLowConfidence(db: *graph_live.GraphDb, artifact_id: []const u8) !usize {
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

fn countArtifactCrossSourceConflicts(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) !usize {
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

fn buildArtifactConflictRows(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) ![]ArtifactConflictRow {
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

    var rows: std.ArrayList(ArtifactConflictRow) = .empty;
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

fn countAssertionsWithStatus(assertions: []const graph_live.RequirementSourceAssertion, target_status: []const u8, treat_missing_text_as_null: bool) usize {
    var count: usize = 0;
    for (assertions) |assertion| {
        const parse_status = assertion.parse_status orelse "ok";
        if (std.mem.eql(u8, parse_status, target_status)) {
            count += 1;
        } else if (treat_missing_text_as_null and (assertion.text == null or assertion.text.?.len == 0)) {
            count += 1;
        }
    }
    return count;
}

fn countLowConfidenceAssertions(assertions: []const graph_live.RequirementSourceAssertion) usize {
    var count: usize = 0;
    for (assertions) |assertion| {
        const parse_status = assertion.parse_status orelse "ok";
        if (isLowConfidenceStatus(parse_status)) count += 1;
    }
    return count;
}

fn extractJsonStringArray(json: []const u8, key: []const u8, alloc: Allocator) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return try alloc.alloc([]const u8, 0);
    const field = root.object.get(key) orelse return try alloc.alloc([]const u8, 0);
    if (field != .array) return try alloc.alloc([]const u8, 0);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(alloc);
    for (field.array.items) |item| {
        if (item != .string) continue;
        try values.append(alloc, try alloc.dupe(u8, item.string));
    }
    return values.toOwnedSlice(alloc);
}

fn loadPreviousArtifactSnapshot(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) !PreviousArtifactSnapshot {
    var assertions: std.ArrayList(PreviousArtifactAssertion) = .empty;
    defer assertions.deinit(alloc);
    var req_ids: std.ArrayList([]const u8) = .empty;
    defer req_ids.deinit(alloc);

    var seen_req_ids: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen_req_ids.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        seen_req_ids.deinit();
    }

    var st = try db.db.prepare(
        \\SELECT
        \\  COALESCE(json_extract(rt.properties, '$.req_id'), ''),
        \\  COALESCE(json_extract(rt.properties, '$.hash'), '')
        \\FROM nodes rt
        \\JOIN edges e ON e.to_id = rt.id AND e.from_id = ? AND e.label='CONTAINS'
        \\WHERE rt.type='RequirementText'
        \\ORDER BY rt.id
    );
    defer st.finalize();
    try st.bindText(1, artifact_id);
    while (try st.step()) {
        const req_id = st.columnText(0);
        const hash = st.columnText(1);
        try assertions.append(alloc, .{
            .req_id = try alloc.dupe(u8, req_id),
            .hash = try alloc.dupe(u8, hash),
        });
        if (req_id.len > 0 and !seen_req_ids.contains(req_id)) {
            try seen_req_ids.put(try alloc.dupe(u8, req_id), {});
            try req_ids.append(alloc, try alloc.dupe(u8, req_id));
        }
    }
    return .{
        .assertions = try assertions.toOwnedSlice(alloc),
        .req_ids = try req_ids.toOwnedSlice(alloc),
    };
}

fn computeNewSinceLastIngest(previous_req_ids: []const []const u8, assertions: []const ParsedRequirementAssertion, alloc: Allocator) ![]const []const u8 {
    var previous: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = previous.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        previous.deinit();
    }
    for (previous_req_ids) |req_id| {
        if (!previous.contains(req_id)) try previous.put(try alloc.dupe(u8, req_id), {});
    }
    var added: std.ArrayList([]const u8) = .empty;
    defer added.deinit(alloc);
    for (assertions) |assertion| {
        if (previous.contains(assertion.req_id)) continue;
        var already_added = false;
        for (added.items) |existing| {
            if (std.mem.eql(u8, existing, assertion.req_id)) {
                already_added = true;
                break;
            }
        }
        if (!already_added) try added.append(alloc, try alloc.dupe(u8, assertion.req_id));
    }
    return added.toOwnedSlice(alloc);
}

fn buildIngestSummary(
    db: *graph_live.GraphDb,
    artifact_id: []const u8,
    kind: ArtifactKind,
    disposition: IngestDisposition,
    previous: PreviousArtifactSnapshot,
    assertions: []const ParsedRequirementAssertion,
    null_text_count: usize,
    low_confidence_count: usize,
    diagnostics_emitted: usize,
    new_since_last_ingest: []const []const u8,
    alloc: Allocator,
) !IngestSummary {
    var previous_by_req: std.StringHashMap([]const u8) = .init(alloc);
    defer {
        var it = previous_by_req.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        previous_by_req.deinit();
    }
    for (previous.assertions) |item| {
        if (!previous_by_req.contains(item.req_id)) {
            try previous_by_req.put(try alloc.dupe(u8, item.req_id), item.hash);
        }
    }

    var nodes_added: usize = 0;
    var nodes_updated: usize = 0;
    var unchanged: usize = 0;
    for (assertions) |assertion| {
        const current_hash = hashNormalizedText(assertion.normalized_text);
        if (previous_by_req.get(assertion.req_id)) |old_hash| {
            if (std.mem.eql(u8, old_hash, &current_hash)) {
                unchanged += 1;
            } else {
                nodes_updated += 1;
            }
        } else {
            nodes_added += 1;
        }
    }

    return .{
        .artifact_id = try alloc.dupe(u8, artifact_id),
        .kind = kind,
        .requirements_seen = assertions.len,
        .nodes_added = nodes_added,
        .nodes_updated = nodes_updated,
        .nodes_deleted = previous.assertions.len,
        .unchanged = unchanged,
        .conflicts_detected = try countArtifactCrossSourceConflicts(db, artifact_id, alloc),
        .null_text_count = null_text_count,
        .low_confidence_count = low_confidence_count,
        .diagnostics_emitted = diagnostics_emitted,
        .timestamp = std.time.timestamp(),
        .disposition = disposition,
        .new_since_last_ingest = blk: {
            var out: std.ArrayList([]const u8) = .empty;
            defer out.deinit(alloc);
            for (new_since_last_ingest) |req_id| try out.append(alloc, try alloc.dupe(u8, req_id));
            break :blk try out.toOwnedSlice(alloc);
        },
    };
}

fn logIngestSummary(summary: IngestSummary) void {
    std.log.info(
        "design artifact ingest result=success artifact={s} kind={s} disposition={s} requirements_seen={d} added={d} updated={d} deleted={d} unchanged={d} conflicts={d} null_text={d} low_confidence={d} diagnostics={d}",
        .{
            summary.artifact_id,
            summary.kind.toString(),
            summary.disposition.toString(),
            summary.requirements_seen,
            summary.nodes_added,
            summary.nodes_updated,
            summary.nodes_deleted,
            summary.unchanged,
            summary.conflicts_detected,
            summary.null_text_count,
            summary.low_confidence_count,
            summary.diagnostics_emitted,
        },
    );
}

fn validateUniqueAssertionIds(assertions: []const ParsedRequirementAssertion, alloc: Allocator) !void {
    var seen: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        seen.deinit();
    }

    for (assertions) |assertion| {
        if (seen.contains(assertion.req_id)) return error.DuplicateRequirementAssertion;
        try seen.put(try alloc.dupe(u8, assertion.req_id), {});
    }
}

pub fn applyArtifactSnapshot(
    db: *graph_live.GraphDb,
    artifact_id: []const u8,
    kind: ArtifactKind,
    display_name: []const u8,
    path: []const u8,
    logical_key: []const u8,
    ingest_source: []const u8,
    disposition: IngestDisposition,
    assertions: []const ParsedRequirementAssertion,
    alloc: Allocator,
) !ArtifactIngestResult {
    try validateUniqueAssertionIds(assertions, alloc);

    var touched_ids: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = touched_ids.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        touched_ids.deinit();
    }

    const snapshot = try loadPreviousArtifactSnapshot(db, artifact_id, alloc);
    defer snapshot.deinit(alloc);

    try deleteArtifactAssertions(db, artifact_id, alloc, &touched_ids);

    const now_text = try std.fmt.allocPrint(alloc, "{d}", .{std.time.timestamp()});
    defer alloc.free(now_text);
    const new_since_last_ingest = try computeNewSinceLastIngest(snapshot.req_ids, assertions, alloc);
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
        try ensureCanonicalRequirement(db, assertion.req_id, alloc);
        const text_id = try buildRequirementTextId(artifact_id, assertion.req_id, alloc);
        defer alloc.free(text_id);
        const props = try buildRequirementTextProperties(
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
            try upsertArtifactDiagnostic(db, artifact_id, assertion.req_id, 9604, "REQ_TEXT_AMBIGUOUS_WITHIN_SOURCE", "warn", "Requirement text ambiguous within artifact", alloc);
            diagnostics_emitted += 1;
        } else if (std.mem.eql(u8, assertion.parse_status, "null_text") or assertion.text == null or assertion.text.?.len == 0) {
            try upsertArtifactDiagnostic(db, artifact_id, assertion.req_id, 9603, "REQ_TEXT_NULL", "warn", "Requirement text missing in design artifact", alloc);
            diagnostics_emitted += 1;
            null_text_count += 1;
        } else if (isLowConfidenceStatus(assertion.parse_status)) {
            try upsertArtifactDiagnostic(db, artifact_id, assertion.req_id, 9605, "REQ_TEXT_LOW_CONFIDENCE", "warn", "Requirement text extracted with low confidence", alloc);
            diagnostics_emitted += 1;
            low_confidence_count += 1;
        }
    }

    var touched_it = touched_ids.iterator();
    while (touched_it.next()) |entry| {
        try rebuildConflictEdgesForRequirement(db, entry.key_ptr.*, alloc);
        diagnostics_emitted += try recomputeRequirementState(db, entry.key_ptr.*, alloc);
    }

    const summary = try buildIngestSummary(db, artifact_id, kind, disposition, snapshot, assertions, null_text_count, low_confidence_count, diagnostics_emitted, new_since_last_ingest, alloc);
    logIngestSummary(summary);
    return .{
        .artifact_id = try alloc.dupe(u8, artifact_id),
        .summary = summary,
    };
}

fn deleteArtifactAssertions(
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

fn ensureCanonicalRequirement(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) !void {
    if (try db.getNode(req_id, alloc)) |existing| {
        shared.freeNode(existing, alloc);
        return;
    }
    const props = "{\"text_status\":\"no_source\"}";
    try db.addNode(req_id, "Requirement", props, null);
}

fn clearLegacyRequirementStatement(db: *graph_live.GraphDb, req_id: []const u8) !void {
    var st = try db.db.prepare("SELECT properties FROM nodes WHERE id=? AND type='Requirement'");
    defer st.finalize();
    try st.bindText(1, req_id);
    if (!try st.step()) return;
    const raw_props = st.columnText(0);
    const stripped = try stripAndExtendRequirementProperties(raw_props, null, "aligned", 1, std.heap.page_allocator);
    defer std.heap.page_allocator.free(stripped);

    db.db.write_mu.lock();
    defer db.db.write_mu.unlock();
    var upd = try db.db.prepare(
        "UPDATE nodes SET properties=?, updated_at=? WHERE id=?"
    );
    defer upd.finalize();
    try upd.bindText(1, stripped);
    try upd.bindInt(2, std.time.timestamp());
    try upd.bindText(3, req_id);
    _ = try upd.step();
}

fn recomputeRequirementState(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) !usize {
    var raw_props: ?[]const u8 = null;
    {
        var st = try db.db.prepare("SELECT properties FROM nodes WHERE id=? AND type='Requirement'");
        defer st.finalize();
        try st.bindText(1, req_id);
        if (!try st.step()) return 0;
        raw_props = try alloc.dupe(u8, st.columnText(0));
    }
    defer if (raw_props) |value| alloc.free(value);

    var resolution = try db.resolveRequirementText(req_id, alloc);
    defer resolution.deinit(alloc);
    const next_props = try stripAndExtendRequirementProperties(
        raw_props.?,
        resolution.authoritative_source,
        resolution.text_status,
        resolution.source_count,
        alloc,
    );
    defer alloc.free(next_props);

    const suspect = std.mem.eql(u8, resolution.text_status, "conflict");
    const suspect_reason = if (suspect) "Requirement text differs across design sources" else null;

    {
        db.db.write_mu.lock();
        defer db.db.write_mu.unlock();
        var upd = try db.db.prepare(
            "UPDATE nodes SET properties=?, suspect=?, suspect_reason=?, updated_at=? WHERE id=?"
        );
        defer upd.finalize();
        try upd.bindText(1, next_props);
        try upd.bindInt(2, if (suspect) 1 else 0);
        if (suspect_reason) |value| try upd.bindText(3, value) else try upd.bindNull(3);
        try upd.bindInt(4, std.time.timestamp());
        try upd.bindText(5, req_id);
        _ = try upd.step();
    }

    var diagnostics_emitted: usize = 0;
    try clearRequirementDiagnostic(db, "REQ_TEXT_MISMATCH", req_id, alloc);
    try clearRequirementDiagnostic(db, "REQ_SINGLE_SOURCE", req_id, alloc);
    try clearRequirementDiagnostic(db, "REQ_NO_SOURCE", req_id, alloc);
    try clearRequirementDiagnostic(db, "REQ_SUSPECT", req_id, alloc);

    if (suspect) {
        try upsertArtifactDiagnostic(db, "requirement", req_id, 9601, "REQ_TEXT_MISMATCH", "warn", "Requirement text differs across design sources", alloc);
        try upsertArtifactDiagnostic(db, "requirement", req_id, 9606, "REQ_SUSPECT", "warn", "Requirement is suspect and needs review", alloc);
        diagnostics_emitted += 2;
    } else if (resolution.source_count == 1) {
        try upsertArtifactDiagnostic(db, "requirement", req_id, 9607, "REQ_SINGLE_SOURCE", "info", "Requirement asserted by only one source", alloc);
        diagnostics_emitted += 1;
    } else if (resolution.source_count == 0) {
        try upsertArtifactDiagnostic(db, "requirement", req_id, 9602, "REQ_NO_SOURCE", "warn", "Requirement has no source assertion", alloc);
        diagnostics_emitted += 1;
    }
    return diagnostics_emitted;
}

fn rebuildConflictEdgesForRequirement(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) !void {
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
    try db.requirementSourceAssertions(req_id, alloc, &assertions);

    db.db.write_mu.lock();
    defer db.db.write_mu.unlock();
    {
        var del = try db.db.prepare(
            \\DELETE FROM edges
            \\WHERE label='CONFLICTS_WITH'
            \\  AND from_id IN (
            \\      SELECT rt.id FROM nodes rt
            \\      JOIN edges e ON e.from_id = rt.id AND e.label='ASSERTS'
            \\      WHERE rt.type='RequirementText' AND e.to_id = ?
            \\  )
        );
        defer del.finalize();
        try del.bindText(1, req_id);
        _ = try del.step();
    }
    for (assertions.items, 0..) |left, i| {
        for (assertions.items[(i + 1)..]) |right| {
            const left_hash = left.hash orelse "";
            const right_hash = right.hash orelse "";
            const hashes_match = left_hash.len > 0 and right_hash.len > 0 and std.mem.eql(u8, left_hash, right_hash);
            if (hashes_match) continue;
            const left_text = left.normalized_text orelse left.text orelse "";
            const right_text = right.normalized_text orelse right.text orelse "";
            if (left_text.len == 0 or right_text.len == 0) continue;
            if (std.mem.eql(u8, left_text, right_text)) continue;
            try db.addEdge(left.text_id, right.text_id, "CONFLICTS_WITH");
            try db.addEdge(right.text_id, left.text_id, "CONFLICTS_WITH");
        }
    }
}

fn upsertArtifactDiagnostic(
    db: *graph_live.GraphDb,
    subject_prefix: []const u8,
    subject_suffix: []const u8,
    code: u16,
    code_name: []const u8,
    severity: []const u8,
    title: []const u8,
    alloc: Allocator,
) !void {
    const subject = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ subject_prefix, subject_suffix });
    defer alloc.free(subject);
    const dedupe_key = try std.fmt.allocPrint(alloc, "design-artifacts:{s}:{s}", .{ code_name, subject });
    defer alloc.free(dedupe_key);
    var details: std.ArrayList(u8) = .empty;
    defer details.deinit(alloc);
    try details.appendSlice(alloc, "{\"code\":");
    try shared.appendJsonStr(&details, code_name, alloc);
    try details.appendSlice(alloc, "}");
    try db.upsertRuntimeDiagnostic(dedupe_key, code, severity, title, title, "design_artifacts", subject, details.items);
}

fn clearRequirementDiagnostic(db: *graph_live.GraphDb, code_name: []const u8, req_id: []const u8, alloc: Allocator) !void {
    const subject = try std.fmt.allocPrint(alloc, "requirement:{s}", .{req_id});
    defer alloc.free(subject);
    const dedupe_key = try std.fmt.allocPrint(alloc, "design-artifacts:{s}:{s}", .{ code_name, subject });
    defer alloc.free(dedupe_key);
    try db.clearRuntimeDiagnostic(dedupe_key);
}

fn buildRequirementTextProperties(
    artifact_id: []const u8,
    kind: ArtifactKind,
    assertion: ParsedRequirementAssertion,
    imported_at: []const u8,
    alloc: Allocator,
) ![]const u8 {
    const hash_hex = hashNormalizedText(assertion.normalized_text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"req_id\":");
    try shared.appendJsonStr(&buf, assertion.req_id, alloc);
    try buf.appendSlice(alloc, ",\"artifact_id\":");
    try shared.appendJsonStr(&buf, artifact_id, alloc);
    try buf.appendSlice(alloc, ",\"source_kind\":");
    try shared.appendJsonStr(&buf, kind.toString(), alloc);
    try buf.appendSlice(alloc, ",\"section\":");
    try shared.appendJsonStr(&buf, assertion.section, alloc);
    try buf.appendSlice(alloc, ",\"text\":");
    try shared.appendJsonStrOpt(&buf, assertion.text, alloc);
    try buf.appendSlice(alloc, ",\"normalized_text\":");
    try shared.appendJsonStrOpt(&buf, assertion.normalized_text, alloc);
    try buf.appendSlice(alloc, ",\"hash\":");
    try shared.appendJsonStr(&buf, &hash_hex, alloc);
    try buf.appendSlice(alloc, ",\"imported_at\":");
    try shared.appendJsonStr(&buf, imported_at, alloc);
    try buf.appendSlice(alloc, ",\"parse_status\":");
    try shared.appendJsonStr(&buf, assertion.parse_status, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"occurrence_count\":{d}}}", .{assertion.occurrence_count});
    return alloc.dupe(u8, buf.items);
}

fn stripAndExtendRequirementProperties(
    raw_props: []const u8,
    authoritative_source: ?[]const u8,
    text_status: []const u8,
    source_count: usize,
    alloc: Allocator,
) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw_props, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '{');
    var first = true;
    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "statement") or
                std.mem.eql(u8, key, "effective_statement") or
                std.mem.eql(u8, key, "effective_statement_source") or
                std.mem.eql(u8, key, "text_status") or
                std.mem.eql(u8, key, "authoritative_source") or
                std.mem.eql(u8, key, "source_count") or
                std.mem.eql(u8, key, "source_assertions"))
            {
                continue;
            }
            if (!first) try buf.append(alloc, ',');
            first = false;
            try json_util.appendJsonQuoted(&buf, key, alloc);
            try buf.append(alloc, ':');
            try appendJsonValue(&buf, entry.value_ptr.*, alloc);
        }
    }
    if (!first) try buf.append(alloc, ',');
    try buf.appendSlice(alloc, "\"text_status\":");
    try shared.appendJsonStr(&buf, text_status, alloc);
    try buf.appendSlice(alloc, ",\"authoritative_source\":");
    try shared.appendJsonStrOpt(&buf, authoritative_source, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"source_count\":{d}}}", .{source_count});
    return alloc.dupe(u8, buf.items);
}

fn appendJsonValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: Allocator) !void {
    switch (value) {
        .null => try buf.appendSlice(alloc, "null"),
        .bool => |v| try buf.appendSlice(alloc, if (v) "true" else "false"),
        .integer => |v| try std.fmt.format(buf.writer(alloc), "{d}", .{v}),
        .float => |v| try std.fmt.format(buf.writer(alloc), "{d}", .{v}),
        .number_string => |v| try buf.appendSlice(alloc, v),
        .string => |v| try json_util.appendJsonQuoted(buf, v, alloc),
        else => try json_util.appendJsonQuoted(buf, "", alloc),
    }
}

fn extractStringField(json: []const u8, key: []const u8) ?[]const u8 {
    return json_util.extractJsonFieldStatic(json, key);
}

fn normalizeText(text: []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var last_space = false;
    for (text) |c| {
        const lowered = std.ascii.toLower(c);
        if (std.ascii.isWhitespace(lowered)) {
            if (!last_space and buf.items.len > 0) {
                try buf.append(alloc, ' ');
                last_space = true;
            }
            continue;
        }
        last_space = false;
        try buf.append(alloc, lowered);
    }
    return alloc.dupe(u8, std.mem.trimRight(u8, buf.items, " "));
}

fn classifyExtractedText(text: ?[]const u8, normalized_text: ?[]const u8) []const u8 {
    const raw = text orelse return "null_text";
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return "low_confidence_empty_after_trim";
    if (raw.len > 300) return "low_confidence_long_text";

    var token_start: ?usize = null;
    var found_ids: usize = 0;
    var idx: usize = 0;
    while (idx <= raw.len) : (idx += 1) {
        const boundary = idx == raw.len or std.ascii.isWhitespace(raw[idx]) or std.mem.indexOfScalar(u8, ":;,()[]{}", raw[idx]) != null;
        if (token_start == null) {
            if (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) token_start = idx;
            continue;
        }
        if (!boundary) continue;
        const token = std.mem.trim(u8, raw[token_start.?..idx], " \t\r\n:;,.()[]{}");
        token_start = null;
        if (token.len > 0 and rtmify.id.looksLikeStructuredIdForInference(token)) {
            found_ids += 1;
            if (found_ids > 0) return "low_confidence_nested_ids";
        }
    }

    if (normalized_text == null or normalized_text.?.len == 0) return "null_text";
    return "ok";
}

pub fn parseDocxAssertions(path: []const u8, alloc: Allocator) !std.ArrayList(ParsedRequirementAssertion) {
    const xml = try extractDocxDocumentXml(path, alloc);
    defer alloc.free(xml);

    var map: std.StringHashMap(ParsedRequirementAssertion) = .init(alloc);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.section);
            if (entry.value_ptr.text) |value| alloc.free(value);
            if (entry.value_ptr.normalized_text) |value| alloc.free(value);
            alloc.free(entry.value_ptr.parse_status);
        }
        map.deinit();
    }

    try collectTableAssertions(xml, alloc, &map);
    try collectParagraphAssertions(xml, alloc, &map);

    var out: std.ArrayList(ParsedRequirementAssertion) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        try out.append(alloc, .{
            .req_id = try alloc.dupe(u8, entry.key_ptr.*),
            .section = try alloc.dupe(u8, entry.value_ptr.section),
            .text = if (entry.value_ptr.text) |value| try alloc.dupe(u8, value) else null,
            .normalized_text = if (entry.value_ptr.normalized_text) |value| try alloc.dupe(u8, value) else null,
            .parse_status = try alloc.dupe(u8, entry.value_ptr.parse_status),
            .occurrence_count = entry.value_ptr.occurrence_count,
        });
    }
    return out;
}

pub fn extractDocxAllText(path: []const u8, alloc: Allocator) ![]u8 {
    const xml = try extractDocxDocumentXml(path, alloc);
    defer alloc.free(xml);
    return extractTextRuns(xml, alloc);
}

fn parseRtmWorkbookAssertions(path: []const u8, alloc: Allocator) !std.ArrayList(ParsedRequirementAssertion) {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sheets = try xlsx.parse(arena, path);
    try validateRtmWorkbookShape(sheets);
    const requirement_rows = findSheetRows(sheets, "Requirements") orelse return error.InvalidXlsx;
    if (requirement_rows.len == 0) return std.ArrayList(ParsedRequirementAssertion).empty;

    const headers = requirement_rows[0];
    const c_id = findHeaderIndex(headers, &.{ "ID", "Req ID", "Requirement ID" }) orelse return error.InvalidXlsx;
    const c_stmt = findHeaderIndex(headers, &.{ "Statement", "Requirement Statement", "Text" }) orelse return error.InvalidXlsx;

    var out: std.ArrayList(ParsedRequirementAssertion) = .empty;
    var seen: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        seen.deinit();
    }

    for (requirement_rows[1..]) |row| {
        if (c_id >= row.len) continue;
        const req_id = std.mem.trim(u8, row[c_id], " \t\r\n:");
        if (req_id.len == 0 or !rtmify.id.looksLikeStructuredIdForInference(req_id)) continue;
        if (seen.contains(req_id)) continue;
        try seen.put(try alloc.dupe(u8, req_id), {});
        const statement = if (c_stmt < row.len) std.mem.trim(u8, row[c_stmt], " \t\r\n") else "";
        const normalized = if (statement.len > 0) try normalizeText(statement, alloc) else null;
        defer if (normalized) |value| alloc.free(value);
        const parse_status = classifyExtractedText(if (statement.len > 0) statement else null, normalized);
        try out.append(alloc, .{
            .req_id = try alloc.dupe(u8, req_id),
            .section = try alloc.dupe(u8, "Requirements"),
            .text = if (statement.len > 0) try alloc.dupe(u8, statement) else null,
            .normalized_text = if (normalized) |value| try alloc.dupe(u8, value) else null,
            .parse_status = try alloc.dupe(u8, parse_status),
            .occurrence_count = 1,
        });
    }
    return out;
}

pub fn validateRtmWorkbookShape(sheets: []const xlsx.SheetData) !void {
    if (findSheetRows(sheets, "SOUP Components") != null or findSheetRows(sheets, "Design BOM") != null) return error.UnsupportedFormat;
    const required = [_][]const u8{ "Requirements", "User Needs", "Tests", "Risks" };
    for (required) |name| {
        if (findSheetRows(sheets, name) == null) return error.InvalidXlsx;
    }
}

fn findSheetRows(sheets: []const xlsx.SheetData, want: []const u8) ?[]const []const []const u8 {
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, sheet.name, " \r\n\t"), want)) return sheet.rows;
    }
    return null;
}

fn findHeaderIndex(headers: []const []const u8, candidates: []const []const u8) ?usize {
    for (headers, 0..) |header, idx| {
        const trimmed = std.mem.trim(u8, header, " \r\n\t");
        for (candidates) |candidate| {
            if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return idx;
        }
    }
    return null;
}

fn collectParagraphAssertions(xml: []const u8, alloc: Allocator, map: *std.StringHashMap(ParsedRequirementAssertion)) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<w:p")) |start| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, xml, open_end, "</w:p>") orelse break;
        const text = try extractTextRuns(xml[open_end + 1 .. close], alloc);
        defer alloc.free(text);
        pos = close + "</w:p>".len;
        if (text.len == 0) continue;
        if (try inferAssertionFromText(text, "paragraph", alloc)) |assertion| {
            defer {
                alloc.free(assertion.req_id);
                alloc.free(assertion.section);
                if (assertion.text) |value| alloc.free(value);
                if (assertion.normalized_text) |value| alloc.free(value);
                alloc.free(assertion.parse_status);
            }
            try mergeAssertion(map, assertion, alloc);
        }
    }
}

fn collectTableAssertions(xml: []const u8, alloc: Allocator, map: *std.StringHashMap(ParsedRequirementAssertion)) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<w:tr")) |row_start| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, row_start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, xml, open_end, "</w:tr>") orelse break;
        const row_xml = xml[open_end + 1 .. close];
        pos = close + "</w:tr>".len;

        var cells: std.ArrayList([]const u8) = .empty;
        defer {
            for (cells.items) |cell| alloc.free(cell);
            cells.deinit(alloc);
        }

        var cell_pos: usize = 0;
        while (std.mem.indexOfPos(u8, row_xml, cell_pos, "<w:tc")) |cell_start| {
            const cell_open_end = std.mem.indexOfScalarPos(u8, row_xml, cell_start, '>') orelse break;
            const cell_close = std.mem.indexOfPos(u8, row_xml, cell_open_end, "</w:tc>") orelse break;
            try cells.append(alloc, try extractTextRuns(row_xml[cell_open_end + 1 .. cell_close], alloc));
            cell_pos = cell_close + "</w:tc>".len;
        }

        for (cells.items, 0..) |cell_text, idx| {
            const id_candidate = std.mem.trim(u8, cell_text, " \t\r\n:");
            if (!rtmify.id.looksLikeStructuredIdForInference(id_candidate)) continue;
            const value_text = blk: {
                var next_idx = idx + 1;
                while (next_idx < cells.items.len) : (next_idx += 1) {
                    const candidate = std.mem.trim(u8, cells.items[next_idx], " \t\r\n:");
                    if (candidate.len > 0 and !rtmify.id.looksLikeStructuredIdForInference(candidate)) break :blk candidate;
                }
                break :blk "";
            };
            const normalized = if (value_text.len > 0) try normalizeText(value_text, alloc) else null;
            defer if (normalized) |value| alloc.free(value);
            const parse_status = classifyExtractedText(if (value_text.len > 0) value_text else null, normalized);
            const assertion: ParsedRequirementAssertion = .{
                .req_id = try alloc.dupe(u8, id_candidate),
                .section = try alloc.dupe(u8, "table"),
                .text = if (value_text.len > 0) try alloc.dupe(u8, value_text) else null,
                .normalized_text = if (normalized) |value| try alloc.dupe(u8, value) else null,
                .parse_status = try alloc.dupe(u8, parse_status),
                .occurrence_count = 1,
            };
            defer {
                alloc.free(assertion.req_id);
                alloc.free(assertion.section);
                if (assertion.text) |value| alloc.free(value);
                if (assertion.normalized_text) |value| alloc.free(value);
                alloc.free(assertion.parse_status);
            }
            try mergeAssertion(map, assertion, alloc);
        }
    }
}

fn inferAssertionFromText(text: []const u8, section: []const u8, alloc: Allocator) !?ParsedRequirementAssertion {
    var token_start: ?usize = null;
    var idx: usize = 0;
    while (idx <= text.len) : (idx += 1) {
        const is_boundary = idx == text.len or std.ascii.isWhitespace(text[idx]) or std.mem.indexOfScalar(u8, ":;,()[]{}", text[idx]) != null;
        if (token_start == null) {
            if (idx < text.len and !std.ascii.isWhitespace(text[idx])) token_start = idx;
            continue;
        }
        if (!is_boundary) continue;
        const token = std.mem.trim(u8, text[token_start.?..idx], " \t\r\n:;,.()[]{}");
        token_start = null;
        if (token.len == 0 or !rtmify.id.looksLikeStructuredIdForInference(token)) continue;
        const remainder = std.mem.trim(u8, text[idx..], " \t\r\n:-\u{2014}");
        const normalized = if (remainder.len > 0) try normalizeText(remainder, alloc) else null;
        defer if (normalized) |value| alloc.free(value);
        const parse_status = classifyExtractedText(if (remainder.len > 0) remainder else null, normalized);
        return ParsedRequirementAssertion{
            .req_id = try alloc.dupe(u8, token),
            .section = try alloc.dupe(u8, section),
            .text = if (remainder.len > 0) try alloc.dupe(u8, remainder) else null,
            .normalized_text = if (normalized) |value| try alloc.dupe(u8, value) else null,
            .parse_status = try alloc.dupe(u8, parse_status),
            .occurrence_count = 1,
        };
    }
    return null;
}

fn mergeAssertion(map: *std.StringHashMap(ParsedRequirementAssertion), assertion: ParsedRequirementAssertion, alloc: Allocator) !void {
    if (map.getPtr(assertion.req_id)) |existing| {
        existing.occurrence_count += 1;
        const left = existing.normalized_text orelse existing.text orelse "";
        const right = assertion.normalized_text orelse assertion.text orelse "";
        if (!std.mem.eql(u8, left, right)) {
            alloc.free(existing.parse_status);
            existing.parse_status = try alloc.dupe(u8, "ambiguous_within_artifact");
        } else if (!std.mem.eql(u8, existing.parse_status, "ambiguous_within_artifact") and isLowConfidenceStatus(assertion.parse_status)) {
            alloc.free(existing.parse_status);
            existing.parse_status = try alloc.dupe(u8, assertion.parse_status);
        }
        return;
    }
    try map.put(try alloc.dupe(u8, assertion.req_id), .{
        .req_id = undefined,
        .section = try alloc.dupe(u8, assertion.section),
        .text = if (assertion.text) |value| try alloc.dupe(u8, value) else null,
        .normalized_text = if (assertion.normalized_text) |value| try alloc.dupe(u8, value) else null,
        .parse_status = try alloc.dupe(u8, assertion.parse_status),
        .occurrence_count = assertion.occurrence_count,
    });
}

fn extractDocxDocumentXml(path: []const u8, alloc: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(&read_buf);

    const Entry = struct {
        name: []u8,
        file_offset: u64,
        compressed_size: u64,
        uncompressed_size: u64,
        method: std.zip.CompressionMethod,
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |item| alloc.free(item.name);
        entries.deinit(alloc);
    }

    var iter = try std.zip.Iterator.init(&fr);
    var name_buf: [512]u8 = undefined;
    while (try iter.next()) |ce| {
        if (ce.filename_len > name_buf.len) continue;
        try fr.seekTo(ce.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name_buf[0..ce.filename_len]);
        const name_slice = name_buf[0..ce.filename_len];
        try entries.append(alloc, .{
            .name = try alloc.dupe(u8, name_slice),
            .file_offset = ce.file_offset,
            .compressed_size = ce.compressed_size,
            .uncompressed_size = ce.uncompressed_size,
            .method = ce.compression_method,
        });
    }

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, "word/document.xml")) {
            return extractZipEntry(&fr, entry.file_offset, entry.compressed_size, entry.uncompressed_size, entry.method, alloc);
        }
    }
    return error.InvalidXlsx;
}

fn extractZipEntry(
    fr: *std.fs.File.Reader,
    file_offset: u64,
    compressed_size: u64,
    uncompressed_size: u64,
    method: std.zip.CompressionMethod,
    alloc: Allocator,
) ![]u8 {
    try fr.seekTo(file_offset);
    const lh = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
    if (!std.mem.eql(u8, &lh.signature, &std.zip.local_file_header_sig)) return error.InvalidXlsx;

    const data_off = file_offset +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        @as(u64, lh.filename_len) +
        @as(u64, lh.extra_len);
    try fr.seekTo(data_off);

    _ = compressed_size;
    const buf = try alloc.alloc(u8, @intCast(uncompressed_size));
    errdefer alloc.free(buf);
    var fw = std.Io.Writer.fixed(buf);
    switch (method) {
        .store => try fr.interface.streamExact64(&fw, uncompressed_size),
        .deflate => {
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var dec = std.compress.flate.Decompress.init(&fr.interface, .raw, &flate_buf);
            try dec.reader.streamExact64(&fw, uncompressed_size);
        },
        else => return error.UnsupportedContentType,
    }
    return buf;
}

fn extractTextRuns(xml: []const u8, alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<w:t")) |start| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, xml, open_end, "</w:t>") orelse break;
        const text = try xmlUnescape(xml[open_end + 1 .. close], alloc);
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
        pos = close + "</w:t>".len;
    }
    return alloc.dupe(u8, std.mem.trim(u8, out.items, " \t\r\n"));
}

fn xmlUnescape(src: []const u8, alloc: Allocator) ![]u8 {
    if (std.mem.indexOfScalar(u8, src, '&') == null) return alloc.dupe(u8, src);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "&amp;")) {
            try out.append(alloc, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, src[i..], "&lt;")) {
            try out.append(alloc, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, src[i..], "&gt;")) {
            try out.append(alloc, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, src[i..], "&quot;")) {
            try out.append(alloc, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, src[i..], "&apos;")) {
            try out.append(alloc, '\'');
            i += 6;
        } else {
            try out.append(alloc, src[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

test "artifact id uses kind namespace" {
    const value = try artifactIdFor(.srs_docx, "core", std.testing.allocator);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("artifact://srs_docx/core", value);
}

test "rtm workbook artifact id uses rtm namespace" {
    const value = try artifactIdFor(.rtm_workbook, "demo", std.testing.allocator);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("artifact://rtm/demo", value);
}

test "requirement text id omits redundant index" {
    const value = try buildRequirementTextId("artifact://srs_docx/core", "REQ-001", std.testing.allocator);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("artifact://srs_docx/core:REQ-001", value);
}

test "validateUniqueAssertionIds rejects duplicate requirement ids" {
    const assertions = [_]ParsedRequirementAssertion{
        .{
            .req_id = "REQ-001",
            .section = "paragraph",
            .text = "One",
            .normalized_text = "one",
            .parse_status = "ok",
            .occurrence_count = 2,
        },
        .{
            .req_id = "REQ-001",
            .section = "table",
            .text = "One",
            .normalized_text = "one",
            .parse_status = "ambiguous_within_artifact",
            .occurrence_count = 1,
        },
    };

    try std.testing.expectError(error.DuplicateRequirementAssertion, validateUniqueAssertionIds(&assertions, std.testing.allocator));
}
