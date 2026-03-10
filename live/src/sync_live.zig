/// sync_live.zig — background sync thread for rtmify-live.
///
/// Polls Google Drive modifiedTime every 30s. On change: fetches 4 tabs,
/// ingests rows via schema.zig into an ephemeral in-memory Graph, then
/// upserts all nodes and edges into the SQLite GraphDb. Writes status
/// columns and row colors back to the sheet.
///
/// Exponential backoff on error: 30→60→120→300s cap.
const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_mod = @import("rtmify").graph;
const schema = @import("rtmify").schema;
const xlsx = @import("rtmify").xlsx;

const graph_live = @import("graph_live.zig");
const sheets_mod = @import("sheets.zig");
const repo_mod = @import("repo.zig");
const annotations_mod = @import("annotations.zig");
const git_mod = @import("git.zig");
const profile_mod = @import("profile.zig");
const provision_mod = @import("provision.zig");

const GraphDb = graph_live.GraphDb;
const TokenCache = sheets_mod.TokenCache;
const RsaKey = sheets_mod.RsaKey;

// ---------------------------------------------------------------------------
// SyncState — shared between sync thread and HTTP server
// ---------------------------------------------------------------------------

pub const SyncState = struct {
    last_sync_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    has_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sync_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// True once a sync thread has been spawned; prevents double-start.
    sync_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Reflects the result of license.check() at startup / activation.
    license_valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // last_error is written under mu
    last_error: [256:0]u8 = .{0} ** 256,
    last_error_len: usize = 0,
    mu: std.Thread.Mutex = .{},

    pub fn setError(s: *SyncState, msg: []const u8) void {
        s.mu.lock();
        defer s.mu.unlock();
        const n = @min(msg.len, s.last_error.len - 1);
        @memcpy(s.last_error[0..n], msg[0..n]);
        s.last_error[n] = 0;
        s.last_error_len = n;
        s.has_error.store(true, .seq_cst);
    }

    pub fn clearError(s: *SyncState) void {
        s.mu.lock();
        defer s.mu.unlock();
        s.last_error[0] = 0;
        s.last_error_len = 0;
        s.has_error.store(false, .seq_cst);
    }

    pub fn getError(s: *SyncState, buf: []u8) usize {
        s.mu.lock();
        defer s.mu.unlock();
        const n = @min(s.last_error_len, buf.len);
        @memcpy(buf[0..n], s.last_error[0..n]);
        return n;
    }
};

// ---------------------------------------------------------------------------
// SyncConfig — passed to the sync thread at spawn time
// ---------------------------------------------------------------------------

pub const SyncConfig = struct {
    /// Service account email
    email: []const u8,
    /// RSA private key (parsed)
    key: RsaKey,
    /// Google Sheet ID (from URL)
    sheet_id: []const u8,
    /// Allocator for the sync thread
    alloc: Allocator,
    /// Database handle (shared)
    db: *GraphDb,
    /// Shared state (reads and writes by both threads)
    state: *SyncState,
};

// ---------------------------------------------------------------------------
// Sync thread entry point
// ---------------------------------------------------------------------------

pub fn syncThread(cfg: SyncConfig) void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();
    _ = cfg.alloc; // use GPA inside thread

    var http_client = std.http.Client{ .allocator = alloc };
    defer http_client.deinit();

    var token_cache: TokenCache = .{};

    var last_modified: i64 = 0;
    var backoff: u64 = 30; // seconds

    while (true) {
        const token = token_cache.getToken(cfg.email, cfg.key, &http_client, alloc) catch |e| {
            const msg = @errorName(e);
            cfg.state.setError(msg);
            std.log.err("sync: token refresh failed: {s}", .{msg});
            std.Thread.sleep(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 300);
            continue;
        };

        // Check Drive modifiedTime
        const mt = sheets_mod.getModifiedTime(&http_client, token, cfg.sheet_id, alloc) catch |e| {
            const msg = @errorName(e);
            cfg.state.setError(msg);
            std.log.err("sync: getModifiedTime failed: {s}", .{msg});
            std.Thread.sleep(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 300);
            continue;
        };

        if (mt <= last_modified) {
            // No change — sleep and try again
            std.Thread.sleep(30 * std.time.ns_per_s);
            continue;
        }

        std.log.info("sync: sheet changed (modifiedTime={d}), ingesting…", .{mt});

        // Provision missing tabs BEFORE sync so blank sheets are viable (non-fatal)
        {
            var prov_arena = std.heap.ArenaAllocator.init(alloc);
            defer prov_arena.deinit();
            const pa = prov_arena.allocator();
            const prov_done = (cfg.db.getConfig("rtmify_provisioned", pa) catch null) orelse "";
            if (prov_done.len == 0) {
                const prof_name = (cfg.db.getConfig("profile", pa) catch null) orelse "generic";
                const pid = profile_mod.fromString(prof_name) orelse .generic;
                const prof = profile_mod.get(pid);
                const tab_ids = sheets_mod.getSheetTabIds(&http_client, token, cfg.sheet_id, pa) catch &.{};
                _ = provision_mod.provisionSheet(&http_client, token, cfg.sheet_id, prof, tab_ids, pa) catch |e| blk: {
                    std.log.warn("provision failed: {s}", .{@errorName(e)});
                    break :blk @as([][]const u8, &.{});
                };
                cfg.db.storeConfig("rtmify_provisioned", "1") catch {};
            }
        }

        // Run a full sync cycle
        runSyncCycle(cfg.db, &http_client, token, cfg.sheet_id, cfg.state, alloc) catch |e| {
            const msg = @errorName(e);
            cfg.state.setError(msg);
            std.log.err("sync: cycle failed: {s}", .{msg});
            std.Thread.sleep(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 300);
            continue;
        };

        last_modified = mt;
        cfg.state.last_sync_at.store(std.time.timestamp(), .seq_cst);
        _ = cfg.state.sync_count.fetchAdd(1, .seq_cst);
        cfg.state.clearError();
        backoff = 30; // reset on success

        std.Thread.sleep(30 * std.time.ns_per_s);
    }
}

