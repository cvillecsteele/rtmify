/// routes.zig — HTTP route handlers for rtmify-live.
///
/// Each handler takes a GraphDb + alloc, returns an allocated JSON string.
/// Report handlers use adapter.zig to build an ephemeral in-memory Graph.
const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const render_md = rtmify.render_md;
const render_docx = rtmify.render_docx;
const render_pdf = rtmify.render_pdf;

const graph_live = @import("graph_live.zig");
const sync_live = @import("sync_live.zig");
const adapter = @import("adapter.zig");
const sheets_mod = @import("sheets.zig");

pub const index_html = @embedFile("static/index.html");

// ---------------------------------------------------------------------------
// GET /nodes
// ---------------------------------------------------------------------------

pub fn handleNodes(db: *graph_live.GraphDb, type_filter: ?[]const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }
    if (type_filter) |t| {
        try db.nodesByType(t, alloc, &nodes);
    } else {
        try db.allNodes(alloc, &nodes);
    }
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /nodes/types
// ---------------------------------------------------------------------------

pub fn handleNodeTypes(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var types: std.ArrayList([]const u8) = .empty;
    defer {
        for (types.items) |t| alloc.free(t);
        types.deinit(alloc);
    }
    try db.allNodeTypes(alloc, &types);
    return jsonStringArray(types.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /edges/labels
// ---------------------------------------------------------------------------

pub fn handleEdgeLabels(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (labels.items) |l| alloc.free(l);
        labels.deinit(alloc);
    }
    try db.allEdgeLabels(alloc, &labels);
    return jsonStringArray(labels.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /search?q=...
// ---------------------------------------------------------------------------

pub fn handleSearch(db: *graph_live.GraphDb, q: []const u8, alloc: Allocator) ![]const u8 {
    var results: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (results.items) |n| freeNode(n, alloc);
        results.deinit(alloc);
    }
    try db.search(q, alloc, &results);
    return jsonNodeArray(results.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /schema
// ---------------------------------------------------------------------------

pub fn handleSchema(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var types: std.ArrayList([]const u8) = .empty;
    defer {
        for (types.items) |t| alloc.free(t);
        types.deinit(alloc);
    }
    var labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (labels.items) |l| alloc.free(l);
        labels.deinit(alloc);
    }
    try db.allNodeTypes(alloc, &types);
    try db.allEdgeLabels(alloc, &labels);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"node_types\":");
    try buf.appendSlice(alloc, try jsonStringArray(types.items, alloc));
    try buf.appendSlice(alloc, ",\"edge_labels\":");
    try buf.appendSlice(alloc, try jsonStringArray(labels.items, alloc));
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /query/gaps
// ---------------------------------------------------------------------------

pub fn handleGaps(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    // Requirements with no TESTED_BY edge
    var reqs: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (reqs.items) |n| freeNode(n, alloc);
        reqs.deinit(alloc);
    }
    try db.nodesMissingEdge("Requirement", "TESTED_BY", alloc, &reqs);
    return jsonNodeArray(reqs.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/rtm
// ---------------------------------------------------------------------------

pub fn handleRtm(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var rows: std.ArrayList(graph_live.RtmRow) = .empty;
    defer {
        for (rows.items) |r| freeRtmRow(r, alloc);
        rows.deinit(alloc);
    }
    try db.rtm(alloc, &rows);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (rows.items, 0..) |row, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"req_id\":");
        try appendJsonStr(&buf, row.req_id, alloc);
        try buf.appendSlice(alloc, ",\"statement\":");
        try appendJsonStrOpt(&buf, row.statement, alloc);
        try buf.appendSlice(alloc, ",\"status\":");
        try appendJsonStrOpt(&buf, row.status, alloc);
        try buf.appendSlice(alloc, ",\"user_need_id\":");
        try appendJsonStrOpt(&buf, row.user_need_id, alloc);
        try buf.appendSlice(alloc, ",\"test_group_id\":");
        try appendJsonStrOpt(&buf, row.test_group_id, alloc);
        try buf.appendSlice(alloc, ",\"test_id\":");
        try appendJsonStrOpt(&buf, row.test_id, alloc);
        try buf.appendSlice(alloc, ",\"test_type\":");
        try appendJsonStrOpt(&buf, row.test_type, alloc);
        try buf.appendSlice(alloc, ",\"test_method\":");
        try appendJsonStrOpt(&buf, row.test_method, alloc);
        try buf.appendSlice(alloc, ",\"result\":");
        try appendJsonStrOpt(&buf, row.result, alloc);
        try buf.appendSlice(alloc, ",\"suspect\":");
        try buf.appendSlice(alloc, if (row.req_suspect) "true" else "false");
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /query/impact/:node_id
// ---------------------------------------------------------------------------

pub fn handleImpact(db: *graph_live.GraphDb, node_id: []const u8, alloc: Allocator) ![]const u8 {
    var impacts: std.ArrayList(graph_live.ImpactNode) = .empty;
    defer {
        for (impacts.items) |imp| {
            alloc.free(imp.id);
            alloc.free(imp.type);
            alloc.free(imp.properties);
            alloc.free(imp.via);
            alloc.free(imp.dir);
        }
        impacts.deinit(alloc);
    }
    try db.impact(node_id, alloc, &impacts);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (impacts.items, 0..) |imp, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"id\":");
        try appendJsonStr(&buf, imp.id, alloc);
        try buf.appendSlice(alloc, ",\"type\":");
        try appendJsonStr(&buf, imp.type, alloc);
        try buf.appendSlice(alloc, ",\"via\":");
        try appendJsonStr(&buf, imp.via, alloc);
        try buf.appendSlice(alloc, ",\"dir\":");
        try appendJsonStr(&buf, imp.dir, alloc);
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /query/suspects
// ---------------------------------------------------------------------------

pub fn handleSuspects(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }
    try db.suspects(alloc, &nodes);
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/user-needs
// ---------------------------------------------------------------------------

pub fn handleUserNeeds(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }
    try db.nodesByType("UserNeed", alloc, &nodes);
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/tests
// ---------------------------------------------------------------------------

pub fn handleTests(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var rows: std.ArrayList(graph_live.TestRow) = .empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.test_group_id);
            if (r.test_id) |v| alloc.free(v);
            if (r.test_type) |v| alloc.free(v);
            if (r.test_method) |v| alloc.free(v);
            if (r.req_id) |v| alloc.free(v);
            if (r.req_statement) |v| alloc.free(v);
            if (r.test_suspect_reason) |v| alloc.free(v);
        }
        rows.deinit(alloc);
    }
    try db.tests(alloc, &rows);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (rows.items, 0..) |row, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"test_group_id\":");
        try appendJsonStr(&buf, row.test_group_id, alloc);
        try buf.appendSlice(alloc, ",\"test_id\":");
        try appendJsonStrOpt(&buf, row.test_id, alloc);
        try buf.appendSlice(alloc, ",\"test_type\":");
        try appendJsonStrOpt(&buf, row.test_type, alloc);
        try buf.appendSlice(alloc, ",\"test_method\":");
        try appendJsonStrOpt(&buf, row.test_method, alloc);
        try buf.appendSlice(alloc, ",\"req_id\":");
        try appendJsonStrOpt(&buf, row.req_id, alloc);
        try buf.appendSlice(alloc, ",\"suspect\":");
        try buf.appendSlice(alloc, if (row.test_suspect) "true" else "false");
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /query/risks
// ---------------------------------------------------------------------------

pub fn handleRisks(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var rows: std.ArrayList(graph_live.RiskRow) = .empty;
    defer {
        for (rows.items) |r| {
            alloc.free(r.risk_id);
            if (r.description) |v| alloc.free(v);
            if (r.initial_severity) |v| alloc.free(v);
            if (r.initial_likelihood) |v| alloc.free(v);
            if (r.mitigation) |v| alloc.free(v);
            if (r.residual_severity) |v| alloc.free(v);
            if (r.residual_likelihood) |v| alloc.free(v);
            if (r.req_id) |v| alloc.free(v);
            if (r.req_statement) |v| alloc.free(v);
        }
        rows.deinit(alloc);
    }
    try db.risks(alloc, &rows);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (rows.items, 0..) |row, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"risk_id\":");
        try appendJsonStr(&buf, row.risk_id, alloc);
        try buf.appendSlice(alloc, ",\"description\":");
        try appendJsonStrOpt(&buf, row.description, alloc);
        try buf.appendSlice(alloc, ",\"severity\":");
        try appendJsonStrOpt(&buf, row.initial_severity, alloc);
        try buf.appendSlice(alloc, ",\"mitigation\":");
        try appendJsonStrOpt(&buf, row.mitigation, alloc);
        try buf.appendSlice(alloc, ",\"req_id\":");
        try appendJsonStrOpt(&buf, row.req_id, alloc);
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /query/node/:node_id
// ---------------------------------------------------------------------------

pub fn handleNode(db: *graph_live.GraphDb, node_id: []const u8, alloc: Allocator) ![]const u8 {
    const node = try db.getNode(node_id, alloc);
    if (node == null) return alloc.dupe(u8, "null");
    defer freeNode(node.?, alloc);

    var edges_from: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges_from.items) |e| freeEdge(e, alloc);
        edges_from.deinit(alloc);
    }
    var edges_to: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges_to.items) |e| freeEdge(e, alloc);
        edges_to.deinit(alloc);
    }
    try db.edgesFrom(node_id, alloc, &edges_from);
    try db.edgesTo(node_id, alloc, &edges_to);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const n = node.?;
    try buf.appendSlice(alloc, "{\"id\":");
    try appendJsonStr(&buf, n.id, alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try appendJsonStr(&buf, n.type, alloc);
    try buf.appendSlice(alloc, ",\"properties\":");
    try buf.appendSlice(alloc, n.properties); // already JSON
    try buf.appendSlice(alloc, ",\"suspect\":");
    try buf.appendSlice(alloc, if (n.suspect) "true" else "false");
    try buf.appendSlice(alloc, ",\"suspect_reason\":");
    try appendJsonStrOpt(&buf, n.suspect_reason, alloc);
    try buf.appendSlice(alloc, ",\"edges_from\":");
    try appendEdgeArray(&buf, edges_from.items, alloc);
    try buf.appendSlice(alloc, ",\"edges_to\":");
    try appendEdgeArray(&buf, edges_to.items, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /api/status
// ---------------------------------------------------------------------------

pub fn handleStatus(db: *graph_live.GraphDb, state: *sync_live.SyncState, alloc: Allocator) ![]const u8 {
    const last_sync = state.last_sync_at.load(.seq_cst);
    const has_error = state.has_error.load(.seq_cst);
    const sync_count = state.sync_count.load(.seq_cst);
    const license_valid = state.license_valid.load(.seq_cst);

    var err_buf: [256]u8 = undefined;
    const err_len = state.getError(&err_buf);
    const err_str = err_buf[0..err_len];

    // Extract client_email from latest stored credential
    var email_owned: ?[]u8 = null;
    defer if (email_owned) |e| alloc.free(e);
    if (try db.getLatestCredential(alloc)) |cred| {
        defer alloc.free(cred);
        if (sheets_mod.extractJsonFieldStatic(cred, "client_email")) |e| {
            email_owned = try alloc.dupe(u8, e);
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "{{\"last_sync_at\":{d},\"has_error\":{s},\"error\":", .{
        last_sync, if (has_error) "true" else "false",
    });
    try appendJsonStr(&buf, err_str, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"sync_count\":{d},\"license_valid\":{s},\"email\":", .{
        sync_count, if (license_valid) "true" else "false",
    });
    try appendJsonStrOpt(&buf, email_owned, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// POST /api/service-account
// ---------------------------------------------------------------------------

pub fn handleServiceAccount(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) ![]const u8 {
    try db.storeCredential(body);
    return alloc.dupe(u8, "{\"ok\":true}");
}

// ---------------------------------------------------------------------------
// POST /api/config
// ---------------------------------------------------------------------------

pub fn handleConfig(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) ![]const u8 {
    // Expect {"key":"...","value":"..."} or {"sheet_id":"..."} etc.
    // Extract sheet_id if present
    if (extractJsonField(body, "sheet_id")) |v| {
        try db.storeConfig("sheet_id", v);
    }
    if (extractJsonField(body, "sheet_url")) |v| {
        // Extract ID from URL
        const id = extractSheetId(v) orelse v;
        try db.storeConfig("sheet_id", id);
    }
    return alloc.dupe(u8, "{\"ok\":true}");
}

// ---------------------------------------------------------------------------
// POST /suspect/:node_id/clear
// ---------------------------------------------------------------------------

pub fn handleClearSuspect(db: *graph_live.GraphDb, node_id: []const u8, alloc: Allocator) ![]const u8 {
    try db.clearSuspect(node_id);
    return alloc.dupe(u8, "{\"ok\":true}");
}

// ---------------------------------------------------------------------------
// POST /ingest
// ---------------------------------------------------------------------------

pub fn handleIngest(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return alloc.dupe(u8, "{\"ok\":false,\"error\":\"expected object\"}");

    const type_val = root.object.get("type") orelse
        return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing type\"}");
    if (type_val != .string) return alloc.dupe(u8, "{\"ok\":false,\"error\":\"type must be string\"}");

    if (std.mem.eql(u8, type_val.string, "node")) {
        const id_val = root.object.get("id") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing id\"}");
        const nt_val = root.object.get("node_type") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing node_type\"}");
        if (id_val != .string or nt_val != .string)
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"id and node_type must be strings\"}");

        // Serialize properties to JSON
        var props_buf: std.ArrayList(u8) = .empty;
        defer props_buf.deinit(alloc);
        if (root.object.get("properties")) |props| {
            const props_json_str = try std.json.Stringify.valueAlloc(alloc, props, .{});
            defer alloc.free(props_json_str);
            try props_buf.appendSlice(alloc, props_json_str);
        } else {
            try props_buf.appendSlice(alloc, "{}");
        }

        // Compute SHA-256 of serialized properties
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(props_buf.items);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hash_hex = std.fmt.bytesToHex(digest, .lower);

        try db.upsertNode(id_val.string, nt_val.string, props_buf.items, &hash_hex);
        return alloc.dupe(u8, "{\"ok\":true}");
    } else if (std.mem.eql(u8, type_val.string, "edge")) {
        const from_val = root.object.get("from") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing from\"}");
        const to_val = root.object.get("to") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing to\"}");
        const label_val = root.object.get("label") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing label\"}");
        if (from_val != .string or to_val != .string or label_val != .string)
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"from, to, label must be strings\"}");

        db.addEdge(from_val.string, to_val.string, label_val.string) catch |e| {
            if (e != error.Exec) return e;
        };
        return alloc.dupe(u8, "{\"ok\":true}");
    } else {
        return alloc.dupe(u8, "{\"ok\":false,\"error\":\"type must be node or edge\"}");
    }
}

