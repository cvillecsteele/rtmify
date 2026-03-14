/// main_live.zig — entry point for rtmify-live HTTP server.
const std = @import("std");
const build_options = @import("build_options");
const graph_live = @import("graph_live.zig");
const sync_live = @import("sync_live.zig");
const server = @import("server.zig");
const connection_mod = @import("connection.zig");
const secure_store_mod = @import("secure_store.zig");
const online_provider = @import("online_provider.zig");
const log_sink = @import("log_sink.zig");
const test_results_auth = @import("test_results_auth.zig");
const test_results_inbox = @import("test_results_inbox.zig");
const rtmify = @import("rtmify");
const license = rtmify.license;

const LicenseCommand = enum {
    info,
    install,
    clear,
};

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = log_sink.logFn,
};

const help_text =
    \\rtmify-live — requirements traceability live server
    \\
    \\Usage: rtmify-live [options]
    \\
    \\Options:
    \\  --port <N>             Listen port (default: 8000)
    \\  --db <path>            SQLite database path (default: graph.db)
    \\  --no-browser           Don't open browser on startup
    \\  --repo <path>          Repository path to scan (repeatable)
    \\  --profile <name>       Industry profile: medical|aerospace|automotive|generic
    \\  --inbox-dir <path>     Test result inbox directory (default: ~/.rtmify/inbox)
    \\  --license <path>       Use a specific signed license file
    \\  license info [--json]  Show installed license details
    \\  license install <path> Install a signed license file
    \\  license clear          Remove the installed license file
    \\  --license-status-json  Print structured license status JSON and exit
    \\  --version              Print version and exit
    \\  --help                 Print this help and exit
    \\
