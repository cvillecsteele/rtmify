/// sync_live.zig — background sync thread for rtmify-live.
///
/// Polls the active online provider every 30s. On change: fetches core tabs,
/// ingests rows via schema.zig into an ephemeral in-memory Graph, then
/// upserts all nodes and edges into the SQLite GraphDb. Writes status
/// columns and row colors back to the workbook through the provider runtime.
///
/// Exponential backoff on error: 30→60→120→300s cap.
const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_mod = @import("rtmify").graph;
const schema = @import("rtmify").schema;
const xlsx = @import("rtmify").xlsx;

const graph_live = @import("graph_live.zig");
const repo_mod = @import("repo.zig");
const annotations_mod = @import("annotations.zig");
const git_mod = @import("git.zig");
const profile_mod = @import("profile.zig");
const provision_mod = @import("provision.zig");
const online_provider = @import("online_provider.zig");
const provider_common = @import("provider_common.zig");
const json_util = @import("json_util.zig");
const test_results = @import("test_results.zig");

const GraphDb = graph_live.GraphDb;
const ProviderRuntime = online_provider.ProviderRuntime;
const ActiveConnection = provider_common.ActiveConnection;
const ValueUpdate = provider_common.ValueUpdate;
const RowFormat = provider_common.RowFormat;

// ---------------------------------------------------------------------------
// SyncState — shared between sync thread and HTTP server
// ---------------------------------------------------------------------------

