const std = @import("std");
const mcp_mod = @import("mcp/mod.zig");

pub fn handleSse(
    req: *std.http.Server.Request,
    registry: *mcp_mod.internal.workbook.registry.WorkbookRegistry,
    secure_store_ref: *mcp_mod.internal.secure_store.Store,
    alloc: mcp_mod.internal.Allocator,
) !void {
    try mcp_mod.http.handleSse(req, registry, secure_store_ref, alloc);
}

pub fn handlePost(
    req: *std.http.Server.Request,
    body: []const u8,
    registry: *mcp_mod.internal.workbook.registry.WorkbookRegistry,
    secure_store_ref: *mcp_mod.internal.secure_store.Store,
    state: *mcp_mod.internal.sync_live.SyncState,
    license_service: *mcp_mod.internal.license.Service,
    refresh_active_runtime_fn: ?mcp_mod.internal.RefreshActiveRuntimeFn,
    alloc: mcp_mod.internal.Allocator,
) !void {
    try mcp_mod.http.handlePost(req, body, registry, secure_store_ref, state, license_service, refresh_active_runtime_fn, alloc);
}

test {
    _ = @import("mcp/tests/mod.zig");
}
