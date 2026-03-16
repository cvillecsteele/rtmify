const std = @import("std");
const internal = @import("internal.zig");
const state_mod = @import("state.zig");
const cycle = @import("cycle.zig");

pub fn syncThread(cfg: state_mod.SyncConfig) void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();
    defer cfg.alloc.free(cfg.workbook_id);
    defer cfg.alloc.free(cfg.workbook_slug);
    defer cfg.state.sync_started.store(false, .seq_cst);
    defer cfg.state.sync_in_progress.store(false, .seq_cst);
    var owned_active = cfg.active;
    defer owned_active.deinit(cfg.alloc);

    var active = owned_active.clone(alloc) catch {
        cfg.state.setError("provider_setup_failed");
        return;
    };
    defer active.deinit(alloc);

    var runtime = internal.ProviderRuntime.init(active, alloc) catch |e| {
        cfg.state.setError(@errorName(e));
        std.log.err("sync: provider init failed: {s}", .{@errorName(e)});
        return;
    };
    defer runtime.deinit(alloc);

    var last_change_token: ?[]u8 = null;
    defer if (last_change_token) |tok| alloc.free(tok);
    var backoff: u64 = 30;

    while (!cfg.control.stop_requested.load(.seq_cst)) {
        if (!cfg.state.product_enabled.load(.seq_cst)) {
            cfg.control.waitTimeout(30 * std.time.ns_per_s);
            continue;
        }

        const force_sync = cfg.control.immediate_sync_requested.swap(false, .seq_cst);
        const change_token = runtime.changeToken(alloc) catch |e| {
            const msg = @errorName(e);
            cfg.state.setError(msg);
            cfg.db.storeConfig("last_sync_error", msg) catch {};
            cfg.db.storeConfig("last_sync_ok", "0") catch {};
            std.log.err("sync: change token refresh failed: {s}", .{msg});
            cfg.control.waitTimeout(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 300);
            continue;
        };

        if (last_change_token) |prev| {
            if (!force_sync and std.mem.eql(u8, prev, change_token)) {
                alloc.free(change_token);
                cfg.control.waitTimeout(30 * std.time.ns_per_s);
                continue;
            }
            alloc.free(prev);
        }
        last_change_token = @constCast(change_token);

        std.log.info("sync: workbook changed (token={s}), ingesting…", .{change_token});

        {
            var prov_arena = std.heap.ArenaAllocator.init(alloc);
            defer prov_arena.deinit();
            const pa = prov_arena.allocator();
            const prov_done = (cfg.db.getConfig("rtmify_provisioned", pa) catch null) orelse "";
            if (prov_done.len == 0) {
                const prof = internal.profile_mod.get(cfg.profile);
                _ = internal.provision_mod.provisionWorkbook(&runtime, prof, pa) catch |e| blk: {
                    std.log.warn("provision failed: {s}", .{@errorName(e)});
                    break :blk @as([][]const u8, &.{});
                };
                cfg.db.storeConfig("rtmify_provisioned", "1") catch {};
            }
        }

        cfg.state.sync_in_progress.store(true, .seq_cst);
        cycle.runSyncCycle(cfg.db, cfg.profile, &runtime, cfg.state, alloc) catch |e| {
            cfg.state.sync_in_progress.store(false, .seq_cst);
            const msg = @errorName(e);
            cfg.state.setError(msg);
            cfg.db.storeConfig("last_sync_error", msg) catch {};
            cfg.db.storeConfig("last_sync_ok", "0") catch {};
            std.log.err("sync: cycle failed: {s}", .{msg});
            cfg.control.waitTimeout(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 300);
            continue;
        };
        cfg.state.sync_in_progress.store(false, .seq_cst);

        const synced_at = std.time.timestamp();
        cfg.state.last_sync_at.store(synced_at, .seq_cst);
        _ = cfg.state.sync_count.fetchAdd(1, .seq_cst);
        cfg.state.clearError();
        {
            const timestamp = std.fmt.allocPrint(alloc, "{d}", .{synced_at}) catch null;
            defer if (timestamp) |value| alloc.free(value);
            if (timestamp) |value| cfg.db.storeConfig("last_sync_at", value) catch {};
        }
        cfg.db.storeConfig("last_sync_error", "") catch {};
        cfg.db.storeConfig("last_sync_ok", "1") catch {};
        backoff = 30;

        cfg.control.waitTimeout(30 * std.time.ns_per_s);
    }
}