pub const SyncState = struct {
    last_sync_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    has_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sync_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// True once a sync thread has been spawned; prevents double-start.
    sync_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Gates background product work when licensing does not permit use.
    product_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    repo_scan_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    repo_scan_last_started_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    repo_scan_last_finished_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    // last_error is written under mu
    last_error: [256:0]u8 = .{0} ** 256,
    last_error_len: usize = 0,
    mu: std.Thread.Mutex = .{},
    repo_scan_mu: std.Thread.Mutex = .{},

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
    workbook_id: []const u8,
    workbook_slug: []const u8,
    profile: profile_mod.ProfileId,
    active: ActiveConnection,
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
    defer cfg.alloc.free(cfg.workbook_id);
    defer cfg.alloc.free(cfg.workbook_slug);
    var owned_active = cfg.active;
    defer owned_active.deinit(cfg.alloc);

    var active = owned_active.clone(alloc) catch {
        cfg.state.setError("provider_setup_failed");
        return;
    };
    defer active.deinit(alloc);

    var runtime = ProviderRuntime.init(active, alloc) catch |e| {
        cfg.state.setError(@errorName(e));
        std.log.err("sync: provider init failed: {s}", .{@errorName(e)});
        return;
    };
    defer runtime.deinit(alloc);

    var last_change_token: ?[]u8 = null;
    defer if (last_change_token) |tok| alloc.free(tok);
    var backoff: u64 = 30; // seconds

    while (true) {
        if (!cfg.state.product_enabled.load(.seq_cst)) {
            std.Thread.sleep(30 * std.time.ns_per_s);
            continue;
        }

        const change_token = runtime.changeToken(alloc) catch |e| {
            const msg = @errorName(e);
            cfg.state.setError(msg);
            std.log.err("sync: change token refresh failed: {s}", .{msg});
            std.Thread.sleep(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 300);
            continue;
        };

        if (last_change_token) |prev| {
            if (std.mem.eql(u8, prev, change_token)) {
                alloc.free(change_token);
                std.Thread.sleep(30 * std.time.ns_per_s);
                continue;
            }
            alloc.free(prev);
        }
        last_change_token = @constCast(change_token);

        std.log.info("sync: workbook changed (token={s}), ingesting…", .{change_token});

        // Provision missing tabs BEFORE sync so blank workbooks are viable (non-fatal)
        {
            var prov_arena = std.heap.ArenaAllocator.init(alloc);
            defer prov_arena.deinit();
            const pa = prov_arena.allocator();
            const prov_done = (cfg.db.getConfig("rtmify_provisioned", pa) catch null) orelse "";
            if (prov_done.len == 0) {
                const prof = profile_mod.get(cfg.profile);
                _ = provision_mod.provisionWorkbook(&runtime, prof, pa) catch |e| blk: {
                    std.log.warn("provision failed: {s}", .{@errorName(e)});
                    break :blk @as([][]const u8, &.{});
                };
                cfg.db.storeConfig("rtmify_provisioned", "1") catch {};
            }
        }

        runSyncCycle(cfg.db, cfg.profile, &runtime, cfg.state, alloc) catch |e| {
            const msg = @errorName(e);
            cfg.state.setError(msg);
            std.log.err("sync: cycle failed: {s}", .{msg});
            std.Thread.sleep(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 300);
            continue;
        };

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

/// Fetch all required tabs through the provider runtime, ingest into graph,
/// then write back status + colors.
fn runSyncCycle(
    db: *GraphDb,
    profile_id: profile_mod.ProfileId,
    runtime: *ProviderRuntime,
    state: *SyncState,
    alloc: Allocator,
) anyerror!void {
    _ = state;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Fetch core tabs (include header row: start from row 1)
    const tests_rows = try runtime.readRows("Tests", a);
    const un_rows = try runtime.readRows("User Needs", a);
    const req_rows = try runtime.readRows("Requirements", a);
    const risk_rows = try runtime.readRows("Risks", a);
    const existing_tabs = try runtime.listTabs(a);
    defer online_provider.freeTabRefs(existing_tabs, a);
    const enable_decomposition_tab = profile_id == .aerospace;
    // Extended tabs — only fetch them if they actually exist to avoid noisy provider errors.
    const di_rows = try readOptionalTab(runtime, existing_tabs, "Design Inputs", a);
    const do_rows = try readOptionalTab(runtime, existing_tabs, "Design Outputs", a);
    const ci_rows = try readOptionalTab(runtime, existing_tabs, "Configuration Items", a);
    const product_rows = try readOptionalTab(runtime, existing_tabs, "Product", a);
    const decomposition_rows = if (enable_decomposition_tab)
        try readOptionalTab(runtime, existing_tabs, "Decomposition", a)
    else
        &.{};

    // 2. Convert [][][]const u8 rows to xlsx.SheetData
    const sheet_data = [_]xlsx.SheetData{
        .{ .name = "Tests", .rows = @ptrCast(tests_rows) },
        .{ .name = "User Needs", .rows = @ptrCast(un_rows) },
        .{ .name = "Requirements", .rows = @ptrCast(req_rows) },
        .{ .name = "Risks", .rows = @ptrCast(risk_rows) },
        .{ .name = "Design Inputs", .rows = @ptrCast(di_rows) },
        .{ .name = "Design Outputs", .rows = @ptrCast(do_rows) },
        .{ .name = "Configuration Items", .rows = @ptrCast(ci_rows) },
        .{ .name = "Product", .rows = @ptrCast(product_rows) },
        .{ .name = "Decomposition", .rows = @ptrCast(decomposition_rows) },
    };

    // 3. Ingest into ephemeral in-memory Graph via schema.zig
    var g = graph_mod.Graph.init(a);
    defer g.deinit();

    var diag = @import("rtmify").diagnostic.Diagnostics.init(a);
    defer diag.deinit();

    _ = schema.ingestValidatedWithOptions(&g, &sheet_data, &diag, .{
        .enable_product_tab = true,
        .enable_decomposition_tab = enable_decomposition_tab,
    }) catch |e| {
        std.log.warn("sync: ingest errors (continuing): {s}", .{@errorName(e)});
    };

    // 4. Port nodes from in-memory Graph to SQLite GraphDb
    try portGraphToDb(db, &g, alloc);

    // 5. Write back status columns and row colors
    try writeBackStatus(db, runtime, req_rows, risk_rows, un_rows, product_rows, a);

    std.log.info("sync: cycle complete — {d} nodes", .{g.nodes.count()});
}

fn readOptionalTab(runtime: *ProviderRuntime, existing_tabs: []const online_provider.TabRef, tab_name: []const u8, alloc: Allocator) ![][][]const u8 {
    if (!tabExists(existing_tabs, tab_name)) return &.{};
    return runtime.readRows(tab_name, alloc) catch &.{};
}

fn tabExists(existing_tabs: []const online_provider.TabRef, want: []const u8) bool {
    for (existing_tabs) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, want)) return true;
        if (containsIgnoreCase(tab.title, want) or containsIgnoreCase(want, tab.title)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var hay_buf: [128]u8 = undefined;
    var needle_buf: [128]u8 = undefined;
    const hay_len = @min(haystack.len, hay_buf.len);
    const needle_len = @min(needle.len, needle_buf.len);
    for (haystack[0..hay_len], 0..) |c, i| hay_buf[i] = std.ascii.toLower(c);
    for (needle[0..needle_len], 0..) |c, i| needle_buf[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, hay_buf[0..hay_len], needle_buf[0..needle_len]) != null;
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
    try json_util.appendJsonEscaped(buf, s, alloc);
}

fn buildFileNodePropsJson(path: []const u8, repo: []const u8, annotation_count: usize, present: bool, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"path\":");
    try json_util.appendJsonQuoted(&buf, path, alloc);
    try buf.appendSlice(alloc, ",\"repo\":");
    try json_util.appendJsonQuoted(&buf, repo, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"annotation_count\":{d}", .{annotation_count});
    try buf.appendSlice(alloc, ",\"present\":");
    try buf.appendSlice(alloc, if (present) "true" else "false");
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

fn ensureHistoricalFileNode(db: *GraphDb, path: []const u8, repo: []const u8, node_type: []const u8, alloc: Allocator) !void {
    if (try db.getNode(path, alloc)) |existing| {
        alloc.free(existing.id);
        alloc.free(existing.type);
        alloc.free(existing.properties);
        if (existing.suspect_reason) |reason| alloc.free(reason);
        return;
    }
    const props = try buildFileNodePropsJson(path, repo, 0, false, alloc);
    try db.upsertNode(path, node_type, props, props);
}

fn buildUnknownAnnotationDetailsJson(ref_id: []const u8, line_number: usize, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ref_id\":");
    try json_util.appendJsonQuoted(&buf, ref_id, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"line\":{d}", .{line_number});
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
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

fn statusColorHex(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "OK")) return "#B6E1CD";
    if (std.mem.eql(u8, status, "NO_TEST_LINKED") or
        std.mem.eql(u8, status, "MISSING_FULL_IDENTIFIER") or
        std.mem.eql(u8, status, "NO_REQ_LINKED") or
        std.mem.eql(u8, status, "MISSING")) return "#FCE8B2";
    return "#F4C7C3";
}

