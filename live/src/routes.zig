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
const profile_mod = @import("profile.zig");
const chain_mod = @import("chain.zig");
const provision_mod = @import("provision.zig");
const connection_mod = @import("connection.zig");
const online_provider = @import("online_provider.zig");
const json_util = @import("json_util.zig");

pub const index_html = @embedFile("static/index.html");

pub const JsonRouteResponse = struct {
    status: std.http.Status = .ok,
    body: []const u8,
    ok: bool = true,
};

fn jsonRouteResponse(status: std.http.Status, body: []const u8, ok: bool) JsonRouteResponse {
    return .{ .status = status, .body = body, .ok = ok };
}

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
    const node = try db.getNode(node_id, alloc);
    if (node == null) return error.NotFound;
    defer freeNode(node.?, alloc);

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
        try buf.appendSlice(alloc, ",\"initial_severity\":");
        try appendJsonStrOpt(&buf, row.initial_severity, alloc);
        try buf.appendSlice(alloc, ",\"initial_likelihood\":");
        try appendJsonStrOpt(&buf, row.initial_likelihood, alloc);
        try buf.appendSlice(alloc, ",\"mitigation\":");
        try appendJsonStrOpt(&buf, row.mitigation, alloc);
        try buf.appendSlice(alloc, ",\"req_id\":");
        try appendJsonStrOpt(&buf, row.req_id, alloc);
        try buf.appendSlice(alloc, ",\"residual_severity\":");
        try appendJsonStrOpt(&buf, row.residual_severity, alloc);
        try buf.appendSlice(alloc, ",\"residual_likelihood\":");
        try appendJsonStrOpt(&buf, row.residual_likelihood, alloc);
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
    if (node == null) return error.NotFound;
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
    try buf.appendSlice(alloc, "{\"node\":{\"id\":");
    try appendJsonStr(&buf, n.id, alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try appendJsonStr(&buf, n.type, alloc);
    try buf.appendSlice(alloc, ",\"properties\":");
    try buf.appendSlice(alloc, n.properties); // already JSON
    try buf.appendSlice(alloc, ",\"suspect\":");
    try buf.appendSlice(alloc, if (n.suspect) "true" else "false");
    try buf.appendSlice(alloc, ",\"suspect_reason\":");
    try appendJsonStrOpt(&buf, n.suspect_reason, alloc);
    try buf.appendSlice(alloc, "},\"edges_out\":");
    try appendEdgeArrayWithNode(&buf, db, edges_from.items, .out, alloc);
    try buf.appendSlice(alloc, ",\"edges_in\":");
    try appendEdgeArrayWithNode(&buf, db, edges_to.items, .in, alloc);
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
    const loaded_active = try connection_mod.loadActive(db, alloc);
    var active = loaded_active;
    defer if (active) |*a| a.deinit(alloc);
    const configured = active != null;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "{{\"configured\":{s},\"last_sync_at\":{d},\"has_error\":{s},\"error\":", .{
        if (configured) "true" else "false", last_sync, if (has_error) "true" else "false",
    });
    try appendJsonStr(&buf, err_str, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"sync_count\":{d},\"license_valid\":{s},\"platform\":", .{
        sync_count, if (license_valid) "true" else "false",
    });
    try appendJsonStrOpt(&buf, if (active) |a| online_provider.providerIdString(a.platform) else null, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try appendJsonStrOpt(&buf, if (active) |a| a.credential_display else null, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try appendJsonStrOpt(&buf, if (active) |a| a.workbook_label else null, alloc);
    try buf.appendSlice(alloc, ",\"workbook_url\":");
    try appendJsonStrOpt(&buf, if (active) |a| a.workbook_url else null, alloc);
    const last_scan = (try db.getConfig("last_scan_at", alloc)) orelse try alloc.dupe(u8, "never");
    defer alloc.free(last_scan);
    try buf.appendSlice(alloc, ",\"last_scan_at\":");
    try appendJsonStr(&buf, last_scan, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// POST /api/connection/validate
// ---------------------------------------------------------------------------

pub fn handleConnectionValidate(body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handleConnectionValidateResponse(body, alloc);
    return resp.body;
}

pub fn handleConnectionValidateResponse(body: []const u8, alloc: Allocator) !JsonRouteResponse {
    var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
        std.log.warn("connection validate parse failed: {s}", .{@errorName(e)});
        return jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
    };
    defer draft.deinit(alloc);

    var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
        std.log.warn("connection validate failed platform={s}: {s}", .{ online_provider.providerIdString(draft.platform), @errorName(e) });
        return jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to validate connection: {s}\"}}", .{@errorName(e)}), false);
    };
    defer validated.deinit(alloc);
    std.log.info("connection validate ok platform={s} workbook={s}", .{ online_provider.providerIdString(validated.platform), validated.workbook_label });

    const profile_name = draft.profile orelse "generic";
    const pid = profile_mod.fromString(profile_name) orelse .generic;
    const prof = profile_mod.get(pid);
    const preview = try getProvisionPreviewForActive(validated.toActive(), prof, alloc);
    defer alloc.free(preview);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"platform\":");
    try appendJsonStr(&buf, online_provider.providerIdString(validated.platform), alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try appendJsonStrOpt(&buf, validated.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try appendJsonStr(&buf, validated.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"preview\":");
    try buf.appendSlice(alloc, preview);
    try buf.append(alloc, '}');
    return jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

// ---------------------------------------------------------------------------
// POST /api/connection
// ---------------------------------------------------------------------------

pub fn handleConnection(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handleConnectionResponse(db, body, alloc);
    return resp.body;
}

pub fn handleConnectionResponse(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) !JsonRouteResponse {
    var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
        std.log.warn("connection parse failed: {s}", .{@errorName(e)});
        return jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
    };
    defer draft.deinit(alloc);

    var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
        std.log.warn("connection failed platform={s}: {s}", .{ online_provider.providerIdString(draft.platform), @errorName(e) });
        return jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to connect: {s}\"}}", .{@errorName(e)}), false);
    };
    defer validated.deinit(alloc);

    try connection_mod.persistActive(db, validated);
    std.log.info("connection persisted platform={s} workbook={s}", .{ online_provider.providerIdString(validated.platform), validated.workbook_label });
    try db.storeConfig("profile", draft.profile orelse "generic");
    db.deleteConfig("rtmify_provisioned") catch {};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"platform\":");
    try appendJsonStr(&buf, online_provider.providerIdString(validated.platform), alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try appendJsonStrOpt(&buf, validated.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try appendJsonStr(&buf, validated.workbook_label, alloc);
    try buf.append(alloc, '}');
    return jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

// ---------------------------------------------------------------------------
// GET /api/provision-preview
// ---------------------------------------------------------------------------

/// query_profile: optional profile name from URL ?profile= param; overrides DB value.
pub fn handleProvisionPreview(
    db: *graph_live.GraphDb,
    query_profile: ?[]const u8,
    alloc: Allocator,
) ![]const u8 {
    const prof_name = if (query_profile) |qp| qp
        else (try db.getConfig("profile", alloc)) orelse try alloc.dupe(u8, "generic");
    defer if (query_profile == null) alloc.free(prof_name);
    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);
    const loaded_active = try connection_mod.loadActive(db, alloc);
    var active = loaded_active;
    defer if (active) |*a| a.deinit(alloc);
    if (active == null) {
        return alloc.dupe(u8, "{\"ready\":false,\"reason\":\"missing_credentials_or_sheet\"}");
    }

    const preview = getProvisionPreviewForActive(active.?, prof, alloc) catch {
        return alloc.dupe(u8, "{\"ready\":false,\"reason\":\"preview_failed\"}");
    };
    return preview;
}

pub fn handleProvision(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    const resp = try handleProvisionResponse(db, alloc);
    return resp.body;
}

pub fn handleProvisionResponse(db: *graph_live.GraphDb, alloc: Allocator) !JsonRouteResponse {
    const prof_name = (try db.getConfig("profile", alloc)) orelse try alloc.dupe(u8, "generic");
    defer alloc.free(prof_name);
    const loaded_active = try connection_mod.loadActive(db, alloc);
    var active = loaded_active;
    defer if (active) |*a| a.deinit(alloc);

    if (active == null) {
        const diag = [_]InlineDiagnostic{
            makeInlineDiagnostic(1207, "info", "Industry profile not configured", "Missing credential or sheet configuration for provisioning", "profile", null, "{}"),
        };
        return jsonRouteResponse(.bad_request, try errorResponseWithDiagnostics("missing sheet or credential for provisioning", &diag, alloc), false);
    }

    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);
    var runtime = try online_provider.ProviderRuntime.init(active.?, alloc);
    defer runtime.deinit(alloc);
    const created = try provision_mod.provisionWorkbook(&runtime, prof, alloc);
    defer {
        for (created) |tab| alloc.free(tab);
        alloc.free(created);
    }

    var already_present: std.ArrayList([]const u8) = .empty;
    defer {
        for (already_present.items) |tab| alloc.free(tab);
        already_present.deinit(alloc);
    }
    for (prof.tabs) |tab| {
        var found = false;
        for (created) |c| {
            if (std.mem.eql(u8, c, tab)) {
                found = true;
                break;
            }
        }
        if (!found) try already_present.append(alloc, try alloc.dupe(u8, tab));
    }

    try db.storeConfig("rtmify_provisioned", "1");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"created\":");
    try buf.appendSlice(alloc, try jsonStringArray(created, alloc));
    try buf.appendSlice(alloc, ",\"already_present\":");
    try buf.appendSlice(alloc, try jsonStringArray(already_present.items, alloc));
    try buf.append(alloc, '}');
    return jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

