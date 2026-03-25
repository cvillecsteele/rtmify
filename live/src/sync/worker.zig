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
    var owned_design_bom_sync = cfg.design_bom_sync;
    defer if (owned_design_bom_sync) |*source| source.deinit(cfg.alloc);
    var owned_soup_sync = cfg.soup_sync;
    defer if (owned_soup_sync) |*source| source.deinit(cfg.alloc);

    var active = owned_active.clone(alloc) catch {
        cfg.state.setError("provider_setup_failed");
        return;
    };
    defer active.deinit(alloc);

    var design_bom_source = if (owned_design_bom_sync) |source|
        source.clone(alloc) catch {
            cfg.state.setError("design_bom_source_setup_failed");
            return;
        }
    else
        null;
    defer if (design_bom_source) |*source| source.deinit(alloc);
    var soup_source = if (owned_soup_sync) |source|
        source.clone(alloc) catch {
            cfg.state.setError("soup_source_setup_failed");
            return;
        }
    else
        null;
    defer if (soup_source) |*source| source.deinit(alloc);

    var runtime = internal.ProviderRuntime.init(active, alloc) catch |e| {
        cfg.state.setError(@errorName(e));
        std.log.err("sync: provider init failed: {s}", .{@errorName(e)});
        return;
    };
    defer runtime.deinit(alloc);

    var design_bom_runtime: ?internal.ProviderRuntime = null;
    defer if (design_bom_runtime) |*runtime_ref| runtime_ref.deinit(alloc);
    var design_bom_last_change_token: ?[]u8 = null;
    defer if (design_bom_last_change_token) |tok| alloc.free(tok);
    var design_bom_last_local_mtime: ?i128 = null;
    var soup_runtime: ?internal.ProviderRuntime = null;
    defer if (soup_runtime) |*runtime_ref| runtime_ref.deinit(alloc);
    var soup_last_change_token: ?[]u8 = null;
    defer if (soup_last_change_token) |tok| alloc.free(tok);
    var soup_last_local_mtime: ?i128 = null;

    if (design_bom_source) |source| switch (source) {
        .provider => |provider_active| {
            design_bom_runtime = internal.ProviderRuntime.init(provider_active, alloc) catch |e| blk: {
                cfg.db.storeConfig("design_bom_last_sync_error", @errorName(e)) catch {};
                recordDesignBomSyncDiagnostic(cfg.db, "provider_init_failed", @errorName(e), alloc) catch {};
                break :blk null;
            };
        },
        .local_xlsx_path => {},
    };
    if (soup_source) |source| switch (source.source) {
        .provider => |provider_active| {
            soup_runtime = internal.ProviderRuntime.init(provider_active, alloc) catch |e| blk: {
                cfg.db.storeConfig("soup_last_sync_error", @errorName(e)) catch {};
                recordSoupSyncDiagnostic(cfg.db, "provider_init_failed", @errorName(e), alloc) catch {};
                break :blk null;
            };
        },
        .local_xlsx_path => {},
    };

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
        cycle.runSyncCycle(cfg.db, cfg.profile, cfg.workbook_slug, cfg.workbook_slug, cfg.workbook_id, &runtime, cfg.state, alloc) catch |e| {
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
        runDesignBomSyncIfNeeded(
            cfg.db,
            design_bom_source,
            if (design_bom_runtime) |*runtime_ref| runtime_ref else null,
            &design_bom_last_change_token,
            &design_bom_last_local_mtime,
            force_sync,
            alloc,
        ) catch |e| {
            const msg = @errorName(e);
            cfg.db.storeConfig("design_bom_last_sync_error", msg) catch {};
            cfg.db.storeConfig("design_bom_last_sync_ok", "0") catch {};
            recordDesignBomSyncDiagnostic(cfg.db, "sync_failed", msg, alloc) catch {};
            std.log.warn("design bom sync failed: {s}", .{msg});
        };
        runSoupSyncIfNeeded(
            cfg.db,
            soup_source,
            if (soup_runtime) |*runtime_ref| runtime_ref else null,
            &soup_last_change_token,
            &soup_last_local_mtime,
            force_sync,
            alloc,
        ) catch |e| {
            const msg = @errorName(e);
            cfg.db.storeConfig("soup_last_sync_error", msg) catch {};
            cfg.db.storeConfig("soup_last_sync_ok", "0") catch {};
            recordSoupSyncDiagnostic(cfg.db, "sync_failed", msg, alloc) catch {};
            std.log.warn("soup sync failed: {s}", .{msg});
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

fn runSoupSyncIfNeeded(
    db: *internal.GraphDb,
    soup_source: ?state_mod.SoupSyncSource,
    soup_runtime: ?*internal.ProviderRuntime,
    last_change_token: *?[]u8,
    last_local_mtime: *?i128,
    force_sync: bool,
    alloc: internal.Allocator,
) !void {
    const source = soup_source orelse return;
    switch (source.source) {
        .provider => {
            const runtime = soup_runtime orelse return;
            const change_token = try runtime.changeToken(alloc);
            if (last_change_token.*) |prev| {
                if (!force_sync and std.mem.eql(u8, prev, change_token)) {
                    alloc.free(change_token);
                    return;
                }
                alloc.free(prev);
            }
            last_change_token.* = @constCast(change_token);
            try syncSoupProvider(db, runtime, source.full_product_identifier, source.bom_name, alloc);
        },
        .local_xlsx_path => |path| {
            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();
            const stat = try file.stat();
            const current_mtime = stat.mtime;
            if (!force_sync and last_local_mtime.* != null and last_local_mtime.*.? == current_mtime) return;
            last_local_mtime.* = current_mtime;
            try syncSoupXlsx(db, path, source.full_product_identifier, source.bom_name, alloc);
        },
    }
}

fn runDesignBomSyncIfNeeded(
    db: *internal.GraphDb,
    design_bom_source: ?state_mod.DesignBomSyncSource,
    design_bom_runtime: ?*internal.ProviderRuntime,
    last_change_token: *?[]u8,
    last_local_mtime: *?i128,
    force_sync: bool,
    alloc: internal.Allocator,
) !void {
    const source = design_bom_source orelse return;
    switch (source) {
        .provider => {
            const runtime = design_bom_runtime orelse return;
            const change_token = try runtime.changeToken(alloc);
            if (last_change_token.*) |prev| {
                if (!force_sync and std.mem.eql(u8, prev, change_token)) {
                    alloc.free(change_token);
                    return;
                }
                alloc.free(prev);
            }
            last_change_token.* = @constCast(change_token);
            try syncDesignBomProvider(db, runtime, alloc);
        },
        .local_xlsx_path => |path| {
            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();
            const stat = try file.stat();
            const current_mtime = stat.mtime;
            if (!force_sync and last_local_mtime.* != null and last_local_mtime.*.? == current_mtime) return;
            last_local_mtime.* = current_mtime;
            try syncDesignBomXlsx(db, path, alloc);
        },
    }
}

fn syncDesignBomProvider(db: *internal.GraphDb, runtime: *internal.ProviderRuntime, alloc: internal.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const existing_tabs = try runtime.listTabs(a);
    defer internal.online_provider.freeTabRefs(existing_tabs, a);
    const design_bom_rows = try cycle.readOptionalTab(runtime, existing_tabs, "Design BOM", a);
    if (design_bom_rows.len == 0) return;
    const product_rows = try cycle.readOptionalTab(runtime, existing_tabs, "Product", a);
    var response = try internal.bom.ingestDesignBomRows(db, design_bom_rows, if (product_rows.len > 0) product_rows else null, .sheets, alloc);
    defer response.deinit(alloc);
    try recordDesignBomSyncResult(db, response, alloc);
}

fn syncDesignBomXlsx(db: *internal.GraphDb, path: []const u8, alloc: internal.Allocator) !void {
    var response = try internal.bom.ingestXlsxPath(db, path, alloc);
    defer response.deinit(alloc);
    try recordDesignBomSyncResult(db, response, alloc);
}

fn syncSoupProvider(
    db: *internal.GraphDb,
    runtime: *internal.ProviderRuntime,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    alloc: internal.Allocator,
) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const existing_tabs = try runtime.listTabs(a);
    defer internal.online_provider.freeTabRefs(existing_tabs, a);
    const soup_rows = try cycle.readOptionalTab(runtime, existing_tabs, "SOUP Components", a);
    if (soup_rows.len == 0) return;
    var response = try internal.soup.ingestSheetRows(db, soup_rows, full_product_identifier, bom_name, alloc);
    defer response.deinit(alloc);
    try recordSoupSyncResult(db, response, alloc);
}

fn syncSoupXlsx(
    db: *internal.GraphDb,
    path: []const u8,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    alloc: internal.Allocator,
) !void {
    var response = try internal.soup.ingestXlsxPath(db, path, full_product_identifier, bom_name, alloc);
    defer response.deinit(alloc);
    try recordSoupSyncResult(db, response, alloc);
}

fn recordDesignBomSyncResult(db: *internal.GraphDb, response: internal.bom.GroupedBomIngestResponse, alloc: internal.Allocator) !void {
    const now = std.time.timestamp();
    const timestamp = try std.fmt.allocPrint(alloc, "{d}", .{now});
    defer alloc.free(timestamp);
    try db.storeConfig("design_bom_last_sync_at", timestamp);
    try db.storeConfig("design_bom_last_sync_error", "");

    var had_failure = false;
    for (response.groups) |group| {
        if (group.status == .failed) {
            had_failure = true;
            if (group.error_detail) |detail| {
                try db.storeConfig("design_bom_last_sync_error", detail);
                try recordDesignBomSyncDiagnostic(db, "group_failed", detail, alloc);
            }
        }
        for (group.warnings) |warning| {
            var details: std.ArrayList(u8) = .empty;
            defer details.deinit(alloc);
            try details.appendSlice(alloc, "{\"warning_code\":");
            try internal.json_util.appendJsonQuoted(&details, warning.code, alloc);
            try details.appendSlice(alloc, ",\"warning_subject\":");
            if (warning.subject) |subject| {
                try internal.json_util.appendJsonQuoted(&details, subject, alloc);
            } else {
                try details.appendSlice(alloc, "null");
            }
            try details.appendSlice(alloc, ",\"full_product_identifier\":");
            try internal.json_util.appendJsonQuoted(&details, group.full_product_identifier, alloc);
            try details.appendSlice(alloc, ",\"bom_name\":");
            try internal.json_util.appendJsonQuoted(&details, group.bom_name, alloc);
            try details.append(alloc, '}');
            const subject = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ group.full_product_identifier, group.bom_name });
            defer alloc.free(subject);
            const dedupe_key = try std.fmt.allocPrint(alloc, "design_bom_sync:{s}:{s}:{s}", .{ group.full_product_identifier, group.bom_name, warning.code });
            defer alloc.free(dedupe_key);
            try db.upsertRuntimeDiagnostic(
                dedupe_key,
                9503,
                "warn",
                "Design BOM sync warning",
                warning.message,
                "design_bom_sync",
                subject,
                details.items,
            );
        }
    }
    try db.storeConfig("design_bom_last_sync_ok", if (had_failure) "0" else "1");
}

