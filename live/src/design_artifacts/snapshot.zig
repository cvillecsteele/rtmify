const std = @import("std");

const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const query = @import("query.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn loadPreviousArtifactSnapshot(db: *graph_live.GraphDb, artifact_id: []const u8, alloc: Allocator) !types.PreviousArtifactSnapshot {
    var assertions: std.ArrayList(types.PreviousArtifactAssertion) = .empty;
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

pub fn computeNewSinceLastIngest(previous_req_ids: []const []const u8, assertions: []const types.ParsedRequirementAssertion, alloc: Allocator) ![]const []const u8 {
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

pub fn buildIngestSummary(
    db: *graph_live.GraphDb,
    artifact_id: []const u8,
    kind: types.ArtifactKind,
    disposition: types.IngestDisposition,
    previous: types.PreviousArtifactSnapshot,
    assertions: []const types.ParsedRequirementAssertion,
    null_text_count: usize,
    low_confidence_count: usize,
    diagnostics_emitted: usize,
    new_since_last_ingest: []const []const u8,
    alloc: Allocator,
) !types.IngestSummary {
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
        const current_hash = util.hashNormalizedText(assertion.normalized_text);
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
        .conflicts_detected = try query.countArtifactCrossSourceConflicts(db, artifact_id, alloc),
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

pub fn logIngestSummary(summary: types.IngestSummary) void {
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

pub fn validateUniqueAssertionIds(assertions: []const types.ParsedRequirementAssertion, alloc: Allocator) !void {
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