// ---------------------------------------------------------------------------
// Full sync cycle
// ---------------------------------------------------------------------------

/// Fetch all 4 tabs, ingest into graph, write back status + colors.
fn runSyncCycle(
    db: *GraphDb,
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    state: *SyncState,
    alloc: Allocator,
) anyerror!void {
    _ = state;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Fetch core tabs (include header row: start from row 1)
    const tests_rows = try sheets_mod.readRows(client, token, sheet_id, "Tests!A1:Z", a);
    const un_rows = try sheets_mod.readRows(client, token, sheet_id, "User%20Needs!A1:Z", a);
    const req_rows = try sheets_mod.readRows(client, token, sheet_id, "Requirements!A1:Z", a);
    const risk_rows = try sheets_mod.readRows(client, token, sheet_id, "Risks!A1:Z", a);
    // Extended tabs — non-fatal, may not exist for all profiles
    const di_rows = sheets_mod.readRows(client, token, sheet_id, "Design%20Inputs!A1:Z", a) catch &.{};
    const do_rows = sheets_mod.readRows(client, token, sheet_id, "Design%20Outputs!A1:Z", a) catch &.{};
    const ci_rows = sheets_mod.readRows(client, token, sheet_id, "Configuration%20Items!A1:Z", a) catch &.{};

    // 2. Convert [][][]const u8 rows to xlsx.SheetData
    const sheet_data = [_]xlsx.SheetData{
        .{ .name = "Tests", .rows = @ptrCast(tests_rows) },
        .{ .name = "User Needs", .rows = @ptrCast(un_rows) },
        .{ .name = "Requirements", .rows = @ptrCast(req_rows) },
        .{ .name = "Risks", .rows = @ptrCast(risk_rows) },
        .{ .name = "Design Inputs", .rows = @ptrCast(di_rows) },
        .{ .name = "Design Outputs", .rows = @ptrCast(do_rows) },
        .{ .name = "Configuration Items", .rows = @ptrCast(ci_rows) },
    };

    // 3. Ingest into ephemeral in-memory Graph via schema.zig
    var g = graph_mod.Graph.init(a);
    defer g.deinit();

    var diag = @import("rtmify").diagnostic.Diagnostics.init(a);
    defer diag.deinit();

    _ = schema.ingestValidated(&g, &sheet_data, &diag) catch |e| {
        std.log.warn("sync: ingest errors (continuing): {s}", .{@errorName(e)});
        // Non-fatal: partial ingest is OK; we'll upsert what we have
    };

    // 4. Port nodes from in-memory Graph to SQLite GraphDb
    try portGraphToDb(db, &g, alloc);

    // 5. Fetch numeric tab IDs (needed for row color formatting)
    const tab_ids = sheets_mod.getSheetTabIds(client, token, sheet_id, a) catch |e| blk: {
        std.log.warn("sync: getSheetTabIds failed (colors skipped): {s}", .{@errorName(e)});
        break :blk &[_]sheets_mod.SheetTabId{};
    };

    // 6. Write back status columns and row colors
    try writeBackStatus(db, client, token, sheet_id, req_rows, risk_rows, un_rows, tab_ids, a);

    std.log.info("sync: cycle complete — {d} nodes", .{g.nodes.count()});
}

// ---------------------------------------------------------------------------
// Port in-memory Graph → SQLite GraphDb
// ---------------------------------------------------------------------------

fn portGraphToDb(db: *GraphDb, g: *graph_mod.Graph, alloc: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Upsert nodes
    var node_iter = g.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;
        const props_json = try serializeProperties(&node.properties, a);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(props_json);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hash_hex = std.fmt.bytesToHex(digest, .lower);
        try db.upsertNode(
            node.id,
            node.node_type.toString(),
            props_json,
            &hash_hex,
        );
    }

    // Add edges
    for (g.edges.items) |edge| {
        db.addEdge(edge.from_id, edge.to_id, edge.label.toString()) catch |e| {
            // Duplicate edges are fine (INSERT OR IGNORE)
            if (e != error.Exec) return e;
        };
    }
}

