/// mcp.zig — MCP endpoint for rtmify-live.
///
/// Transport: Streamable HTTP (POST /mcp) + SSE discovery (GET /mcp).
///
/// POST /mcp: JSON-RPC 2.0 dispatcher. Supported methods:
///   initialize, notifications/initialized, ping,
///   tools/list, tools/call
///
/// GET /mcp: Sends an SSE "endpoint" event pointing to POST /mcp
///   (for legacy SSE-transport MCP clients).
///
/// All tools map 1:1 to route handlers in routes.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("graph_live.zig");
const sync_live = @import("sync_live.zig");
const routes = @import("routes.zig");

// ---------------------------------------------------------------------------
// Tool definitions (JSON Schema, hand-written per PRD §10.2)
// ---------------------------------------------------------------------------

const tools_json =
    \\[
    \\{"name":"get_rtm","description":"Get the full Requirements Traceability Matrix. Returns all requirements with linked user needs, tests, and traceability status.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_gaps","description":"Get requirements with no test linked. Returns untested requirements that have gaps in traceability coverage.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_suspects","description":"Get all suspect nodes. A node is suspect when an upstream dependency changed after it was last reviewed.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_nodes","description":"Get all graph nodes, optionally filtered by type. Node types include: Requirement, UserNeed, Test, Risk.","inputSchema":{"type":"object","properties":{"type":{"type":"string","description":"Filter by node type (e.g. Requirement, UserNeed, Test, Risk)"}},"required":[]}},
    \\{"name":"get_node","description":"Get a single node by ID including all edges in and out.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"The node ID (e.g. REQ-001)"}},"required":["id"]}},
    \\{"name":"search","description":"Full-text search across node IDs and properties.","inputSchema":{"type":"object","properties":{"q":{"type":"string","description":"Search query string"}},"required":["q"]}},
    \\{"name":"get_user_needs","description":"Get all User Need nodes.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_tests","description":"Get all Test nodes with linked requirements.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_risks","description":"Get the risk register with severity, mitigation, and linked requirements.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_impact","description":"Get impact analysis for a node: all nodes upstream and downstream in the graph.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"The node ID to analyse"}},"required":["id"]}},
    \\{"name":"get_schema","description":"Get the graph schema: node types, edge labels, and their semantic meanings.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_status","description":"Get sync state: last sync timestamp, error status, and license validity.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"clear_suspect","description":"Mark a suspect node as reviewed, clearing the suspect flag.","inputSchema":{"type":"object","properties":{"id":{"type":"string","description":"The node ID to clear"}},"required":["id"]}},
    \\{"name":"code_traceability","description":"Source and test files with annotation counts.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"unimplemented_requirements","description":"Requirements with no IMPLEMENTED_IN edge (not yet linked to source code).","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"untested_source_files","description":"Source files with no VERIFIED_BY_CODE edge (not yet linked to a test).","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"file_annotations","description":"Code annotations found in a specific source file.","inputSchema":{"type":"object","properties":{"file_path":{"type":"string","description":"Absolute or relative file path"}},"required":["file_path"]}},
    \\{"name":"blame_for_requirement","description":"Code annotations with blame data linked to a requirement.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string","description":"Requirement node ID (e.g. REQ-001)"}},"required":["req_id"]}},
    \\{"name":"commit_history","description":"Commits linked to a requirement via COMMITTED_IN edges.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string","description":"Requirement node ID"}},"required":["req_id"]}},
    \\{"name":"design_history","description":"Full upstream/downstream chain for a requirement: user needs, DI/DO/CI, tests, source files, commits.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string","description":"Requirement node ID"}},"required":["req_id"]}},
    \\{"name":"chain_gaps","description":"Traceability chain gaps for the active industry profile (medical/aerospace/automotive/generic).","inputSchema":{"type":"object","properties":{},"required":[]}}
    \\]
;

const initialize_result =
    \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"rtmify-live","version":"1.0"}}
;

// ---------------------------------------------------------------------------
// GET /mcp — SSE discovery for legacy SSE-transport clients
// ---------------------------------------------------------------------------

/// Handle GET /mcp.
/// Sends an SSE "endpoint" event pointing to POST /mcp, then closes.
/// This lets legacy SSE-transport MCP clients discover the message endpoint.
pub fn handleSse(req: *std.http.Server.Request, db: *graph_live.GraphDb, alloc: Allocator) !void {
    _ = db;
    _ = alloc;

    // The endpoint event tells SSE clients where to POST JSON-RPC messages.
    // We point them at POST /mcp (Streamable HTTP transport).
    const body =
        "event: endpoint\r\n" ++
        "data: /mcp\r\n" ++
        "\r\n";

    const sse_headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/event-stream" },
        .{ .name = "Cache-Control", .value = "no-cache" },
        .{ .name = "Connection", .value = "close" },
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    };

    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &sse_headers,
        .keep_alive = false,
    });
}

