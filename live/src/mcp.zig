/// mcp.zig — MCP endpoint for rtmify-live.
///
/// Transport: Streamable HTTP (POST /mcp) + SSE discovery (GET /mcp).
const std = @import("std");
const Allocator = std.mem.Allocator;

const license = @import("rtmify").license;
const graph_live = @import("graph_live.zig");
const sync_live = @import("sync_live.zig");
const routes = @import("routes.zig");
const secure_store = @import("secure_store.zig");
const json_util = @import("json_util.zig");
const profile_mod = @import("profile.zig");
const chain_mod = @import("chain.zig");

const ToolPayload = struct {
    text: []const u8,
    note: ?[]const u8 = null,
    pub fn deinit(self: ToolPayload, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.note) |n| alloc.free(n);
    }
};

const resources_json =
    \\[
    \\{"uri":"report://status","name":"Live Status","description":"Current sync and connection status.","mimeType":"text/markdown"},
    \\{"uri":"report://chain-gaps","name":"Chain Gap Summary","description":"Summary of current profile-specific traceability gaps.","mimeType":"text/markdown"},
    \\{"uri":"report://rtm","name":"RTM Summary","description":"Summary of requirements traceability matrix coverage.","mimeType":"text/markdown"},
    \\{"uri":"report://code-traceability","name":"Code Traceability Summary","description":"Summary of source and test file traceability.","mimeType":"text/markdown"},
    \\{"uri":"report://review","name":"Review Summary","description":"Summary of suspect items requiring review.","mimeType":"text/markdown"}
    \\]
;

const prompts_json =
    \\[
    \\{"name":"trace_requirement","description":"Trace one requirement through tests, risks, code, commits, and gaps.","arguments":[{"name":"id","description":"Requirement ID (e.g. REQ-001)","required":true}]},
    \\{"name":"impact_of_change","description":"Analyze downstream impact from changing a traced node.","arguments":[{"name":"id","description":"Node ID (e.g. UN-001 or REQ-001)","required":true}]},
    \\{"name":"explain_gap","description":"Explain why RTMify raised a specific chain gap.","arguments":[{"name":"code","description":"Gap code (e.g. 1203)","required":true},{"name":"node_id","description":"Node ID tied to the gap","required":true}]},
    \\{"name":"audit_readiness_summary","description":"Summarize RTMify readiness for the selected profile.","arguments":[{"name":"profile","description":"Profile name (generic, medical, aerospace, automotive)","required":true}]},
    \\{"name":"repo_coverage_summary","description":"Summarize repo-backed implementation and test coverage.","arguments":[{"name":"repo","description":"Optional repo path filter","required":false}]},
    \\{"name":"design_history_summary","description":"Summarize design history for a requirement.","arguments":[{"name":"req_id","description":"Requirement ID (e.g. REQ-001)","required":true}]}
    \\]
;

const tools_json =
    \\[
    \\{"name":"get_rtm","description":"Get the Requirements Traceability Matrix. Optional limit/offset and suspect-only filtering.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"},"suspect_only":{"type":"boolean"}},"required":[]}},
    \\{"name":"get_gaps","description":"Get requirements with no test linked. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"get_suspects","description":"Get all suspect nodes. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"get_nodes","description":"Get graph nodes, optionally filtered by type. Supports limit and offset.","inputSchema":{"type":"object","properties":{"type":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"get_node","description":"Get a single node by ID including all edges in and out.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"include_edges":{"type":"boolean"},"include_properties":{"type":"boolean"}},"required":["id"]}},
    \\{"name":"search","description":"Full-text search across node IDs and properties. Supports limit.","inputSchema":{"type":"object","properties":{"q":{"type":"string"},"limit":{"type":"integer"}},"required":["q"]}},
    \\{"name":"get_user_needs","description":"Get User Need nodes. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"get_tests","description":"Get Test nodes with linked requirements. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"get_risks","description":"Get the risk register. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"get_impact","description":"Get impact analysis for a node.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
    \\{"name":"get_schema","description":"Get the graph schema: node types, edge labels, and meanings.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_status","description":"Get sync state, connection, and license status.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"clear_suspect","description":"Mark a suspect node as reviewed.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
    \\{"name":"code_traceability","description":"Source and test files with annotation counts. Supports repo and limit.","inputSchema":{"type":"object","properties":{"repo":{"type":"string"},"limit":{"type":"integer"}},"required":[]}},
    \\{"name":"unimplemented_requirements","description":"Requirements with no IMPLEMENTED_IN edge.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"untested_source_files","description":"Source files with no VERIFIED_BY_CODE edge.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"file_annotations","description":"Code annotations found in a specific source file.","inputSchema":{"type":"object","properties":{"file_path":{"type":"string"},"limit":{"type":"integer"}},"required":["file_path"]}},
    \\{"name":"blame_for_requirement","description":"Code annotations with blame data linked to a requirement.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"},"limit":{"type":"integer"}},"required":["req_id"]}},
    \\{"name":"commit_history","description":"Commits linked to a requirement via COMMITTED_IN edges. Supports limit.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"},"limit":{"type":"integer"}},"required":["req_id"]}},
    \\{"name":"design_history","description":"Full upstream/downstream chain for a requirement.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"}},"required":["req_id"]}},
    \\{"name":"chain_gaps","description":"Traceability chain gaps for the active or requested industry profile. Supports severity, profile, limit, and offset.","inputSchema":{"type":"object","properties":{"profile":{"type":"string"},"severity":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]}},
    \\{"name":"implementation_changes_since","description":"Find requirements or user needs whose implementation files changed since an ISO timestamp. This uses file/commit history, not explicit COMMITTED_IN message references. Supports repo, limit, and offset.","inputSchema":{"type":"object","properties":{"since":{"type":"string"},"node_type":{"type":"string","enum":["Requirement","UserNeed"]},"repo":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":["since","node_type"]}},
    \\{"name":"requirement_trace","description":"Concise markdown trace summary for a requirement.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
    \\{"name":"gap_explanation","description":"Concise markdown explanation for a specific chain gap.","inputSchema":{"type":"object","properties":{"code":{"type":"integer"},"node_id":{"type":"string"}},"required":["code","node_id"]}},
    \\{"name":"impact_summary","description":"Concise markdown impact summary for a node.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
    \\{"name":"status_summary","description":"Concise markdown summary of Live status.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"review_summary","description":"Concise markdown summary of suspects and open chain gaps.","inputSchema":{"type":"object","properties":{},"required":[]}}
    \\]
;

const initialize_result =
    \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{},"prompts":{}},"serverInfo":{"name":"rtmify-live","version":"1.0"}}
;

const json_rpc_headers = [_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Connection", .value = "close" },
};

pub fn handleSse(req: *std.http.Server.Request, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, alloc: Allocator) !void {
    _ = db;
    _ = secure_store_ref;
    _ = alloc;
    const body =
        "event: endpoint\r\n" ++
        "data: /mcp\r\n" ++
        "\r\n";
    const sse_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/event-stream" },
        .{ .name = "Cache-Control", .value = "no-cache" },
        .{ .name = "Connection", .value = "close" },
    };
    try req.respond(body, .{ .status = .ok, .extra_headers = &sse_headers, .keep_alive = false });
}

pub fn handlePost(
    req: *std.http.Server.Request,
    body: []const u8,
    db: *graph_live.GraphDb,
    secure_store_ref: *secure_store.Store,
    state: *sync_live.SyncState,
    alloc: Allocator,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return sendError(req, "null", -32600, "Invalid Request", alloc);
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return sendError(req, "null", -32600, "Invalid Request", alloc);
    const method = json_util.getString(root, "method") orelse return sendError(req, "null", -32600, "Invalid Request", alloc);
    const id_raw = if (json_util.getObjectField(root, "id")) |id_value|
        try std.json.Stringify.valueAlloc(alloc, id_value, .{})
    else
        try alloc.dupe(u8, "null");
    defer alloc.free(id_raw);
    const is_notification = json_util.getObjectField(root, "id") == null;

    if (std.mem.eql(u8, method, "initialize")) {
        try sendResult(req, id_raw, initialize_result, alloc);
    } else if (std.mem.eql(u8, method, "notifications/initialized") or std.mem.eql(u8, method, "notifications/cancelled")) {
        if (is_notification) {
            try req.respond("", .{ .status = .accepted, .extra_headers = &json_rpc_headers, .keep_alive = false });
        } else {
            try sendResult(req, id_raw, "{}", alloc);
        }
    } else if (std.mem.eql(u8, method, "ping")) {
        try sendResult(req, id_raw, "{}", alloc);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        const result = try std.fmt.allocPrint(alloc, "{{\"tools\":{s}}}", .{tools_json});
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try dispatchToolCall(req, root, id_raw, db, secure_store_ref, state, alloc);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        const result = try resourcesListResult(db, alloc);
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        try dispatchResourceRead(req, root, id_raw, db, secure_store_ref, state, alloc);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        const result = try promptsListResult(alloc);
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        try dispatchPromptGet(req, root, id_raw, db, secure_store_ref, state, alloc);
    } else {
        try sendError(req, id_raw, -32601, "Method not found", alloc);
    }
}

fn dispatchToolCall(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) !void {
    const params = json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", alloc);
    const name = json_util.getString(params, "name") orelse return sendError(req, id_raw, -32602, "Missing tool name", alloc);
    const args = json_util.getObjectField(params, "arguments");
    const payload = buildToolPayload(name, args, db, secure_store_ref, state, alloc) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Not found", alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid arguments", alloc),
        else => return e,
    };
    defer payload.deinit(alloc);
    try sendToolPayload(req, id_raw, payload, alloc);
}