;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var db_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var db_path: [:0]const u8 = "graph.db";
    var port: u16 = 8000;
    var show_version = false;
    var show_license_status_json = false;
    var show_help = false;
    var no_browser = false;
    var license_path_override: ?[]const u8 = null;
    var license_cmd: ?LicenseCommand = null;
    var license_cmd_path: ?[]const u8 = null;
    var license_cmd_json = false;
    var repo_paths: std.ArrayList([]const u8) = .empty;
    var profile_name: ?[]const u8 = null;
    var inbox_dir_override: ?[]const u8 = null;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--license-status-json")) {
            show_license_status_json = true;
        } else if (std.mem.eql(u8, arg, "--license") and i + 1 < args.len) {
            i += 1;
            license_path_override = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            license_cmd_json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--no-browser")) {
            no_browser = true;
        } else if (std.mem.eql(u8, arg, "license")) {
            if (i + 1 >= args.len) {
                try stderr.writeAll("Error: missing license subcommand\n");
                std.process.exit(1);
            }
            i += 1;
            license_cmd = std.meta.stringToEnum(LicenseCommand, args[i]) orelse {
                try stderr.print("Error: unknown license subcommand: {s}\n", .{args[i]});
                std.process.exit(1);
            };
            if (license_cmd == .install) {
                if (i + 1 >= args.len) {
                    try stderr.writeAll("Error: missing license file path\n");
                    std.process.exit(1);
                }
                i += 1;
                license_cmd_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--db") and i + 1 < args.len) {
            i += 1;
            const src = args[i];
            @memcpy(db_path_buf[0..src.len], src);
            db_path_buf[src.len] = 0;
            db_path = db_path_buf[0..src.len :0];
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--repo") and i + 1 < args.len) {
            i += 1;
            try repo_paths.append(gpa, args[i]);
        } else if (std.mem.eql(u8, arg, "--profile") and i + 1 < args.len) {
            i += 1;
            profile_name = args[i];
        } else if (std.mem.eql(u8, arg, "--inbox-dir") and i + 1 < args.len) {
            i += 1;
            inbox_dir_override = args[i];
        }
    }

    if (show_help) {
        try stdout.writeAll(help_text);
        return;
    }

    if (show_version) {
        try stdout.print("rtmify-live {s}\n", .{build_options.version});
        return;
    }

    var license_service = try license.initDefaultHmacFile(gpa, .{
        .product = .live,
        .trial_policy = .requires_license,
        .license_path_override = license_path_override,
    });
    defer license_service.deinit(gpa);

    if (show_license_status_json) {
        var status = try license_service.getStatus(gpa);
        defer status.deinit(gpa);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const writer = buf.writer(gpa);
        try writer.writeAll("{\"state\":");
        try license.license_file.writeJsonString(writer, @tagName(status.state));
        try writer.writeAll(",\"permits_use\":");
        try writer.writeAll(if (status.permits_use) "true" else "false");
        try writer.writeAll(",\"detail_code\":");
        try license.license_file.writeJsonString(writer, @tagName(status.detail_code));
        try writer.writeAll(",\"license_path\":");
        try license.license_file.writeJsonString(writer, status.license_path);
        try writer.writeAll(",\"expected_key_fingerprint\":");
        try license.license_file.writeJsonString(writer, status.expected_key_fingerprint);
        try writer.writeAll(",\"license_signing_key_fingerprint\":");
        if (status.license_signing_key_fingerprint) |value| {
            try license.license_file.writeJsonString(writer, value);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}\n");
        try stdout.writeAll(buf.items);
        return;
    }

    if (license_cmd) |cmd| {
        switch (cmd) {
            .info => {
                var info = license_service.getInfo(gpa) catch |err| {
                    try stderr.print("Error: {s}\n", .{@errorName(err)});
                    std.process.exit(2);
                };
                defer info.deinit(gpa);
                if (license_cmd_json) {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(gpa);
                    const writer = buf.writer(gpa);
                    try writer.writeAll("{\"license_path\":");
                    try license.license_file.writeJsonString(writer, info.license_path);
                    try writer.writeAll(",\"expected_key_fingerprint\":");
                    try license.license_file.writeJsonString(writer, info.expected_key_fingerprint);
                    try writer.writeAll(",\"license_signing_key_fingerprint\":");
                    if (info.license_signing_key_fingerprint) |value| {
                        try license.license_file.writeJsonString(writer, value);
                    } else {
                        try writer.writeAll("null");
                    }
                    try writer.writeAll(",\"payload\":");
                    try license.license_file.writePayloadJson(writer, info.payload);
                    try writer.writeAll("}\n");
                    try stdout.writeAll(buf.items);
                } else {
                    try stdout.print("License ID: {s}\nProduct: {s}\nTier: {s}\nIssued To: {s}\n", .{
                        info.payload.license_id,
                        @tagName(info.payload.product),
                        @tagName(info.payload.tier),
                        info.payload.issued_to,
                    });
                    if (info.payload.org) |org| try stdout.print("Org: {s}\n", .{org});
                    if (info.payload.expires_at) |expires_at| {
                        try stdout.print("Expires At: {d}\n", .{expires_at});
                    } else {
                        try stdout.writeAll("Expires At: perpetual\n");
                    }
                    try stdout.print("Expected Key: {s}\n", .{license.displayFingerprint(info.expected_key_fingerprint)});
                    if (info.license_signing_key_fingerprint) |value| {
                        try stdout.print("File Key: {s}\n", .{license.displayFingerprint(value)});
                    }
                    try stdout.print("Path: {s}\n", .{info.license_path});
                }
                return;
            },
            .install => {
                const path = license_cmd_path orelse {
                    try stderr.writeAll("Error: missing license file path\n");
                    std.process.exit(1);
                };
                var status = try license_service.installFromPath(gpa, path);
                defer status.deinit(gpa);
                if (!status.permits_use) {
                    try stderr.print("Error: {s}\n", .{status.message orelse "license install failed"});
                    std.process.exit(2);
                }
                try stdout.writeAll("License installed successfully.\n");
                return;
            },
            .clear => {
                var status = try license_service.clearInstalledLicense(gpa);
                defer status.deinit(gpa);
                try stdout.writeAll("Installed license cleared.\n");
                return;
            },
        }
    }

    std.log.info("rtmify-live {s} — db={s} port={d}", .{ build_options.version, db_path, port });

    var g = try graph_live.GraphDb.init(db_path);
    defer g.deinit();

    const resolved_db_path = try resolveDbPath(gpa, db_path);
    defer gpa.free(resolved_db_path);
    try g.storeConfig("db_path", resolved_db_path);
    try g.storeConfig("live_version", build_options.version);
    if (std.process.getEnvVarOwned(gpa, "RTMIFY_TRAY_APP_VERSION")) |tray_version| {
        defer gpa.free(tray_version);
        try g.storeConfig("tray_app_version", tray_version);
    } else |_| {
        try g.storeConfig("tray_app_version", "not available");
    }
    if (std.process.getEnvVarOwned(gpa, "RTMIFY_LOG_PATH")) |log_path| {
        defer gpa.free(log_path);
        try g.storeConfig("log_path", log_path);
    } else |_| {
        const default_log_path = try log_sink.defaultLogPath(gpa);
        defer gpa.free(default_log_path);
        try g.storeConfig("log_path", default_log_path);
    }

    var secure_store = try secure_store_mod.initDefault(gpa);
    defer secure_store.deinit(gpa);
    var ingestion_auth = try test_results_auth.AuthState.initDefault(gpa);
    defer ingestion_auth.deinit(gpa);

    const inbox_dir = if (inbox_dir_override) |path|
        try gpa.dupe(u8, path)
    else
        try test_results_auth.defaultInboxDir(gpa);
    defer gpa.free(inbox_dir);
    try g.storeConfig("test_results_inbox_dir", inbox_dir);

    try connection_mod.migrateLegacyGoogleConfig(&g, &secure_store, gpa);

    var state: sync_live.SyncState = .{};

    var startup_license_status = try license_service.getStatus(gpa);
    defer startup_license_status.deinit(gpa);
    state.product_enabled.store(startup_license_status.permits_use, .seq_cst);
    if (!startup_license_status.permits_use) {
        std.log.warn("license check: {s} — product routes will be gated", .{@tagName(startup_license_status.state)});
    }

    var loaded_active = try connection_mod.loadActive(&g, &secure_store, gpa);
    defer loaded_active.deinit(gpa);
    if (startup_license_status.permits_use) {
        if (loaded_active == .active) {
            const started = maybeStartSync(&g, &state, loaded_active.active, gpa) catch |e| blk: {
                std.log.warn("sync thread not started: {s}", .{@errorName(e)});
                break :blk false;
            };
            if (started) std.log.info("sync thread started for configured provider connection", .{});
        }
    }

    // Store profile if given
    const profile_str = profile_name orelse "generic";
    try g.storeConfig("profile", profile_str);

    // Store CLI --repo paths in DB so they persist and are picked up by dynamic scan loop
    for (repo_paths.items) |p| {
        // Check if already stored to avoid duplicates
        var already: bool = false;
        var ci: usize = 0;
        while (ci < 64) : (ci += 1) {
            const ck = try std.fmt.allocPrint(gpa, "repo_path_{d}", .{ci});
            defer gpa.free(ck);
            const cv = try g.getConfig(ck, gpa);
            if (cv) |v| {
                defer gpa.free(v);
                if (std.mem.eql(u8, v, p)) { already = true; break; }
            } else break;
        }
        if (already) continue;
        // Find next empty slot
        var si: usize = 0;
        while (si < 64) : (si += 1) {
            const sk = try std.fmt.allocPrint(gpa, "repo_path_{d}", .{si});
            defer gpa.free(sk);
            const sv = try g.getConfig(sk, gpa);
            if (sv == null) {
                try g.storeConfig(sk, p);
                break;
            }
            gpa.free(sv.?);
        }
    }

    // Always spawn repo scan thread (picks up repos from DB dynamically each cycle)
    {
        const scan_ctx = try gpa.create(sync_live.RepoScanCtx);
        scan_ctx.* = .{
            .db = &g,
            .repo_paths = try repo_paths.toOwnedSlice(gpa),
            .state = &state,
            .alloc = gpa,
        };
        const t = try std.Thread.spawn(.{}, sync_live.repoScanThread, .{scan_ctx});
        t.detach();
        std.log.info("repo scan thread started", .{});
    }
    {
        const inbox_ctx = try gpa.create(test_results_inbox.InboxCtx);
        inbox_ctx.* = .{
            .db = &g,
            .state = &state,
            .inbox_dir = try gpa.dupe(u8, inbox_dir),
            .alloc = gpa,
        };
        const t = try std.Thread.spawn(.{}, test_results_inbox.inboxThread, .{inbox_ctx});
        t.detach();
        std.log.info("test results inbox thread started dir={s}", .{inbox_dir});
    }

    // Find first available port (8000-8010) via quick probe
    var actual_port = port;
    while (actual_port <= port + 10) : (actual_port += 1) {
        const probe_addr = try std.net.Address.parseIp("127.0.0.1", actual_port);
        var probe = probe_addr.listen(.{ .reuse_address = true }) catch |e| {
            if (e == error.AddressInUse) {
                std.log.warn("port {d} in use, trying {d}...", .{ actual_port, actual_port + 1 });
                continue;
            }
            return e;
        };
        probe.deinit();
        break;
    }

    // Store actual port so UI/reload knows where to connect
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{actual_port});
    defer gpa.free(port_str);
    try g.storeConfig("actual_port", port_str);

    // Open browser with the correct port
    if (!no_browser) {
        openBrowser(actual_port, gpa) catch |e| {
            std.log.warn("browser open failed: {s}", .{@errorName(e)});
        };
    }

    // Start HTTP server (blocks until shutdown)
    const ctx: server.ServerCtx = .{
        .db = &g,
        .secure_store = &secure_store,
        .state = &state,
        .license_service = &license_service,
        .test_results_auth = &ingestion_auth,
        .test_results_inbox_dir = inbox_dir,
        .alloc = gpa,
        .startSyncFn = startSyncCallback,
    };
    server.listen(actual_port, ctx) catch |e| return e;
}

