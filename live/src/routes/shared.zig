const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const chain_mod = @import("../chain.zig");

pub const JsonRouteResponse = struct {
    status: std.http.Status = .ok,
    body: []const u8,
    ok: bool = true,
};

pub fn jsonRouteResponse(status: std.http.Status, body: []const u8, ok: bool) JsonRouteResponse {
    return .{ .status = status, .body = body, .ok = ok };
}

pub fn freeNode(n: graph_live.Node, alloc: Allocator) void {
    alloc.free(n.id);
    alloc.free(n.type);
    alloc.free(n.properties);
    if (n.suspect_reason) |r| alloc.free(r);
}

pub fn freeNodeList(nodes: *std.ArrayList(graph_live.Node), alloc: Allocator) void {
    for (nodes.items) |n| freeNode(n, alloc);
    nodes.deinit(alloc);
}

pub fn freeGapSlice(gaps: []const chain_mod.Gap, alloc: Allocator) void {
    for (gaps) |gap| {
        alloc.free(gap.title);
        alloc.free(gap.gap_type);
        alloc.free(gap.node_id);
        alloc.free(gap.message);
    }
    alloc.free(gaps);
}

pub fn freeGapList(gaps: *std.ArrayList(chain_mod.Gap), alloc: Allocator) void {
    for (gaps.items) |gap| {
        alloc.free(gap.title);
        alloc.free(gap.gap_type);
        alloc.free(gap.node_id);
        alloc.free(gap.message);
    }
    gaps.deinit(alloc);
}

pub fn freeEdge(e: graph_live.Edge, alloc: Allocator) void {
    alloc.free(e.id);
    alloc.free(e.from_id);
    alloc.free(e.to_id);
    alloc.free(e.label);
    if (e.properties) |p| alloc.free(p);
}

pub fn freeRuntimeDiagnostic(d: graph_live.RuntimeDiagnostic, alloc: Allocator) void {
    alloc.free(d.dedupe_key);
    alloc.free(d.severity);
    alloc.free(d.title);
    alloc.free(d.message);
    alloc.free(d.source);
    if (d.subject) |s| alloc.free(s);
    alloc.free(d.details_json);
}

pub fn freeRtmRow(r: graph_live.RtmRow, alloc: Allocator) void {
    alloc.free(r.req_id);
    if (r.statement) |v| alloc.free(v);
    if (r.status) |v| alloc.free(v);
    if (r.user_need_id) |v| alloc.free(v);
    if (r.user_need_statement) |v| alloc.free(v);
    if (r.test_group_id) |v| alloc.free(v);
    if (r.test_id) |v| alloc.free(v);
    if (r.test_type) |v| alloc.free(v);
    if (r.test_method) |v| alloc.free(v);
    if (r.result) |v| alloc.free(v);
    if (r.req_suspect_reason) |v| alloc.free(v);
}

pub fn jsonNodeArray(nodes: []const graph_live.Node, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (nodes, 0..) |n, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"id\":");
        try appendJsonStr(&buf, n.id, alloc);
        try buf.appendSlice(alloc, ",\"type\":");
        try appendJsonStr(&buf, n.type, alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, n.properties);
        try buf.appendSlice(alloc, ",\"suspect\":");
        try buf.appendSlice(alloc, if (n.suspect) "true" else "false");
        if (n.suspect_reason) |r| {
            try buf.appendSlice(alloc, ",\"suspect_reason\":");
            try appendJsonStr(&buf, r, alloc);
        }
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

pub fn appendNodeObject(buf: *std.ArrayList(u8), n: graph_live.Node, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"id\":");
    try appendJsonStr(buf, n.id, alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try appendJsonStr(buf, n.type, alloc);
    try buf.appendSlice(alloc, ",\"properties\":");
    try buf.appendSlice(alloc, n.properties);
    try buf.appendSlice(alloc, ",\"suspect\":");
    try buf.appendSlice(alloc, if (n.suspect) "true" else "false");
    if (n.suspect_reason) |r| {
        try buf.appendSlice(alloc, ",\"suspect_reason\":");
        try appendJsonStr(buf, r, alloc);
    }
    try buf.append(alloc, '}');
}

