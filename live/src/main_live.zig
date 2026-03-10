/// main_live.zig — entry point for rtmify-live HTTP server.
const std = @import("std");
const build_options = @import("build_options");
const graph_live = @import("graph_live.zig");
const sync_live = @import("sync_live.zig");
const server = @import("server.zig");
const sheets_mod = @import("sheets.zig");
const rtmify = @import("rtmify");
const license = rtmify.license;

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
    \\  --activate <key>       Activate license key
    \\  --deactivate           Deactivate license
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
    var show_help = false;
    var no_browser = false;
    var activate_key: ?[]const u8 = null;
    var do_deactivate = false;
    var repo_paths: std.ArrayList([]const u8) = .empty;
    var profile_name: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--no-browser")) {
            no_browser = true;
        } else if (std.mem.eql(u8, arg, "--deactivate")) {
            do_deactivate = true;
        } else if (std.mem.eql(u8, arg, "--activate") and i + 1 < args.len) {
            i += 1;
            activate_key = args[i];
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
        }
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (show_help) {
        try stdout.writeAll(help_text);
        return;
    }

    if (show_version) {
        try stdout.print("rtmify-live {s}\n", .{build_options.version});
        return;
    }

    if (activate_key) |key| {
        license.activate(gpa, .{}, key) catch {
            const ls_msg = license.lastLsError();
            if (ls_msg.len > 0) {
                try stderr.print("Error: {s}\n", .{ls_msg});
            } else {
                try stderr.writeAll("Error: license activation failed. Check your key and internet connection.\n");
            }
            std.process.exit(2);
        };
        try stdout.print("License activated successfully.\n", .{});
        return;
    }

    if (do_deactivate) {
        license.deactivate(gpa, .{}) catch |err| {
            try stderr.print("Warning: deactivation error: {s}\n", .{@errorName(err)});
        };
        try stdout.print("License deactivated.\n", .{});
        return;
    }

    std.log.info("rtmify-live {s} — db={s} port={d}", .{ build_options.version, db_path, port });

    var g = try graph_live.GraphDb.init(db_path);
    defer g.deinit();

    var state: sync_live.SyncState = .{};

    // License check — result stored in state for the web UI
    const lic_result = license.check(gpa, .{}) catch .not_activated;
    state.license_valid.store(lic_result == .ok, .seq_cst);
    if (lic_result != .ok) {
        std.log.warn("license check: {s} — web UI will show license gate", .{@tagName(lic_result)});
    }

    // Check if credentials + sheet_id exist — start sync thread if they do
    if (try g.getLatestCredential(gpa)) |cred| {
        defer gpa.free(cred);
        if (try g.getConfig("sheet_id", gpa)) |sheet_id| {
            defer gpa.free(sheet_id);
            const started = maybeStartSync(&g, &state, cred, sheet_id, gpa) catch |e| blk: {
                std.log.warn("sync thread not started: {s}", .{@errorName(e)});
                break :blk false;
            };
            if (started) std.log.info("sync thread started for sheet: {s}", .{sheet_id});
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

    // Find first available port (8000-8010) via quick probe
    var actual_port = port;
    while (actual_port <= port + 10) : (actual_port += 1) {
        const probe_addr = try std.net.Address.parseIp("0.0.0.0", actual_port);
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
        .state = &state,
        .alloc = gpa,
        .startSyncFn = startSyncCallback,
    };
    server.listen(actual_port, ctx) catch |e| return e;
}

/// Callback passed to ServerCtx so that POST /api/config can trigger sync start.
fn startSyncCallback(db: *graph_live.GraphDb, state: *sync_live.SyncState, alloc: std.mem.Allocator) void {
    // Guard: only start once
    if (state.sync_started.load(.seq_cst)) return;

    const cred = db.getLatestCredential(alloc) catch return;
    const cred_str = cred orelse return;
    defer alloc.free(cred_str);

    const sheet_id = db.getConfig("sheet_id", alloc) catch return;
    const sid = sheet_id orelse return;
    defer alloc.free(sid);

    const started = maybeStartSync(db, state, cred_str, sid, alloc) catch |e| blk: {
        std.log.warn("POST /api/config: sync start failed: {s}", .{@errorName(e)});
        break :blk false;
    };
    if (started) std.log.info("sync thread started via POST /api/config", .{});
}

fn maybeStartSync(
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    cred_json: []const u8,
    sheet_id: []const u8,
    alloc: std.mem.Allocator,
) !bool {
    // Guard: only start once
    if (state.sync_started.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return false;

    // Extract service account email and private key from credential JSON
    const email = sheets_mod.extractJsonFieldStatic(cred_json, "client_email") orelse {
        state.sync_started.store(false, .seq_cst); // reset so it can be retried
        return false;
    };
    const pem = sheets_mod.extractJsonFieldStatic(cred_json, "private_key") orelse {
        state.sync_started.store(false, .seq_cst);
        return false;
    };
    // Unescape \n in the PEM key
    const pem_unescaped = try unescapeNewlines(pem, alloc);
    defer alloc.free(pem_unescaped);

    const key = try sheets_mod.parsePemRsaKey(pem_unescaped, alloc);

    const cfg = sync_live.SyncConfig{
        .email = try alloc.dupe(u8, email),
        .key = key,
        .sheet_id = try alloc.dupe(u8, sheet_id),
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
    const url = try std.fmt.allocPrint(alloc, "http://localhost:{d}", .{port});
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

    const started = try maybeStartSync(&db, &state, "{\"type\":\"service_account\"}", "sheet-123", alloc);
    try testing.expect(!started);
    try testing.expect(!state.sync_started.load(.seq_cst));
}
