const std = @import("std");

const internal = @import("../internal.zig");
const design_artifacts = @import("../../design_artifacts.zig");
const common = @import("common.zig");

pub fn nodeMarkdown(node_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const data = try internal.routes.handleNode(db, node_id, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    return common.markdownFromNodeDetail(node, internal.json_util.getObjectField(parsed.value, "edges_out"), internal.json_util.getObjectField(parsed.value, "edges_in"), alloc);
}

pub fn userNeedMarkdown(user_need_id: []const u8, db: *internal.graph_live.GraphDb, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleNode(db, user_need_id, arena);
    const gaps_json = try internal.routes.handleChainGaps(db, profile_name, arena);

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_json, .{});
    defer gaps_parsed.deinit();

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    const edges_in = internal.json_util.getObjectField(parsed.value, "edges_in");
    const edges_out = internal.json_util.getObjectField(parsed.value, "edges_out");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try std.fmt.format(buf.writer(alloc), "# User Need {s}\n\n", .{user_need_id});
    try common.appendNodeCoreMarkdown(&buf, node, alloc);
    try common.appendFilteredEdgeNodeSection(&buf, "Derived Requirements", edges_in, "DERIVES_FROM", "Requirement", alloc);
    try common.appendFilteredGapSection(&buf, "Chain Gaps", if (gaps_parsed.value == .array) gaps_parsed.value else null, user_need_id, alloc);
    try common.appendEdgeSection(&buf, "Other Outgoing Links", edges_out, alloc);
    try common.appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "DERIVES_FROM", "Requirement", alloc);
    return alloc.dupe(u8, buf.items);
}