/// Write status columns for Requirements, Risks, and User Needs tabs.
fn writeBackStatus(
    db: *GraphDb,
    runtime: *ProviderRuntime,
    req_rows: [][][]const u8,
    risk_rows: [][][]const u8,
    un_rows: [][][]const u8,
    product_rows: []const []const []const u8,
    alloc: Allocator,
) !void {
    var value_updates: std.ArrayList(ValueUpdate) = .empty;
    defer {
        for (value_updates.items) |upd| {
            alloc.free(upd.a1_range);
            for (upd.values) |v| alloc.free(v);
            alloc.free(upd.values);
        }
        value_updates.deinit(alloc);
    }
    var row_formats: std.ArrayList(RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    // --- Requirements ---
    if (req_rows.len > 1) {
        const header = req_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        const verification_col = findCol(header, "RTMify Verification") orelse header.len;
        if (id_col != null and status_col != null) {
            const scol = status_col.?;
            if (verification_col == header.len) {
                const header_col_letter = colLetterBuf(verification_col);
                const header_range = try std.fmt.allocPrint(alloc, "Requirements!{s}1", .{colLetterRef(header_col_letter, verification_col)});
                const header_values = try alloc.alloc([]const u8, 1);
                header_values[0] = try alloc.dupe(u8, "RTMify Verification");
                try value_updates.append(alloc, .{ .a1_range = header_range, .values = header_values });
            }
            for (req_rows[1..], 0..) |row, i| {
                const row_num = i + 2; // 1-indexed sheet row
                const req_id = if (id_col.? < row.len) row[id_col.?] else "";
                if (req_id.len == 0) continue;
                const status = requirementStatus(db, req_id, alloc);
                const col_letter = colLetterBuf(scol);
                const range = try std.fmt.allocPrint(alloc, "Requirements!{s}{d}", .{ colLetterRef(col_letter, scol), row_num });
                const values = try alloc.alloc([]const u8, 1);
                values[0] = try alloc.dupe(u8, status);
                try value_updates.append(alloc, .{ .a1_range = range, .values = values });

                var verification = try test_results.verificationForRequirement(db, req_id, alloc);
                defer verification.deinit(alloc);
                const verification_value: []const u8 = if (verification.linked_test_groups.len == 0 and verification.linked_tests.len == 0)
                    ""
                else
                    @tagName(verification.state);
                const verification_col_letter = colLetterBuf(verification_col);
                const verification_range = try std.fmt.allocPrint(alloc, "Requirements!{s}{d}", .{ colLetterRef(verification_col_letter, verification_col), row_num });
                const verification_values = try alloc.alloc([]const u8, 1);
                verification_values[0] = try alloc.dupe(u8, verification_value);
                try value_updates.append(alloc, .{ .a1_range = verification_range, .values = verification_values });

                try row_formats.append(alloc, .{
                    .tab_title = "Requirements",
                    .row_1based = row_num,
                    .col_start_1based = 1,
                    .col_end_1based = if (verification_col == header.len) header.len + 1 else header.len,
                    .fill_hex = statusColorHex(status),
                });
            }
        }
    }

    // --- Risks ---
    if (risk_rows.len > 1) {
        const header = risk_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        if (id_col != null and status_col != null) {
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
                const col_letter = colLetterBuf(status_col.?);
                const range = try std.fmt.allocPrint(alloc, "Risks!{s}{d}", .{ colLetterRef(col_letter, status_col.?), row_num });
                const values = try alloc.alloc([]const u8, 1);
                values[0] = try alloc.dupe(u8, status);
                try value_updates.append(alloc, .{ .a1_range = range, .values = values });
                try row_formats.append(alloc, .{
                    .tab_title = "Risks",
                    .row_1based = row_num,
                    .col_start_1based = 1,
                    .col_end_1based = header.len,
                    .fill_hex = statusColorHex(status),
                });
            }
        }
    }

    // --- User Needs ---
    if (un_rows.len > 1) {
        const header = un_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        if (id_col != null and status_col != null) {
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
                const col_letter = colLetterBuf(status_col.?);
                const range = try std.fmt.allocPrint(alloc, "User Needs!{s}{d}", .{ colLetterRef(col_letter, status_col.?), row_num });
                const values = try alloc.alloc([]const u8, 1);
                values[0] = try alloc.dupe(u8, status);
                try value_updates.append(alloc, .{ .a1_range = range, .values = values });
                try row_formats.append(alloc, .{
                    .tab_title = "User Needs",
                    .row_1based = row_num,
                    .col_start_1based = 1,
                    .col_end_1based = header.len,
                    .fill_hex = statusColorHex(status),
                });
            }
        }
    }

    try appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    if (value_updates.items.len > 0) {
        runtime.batchWriteValues(value_updates.items, alloc) catch |e| {
            std.log.warn("sync: status writeback failed: {s}", .{@errorName(e)});
        };
    }
    if (row_formats.items.len > 0) {
        runtime.applyRowFormats(row_formats.items, alloc) catch |e| {
            std.log.warn("sync: color writeback failed: {s}", .{@errorName(e)});
        };
    }
}

fn normalizeProductCell(raw: []const u8, alloc: Allocator) ![]const u8 {
    const normalized = try xlsx.normalizeCell(raw, alloc);
    return std.mem.trim(u8, normalized, " ");
}

