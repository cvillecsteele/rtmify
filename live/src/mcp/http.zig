const std = @import("std");
const internal = @import("internal.zig");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");
const resources = @import("resources.zig");
const prompts = @import("prompts.zig");
const workbooks = @import("workbooks.zig");

pub fn handleSse(req: *std.http.Server.Request, registry: *internal.workbook.registry.WorkbookRegistry, secure_store_ref: *internal.secure_store.Store, alloc: internal.Allocator) !void {
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
    registry: *internal.workbook.registry.WorkbookRegistry,
    secure_store_ref: *internal.secure_store.Store,
    state: *internal.sync_live.SyncState,
    license_service: *internal.license.Service,
    refresh_active_runtime_fn: ?internal.RefreshActiveRuntimeFn,
    alloc: internal.Allocator,
) !void {
    var runtime_ctx: internal.RuntimeContext = blk: {
        if (registry.active_runtime) |runtime| {
            break :blk .{
                .db = &runtime.db,
                .profile_name = runtime.config.profile,
            };
        }
        var scratch_db = try internal.graph_live.GraphDb.init(":memory:");
        break :blk .{
            .db = &scratch_db,
            .profile_name = "generic",
            .owned_scratch_db = scratch_db,
        };
    };
    defer runtime_ctx.deinit();

    const req_ctx = internal.RequestContext{
        .registry = registry,
        .secure_store_ref = secure_store_ref,
        .state = state,
        .license_service = license_service,
        .refresh_active_runtime_fn = refresh_active_runtime_fn,
        .alloc = alloc,
    };

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return sendError(req, "null", -32600, "Invalid Request", alloc);
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return sendError(req, "null", -32600, "Invalid Request", alloc);
    const method = internal.json_util.getString(root, "method") orelse return sendError(req, "null", -32600, "Invalid Request", alloc);
    const id_raw = if (internal.json_util.getObjectField(root, "id")) |id_value|
        try std.json.Stringify.valueAlloc(alloc, id_value, .{})
    else
        try alloc.dupe(u8, "null");
    defer alloc.free(id_raw);
    const is_notification = internal.json_util.getObjectField(root, "id") == null;

    if (std.mem.eql(u8, method, "initialize")) {
        try sendResult(req, id_raw, protocol.initialize_result, alloc);
    } else if (std.mem.eql(u8, method, "notifications/initialized") or std.mem.eql(u8, method, "notifications/cancelled")) {
        if (is_notification) {
            try req.respond("", .{ .status = .accepted, .extra_headers = &protocol.json_rpc_headers, .keep_alive = false });
        } else {
            try sendResult(req, id_raw, "{}", alloc);
        }
    } else if (std.mem.eql(u8, method, "ping")) {
        try sendResult(req, id_raw, "{}", alloc);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        const result = try std.fmt.allocPrint(alloc, "{{\"tools\":{s}}}", .{protocol.tools_json});
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try dispatchToolCall(req, root, id_raw, &req_ctx, &runtime_ctx);
    } else if (std.mem.eql(u8, method, "resources/list")) {
        const result = try resources.resourcesListResult(runtime_ctx.db, alloc);
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "resources/read")) {
        try dispatchResourceRead(req, root, id_raw, &req_ctx, &runtime_ctx);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        const result = try prompts.promptsListResult(alloc);
        defer alloc.free(result);
        try sendResult(req, id_raw, result, alloc);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        try dispatchPromptGet(req, root, id_raw, &req_ctx, &runtime_ctx);
    } else {
        try sendError(req, id_raw, -32601, "Method not found", alloc);
    }
}

fn dispatchToolCall(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, req_ctx: *const internal.RequestContext, runtime_ctx: *const internal.RuntimeContext) !void {
    const params = internal.json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", req_ctx.alloc);
    const name = internal.json_util.getString(params, "name") orelse return sendError(req, id_raw, -32602, "Missing tool name", req_ctx.alloc);
    const args = internal.json_util.getObjectField(params, "arguments");
    const dispatch = tools.buildToolPayload(name, args, req_ctx, runtime_ctx) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Not found", req_ctx.alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid arguments", req_ctx.alloc),
        else => return e,
    };
    defer dispatch.deinit(req_ctx.alloc);
    switch (dispatch) {
        .payload => |payload| try sendToolPayload(req, id_raw, name, req_ctx.registry, payload, req_ctx.alloc),
        .invalid_arguments => |msg| try sendError(req, id_raw, -32602, msg, req_ctx.alloc),
        .not_found => try sendError(req, id_raw, -32004, "Not found", req_ctx.alloc),
    }
}

