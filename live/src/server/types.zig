const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const license = rtmify.license;
const graph_live = @import("../graph_live.zig");
const secure_store = @import("../secure_store.zig");
const sync_live = @import("../sync_live.zig");
const test_results_auth = @import("../test_results_auth.zig");
const workbook = @import("../workbook/mod.zig");
const workbook_runtime = @import("../workbook/runtime.zig");

pub const ServerCtx = struct {
    registry: *workbook.registry.WorkbookRegistry,
    secure_store: *secure_store.Store,
    license_service: *license.Service,
    instance_info: InstanceInfo,
    alloc: Allocator,
    refresh_active_runtime_fn: ?*const fn (*workbook.registry.WorkbookRegistry, *secure_store.Store, *license.Service, Allocator) void = null,
    restart_active_workers_fn: ?*const fn (*workbook.registry.WorkbookRegistry, *secure_store.Store, *license.Service, Allocator) void = null,
    run_preview_sync_fn: ?*const fn (*workbook.registry.WorkbookRegistry, *secure_store.Store, *license.Service, Allocator) void = null,
};

pub const InstanceInfo = struct {
    actual_port: u16,
    live_version: []const u8,
    tray_app_version: []const u8,
    log_path: []const u8,
};

pub const RuntimeRefs = struct {
    active_runtime: ?*workbook_runtime.WorkbookRuntime,
    db: ?*graph_live.GraphDb,
    state: ?*sync_live.SyncState,
    auth: ?*test_results_auth.AuthState,
};

pub const RequestDispatch = struct {
    req: *std.http.Server.Request,
    ctx: ServerCtx,
    alloc: Allocator,
    target: []const u8,
    path: []const u8,
    runtime: RuntimeRefs,
    response_status: *?std.http.Status,
    response_bytes: *usize,
};