// ---------------------------------------------------------------------------
// DELETE /api/repos/:slot
// ---------------------------------------------------------------------------

pub fn handleDeleteRepo(db: *graph_live.GraphDb, idx_str: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handleDeleteRepoResponse(db, idx_str, alloc);
    return resp.body;
}

pub fn handleDeleteRepoResponse(db: *graph_live.GraphDb, idx_str: []const u8, alloc: Allocator) !JsonRouteResponse {
    const key = try std.fmt.allocPrint(alloc, "repo_path_{s}", .{idx_str});
    defer alloc.free(key);
    const existing = try db.getConfig(key, alloc);
    if (existing == null) {
        return jsonRouteResponse(.not_found, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"repo not found\",\"slot\":{s}}}", .{idx_str}), false);
    }
    defer alloc.free(existing.?);
    try db.deleteConfig(key);
    return jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

// ---------------------------------------------------------------------------
// GET /report/coverage.md
// ---------------------------------------------------------------------------

pub fn handleCoverageReport(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    // Count total requirements
    var total: i64 = 0;
    {
        var st = try db.db.prepare("SELECT COUNT(*) FROM nodes WHERE type='Requirement'");
        defer st.finalize();
        if (try st.step()) total = st.columnInt(0);
    }

    // Count requirements with at least one IMPLEMENTED_IN edge
    var implemented: i64 = 0;
    {
        var st = try db.db.prepare(
            "SELECT COUNT(DISTINCT n.id) FROM nodes n JOIN edges e ON e.from_id=n.id AND e.label='IMPLEMENTED_IN' WHERE n.type='Requirement'"
        );
        defer st.finalize();
        if (try st.step()) implemented = st.columnInt(0);
    }

    // Collect SourceFile nodes with no IMPLEMENTED_IN edge pointing to them
    var orphan_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (orphan_files.items) |s| alloc.free(s);
        orphan_files.deinit(alloc);
    }
    {
        var st = try db.db.prepare(
            \\SELECT id FROM nodes WHERE type='SourceFile'
            \\AND id NOT IN (SELECT to_id FROM edges WHERE label='IMPLEMENTED_IN')
        );
        defer st.finalize();
        while (try st.step()) {
            try orphan_files.append(alloc, try alloc.dupe(u8, st.columnText(0)));
        }
    }

    const pct: i64 = if (total > 0) @divTrunc(implemented * 100, total) else 0;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.writer(alloc).print(
        "# Code Coverage Report\n\n| Metric | Count |\n|--------|-------|\n| Total Requirements | {d} |\n| Implemented | {d} ({d}%) |\n| Orphan Source Files | {d} |\n",
        .{ total, implemented, pct, orphan_files.items.len },
    );
    if (orphan_files.items.len > 0) {
        try buf.appendSlice(alloc, "\n## Orphan Source Files\n\n");
        for (orphan_files.items) |path| {
            try buf.writer(alloc).print("- `{s}`\n", .{path});
        }
    }
    return alloc.dupe(u8, buf.items);
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
// GET /api/profile
// ---------------------------------------------------------------------------