// ---------------------------------------------------------------------------
// POST /mcp — Streamable HTTP transport: JSON-RPC dispatcher
// ---------------------------------------------------------------------------

/// Handle POST /mcp.
/// Reads the JSON-RPC request body (already read by server.zig) and dispatches.
pub fn handlePost(
    req: *std.http.Server.Request,
    body: []const u8,
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    alloc: Allocator,
) !void {
    const method = extractField(body, "method") orelse {
        return sendError(req, "null", -32600, "Invalid Request", alloc);
    };

    // Extract raw id (number, string, or null) for response
    const id_raw = extractRawId(body) orelse "null";

    // Notifications have no id — send no response
    const is_notification = !hasId(body);

    if (std.mem.eql(u8, method, "initialize")) {
        try sendResult(req, id_raw, initialize_result, alloc);
    } else if (std.mem.eql(u8, method, "notifications/initialized") or
        std.mem.eql(u8, method, "notifications/cancelled"))
    {
        // Client notifications: MCP spec §6.1 — respond 202 Accepted with no body.
        // If it somehow has an id, send an empty result instead.
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
        try dispatchToolCall(req, body, id_raw, db, state, alloc);
    } else {
        try sendError(req, id_raw, -32601, "Method not found", alloc);
    }
}

// ---------------------------------------------------------------------------
// Tool call dispatcher
// ---------------------------------------------------------------------------