fn dispatchResourceRead(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) !void {
    const params = json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", alloc);
    const uri = json_util.getString(params, "uri") orelse return sendError(req, id_raw, -32602, "Missing uri", alloc);
    const result = resourceReadResult(uri, db, secure_store_ref, state, alloc) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Resource not found", alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid resource URI", alloc),
        else => return e,
    };
    defer alloc.free(result);
    try sendResult(req, id_raw, result, alloc);
}

fn dispatchPromptGet(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) !void {
    const params = json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", alloc);
    const name = json_util.getString(params, "name") orelse return sendError(req, id_raw, -32602, "Missing prompt name", alloc);
    const args = json_util.getObjectField(params, "arguments");
    const result = promptGetResult(name, args, db, secure_store_ref, state, alloc) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Prompt not found", alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid prompt arguments", alloc),
        else => return e,
    };
    defer alloc.free(result);
    try sendResult(req, id_raw, result, alloc);
}

fn buildToolPayload(name: []const u8, args: ?std.json.Value, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) !ToolPayload {
    if (std.mem.eql(u8, name, "get_rtm")) {
        const data = try routes.handleRtm(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{ .suspect_field = true }, alloc);
    } else if (std.mem.eql(u8, name, "get_gaps")) {
        const data = try routes.handleGaps(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "get_suspects")) {
        const data = try routes.handleSuspects(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "get_nodes")) {
        const type_filter = if (args) |a| json_util.getString(a, "type") else null;
        const data = try routes.handleNodes(db, type_filter, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "get_node")) {
        const node_id = try requireStringArg(args, "id");
        const data = try routes.handleNode(db, node_id, alloc);
        return .{ .text = data };
    } else if (std.mem.eql(u8, name, "search")) {
        const q = try requireStringArg(args, "q");
        const data = try routes.handleSearch(db, q, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "get_user_needs")) {
        const data = try routes.handleUserNeeds(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "get_tests")) {
        const data = try routes.handleTests(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "get_risks")) {
        const data = try routes.handleRisks(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "get_impact")) {
        const node_id = try requireStringArg(args, "id");
        const data = try routes.handleImpact(db, node_id, alloc);
        return .{ .text = data };
    } else if (std.mem.eql(u8, name, "get_schema")) {
        const data = try routes.handleSchema(db, alloc);
        return .{ .text = data };
    } else if (std.mem.eql(u8, name, "get_status")) {
        var license_service = try license.initDefaultLemonSqueezy(alloc, .{});
        defer license_service.deinit(alloc);
        const data = try routes.handleStatus(db, secure_store_ref, state, &license_service, alloc);
        return .{ .text = data };
    } else if (std.mem.eql(u8, name, "clear_suspect")) {
        const node_id = try requireStringArg(args, "id");
        const data = try routes.handleClearSuspect(db, node_id, alloc);
        return .{ .text = data };
    } else if (std.mem.eql(u8, name, "code_traceability")) {
        const data = try routes.handleCodeTraceability(db, alloc);
        defer alloc.free(data);
        return filterCodeTraceabilityPayload(data, args, alloc);
    } else if (std.mem.eql(u8, name, "unimplemented_requirements")) {
        const data = try routes.handleUnimplementedRequirements(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "untested_source_files")) {
        const data = try routes.handleUntestedSourceFiles(db, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "file_annotations")) {
        const file_path = try requireStringArg(args, "file_path");
        const data = try routes.handleFileAnnotations(db, file_path, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "blame_for_requirement")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try routes.handleBlameForRequirement(db, req_id, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "commit_history")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try routes.handleCommitHistory(db, req_id, alloc);
        defer alloc.free(data);
        return filteredArrayPayload(data, args, .{}, alloc);
    } else if (std.mem.eql(u8, name, "design_history")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try routes.handleDesignHistory(db, req_id, alloc);
        return .{ .text = data };
    } else if (std.mem.eql(u8, name, "chain_gaps")) {
        return chainGapsToolPayload(db, args, alloc);
    } else if (std.mem.eql(u8, name, "implementation_changes_since")) {
        const since = try requireStringArg(args, "since");
        const node_type = try requireStringArg(args, "node_type");
        const repo = if (args) |a| json_util.getString(a, "repo") else null;
        const limit_arg = getIntArg(args, "limit");
        const offset_arg = getIntArg(args, "offset");
        const limit = if (limit_arg) |v| try std.fmt.allocPrint(alloc, "{d}", .{v}) else null;
        defer if (limit) |v| alloc.free(v);
        const offset = if (offset_arg) |v| try std.fmt.allocPrint(alloc, "{d}", .{v}) else null;
        defer if (offset) |v| alloc.free(v);
        const data = try routes.handleImplementationChangesResponse(db, since, node_type, repo, limit, offset, alloc);
        if (!data.ok) return error.InvalidArgument;
        defer alloc.free(data.body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data.body, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return .{ .text = try alloc.dupe(u8, data.body) };
        const note = if (limit_arg != null and parsed.value.array.items.len > 0)
            try std.fmt.allocPrint(alloc, "Returned {d} implementation-change rows using file/commit evidence.", .{parsed.value.array.items.len})
        else
            null;
        return .{ .text = try alloc.dupe(u8, data.body), .note = note };
    } else if (std.mem.eql(u8, name, "requirement_trace")) {
        const id = try requireStringArg(args, "id");
        return .{ .text = try requirementTraceMarkdown(id, db, alloc) };
    } else if (std.mem.eql(u8, name, "gap_explanation")) {
        const code = try requireIntArg(args, "code");
        const node_id = try requireStringArg(args, "node_id");
        return .{ .text = try gapExplanationMarkdown(@intCast(code), node_id, db, alloc) };
    } else if (std.mem.eql(u8, name, "impact_summary")) {
        const id = try requireStringArg(args, "id");
        return .{ .text = try impactMarkdown(id, db, alloc) };
    } else if (std.mem.eql(u8, name, "status_summary")) {
        return .{ .text = try statusMarkdown(db, secure_store_ref, state, alloc) };
    } else if (std.mem.eql(u8, name, "review_summary")) {
        return .{ .text = try reviewSummaryMarkdown(db, state, alloc) };
    }
    return error.InvalidArgument;
}

const FilterOpts = struct { suspect_field: bool = false };

fn filteredArrayPayload(data_json: []const u8, args: ?std.json.Value, opts: FilterOpts, alloc: Allocator) !ToolPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return .{ .text = data_json };

    const offset = @max(getIntArg(args, "offset") orelse 0, 0);
    const limit = getIntArg(args, "limit");
    const suspect_only = opts.suspect_field and (getBoolArg(args, "suspect_only") orelse false);

    var filtered: std.ArrayList(std.json.Value) = .empty;
    defer filtered.deinit(alloc);
    for (parsed.value.array.items) |item| {
        if (suspect_only) {
            const suspect = if (json_util.getObjectField(item, "suspect")) |v| switch (v) { .bool => v.bool, else => false } else false;
            if (!suspect) continue;
        }
        try filtered.append(alloc, item);
    }

    var out: std.ArrayList(std.json.Value) = .empty;
    defer out.deinit(alloc);
    const start: usize = @intCast(@min(offset, @as(i64, @intCast(filtered.items.len))));
    const max_count: usize = if (limit) |l| @intCast(@max(l, 0)) else filtered.items.len;
    var i = start;
    while (i < filtered.items.len and out.items.len < max_count) : (i += 1) {
        try out.append(alloc, filtered.items[i]);
    }

    const out_json = try jsonArrayFromValues(out.items, alloc);
    const truncated = limit != null and (start + out.items.len < filtered.items.len);
    if (truncated) {
        const note = try std.fmt.allocPrint(alloc, "Truncated results to {d} of {d} items.", .{ out.items.len, filtered.items.len });
        return .{ .text = out_json, .note = note };
    }
    return .{ .text = out_json };
}

