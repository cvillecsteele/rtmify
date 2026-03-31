const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const poller = @import("poller.zig");
const sync_live = @import("../sync_live.zig");

pub const InboxCtx = struct {
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    control: *sync_live.WorkerControl,
    inbox_dir: []const u8,
    alloc: Allocator,
};

pub fn destroyInboxCtx(ctx: *InboxCtx) void {
    ctx.alloc.free(ctx.inbox_dir);
    ctx.alloc.destroy(ctx);
}

pub fn inboxThread(ctx: *InboxCtx) void {
    defer destroyInboxCtx(ctx);

    while (!ctx.control.stop_requested.load(.seq_cst)) {
        if (!ctx.state.product_enabled.load(.seq_cst)) {
            ctx.control.waitTimeout(5 * std.time.ns_per_s);
            continue;
        }

        poller.processInboxOnce(ctx.db, ctx.inbox_dir, ctx.alloc) catch |err| {
            std.log.warn("external ingest inbox poll failed: {s}", .{@errorName(err)});
        };
        ctx.control.waitTimeout(5 * std.time.ns_per_s);
    }
}