fn recordDesignBomSyncDiagnostic(db: *internal.GraphDb, code_suffix: []const u8, message: []const u8, alloc: internal.Allocator) !void {
    const dedupe_key = try std.fmt.allocPrint(alloc, "design_bom_sync:{s}", .{code_suffix});
    defer alloc.free(dedupe_key);
    try db.upsertRuntimeDiagnostic(
        dedupe_key,
        9503,
        "warn",
        "Design BOM sync issue",
        message,
        "design_bom_sync",
        null,
        "{}",
    );
}

fn recordSoupSyncResult(db: *internal.GraphDb, response: internal.soup.SoupIngestResponse, alloc: internal.Allocator) !void {
    const now = std.time.timestamp();
    const timestamp = try std.fmt.allocPrint(alloc, "{d}", .{now});
    defer alloc.free(timestamp);
    try db.storeConfig("soup_last_sync_at", timestamp);
    try db.storeConfig("soup_last_sync_error", "");
    try db.storeConfig("soup_last_sync_ok", "1");

    for (response.warnings) |warning| {
        var details: std.ArrayList(u8) = .empty;
        defer details.deinit(alloc);
        try details.appendSlice(alloc, "{\"warning_code\":");
        try internal.json_util.appendJsonQuoted(&details, warning.code, alloc);
        try details.appendSlice(alloc, ",\"warning_subject\":");
        if (warning.subject) |subject| {
            try internal.json_util.appendJsonQuoted(&details, subject, alloc);
        } else {
            try details.appendSlice(alloc, "null");
        }
        try details.appendSlice(alloc, ",\"full_product_identifier\":");
        try internal.json_util.appendJsonQuoted(&details, response.full_product_identifier, alloc);
        try details.appendSlice(alloc, ",\"bom_name\":");
        try internal.json_util.appendJsonQuoted(&details, response.bom_name, alloc);
        try details.appendSlice(alloc, ",\"bom_type\":\"software\"}");
        const subject = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ response.full_product_identifier, response.bom_name });
        defer alloc.free(subject);
        const dedupe_key = try std.fmt.allocPrint(alloc, "soup_sync:{s}:{s}:{s}", .{ response.full_product_identifier, response.bom_name, warning.code });
        defer alloc.free(dedupe_key);
        try db.upsertRuntimeDiagnostic(
            dedupe_key,
            9504,
            "warn",
            "SOUP sync warning",
            warning.message,
            "soup_sync",
            subject,
            details.items,
        );
    }
}

fn recordSoupSyncDiagnostic(db: *internal.GraphDb, code_suffix: []const u8, message: []const u8, alloc: internal.Allocator) !void {
    const dedupe_key = try std.fmt.allocPrint(alloc, "soup_sync:{s}", .{code_suffix});
    defer alloc.free(dedupe_key);
    try db.upsertRuntimeDiagnostic(
        dedupe_key,
        9504,
        "warn",
        "SOUP sync issue",
        message,
        "soup_sync",
        null,
        "{}",
    );
}