fn filterCodeTraceabilityPayload(data_json: []const u8, args: ?std.json.Value, alloc: Allocator) !ToolPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .text = data_json };
    const repo_filter = if (args) |a| json_util.getString(a, "repo") else null;
    const limit = getIntArg(args, "limit");

    const empty_values = [_]std.json.Value{};
    const src_val = parsed.value.object.get("source_files") orelse std.json.Value{ .array = .{ .items = &empty_values, .capacity = 0, .allocator = alloc } };
    const test_val = parsed.value.object.get("test_files") orelse std.json.Value{ .array = .{ .items = &empty_values, .capacity = 0, .allocator = alloc } };
    var src_out: std.ArrayList(std.json.Value) = .empty;
    defer src_out.deinit(alloc);
    var test_out: std.ArrayList(std.json.Value) = .empty;
    defer test_out.deinit(alloc);

    if (src_val == .array) {
        for (src_val.array.items) |item| {
            if (repo_filter) |repo| if (!nodeMatchesRepo(item, repo)) continue;
            if (limit != null and src_out.items.len >= @as(usize, @intCast(@max(limit.?, 0)))) break;
            try src_out.append(alloc, item);
        }
    }
    if (test_val == .array) {
        for (test_val.array.items) |item| {
            if (repo_filter) |repo| if (!nodeMatchesRepo(item, repo)) continue;
            if (limit != null and test_out.items.len >= @as(usize, @intCast(@max(limit.?, 0)))) break;
            try test_out.append(alloc, item);
        }
    }

    const src_json = try jsonArrayFromValues(src_out.items, alloc);
    defer alloc.free(src_json);
    const test_json = try jsonArrayFromValues(test_out.items, alloc);
    defer alloc.free(test_json);
    const out_json = try std.fmt.allocPrint(alloc, "{{\"source_files\":{s},\"test_files\":{s}}}", .{ src_json, test_json });

    var truncated = false;
    if (limit) |l| {
        if (src_val == .array and src_val.array.items.len > @as(usize, @intCast(@max(l, 0)))) truncated = true;
        if (test_val == .array and test_val.array.items.len > @as(usize, @intCast(@max(l, 0)))) truncated = true;
    }
    if (truncated) {
        const note = try std.fmt.allocPrint(alloc, "Truncated code traceability results to {d} source files and {d} test files.", .{ src_out.items.len, test_out.items.len });
        return .{ .text = out_json, .note = note };
    }
    return .{ .text = out_json };
}

fn chainGapsToolPayload(db: *graph_live.GraphDb, args: ?std.json.Value, alloc: Allocator) !ToolPayload {
    const prof_name = if (args) |a| json_util.getString(a, "profile") else null;
    const pid = if (prof_name) |n| profile_mod.fromString(n) orelse return error.InvalidArgument else null;
    const data = if (pid) |profile_id| blk: {
        const prof = profile_mod.get(profile_id);
        const edge_gaps = try chain_mod.walkChain(db, prof, alloc);
        defer alloc.free(edge_gaps);
        const special_gaps = try chain_mod.walkSpecialGaps(db, prof, alloc);
        defer alloc.free(special_gaps);
        var all: std.ArrayList(chain_mod.Gap) = .empty;
        defer all.deinit(alloc);
        try all.appendSlice(alloc, edge_gaps);
        try all.appendSlice(alloc, special_gaps);
        break :blk try chain_mod.gapsToJson(all.items, alloc);
    } else try routes.handleChainGaps(db, alloc);
    defer alloc.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return .{ .text = try alloc.dupe(u8, data) };
    const severity_filter = if (args) |a| json_util.getString(a, "severity") else null;
    const offset = @max(getIntArg(args, "offset") orelse 0, 0);
    const limit = getIntArg(args, "limit");
    var filtered: std.ArrayList(std.json.Value) = .empty;
    defer filtered.deinit(alloc);
    for (parsed.value.array.items) |item| {
        if (severity_filter) |sev| {
            const item_sev = json_util.getString(item, "severity") orelse continue;
            if (!std.mem.eql(u8, item_sev, sev)) continue;
        }
        try filtered.append(alloc, item);
    }
    var out: std.ArrayList(std.json.Value) = .empty;
    defer out.deinit(alloc);
    const start: usize = @intCast(@min(offset, @as(i64, @intCast(filtered.items.len))));
    const max_count: usize = if (limit) |l| @intCast(@max(l, 0)) else filtered.items.len;
    var i = start;
    while (i < filtered.items.len and out.items.len < max_count) : (i += 1) try out.append(alloc, filtered.items[i]);
    const out_json = try jsonArrayFromValues(out.items, alloc);
    const truncated = limit != null and (start + out.items.len < filtered.items.len);
    if (truncated) {
        const note = try std.fmt.allocPrint(alloc, "Truncated chain gaps to {d} of {d} items.", .{ out.items.len, filtered.items.len });
        return .{ .text = out_json, .note = note };
    }
    return .{ .text = out_json };
}