pub fn handleGetProfile(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    const prof_name = (try db.getConfig("profile", alloc)) orelse try alloc.dupe(u8, "generic");
    defer alloc.free(prof_name);
    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);
    return std.fmt.allocPrint(alloc, "{{\"profile\":\"{s}\",\"name\":\"{s}\"}}", .{ prof_name, prof.name });
}

// ---------------------------------------------------------------------------
// POST /api/profile
// ---------------------------------------------------------------------------

pub fn handlePostProfile(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handlePostProfileResponse(db, body, alloc);
    return resp.body;
}

pub fn handlePostProfileResponse(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) !JsonRouteResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}"), false);
    defer parsed.deinit();

    const name = json_util.getString(parsed.value, "profile") orelse
        return jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing profile field\"}"), false);
    if (profile_mod.fromString(name) == null) {
        return jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"unknown profile\"}"), false);
    }
    try db.storeConfig("profile", name);
    db.deleteConfig("rtmify_provisioned") catch {};
    return jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

// ---------------------------------------------------------------------------
// GET /api/repos
// ---------------------------------------------------------------------------

pub fn handleGetRepos(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"repos\":[");
    var first = true;
    var idx: usize = 0;
    while (idx < 64) : (idx += 1) {
        const key = try std.fmt.allocPrint(alloc, "repo_path_{d}", .{idx});
        defer alloc.free(key);
        const path = (try db.getConfig(key, alloc)) orelse continue;
        defer alloc.free(path);
        const ts_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{path});
        defer alloc.free(ts_key);
        const last_scan = (try db.getConfig(ts_key, alloc)) orelse try alloc.dupe(u8, "0");
        defer alloc.free(last_scan);
        const source_file_count = try countNodesForRepo(db, "SourceFile", path);
        const test_file_count = try countNodesForRepo(db, "TestFile", path);
        const annotation_count = try countAnnotationsForRepo(db, path);
        const commit_count = try countCommitsForRepo(db, path);
        if (!first) try buf.append(alloc, ',');
        first = false;
        try std.fmt.format(buf.writer(alloc), "{{\"slot\":{d},\"path\":", .{idx});
        try appendJsonStr(&buf, path, alloc);
        try buf.appendSlice(alloc, ",\"last_scan\":");
        try appendJsonStr(&buf, last_scan, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"source_file_count\":{d},\"test_file_count\":{d},\"file_count\":{d},\"annotation_count\":{d},\"commit_count\":{d}",
            .{ source_file_count, test_file_count, source_file_count + test_file_count, annotation_count, commit_count });
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// POST /api/repos
// ---------------------------------------------------------------------------

pub fn handlePostRepo(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handlePostRepoResponse(db, body, alloc);
    return resp.body;
}

pub fn handlePostRepoResponse(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) !JsonRouteResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}"), false);
    defer parsed.deinit();

    const path = json_util.getString(parsed.value, "path") orelse
        return jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing path field\"}"), false);
    std.fs.accessAbsolute(path, .{}) catch {
        const diag = [_]InlineDiagnostic{
            makeInlineDiagnostic(901, "err", "Repo path does not exist", try std.fmt.allocPrint(alloc, "Repo path does not exist: {s}", .{path}), "repo_validation", path, "{}"),
        };
        return jsonRouteResponse(.bad_request, try errorResponseWithDiagnostics("repo path does not exist", &diag, alloc), false);
    };
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.NotDir => {
            const diag = [_]InlineDiagnostic{
                makeInlineDiagnostic(902, "err", "Repo path is not a directory", try std.fmt.allocPrint(alloc, "Repo path is not a directory: {s}", .{path}), "repo_validation", path, "{}"),
            };
            return jsonRouteResponse(.bad_request, try errorResponseWithDiagnostics("path is not a directory", &diag, alloc), false);
        },
        error.AccessDenied => {
            const diag = [_]InlineDiagnostic{
                makeInlineDiagnostic(904, "err", "Repo path not readable", try std.fmt.allocPrint(alloc, "Repo path is not readable: {s}", .{path}), "repo_validation", path, "{}"),
            };
            return jsonRouteResponse(.bad_request, try errorResponseWithDiagnostics("path is not readable", &diag, alloc), false);
        },
        else => {
            const diag = [_]InlineDiagnostic{
                makeInlineDiagnostic(902, "err", "Repo path is not a directory", try std.fmt.allocPrint(alloc, "Repo path is not a directory or is not accessible: {s}", .{path}), "repo_validation", path, "{}"),
            };
            return jsonRouteResponse(.bad_request, try errorResponseWithDiagnostics("path is not a directory or is not accessible", &diag, alloc), false);
        },
    };
    dir.close();
    // Walk up to find .git — required for git features; error if absent (E903)
    {
        var cur: []const u8 = path;
        var found_git = false;
        while (true) {
            const git_check = std.fmt.allocPrint(alloc, "{s}/.git", .{cur}) catch break;
            defer alloc.free(git_check);
            if (std.fs.accessAbsolute(git_check, .{})) {
                found_git = true;
                break;
            } else |_| {}
            const parent = std.fs.path.dirname(cur) orelse break;
            if (std.mem.eql(u8, parent, cur)) break;
            cur = parent;
        }
        if (!found_git) {
            const diag = [_]InlineDiagnostic{
                makeInlineDiagnostic(903, "err", "No .git directory found", try std.fmt.allocPrint(alloc, "No .git directory found at {s}", .{path}), "repo_validation", path, "{}"),
            };
            return jsonRouteResponse(.bad_request, try errorResponseWithDiagnostics("no .git directory found — is this a git repository?", &diag, alloc), false);
        }
    }
    // Find next available slot
    var idx: usize = 0;
    while (idx < 64) : (idx += 1) {
        const key = try std.fmt.allocPrint(alloc, "repo_path_{d}", .{idx});
        defer alloc.free(key);
        if ((try db.getConfig(key, alloc)) == null) {
            try db.storeConfig(key, path);
            return jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
        }
    }
    return jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"too many repos\"}"), false);
}