fn appendProductWriteback(
    value_updates: *std.ArrayList(ValueUpdate),
    row_formats: *std.ArrayList(RowFormat),
    product_rows: []const []const []const u8,
    alloc: Allocator,
) !void {
    if (product_rows.len == 0) return;

    const header = product_rows[0];
    const assembly_col = findCol(header, "assembly");
    const revision_col = findCol(header, "revision");
    const identifier_col = findCol(header, "full_identifier");
    const description_col = findCol(header, "description");
    const product_status_col = findCol(header, "Product Status");
    const rtmify_status_col = findCol(header, "RTMify Status") orelse 5;

    if (findCol(header, "RTMify Status") == null) {
        try appendSingleValueUpdate(value_updates, "Product", rtmify_status_col, 1, "RTMify Status", alloc);
    }

    if (product_rows.len == 1) {
        try appendSingleValueUpdate(value_updates, "Product", rtmify_status_col, 2, "NO_PRODUCT_DECLARED", alloc);
        return;
    }

    var seen_identifiers = std.StringHashMap(void).init(alloc);
    defer seen_identifiers.deinit();

    for (product_rows[1..], 0..) |row, i| {
        const row_num = i + 2;
        const assembly_raw = if (assembly_col) |col| if (col < row.len) row[col] else "" else "";
        const revision_raw = if (revision_col) |col| if (col < row.len) row[col] else "" else "";
        const identifier_raw = if (identifier_col) |col| if (col < row.len) row[col] else "" else "";
        const description_raw = if (description_col) |col| if (col < row.len) row[col] else "" else "";
        const product_status_raw = if (product_status_col) |col| if (col < row.len) row[col] else "" else "";

        if (schema.isBlankEquivalent(assembly_raw) and
            schema.isBlankEquivalent(revision_raw) and
            schema.isBlankEquivalent(identifier_raw) and
            schema.isBlankEquivalent(description_raw) and
            schema.isBlankEquivalent(product_status_raw))
        {
            continue;
        }

        const normalized_identifier = try normalizeProductCell(identifier_raw, alloc);
        const status: []const u8 = blk: {
            if (normalized_identifier.len == 0 or schema.isBlankEquivalent(normalized_identifier)) {
                break :blk "MISSING_FULL_IDENTIFIER";
            }
            if (seen_identifiers.contains(normalized_identifier)) {
                break :blk "DUPLICATE_FULL_IDENTIFIER";
            }
            try seen_identifiers.put(normalized_identifier, {});
            break :blk "OK";
        };

        try appendSingleValueUpdate(value_updates, "Product", rtmify_status_col, row_num, status, alloc);
        try row_formats.append(alloc, .{
            .tab_title = "Product",
            .row_1based = row_num,
            .col_start_1based = 1,
            .col_end_1based = 6,
            .fill_hex = statusColorHex(status),
        });
    }
}

fn appendSingleValueUpdate(
    value_updates: *std.ArrayList(ValueUpdate),
    tab_title: []const u8,
    col_index: usize,
    row_num: usize,
    value: []const u8,
    alloc: Allocator,
) !void {
    const col_letter = colLetterBuf(col_index);
    const range = try std.fmt.allocPrint(alloc, "{s}!{s}{d}", .{ tab_title, colLetterRef(col_letter, col_index), row_num });
    const values = try alloc.alloc([]const u8, 1);
    values[0] = try alloc.dupe(u8, value);
    try value_updates.append(alloc, .{ .a1_range = range, .values = values });
}

// ---------------------------------------------------------------------------
// Column lookup utilities
// ---------------------------------------------------------------------------

fn findCol(header: []const []const u8, name: []const u8) ?usize {
    for (header, 0..) |h, i| {
        if (std.ascii.eqlIgnoreCase(h, name)) return i;
    }
    return null;
}