fn resourcesListResult(db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"resources\":");
    try buf.appendSlice(alloc, resources_json);

    var added_any = false;
    const gaps_json = routes.handleChainGaps(db, arena) catch null;
    if (gaps_json) |gjson| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, gjson, .{});
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            var extras: std.ArrayList(u8) = .empty;
            defer extras.deinit(alloc);
            for (parsed.value.array.items, 0..) |item, idx| {
                if (idx >= 5) break;
                const code = if (json_util.getObjectField(item, "code")) |v| switch (v) { .integer => v.integer, else => 0 } else 0;
                const node_id = json_util.getString(item, "node_id") orelse continue;
                if (idx == 0) try extras.appendSlice(alloc, ",");
                try std.fmt.format(extras.writer(alloc), "{{\"uri\":", .{});
                const gap_uri = try std.fmt.allocPrint(arena, "gap://{d}/{s}", .{ code, node_id });
                try json_util.appendJsonQuoted(&extras, gap_uri, alloc);
                try extras.appendSlice(alloc, ",\"name\":");
                try json_util.appendJsonQuoted(&extras, "Gap Explanation", alloc);
                try extras.appendSlice(alloc, ",\"description\":");
                try json_util.appendJsonQuoted(&extras, json_util.getString(item, "title") orelse "Gap detail", alloc);
                try extras.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
                added_any = true;
            }
            if (added_any) {
                _ = buf.pop();
                try buf.appendSlice(alloc, extras.items);
                try buf.append(alloc, ']');
            }
        }
    }

    const rtm_json = routes.handleRtm(db, arena) catch null;
    if (rtm_json) |rjson| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, rjson, .{});
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            _ = buf.pop();
            for (parsed.value.array.items, 0..) |item, idx| {
                if (idx >= 5) break;
                const req_id = json_util.getString(item, "req_id") orelse continue;
                try buf.append(alloc, ',');
                try buf.appendSlice(alloc, "{\"uri\":");
                const req_uri = try std.fmt.allocPrint(arena, "requirement://{s}", .{req_id});
                try json_util.appendJsonQuoted(&buf, req_uri, alloc);
                try buf.appendSlice(alloc, ",\"name\":");
                try json_util.appendJsonQuoted(&buf, req_id, alloc);
                try buf.appendSlice(alloc, ",\"description\":");
                try json_util.appendJsonQuoted(&buf, json_util.getString(item, "statement") orelse "Requirement trace record", alloc);
                try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
            }
            try buf.append(alloc, ']');
        }
    }

    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn resourceReadResult(uri: []const u8, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) ![]u8 {
    const text = if (std.mem.startsWith(u8, uri, "requirement://"))
        try requirementTraceMarkdown(uri[14..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "user-need://"))
        try nodeMarkdown(uri[12..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "risk://"))
        try nodeMarkdown(uri[7..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "test://"))
        try nodeMarkdown(uri[7..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "test-group://"))
        try nodeMarkdown(uri[13..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "node://"))
        try nodeMarkdown(uri[7..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "impact://"))
        try impactMarkdown(uri[9..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "design-history://"))
        try designHistoryMarkdown(uri[17..], db, alloc)
    else if (std.mem.startsWith(u8, uri, "gap://")) blk: {
        const rest = uri[6..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidArgument;
        const code = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.InvalidArgument;
        break :blk try gapExplanationMarkdown(code, rest[slash + 1 ..], db, alloc);
    } else if (std.mem.eql(u8, uri, "report://status"))
        try statusMarkdown(db, secure_store_ref, state, alloc)
    else if (std.mem.eql(u8, uri, "report://chain-gaps"))
        try chainGapSummaryMarkdown(db, alloc)
    else if (std.mem.eql(u8, uri, "report://rtm"))
        try rtmSummaryMarkdown(db, alloc)
    else if (std.mem.eql(u8, uri, "report://code-traceability"))
        try codeTraceabilitySummaryMarkdown(db, alloc)
    else if (std.mem.eql(u8, uri, "report://review"))
        try reviewSummaryMarkdown(db, state, alloc)
    else
        return error.NotFound;
    defer alloc.free(text);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"contents\":[{\"uri\":");
    try json_util.appendJsonQuoted(&buf, uri, alloc);
    try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\",\"text\":");
    try json_util.appendJsonQuoted(&buf, text, alloc);
    try buf.appendSlice(alloc, "}]}");
    return alloc.dupe(u8, buf.items);
}

fn promptsListResult(alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"prompts\":{s}}}", .{prompts_json});
}

