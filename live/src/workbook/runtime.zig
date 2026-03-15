const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const sync_live = @import("../sync_live.zig");
const test_results_auth = @import("../test_results_auth.zig");
const workbook_config = @import("config.zig");

pub const WorkbookRuntime = struct {
    config: workbook_config.WorkbookConfig,
    db: graph_live.GraphDb,
    sync_state: sync_live.SyncState = .{},
    ingest_auth: test_results_auth.AuthState,

    pub fn deinit(self: *WorkbookRuntime, alloc: Allocator) void {
        self.db.deinit();
        self.ingest_auth.deinit(alloc);
        self.config.deinit(alloc);
    }
};
