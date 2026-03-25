const std = @import("std");

const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const diagnostics = @import("diagnostics.zig");
const json = @import("json.zig");

pub fn ensureCanonicalRequirement(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) !void {
    if (try db.getNode(req_id, alloc)) |existing| {
        @import("../routes/shared.zig").freeNode(existing, alloc);
        return;
    }
    const props = "{\"text_status\":\"no_source\"}";
    try db.addNode(req_id, "Requirement", props, null);
}

pub fn clearLegacyRequirementStatement(db: *graph_live.GraphDb, req_id: []const u8) !void {
    var st = try db.db.prepare("SELECT properties FROM nodes WHERE id=? AND type='Requirement'");
    defer st.finalize();
    try st.bindText(1, req_id);
    if (!try st.step()) return;
    const raw_props = st.columnText(0);
    const stripped = try json.stripAndExtendRequirementProperties(raw_props, null, "aligned", 1, std.heap.page_allocator);
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

pub fn recomputeRequirementState(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) !usize {
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
    const next_props = try json.stripAndExtendRequirementProperties(
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
    try diagnostics.clearRequirementDiagnostic(db, "REQ_TEXT_MISMATCH", req_id, alloc);
    try diagnostics.clearRequirementDiagnostic(db, "REQ_SINGLE_SOURCE", req_id, alloc);
    try diagnostics.clearRequirementDiagnostic(db, "REQ_NO_SOURCE", req_id, alloc);
    try diagnostics.clearRequirementDiagnostic(db, "REQ_SUSPECT", req_id, alloc);

    if (suspect) {
        try diagnostics.upsertArtifactDiagnostic(db, "requirement", req_id, 9601, "REQ_TEXT_MISMATCH", "warn", "Requirement text differs across design sources", alloc);
        try diagnostics.upsertArtifactDiagnostic(db, "requirement", req_id, 9606, "REQ_SUSPECT", "warn", "Requirement is suspect and needs review", alloc);
        diagnostics_emitted += 2;
    } else if (resolution.source_count == 1) {
        try diagnostics.upsertArtifactDiagnostic(db, "requirement", req_id, 9607, "REQ_SINGLE_SOURCE", "info", "Requirement asserted by only one source", alloc);
        diagnostics_emitted += 1;
    } else if (resolution.source_count == 0) {
        try diagnostics.upsertArtifactDiagnostic(db, "requirement", req_id, 9602, "REQ_NO_SOURCE", "warn", "Requirement has no source assertion", alloc);
        diagnostics_emitted += 1;
    }
    return diagnostics_emitted;
}

pub fn rebuildConflictEdgesForRequirement(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) !void {
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