pub fn artifactMarkdown(artifact_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try design_artifacts.getArtifactJson(db, artifact_id, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# Design Artifact {s}\n\n", .{artifact_id});

    const props = internal.json_util.getObjectField(parsed.value, "properties");
    if (props) |p| {
        try std.fmt.format(buf.writer(alloc), "- Kind: {s}\n", .{internal.json_util.getString(p, "kind") orelse "unknown"});
        try std.fmt.format(buf.writer(alloc), "- Display Name: {s}\n", .{internal.json_util.getString(p, "display_name") orelse artifact_id});
        try std.fmt.format(buf.writer(alloc), "- Path: {s}\n", .{internal.json_util.getString(p, "path") orelse "—"});
        try std.fmt.format(buf.writer(alloc), "- Ingest Source: {s}\n", .{internal.json_util.getString(p, "ingest_source") orelse "—"});
        try std.fmt.format(buf.writer(alloc), "- Last Ingested: {s}\n\n", .{internal.json_util.getString(p, "last_ingested_at") orelse "—"});
    }

    const extraction_summary = internal.json_util.getObjectField(parsed.value, "extraction_summary");
    if (extraction_summary) |summary| {
        try std.fmt.format(buf.writer(alloc), "- Requirements Seen: {d}\n", .{internal.json_util.getInt(summary, "requirements_seen") orelse 0});
        try std.fmt.format(buf.writer(alloc), "- Null Text Rows: {d}\n", .{internal.json_util.getInt(summary, "null_text_count") orelse 0});
        try std.fmt.format(buf.writer(alloc), "- Low Confidence Rows: {d}\n", .{internal.json_util.getInt(summary, "low_confidence_count") orelse 0});
        try std.fmt.format(buf.writer(alloc), "- Ambiguous Rows: {d}\n\n", .{internal.json_util.getInt(summary, "ambiguous_within_artifact_count") orelse 0});
    }

    const new_ids = internal.json_util.getObjectField(parsed.value, "new_since_last_ingest");
    if (new_ids != null and new_ids.? == .array and new_ids.?.array.items.len > 0) {
        try buf.appendSlice(alloc, "## New Since Last Ingest\n");
        for (new_ids.?.array.items) |item| {
            if (item != .string) continue;
            try std.fmt.format(buf.writer(alloc), "- `{s}`\n", .{item.string});
        }
        try buf.append(alloc, '\n');
    }

    const conflicts = internal.json_util.getObjectField(parsed.value, "conflicts");
    if (conflicts != null and conflicts.? == .array and conflicts.?.array.items.len > 0) {
        try buf.appendSlice(alloc, "## Cross-Source Conflicts\n");
        for (conflicts.?.array.items) |item| {
            const req_id = internal.json_util.getString(item, "req_id") orelse "unknown";
            const other_artifact_id = internal.json_util.getString(item, "other_artifact_id") orelse "unknown";
            const other_text = internal.json_util.getString(item, "other_text") orelse "—";
            try std.fmt.format(buf.writer(alloc), "- `{s}` conflicts with `{s}` — {s}\n", .{ req_id, other_artifact_id, other_text });
        }
        try buf.append(alloc, '\n');
    }

    const assertions = internal.json_util.getObjectField(parsed.value, "assertions");
    try buf.appendSlice(alloc, "## Assertions\n");
    if (assertions == null or assertions.? != .array or assertions.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n");
        return alloc.dupe(u8, buf.items);
    }
    for (assertions.?.array.items) |item| {
        const req_id = internal.json_util.getString(item, "req_id") orelse internal.json_util.getString(item, "id") orelse "unknown";
        const text = internal.json_util.getString(item, "text") orelse "—";
        const status = internal.json_util.getString(item, "parse_status") orelse "ok";
        const hash = internal.json_util.getString(item, "hash") orelse "";
        if (hash.len > 0) {
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [status={s}, hash={s}]\n", .{ req_id, text, status, hash });
        } else {
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [status={s}]\n", .{ req_id, text, status });
        }
    }
    return alloc.dupe(u8, buf.items);
}

pub fn codeFileMarkdown(node_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const data = try internal.routes.handleNode(db, node_id, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    const node_type = internal.json_util.getString(node, "type") orelse return error.NotFound;
    const edges_out = internal.json_util.getObjectField(parsed.value, "edges_out");
    const edges_in = internal.json_util.getObjectField(parsed.value, "edges_in");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    if (std.mem.eql(u8, node_type, "SourceFile")) {
        try std.fmt.format(buf.writer(alloc), "# Source File {s}\n\n", .{node_id});
        try common.appendNodeCoreMarkdown(&buf, node, alloc);
        try common.appendFilteredEdgeNodeSection(&buf, "Linked Requirements", edges_in, "IMPLEMENTED_IN", "Requirement", alloc);
        try common.appendFilteredEdgeNodeSection(&buf, "Linked Design Outputs", edges_in, "IMPLEMENTED_IN", "DesignOutput", alloc);
        try common.appendFilteredEdgeNodeSection(&buf, "Verified By Test Files", edges_out, "VERIFIED_BY_CODE", "TestFile", alloc);
        try common.appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "IMPLEMENTED_IN", "Requirement", alloc);
        try common.appendNonMatchingEdgeSection(&buf, "Other Outgoing Links", edges_out, "VERIFIED_BY_CODE", "TestFile", alloc);
    } else if (std.mem.eql(u8, node_type, "TestFile")) {
        try std.fmt.format(buf.writer(alloc), "# Test File {s}\n\n", .{node_id});
        try common.appendNodeCoreMarkdown(&buf, node, alloc);
        try common.appendFilteredEdgeNodeSection(&buf, "Verifies Source Files", edges_in, "VERIFIED_BY_CODE", "SourceFile", alloc);
        try common.appendFilteredEdgeNodeSection(&buf, "Verifies Requirements", edges_in, "VERIFIED_BY_CODE", "Requirement", alloc);
        try common.appendEdgeSection(&buf, "Outgoing Links", edges_out, alloc);
        try common.appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "VERIFIED_BY_CODE", "SourceFile", alloc);
    } else {
        return error.NotFound;
    }

    return alloc.dupe(u8, buf.items);
}