fn promptGetResult(name: []const u8, args: ?std.json.Value, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) ![]u8 {
    _ = db;
    _ = secure_store_ref;
    _ = state;
    const body = if (std.mem.eql(u8, name, "trace_requirement")) blk: {
        const id = try requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc,
            "Trace requirement {s} using RTMify. Read requirement://{s} and design-history://{s}. If needed, call commit_history with req_id={s} and code_traceability. Produce sections: Overview, Upstream Need, Verification, Risks, Code & Commits, Chain Gaps, and Open Questions. Keep the output concise and call out any missing links explicitly.",
            .{ id, id, id, id });
    } else if (std.mem.eql(u8, name, "impact_of_change")) blk: {
        const id = try requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc,
            "Analyze the downstream impact of changing node {s}. Read impact://{s}. If the node is a requirement, also read requirement://{s}. Return: Summary, Directly Impacted Items, Likely Verification Fallout, and Suggested Next Checks. Distinguish real traceability impact from missing-data uncertainty.",
            .{ id, id, id });
    } else if (std.mem.eql(u8, name, "explain_gap")) blk: {
        const code = try requireIntArg(args, "code");
        const node_id = try requireStringArg(args, "node_id");
        break :blk try std.fmt.allocPrint(alloc,
            "Explain RTMify gap {d} for node {s}. Read gap://{d}/{s} and node://{s}. Return sections: What RTMify Checked, Why This Gap Exists, What To Inspect Next, and Likely Resolution. State whether this looks like a real model gap or a data-entry / ingestion issue.",
            .{ code, node_id, code, node_id, node_id });
    } else if (std.mem.eql(u8, name, "audit_readiness_summary")) blk: {
        const profile = try requireStringArg(args, "profile");
        break :blk try std.fmt.allocPrint(alloc,
            "Summarize RTMify audit readiness for the {s} profile. Read report://status and report://chain-gaps. Call chain_gaps with profile={s} if you need detail. Return: Current State, Critical Gaps, Medium Gaps, Evidence Strength, and Top 3 Next Actions.",
            .{ profile, profile });
    } else if (std.mem.eql(u8, name, "repo_coverage_summary")) blk: {
        const repo_note = if (args) |a| json_util.getString(a, "repo") else null;
        if (repo_note) |repo| {
            break :blk try std.fmt.allocPrint(alloc,
                "Summarize repository-backed traceability coverage for repo {s}. Call code_traceability with repo={s}. Also call unimplemented_requirements and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.",
                .{ repo, repo });
        }
        break :blk try alloc.dupe(u8,
            "Summarize repository-backed traceability coverage across all configured repos. Call code_traceability, unimplemented_requirements, and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.");
    } else if (std.mem.eql(u8, name, "design_history_summary")) blk: {
        const req_id = try requireStringArg(args, "req_id");
        break :blk try std.fmt.allocPrint(alloc,
            "Summarize design history for requirement {s}. Read design-history://{s}. Return: Requirement, Upstream Need, Design Inputs/Outputs, Configuration Control, Verification, Commits, and Open Traceability Gaps.",
            .{ req_id, req_id });
    } else return error.NotFound;
    defer alloc.free(body);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"description\":");
    try json_util.appendJsonQuoted(&buf, name, alloc);
    try buf.appendSlice(alloc, ",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
    try json_util.appendJsonQuoted(&buf, body, alloc);
    try buf.appendSlice(alloc, "}}]}");
    return alloc.dupe(u8, buf.items);
}

fn requireStringArg(args: ?std.json.Value, key: []const u8) ![]const u8 {
    return if (args) |a| json_util.getString(a, key) orelse error.InvalidArgument else error.InvalidArgument;
}

fn requireIntArg(args: ?std.json.Value, key: []const u8) !i64 {
    return getIntArg(args, key) orelse error.InvalidArgument;
}

fn getIntArg(args: ?std.json.Value, key: []const u8) ?i64 {
    const field = if (args) |a| json_util.getObjectField(a, key) else null;
    return if (field) |v| switch (v) { .integer => v.integer, else => null } else null;
}

fn getBoolArg(args: ?std.json.Value, key: []const u8) ?bool {
    const field = if (args) |a| json_util.getObjectField(a, key) else null;
    return if (field) |v| switch (v) { .bool => v.bool, else => null } else null;
}

fn nodeMatchesRepo(item: std.json.Value, repo: []const u8) bool {
    const props = json_util.getObjectField(item, "properties") orelse return false;
    const prop_repo = json_util.getString(props, "repo") orelse return false;
    return std.mem.eql(u8, prop_repo, repo);
}

fn jsonArrayFromValues(items: []const std.json.Value, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        const piece = try std.json.Stringify.valueAlloc(alloc, item, .{});
        defer alloc.free(piece);
        try buf.appendSlice(alloc, piece);
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}