// ---------------------------------------------------------------------------
// GET /api/diagnostics
// ---------------------------------------------------------------------------

pub fn handleDiagnostics(db: *graph_live.GraphDb, source_filter: ?[]const u8, alloc: Allocator) ![]const u8 {
    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |d| freeRuntimeDiagnostic(d, alloc);
        diags.deinit(alloc);
    }
    const source = if (source_filter) |s|
        if (std.mem.eql(u8, s, "all")) null else sourceFilterValue(s)
    else
        null;
    try db.listRuntimeDiagnostics(source, alloc, &diags);
    return runtimeDiagnosticsJson(diags.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/chain-gaps
// ---------------------------------------------------------------------------

pub fn handleChainGaps(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    const prof_name = (try db.getConfig("profile", alloc)) orelse try alloc.dupe(u8, "generic");
    defer alloc.free(prof_name);
    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);

    const edge_gaps = try chain_mod.walkChain(db, prof, alloc);
    defer alloc.free(edge_gaps);
    const special_gaps = try chain_mod.walkSpecialGaps(db, prof, alloc);
    defer alloc.free(special_gaps);

    var all: std.ArrayList(chain_mod.Gap) = .empty;
    defer all.deinit(alloc);
    try all.appendSlice(alloc, edge_gaps);
    try all.appendSlice(alloc, special_gaps);
    return chain_mod.gapsToJson(all.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/code-traceability
// ---------------------------------------------------------------------------

pub fn handleCodeTraceability(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var src_nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (src_nodes.items) |n| freeNode(n, alloc);
        src_nodes.deinit(alloc);
    }
    var tst_nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (tst_nodes.items) |n| freeNode(n, alloc);
        tst_nodes.deinit(alloc);
    }
    try db.nodesByType("SourceFile", alloc, &src_nodes);
    try db.nodesByType("TestFile", alloc, &tst_nodes);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"source_files\":");
    try buf.appendSlice(alloc, try jsonNodeArray(src_nodes.items, alloc));
    try buf.appendSlice(alloc, ",\"test_files\":");
    try buf.appendSlice(alloc, try jsonNodeArray(tst_nodes.items, alloc));
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /query/unimplemented-requirements
// ---------------------------------------------------------------------------

pub fn handleUnimplementedRequirements(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }
    try db.nodesMissingEdge("Requirement", "IMPLEMENTED_IN", alloc, &nodes);
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/untested-source-files
// ---------------------------------------------------------------------------

pub fn handleUntestedSourceFiles(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }
    try db.nodesMissingEdge("SourceFile", "VERIFIED_BY_CODE", alloc, &nodes);
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/file-annotations?file_path=...
// ---------------------------------------------------------------------------

pub fn handleFileAnnotations(db: *graph_live.GraphDb, file_path: []const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }

    var st = try db.db.prepare(
        "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE type='CodeAnnotation' AND json_extract(properties,'$.file_path')=? ORDER BY id"
    );
    defer st.finalize();
    try st.bindText(1, file_path);
    while (try st.step()) {
        const n = graph_live.Node{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        };
        try nodes.append(alloc, n);
    }
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/commit-history/:req_id
// ---------------------------------------------------------------------------

pub fn handleCommitHistory(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }

    var st = try db.db.prepare(
        \\SELECT n.id, n.type, n.properties, n.suspect, n.suspect_reason
        \\FROM nodes n JOIN edges e ON e.to_id=n.id
        \\WHERE e.from_id=? AND e.label='COMMITTED_IN' AND n.type='Commit'
        \\ORDER BY n.id DESC
    );
    defer st.finalize();
    try st.bindText(1, req_id);
    while (try st.step()) {
        const n = graph_live.Node{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        };
        try nodes.append(alloc, n);
    }
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/recent-commits
// ---------------------------------------------------------------------------

pub fn handleRecentCommits(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }
    var st = try db.db.prepare(
        \\SELECT id, type, properties, suspect, suspect_reason
        \\FROM nodes
        \\WHERE type='Commit'
        \\ORDER BY json_extract(properties,'$.date') DESC, id DESC
        \\LIMIT 20
    );
    defer st.finalize();
    while (try st.step()) {
        try nodes.append(alloc, .{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        });
    }
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/blame-for-requirement?req_id=... (MCP only)
// ---------------------------------------------------------------------------

pub fn handleBlameForRequirement(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) ![]const u8 {
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| freeNode(n, alloc);
        nodes.deinit(alloc);
    }

    var st = try db.db.prepare(
        \\SELECT n.id, n.type, n.properties, n.suspect, n.suspect_reason
        \\FROM nodes n JOIN edges e ON e.to_id=n.id
        \\WHERE e.from_id=? AND e.label='ANNOTATED_AT' AND n.type='CodeAnnotation'
        \\ORDER BY n.id
    );
    defer st.finalize();
    try st.bindText(1, req_id);
    while (try st.step()) {
        const n = graph_live.Node{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        };
        try nodes.append(alloc, n);
    }
    return jsonNodeArray(nodes.items, alloc);
}

// ---------------------------------------------------------------------------
// GET /query/design-history?req_id=... (MCP only)
// ---------------------------------------------------------------------------