/// Convert 0-based column index to spreadsheet letter (A, B, …, Z, AA, …).
fn colLetterBuf(idx: usize) [3]u8 {
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

fn colLetterRef(buf: [3]u8, idx: usize) []const u8 {
    return buf[0..if (idx < 26) 1 else 2];
}

fn colLetter(idx: usize) [3]u8 {
    return colLetterBuf(idx);
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

pub fn destroyRepoScanCtx(ctx: *RepoScanCtx) void {
    for (ctx.repo_paths) |repo_path| ctx.alloc.free(repo_path);
    ctx.alloc.free(ctx.repo_paths);
    ctx.alloc.destroy(ctx);
}

/// Background thread: scans repos for source files + annotations + commits.
/// Loops every 60 seconds. Each cycle:
///   1. Builds list of known req IDs from the graph DB.
///   2. For each repo_path: scans files, upserts SourceFile/TestFile nodes.
///   3. Scans each file for annotations, upserts CodeAnnotation nodes + edges.
///   4. Runs git log, upserts Commit nodes + COMMITTED_IN edges.
///   5. Rate-limited blame: first 50 annotations per cycle.
pub fn repoScanThread(ctx: *RepoScanCtx) void {
    defer destroyRepoScanCtx(ctx);

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
        if (!ctx.state.product_enabled.load(.seq_cst)) {
            std.Thread.sleep(30 * std.time.ns_per_s);
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        repoScanCycleSerialized(ctx, a) catch |e| {
            std.log.warn("repo scan cycle failed: {s}", .{@errorName(e)});
        };

        std.Thread.sleep(60 * std.time.ns_per_s);
    }
}

pub fn triggerRepoScanNow(db: *GraphDb, state: *SyncState, alloc: Allocator) !void {
    var idx: usize = 0;
    while (idx < 64) : (idx += 1) {
        const repo_key = try std.fmt.allocPrint(alloc, "repo_path_{d}", .{idx});
        defer alloc.free(repo_key);
        const repo_path = (try db.getConfig(repo_key, alloc)) orelse continue;
        const last_scan_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{repo_path});
        defer alloc.free(last_scan_key);
        try db.storeConfig(last_scan_key, "0");
    }

    var ctx = RepoScanCtx{
        .db = db,
        .repo_paths = &.{},
        .state = state,
        .alloc = alloc,
    };
    std.log.info("repo scan: manual scan requested", .{});
    try repoScanCycleSerialized(&ctx, alloc);
}

fn repoScanCycleSerialized(ctx: *RepoScanCtx, alloc: Allocator) !void {
    ctx.state.repo_scan_mu.lock();
    defer ctx.state.repo_scan_mu.unlock();
    const started_at = std.time.timestamp();
    ctx.state.repo_scan_in_progress.store(true, .seq_cst);
    ctx.state.repo_scan_last_started_at.store(started_at, .seq_cst);
    defer {
        ctx.state.repo_scan_in_progress.store(false, .seq_cst);
        ctx.state.repo_scan_last_finished_at.store(std.time.timestamp(), .seq_cst);
    }
    try repoScanCycle(ctx, alloc);
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

        var blame_count: usize = 0;

        for (files) |file| {
            // Collect existing CodeAnnotation IDs for this rescanned file only.
            // Incremental scans must not delete annotations for untouched files.
            var existing_file_ann_ids = std.StringHashMap(void).init(alloc);
            defer existing_file_ann_ids.deinit();
            {
                var st = try ctx.db.db.prepare(
                    "SELECT id FROM nodes WHERE type='CodeAnnotation' AND id LIKE ? || ':%'"
                );
                defer st.finalize();
                try st.bindText(1, file.path);
                while (try st.step()) {
                    const id = try alloc.dupe(u8, st.columnText(0));
                    try existing_file_ann_ids.put(id, {});
                }
            }

            var seen_file_ann_ids = std.StringHashMap(void).init(alloc);
            defer seen_file_ann_ids.deinit();

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
            const props = try buildFileNodePropsJson(file.path, repo_path, annotation_count, true, alloc);
            try ctx.db.upsertNode(file.path, node_type, props, props);

            if (hasDuplicateAnnotationLine(anns)) {
                try upsertRuntimeDiag(ctx.db, "annotation", 1106, "info", "Multiple annotations on same line", try std.fmt.allocPrint(alloc, "File {s} has multiple requirement annotations on the same line", .{file.path}), file.path, "{}");
            }

            for (scan.unknown_refs) |unknown| {
                const subject = try std.fmt.allocPrint(alloc, "{s}:{d}:{s}", .{ unknown.file_path, unknown.line_number, unknown.ref_id });
                const details = try buildUnknownAnnotationDetailsJson(unknown.ref_id, unknown.line_number, alloc);
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
                try seen_file_ann_ids.put(try alloc.dupe(u8, ann_id), {});

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

            // Remove stale CodeAnnotation nodes only for this rescanned file.
            var stale_file_it = existing_file_ann_ids.keyIterator();
            while (stale_file_it.next()) |id| {
                if (seen_file_ann_ids.contains(id.*)) continue;
                ctx.db.deleteNode(id.*) catch |e| {
                    std.log.warn("deleteNode {s}: {s}", .{ id.*, @errorName(e) });
                };
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
            for (commit.file_changes) |change| {
                const full_changed_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ repo_path, change.path });
                const changed_kind = repo_mod.classifyFile(change.path);
                const changed_node_type: ?[]const u8 = switch (changed_kind) {
                    .source => "SourceFile",
                    .test_file => "TestFile",
                    .ignored => null,
                };
                if (changed_node_type) |nt| {
                    try ensureHistoricalFileNode(ctx.db, full_changed_path, repo_path, nt, alloc);
                    ctx.db.addEdge(full_changed_path, commit.hash, "CHANGED_IN") catch {};
                    ctx.db.addEdge(commit.hash, full_changed_path, "CHANGES") catch {};
                }
            }
            if (last_hash_new == null) last_hash_new = commit.hash; // most recent
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
const test_git_repo = @import("test_git_repo.zig");

fn testEdgeExists(db: *GraphDb, from_id: []const u8, to_id: []const u8, label: []const u8, alloc: Allocator) !bool {
    var edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        edges.deinit(alloc);
    }
    try db.edgesFrom(from_id, alloc, &edges);
    for (edges.items) |e| {
        if (std.mem.eql(u8, e.to_id, to_id) and std.mem.eql(u8, e.label, label)) return true;
    }
    return false;
}

fn testGetNodeJsonBool(db: *GraphDb, node_id: []const u8, field: []const u8, alloc: Allocator) !bool {
    const node = (try db.getNode(node_id, alloc)) orelse return error.TestExpectedNodeMissing;
    defer {
        alloc.free(node.id);
        alloc.free(node.type);
        alloc.free(node.properties);
        if (node.suspect_reason) |s| alloc.free(s);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, node.properties, .{});
    defer parsed.deinit();
    return json_util.getObjectField(parsed.value, field).?.bool;
}

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

test "buildFileNodePropsJson escapes quote and backslash in file path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json = try buildFileNodePropsJson("src/\"gps\"\\main.c", "/tmp/repo \"alpha\"", 2, true, alloc);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("src/\"gps\"\\main.c", json_util.getString(parsed.value, "path").?);
    try testing.expectEqualStrings("/tmp/repo \"alpha\"", json_util.getString(parsed.value, "repo").?);
    try testing.expect(json_util.getObjectField(parsed.value, "present").?.bool);
}

test "buildUnknownAnnotationDetailsJson escapes ref ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json = try buildUnknownAnnotationDetailsJson("REQ-\"999\"", 42, alloc);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("REQ-\"999\"", json_util.getString(parsed.value, "ref_id").?);
    try testing.expectEqual(@as(i64, 42), json_util.getObjectField(parsed.value, "line").?.integer);
}