fn dispatchToolCall(
    req: *std.http.Server.Request,
    body: []const u8,
    id_raw: []const u8,
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    alloc: Allocator,
) !void {
    // Extract params.name
    const params_start = findObjectField(body, "params") orelse {
        return sendError(req, id_raw, -32602, "Missing params", alloc);
    };
    const name = extractField(params_start, "name") orelse {
        return sendError(req, id_raw, -32602, "Missing tool name", alloc);
    };

    // Extract params.arguments (optional JSON object)
    const args_start = findObjectField(params_start, "arguments") orelse "";

    if (std.mem.eql(u8, name, "get_rtm")) {
        const data = try routes.handleRtm(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_gaps")) {
        const data = try routes.handleGaps(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_suspects")) {
        const data = try routes.handleSuspects(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_nodes")) {
        const type_filter = extractField(args_start, "type");
        const data = try routes.handleNodes(db, type_filter, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_node")) {
        const node_id = extractField(args_start, "id") orelse {
            return sendError(req, id_raw, -32602, "Missing argument: id", alloc);
        };
        const data = try routes.handleNode(db, node_id, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "search")) {
        const q = extractField(args_start, "q") orelse "";
        const data = try routes.handleSearch(db, q, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_user_needs")) {
        const data = try routes.handleUserNeeds(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_tests")) {
        const data = try routes.handleTests(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_risks")) {
        const data = try routes.handleRisks(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_impact")) {
        const node_id = extractField(args_start, "id") orelse {
            return sendError(req, id_raw, -32602, "Missing argument: id", alloc);
        };
        const data = try routes.handleImpact(db, node_id, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_schema")) {
        const data = try routes.handleSchema(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "get_status")) {
        const data = try routes.handleStatus(db, state, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "clear_suspect")) {
        const node_id = extractField(args_start, "id") orelse {
            return sendError(req, id_raw, -32602, "Missing argument: id", alloc);
        };
        const data = try routes.handleClearSuspect(db, node_id, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "code_traceability")) {
        const data = try routes.handleCodeTraceability(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "unimplemented_requirements")) {
        const data = try routes.handleUnimplementedRequirements(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "untested_source_files")) {
        const data = try routes.handleUntestedSourceFiles(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "file_annotations")) {
        const file_path = extractField(args_start, "file_path") orelse {
            return sendError(req, id_raw, -32602, "Missing argument: file_path", alloc);
        };
        const data = try routes.handleFileAnnotations(db, file_path, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "blame_for_requirement")) {
        const req_id = extractField(args_start, "req_id") orelse {
            return sendError(req, id_raw, -32602, "Missing argument: req_id", alloc);
        };
        const data = try routes.handleBlameForRequirement(db, req_id, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "commit_history")) {
        const req_id = extractField(args_start, "req_id") orelse {
            return sendError(req, id_raw, -32602, "Missing argument: req_id", alloc);
        };
        const data = try routes.handleCommitHistory(db, req_id, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "design_history")) {
        const req_id = extractField(args_start, "req_id") orelse {
            return sendError(req, id_raw, -32602, "Missing argument: req_id", alloc);
        };
        const data = try routes.handleDesignHistory(db, req_id, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else if (std.mem.eql(u8, name, "chain_gaps")) {
        const data = try routes.handleChainGaps(db, alloc);
        defer alloc.free(data);
        try sendToolResult(req, id_raw, data, alloc);
    } else {
        try sendError(req, id_raw, -32602, "Unknown tool", alloc);
    }
}

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

const json_rpc_headers = [_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Connection", .value = "close" },
};

/// Send a JSON-RPC success result.
/// `result_json` is the raw JSON value for the "result" field.
fn sendResult(
    req: *std.http.Server.Request,
    id_raw: []const u8,
    result_json: []const u8,
    alloc: Allocator,
) !void {
    const resp = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_raw, result_json },
    );
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

/// Send a JSON-RPC tools/call result wrapping the data in MCP content format.
fn sendToolResult(
    req: *std.http.Server.Request,
    id_raw: []const u8,
    data_json: []const u8,
    alloc: Allocator,
) !void {
    // Escape the JSON string for embedding in a JSON string value
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(alloc);
    for (data_json) |c| {
        switch (c) {
            '"' => try escaped.appendSlice(alloc, "\\\""),
            '\\' => try escaped.appendSlice(alloc, "\\\\"),
            '\n' => try escaped.appendSlice(alloc, "\\n"),
            '\r' => try escaped.appendSlice(alloc, "\\r"),
            '\t' => try escaped.appendSlice(alloc, "\\t"),
            else => try escaped.append(alloc, c),
        }
    }
    const resp = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}",
        .{ id_raw, escaped.items },
    );
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

/// Send a JSON-RPC error response.
fn sendError(
    req: *std.http.Server.Request,
    id_raw: []const u8,
    code: i32,
    message: []const u8,
    alloc: Allocator,
) !void {
    const resp = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
        .{ id_raw, code, message },
    );
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &json_rpc_headers, .keep_alive = false });
}

// ---------------------------------------------------------------------------
// JSON extraction helpers
// ---------------------------------------------------------------------------

/// Extract a string value for a key from a JSON object. Returns the unquoted
/// content of the string (no allocation — points into `json`).
fn extractField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
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

/// Find the start of a JSON object value for a key.
/// Returns a slice starting at the '{' of the value object.
fn findObjectField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = key_pos + needle.len;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
    if (pos >= json.len or json[pos] != '{') return null;
    return json[pos..];
}

/// Extract the raw `id` value from a JSON-RPC body (number, string, or null).
/// Returns a slice of `json` containing the raw JSON value.
fn extractRawId(json: []const u8) ?[]const u8 {
    const needle = "\"id\":";
    const id_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    var pos = id_pos + needle.len;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
    if (pos >= json.len) return null;
    const start = pos;
    if (json[pos] == '"') {
        // String id
        pos += 1;
        while (pos < json.len and json[pos] != '"') {
            if (json[pos] == '\\') pos += 1;
            pos += 1;
        }
        if (pos < json.len) pos += 1; // closing "
        return json[start..pos];
    }
    // Number or null
    while (pos < json.len and json[pos] != ',' and json[pos] != '}' and
        json[pos] != '\n' and json[pos] != '\r') pos += 1;
    return std.mem.trim(u8, json[start..pos], " \t");
}

/// Returns true if the JSON body contains an explicit "id" field.
/// Notifications omit the id field.
fn hasId(json: []const u8) bool {
    return std.mem.indexOf(u8, json, "\"id\":") != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extractField basic" {
    const json =
        \\{"jsonrpc":"2.0","method":"tools/call","id":1}
    ;
    try testing.expectEqualStrings("2.0", extractField(json, "jsonrpc").?);
    try testing.expectEqualStrings("tools/call", extractField(json, "method").?);
    try testing.expect(extractField(json, "missing") == null);
}

test "extractRawId number" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"ping\"}";
    try testing.expectEqualStrings("42", extractRawId(json).?);
}

test "extractRawId string" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"ping\"}";
    try testing.expectEqualStrings("\"req-1\"", extractRawId(json).?);
}

test "extractRawId null" {
    const json = "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}";
    try testing.expectEqualStrings("null", extractRawId(json).?);
}

test "hasId true" {
    try testing.expect(hasId("{\"id\":1,\"method\":\"ping\"}"));
}

test "hasId false — notification" {
    try testing.expect(!hasId("{\"method\":\"notifications/initialized\"}"));
}

test "findObjectField" {
    const json =
        \\{"method":"tools/call","params":{"name":"get_rtm","arguments":{}}}
    ;
    const params = findObjectField(json, "params").?;
    try testing.expect(std.mem.startsWith(u8, params, "{"));
    try testing.expectEqualStrings("get_rtm", extractField(params, "name").?);
}

test "findObjectField missing" {
    try testing.expect(findObjectField("{\"a\":1}", "missing") == null);
}
