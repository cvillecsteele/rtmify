const std = @import("std");
const internal = @import("../internal.zig");
const protocol = @import("../protocol.zig");
const tools = @import("../tools.zig");

pub const testing = std.testing;

pub fn makeTestRegistry(alloc: internal.Allocator, store: *internal.secure_store.Store, profile_name: []const u8) !internal.workbook.registry.WorkbookRegistry {
    var cfg = try internal.workbook.config.bootstrapConfig(alloc, .{ .profile = profile_name });
    errdefer cfg.deinit(alloc);
    alloc.free(cfg.workbooks[0].db_path);
    cfg.workbooks[0].db_path = try alloc.dupe(u8, ":memory:");
    alloc.free(cfg.workbooks[0].inbox_dir);
    cfg.workbooks[0].inbox_dir = try alloc.dupe(u8, "/tmp/inbox");
    return internal.workbook.registry.WorkbookRegistry.initForConfig(alloc, cfg, store);
}

pub fn parseJsonForTest(json: []const u8, alloc: internal.Allocator) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json, .{});
}

pub fn parseToolsJsonForTest(alloc: internal.Allocator) !std.json.Parsed(std.json.Value) {
    const wrapped = try std.fmt.allocPrint(alloc, "{{\"tools\":{s}}}", .{protocol.tools_json});
    defer alloc.free(wrapped);
    return parseJsonForTest(wrapped, alloc);
}

pub fn findToolForTest(root: std.json.Value, name: []const u8) ?std.json.Value {
    const tools_val = internal.json_util.getObjectField(root, "tools") orelse return null;
    if (tools_val != .array) return null;
    for (tools_val.array.items) |item| {
        const item_name = internal.json_util.getString(item, "name") orelse continue;
        if (std.mem.eql(u8, item_name, name)) return item;
    }
    return null;
}

pub fn buildToolPayloadForTest(name: []const u8, args: ?std.json.Value, registry: *internal.workbook.registry.WorkbookRegistry, db: *internal.graph_live.GraphDb, store: *internal.secure_store.Store, state: *internal.sync_live.SyncState, profile_name: []const u8, alloc: internal.Allocator) !internal.ToolDispatch {
    var license_service = try internal.license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);
    const req_ctx = internal.RequestContext{
        .registry = registry,
        .secure_store_ref = store,
        .state = state,
        .license_service = &license_service,
        .refresh_active_runtime_fn = null,
        .alloc = alloc,
    };
    const runtime_ctx = internal.RuntimeContext{
        .db = db,
        .profile_name = profile_name,
    };
    return tools.buildToolPayload(name, args, &req_ctx, &runtime_ctx);
}
