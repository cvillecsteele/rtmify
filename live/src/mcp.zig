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
const test_results = @import("test_results.zig");
const bom = @import("bom.zig");
const workbook = @import("workbook/mod.zig");

const ToolPayload = struct {
    text: []const u8,
    note: ?[]const u8 = null,
    structured_json: ?[]const u8 = null,
    structured_aliases_text: bool = false,
    pub fn deinit(self: ToolPayload, alloc: Allocator) void {
        alloc.free(self.text);
        if (self.note) |n| alloc.free(n);
        if (self.structured_json) |json| {
            if (!self.structured_aliases_text) alloc.free(json);
        }
    }
};

const ToolDispatch = union(enum) {
    payload: ToolPayload,
    invalid_arguments: []const u8,
    not_found: void,

    pub fn deinit(self: ToolDispatch, alloc: Allocator) void {
        switch (self) {
            .payload => |payload| payload.deinit(alloc),
            .invalid_arguments => |msg| alloc.free(msg),
            .not_found => {},
        }
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
    \\{"name":"get_rtm","description":"Get the Requirements Traceability Matrix. Optional limit/offset and suspect-only filtering.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"},"suspect_only":{"type":"boolean"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_gaps","description":"Get requirements with no test linked. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_suspects","description":"Get all suspect nodes. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_nodes","description":"Get graph nodes, optionally filtered by type. Supports limit and offset.","inputSchema":{"type":"object","properties":{"type":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_node","description":"Get a single node by ID. Set include_edges or include_properties to false to omit those sections from the result.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"include_edges":{"type":"boolean","default":true},"include_properties":{"type":"boolean","default":true}},"required":["id"]},"outputSchema":{"type":"object"}},
    \\{"name":"search","description":"Full-text search across node IDs and properties. Supports limit.","inputSchema":{"type":"object","properties":{"q":{"type":"string"},"limit":{"type":"integer"}},"required":["q"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_user_needs","description":"Get User Need nodes. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_tests","description":"Get Test nodes with linked requirements. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_risks","description":"Get the risk register. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_impact","description":"Get impact analysis for a node.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_schema","description":"Get the graph schema: node types, edge labels, and meanings.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"get_status","description":"Get sync state, connection, and license status.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"clear_suspect","description":"Mark a suspect node as reviewed.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},"outputSchema":{"type":"object"}},
    \\{"name":"code_traceability","description":"Source and test files with annotation counts. Supports repo and limit.","inputSchema":{"type":"object","properties":{"repo":{"type":"string"},"limit":{"type":"integer"}},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"unimplemented_requirements","description":"Requirements with no IMPLEMENTED_IN edge.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"untested_source_files","description":"Source files with no VERIFIED_BY_CODE edge.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"file_annotations","description":"Code annotations found in a specific source file.","inputSchema":{"type":"object","properties":{"file_path":{"type":"string"},"limit":{"type":"integer"}},"required":["file_path"]},"outputSchema":{"type":"array"}},
    \\{"name":"blame_for_requirement","description":"Code annotations with blame data linked to a requirement.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"},"limit":{"type":"integer"}},"required":["req_id"]},"outputSchema":{"type":"array"}},
    \\{"name":"commit_history","description":"Commits linked to a requirement via COMMITTED_IN edges. Supports limit.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"},"limit":{"type":"integer"}},"required":["req_id"]},"outputSchema":{"type":"array"}},
    \\{"name":"design_history","description":"Full upstream/downstream chain for a requirement.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"}},"required":["req_id"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_test_results","description":"Get ingested test results for a test case, newest first.","inputSchema":{"type":"object","properties":{"test_case_ref":{"type":"string"}},"required":["test_case_ref"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_execution","description":"Get a stored test execution by execution_id.","inputSchema":{"type":"object","properties":{"execution_id":{"type":"string"}},"required":["execution_id"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_verification_status","description":"Get verification rollup and latest results for a requirement.","inputSchema":{"type":"object","properties":{"requirement_ref":{"type":"string"}},"required":["requirement_ref"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_dangling_results","description":"Get ingested test results that do not resolve to a known Test node.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_unit_history","description":"Get test execution history for a serial number, newest first.","inputSchema":{"type":"object","properties":{"serial_number":{"type":"string"}},"required":["serial_number"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_bom","description":"Get BOM trees for a product, optionally filtered by bom_type or bom_name.","inputSchema":{"type":"object","properties":{"full_product_identifier":{"type":"string"},"bom_type":{"type":"string","enum":["hardware","software"]},"bom_name":{"type":"string"}},"required":["full_product_identifier"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_bom_item","description":"Get a single BOM item and its parent chains.","inputSchema":{"oneOf":[{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},{"type":"object","properties":{"full_product_identifier":{"type":"string"},"bom_type":{"type":"string","enum":["hardware","software"]},"bom_name":{"type":"string"},"part":{"type":"string"},"revision":{"type":"string"}},"required":["full_product_identifier","bom_type","bom_name","part","revision"]}]},"outputSchema":{"type":"object"}},
    \\{"name":"get_product_serials","description":"Get serial-bearing test executions scoped to a product.","inputSchema":{"type":"object","properties":{"full_product_identifier":{"type":"string"}},"required":["full_product_identifier"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_components_by_supplier","description":"Get BOM components linked through CONTAINS edges with a matching supplier.","inputSchema":{"type":"object","properties":{"supplier":{"type":"string"}},"required":["supplier"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_software_components","description":"Get software BOM components, optionally filtered by purl prefix or license.","inputSchema":{"type":"object","properties":{"purl_prefix":{"type":"string"},"license":{"type":"string"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"chain_gaps","description":"Traceability chain gaps for the active or requested industry profile. Supports severity, profile, limit, and offset.","inputSchema":{"type":"object","properties":{"profile":{"type":"string"},"severity":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"implementation_changes_since","description":"Find requirements or user needs whose implementation files changed since an ISO timestamp. This uses file/commit history, not explicit COMMITTED_IN message references. Supports repo, limit, and offset.","inputSchema":{"type":"object","properties":{"since":{"type":"string"},"node_type":{"type":"string","enum":["Requirement","UserNeed"]},"repo":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":["since","node_type"]},"outputSchema":{"type":"array"}},
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

pub fn handleSse(req: *std.http.Server.Request, registry: *workbook.registry.WorkbookRegistry, secure_store_ref: *secure_store.Store, alloc: Allocator) !void {
    _ = registry;
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
    registry: *workbook.registry.WorkbookRegistry,
    secure_store_ref: *secure_store.Store,
    state: *sync_live.SyncState,
    alloc: Allocator,
) !void {
    const active_runtime = try registry.active();
    const db = &active_runtime.db;
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
        try dispatchToolCall(req, root, id_raw, registry, db, secure_store_ref, state, active_runtime.config.profile, alloc);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        const result = try resourcesListResult(db, alloc);
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        try dispatchResourceRead(req, root, id_raw, registry, db, secure_store_ref, state, active_runtime.config.profile, alloc);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        const result = try promptsListResult(alloc);
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        try dispatchPromptGet(req, root, id_raw, registry, db, secure_store_ref, state, active_runtime.config.profile, alloc);
    } else {
        try sendError(req, id_raw, -32601, "Method not found", alloc);
    }
}

fn dispatchToolCall(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, profile_name: []const u8, alloc: Allocator) !void {
    const params = json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", alloc);
    const name = json_util.getString(params, "name") orelse return sendError(req, id_raw, -32602, "Missing tool name", alloc);
    const args = json_util.getObjectField(params, "arguments");
    const dispatch = buildToolPayload(name, args, registry, db, secure_store_ref, state, profile_name, alloc) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Not found", alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid arguments", alloc),
        else => return e,
    };
    defer dispatch.deinit(alloc);
    switch (dispatch) {
        .payload => |payload| try sendToolPayload(req, id_raw, payload, alloc),
        .invalid_arguments => |msg| try sendError(req, id_raw, -32602, msg, alloc),
        .not_found => try sendError(req, id_raw, -32004, "Not found", alloc),
    }
}

fn dispatchResourceRead(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, profile_name: []const u8, alloc: Allocator) !void {
    const params = json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", alloc);
    const uri = json_util.getString(params, "uri") orelse return sendError(req, id_raw, -32602, "Missing uri", alloc);
    const result = resourceReadResult(uri, registry, db, secure_store_ref, state, profile_name, alloc) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Resource not found", alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid resource URI", alloc),
        else => return e,
    };
    defer alloc.free(result);
    try sendResult(req, id_raw, result, alloc);
}

fn dispatchPromptGet(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, profile_name: []const u8, alloc: Allocator) !void {
    const params = json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", alloc);
    const name = json_util.getString(params, "name") orelse return sendError(req, id_raw, -32602, "Missing prompt name", alloc);
    const args = json_util.getObjectField(params, "arguments");
    const result = promptGetResult(name, args, registry, db, secure_store_ref, state, profile_name, alloc) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Prompt not found", alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid prompt arguments", alloc),
        else => return e,
    };
    defer alloc.free(result);
    try sendResult(req, id_raw, result, alloc);
}

fn invalidArgumentsDispatch(message: []const u8, alloc: Allocator) !ToolDispatch {
    return .{ .invalid_arguments = try alloc.dupe(u8, message) };
}

fn jsonPayloadOwned(json: []const u8) ToolPayload {
    return .{
        .text = json,
        .structured_json = json,
        .structured_aliases_text = true,
    };
}

fn jsonPayloadOwnedWithNote(json: []const u8, note: ?[]const u8) ToolPayload {
    return .{
        .text = json,
        .note = note,
        .structured_json = json,
        .structured_aliases_text = true,
    };
}

fn textPayloadOwned(text: []const u8) ToolPayload {
    return .{ .text = text };
}

fn buildToolPayload(name: []const u8, args: ?std.json.Value, registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, profile_name: []const u8, alloc: Allocator) !ToolDispatch {
    if (std.mem.eql(u8, name, "get_rtm")) {
        const data = try routes.handleRtm(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{ .suspect_field = true }, alloc) };
    } else if (std.mem.eql(u8, name, "get_gaps")) {
        const data = try routes.handleGaps(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_suspects")) {
        const data = try routes.handleSuspects(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_nodes")) {
        const type_filter = if (args) |a| json_util.getString(a, "type") else null;
        const data = try routes.handleNodes(db, type_filter, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_node")) {
        const node_id = if (args) |a| json_util.getString(a, "id") else null;
        if (node_id == null) return invalidArgumentsDispatch("get_node requires 'id'", alloc);
        const include_edges = getBoolArg(args, "include_edges") orelse true;
        const include_properties = getBoolArg(args, "include_properties") orelse true;
        const data = try routes.handleNode(db, node_id.?, alloc);
        return .{ .payload = try filterNodePayload(data, include_edges, include_properties, alloc) };
    } else if (std.mem.eql(u8, name, "search")) {
        const q = try requireStringArg(args, "q");
        const data = try routes.handleSearch(db, q, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_user_needs")) {
        const data = try routes.handleUserNeeds(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_tests")) {
        const data = try routes.handleTests(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_risks")) {
        const data = try routes.handleRisks(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_impact")) {
        const node_id = try requireStringArg(args, "id");
        const data = try routes.handleImpact(db, node_id, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "get_schema")) {
        const data = try routes.handleSchema(db, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "get_status")) {
        var license_service = try license.initDefaultHmacFile(alloc, .{
            .product = .live,
            .trial_policy = .requires_license,
        });
        defer license_service.deinit(alloc);
        const data = try routes.handleStatus(registry, secure_store_ref, state, &license_service, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "clear_suspect")) {
        const node_id = try requireStringArg(args, "id");
        const data = try routes.handleClearSuspect(db, node_id, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "code_traceability")) {
        const data = try routes.handleCodeTraceability(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filterCodeTraceabilityPayload(data, args, alloc) };
    } else if (std.mem.eql(u8, name, "unimplemented_requirements")) {
        const data = try routes.handleUnimplementedRequirements(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "untested_source_files")) {
        const data = try routes.handleUntestedSourceFiles(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "file_annotations")) {
        const file_path = try requireStringArg(args, "file_path");
        const data = try routes.handleFileAnnotations(db, file_path, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "blame_for_requirement")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try routes.handleBlameForRequirement(db, req_id, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "commit_history")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try routes.handleCommitHistory(db, req_id, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "design_history")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try routes.handleDesignHistory(db, profile_name, req_id, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "get_test_results")) {
        const test_case_ref = try requireStringArg(args, "test_case_ref");
        return .{ .payload = jsonPayloadOwned(try test_results.getTestResultsJson(db, test_case_ref, alloc)) };
    } else if (std.mem.eql(u8, name, "get_execution")) {
        const execution_id = try requireStringArg(args, "execution_id");
        const data = try test_results.getExecutionJson(db, execution_id, alloc);
        return .{ .payload = jsonPayloadOwned(if (data) |value| value else try alloc.dupe(u8, "{\"error\":\"not_found\"}")) };
    } else if (std.mem.eql(u8, name, "get_verification_status")) {
        const requirement_ref = try requireStringArg(args, "requirement_ref");
        return .{ .payload = jsonPayloadOwned(try test_results.verificationJson(db, requirement_ref, alloc)) };
    } else if (std.mem.eql(u8, name, "get_dangling_results")) {
        return .{ .payload = jsonPayloadOwned(try test_results.danglingResultsJson(db, alloc)) };
    } else if (std.mem.eql(u8, name, "get_unit_history")) {
        const serial_number = try requireStringArg(args, "serial_number");
        return .{ .payload = jsonPayloadOwned(try test_results.unitHistoryJson(db, serial_number, alloc)) };
    } else if (std.mem.eql(u8, name, "get_bom")) {
        const full_product_identifier = try requireStringArg(args, "full_product_identifier");
        const bom_type = if (args) |a| json_util.getString(a, "bom_type") else null;
        const bom_name = if (args) |a| json_util.getString(a, "bom_name") else null;
        return .{ .payload = jsonPayloadOwned(try bom.getBomJson(db, full_product_identifier, bom_type, bom_name, alloc)) };
    } else if (std.mem.eql(u8, name, "get_bom_item")) {
        const item_id = if (args) |a| blk: {
            if (json_util.getString(a, "id")) |value| break :blk try alloc.dupe(u8, value);
            const full_product_identifier = json_util.getString(a, "full_product_identifier") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const bom_type = json_util.getString(a, "bom_type") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const bom_name = json_util.getString(a, "bom_name") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const part = json_util.getString(a, "part") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const revision = json_util.getString(a, "revision") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            break :blk try std.fmt.allocPrint(alloc, "bom-item://{s}/{s}/{s}/{s}@{s}", .{
                full_product_identifier,
                bom_type,
                bom_name,
                part,
                revision,
            });
        } else return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
        defer alloc.free(item_id);
        return .{ .payload = jsonPayloadOwned(try bom.getBomItemJson(db, item_id, alloc)) };
    } else if (std.mem.eql(u8, name, "get_product_serials")) {
        const full_product_identifier = try requireStringArg(args, "full_product_identifier");
        return .{ .payload = jsonPayloadOwned(try bom.getProductSerialsJson(db, full_product_identifier, alloc)) };
    } else if (std.mem.eql(u8, name, "get_components_by_supplier")) {
        const supplier = try requireStringArg(args, "supplier");
        return .{ .payload = jsonPayloadOwned(try bom.getComponentsBySupplierJson(db, supplier, alloc)) };
    } else if (std.mem.eql(u8, name, "get_software_components")) {
        const purl_prefix = if (args) |a| json_util.getString(a, "purl_prefix") else null;
        const license_filter = if (args) |a| json_util.getString(a, "license") else null;
        return .{ .payload = jsonPayloadOwned(try bom.getSoftwareComponentsJson(db, purl_prefix, license_filter, alloc)) };
    } else if (std.mem.eql(u8, name, "chain_gaps")) {
        return .{ .payload = try chainGapsToolPayload(db, args, alloc) };
    } else if (std.mem.eql(u8, name, "implementation_changes_since")) {
        const since = if (args) |a| json_util.getString(a, "since") else null;
        const node_type = if (args) |a| json_util.getString(a, "node_type") else null;
        if (since == null or node_type == null) return invalidArgumentsDispatch("implementation_changes_since requires 'since' and 'node_type'", alloc);
        const repo = if (args) |a| json_util.getString(a, "repo") else null;
        const limit_arg = getIntArg(args, "limit");
        const offset_arg = getIntArg(args, "offset");
        const limit = if (limit_arg) |v| try std.fmt.allocPrint(alloc, "{d}", .{v}) else null;
        defer if (limit) |v| alloc.free(v);
        const offset = if (offset_arg) |v| try std.fmt.allocPrint(alloc, "{d}", .{v}) else null;
        defer if (offset) |v| alloc.free(v);
        const data = try routes.handleImplementationChangesResponse(db, since.?, node_type.?, repo, limit, offset, alloc);
        if (!data.ok) return invalidArgumentsDispatch("implementation_changes_since requires 'since' and 'node_type'", alloc);
        defer alloc.free(data.body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data.body, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return .{ .payload = jsonPayloadOwned(try alloc.dupe(u8, data.body)) };
        const note = if (limit_arg != null and parsed.value.array.items.len > 0)
            try std.fmt.allocPrint(alloc, "Returned {d} implementation-change rows using file/commit evidence.", .{parsed.value.array.items.len})
        else
            null;
        return .{ .payload = jsonPayloadOwnedWithNote(try alloc.dupe(u8, data.body), note) };
    } else if (std.mem.eql(u8, name, "requirement_trace")) {
        const id = try requireStringArg(args, "id");
        return .{ .payload = textPayloadOwned(try requirementTraceMarkdown(id, db, profile_name, alloc)) };
    } else if (std.mem.eql(u8, name, "gap_explanation")) {
        const code = try requireIntArg(args, "code");
        const node_id = try requireStringArg(args, "node_id");
        return .{ .payload = textPayloadOwned(try gapExplanationMarkdown(@intCast(code), node_id, db, profile_name, alloc)) };
    } else if (std.mem.eql(u8, name, "impact_summary")) {
        const id = try requireStringArg(args, "id");
        return .{ .payload = textPayloadOwned(try impactMarkdown(id, db, alloc)) };
    } else if (std.mem.eql(u8, name, "status_summary")) {
        return .{ .payload = textPayloadOwned(try statusMarkdown(registry, secure_store_ref, state, alloc)) };
    } else if (std.mem.eql(u8, name, "review_summary")) {
        return .{ .payload = textPayloadOwned(try reviewSummaryMarkdown(db, profile_name, state, alloc)) };
    }
    return .{ .not_found = {} };
}

const FilterOpts = struct { suspect_field: bool = false };

fn filteredArrayPayload(data_json: []const u8, args: ?std.json.Value, opts: FilterOpts, alloc: Allocator) !ToolPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return jsonPayloadOwned(try alloc.dupe(u8, data_json));

    const offset = @max(getIntArg(args, "offset") orelse 0, 0);
    const limit = getIntArg(args, "limit");
    const suspect_only = opts.suspect_field and (getBoolArg(args, "suspect_only") orelse false);

    var filtered: std.ArrayList(std.json.Value) = .empty;
    defer filtered.deinit(alloc);
    for (parsed.value.array.items) |item| {
        if (suspect_only) {
            const suspect = if (json_util.getObjectField(item, "suspect")) |v| switch (v) {
                .bool => v.bool,
                else => false,
            } else false;
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
        return jsonPayloadOwnedWithNote(out_json, note);
    }
    return jsonPayloadOwned(out_json);
}

fn filterNodePayload(data_json: []const u8, include_edges: bool, include_properties: bool, alloc: Allocator) !ToolPayload {
    if (include_edges and include_properties) return jsonPayloadOwned(data_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return jsonPayloadOwned(data_json);

    const node = json_util.getObjectField(parsed.value, "node") orelse return jsonPayloadOwned(data_json);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"node\":{\"id\":");
    try json_util.appendJsonQuoted(&buf, json_util.getString(node, "id") orelse "unknown", alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try json_util.appendJsonQuoted(&buf, json_util.getString(node, "type") orelse "Node", alloc);
    if (include_properties) {
        const properties = json_util.getObjectField(node, "properties") orelse std.json.Value{ .null = {} };
        try buf.appendSlice(alloc, ",\"properties\":");
        try appendJsonValue(&buf, properties, alloc);
    }
    const suspect = if (json_util.getObjectField(node, "suspect")) |v| switch (v) {
        .bool => v.bool,
        else => false,
    } else false;
    try buf.appendSlice(alloc, ",\"suspect\":");
    try buf.appendSlice(alloc, if (suspect) "true" else "false");
    const suspect_reason = json_util.getObjectField(node, "suspect_reason") orelse std.json.Value{ .null = {} };
    try buf.appendSlice(alloc, ",\"suspect_reason\":");
    try appendJsonValue(&buf, suspect_reason, alloc);
    try buf.append(alloc, '}');
    if (include_edges) {
        const empty_values = [_]std.json.Value{};
        const empty_array = std.json.Value{ .array = .{ .items = &empty_values, .capacity = 0, .allocator = alloc } };
        try buf.appendSlice(alloc, ",\"edges_out\":");
        try appendJsonValue(&buf, json_util.getObjectField(parsed.value, "edges_out") orelse empty_array, alloc);
        try buf.appendSlice(alloc, ",\"edges_in\":");
        try appendJsonValue(&buf, json_util.getObjectField(parsed.value, "edges_in") orelse empty_array, alloc);
    }
    try buf.append(alloc, '}');
    alloc.free(data_json);
    return jsonPayloadOwned(try alloc.dupe(u8, buf.items));
}

fn filterCodeTraceabilityPayload(data_json: []const u8, args: ?std.json.Value, alloc: Allocator) !ToolPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return jsonPayloadOwned(try alloc.dupe(u8, data_json));
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
        return jsonPayloadOwnedWithNote(out_json, note);
    }
    return jsonPayloadOwned(out_json);
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
    } else try routes.handleChainGaps(db, prof_name orelse "generic", alloc);
    defer alloc.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return jsonPayloadOwned(try alloc.dupe(u8, data));
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
        return jsonPayloadOwnedWithNote(out_json, note);
    }
    return jsonPayloadOwned(out_json);
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
    const gaps_json = routes.handleChainGaps(db, "generic", arena) catch null;
    if (gaps_json) |gjson| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, gjson, .{});
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            var extras: std.ArrayList(u8) = .empty;
            defer extras.deinit(alloc);
            for (parsed.value.array.items, 0..) |item, idx| {
                if (idx >= 5) break;
                const code = if (json_util.getObjectField(item, "code")) |v| switch (v) {
                    .integer => v.integer,
                    else => 0,
                } else 0;
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

fn resourceReadResult(uri: []const u8, registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, profile_name: []const u8, alloc: Allocator) ![]u8 {
    const text = if (std.mem.startsWith(u8, uri, "requirement://"))
        try requirementTraceMarkdown(uri[14..], db, profile_name, alloc)
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
        try designHistoryMarkdown(uri[17..], db, profile_name, alloc)
    else if (std.mem.startsWith(u8, uri, "gap://")) blk: {
        const rest = uri[6..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidArgument;
        const code = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.InvalidArgument;
        break :blk try gapExplanationMarkdown(code, rest[slash + 1 ..], db, profile_name, alloc);
    } else if (std.mem.eql(u8, uri, "report://status"))
        try statusMarkdown(registry, secure_store_ref, state, alloc)
    else if (std.mem.eql(u8, uri, "report://chain-gaps"))
        try chainGapSummaryMarkdown(db, profile_name, alloc)
    else if (std.mem.eql(u8, uri, "report://rtm"))
        try rtmSummaryMarkdown(db, alloc)
    else if (std.mem.eql(u8, uri, "report://code-traceability"))
        try codeTraceabilitySummaryMarkdown(db, alloc)
    else if (std.mem.eql(u8, uri, "report://review"))
        try reviewSummaryMarkdown(db, profile_name, state, alloc)
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

fn promptGetResult(name: []const u8, args: ?std.json.Value, registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, profile_name: []const u8, alloc: Allocator) ![]u8 {
    _ = db;
    _ = secure_store_ref;
    _ = state;
    _ = registry;
    _ = profile_name;
    const body = if (std.mem.eql(u8, name, "trace_requirement")) blk: {
        const id = try requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Trace requirement {s} using RTMify. Read requirement://{s} and design-history://{s}. If needed, call commit_history with req_id={s} and code_traceability. Produce sections: Overview, Upstream Need, Verification, Risks, Code & Commits, Chain Gaps, and Open Questions. Keep the output concise and call out any missing links explicitly.", .{ id, id, id, id });
    } else if (std.mem.eql(u8, name, "impact_of_change")) blk: {
        const id = try requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Analyze the downstream impact of changing node {s}. Read impact://{s}. If the node is a requirement, also read requirement://{s}. Return: Summary, Directly Impacted Items, Likely Verification Fallout, and Suggested Next Checks. Distinguish real traceability impact from missing-data uncertainty.", .{ id, id, id });
    } else if (std.mem.eql(u8, name, "explain_gap")) blk: {
        const code = try requireIntArg(args, "code");
        const node_id = try requireStringArg(args, "node_id");
        break :blk try std.fmt.allocPrint(alloc, "Explain RTMify gap {d} for node {s}. Read gap://{d}/{s} and node://{s}. Return sections: What RTMify Checked, Why This Gap Exists, What To Inspect Next, and Likely Resolution. State whether this looks like a real model gap or a data-entry / ingestion issue.", .{ code, node_id, code, node_id, node_id });
    } else if (std.mem.eql(u8, name, "audit_readiness_summary")) blk: {
        const profile = try requireStringArg(args, "profile");
        break :blk try std.fmt.allocPrint(alloc, "Summarize RTMify audit readiness for the {s} profile. Read report://status and report://chain-gaps. Call chain_gaps with profile={s} if you need detail. Return: Current State, Critical Gaps, Medium Gaps, Evidence Strength, and Top 3 Next Actions.", .{ profile, profile });
    } else if (std.mem.eql(u8, name, "repo_coverage_summary")) blk: {
        const repo_note = if (args) |a| json_util.getString(a, "repo") else null;
        if (repo_note) |repo| {
            break :blk try std.fmt.allocPrint(alloc, "Summarize repository-backed traceability coverage for repo {s}. Call code_traceability with repo={s}. Also call unimplemented_requirements and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.", .{ repo, repo });
        }
        break :blk try alloc.dupe(u8, "Summarize repository-backed traceability coverage across all configured repos. Call code_traceability, unimplemented_requirements, and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.");
    } else if (std.mem.eql(u8, name, "design_history_summary")) blk: {
        const req_id = try requireStringArg(args, "req_id");
        break :blk try std.fmt.allocPrint(alloc, "Summarize design history for requirement {s}. Read design-history://{s}. Return: Requirement, Upstream Need, Design Inputs/Outputs, Configuration Control, Verification, Commits, and Open Traceability Gaps.", .{ req_id, req_id });
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
    return if (field) |v| switch (v) {
        .integer => v.integer,
        else => null,
    } else null;
}

fn getBoolArg(args: ?std.json.Value, key: []const u8) ?bool {
    const field = if (args) |a| json_util.getObjectField(a, key) else null;
    return if (field) |v| switch (v) {
        .bool => v.bool,
        else => null,
    } else null;
}

fn nodeMatchesRepo(item: std.json.Value, repo: []const u8) bool {
    const props = json_util.getObjectField(item, "properties") orelse return false;
    const prop_repo = json_util.getString(props, "repo") orelse return false;
    return std.mem.eql(u8, prop_repo, repo);
}

fn appendJsonValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: Allocator) !void {
    const piece = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(piece);
    try buf.appendSlice(alloc, piece);
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

fn requirementTraceMarkdown(req_id: []const u8, db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleDesignHistory(db, profile_name, req_id, arena);
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

fn designHistoryMarkdown(req_id: []const u8, db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) ![]u8 {
    return requirementTraceMarkdown(req_id, db, profile_name, alloc);
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

fn statusMarkdown(registry: *workbook.registry.WorkbookRegistry, secure_store_ref: *secure_store.Store, state: *sync_live.SyncState, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var license_service = try license.initDefaultHmacFile(arena, .{
        .product = .live,
        .trial_policy = .requires_license,
    });
    const data = try routes.handleStatus(registry, secure_store_ref, state, &license_service, arena);
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

fn chainGapSummaryMarkdown(db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleChainGaps(db, profile_name, arena);
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

fn reviewSummaryMarkdown(db: *graph_live.GraphDb, profile_name: []const u8, state: *sync_live.SyncState, alloc: Allocator) ![]u8 {
    _ = state;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suspects_json = try routes.handleSuspects(db, arena);
    const gaps_json = try routes.handleChainGaps(db, profile_name, arena);
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

fn gapExplanationMarkdown(code: u16, node_id: []const u8, db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try routes.handleChainGaps(db, profile_name, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.NotFound;
    var found: ?std.json.Value = null;
    for (parsed.value.array.items) |item| {
        const item_code = if (json_util.getObjectField(item, "code")) |v| switch (v) {
            .integer => v.integer,
            else => -1,
        } else -1;
        const item_node = json_util.getString(item, "node_id") orelse continue;
        if (item_code == code and std.mem.eql(u8, item_node, node_id)) {
            found = item;
            break;
        }
    }
    const gap = found orelse return error.NotFound;
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
    const suspect = if (json_util.getObjectField(node, "suspect")) |v| switch (v) {
        .bool => v.bool,
        else => false,
    } else false;
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
            try std.fmt.format(buf.writer(alloc), "- `{s}` -> `{s}` ({s})", .{ label, id, ty });
            try appendEdgePropertySuffix(buf, json_util.getObjectField(item, "properties"), alloc);
            try buf.append(alloc, '\n');
        }
    }
    try buf.append(alloc, '\n');
}

fn edgePropertyPriority(key: []const u8) usize {
    if (std.mem.eql(u8, key, "quantity")) return 0;
    if (std.mem.eql(u8, key, "ref_designator")) return 1;
    if (std.mem.eql(u8, key, "supplier")) return 2;
    if (std.mem.eql(u8, key, "relation_source")) return 3;
    return 4;
}

fn edgePropertyLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const lhs_priority = edgePropertyPriority(lhs);
    const rhs_priority = edgePropertyPriority(rhs);
    if (lhs_priority != rhs_priority) return lhs_priority < rhs_priority;
    return std.mem.lessThan(u8, lhs, rhs);
}

fn appendEdgePropertyValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: Allocator) !void {
    switch (value) {
        .string => try buf.appendSlice(alloc, value.string),
        .integer => try std.fmt.format(buf.writer(alloc), "{d}", .{value.integer}),
        .float => try std.fmt.format(buf.writer(alloc), "{d}", .{value.float}),
        .bool => try buf.appendSlice(alloc, if (value.bool) "true" else "false"),
        else => {
            const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
            defer alloc.free(json);
            try buf.appendSlice(alloc, json);
        },
    }
}

fn appendEdgePropertySuffix(buf: *std.ArrayList(u8), properties: ?std.json.Value, alloc: Allocator) !void {
    if (properties == null or properties.? != .object) return;

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);
    var it = properties.?.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        try keys.append(alloc, entry.key_ptr.*);
    }
    if (keys.items.len == 0) return;
    std.mem.sort([]const u8, keys.items, {}, edgePropertyLessThan);

    try buf.appendSlice(alloc, " [");
    for (keys.items, 0..) |key, idx| {
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, key);
        try buf.append(alloc, '=');
        try appendEdgePropertyValue(buf, properties.?.object.get(key).?, alloc);
    }
    try buf.append(alloc, ']');
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
    return switch (field) {
        .integer => field.integer,
        else => null,
    };
}

fn boolStr(v: ?std.json.Value) []const u8 {
    if (v) |val| switch (val) {
        .bool => return if (val.bool) "true" else "false",
        else => {},
    };
    return "false";
}

fn sendResult(req: *std.http.Server.Request, id_raw: []const u8, result_json: []const u8, alloc: Allocator) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_raw, result_json });
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

fn toolPayloadResultJson(id_raw: []const u8, payload: ToolPayload, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":", .{id_raw});
    try json_util.appendJsonQuoted(&buf, payload.text, alloc);
    try buf.append(alloc, '}');
    if (payload.note) |note| {
        try buf.appendSlice(alloc, ",{\"type\":\"text\",\"text\":");
        try json_util.appendJsonQuoted(&buf, note, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]");
    if (payload.structured_json) |json| {
        try buf.appendSlice(alloc, ",\"structuredContent\":");
        try buf.appendSlice(alloc, json);
    }
    try buf.appendSlice(alloc, "}}");
    return alloc.dupe(u8, buf.items);
}

fn sendToolPayload(req: *std.http.Server.Request, id_raw: []const u8, payload: ToolPayload, alloc: Allocator) !void {
    const resp = try toolPayloadResultJson(id_raw, payload, alloc);
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

fn sendError(req: *std.http.Server.Request, id_raw: []const u8, code: i32, message: []const u8, alloc: Allocator) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id_raw, code, message });
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

const testing = std.testing;

fn makeTestRegistry(alloc: Allocator, store: *secure_store.Store, profile_name: []const u8) !workbook.registry.WorkbookRegistry {
    var cfg = try workbook.config.bootstrapConfig(alloc, .{ .profile = profile_name });
    errdefer cfg.deinit(alloc);
    alloc.free(cfg.workbooks[0].db_path);
    cfg.workbooks[0].db_path = try alloc.dupe(u8, ":memory:");
    alloc.free(cfg.workbooks[0].inbox_dir);
    cfg.workbooks[0].inbox_dir = try alloc.dupe(u8, "/tmp/inbox");
    return workbook.registry.WorkbookRegistry.initForConfig(alloc, cfg, store);
}

fn parseJsonForTest(json: []const u8, alloc: Allocator) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

fn parseToolsJsonForTest(alloc: Allocator) !std.json.Parsed(std.json.Value) {
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"tools\":{s}}}", .{tools_json});
    defer alloc.free(wrapped);
    return parseJsonForTest(wrapped, alloc);
}

fn findToolForTest(root: std.json.Value, name: []const u8) ?std.json.Value {
    const tools = json_util.getObjectField(root, "tools") orelse return null;
    if (tools != .array) return null;
    for (tools.array.items) |item| {
        const item_name = json_util.getString(item, "name") orelse continue;
        if (std.mem.eql(u8, item_name, name)) return item;
    }
    return null;
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
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const resp = try resourceReadResult("requirement://REQ-001", &registry, &db, &store, &state, "generic", testing.allocator);
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
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const resp = try resourceReadResult("impact://UN-001", &registry, &db, &store, &state, "generic", testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "# Impact Analysis for UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
}

test "resources read returns gap markdown" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Example\"}", null);
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need\"}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try makeTestRegistry(testing.allocator, &store, "aerospace");
    defer registry.deinit(testing.allocator);
    const resp = try resourceReadResult("gap://1203/REQ-001", &registry, &db, &store, &state, "aerospace", testing.allocator);
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
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    try testing.expectError(error.NotFound, resourceReadResult("unknown://x", &registry, &db, &store, &state, "generic", testing.allocator));
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
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const resp = try promptGetResult("trace_requirement", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "design-history://REQ-001") != null);
}

test "tools list exposes truthful schemas for structured and narrative tools" {
    var parsed = try parseToolsJsonForTest(testing.allocator);
    defer parsed.deinit();

    const get_rtm = findToolForTest(parsed.value, "get_rtm") orelse return error.TestUnexpectedResult;
    try testing.expect(json_util.getObjectField(get_rtm, "outputSchema") != null);
    try testing.expectEqualStrings("array", json_util.getString(json_util.getObjectField(get_rtm, "outputSchema").?, "type").?);

    const get_node = findToolForTest(parsed.value, "get_node") orelse return error.TestUnexpectedResult;
    const get_node_schema = json_util.getObjectField(get_node, "inputSchema") orelse return error.TestUnexpectedResult;
    const get_node_props = json_util.getObjectField(get_node_schema, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(json_util.getObjectField(get_node_props, "include_edges") != null);
    try testing.expect(json_util.getObjectField(get_node_props, "include_properties") != null);
    try testing.expectEqualStrings("object", json_util.getString(json_util.getObjectField(get_node, "outputSchema").?, "type").?);

    const get_bom_item = findToolForTest(parsed.value, "get_bom_item") orelse return error.TestUnexpectedResult;
    const get_bom_item_schema = json_util.getObjectField(get_bom_item, "inputSchema") orelse return error.TestUnexpectedResult;
    const one_of = json_util.getObjectField(get_bom_item_schema, "oneOf") orelse return error.TestUnexpectedResult;
    try testing.expect(one_of == .array);
    try testing.expectEqual(@as(usize, 2), one_of.array.items.len);

    const requirement_trace = findToolForTest(parsed.value, "requirement_trace") orelse return error.TestUnexpectedResult;
    try testing.expect(json_util.getObjectField(requirement_trace, "outputSchema") == null);
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
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const dispatch = try buildToolPayload("get_rtm", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    const payload = switch (dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(payload.note != null);
    try testing.expect(payload.structured_json != null);
    const resp = try toolPayloadResultJson("1", payload, testing.allocator);
    defer testing.allocator.free(resp);
    var parsed = try parseJsonForTest(resp, testing.allocator);
    defer parsed.deinit();
    const result = json_util.getObjectField(parsed.value, "result") orelse return error.TestUnexpectedResult;
    try testing.expect(json_util.getObjectField(result, "structuredContent") != null);
    try testing.expect(json_util.getObjectField(result, "structuredContent").? == .array);
}

test "get_node honors include_edges and include_properties flags" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"One\",\"status\":\"Approved\"}", null);
    try db.addNode("TEST-001", "Test", "{\"result\":\"PASS\"}", null);
    try db.addEdge("REQ-001", "TEST-001", "TESTED_BY");

    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    var args_default = std.json.ObjectMap.init(testing.allocator);
    defer args_default.deinit();
    try args_default.put("id", .{ .string = "REQ-001" });
    const dispatch_default = try buildToolPayload("get_node", .{ .object = args_default }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch_default.deinit(testing.allocator);
    const payload_default = switch (dispatch_default) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    var parsed_default = try parseJsonForTest(payload_default.structured_json.?, testing.allocator);
    defer parsed_default.deinit();
    try testing.expect(json_util.getObjectField(parsed_default.value, "edges_out") != null);
    try testing.expect(json_util.getObjectField(json_util.getObjectField(parsed_default.value, "node").?, "properties") != null);

    var args_no_edges = std.json.ObjectMap.init(testing.allocator);
    defer args_no_edges.deinit();
    try args_no_edges.put("id", .{ .string = "REQ-001" });
    try args_no_edges.put("include_edges", .{ .bool = false });
    const dispatch_no_edges = try buildToolPayload("get_node", .{ .object = args_no_edges }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch_no_edges.deinit(testing.allocator);
    const payload_no_edges = switch (dispatch_no_edges) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    var parsed_no_edges = try parseJsonForTest(payload_no_edges.structured_json.?, testing.allocator);
    defer parsed_no_edges.deinit();
    try testing.expect(json_util.getObjectField(parsed_no_edges.value, "edges_out") == null);
    try testing.expect(json_util.getObjectField(parsed_no_edges.value, "edges_in") == null);

    var args_no_props = std.json.ObjectMap.init(testing.allocator);
    defer args_no_props.deinit();
    try args_no_props.put("id", .{ .string = "REQ-001" });
    try args_no_props.put("include_properties", .{ .bool = false });
    const dispatch_no_props = try buildToolPayload("get_node", .{ .object = args_no_props }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch_no_props.deinit(testing.allocator);
    const payload_no_props = switch (dispatch_no_props) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    var parsed_no_props = try parseJsonForTest(payload_no_props.structured_json.?, testing.allocator);
    defer parsed_no_props.deinit();
    try testing.expect(json_util.getObjectField(json_util.getObjectField(parsed_no_props.value, "node").?, "properties") == null);
}

test "get_bom_item invalid selector returns specific message" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("bom_name", .{ .string = "pcba" });
    const dispatch = try buildToolPayload("get_bom_item", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    switch (dispatch) {
        .invalid_arguments => |msg| try testing.expectEqualStrings("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", msg),
        else => return error.TestUnexpectedResult,
    }
}

test "implementation changes tool validates required arguments explicitly" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("since", .{ .string = "2026-03-05T00:00:00Z" });
    const dispatch = try buildToolPayload("implementation_changes_since", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    switch (dispatch) {
        .invalid_arguments => |msg| try testing.expectEqualStrings("implementation_changes_since requires 'since' and 'node_type'", msg),
        else => return error.TestUnexpectedResult,
    }
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
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);
    const dispatch = try buildToolPayload("implementation_changes_since", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    const payload = switch (dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"node_id\":\"REQ-001\"") != null);
    try testing.expect(payload.note != null);
    try testing.expect(payload.structured_json != null);
}

test "get_bom tool returns product bom tree" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    var ingest = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4",
        \\      "supplier": "Murata"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);

    var args_obj = std.json.ObjectMap.init(testing.allocator);
    defer args_obj.deinit();
    try args_obj.put("full_product_identifier", .{ .string = "ASM-1000-REV-C" });
    var state: sync_live.SyncState = .{};
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try makeTestRegistry(testing.allocator, &store, "generic");
    defer registry.deinit(testing.allocator);

    const dispatch = try buildToolPayload("get_bom", .{ .object = args_obj }, &registry, &db, &store, &state, "generic", testing.allocator);
    defer dispatch.deinit(testing.allocator);
    const payload = switch (dispatch) {
        .payload => |payload| payload,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"bom_name\":\"pcba\"") != null);
    try testing.expect(std.mem.indexOf(u8, payload.text, "\"quantity\":\"4\"") != null);
    try testing.expect(payload.structured_json != null);
}

test "node markdown includes edge properties in stable order" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("BOM-ROOT", "BOM", "{\"description\":\"Root\"}", null);
    try db.addNode("BOM-ITEM", "BOMItem", "{\"description\":\"Child\"}", null);
    try db.addEdgeWithProperties("BOM-ROOT", "BOM-ITEM", "CONTAINS", "{\"supplier\":\"Murata\",\"quantity\":\"4\",\"relation_source\":\"hardware_csv\",\"ref_designator\":\"C47,C48\"}");

    const md = try nodeMarkdown("BOM-ROOT", &db, testing.allocator);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "[quantity=4, ref_designator=C47,C48, supplier=Murata, relation_source=hardware_csv]") != null);
}