pub fn appendNodeObjectOpt(buf: *std.ArrayList(u8), n: ?graph_live.Node, alloc: Allocator) !void {
    if (n) |node| {
        try appendNodeObject(buf, node, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

pub fn addUniqueNode(result: *std.ArrayList(graph_live.Node), node: graph_live.Node, alloc: Allocator) !void {
    for (result.items) |existing| {
        if (std.mem.eql(u8, existing.id, node.id)) {
            freeNode(node, alloc);
            return;
        }
    }
    try result.append(alloc, node);
}

pub fn collectNodesViaOutgoingEdge(
    db: *graph_live.GraphDb,
    from_id: []const u8,
    edge_label: []const u8,
    node_type: []const u8,
    alloc: Allocator,
    result: *std.ArrayList(graph_live.Node),
) !void {
    var st = try db.db.prepare(
        \\SELECT n.id, n.type, n.properties, n.suspect, n.suspect_reason
        \\FROM nodes n JOIN edges e ON e.to_id=n.id
        \\WHERE e.from_id=? AND e.label=? AND n.type=?
        \\ORDER BY n.id
    );
    defer st.finalize();
    try st.bindText(1, from_id);
    try st.bindText(2, edge_label);
    try st.bindText(3, node_type);
    while (try st.step()) {
        const node_id = st.columnText(0);
        if (try db.getNode(node_id, alloc)) |node| {
            try addUniqueNode(result, node, alloc);
        }
    }
}

pub fn collectNodesViaIncomingEdge(
    db: *graph_live.GraphDb,
    to_id: []const u8,
    edge_label: []const u8,
    node_type: []const u8,
    alloc: Allocator,
    result: *std.ArrayList(graph_live.Node),
) !void {
    var st = try db.db.prepare(
        \\SELECT n.id, n.type, n.properties, n.suspect, n.suspect_reason
        \\FROM nodes n JOIN edges e ON e.from_id=n.id
        \\WHERE e.to_id=? AND e.label=? AND n.type=?
        \\ORDER BY n.id
    );
    defer st.finalize();
    try st.bindText(1, to_id);
    try st.bindText(2, edge_label);
    try st.bindText(3, node_type);
    while (try st.step()) {
        const node_id = st.columnText(0);
        if (try db.getNode(node_id, alloc)) |node| {
            try addUniqueNode(result, node, alloc);
        }
    }
}

pub fn relatedIdsPut(set: *std.StringHashMap(void), id: []const u8, alloc: Allocator) !void {
    if (set.contains(id)) return;
    try set.put(try alloc.dupe(u8, id), {});
}

pub fn addNodeIdsToSet(nodes: []const graph_live.Node, set: *std.StringHashMap(void), alloc: Allocator) !void {
    for (nodes) |node| try relatedIdsPut(set, node.id, alloc);
}

pub fn appendMatchingGaps(
    source_gaps: []const chain_mod.Gap,
    related_ids: *const std.StringHashMap(void),
    alloc: Allocator,
    dest: *std.ArrayList(chain_mod.Gap),
) !void {
    for (source_gaps) |gap| {
        if (!related_ids.contains(gap.node_id)) continue;
        try dest.append(alloc, .{
            .code = gap.code,
            .title = try alloc.dupe(u8, gap.title),
            .gap_type = try alloc.dupe(u8, gap.gap_type),
            .node_id = try alloc.dupe(u8, gap.node_id),
            .severity = gap.severity,
            .message = try alloc.dupe(u8, gap.message),
        });
    }
}

pub fn jsonStringArray(items: []const []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try buf.append(alloc, ',');
        try appendJsonStr(&buf, s, alloc);
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

pub const InlineDiagnostic = struct {
    code: u16,
    severity: []const u8,
    title: []const u8,
    message: []const u8,
    source: []const u8,
    subject: ?[]const u8,
    details_json: []const u8,
};

pub fn runtimeDiagnosticsJson(items: []const graph_live.RuntimeDiagnostic, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"diagnostics\":[");
    for (items, 0..) |d, i| {
        if (i > 0) try buf.append(alloc, ',');
        try appendRuntimeDiagnosticObject(&buf, .{
            .code = d.code,
            .severity = d.severity,
            .title = d.title,
            .message = d.message,
            .source = d.source,
            .subject = d.subject,
            .details_json = d.details_json,
        }, alloc);
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn errorResponseWithDiagnostics(msg: []const u8, diagnostics: []const InlineDiagnostic, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":false,\"error\":");
    try appendJsonStr(&buf, msg, alloc);
    try buf.appendSlice(alloc, ",\"diagnostics\":[");
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try buf.append(alloc, ',');
        try appendRuntimeDiagnosticObject(&buf, d, alloc);
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn appendRuntimeDiagnosticObject(buf: *std.ArrayList(u8), d: anytype, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"code\":");
    try std.fmt.format(buf.writer(alloc), "{d}", .{d.code});
    try buf.appendSlice(alloc, ",\"severity\":");
    try appendJsonStr(buf, d.severity, alloc);
    try buf.appendSlice(alloc, ",\"title\":");
    try appendJsonStr(buf, d.title, alloc);
    try buf.appendSlice(alloc, ",\"message\":");
    try appendJsonStr(buf, d.message, alloc);
    try buf.appendSlice(alloc, ",\"source\":");
    try appendJsonStr(buf, d.source, alloc);
    try buf.appendSlice(alloc, ",\"subject\":");
    try appendJsonStrOpt(buf, d.subject, alloc);
    try buf.appendSlice(alloc, ",\"details\":");
    try buf.appendSlice(alloc, d.details_json);
    try buf.append(alloc, '}');
}

pub const EdgeDir = enum { out, in };

pub fn appendEdgeArrayWithNode(buf: *std.ArrayList(u8), db: *graph_live.GraphDb, edges: []const graph_live.Edge, dir: EdgeDir, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    for (edges, 0..) |e, i| {
        if (i > 0) try buf.append(alloc, ',');
        const other_id = switch (dir) {
            .out => e.to_id,
            .in => e.from_id,
        };
        const other_node = try db.getNode(other_id, alloc);
        if (other_node == null) continue;
        defer freeNode(other_node.?, alloc);

        try buf.appendSlice(alloc, "{\"node\":{\"id\":");
        try appendJsonStr(buf, other_node.?.id, alloc);
        try buf.appendSlice(alloc, ",\"type\":");
        try appendJsonStr(buf, other_node.?.type, alloc);
        try buf.append(alloc, '}');
        try buf.appendSlice(alloc, ",\"from_id\":");
        try appendJsonStr(buf, e.from_id, alloc);
        try buf.appendSlice(alloc, ",\"to_id\":");
        try appendJsonStr(buf, e.to_id, alloc);
        try buf.appendSlice(alloc, ",\"label\":");
        try appendJsonStr(buf, e.label, alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        if (e.properties) |properties| {
            try buf.appendSlice(alloc, properties);
        } else {
            try buf.appendSlice(alloc, "null");
        }
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
}

pub fn appendJsonStr(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
    try buf.append(alloc, '"');
}

pub fn appendJsonStrOpt(buf: *std.ArrayList(u8), s: ?[]const u8, alloc: Allocator) !void {
    if (s) |v| {
        try appendJsonStr(buf, v, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

pub fn appendJsonIntOpt(buf: *std.ArrayList(u8), value: ?i64, alloc: Allocator) !void {
    if (value) |v| {
        try std.fmt.format(buf.writer(alloc), "{d}", .{v});
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

pub fn makeInlineDiagnostic(code: u16, severity: []const u8, title: []const u8, message: []const u8, source: []const u8, subject: ?[]const u8, details_json: []const u8) InlineDiagnostic {
    return .{
        .code = code,
        .severity = severity,
        .title = title,
        .message = message,
        .source = source,
        .subject = subject,
        .details_json = details_json,
    };
}

pub fn sourceFilterValue(filter: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, filter, "repo")) return "repo_validation";
    if (std.mem.eql(u8, filter, "git")) return "git";
    if (std.mem.eql(u8, filter, "annotation")) return "annotation";
    if (std.mem.eql(u8, filter, "profile")) return "profile";
    if (std.mem.eql(u8, filter, "repo_scan")) return "repo_scan";
    return null;
}

pub fn countNodesForRepo(db: *graph_live.GraphDb, node_type: []const u8, repo_path: []const u8) !i64 {
    var st = try db.db.prepare(
        \\SELECT COUNT(*) FROM nodes
        \\WHERE type=? AND json_extract(properties,'$.repo')=?
        \\  AND COALESCE(json_extract(properties,'$.present'), 1) != 0
    );
    defer st.finalize();
    try st.bindText(1, node_type);
    try st.bindText(2, repo_path);
    _ = try st.step();
    return st.columnInt(0);
}

pub fn countAnnotationsForRepo(db: *graph_live.GraphDb, repo_path: []const u8) !i64 {
    var st = try db.db.prepare(
        \\SELECT COUNT(DISTINCT ann.id)
        \\FROM nodes ann
        \\JOIN edges e ON e.to_id = ann.id AND e.label='CONTAINS'
        \\JOIN nodes file ON file.id = e.from_id
        \\WHERE ann.type='CodeAnnotation' AND json_extract(file.properties,'$.repo')=?
    );
    defer st.finalize();
    try st.bindText(1, repo_path);
    _ = try st.step();
    return st.columnInt(0);
}

pub fn countAnnotationsForFile(db: *graph_live.GraphDb, file_path: []const u8) !i64 {
    var st = try db.db.prepare(
        \\SELECT COUNT(*)
        \\FROM nodes
        \\WHERE type='CodeAnnotation' AND json_extract(properties,'$.file_path')=?
    );
    defer st.finalize();
    try st.bindText(1, file_path);
    _ = try st.step();
    return st.columnInt(0);
}

pub fn countCommitsForRepo(db: *graph_live.GraphDb, repo_path: []const u8) !i64 {
    var st = try db.db.prepare(
        \\SELECT COUNT(DISTINCT c.id)
        \\FROM nodes c
        \\JOIN edges ec ON ec.to_id = c.id AND ec.label='CHANGED_IN'
        \\JOIN nodes f ON f.id = ec.from_id
        \\WHERE c.type='Commit'
        \\  AND json_extract(f.properties,'$.repo')=?
    );
    defer st.finalize();
    try st.bindText(1, repo_path);
    _ = try st.step();
    return st.columnInt(0);
}