fn nodeMarkdown(node_id: []const u8, db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    const data = try routes.handleNode(db, node_id, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const node = json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    return markdownFromNodeDetail(node, json_util.getObjectField(parsed.value, "edges_out"), json_util.getObjectField(parsed.value, "edges_in"), alloc);
}

fn requirementTraceMarkdown(req_id: []const u8, db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleDesignHistory(db, req_id, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    const requirement = json_util.getObjectField(parsed.value, "requirement") orelse return error.NotFound;
    if (requirement == .null) return error.NotFound;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const rid = json_util.getString(requirement, "id") orelse req_id;
    try std.fmt.format(buf.writer(alloc), "# Requirement {s}\n\n", .{rid});
    try appendNodeCoreMarkdown(&buf, requirement, alloc);
    try appendNodeArraySection(&buf, "User Needs", json_util.getObjectField(parsed.value, "user_needs"), alloc);
    try appendNodeArraySection(&buf, "Risks", json_util.getObjectField(parsed.value, "risks"), alloc);
    try appendNodeArraySection(&buf, "Design Inputs", json_util.getObjectField(parsed.value, "design_inputs"), alloc);
    try appendNodeArraySection(&buf, "Design Outputs", json_util.getObjectField(parsed.value, "design_outputs"), alloc);
    try appendNodeArraySection(&buf, "Configuration Items", json_util.getObjectField(parsed.value, "configuration_items"), alloc);
    try appendNodeArraySection(&buf, "Source Files", json_util.getObjectField(parsed.value, "source_files"), alloc);
    try appendNodeArraySection(&buf, "Test Files", json_util.getObjectField(parsed.value, "test_files"), alloc);
    try appendNodeArraySection(&buf, "Commits", json_util.getObjectField(parsed.value, "commits"), alloc);
    try appendGapArraySection(&buf, "Chain Gaps", json_util.getObjectField(parsed.value, "chain_gaps"), alloc);
    return alloc.dupe(u8, buf.items);
}

fn designHistoryMarkdown(req_id: []const u8, db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    return requirementTraceMarkdown(req_id, db, alloc);
}

fn impactMarkdown(node_id: []const u8, db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleImpact(db, node_id, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidArgument;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# Impact Analysis for {s}\n\n", .{node_id});
    try std.fmt.format(buf.writer(alloc), "- Impacted nodes: {d}\n\n", .{parsed.value.array.items.len});
    try buf.appendSlice(alloc, "## Impacted Nodes\n");
    if (parsed.value.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n");
    } else {
        for (parsed.value.array.items) |item| {
            const id = json_util.getString(item, "id") orelse "?";
            const ty = json_util.getString(item, "type") orelse "?";
            const via = json_util.getString(item, "via") orelse "?";
            const dir = json_util.getString(item, "dir") orelse "?";
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) via `{s}` {s}\n", .{ id, ty, via, dir });
        }
    }
    return alloc.dupe(u8, buf.items);
}

fn statusMarkdown(db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var license_service = try license.initDefaultLemonSqueezy(arena, .{});
    const data = try routes.handleStatus(db, secure_store_ref, state, &license_service, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Live Status\n\n");
    try std.fmt.format(buf.writer(alloc), "- Configured: {s}\n", .{boolStr(json_util.getObjectField(parsed.value, "configured"))});
    try std.fmt.format(buf.writer(alloc), "- Platform: {s}\n", .{json_util.getString(parsed.value, "platform") orelse "none"});
    try std.fmt.format(buf.writer(alloc), "- Workbook: {s}\n", .{json_util.getString(parsed.value, "workbook_label") orelse "none"});
    try std.fmt.format(buf.writer(alloc), "- Sync Count: {d}\n", .{getIntField(parsed.value, "sync_count") orelse 0});
    try std.fmt.format(buf.writer(alloc), "- Last Sync At: {d}\n", .{getIntField(parsed.value, "last_sync_at") orelse 0});
    try std.fmt.format(buf.writer(alloc), "- Last Scan At: {s}\n", .{json_util.getString(parsed.value, "last_scan_at") orelse "never"});
    try std.fmt.format(buf.writer(alloc), "- Has Error: {s}\n", .{boolStr(json_util.getObjectField(parsed.value, "has_error"))});
    const err = json_util.getString(parsed.value, "error") orelse "";
    if (err.len > 0) try std.fmt.format(buf.writer(alloc), "- Error: {s}\n", .{err});
    return alloc.dupe(u8, buf.items);
}

fn chainGapSummaryMarkdown(db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleChainGaps(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var err_count: usize = 0;
    var warn_count: usize = 0;
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            const sev = json_util.getString(item, "severity") orelse "info";
            if (std.mem.eql(u8, sev, "err")) err_count += 1 else if (std.mem.eql(u8, sev, "warn")) warn_count += 1;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Chain Gap Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Total gaps: {d}\n- Errors: {d}\n- Warnings: {d}\n\n", .{ if (parsed.value == .array) parsed.value.array.items.len else 0, err_count, warn_count });
    try appendGapArraySection(&buf, "Top Gaps", if (parsed.value == .array) parsed.value else null, alloc);
    return alloc.dupe(u8, buf.items);
}

fn rtmSummaryMarkdown(db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleRtm(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var unique: std.StringHashMap(void) = .init(arena);
    defer unique.deinit();
    var linked_tests: usize = 0;
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            const req_id = json_util.getString(item, "req_id") orelse continue;
            try unique.put(req_id, {});
            if (json_util.getString(item, "test_group_id") != null) linked_tests += 1;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# RTM Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Requirements represented: {d}\n- Rows with linked tests: {d}\n", .{ unique.count(), linked_tests });
    return alloc.dupe(u8, buf.items);
}

fn codeTraceabilitySummaryMarkdown(db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleCodeTraceability(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    const src_count = if (json_util.getObjectField(parsed.value, "source_files")) |v| if (v == .array) v.array.items.len else 0 else 0;
    const test_count = if (json_util.getObjectField(parsed.value, "test_files")) |v| if (v == .array) v.array.items.len else 0 else 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Code Traceability Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Source files: {d}\n- Test files: {d}\n", .{ src_count, test_count });
    return alloc.dupe(u8, buf.items);
}

fn reviewSummaryMarkdown(db: *graph_live.GraphDb, state: *sync_live.SyncState, alloc: Allocator) ![]u8 {
    _ = state;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suspects_json = try routes.handleSuspects(db, arena);
    const gaps_json = try routes.handleChainGaps(db, arena);
    var suspects_parsed = try std.json.parseFromSlice(std.json.Value, arena, suspects_json, .{});
    defer suspects_parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_json, .{});
    defer gaps_parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Review Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Suspect nodes: {d}\n- Chain gaps: {d}\n", .{
        if (suspects_parsed.value == .array) suspects_parsed.value.array.items.len else 0,
        if (gaps_parsed.value == .array) gaps_parsed.value.array.items.len else 0,
    });
    return alloc.dupe(u8, buf.items);
}

fn gapExplanationMarkdown(code: u16, node_id: []const u8, db: *graph_live.GraphDb, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleChainGaps(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.NotFound;
    var found: ?std.json.Value = null;
    for (parsed.value.array.items) |item| {
        const item_code = if (json_util.getObjectField(item, "code")) |v| switch (v) { .integer => v.integer, else => -1 } else -1;
        const item_node = json_util.getString(item, "node_id") orelse continue;
        if (item_code == code and std.mem.eql(u8, item_node, node_id)) {
            found = item;
            break;
        }
    }
    const gap = found orelse return error.NotFound;
    const profile_name = (try db.getConfig("profile", alloc)) orelse try alloc.dupe(u8, "generic");
    defer alloc.free(profile_name);
    return markdownFromGap(gap, profile_name, alloc);
}

fn markdownFromNodeDetail(node: std.json.Value, edges_out: ?std.json.Value, edges_in: ?std.json.Value, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const id = json_util.getString(node, "id") orelse "unknown";
    const ty = json_util.getString(node, "type") orelse "Node";
    try std.fmt.format(buf.writer(alloc), "# {s} {s}\n\n", .{ ty, id });
    try appendNodeCoreMarkdown(&buf, node, alloc);
    try appendEdgeSection(&buf, "Outgoing Links", edges_out, alloc);
    try appendEdgeSection(&buf, "Incoming Links", edges_in, alloc);
    return alloc.dupe(u8, buf.items);
}

fn appendNodeCoreMarkdown(buf: *std.ArrayList(u8), node: std.json.Value, alloc: Allocator) !void {
    const id = json_util.getString(node, "id") orelse "unknown";
    const ty = json_util.getString(node, "type") orelse "Node";
    try std.fmt.format(buf.writer(alloc), "- ID: `{s}`\n- Type: {s}\n", .{ id, ty });
    const suspect = if (json_util.getObjectField(node, "suspect")) |v| switch (v) { .bool => v.bool, else => false } else false;
    try std.fmt.format(buf.writer(alloc), "- Suspect: {s}\n", .{if (suspect) "yes" else "no"});
    const props = json_util.getObjectField(node, "properties");
    if (props) |p| if (p == .object) {
        const statement = json_util.getString(p, "statement");
        const status = json_util.getString(p, "status");
        const description = json_util.getString(p, "description");
        const path = json_util.getString(p, "path");
        const message = json_util.getString(p, "message");
        if (statement) |s| try std.fmt.format(buf.writer(alloc), "- Statement: {s}\n", .{s});
        if (description) |s| try std.fmt.format(buf.writer(alloc), "- Description: {s}\n", .{s});
        if (status) |s| try std.fmt.format(buf.writer(alloc), "- Status: {s}\n", .{s});
        if (path) |s| try std.fmt.format(buf.writer(alloc), "- Path: `{s}`\n", .{s});
        if (message) |s| try std.fmt.format(buf.writer(alloc), "- Message: {s}\n", .{s});
    };
    try buf.append(alloc, '\n');
}

fn appendNodeArraySection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const id = json_util.getString(item, "id") orelse "?";
        const ty = json_util.getString(item, "type") orelse "Node";
        const summary = nodeSummary(item);
        if (summary) |s| {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) — {s}\n", .{ id, ty, s });
        } else {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s})\n", .{ id, ty });
        }
    }
    try buf.append(alloc, '\n');
}

fn appendGapArraySection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const code = getIntField(item, "code") orelse 0;
        const title_val = json_util.getString(item, "title") orelse "Gap";
        const message = json_util.getString(item, "message") orelse "";
        try std.fmt.format(buf.writer(alloc), "- [{d}] {s}: {s}\n", .{ code, title_val, message });
    }
    try buf.append(alloc, '\n');
}