pub fn handleDesignHistory(db: *graph_live.GraphDb, req_id: []const u8, alloc: Allocator) ![]const u8 {
    const requirement = try db.getNode(req_id, alloc);
    defer if (requirement) |n| freeNode(n, alloc);

    var user_needs: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&user_needs, alloc);
    var risks: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&risks, alloc);
    var design_inputs: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&design_inputs, alloc);
    var design_outputs: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&design_outputs, alloc);
    var configuration_items: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&configuration_items, alloc);
    var source_files: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&source_files, alloc);
    var test_files: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&test_files, alloc);
    var annotations: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&annotations, alloc);
    var commits: std.ArrayList(graph_live.Node) = .empty;
    defer freeNodeList(&commits, alloc);

    try collectNodesViaOutgoingEdge(db, req_id, "DERIVES_FROM", "UserNeed", alloc, &user_needs);
    try collectNodesViaIncomingEdge(db, req_id, "MITIGATED_BY", "Risk", alloc, &risks);
    try collectNodesViaOutgoingEdge(db, req_id, "ALLOCATED_TO", "DesignInput", alloc, &design_inputs);
    try collectNodesViaOutgoingEdge(db, req_id, "IMPLEMENTED_IN", "SourceFile", alloc, &source_files);
    try collectNodesViaOutgoingEdge(db, req_id, "VERIFIED_BY_CODE", "TestFile", alloc, &test_files);
    try collectNodesViaOutgoingEdge(db, req_id, "ANNOTATED_AT", "CodeAnnotation", alloc, &annotations);
    try collectNodesViaOutgoingEdge(db, req_id, "COMMITTED_IN", "Commit", alloc, &commits);

    for (design_inputs.items) |di| {
        try collectNodesViaOutgoingEdge(db, di.id, "SATISFIED_BY", "DesignOutput", alloc, &design_outputs);
    }
    for (design_outputs.items) |do_node| {
        try collectNodesViaOutgoingEdge(db, do_node.id, "CONTROLLED_BY", "ConfigurationItem", alloc, &configuration_items);
        try collectNodesViaOutgoingEdge(db, do_node.id, "IMPLEMENTED_IN", "SourceFile", alloc, &source_files);
    }
    for (source_files.items) |src| {
        try collectNodesViaOutgoingEdge(db, src.id, "VERIFIED_BY_CODE", "TestFile", alloc, &test_files);
    }

    const prof_name = (try db.getConfig("profile", alloc)) orelse try alloc.dupe(u8, "generic");
    defer alloc.free(prof_name);
    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);

    const edge_gaps = try chain_mod.walkChain(db, prof, alloc);
    defer freeGapSlice(edge_gaps, alloc);
    const special_gaps = try chain_mod.walkSpecialGaps(db, prof, alloc);
    defer freeGapSlice(special_gaps, alloc);

    var related_ids = std.StringHashMap(void).init(alloc);
    defer {
        var it = related_ids.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        related_ids.deinit();
    }
    try relatedIdsPut(&related_ids, req_id, alloc);
    if (requirement) |n| try relatedIdsPut(&related_ids, n.id, alloc);
    try addNodeIdsToSet(user_needs.items, &related_ids, alloc);
    try addNodeIdsToSet(risks.items, &related_ids, alloc);
    try addNodeIdsToSet(design_inputs.items, &related_ids, alloc);
    try addNodeIdsToSet(design_outputs.items, &related_ids, alloc);
    try addNodeIdsToSet(configuration_items.items, &related_ids, alloc);
    try addNodeIdsToSet(source_files.items, &related_ids, alloc);
    try addNodeIdsToSet(test_files.items, &related_ids, alloc);
    try addNodeIdsToSet(annotations.items, &related_ids, alloc);
    try addNodeIdsToSet(commits.items, &related_ids, alloc);

    var filtered_gaps: std.ArrayList(chain_mod.Gap) = .empty;
    defer freeGapList(&filtered_gaps, alloc);
    try appendMatchingGaps(edge_gaps, &related_ids, alloc, &filtered_gaps);
    try appendMatchingGaps(special_gaps, &related_ids, alloc, &filtered_gaps);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"profile\":");
    try appendJsonStr(&buf, @tagName(prof.id), alloc);
    try buf.appendSlice(alloc, ",\"requirement\":");
    try appendNodeObjectOpt(&buf, requirement, alloc);
    try buf.appendSlice(alloc, ",\"user_needs\":");
    try buf.appendSlice(alloc, try jsonNodeArray(user_needs.items, alloc));
    try buf.appendSlice(alloc, ",\"risks\":");
    try buf.appendSlice(alloc, try jsonNodeArray(risks.items, alloc));
    try buf.appendSlice(alloc, ",\"design_inputs\":");
    try buf.appendSlice(alloc, try jsonNodeArray(design_inputs.items, alloc));
    try buf.appendSlice(alloc, ",\"design_outputs\":");
    try buf.appendSlice(alloc, try jsonNodeArray(design_outputs.items, alloc));
    try buf.appendSlice(alloc, ",\"configuration_items\":");
    try buf.appendSlice(alloc, try jsonNodeArray(configuration_items.items, alloc));
    try buf.appendSlice(alloc, ",\"source_files\":");
    try buf.appendSlice(alloc, try jsonNodeArray(source_files.items, alloc));
    try buf.appendSlice(alloc, ",\"test_files\":");
    try buf.appendSlice(alloc, try jsonNodeArray(test_files.items, alloc));
    try buf.appendSlice(alloc, ",\"annotations\":");
    try buf.appendSlice(alloc, try jsonNodeArray(annotations.items, alloc));
    try buf.appendSlice(alloc, ",\"commits\":");
    try buf.appendSlice(alloc, try jsonNodeArray(commits.items, alloc));
    try buf.appendSlice(alloc, ",\"chain_gaps\":");
    try buf.appendSlice(alloc, try chain_mod.gapsToJson(filtered_gaps.items, alloc));
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /report/dhr/md
// ---------------------------------------------------------------------------