fn resolveDbPath(alloc: std.mem.Allocator, db_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(db_path)) return alloc.dupe(u8, db_path);
    const cwd_real = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd_real);
    return std.fs.path.resolve(alloc, &.{ cwd_real, db_path });
}

/// Callback passed to ServerCtx so that POST /api/connection can trigger sync start.
fn startSyncCallback(db: *graph_live.GraphDb, secure_store: *secure_store_mod.Store, state: *sync_live.SyncState, alloc: std.mem.Allocator) void {
    // Guard: only start once
    if (state.sync_started.load(.seq_cst)) return;

    var loaded = connection_mod.loadActive(db, secure_store, alloc) catch return;
    defer loaded.deinit(alloc);
    if (loaded != .active) return;

    const started = maybeStartSync(db, state, loaded.active, alloc) catch |e| blk: {
        std.log.warn("POST /api/connection: sync start failed: {s}", .{@errorName(e)});
        break :blk false;
    };
    if (started) std.log.info("sync thread started via POST /api/connection", .{});
}

fn maybeStartSync(
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    active: @import("provider_common.zig").ActiveConnection,
    alloc: std.mem.Allocator,
) !bool {
    // Guard: only start once
    if (state.sync_started.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return false;

    var runtime = online_provider.ProviderRuntime.init(active, alloc) catch {
        state.sync_started.store(false, .seq_cst);
        return false;
    };
    runtime.deinit(alloc);

    const cfg = sync_live.SyncConfig{
        .active = try active.clone(alloc),
        .alloc = alloc,
        .db = db,
        .state = state,
    };

    const t = try std.Thread.spawn(.{}, sync_live.syncThread, .{cfg});
    t.detach();
    return true;
}

fn unescapeNewlines(s: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var j: usize = 0;
    while (j < s.len) : (j += 1) {
        if (s[j] == '\\' and j + 1 < s.len and s[j + 1] == 'n') {
            try buf.append(alloc, '\n');
            j += 1;
        } else {
            try buf.append(alloc, s[j]);
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn openBrowser(port: u16, alloc: std.mem.Allocator) !void {
    const url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
    defer alloc.free(url);

    const cmd: []const []const u8 = switch (@import("builtin").os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", url },
        else => &.{ "xdg-open", url },
    };

    var child = std.process.Child.init(cmd, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawnAndWait();
}

const testing = std.testing;

test "unescapeNewlines converts escaped newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const out = try unescapeNewlines("line1\\nline2\\n", alloc);
    try testing.expectEqualStrings("line1\nline2\n", out);
}

test "maybeStartSync returns false and resets state for invalid credential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var state: sync_live.SyncState = .{};

    var active = @import("provider_common.zig").ActiveConnection{
        .platform = .google,
        .credential_json = try alloc.dupe(u8, "{\"type\":\"service_account\"}"),
        .workbook_url = try alloc.dupe(u8, "https://docs.google.com/spreadsheets/d/sheet-123/edit"),
        .workbook_label = try alloc.dupe(u8, "sheet-123"),
        .credential_display = null,
        .target = .{ .google = .{ .sheet_id = try alloc.dupe(u8, "sheet-123") } },
    };
    defer active.deinit(alloc);

    const started = try maybeStartSync(&db, &state, active, alloc);
    try testing.expect(!started);
    try testing.expect(!state.sync_started.load(.seq_cst));
}