fn appendEdgeSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const label = json_util.getString(item, "label") orelse "";
        const node = json_util.getObjectField(item, "node");
        if (node) |n| {
            const id = json_util.getString(n, "id") orelse "?";
            const ty = json_util.getString(n, "type") orelse "Node";
            try std.fmt.format(buf.writer(alloc), "- `{s}` -> `{s}` ({s})\n", .{ label, id, ty });
        }
    }
    try buf.append(alloc, '\n');
}

fn nodeSummary(node: std.json.Value) ?[]const u8 {
    const props = json_util.getObjectField(node, "properties") orelse return null;
    return json_util.getString(props, "statement") orelse
        json_util.getString(props, "description") orelse
        json_util.getString(props, "path") orelse
        json_util.getString(props, "file_path") orelse
        json_util.getString(props, "message") orelse
        json_util.getString(props, "short_hash");
}

fn markdownFromGap(gap: std.json.Value, profile_name: []const u8, alloc: Allocator) ![]u8 {
    const code = getIntField(gap, "code") orelse 0;
    const title = json_util.getString(gap, "title") orelse "Gap";
    const gap_type = json_util.getString(gap, "gap_type") orelse "gap";
    const node_id = json_util.getString(gap, "node_id") orelse "unknown";
    const severity = json_util.getString(gap, "severity") orelse "info";
    const message = json_util.getString(gap, "message") orelse "";
    const expl = explainGap(gap_type, node_id, profile_name);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# [{d}] {s}\n\n", .{ code, title });
    try std.fmt.format(buf.writer(alloc), "- Node: `{s}`\n- Severity: {s}\n- Profile: {s}\n- Type: `{s}`\n\n", .{ node_id, severity, profile_name, gap_type });
    try std.fmt.format(buf.writer(alloc), "{s}\n\n", .{message});
    try std.fmt.format(buf.writer(alloc), "## What RTMify Checked\n{s}\n\n", .{expl.check});
    try std.fmt.format(buf.writer(alloc), "## Why You’re Seeing It\n{s}\n\n", .{expl.why});
    try std.fmt.format(buf.writer(alloc), "## What To Inspect\n{s}\n", .{expl.inspect});
    return alloc.dupe(u8, buf.items);
}

const GapExplanation = struct { check: []const u8, why: []const u8, inspect: []const u8 };

fn explainGap(gap_type: []const u8, node_id: []const u8, profile_name: []const u8) GapExplanation {
    _ = profile_name;
    if (std.mem.eql(u8, gap_type, "orphan_requirement")) {
        if (std.mem.startsWith(u8, node_id, "UN-")) return .{
            .check = "RTMify looked for downstream Requirements linked to this User Need.",
            .why = "No requirement currently derives from this user need in the graph.",
            .inspect = "Check the Requirements tab for a row whose User Need ID cell contains this exact user-need ID.",
        };
        return .{
            .check = "RTMify checked for the next required edge in the active profile chain.",
            .why = "That expected traceability step is absent in the graph.",
            .inspect = "Open the source tab for this artifact and verify the expected upstream or downstream link is present.",
        };
    }
    if (std.mem.eql(u8, gap_type, "hlr_without_llr")) return .{
        .check = "RTMify identified this requirement as deriving from a User Need, then looked for downstream lower-level Requirements.",
        .why = "It has no downstream lower-level requirements.",
        .inspect = "Add lower-level requirements and REFINED_BY links, or use a less strict profile if you intentionally model one requirement level.",
    };
    if (std.mem.eql(u8, gap_type, "llr_without_source")) return .{
        .check = "RTMify found a decomposed requirement and then looked for current source implementation evidence.",
        .why = "The decomposition exists, but RTMify cannot see code that currently implements this lower-level requirement.",
        .inspect = "Verify repo scanning and code annotations are linking this requirement to the right source files.",
    };
    if (std.mem.eql(u8, gap_type, "unimplemented_requirement")) return .{
        .check = "RTMify looked for current source implementation evidence linked to the requirement.",
        .why = "RTMify cannot see code that currently appears to implement this requirement.",
        .inspect = "Confirm implementation exists and code annotations are linking the requirement to source files.",
    };
    if (std.mem.eql(u8, gap_type, "uncommitted_requirement")) return .{
        .check = "RTMify found current implementation evidence and then looked for commits whose messages explicitly referenced the requirement.",
        .why = "Implementation evidence exists, but no commit message explicitly names this requirement.",
        .inspect = "Check git scan results and whether commit messages were linked to this requirement.",
    };
    if (std.mem.eql(u8, gap_type, "unattributed_annotation")) return .{
        .check = "RTMify found a requirement tag in code and then asked git who last changed that line.",
        .why = "The requirement tag exists, but git did not provide usable blame data for that line.",
        .inspect = "Check git blame availability and whether the file is tracked and readable.",
    };
    if (std.mem.eql(u8, gap_type, "req_without_design_input")) return .{
        .check = "RTMify looked for ALLOCATED_TO from the requirement to a design input.",
        .why = "The requirement is not allocated to any design input.",
        .inspect = "Check the Design Inputs tab and linked requirement IDs.",
    };
    if (std.mem.eql(u8, gap_type, "design_input_without_design_output")) return .{
        .check = "RTMify looked for SATISFIED_BY from the design input to a design output.",
        .why = "The design input is not satisfied by any design output.",
        .inspect = "Check the Design Outputs tab and whether it references this design input.",
    };
    if (std.mem.eql(u8, gap_type, "design_output_without_source")) return .{
        .check = "RTMify looked for current source implementation evidence linked to the design output.",
        .why = "The design output has no source implementation evidence in the current graph.",
        .inspect = "Check repo scanning, code annotations, and design output IDs.",
    };
    if (std.mem.eql(u8, gap_type, "design_output_without_config_control")) return .{
        .check = "RTMify looked for CONTROLLED_BY from the design output to a configuration item.",
        .why = "The design output is not under configuration control in the current graph.",
        .inspect = "Check the Configuration Items tab and linked design output IDs.",
    };
    if (std.mem.eql(u8, gap_type, "source_without_structural_coverage")) return .{
        .check = "RTMify found this source file as current implementation evidence and then looked for current test evidence tied to it.",
        .why = "RTMify can see code that appears to implement the requirement, but it cannot see tests that currently verify that code.",
        .inspect = "Check whether a test file should be linked and whether repo annotations captured it.",
    };
    if (std.mem.eql(u8, gap_type, "missing_asil")) return .{
        .check = "RTMify checked whether the automotive requirement has an asil property.",
        .why = "ASIL is required by the current profile for this requirement.",
        .inspect = "Add or correct the asil property in the requirement row.",
    };
    if (std.mem.eql(u8, gap_type, "asil_inheritance")) return .{
        .check = "RTMify compared parent and child ASIL values across REFINED_BY edges.",
        .why = "A child requirement appears to have a lower ASIL than its parent.",
        .inspect = "Verify the intended safety allocation and the asil values on both requirements.",
    };
    return .{
        .check = "RTMify evaluated a profile-specific traceability rule.",
        .why = "The required relationship or property is missing or inconsistent.",
        .inspect = "Inspect the related node and its upstream/downstream links in the relevant sheet tabs.",
    };
}