pub fn handleReportDhrMd(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_md.renderDhr(&g, buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

// ---------------------------------------------------------------------------
// GET /report/dhr/pdf
// ---------------------------------------------------------------------------

pub fn handleReportDhrPdf(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_pdf.renderDhrPdf(&g, buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
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

fn freeNodeList(nodes: *std.ArrayList(graph_live.Node), alloc: Allocator) void {
    for (nodes.items) |n| freeNode(n, alloc);
    nodes.deinit(alloc);
}

fn freeGapSlice(gaps: []const chain_mod.Gap, alloc: Allocator) void {
    for (gaps) |gap| {
        alloc.free(gap.title);
        alloc.free(gap.gap_type);
        alloc.free(gap.node_id);
        alloc.free(gap.message);
    }
    alloc.free(gaps);
}

fn freeGapList(gaps: *std.ArrayList(chain_mod.Gap), alloc: Allocator) void {
    for (gaps.items) |gap| {
        alloc.free(gap.title);
        alloc.free(gap.gap_type);
        alloc.free(gap.node_id);
        alloc.free(gap.message);
    }
    gaps.deinit(alloc);
}

fn freeEdge(e: graph_live.Edge, alloc: Allocator) void {
    alloc.free(e.id);
    alloc.free(e.from_id);
    alloc.free(e.to_id);
    alloc.free(e.label);
}

fn freeRuntimeDiagnostic(d: graph_live.RuntimeDiagnostic, alloc: Allocator) void {
    alloc.free(d.dedupe_key);
    alloc.free(d.severity);
    alloc.free(d.title);
    alloc.free(d.message);
    alloc.free(d.source);
    if (d.subject) |s| alloc.free(s);
    alloc.free(d.details_json);
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

fn appendNodeObject(buf: *std.ArrayList(u8), n: graph_live.Node, alloc: Allocator) !void {
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

fn appendNodeObjectOpt(buf: *std.ArrayList(u8), n: ?graph_live.Node, alloc: Allocator) !void {
    if (n) |node| {
        try appendNodeObject(buf, node, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

fn addUniqueNode(result: *std.ArrayList(graph_live.Node), node: graph_live.Node, alloc: Allocator) !void {
    for (result.items) |existing| {
        if (std.mem.eql(u8, existing.id, node.id)) {
            freeNode(node, alloc);
            return;
        }
    }
    try result.append(alloc, node);
}

fn collectNodesViaOutgoingEdge(
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
        try addUniqueNode(result, .{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        }, alloc);
    }
}

fn collectNodesViaIncomingEdge(
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
        try addUniqueNode(result, .{
            .id = try alloc.dupe(u8, st.columnText(0)),
            .type = try alloc.dupe(u8, st.columnText(1)),
            .properties = try alloc.dupe(u8, st.columnText(2)),
            .suspect = st.columnInt(3) != 0,
            .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
        }, alloc);
    }
}

fn relatedIdsPut(set: *std.StringHashMap(void), id: []const u8, alloc: Allocator) !void {
    if (set.contains(id)) return;
    try set.put(try alloc.dupe(u8, id), {});
}

fn addNodeIdsToSet(nodes: []const graph_live.Node, set: *std.StringHashMap(void), alloc: Allocator) !void {
    for (nodes) |node| try relatedIdsPut(set, node.id, alloc);
}

fn appendMatchingGaps(
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

const InlineDiagnostic = struct {
    code: u16,
    severity: []const u8,
    title: []const u8,
    message: []const u8,
    source: []const u8,
    subject: ?[]const u8,
    details_json: []const u8,
};

fn runtimeDiagnosticsJson(items: []const graph_live.RuntimeDiagnostic, alloc: Allocator) ![]const u8 {
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

fn errorResponseWithDiagnostics(msg: []const u8, diagnostics: []const InlineDiagnostic, alloc: Allocator) ![]const u8 {
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

fn appendRuntimeDiagnosticObject(buf: *std.ArrayList(u8), d: anytype, alloc: Allocator) !void {
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

const EdgeDir = enum { out, in };

fn appendEdgeArrayWithNode(buf: *std.ArrayList(u8), db: *graph_live.GraphDb, edges: []const graph_live.Edge, dir: EdgeDir, alloc: Allocator) !void {
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

fn makeInlineDiagnostic(code: u16, severity: []const u8, title: []const u8, message: []const u8, source: []const u8, subject: ?[]const u8, details_json: []const u8) InlineDiagnostic {
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

fn sourceFilterValue(filter: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, filter, "repo")) return "repo_validation";
    if (std.mem.eql(u8, filter, "git")) return "git";
    if (std.mem.eql(u8, filter, "annotation")) return "annotation";
    if (std.mem.eql(u8, filter, "profile")) return "profile";
    if (std.mem.eql(u8, filter, "repo_scan")) return "repo_scan";
    return null;
}

fn countNodesForRepo(db: *graph_live.GraphDb, node_type: []const u8, repo_path: []const u8) !i64 {
    var st = try db.db.prepare(
        \\SELECT COUNT(*) FROM nodes
        \\WHERE type=? AND json_extract(properties,'$.repo')=?
    );
    defer st.finalize();
    try st.bindText(1, node_type);
    try st.bindText(2, repo_path);
    _ = try st.step();
    return st.columnInt(0);
}

fn countAnnotationsForRepo(db: *graph_live.GraphDb, repo_path: []const u8) !i64 {
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

fn countCommitsForRepo(db: *graph_live.GraphDb, repo_path: []const u8) !i64 {
    var st = try db.db.prepare(
        \\SELECT COUNT(DISTINCT c.id)
        \\FROM nodes c
        \\JOIN edges ec ON ec.to_id = c.id AND ec.label='COMMITTED_IN'
        \\WHERE c.type='Commit'
        \\  AND EXISTS (
        \\      SELECT 1
        \\      FROM edges ei
        \\      JOIN nodes f ON f.id = ei.to_id
        \\      WHERE ei.from_id = ec.from_id
        \\        AND ei.label='IMPLEMENTED_IN'
        \\        AND json_extract(f.properties,'$.repo')=?
        \\  )
    );
    defer st.finalize();
    try st.bindText(1, repo_path);
    _ = try st.step();
    return st.columnInt(0);
}

fn getProvisionPreviewForActive(active: online_provider.ActiveConnection, prof: profile_mod.Profile, alloc: Allocator) ![]const u8 {
    var runtime = try online_provider.ProviderRuntime.init(active, alloc);
    defer runtime.deinit(alloc);
    const tab_ids = try runtime.listTabs(alloc);
    defer online_provider.freeTabRefs(tab_ids, alloc);

    return buildProvisionPreviewJson(prof, tab_ids, alloc);
}

fn buildProvisionPreviewJson(prof: profile_mod.Profile, tab_ids: []const online_provider.TabRef, alloc: Allocator) ![]const u8 {

    var existing: std.ArrayList([]const u8) = .empty;
    defer existing.deinit(alloc);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ready\":true,\"profile\":");
    try appendJsonStr(&buf, @tagName(prof.id), alloc);
    try buf.appendSlice(alloc, ",\"tabs\":[");
    for (prof.tabs, 0..) |tab, i| {
        if (i > 0) try buf.append(alloc, ',');
        const exists = previewTabExists(tab_ids, tab);
        if (exists) try existing.append(alloc, tab) else try missing.append(alloc, tab);
        try buf.appendSlice(alloc, "{\"name\":");
        try appendJsonStr(&buf, tab, alloc);
        try buf.appendSlice(alloc, ",\"exists\":");
        try buf.appendSlice(alloc, if (exists) "true" else "false");
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    try std.fmt.format(buf.writer(alloc), ",\"existing_count\":{d},\"missing_count\":{d},\"existing\":", .{ existing.items.len, missing.items.len });
    try buf.appendSlice(alloc, try jsonStringArray(existing.items, alloc));
    try buf.appendSlice(alloc, ",\"missing\":");
    try buf.appendSlice(alloc, try jsonStringArray(missing.items, alloc));
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn previewTabExists(existing_tabs: []const online_provider.TabRef, want: []const u8) bool {
    for (existing_tabs) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, want)) return true;
        if (containsIgnoreCase(tab.title, want) or containsIgnoreCase(want, tab.title)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var hay_buf: [128]u8 = undefined;
    var needle_buf: [128]u8 = undefined;
    const hay_len = @min(haystack.len, hay_buf.len);
    const needle_len = @min(needle.len, needle_buf.len);
    for (haystack[0..hay_len], 0..) |c, i| hay_buf[i] = std.ascii.toLower(c);
    for (needle[0..needle_len], 0..) |c, i| needle_buf[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, hay_buf[0..hay_len], needle_buf[0..needle_len]) != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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

test "handlePostProfile accepts legal JSON with whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handlePostProfile(&db, "{ \"profile\" : \"aerospace\" }", alloc);
    try testing.expectEqualStrings("{\"ok\":true}", resp);
}

test "handleProvisionPreview returns ready false without credential or sheet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handleProvisionPreview(&db, null, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"ready\":false") != null);
}

test "gitless mode status is configured and repos list is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var state: sync_live.SyncState = .{};

    try db.storeCredential("{\"platform\":\"google\",\"client_email\":\"svc@example.com\",\"private_key\":\"key\"}");
    try db.storeConfig("platform", "google");
    try db.storeConfig("google_sheet_id", "sheet-123");
    try db.storeConfig("workbook_url", "https://docs.google.com/spreadsheets/d/sheet-123/edit");
    try db.storeConfig("workbook_label", "sheet-123");
    try db.storeConfig("credential_display", "svc@example.com");

    const status = try handleStatus(&db, &state, alloc);
    try testing.expect(std.mem.indexOf(u8, status, "\"configured\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"platform\":\"google\"") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"credential_display\":\"svc@example.com\"") != null);

    const repos = try handleGetRepos(&db, alloc);
    try testing.expectEqualStrings("{\"repos\":[]}", repos);
}

test "handlePostRepo returns E902 for file path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const tmp_path = "/tmp/rtmify-routes-file.txt";
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("x");
    }
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{tmp_path});
    const resp = try handlePostRepo(&db, body, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":902") != null);
}

test "handlePostRepo accepts legal JSON with whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    const body = try std.fmt.allocPrint(alloc, "{{ \"path\" : \"{s}\" }}", .{tmp_path});
    const resp = try handlePostRepo(&db, body, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"missing path field\"") == null);
}

test "handlePostRepo accepts escaped path characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handlePostRepo(&db, "{ \"path\" : \"/tmp/repo \\\"alpha\\\"\" }", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":901") != null);
}

