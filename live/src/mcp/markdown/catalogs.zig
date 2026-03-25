const std = @import("std");

const internal = @import("../internal.zig");
const protocol = @import("../protocol.zig");
const common = @import("common.zig");

pub fn statusMarkdown(
    registry: *internal.workbook.registry.WorkbookRegistry,
    secure_store_ref: *internal.secure_store.Store,
    state: *internal.sync_live.SyncState,
    alloc: internal.Allocator,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var license_service = try internal.license.initDefaultHmacFile(arena, .{
        .product = .live,
        .trial_policy = .requires_license,
    });
    const data = try internal.routes.handleStatus(registry, secure_store_ref, state, &license_service, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Live Status\n\n");
    try std.fmt.format(buf.writer(alloc), "- Configured: {s}\n", .{common.boolStr(internal.json_util.getObjectField(parsed.value, "configured"))});
    try std.fmt.format(buf.writer(alloc), "- Platform: {s}\n", .{internal.json_util.getString(parsed.value, "platform") orelse "none"});
    try std.fmt.format(buf.writer(alloc), "- Workbook: {s}\n", .{internal.json_util.getString(parsed.value, "workbook_label") orelse "none"});
    try std.fmt.format(buf.writer(alloc), "- Sync Count: {d}\n", .{common.getIntField(parsed.value, "sync_count") orelse 0});
    try std.fmt.format(buf.writer(alloc), "- Last Sync At: {d}\n", .{common.getIntField(parsed.value, "last_sync_at") orelse 0});
    try std.fmt.format(buf.writer(alloc), "- Last Scan At: {s}\n", .{internal.json_util.getString(parsed.value, "last_scan_at") orelse "never"});
    try std.fmt.format(buf.writer(alloc), "- Has Error: {s}\n", .{common.boolStr(internal.json_util.getObjectField(parsed.value, "has_error"))});
    const err = internal.json_util.getString(parsed.value, "error") orelse "";
    if (err.len > 0) try std.fmt.format(buf.writer(alloc), "- Error: {s}\n", .{err});
    return alloc.dupe(u8, buf.items);
}

pub fn mcpToolsIndexMarkdown(alloc: internal.Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, protocol.tools_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidArgument;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# MCP Tools\n\n");
    try std.fmt.format(buf.writer(alloc), "- Callable tools exposed by this server: {d}\n\n", .{parsed.value.array.items.len});
    try buf.appendSlice(alloc, "## Tool Catalog\n");
    for (parsed.value.array.items) |item| {
        const name = internal.json_util.getString(item, "name") orelse continue;
        const description = internal.json_util.getString(item, "description") orelse "";
        const input_schema = internal.json_util.getObjectField(item, "inputSchema");
        const required_count: usize = if (input_schema) |schema|
            if (internal.json_util.getObjectField(schema, "required")) |required|
                if (required == .array) required.array.items.len else 0
            else 0
        else 0;
        try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [required_args={d}]\n", .{
            name,
            description,
            required_count,
        });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn mcpPromptsIndexMarkdown(alloc: internal.Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, protocol.prompts_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidArgument;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# MCP Prompts\n\n");
    try std.fmt.format(buf.writer(alloc), "- Prompts exposed by this server: {d}\n\n", .{parsed.value.array.items.len});
    try buf.appendSlice(alloc, "## Prompt Catalog\n");
    for (parsed.value.array.items) |item| {
        const name = internal.json_util.getString(item, "name") orelse continue;
        const description = internal.json_util.getString(item, "description") orelse "";
        const arguments = internal.json_util.getObjectField(item, "arguments");
        const arg_count: usize = if (arguments) |args| if (args == .array) args.array.items.len else 0 else 0;
        try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [arguments={d}]\n", .{
            name,
            description,
            arg_count,
        });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}