fn getIntField(value: std.json.Value, key: []const u8) ?i64 {
    const field = json_util.getObjectField(value, key) orelse return null;
    return switch (field) { .integer => field.integer, else => null };
}

fn boolStr(v: ?std.json.Value) []const u8 {
    if (v) |val| switch (val) { .bool => return if (val.bool) "true" else "false", else => {} };
    return "false";
}

fn sendResult(req: *std.http.Server.Request, id_raw: []const u8, result_json: []const u8, alloc: Allocator) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_raw, result_json });
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

fn sendToolPayload(req: *std.http.Server.Request, id_raw: []const u8, payload: ToolPayload, alloc: Allocator) !void {
    var text_escaped: std.ArrayList(u8) = .empty;
    defer text_escaped.deinit(alloc);
    try json_util.appendJsonEscaped(&text_escaped, payload.text, alloc);
    var note_part: []const u8 = "";
    var note_owned: ?[]u8 = null;
    defer if (note_owned) |n| alloc.free(n);
    if (payload.note) |note| {
        var note_escaped: std.ArrayList(u8) = .empty;
        defer note_escaped.deinit(alloc);
        try json_util.appendJsonEscaped(&note_escaped, note, alloc);
        note_owned = try std.fmt.allocPrint(alloc, ",{{\"type\":\"text\",\"text\":\"{s}\"}}", .{note_escaped.items});
        note_part = note_owned.?;
    }
    const resp = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}{s}]}}}}",
        .{ id_raw, text_escaped.items, note_part },
    );
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

fn sendError(req: *std.http.Server.Request, id_raw: []const u8, code: i32, message: []const u8, alloc: Allocator) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id_raw, code, message });
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

const testing = std.testing;

fn parseJsonForTest(json: []const u8, alloc: Allocator) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

test "json rpc parsing tolerates whitespace after colon" {
    var parsed = try parseJsonForTest("{\"jsonrpc\" : \"2.0\", \"method\" : \"tools/call\", \"id\" : 1}", testing.allocator);
    defer parsed.deinit();
    try testing.expectEqualStrings("2.0", json_util.getString(parsed.value, "jsonrpc").?);
    try testing.expectEqualStrings("tools/call", json_util.getString(parsed.value, "method").?);
}

test "json rpc id serialization tolerates whitespace around field" {
    var parsed = try parseJsonForTest("{\"jsonrpc\":\"2.0\", \"id\" : 42, \"method\":\"ping\"}", testing.allocator);
    defer parsed.deinit();
    const id_value = json_util.getObjectField(parsed.value, "id").?;
    const id_raw = try std.json.Stringify.valueAlloc(testing.allocator, id_value, .{});
    defer testing.allocator.free(id_raw);
    try testing.expectEqualStrings("42", id_raw);
}

test "json rpc id string serialization preserves raw JSON string" {
    var parsed = try parseJsonForTest("{\"jsonrpc\":\"2.0\", \"id\" : \"req-1\", \"method\":\"ping\"}", testing.allocator);
    defer parsed.deinit();
    const id_value = json_util.getObjectField(parsed.value, "id").?;
    const id_raw = try std.json.Stringify.valueAlloc(testing.allocator, id_value, .{});
    defer testing.allocator.free(id_raw);
    try testing.expectEqualStrings("\"req-1\"", id_raw);
}

test "json rpc notification detection tolerates legal spacing" {
    var parsed = try parseJsonForTest("{\"method\" : \"notifications/initialized\"}", testing.allocator);
    defer parsed.deinit();
    try testing.expect(json_util.getObjectField(parsed.value, "id") == null);
}

test "resources list returns curated resources" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", null);
    const resp = try resourcesListResult(&db, testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "report://status") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "requirement://REQ-001") != null);
}

test "resources read returns requirement markdown" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\",\"status\":\"Approved\"}", null);
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    const resp = try resourceReadResult("requirement://REQ-001", &db, &store, &state, testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Requirement REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "User Needs") != null);
}

test "resources read returns impact markdown" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    const resp = try resourceReadResult("impact://UN-001", &db, &store, &state, testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Impact Analysis for UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
}

test "resources read returns gap markdown" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.storeConfig("profile", "aerospace");
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    const resp = try resourceReadResult("gap://1203/REQ-001", &db, &store, &state, testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "What RTMify Checked") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
}

test "resources read invalid uri returns error" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    try testing.expectError(error.NotFound, resourceReadResult("unknown://x", &db, &store, &state, testing.allocator));
}

test "prompts list returns expected names" {
    const resp = try promptsListResult(testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "trace_requirement") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "impact_of_change") != null);
}

test "prompts get interpolates arguments" {
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("id", .{ .string = "REQ-001" });
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    const resp = try promptGetResult("trace_requirement", .{ .object = args_obj }, &db, &store, &state, testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "design-history://REQ-001") != null);
}

test "tools list contains legacy and new tools" {
    try testing.expect(std.mem.indexOf(u8, tools_json, "get_rtm") != null);
    try testing.expect(std.mem.indexOf(u8, tools_json, "requirement_trace") != null);
    try testing.expect(std.mem.indexOf(u8, tools_json, "gap_explanation") != null);
    try testing.expect(std.mem.indexOf(u8, tools_json, "implementation_changes_since") != null);
}

test "mcp headers do not advertise wildcard cors" {
    for (json_rpc_headers) |header| {
        try testing.expect(!std.ascii.eqlIgnoreCase(header.name, "Access-Control-Allow-Origin"));
    }
}

test "large output tools honor limit with truncation note" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"One\",\"status\":\"Approved\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Two\",\"status\":\"Approved\"}", null);
    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("limit", .{ .integer = 1 });
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    const payload = try buildToolPayload("get_rtm", .{ .object = args_obj }, &db, &store, &state, testing.allocator);
    defer payload.deinit(testing.allocator);
    try testing.expect(payload.note != null);
    try testing.expect(std.mem.indexOf(u8, payload.text, "REQ-001") != null or std.mem.indexOf(u8, payload.text, "REQ-002") != null);
}

test "implementation changes tool returns bounded rows" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("src/foo.c", "SourceFile", "{\"repo\":\"/repo\",\"present\":true}", null);
    try db.addNode("commit-1", "Commit", "{\"short_hash\":\"abc1234\",\"date\":\"2026-03-06T12:30:00Z\",\"message\":\"refactor\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("REQ-001", "src/foo.c", "IMPLEMENTED_IN");
    try db.addEdge("src/foo.c", "commit-1", "CHANGED_IN");
    try db.addEdge("commit-1", "src/foo.c", "CHANGES");

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("since", .{ .string = "2026-03-05T00:00:00Z" });
    try args_obj.put("node_type", .{ .string = "Requirement" });
    try args_obj.put("limit", .{ .integer = 1 });

    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    const payload = try buildToolPayload("implementation_changes_since", .{ .object = args_obj }, &db, &store, &state, testing.allocator);
    defer payload.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"node_id\":\"REQ-001\"") != null);
    try testing.expect(payload.note != null);
}