test "handlePostRepo returns E903 for directory without git" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const tmp_dir = "/tmp/rtmify-routes-nogit";
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{tmp_dir});
    const resp = try handlePostRepo(&db, body, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":903") != null);
}

test "handleChainGaps includes code and title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.storeConfig("profile", "medical");
    try db.addNode("REQ-001", "Requirement", "{}", null);

    const resp = try handleChainGaps(&db, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"title\":") != null);
}

test "handleChainGaps returns empty for generic profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.storeConfig("profile", "generic");
    try db.addNode("REQ-001", "Requirement", "{}", null);

    const resp = try handleChainGaps(&db, alloc);
    try testing.expectEqualStrings("[]", resp);
}

test "handleDesignHistory returns structured chain with filtered gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.storeConfig("profile", "medical");

    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need GPS\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Detect GPS loss\"}", null);
    try db.addNode("RSK-001", "Risk", "{\"description\":\"Clock drift\"}", null);
    try db.addNode("DI-001", "DesignInput", "{\"description\":\"Timing spec\"}", null);
    try db.addNode("DO-001", "DesignOutput", "{\"description\":\"GPS firmware\"}", null);
    try db.addNode("src/gps.c", "SourceFile", "{\"path\":\"src/gps.c\"}", null);
    try db.addNode("test/gps_test.c", "TestFile", "{\"path\":\"test/gps_test.c\"}", null);
    try db.addNode("src/gps.c:10", "CodeAnnotation", "{\"req_id\":\"REQ-001\",\"file_path\":\"src/gps.c\",\"line_number\":10}", null);
    try db.addNode("abc123", "Commit", "{\"hash\":\"abc123\",\"short_hash\":\"abc123\",\"date\":\"2026-03-09T00:00:00Z\"}", null);

    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");
    try db.addEdge("REQ-001", "DI-001", "ALLOCATED_TO");
    try db.addEdge("DI-001", "DO-001", "SATISFIED_BY");
    try db.addEdge("REQ-001", "src/gps.c", "IMPLEMENTED_IN");
    try db.addEdge("REQ-001", "test/gps_test.c", "VERIFIED_BY_CODE");
    try db.addEdge("src/gps.c", "test/gps_test.c", "VERIFIED_BY_CODE");
    try db.addEdge("REQ-001", "src/gps.c:10", "ANNOTATED_AT");
    try db.addEdge("src/gps.c", "src/gps.c:10", "CONTAINS");
    try db.addEdge("REQ-001", "abc123", "COMMITTED_IN");

    const resp = try handleDesignHistory(&db, "REQ-001", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"requirement\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"user_needs\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"design_inputs\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"design_outputs\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"source_files\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"test_files\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"annotations\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"commits\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"chain_gaps\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "DO-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "design_output_without_config_control") != null);
}

