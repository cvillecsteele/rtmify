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

    // 1. Fetch all 4 tabs (include header row: start from row 1)
    const tests_rows = try sheets_mod.readRows(client, token, sheet_id, "Tests!A1:Z", a);
    const un_rows = try sheets_mod.readRows(client, token, sheet_id, "User%20Needs!A1:Z", a);
    const req_rows = try sheets_mod.readRows(client, token, sheet_id, "Requirements!A1:Z", a);
    const risk_rows = try sheets_mod.readRows(client, token, sheet_id, "Risks!A1:Z", a);

    // 2. Convert [][][]const u8 rows to xlsx.SheetData
    const sheet_data = [_]xlsx.SheetData{
        .{ .name = "Tests", .rows = @ptrCast(tests_rows) },
        .{ .name = "User Needs", .rows = @ptrCast(un_rows) },
        .{ .name = "Requirements", .rows = @ptrCast(req_rows) },
        .{ .name = "Risks", .rows = @ptrCast(risk_rows) },
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
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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