fn dispatchResourceRead(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, req_ctx: *const internal.RequestContext, runtime_ctx: *const internal.RuntimeContext) !void {
    const params = internal.json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", req_ctx.alloc);
    const uri = internal.json_util.getString(params, "uri") orelse return sendError(req, id_raw, -32602, "Missing uri", req_ctx.alloc);
    const result = resources.resourceReadResult(uri, req_ctx, runtime_ctx) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Resource not found", req_ctx.alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid resource URI", req_ctx.alloc),
        else => return e,
    };
    defer req_ctx.alloc.free(result);
    try sendResult(req, id_raw, result, req_ctx.alloc);
}

fn dispatchPromptGet(req: *std.http.Server.Request, root: std.json.Value, id_raw: []const u8, req_ctx: *const internal.RequestContext, runtime_ctx: *const internal.RuntimeContext) !void {
    const params = internal.json_util.getObjectField(root, "params") orelse return sendError(req, id_raw, -32602, "Missing params", req_ctx.alloc);
    const name = internal.json_util.getString(params, "name") orelse return sendError(req, id_raw, -32602, "Missing prompt name", req_ctx.alloc);
    const args = internal.json_util.getObjectField(params, "arguments");
    const result = prompts.promptGetResult(name, args, req_ctx, runtime_ctx) catch |e| switch (e) {
        error.NotFound => return sendError(req, id_raw, -32004, "Prompt not found", req_ctx.alloc),
        error.InvalidArgument => return sendError(req, id_raw, -32602, "Invalid prompt arguments", req_ctx.alloc),
        else => return e,
    };
    defer req_ctx.alloc.free(result);
    try sendResult(req, id_raw, result, req_ctx.alloc);
}

pub fn sendResult(req: *std.http.Server.Request, id_raw: []const u8, result_json: []const u8, alloc: internal.Allocator) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_raw, result_json });
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &protocol.json_rpc_headers, .keep_alive = false });
}

pub fn toolPayloadResultJson(id_raw: []const u8, tool_name: []const u8, registry: *internal.workbook.registry.WorkbookRegistry, payload: internal.ToolPayload, alloc: internal.Allocator) ![]u8 {
    const context_json = try workbooks.workbookContextJson(registry, alloc);
    defer alloc.free(context_json);
    const contextual_text = blk: {
        if (tools.toolIsNarrative(tool_name)) {
            const heading = try workbooks.workbookHeading(registry, alloc);
            defer alloc.free(heading);
            break :blk try std.fmt.allocPrint(alloc, "{s}{s}", .{ heading, payload.text });
        }
        break :blk try alloc.dupe(u8, payload.text);
    };
    defer alloc.free(contextual_text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":", .{id_raw});
    try internal.json_util.appendJsonQuoted(&buf, contextual_text, alloc);
    try buf.append(alloc, '}');
    if (payload.note) |note| {
        try buf.appendSlice(alloc, ",{\"type\":\"text\",\"text\":");
        try internal.json_util.appendJsonQuoted(&buf, note, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]");
    if (payload.structured_json) |json| {
        try buf.appendSlice(alloc, ",\"structuredContent\":");
        try std.fmt.format(buf.writer(alloc), "{{\"workbook\":{s},\"data\":{s}}}", .{ context_json, json });
    } else if (tools.toolIsNarrative(tool_name)) {
        try buf.appendSlice(alloc, ",\"structuredContent\":");
        try buf.appendSlice(alloc, "{\"workbook\":");
        try buf.appendSlice(alloc, context_json);
        try buf.appendSlice(alloc, ",\"markdown\":");
        try internal.json_util.appendJsonQuoted(&buf, contextual_text, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "}}");
    return alloc.dupe(u8, buf.items);
}

pub fn sendToolPayload(req: *std.http.Server.Request, id_raw: []const u8, tool_name: []const u8, registry: *internal.workbook.registry.WorkbookRegistry, payload: internal.ToolPayload, alloc: internal.Allocator) !void {
    const resp = try toolPayloadResultJson(id_raw, tool_name, registry, payload, alloc);
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &protocol.json_rpc_headers, .keep_alive = false });
}

pub fn sendError(req: *std.http.Server.Request, id_raw: []const u8, code: i32, message: []const u8, alloc: internal.Allocator) !void {
    const resp = try std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id_raw, code, message });
    defer alloc.free(resp);
    try req.respond(resp, .{ .status = .ok, .extra_headers = &protocol.json_rpc_headers, .keep_alive = false });
}