test "tabExists matches exact case-insensitive and fuzzy optional tab titles" {
    const tabs = [_]online_provider.TabRef{
        .{ .title = "User Needs", .native_id = "1" },
        .{ .title = "Requirements", .native_id = "2" },
        .{ .title = "Configuration Items (optional)", .native_id = "3" },
    };

    try testing.expect(tabExists(&tabs, "User Needs"));
    try testing.expect(tabExists(&tabs, "user needs"));
    try testing.expect(tabExists(&tabs, "Configuration Items"));
    try testing.expect(!tabExists(&tabs, "Design Inputs"));
}

fn freeValueUpdates(updates: *std.ArrayList(ValueUpdate), alloc: Allocator) void {
    for (updates.items) |upd| {
        alloc.free(upd.a1_range);
        for (upd.values) |value| alloc.free(value);
        alloc.free(upd.values);
    }
    updates.deinit(alloc);
}

fn findSingleValueUpdate(updates: []const ValueUpdate, range: []const u8) ?[]const u8 {
    for (updates) |upd| {
        if (std.mem.eql(u8, upd.a1_range, range)) return upd.values[0];
    }
    return null;
}

test "appendProductWriteback writes empty tab advisory to F2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
    };

    var value_updates: std.ArrayList(ValueUpdate) = .empty;
    defer freeValueUpdates(&value_updates, alloc);
    var row_formats: std.ArrayList(RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    try appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    try testing.expectEqualStrings("NO_PRODUCT_DECLARED", findSingleValueUpdate(value_updates.items, "Product!F2").?);
    try testing.expectEqual(@as(usize, 0), row_formats.items.len);
}

test "appendProductWriteback sets product row statuses and fills" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
        &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Active", "" },
        &.{ "ASM-1000", "Rev D", "", "Sensor Controller Unit Rev D", "Development", "" },
        &.{ "ASM-1000", "Rev E", "ASM-1000 Rev C", "Sensor Controller Unit Rev E", "Development", "" },
    };

    var value_updates: std.ArrayList(ValueUpdate) = .empty;
    defer freeValueUpdates(&value_updates, alloc);
    var row_formats: std.ArrayList(RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    try appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    try testing.expectEqualStrings("OK", findSingleValueUpdate(value_updates.items, "Product!F2").?);
    try testing.expectEqualStrings("MISSING_FULL_IDENTIFIER", findSingleValueUpdate(value_updates.items, "Product!F3").?);
    try testing.expectEqualStrings("DUPLICATE_FULL_IDENTIFIER", findSingleValueUpdate(value_updates.items, "Product!F4").?);
    try testing.expectEqual(@as(usize, 3), row_formats.items.len);
    try testing.expectEqualStrings("#B6E1CD", row_formats.items[0].fill_hex);
    try testing.expectEqualStrings("#FCE8B2", row_formats.items[1].fill_hex);
    try testing.expectEqualStrings("#F4C7C3", row_formats.items[2].fill_hex);
}

test "appendProductWriteback recreates missing RTMify Status header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status" },
        &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Active" },
    };

    var value_updates: std.ArrayList(ValueUpdate) = .empty;
    defer freeValueUpdates(&value_updates, alloc);
    var row_formats: std.ArrayList(RowFormat) = .empty;
    defer row_formats.deinit(alloc);

    try appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    try testing.expectEqualStrings("RTMify Status", findSingleValueUpdate(value_updates.items, "Product!F1").?);
    try testing.expectEqualStrings("OK", findSingleValueUpdate(value_updates.items, "Product!F2").?);
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