// ---------------------------------------------------------------------------
// GET /report/rtm (PDF)
// ---------------------------------------------------------------------------

pub fn handleReportRtmPdf(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_pdf.renderPdf(&g, "live.db", "live", buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /report/rtm.md
// ---------------------------------------------------------------------------

pub fn handleReportRtmMd(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_md.renderMd(&g, "live.db", "live", buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /report/rtm.docx
// ---------------------------------------------------------------------------

pub fn handleReportRtmDocx(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_docx.renderDocx(&g, "live.db", "live", buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// Memory helpers
// ---------------------------------------------------------------------------

fn freeNode(n: graph_live.Node, alloc: Allocator) void {
    alloc.free(n.id);
    alloc.free(n.type);
    alloc.free(n.properties);
    if (n.suspect_reason) |r| alloc.free(r);
}

fn freeEdge(e: graph_live.Edge, alloc: Allocator) void {
    alloc.free(e.id);
    alloc.free(e.from_id);
    alloc.free(e.to_id);
    alloc.free(e.label);
}

fn freeRtmRow(r: graph_live.RtmRow, alloc: Allocator) void {
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

// ---------------------------------------------------------------------------
// JSON serialization helpers
// ---------------------------------------------------------------------------

fn jsonNodeArray(nodes: []const graph_live.Node, alloc: Allocator) ![]const u8 {
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

fn jsonStringArray(items: []const []const u8, alloc: Allocator) ![]const u8 {
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

fn appendEdgeArray(buf: *std.ArrayList(u8), edges: []const graph_live.Edge, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    for (edges, 0..) |e, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"from_id\":");
        try appendJsonStr(buf, e.from_id, alloc);
        try buf.appendSlice(alloc, ",\"to_id\":");
        try appendJsonStr(buf, e.to_id, alloc);
        try buf.appendSlice(alloc, ",\"label\":");
        try appendJsonStr(buf, e.label, alloc);
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
}

fn appendJsonStr(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
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

fn appendJsonStrOpt(buf: *std.ArrayList(u8), s: ?[]const u8, alloc: Allocator) !void {
    if (s) |v| {
        try appendJsonStr(buf, v, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

fn extractJsonField(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = key_pos + needle.len;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;
    const start = pos;
    while (pos < json.len and json[pos] != '"') {
        if (json[pos] == '\\') pos += 1;
        pos += 1;
    }
    return json[start..pos];
}

/// Extract Google Sheet ID from a URL like .../spreadsheets/d/ID/edit
fn extractSheetId(url: []const u8) ?[]const u8 {
    const marker = "/spreadsheets/d/";
    const idx = std.mem.indexOf(u8, url, marker) orelse return null;
    const start = idx + marker.len;
    const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
    if (end <= start) return null;
    return url[start..end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extractJsonFieldStatic extracts client_email from credential" {
    const cred = "{\"type\":\"service_account\",\"client_email\":\"svc@proj.iam.gserviceaccount.com\",\"private_key\":\"...\"}";
    const email = sheets_mod.extractJsonFieldStatic(cred, "client_email");
    try testing.expect(email != null);
    try testing.expectEqualStrings("svc@proj.iam.gserviceaccount.com", email.?);
}

test "extractJsonFieldStatic returns null when key absent" {
    const cred = "{\"type\":\"service_account\"}";
    try testing.expect(sheets_mod.extractJsonFieldStatic(cred, "client_email") == null);
}

test "handleIngest node payload inserts node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const body = "{\"type\":\"node\",\"id\":\"REQ-001\",\"node_type\":\"Requirement\",\"properties\":{\"text\":\"shall do X\"}}";
    const resp = try handleIngest(&db, body, alloc);
    try testing.expectEqualStrings("{\"ok\":true}", resp);

    const node = try db.getNode("REQ-001", alloc);
    try testing.expect(node != null);
    try testing.expectEqualStrings("Requirement", node.?.type);
}

test "handleIngest edge payload inserts edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    // Insert prerequisite nodes so the edge has valid endpoints
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TEST-001", "TestGroup", "{}", null);

    const body = "{\"type\":\"edge\",\"from\":\"REQ-001\",\"to\":\"TEST-001\",\"label\":\"TESTED_BY\"}";
    const resp = try handleIngest(&db, body, alloc);
    try testing.expectEqualStrings("{\"ok\":true}", resp);

    var edges: std.ArrayList(graph_live.Edge) = .empty;
    try db.edgesFrom("REQ-001", alloc, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("TESTED_BY", edges.items[0].label);
}

test "handleIngest malformed JSON returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handleIngest(&db, "not json{{{", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}