test "handleNode returns node wrapper plus edge arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("TEST-001", "Test", "{\"result\":\"PASS\"}", null);
    try db.addEdge("REQ-001", "TEST-001", "TESTED_BY");

    const resp = try handleNode(&db, "REQ-001", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"node\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"edges_out\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"edges_in\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":\"REQ-001\"") != null);
}

test "handleNode matches dashboard contract structurally" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("TEST-001", "Test", "{\"result\":\"PASS\"}", null);
    try db.addEdge("REQ-001", "TEST-001", "TESTED_BY");
    {
        var st = try db.db.prepare("UPDATE nodes SET suspect=1, suspect_reason='changed' WHERE id='REQ-001'");
        defer st.finalize();
        _ = try st.step();
    }

    const resp = try handleNode(&db, "REQ-001", alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expect(root.get("node") != null);
    try testing.expect(root.get("edges_out") != null);
    try testing.expect(root.get("edges_in") != null);

    const node = root.get("node").?.object;
    try testing.expectEqualStrings("REQ-001", node.get("id").?.string);
    try testing.expectEqualStrings("Requirement", node.get("type").?.string);
    try testing.expectEqualStrings("Example", node.get("properties").?.object.get("statement").?.string);
    try testing.expect(node.get("suspect").?.bool);
    try testing.expectEqualStrings("changed", node.get("suspect_reason").?.string);

    const edges_out = root.get("edges_out").?.array.items;
    const edges_in = root.get("edges_in").?.array.items;
    try testing.expectEqual(@as(usize, 1), edges_out.len);
    try testing.expectEqual(@as(usize, 0), edges_in.len);
    try testing.expectEqualStrings("TESTED_BY", edges_out[0].object.get("label").?.string);
    try testing.expect(edges_out[0].object.get("node") != null);
    try testing.expectEqualStrings("TEST-001", edges_out[0].object.get("node").?.object.get("id").?.string);
    try testing.expectEqualStrings("Test", edges_out[0].object.get("node").?.object.get("type").?.string);
}

test "handleNode missing node returns not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try testing.expectError(error.NotFound, handleNode(&db, "REQ-404", alloc));
}

test "handleImpact missing node returns not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try testing.expectError(error.NotFound, handleImpact(&db, "REQ-404", alloc));
}

test "handleRisks includes score fields used by dashboard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("RSK-001", "Risk", "{\"description\":\"Example\",\"initial_severity\":\"4\",\"initial_likelihood\":\"3\",\"mitigation\":\"Mitigate\",\"residual_severity\":\"2\",\"residual_likelihood\":\"1\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example req\"}", null);
    try db.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");

    const resp = try handleRisks(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    const row = rows[0].object;
    try testing.expect(row.get("initial_severity") != null);
    try testing.expect(row.get("initial_likelihood") != null);
    try testing.expect(row.get("residual_severity") != null);
    try testing.expect(row.get("residual_likelihood") != null);
}

test "handleGetRepos includes stable slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.storeConfig("repo_path_3", "/tmp/repo");

    const resp = try handleGetRepos(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const repos = parsed.value.object.get("repos").?.array.items;
    try testing.expectEqual(@as(usize, 1), repos.len);
    try testing.expectEqual(@as(i64, 3), repos[0].object.get("slot").?.integer);
}

test "handleRtm uses canonical suspect field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", "changed");

    const resp = try handleRtm(&db, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"suspect\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"req_suspect\":") == null);
}

test "handleTests uses canonical suspect field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addNode("TEST-001", "Test", "{\"test_group_id\":\"TG-001\",\"test_id\":\"TEST-001\",\"test_type\":\"Functional\",\"test_method\":\"Manual\"}", "changed");
    try db.addEdge("TG-001", "TEST-001", "HAS_TEST");

    const resp = try handleTests(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 1), rows.len);
    const row = rows[0].object;
    try testing.expect(row.get("suspect") != null);
    try testing.expect(row.get("test_suspect") == null);
}

test "index_html smoke covers onboarding profile and code traceability flows" {
    try testing.expect(std.mem.indexOf(u8, index_html, "provision-preview") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "/api/profile") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "/api/provision") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "/query/chain-gaps") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "/api/repos") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "/api/diagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "/query/recent-commits") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Create Missing Tabs") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Code Traceability") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "Design History Record (DHR)") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "const { node, edges_out, edges_in } = data;") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "function humanEdgeLabel(") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "JSON.parse(f.properties") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "JSON.parse(a.properties") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "JSON.parse(c.properties") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "r.test_suspect") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "r.req_suspect") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "${arrow} ${esc(e.label)}") == null);
    try testing.expect(std.mem.indexOf(u8, index_html, "deleteRepo(${Number.isInteger(r.slot) ? r.slot : 0})") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "id=\"lobby-share-hint\"") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "id=\"lobby-share-hint\" style=\"margin-top:8px;display:none\"") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "shareHintEl.style.display = 'block'") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "shareHintEl.style.display = 'none'") != null);
    try testing.expect(std.mem.indexOf(u8, index_html, "document.getElementById('lobby-share-hint').style.display = 'block'") != null);
}

test "buildProvisionPreviewJson closes tabs array before summary fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prof = profile_mod.get(.medical);
    const tabs = [_]online_provider.TabRef{
        .{ .title = "User Needs", .native_id = "1" },
        .{ .title = "Requirements", .native_id = "2" },
        .{ .title = "Tests", .native_id = "3" },
        .{ .title = "Risks", .native_id = "4" },
    };
    const preview = try buildProvisionPreviewJson(prof, &tabs, alloc);
    defer alloc.free(preview);

    try testing.expect(std.mem.indexOf(u8, preview, "],\"existing_count\"") != null);
}
