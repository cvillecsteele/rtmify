const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const license = @import("rtmify").license;
pub const profile_mod = @import("rtmify").profile;
pub const graph_live = @import("../graph_live.zig");
pub const sync_live = @import("../sync_live.zig");
pub const routes = @import("../routes.zig");
pub const secure_store = @import("../secure_store.zig");
pub const json_util = @import("../json_util.zig");
pub const chain_mod = @import("../chain.zig");
pub const test_results = @import("../test_results.zig");
pub const bom = @import("../bom.zig");
pub const workbook = @import("../workbook/mod.zig");
pub const shared = @import("../routes/shared.zig");

pub const GraphDb = graph_live.GraphDb;
pub const SyncState = sync_live.SyncState;
pub const WorkbookRegistry = workbook.registry.WorkbookRegistry;
pub const SecureStore = secure_store.Store;
pub const RefreshActiveRuntimeFn = *const fn (*workbook.registry.WorkbookRegistry, *secure_store.Store, *license.Service, Allocator) void;

pub const ToolPayload = struct {
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

pub const ToolDispatch = union(enum) {
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

pub const RequestContext = struct {
    registry: *workbook.registry.WorkbookRegistry,
    secure_store_ref: *secure_store.Store,
    state: *sync_live.SyncState,
    license_service: *license.Service,
    refresh_active_runtime_fn: ?RefreshActiveRuntimeFn,
    alloc: Allocator,
};

pub const RuntimeContext = struct {
    db: *graph_live.GraphDb,
    profile_name: []const u8,
    owned_scratch_db: ?graph_live.GraphDb = null,

    pub fn deinit(self: *RuntimeContext) void {
        if (self.owned_scratch_db) |*db_ref| db_ref.deinit();
    }
};