test "repoScanCycle creates file commit edges without committed_in and preserves historical file presence" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/src");
    {
        const f = try tmp.dir.createFile("repo/src/current.c", .{});
        defer f.close();
        try f.writeAll("// REQ-001 implemented here\nint main(void) { return 0; }\n");
    }
    {
        const f = try tmp.dir.createFile("fake-git.sh", .{});
        defer f.close();
        try f.writeAll(
            \\#!/bin/sh
            \\cmd="$1"
            \\shift
            \\if [ "$cmd" = "--version" ]; then
            \\  echo "git version fake"
            \\  exit 0
            \\fi
            \\if [ "$cmd" = "log" ]; then
            \\  printf '\036aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|aaaaaaa|Alice|alice@example.com|2026-03-06T12:00:00+00:00|refactor without req id\n'
            \\  printf 'M\tsrc/current.c\n'
            \\  printf 'D\tsrc/historical_only.c\n\n'
            \\  exit 0
            \\fi
            \\if [ "$cmd" = "blame" ]; then
            \\  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1\nauthor Alice\nauthor-mail <alice@example.com>\nauthor-time 1770000000\n'
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
        .git_timeout_ms_override = 1000,
    };

    try repoScanCycle(&ctx, alloc);

    const current_path = try std.fmt.allocPrint(alloc, "{s}/src/current.c", .{repo_path});
    const historical_path = try std.fmt.allocPrint(alloc, "{s}/src/historical_only.c", .{repo_path});
    try testing.expect((try db.getNode(current_path, alloc)) != null);
    try testing.expect((try db.getNode(historical_path, alloc)) != null);
    const current = (try db.getNode(current_path, alloc)).?;
    defer {
        alloc.free(current.id);
        alloc.free(current.type);
        alloc.free(current.properties);
    }
    var parsed_current = try std.json.parseFromSlice(std.json.Value, alloc, current.properties, .{});
    defer parsed_current.deinit();
    try testing.expect(json_util.getObjectField(parsed_current.value, "present").?.bool);

    const historical = (try db.getNode(historical_path, alloc)).?;
    defer {
        alloc.free(historical.id);
        alloc.free(historical.type);
        alloc.free(historical.properties);
    }
    var parsed_hist = try std.json.parseFromSlice(std.json.Value, alloc, historical.properties, .{});
    defer parsed_hist.deinit();
    try testing.expect(!json_util.getObjectField(parsed_hist.value, "present").?.bool);

    var from_current: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (from_current.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        from_current.deinit(alloc);
    }
    try db.edgesFrom(current_path, alloc, &from_current);
    var has_changed_in = false;
    for (from_current.items) |e| {
        if (std.mem.eql(u8, e.label, "CHANGED_IN") and std.mem.eql(u8, e.to_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")) {
            has_changed_in = true;
        }
    }
    try testing.expect(has_changed_in);

    var commit_edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (commit_edges.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        commit_edges.deinit(alloc);
    }
    try db.edgesFrom("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", alloc, &commit_edges);
    var has_changes = false;
    for (commit_edges.items) |e| {
        if (std.mem.eql(u8, e.label, "CHANGES") and std.mem.eql(u8, e.to_id, current_path)) {
            has_changes = true;
        }
        try testing.expect(!std.mem.eql(u8, e.label, "COMMITTED_IN"));
    }
    try testing.expect(has_changes);

    var req_edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (req_edges.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        req_edges.deinit(alloc);
    }
    try db.edgesFrom("REQ-001", alloc, &req_edges);
    for (req_edges.items) |e| {
        try testing.expect(!std.mem.eql(u8, e.label, "COMMITTED_IN"));
    }
}

test "repoScanCycle backfills full history first then uses git cursor incrementally" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/src");
    {
        const f = try tmp.dir.createFile("repo/src/current.c", .{});
        defer f.close();
        try f.writeAll("// REQ-001 implemented here\nint main(void) { return 0; }\n");
    }
    {
        const f = try tmp.dir.createFile("fake-git.sh", .{});
        defer f.close();
        try f.writeAll(
            \\#!/bin/sh
            \\if [ "$1" = "--version" ]; then
            \\  echo "git version fake"
            \\  exit 0
            \\fi
            \\if [ "$1" = "log" ]; then
            \\  for arg in "$@"; do
            \\    if echo "$arg" | grep -q '\.\.HEAD'; then
            \\      printf '\036bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|bbbbbbb|Bob|bob@example.com|2026-03-07T12:00:00+00:00|REQ-001 incremental commit\n'
            \\      printf 'M\tsrc/current.c\n\n'
            \\      exit 0
            \\    fi
            \\  done
            \\  printf '\036aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|aaaaaaa|Alice|alice@example.com|2026-03-06T12:00:00+00:00|initial history\n'
            \\  printf 'M\tsrc/current.c\n\n'
            \\  exit 0
            \\fi
            \\if [ "$1" = "blame" ]; then
            \\  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1\nauthor Alice\nauthor-mail <alice@example.com>\nauthor-time 1770000000\n'
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
        .git_timeout_ms_override = 1000,
    };

    try repoScanCycle(&ctx, alloc);
    const git_key = try std.fmt.allocPrint(alloc, "git_last_hash_{s}", .{repo_path});
    defer alloc.free(git_key);
    const stored_hash_1 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_1);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", stored_hash_1);

    try repoScanCycle(&ctx, alloc);
    const stored_hash_2 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_2);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", stored_hash_2);

    try testing.expect((try db.getNode("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", alloc)) != null);
    try testing.expect((try db.getNode("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", alloc)) != null);

    var req_edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (req_edges.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        req_edges.deinit(alloc);
    }
    try db.edgesFrom("REQ-001", alloc, &req_edges);
    var committed_count: usize = 0;
    for (req_edges.items) |e| {
        if (std.mem.eql(u8, e.label, "COMMITTED_IN")) committed_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), committed_count);
}

test "triggerRepoScanNow forces full file rescan regardless of last_scan cursor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    _ = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T12:00:00Z");

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.storeConfig("repo_path_0", fixture.path);

    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repoScanCycle(&ctx, alloc);

    const file_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/foo.c" });
    defer alloc.free(file_path);

    var delete_ann = try db.db.prepare("DELETE FROM nodes WHERE type='CodeAnnotation'");
    defer delete_ann.finalize();
    _ = try delete_ann.step();

    const stale_props = try buildFileNodePropsJson(file_path, fixture.path, 0, true, alloc);
    defer alloc.free(stale_props);
    try db.upsertNode(file_path, "SourceFile", stale_props, stale_props);

    const last_scan_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{fixture.path});
    defer alloc.free(last_scan_key);
    try db.storeConfig(last_scan_key, "9999999999");

    try triggerRepoScanNow(&db, &state, alloc);

    const annotation_id = try std.fmt.allocPrint(alloc, "{s}:1", .{file_path});
    defer alloc.free(annotation_id);
    try testing.expect((try db.getNode(annotation_id, alloc)) != null);
    try testing.expect(try testEdgeExists(&db, "REQ-001", annotation_id, "ANNOTATED_AT", alloc));
}