/// Serialize a StringHashMapUnmanaged([]const u8) to a JSON object string.
fn serializeProperties(props: *const std.StringHashMapUnmanaged([]const u8), alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '{');
    var it = props.iterator();
    var first = true;
    while (it.next()) |kv| {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.append(alloc, '"');
        try appendJsonEscaped(&buf, kv.key_ptr.*, alloc);
        try buf.appendSlice(alloc, "\":\"");
        try appendJsonEscaped(&buf, kv.value_ptr.*, alloc);
        try buf.append(alloc, '"');
    }
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn appendJsonEscaped(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

// ---------------------------------------------------------------------------
// Status writeback helpers
// ---------------------------------------------------------------------------

/// Compute a simple status string for a Requirements row based on graph state.
fn requirementStatus(db: *GraphDb, req_id: []const u8, alloc: Allocator) []const u8 {
    // Check if node exists and has test linkage
    const node = db.getNode(req_id, alloc) catch return "ERROR";
    if (node == null) return "MISSING";
    defer if (node) |n| {
        alloc.free(n.id);
        alloc.free(n.type);
        alloc.free(n.properties);
        if (n.suspect_reason) |r| alloc.free(r);
    };
    // Check for TESTED_BY edges
    var tests: std.ArrayList(graph_live.Edge) = .empty;
    db.edgesFrom(req_id, alloc, &tests) catch return "ERROR";
    defer {
        for (tests.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        tests.deinit(alloc);
    }
    var has_test = false;
    for (tests.items) |e| {
        if (std.mem.eql(u8, e.label, "TESTED_BY") or std.mem.eql(u8, e.label, "HAS_TEST")) {
            has_test = true;
            break;
        }
    }
    if (!has_test) return "NO_TEST_LINKED";
    return "OK";
}

/// Look up the numeric sheetId for a tab title. Returns null if not found.
fn findTabId(tab_ids: []const sheets_mod.SheetTabId, title: []const u8) ?i64 {
    for (tab_ids) |t| {
        if (std.mem.eql(u8, t.title, title)) return t.id;
    }
    return null;
}

/// Color constants (Google Sheets light palette: r,g,b as 0.0–1.0)
const color_ok = [3]f32{ 0.714, 0.882, 0.804 }; // light green
const color_warn = [3]f32{ 0.988, 0.910, 0.698 }; // light yellow
const color_bad = [3]f32{ 0.957, 0.780, 0.765 }; // light red
const color_none = [3]f32{ 1.0, 1.0, 1.0 }; // white (clear)

fn statusColor(status: []const u8) [3]f32 {
    if (std.mem.eql(u8, status, "OK")) return color_ok;
    if (std.mem.eql(u8, status, "NO_TEST_LINKED") or
        std.mem.eql(u8, status, "NO_REQ_LINKED") or
        std.mem.eql(u8, status, "MISSING")) return color_warn;
    return color_bad;
}

/// Write status columns for Requirements, Risks, and User Needs tabs.
fn writeBackStatus(
    db: *GraphDb,
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    req_rows: [][][]const u8,
    risk_rows: [][][]const u8,
    un_rows: [][][]const u8,
    tab_ids: []const sheets_mod.SheetTabId,
    alloc: Allocator,
) !void {
    // --- Requirements ---
    if (req_rows.len > 1) {
        const header = req_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        if (id_col != null and status_col != null) {
            const scol = status_col.?;
            const numeric_id = findTabId(tab_ids, "Requirements");
            var statuses: std.ArrayList(sheets_mod.ValueRange) = .empty;
            defer statuses.deinit(alloc);
            var color_reqs: std.ArrayList(u8) = .empty;
            defer color_reqs.deinit(alloc);
            try color_reqs.append(alloc, '[');
            var color_count: usize = 0;
            for (req_rows[1..], 0..) |row, i| {
                const row_num = i + 2; // 1-indexed sheet row
                const req_id = if (id_col.? < row.len) row[id_col.?] else "";
                if (req_id.len == 0) continue;
                const status = requirementStatus(db, req_id, alloc);
                const col_letter = colLetter(scol);
                const range = try std.fmt.allocPrint(alloc, "Requirements!{s}{d}", .{ col_letter, row_num });
                try statuses.append(alloc, .{
                    .range = range,
                    .values = &[_][]const u8{try alloc.dupe(u8, status)},
                });
                if (numeric_id) |nid| {
                    const col = statusColor(status);
                    const req = try sheets_mod.buildRepeatCellRequest(
                        nid,
                        @intCast(i + 1), // 0-based: header=0, first data row=1
                        0,
                        @intCast(header.len),
                        col[0], col[1], col[2],
                        alloc,
                    );
                    defer alloc.free(req);
                    if (color_count > 0) try color_reqs.append(alloc, ',');
                    try color_reqs.appendSlice(alloc, req);
                    color_count += 1;
                }
            }
            try color_reqs.append(alloc, ']');
            if (statuses.items.len > 0) {
                sheets_mod.batchUpdateValues(client, token, sheet_id, statuses.items, alloc) catch |e| {
                    std.log.warn("sync: requirements status writeback failed: {s}", .{@errorName(e)});
                };
            }
            if (color_count > 0) {
                sheets_mod.batchUpdateFormat(client, token, sheet_id, color_reqs.items, alloc) catch |e| {
                    std.log.warn("sync: requirements color writeback failed: {s}", .{@errorName(e)});
                };
            }
        }
    }

    // --- Risks ---
    if (risk_rows.len > 1) {
        const header = risk_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        if (id_col != null and status_col != null) {
            const numeric_id = findTabId(tab_ids, "Risks");
            var statuses: std.ArrayList(sheets_mod.ValueRange) = .empty;
            defer statuses.deinit(alloc);
            var color_reqs: std.ArrayList(u8) = .empty;
            defer color_reqs.deinit(alloc);
            try color_reqs.append(alloc, '[');
            var color_count: usize = 0;
            for (risk_rows[1..], 0..) |row, i| {
                const row_num = i + 2;
                const risk_id = if (id_col.? < row.len) row[id_col.?] else "";
                if (risk_id.len == 0) continue;
                const node = db.getNode(risk_id, alloc) catch null;
                const status: []const u8 = if (node != null) "OK" else "MISSING";
                if (node) |n| {
                    alloc.free(n.id);
                    alloc.free(n.type);
                    alloc.free(n.properties);
                    if (n.suspect_reason) |r| alloc.free(r);
                }
                const col_letter = colLetter(status_col.?);
                const range = try std.fmt.allocPrint(alloc, "Risks!{s}{d}", .{ col_letter, row_num });
                try statuses.append(alloc, .{
                    .range = range,
                    .values = &[_][]const u8{try alloc.dupe(u8, status)},
                });
                if (numeric_id) |nid| {
                    const col = statusColor(status);
                    const req = try sheets_mod.buildRepeatCellRequest(
                        nid, @intCast(i + 1), 0, @intCast(header.len),
                        col[0], col[1], col[2], alloc,
                    );
                    defer alloc.free(req);
                    if (color_count > 0) try color_reqs.append(alloc, ',');
                    try color_reqs.appendSlice(alloc, req);
                    color_count += 1;
                }
            }
            try color_reqs.append(alloc, ']');
            if (statuses.items.len > 0) {
                sheets_mod.batchUpdateValues(client, token, sheet_id, statuses.items, alloc) catch |e| {
                    std.log.warn("sync: risks status writeback failed: {s}", .{@errorName(e)});
                };
            }
            if (color_count > 0) {
                sheets_mod.batchUpdateFormat(client, token, sheet_id, color_reqs.items, alloc) catch |e| {
                    std.log.warn("sync: risks color writeback failed: {s}", .{@errorName(e)});
                };
            }
        }
    }

    // --- User Needs ---
    if (un_rows.len > 1) {
        const header = un_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        if (id_col != null and status_col != null) {
            const numeric_id = findTabId(tab_ids, "User Needs");
            var statuses: std.ArrayList(sheets_mod.ValueRange) = .empty;
            defer statuses.deinit(alloc);
            var color_reqs: std.ArrayList(u8) = .empty;
            defer color_reqs.deinit(alloc);
            try color_reqs.append(alloc, '[');
            var color_count: usize = 0;
            for (un_rows[1..], 0..) |row, i| {
                const row_num = i + 2;
                const un_id = if (id_col.? < row.len) row[id_col.?] else "";
                if (un_id.len == 0) continue;
                var edges: std.ArrayList(graph_live.Edge) = .empty;
                db.edgesTo(un_id, alloc, &edges) catch {
                    edges.deinit(alloc);
                    continue;
                };
                var linked = false;
                for (edges.items) |e| {
                    if (std.mem.eql(u8, e.label, "DERIVES_FROM")) {
                        linked = true;
                        break;
                    }
                }
                for (edges.items) |e| {
                    alloc.free(e.id);
                    alloc.free(e.from_id);
                    alloc.free(e.to_id);
                    alloc.free(e.label);
                }
                edges.deinit(alloc);
                const status: []const u8 = if (linked) "OK" else "NO_REQ_LINKED";
                const col_letter = colLetter(status_col.?);
                const range = try std.fmt.allocPrint(alloc, "User Needs!{s}{d}", .{ col_letter, row_num });
                try statuses.append(alloc, .{
                    .range = range,
                    .values = &[_][]const u8{try alloc.dupe(u8, status)},
                });
                if (numeric_id) |nid| {
                    const col = statusColor(status);
                    const req = try sheets_mod.buildRepeatCellRequest(
                        nid, @intCast(i + 1), 0, @intCast(header.len),
                        col[0], col[1], col[2], alloc,
                    );
                    defer alloc.free(req);
                    if (color_count > 0) try color_reqs.append(alloc, ',');
                    try color_reqs.appendSlice(alloc, req);
                    color_count += 1;
                }
            }
            try color_reqs.append(alloc, ']');
            if (statuses.items.len > 0) {
                sheets_mod.batchUpdateValues(client, token, sheet_id, statuses.items, alloc) catch |e| {
                    std.log.warn("sync: user needs status writeback failed: {s}", .{@errorName(e)});
                };
            }
            if (color_count > 0) {
                sheets_mod.batchUpdateFormat(client, token, sheet_id, color_reqs.items, alloc) catch |e| {
                    std.log.warn("sync: user needs color writeback failed: {s}", .{@errorName(e)});
                };
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Column lookup utilities
// ---------------------------------------------------------------------------

fn findCol(header: [][]const u8, name: []const u8) ?usize {
    for (header, 0..) |h, i| {
        if (std.ascii.eqlIgnoreCase(h, name)) return i;
    }
    return null;
}

/// Convert 0-based column index to spreadsheet letter (A, B, …, Z, AA, …).
fn colLetter(idx: usize) [3]u8 {
    var result: [3]u8 = .{ 'A', 0, 0 };
    if (idx < 26) {
        result[0] = 'A' + @as(u8, @intCast(idx));
        return result;
    }
    // Two-letter: A=0 → AA=26
    const a = idx / 26 - 1;
    const b = idx % 26;
    result[0] = 'A' + @as(u8, @intCast(a));
    result[1] = 'A' + @as(u8, @intCast(b));
    result[2] = 0;
    return result;
}

// ---------------------------------------------------------------------------
// Repo scan thread (code traceability)
// ---------------------------------------------------------------------------

pub const RepoScanCtx = struct {
    db: *GraphDb,
    repo_paths: []const []const u8,
    state: *SyncState,
    alloc: Allocator,
    git_exe_override: ?[]const u8 = null,
    git_timeout_ms_override: ?u64 = null,
};

/// Background thread: scans repos for source files + annotations + commits.
/// Loops every 60 seconds. Each cycle:
///   1. Builds list of known req IDs from the graph DB.
///   2. For each repo_path: scans files, upserts SourceFile/TestFile nodes.
///   3. Scans each file for annotations, upserts CodeAnnotation nodes + edges.
///   4. Runs git log, upserts Commit nodes + COMMITTED_IN edges.
///   5. Rate-limited blame: first 50 annotations per cycle.
pub fn repoScanThread(ctx: *RepoScanCtx) void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Verify git is on PATH before starting scan loop
    {
        const git_check = std.process.Child.run(.{
            .argv = &.{ "git", "--version" },
            .allocator = gpa,
        }) catch {
            std.log.err("git not found on PATH — repo scan disabled", .{});
            return;
        };
        defer gpa.free(git_check.stdout);
        defer gpa.free(git_check.stderr);
        if (git_check.term != .Exited or git_check.term.Exited != 0) {
            std.log.err("git check failed — repo scan disabled", .{});
            return;
        }
    }

    while (true) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        repoScanCycle(ctx, a) catch |e| {
            std.log.warn("repo scan cycle failed: {s}", .{@errorName(e)});
        };

        std.Thread.sleep(60 * std.time.ns_per_s);
    }
}

fn repoScanCycle(ctx: *RepoScanCtx, alloc: Allocator) !void {
    const git_options = git_mod.GitOptions{
        .exe = ctx.git_exe_override,
        .timeout_ms = ctx.git_timeout_ms_override,
    };
    // Build dynamic list of repo paths from DB (picks up UI-added repos each cycle)
    var dyn_paths: std.ArrayList([]const u8) = .empty;
    defer dyn_paths.deinit(alloc);
    {
        var idx: usize = 0;
        while (idx < 64) : (idx += 1) {
            const key = try std.fmt.allocPrint(alloc, "repo_path_{d}", .{idx});
            defer alloc.free(key);
            const p = (try ctx.db.getConfig(key, alloc)) orelse continue;
            try dyn_paths.append(alloc, p);
        }
    }
    // Merge CLI-provided paths (already stored in DB at startup, but keep as fallback)
    outer: for (ctx.repo_paths) |p| {
        for (dyn_paths.items) |dp| {
            if (std.mem.eql(u8, dp, p)) continue :outer;
        }
        try dyn_paths.append(alloc, try alloc.dupe(u8, p));
    }

    if (dyn_paths.items.len == 0) return; // no repos configured yet

    // Build known req IDs from database
    const known_ids = try annotations_mod.buildKnownIds(ctx.db, alloc);

    for (dyn_paths.items) |repo_path| {
        try ctx.db.clearRuntimeDiagnosticsBySubjectPrefix("repo_scan", repo_path);
        try ctx.db.clearRuntimeDiagnosticsBySubjectPrefix("git", repo_path);
        try ctx.db.clearRuntimeDiagnosticsBySubjectPrefix("annotation", repo_path);

        // Get last scan time for this repo
        const last_scan_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{repo_path});
        const last_scan_str = (try ctx.db.getConfig(last_scan_key, alloc)) orelse "0";
        const last_scan: i64 = std.fmt.parseInt(i64, last_scan_str, 10) catch 0;

        // Get last git hash
        const git_key = try std.fmt.allocPrint(alloc, "git_last_hash_{s}", .{repo_path});
        const last_hash = try ctx.db.getConfig(git_key, alloc);

        // Scan repo files
        const files = repo_mod.scanRepo(repo_path, last_scan, alloc) catch |e| {
            std.log.warn("repo scan {s}: {s}", .{ repo_path, @errorName(e) });
            try upsertRuntimeDiag(ctx.db, "repo_scan", 904, "err", "Repo path not readable", try std.fmt.allocPrint(alloc, "Repo scan failed for {s}: {s}", .{ repo_path, @errorName(e) }), repo_path, "{}");
            continue;
        };

        // Collect existing CodeAnnotation IDs for this repo (for stale removal)
        var existing_ann_ids = std.StringHashMap(void).init(alloc);
        defer existing_ann_ids.deinit();
        {
            var st = try ctx.db.db.prepare(
                "SELECT id FROM nodes WHERE type='CodeAnnotation' AND id LIKE ? || '%'"
            );
            defer st.finalize();
            try st.bindText(1, repo_path);
            while (try st.step()) {
                const id = try alloc.dupe(u8, st.columnText(0));
                try existing_ann_ids.put(id, {});
            }
        }

        var seen_ann_ids = std.StringHashMap(void).init(alloc);
        defer seen_ann_ids.deinit();

        var blame_count: usize = 0;

        for (files) |file| {
            // Upsert SourceFile or TestFile node
            const node_type: []const u8 = switch (file.kind) {
                .source => "SourceFile",
                .test_file => "TestFile",
                .ignored => continue,
            };

            // Scan for annotations
            const scan = annotations_mod.scanFileDetailed(file.path, known_ids, alloc) catch |e| {
                try upsertRuntimeDiag(ctx.db, "annotation", 1105, "info", "Unrecognized file extension", try std.fmt.allocPrint(alloc, "Annotation scan failed for {s}: {s}", .{ file.path, @errorName(e) }), file.path, "{}");
                continue;
            };
            const anns = scan.annotations;
            const annotation_count = anns.len;
            const props = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"repo\":\"{s}\",\"annotation_count\":{d}}}", .{ file.path, repo_path, annotation_count });
            try ctx.db.upsertNode(file.path, node_type, props, null);

            if (hasDuplicateAnnotationLine(anns)) {
                try upsertRuntimeDiag(ctx.db, "annotation", 1106, "info", "Multiple annotations on same line", try std.fmt.allocPrint(alloc, "File {s} has multiple requirement annotations on the same line", .{file.path}), file.path, "{}");
            }

            for (scan.unknown_refs) |unknown| {
                const subject = try std.fmt.allocPrint(alloc, "{s}:{d}:{s}", .{ unknown.file_path, unknown.line_number, unknown.ref_id });
                const details = try std.fmt.allocPrint(alloc, "{{\"ref_id\":\"{s}\",\"line\":{d}}}", .{ unknown.ref_id, unknown.line_number });
                try upsertRuntimeDiag(ctx.db, "annotation", 1101, "warn", "Annotation references unknown requirement ID", try std.fmt.allocPrint(alloc, "Unknown annotation reference {s} at {s}:{d}", .{ unknown.ref_id, unknown.file_path, unknown.line_number }), subject, details);
            }

            for (anns) |ann| {
                // Upsert CodeAnnotation node with context
                const ann_id = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ file.path, ann.line_number });
                {
                    var ap: std.ArrayList(u8) = .empty;
                    try ap.appendSlice(alloc, "{\"req_id\":\"");
                    try appendJsonEscaped(&ap, ann.req_id, alloc);
                    try ap.appendSlice(alloc, "\",\"file_path\":\"");
                    try appendJsonEscaped(&ap, ann.file_path, alloc);
                    try ap.writer(alloc).print("\",\"line_number\":{d},\"context\":\"", .{ann.line_number});
                    try appendJsonEscaped(&ap, ann.context, alloc);
                    try ap.appendSlice(alloc, "\"}");
                    try ctx.db.upsertNode(ann_id, "CodeAnnotation", ap.items, null);
                }
                try seen_ann_ids.put(try alloc.dupe(u8, ann_id), {});

                // PRD edge model:
                // Requirement → CodeAnnotation via ANNOTATED_AT
                ctx.db.addEdge(ann.req_id, ann_id, "ANNOTATED_AT") catch {};
                // SourceFile/TestFile → CodeAnnotation via CONTAINS
                ctx.db.addEdge(file.path, ann_id, "CONTAINS") catch {};
                // Requirement → SourceFile via IMPLEMENTED_IN (source files only)
                if (file.kind == .source) {
                    ctx.db.addEdge(ann.req_id, file.path, "IMPLEMENTED_IN") catch {};
                }
                // Requirement → TestFile via VERIFIED_BY_CODE (test files only)
                if (file.kind == .test_file) {
                    ctx.db.addEdge(ann.req_id, file.path, "VERIFIED_BY_CODE") catch {};
                }

                // Rate-limited blame
                if (blame_count < 50) {
                    const blame_subject = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ file.path, ann.line_number });
                    if (git_mod.gitBlameWithOptions(repo_path, file.path, ann.line_number, git_options, alloc)) |blame| {
                        var bp: std.ArrayList(u8) = .empty;
                        try bp.appendSlice(alloc, "{\"req_id\":\"");
                        try appendJsonEscaped(&bp, ann.req_id, alloc);
                        try bp.appendSlice(alloc, "\",\"file_path\":\"");
                        try appendJsonEscaped(&bp, ann.file_path, alloc);
                        try bp.writer(alloc).print("\",\"line_number\":{d},\"blame_author\":\"", .{ann.line_number});
                        try appendJsonEscaped(&bp, blame.author, alloc);
                        try bp.appendSlice(alloc, "\",\"author_email\":\"");
                        try appendJsonEscaped(&bp, blame.author_email, alloc);
                        try bp.writer(alloc).print("\",\"author_time\":{d},\"short_hash\":\"", .{blame.author_time});
                        const sh = blame.commit_hash[0..@min(7, blame.commit_hash.len)];
                        try appendJsonEscaped(&bp, sh, alloc);
                        try bp.appendSlice(alloc, "\",\"context\":\"");
                        try appendJsonEscaped(&bp, ann.context, alloc);
                        try bp.appendSlice(alloc, "\"}");
                        try ctx.db.upsertNode(ann_id, "CodeAnnotation", bp.items, null);
                        try clearRuntimeDiagByCodeAndSubject(ctx.db, "annotation", blame_subject, 1002);
                        try clearRuntimeDiagByCodeAndSubject(ctx.db, "annotation", blame_subject, 1004);
                        try clearRuntimeDiagByCodeAndSubject(ctx.db, "annotation", blame_subject, 1005);
                        blame_count += 1;
                    } else |e| {
                        const diag_code: u16 = if (e == error.Timeout)
                            1005
                        else if (e == error.BlameParseErr)
                            1004
                        else
                            1002;
                        const title = if (diag_code == 1005)
                            "git command timed out (> 10s)"
                        else if (diag_code == 1004)
                            "Failed to parse git blame output"
                        else
                            "git blame command failed";
                        try upsertRuntimeDiag(ctx.db, "annotation", diag_code, "warn", title, try std.fmt.allocPrint(alloc, "git blame failed for {s}:{d}: {s}", .{ file.path, ann.line_number, @errorName(e) }), blame_subject, "{}");
                    }
                }
            }
        }

        // Git log integration
        const commits = git_mod.gitLogWithOptions(repo_path, last_hash, known_ids, git_options, alloc) catch |e| blk: {
            const diag_code: u16 = if (e == error.Timeout)
                1005
            else if (e == error.CommitParseErr)
                1003
            else
                1001;
            const title = if (diag_code == 1005)
                "git command timed out (> 10s)"
            else if (diag_code == 1003)
                "Commit message parse error"
            else
                "git log command failed";
            try upsertRuntimeDiag(ctx.db, "git", diag_code, "warn", title, try std.fmt.allocPrint(alloc, "git log failed for {s}: {s}", .{ repo_path, @errorName(e) }), repo_path, "{}");
            break :blk &.{};
        };
        if (commits.len > 0) {
            try clearRuntimeDiagByCodeAndSubject(ctx.db, "git", repo_path, 1001);
            try clearRuntimeDiagByCodeAndSubject(ctx.db, "git", repo_path, 1003);
            try clearRuntimeDiagByCodeAndSubject(ctx.db, "git", repo_path, 1005);
        }
        var last_hash_new: ?[]const u8 = null;
        for (commits) |commit| {
            // Upsert Commit node with full fields including email and req_ids
            var cp: std.ArrayList(u8) = .empty;
            try cp.appendSlice(alloc, "{\"hash\":\"");
            try appendJsonEscaped(&cp, commit.hash, alloc);
            try cp.appendSlice(alloc, "\",\"short_hash\":\"");
            try appendJsonEscaped(&cp, commit.short_hash, alloc);
            try cp.appendSlice(alloc, "\",\"author\":\"");
            try appendJsonEscaped(&cp, commit.author, alloc);
            try cp.appendSlice(alloc, "\",\"email\":\"");
            try appendJsonEscaped(&cp, commit.email, alloc);
            try cp.appendSlice(alloc, "\",\"date\":\"");
            try appendJsonEscaped(&cp, commit.date_iso, alloc);
            try cp.appendSlice(alloc, "\",\"message\":\"");
            try appendJsonEscaped(&cp, commit.message, alloc);
            try cp.appendSlice(alloc, "\",\"req_ids\":[");
            for (commit.req_ids, 0..) |rid, ri| {
                if (ri > 0) try cp.append(alloc, ',');
                try cp.append(alloc, '"');
                try appendJsonEscaped(&cp, rid, alloc);
                try cp.append(alloc, '"');
            }
            try cp.appendSlice(alloc, "]}");
            try ctx.db.upsertNode(commit.hash, "Commit", cp.items, null);
            for (commit.req_ids) |req_id| {
                ctx.db.addEdge(req_id, commit.hash, "COMMITTED_IN") catch {};
            }
            if (last_hash_new == null) last_hash_new = commit.hash; // most recent
        }

        // Remove stale CodeAnnotation nodes (annotations removed from source since last scan)
        var stale_it = existing_ann_ids.keyIterator();
        while (stale_it.next()) |id| {
            if (seen_ann_ids.contains(id.*)) continue;
            ctx.db.deleteNode(id.*) catch |e| {
                std.log.warn("deleteNode {s}: {s}", .{ id.*, @errorName(e) });
            };
        }

        // Update config: last scan time and git hash
        const now_str = try std.fmt.allocPrint(alloc, "{d}", .{std.time.timestamp()});
        try ctx.db.storeConfig(last_scan_key, now_str);
        if (last_hash_new) |h| try ctx.db.storeConfig(git_key, h);
    }

    // Store unified last_scan_at timestamp
    const scan_now_str = try std.fmt.allocPrint(alloc, "{d}", .{std.time.timestamp()});
    ctx.db.storeConfig("last_scan_at", scan_now_str) catch {};
}