test "repoScanCycle real git repo links source annotation commit and file changes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    const commit_hash = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T12:00:00Z");

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repoScanCycle(&ctx, alloc);

    const current_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/foo.c" });
    const annotation_id = try std.fmt.allocPrint(alloc, "{s}:1", .{current_path});
    defer alloc.free(current_path);
    defer alloc.free(annotation_id);

    try testing.expect((try db.getNode(current_path, alloc)) != null);
    try testing.expect((try db.getNode(annotation_id, alloc)) != null);
    try testing.expect((try db.getNode(commit_hash, alloc)) != null);

    try testing.expect(try testEdgeExists(&db, "REQ-001", current_path, "IMPLEMENTED_IN", alloc));
    try testing.expect(try testEdgeExists(&db, "REQ-001", annotation_id, "ANNOTATED_AT", alloc));
    try testing.expect(try testEdgeExists(&db, "REQ-001", commit_hash, "COMMITTED_IN", alloc));
    try testing.expect(try testEdgeExists(&db, current_path, commit_hash, "CHANGED_IN", alloc));
    try testing.expect(try testEdgeExists(&db, commit_hash, current_path, "CHANGES", alloc));
    try testing.expect(try testGetNodeJsonBool(&db, current_path, "present", alloc));
}

test "repoScanCycle real git repo records later file change without inferring committed_in from later commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    const commit_1 = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T12:00:00Z");

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repoScanCycle(&ctx, alloc);

    std.Thread.sleep(1200 * std.time.ns_per_ms);
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here (bob)
        \\int main(void) { return 1; }
        \\
    );
    const commit_2 = try fixture.commit("refactor without req id", "Bob", "bob@example.com", "2026-03-07T15:45:00Z");
    try repoScanCycle(&ctx, alloc);

    const current_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/foo.c" });
    const annotation_id = try std.fmt.allocPrint(alloc, "{s}:1", .{current_path});
    defer alloc.free(current_path);
    defer alloc.free(annotation_id);

    try testing.expect((try db.getNode(annotation_id, alloc)) != null);

    try testing.expect(try testEdgeExists(&db, current_path, commit_2, "CHANGED_IN", alloc));
    try testing.expect(try testEdgeExists(&db, commit_2, current_path, "CHANGES", alloc));

    var req_edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (req_edges.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        req_edges.deinit(alloc);
    }
    try db.edgesFrom("REQ-001", alloc, &req_edges);
    var committed_to_first = false;
    var committed_to_second = false;
    for (req_edges.items) |e| {
        if (std.mem.eql(u8, e.label, "COMMITTED_IN") and std.mem.eql(u8, e.to_id, commit_1)) committed_to_first = true;
        if (std.mem.eql(u8, e.label, "COMMITTED_IN") and std.mem.eql(u8, e.to_id, commit_2)) committed_to_second = true;
    }
    try testing.expect(committed_to_first);
    try testing.expect(!committed_to_second);
}

test "repoScanCycle real git repo classifies test annotations as verified by code" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("tests/foo_test.c",
        \\// REQ-001 verified here
        \\int test_foo(void) { return 0; }
        \\
    );
    const commit_hash = try fixture.commit("add test coverage", "Alice", "alice@example.com", "2026-03-08T09:00:00Z");

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repoScanCycle(&ctx, alloc);

    const test_path = try std.fs.path.join(alloc, &.{ fixture.path, "tests/foo_test.c" });
    defer alloc.free(test_path);

    const file_node = (try db.getNode(test_path, alloc)).?;
    defer {
        alloc.free(file_node.id);
        alloc.free(file_node.type);
        alloc.free(file_node.properties);
        if (file_node.suspect_reason) |s| alloc.free(s);
    }
    try testing.expectEqualStrings("TestFile", file_node.type);
    try testing.expect(try testEdgeExists(&db, "REQ-001", test_path, "VERIFIED_BY_CODE", alloc));
    try testing.expect(try testEdgeExists(&db, test_path, commit_hash, "CHANGED_IN", alloc));
}

test "repoScanCycle real git repo preserves historical rename path with present false" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/old_name.c",
        \\// REQ-001 implemented here
        \\int old_name(void) { return 0; }
        \\
    );
    _ = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T08:00:00Z");
    try fixture.renameFile("src/old_name.c", "src/new_name.c");
    const rename_commit = try fixture.commit("rename implementation file", "Alice", "alice@example.com", "2026-03-07T08:00:00Z");

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repoScanCycle(&ctx, alloc);

    const old_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/old_name.c" });
    const new_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/new_name.c" });
    defer alloc.free(old_path);
    defer alloc.free(new_path);

    try testing.expect((try db.getNode(old_path, alloc)) != null);
    try testing.expect((try db.getNode(new_path, alloc)) != null);
    try testing.expect(!try testGetNodeJsonBool(&db, old_path, "present", alloc));
    try testing.expect(try testGetNodeJsonBool(&db, new_path, "present", alloc));
    try testing.expect(try testEdgeExists(&db, new_path, rename_commit, "CHANGED_IN", alloc));
}

test "repoScanCycle real git repo backfills and advances cursor incrementally" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    const commit_1 = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T11:00:00Z");

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: SyncState = .{};
    var ctx = RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repoScanCycle(&ctx, alloc);

    const git_key = try std.fmt.allocPrint(alloc, "git_last_hash_{s}", .{fixture.path});
    defer alloc.free(git_key);
    const stored_hash_1 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_1);
    try testing.expectEqualStrings(commit_1, stored_hash_1);

    std.Thread.sleep(1200 * std.time.ns_per_ms);
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 2; }
        \\
    );
    const commit_2 = try fixture.commit("REQ-001 follow-up implementation", "Bob", "bob@example.com", "2026-03-07T11:00:00Z");
    try repoScanCycle(&ctx, alloc);

    const stored_hash_2 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_2);
    try testing.expectEqualStrings(commit_2, stored_hash_2);
    try testing.expect((try db.getNode(commit_1, alloc)) != null);
    try testing.expect((try db.getNode(commit_2, alloc)) != null);
}