fn hasDuplicateAnnotationLine(anns: []const annotations_mod.Annotation) bool {
    for (anns, 0..) |ann, i| {
        for (anns[i + 1 ..]) |other| {
            if (ann.line_number == other.line_number) return true;
        }
    }
    return false;
}

fn upsertRuntimeDiag(db: *GraphDb, source: []const u8, code: u16, severity: []const u8, title: []const u8, message: []const u8, subject: ?[]const u8, details_json: []const u8) !void {
    const subject_part = subject orelse "";
    const dedupe_key = try std.fmt.allocPrint(std.heap.page_allocator, "{s}:{s}:{d}", .{ source, subject_part, code });
    defer std.heap.page_allocator.free(dedupe_key);
    try db.upsertRuntimeDiagnostic(dedupe_key, code, severity, title, message, source, subject, details_json);
}

fn clearRuntimeDiagByCodeAndSubject(db: *GraphDb, source: []const u8, subject: []const u8, code: u16) !void {
    const dedupe_key = try std.fmt.allocPrint(std.heap.page_allocator, "{s}:{s}:{d}", .{ source, subject, code });
    defer std.heap.page_allocator.free(dedupe_key);
    try db.clearRuntimeDiagnostic(dedupe_key);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

test "colLetter single" {
    const a = colLetter(0);
    try testing.expectEqual(@as(u8, 'A'), a[0]);
    const z = colLetter(25);
    try testing.expectEqual(@as(u8, 'Z'), z[0]);
}

test "colLetter double" {
    const aa = colLetter(26);
    try testing.expectEqual(@as(u8, 'A'), aa[0]);
    try testing.expectEqual(@as(u8, 'A'), aa[1]);
    const ab = colLetter(27);
    try testing.expectEqual(@as(u8, 'A'), ab[0]);
    try testing.expectEqual(@as(u8, 'B'), ab[1]);
}

test "findCol" {
    var h = [_][]const u8{ "ID", "Statement", "Status" };
    try testing.expectEqual(@as(?usize, 0), findCol(&h, "ID"));
    try testing.expectEqual(@as(?usize, 2), findCol(&h, "Status"));
    try testing.expectEqual(@as(?usize, null), findCol(&h, "Missing"));
}

test "SyncState error round-trip" {
    var s: SyncState = .{};
    s.setError("connection refused");
    try testing.expect(s.has_error.load(.seq_cst));
    var buf: [256]u8 = undefined;
    const n = s.getError(&buf);
    try testing.expectEqualStrings("connection refused", buf[0..n]);
    s.clearError();
    try testing.expect(!s.has_error.load(.seq_cst));
}

test "repoScanCycle with no repos is a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{},
        .state = &state,
        .alloc = alloc,
    };

    try repoScanCycle(&ctx, alloc);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer diags.deinit(alloc);
    try db.listRuntimeDiagnostics(null, alloc, &diags);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "repoScanCycle emits E1101 for unknown refs and E1005 for hanging git" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo");
    {
        const f = try tmp.dir.createFile("repo/main.c", .{});
        defer f.close();
        try f.writeAll(
            \\// REQ-001 implemented here
            \\// REQ-999 is stale
            \\int main(void) { return 0; }
        );
    }
    {
        const f = try tmp.dir.createFile("fake-git.sh", .{});
        defer f.close();
        try f.writeAll(
            \\#!/bin/sh
            \\cmd="$1"
            \\if [ "$cmd" = "log" ] || [ "$cmd" = "blame" ]; then
            \\  sleep 1
            \\  exit 0
            \\fi
            \\exit 1
        );
        try f.chmod(0o755);
    }

    var repo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_path = try tmp.dir.realpath("repo", &repo_path_buf);
    var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = try tmp.dir.realpath("fake-git.sh", &git_path_buf);

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{repo_path},
        .state = &state,
        .alloc = alloc,
        .git_exe_override = git_path,
        .git_timeout_ms_override = 100,
    };

    try repoScanCycle(&ctx, alloc);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |d| {
            alloc.free(d.dedupe_key);
            alloc.free(d.severity);
            alloc.free(d.title);
            alloc.free(d.message);
            alloc.free(d.source);
            if (d.subject) |s| alloc.free(s);
            alloc.free(d.details_json);
        }
        diags.deinit(alloc);
    }
    try db.listRuntimeDiagnostics(null, alloc, &diags);

    var found_unknown = false;
    var found_git_timeout = false;
    var found_blame_timeout = false;
    for (diags.items) |d| {
        if (d.code == 1101 and std.mem.eql(u8, d.source, "annotation") and std.mem.indexOf(u8, d.message, "REQ-999") != null) {
            found_unknown = true;
        }
        if (d.code == 1005 and std.mem.eql(u8, d.source, "git")) {
            found_git_timeout = true;
        }
        if (d.code == 1005 and std.mem.eql(u8, d.source, "annotation")) {
            found_blame_timeout = true;
        }
    }

    try testing.expect(found_unknown);
    try testing.expect(found_git_timeout);
    try testing.expect(found_blame_timeout);
}
