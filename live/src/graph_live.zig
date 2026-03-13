/// graph_live.zig — SQLite-backed graph for rtmify-live.
/// Mirrors graph.py method-for-method. All writes serialized via db.write_mu.
const std = @import("std");
const Allocator = std.mem.Allocator;
const db_mod = @import("db.zig");
const Db = db_mod.Db;
const Stmt = db_mod.Stmt;

// ---------------------------------------------------------------------------
// Public data types
// ---------------------------------------------------------------------------

pub const Node = struct {
    id: []const u8,
    type: []const u8,
    properties: []const u8, // JSON blob
    suspect: bool,
    suspect_reason: ?[]const u8,
};

pub const Edge = struct {
    id: []const u8,
    from_id: []const u8,
    to_id: []const u8,
    label: []const u8,
};

pub const RuntimeDiagnostic = struct {
    dedupe_key: []const u8,
    code: u16,
    severity: []const u8,
    title: []const u8,
    message: []const u8,
    source: []const u8,
    subject: ?[]const u8,
    details_json: []const u8,
    updated_at: i64,
};

pub const RtmRow = struct {
    req_id: []const u8,
    statement: ?[]const u8,
    status: ?[]const u8,
    user_need_id: ?[]const u8,
    user_need_statement: ?[]const u8,
    test_group_id: ?[]const u8,
    test_id: ?[]const u8,
    test_type: ?[]const u8,
    test_method: ?[]const u8,
    result: ?[]const u8,
    req_suspect: bool,
    req_suspect_reason: ?[]const u8,
};

pub const RiskRow = struct {
    risk_id: []const u8,
    description: ?[]const u8,
    initial_severity: ?[]const u8,
    initial_likelihood: ?[]const u8,
    mitigation: ?[]const u8,
    residual_severity: ?[]const u8,
    residual_likelihood: ?[]const u8,
    req_id: ?[]const u8,
    req_statement: ?[]const u8,
};

pub const TestRow = struct {
    test_group_id: []const u8,
    test_id: ?[]const u8,
    test_type: ?[]const u8,
    test_method: ?[]const u8,
    req_ids: [][]const u8,
    req_statements: [][]const u8,
    req_id: ?[]const u8,
    req_statement: ?[]const u8,
    test_suspect: bool,
    test_suspect_reason: ?[]const u8,
};

pub const ImpactNode = struct {
    id: []const u8,
    type: []const u8,
    properties: []const u8,
    via: []const u8,
    dir: []const u8,
};

pub const ImplementationChangeEvidence = struct {
    node_id: []const u8,
    node_type: []const u8,
    requirement_id: []const u8,
    file_id: []const u8,
    commit_id: []const u8,
    commit_short_hash: ?[]const u8,
    commit_date: ?[]const u8,
    commit_message: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Suspect propagation rules (mirrors graph.py)
// ---------------------------------------------------------------------------

/// Forward: from_id changes → to_id becomes suspect
const SUSPECT_FORWARD = [_][]const u8{ "TESTED_BY", "HAS_TEST", "MITIGATED_BY", "IMPLEMENTED_IN", "VERIFIED_BY_CODE" };
/// Backward: to_id changes → from_id becomes suspect
const SUSPECT_BACKWARD = [_][]const u8{"MITIGATED_BY"};

/// Impact traversal is broader than suspect propagation: it should reflect all
/// downstream traceability dependents, not only nodes that become suspect.
const IMPACT_FORWARD = [_][]const u8{
    "TESTED_BY",
    "HAS_TEST",
    "ALLOCATED_TO",
    "SATISFIED_BY",
    "CONTROLLED_BY",
    "IMPLEMENTED_IN",
    "VERIFIED_BY_CODE",
    "REFINED_BY",
};
const IMPACT_BACKWARD = [_][]const u8{
    "DERIVES_FROM",
    "MITIGATED_BY",
};

fn isSuspectForward(label: []const u8) bool {
    for (SUSPECT_FORWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

fn isSuspectBackward(label: []const u8) bool {
    for (SUSPECT_BACKWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

fn isImpactForward(label: []const u8) bool {
    for (IMPACT_FORWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

fn isImpactBackward(label: []const u8) bool {
    for (IMPACT_BACKWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// GraphDb
// ---------------------------------------------------------------------------

pub const GraphDb = struct {
    db: Db,

    pub fn init(path: [:0]const u8) !GraphDb {
        var d = try Db.open(path);
        try d.initSchema();
        return .{ .db = d };
    }

    pub fn deinit(g: *GraphDb) void {
        g.db.close();
    }

    // -----------------------------------------------------------------------
    // Node operations
    // -----------------------------------------------------------------------

    pub fn addNode(g: *GraphDb, id: []const u8, node_type: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        const now = std.time.timestamp();
        var st = try g.db.prepare(
            \\INSERT OR IGNORE INTO nodes (id, type, properties, row_hash, created_at, updated_at)
            \\VALUES (?, ?, ?, ?, ?, ?)
        );
        defer st.finalize();
        try st.bindText(1, id);
        try st.bindText(2, node_type);
        try st.bindText(3, properties_json);
        if (row_hash) |h| try st.bindText(4, h) else try st.bindNull(4);
        try st.bindInt(5, now);
        try st.bindInt(6, now);
        _ = try st.step();
    }

    pub fn updateNode(g: *GraphDb, id: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
        // Caller must hold write_mu; we acquire it here for internal calls.
        const now = std.time.timestamp();
        {
            var hist = try g.db.prepare(
                \\INSERT INTO node_history (node_id, properties, superseded_at)
                \\SELECT id, properties, ? FROM nodes WHERE id=?
            );
            defer hist.finalize();
            try hist.bindInt(1, now);
            try hist.bindText(2, id);
            _ = try hist.step();
        }
        {
            var upd = try g.db.prepare(
                \\UPDATE nodes SET properties=?, row_hash=?, updated_at=? WHERE id=?
            );
            defer upd.finalize();
            try upd.bindText(1, properties_json);
            if (row_hash) |h| try upd.bindText(2, h) else try upd.bindNull(2);
            try upd.bindInt(3, now);
            try upd.bindText(4, id);
            _ = try upd.step();
        }
        // propagate suspect (under same lock)
        try g.propagateSuspectLocked(id);
    }

    /// Create if new; update (with history) only if row_hash changed.
    pub fn upsertNode(g: *GraphDb, id: []const u8, node_type: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();

        var st = try g.db.prepare("SELECT row_hash FROM nodes WHERE id=?");
        defer st.finalize();
        try st.bindText(1, id);
        const has_row = try st.step();

        if (!has_row) {
            // Insert new node (no propagation for new nodes)
            const now = std.time.timestamp();
            var ins = try g.db.prepare(
                \\INSERT OR IGNORE INTO nodes (id, type, properties, row_hash, created_at, updated_at)
                \\VALUES (?, ?, ?, ?, ?, ?)
            );
            defer ins.finalize();
            try ins.bindText(1, id);
            try ins.bindText(2, node_type);
            try ins.bindText(3, properties_json);
            if (row_hash) |h| try ins.bindText(4, h) else try ins.bindNull(4);
            try ins.bindInt(5, now);
            try ins.bindInt(6, now);
            _ = try ins.step();
        } else {
            // Hashless nodes are intentionally always overwriteable. This is
            // required for runtime-enriched nodes like CodeAnnotation, where
            // the first upsert writes context and a later upsert adds blame.
            if (row_hash == null) {
                try g.updateNode(id, properties_json, null);
            } else {
                // Check if hash changed
                const existing_hash = st.columnText(0);
                const new_hash = row_hash.?;
                if (!std.mem.eql(u8, existing_hash, new_hash)) {
                    try g.updateNode(id, properties_json, row_hash);
                }
            }
        }
    }

    pub fn getNode(g: *GraphDb, id: []const u8, alloc: Allocator) !?Node {
        var st = try g.db.prepare(
            "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE id=?"
        );
        defer st.finalize();
        try st.bindText(1, id);
        if (!try st.step()) return null;
        return try stmtToNode(&st, alloc);
    }

    pub fn allNodes(g: *GraphDb, alloc: Allocator, result: *std.ArrayList(Node)) !void {
        var st = try g.db.prepare(
            "SELECT id, type, properties, suspect, suspect_reason FROM nodes ORDER BY type, id"
        );
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, try stmtToNode(&st, alloc));
        }
    }

    pub fn nodesByType(g: *GraphDb, node_type: []const u8, alloc: Allocator, result: *std.ArrayList(Node)) !void {
        var st = try g.db.prepare(
            "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE type=? ORDER BY id"
        );
        defer st.finalize();
        try st.bindText(1, node_type);
        while (try st.step()) {
            try result.append(alloc, try stmtToNode(&st, alloc));
        }
    }

    pub fn nodesByTypePresent(g: *GraphDb, node_type: []const u8, alloc: Allocator, result: *std.ArrayList(Node)) !void {
        var st = try g.db.prepare(
            \\SELECT id, type, properties, suspect, suspect_reason FROM nodes
            \\WHERE type=?
            \\  AND COALESCE(json_extract(properties,'$.present'), 1) != 0
            \\ORDER BY id
        );
        defer st.finalize();
        try st.bindText(1, node_type);
        while (try st.step()) {
            try result.append(alloc, try stmtToNode(&st, alloc));
        }
    }

    pub fn allNodeTypes(g: *GraphDb, alloc: Allocator, result: *std.ArrayList([]const u8)) !void {
        var st = try g.db.prepare("SELECT DISTINCT type FROM nodes ORDER BY type");
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, try alloc.dupe(u8, st.columnText(0)));
        }
    }

    pub fn allEdgeLabels(g: *GraphDb, alloc: Allocator, result: *std.ArrayList([]const u8)) !void {
        var st = try g.db.prepare("SELECT DISTINCT label FROM edges ORDER BY label");
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, try alloc.dupe(u8, st.columnText(0)));
        }
    }

    /// Returns SourceFile and TestFile nodes whose properties contain
    /// `"repo": "<repo_path>"`.
    pub fn nodesByRepo(g: *GraphDb, repo_path: []const u8, alloc: Allocator, result: *std.ArrayList(Node)) !void {
        var st = try g.db.prepare(
            \\SELECT id, type, properties, suspect, suspect_reason FROM nodes
            \\WHERE type IN ('SourceFile','TestFile')
            \\AND json_extract(properties,'$.repo') = ?
            \\AND COALESCE(json_extract(properties,'$.present'), 1) != 0
            \\ORDER BY id
        );
        defer st.finalize();
        try st.bindText(1, repo_path);
        while (try st.step()) {
            try result.append(alloc, try stmtToNode(&st, alloc));
        }
    }

    pub fn requirementsWithImplementationChangesSince(
        g: *GraphDb,
        since: []const u8,
        repo_path: ?[]const u8,
        alloc: Allocator,
        result: *std.ArrayList(ImplementationChangeEvidence),
    ) !void {
        var st = try g.db.prepare(
            \\SELECT DISTINCT
            \\  req.id,
            \\  req.type,
            \\  req.id,
            \\  file.id,
            \\  cmt.id,
            \\  json_extract(cmt.properties,'$.short_hash'),
            \\  json_extract(cmt.properties,'$.date'),
            \\  json_extract(cmt.properties,'$.message')
            \\FROM nodes req
            \\JOIN edges impl ON impl.from_id = req.id AND impl.label = 'IMPLEMENTED_IN'
            \\JOIN nodes file ON file.id = impl.to_id AND file.type = 'SourceFile'
            \\JOIN edges chg ON chg.from_id = file.id AND chg.label = 'CHANGED_IN'
            \\JOIN nodes cmt ON cmt.id = chg.to_id AND cmt.type = 'Commit'
            \\WHERE req.type = 'Requirement'
            \\  AND json_extract(cmt.properties,'$.date') > ?
            \\  AND (? IS NULL OR json_extract(file.properties,'$.repo') = ?)
            \\ORDER BY json_extract(cmt.properties,'$.date') DESC, req.id, file.id
        );
        defer st.finalize();
        try st.bindText(1, since);
        if (repo_path) |rp| {
            try st.bindText(2, rp);
            try st.bindText(3, rp);
        } else {
            try st.bindNull(2);
            try st.bindNull(3);
        }
        while (try st.step()) {
            try result.append(alloc, .{
                .node_id = try alloc.dupe(u8, st.columnText(0)),
                .node_type = try alloc.dupe(u8, st.columnText(1)),
                .requirement_id = try alloc.dupe(u8, st.columnText(2)),
                .file_id = try alloc.dupe(u8, st.columnText(3)),
                .commit_id = try alloc.dupe(u8, st.columnText(4)),
                .commit_short_hash = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
                .commit_date = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
                .commit_message = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
            });
        }
    }

    pub fn userNeedsWithImplementationChangesSince(
        g: *GraphDb,
        since: []const u8,
        repo_path: ?[]const u8,
        alloc: Allocator,
        result: *std.ArrayList(ImplementationChangeEvidence),
    ) !void {
        var st = try g.db.prepare(
            \\SELECT DISTINCT
            \\  un.id,
            \\  un.type,
            \\  req.id,
            \\  file.id,
            \\  cmt.id,
            \\  json_extract(cmt.properties,'$.short_hash'),
            \\  json_extract(cmt.properties,'$.date'),
            \\  json_extract(cmt.properties,'$.message')
            \\FROM nodes un
            \\JOIN edges drv ON drv.to_id = un.id AND drv.label = 'DERIVES_FROM'
            \\JOIN nodes req ON req.id = drv.from_id AND req.type = 'Requirement'
            \\JOIN edges impl ON impl.from_id = req.id AND impl.label = 'IMPLEMENTED_IN'
            \\JOIN nodes file ON file.id = impl.to_id AND file.type = 'SourceFile'
            \\JOIN edges chg ON chg.from_id = file.id AND chg.label = 'CHANGED_IN'
            \\JOIN nodes cmt ON cmt.id = chg.to_id AND cmt.type = 'Commit'
            \\WHERE un.type = 'UserNeed'
            \\  AND json_extract(cmt.properties,'$.date') > ?
            \\  AND (? IS NULL OR json_extract(file.properties,'$.repo') = ?)
            \\ORDER BY json_extract(cmt.properties,'$.date') DESC, un.id, req.id, file.id
        );
        defer st.finalize();
        try st.bindText(1, since);
        if (repo_path) |rp| {
            try st.bindText(2, rp);
            try st.bindText(3, rp);
        } else {
            try st.bindNull(2);
            try st.bindNull(3);
        }
        while (try st.step()) {
            try result.append(alloc, .{
                .node_id = try alloc.dupe(u8, st.columnText(0)),
                .node_type = try alloc.dupe(u8, st.columnText(1)),
                .requirement_id = try alloc.dupe(u8, st.columnText(2)),
                .file_id = try alloc.dupe(u8, st.columnText(3)),
                .commit_id = try alloc.dupe(u8, st.columnText(4)),
                .commit_short_hash = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
                .commit_date = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
                .commit_message = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
            });
        }
    }

    // -----------------------------------------------------------------------
    // Edge operations
    // -----------------------------------------------------------------------

    pub fn addEdge(g: *GraphDb, from_id: []const u8, to_id: []const u8, label: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();

        // Idempotency check
        var chk = try g.db.prepare(
            "SELECT id FROM edges WHERE from_id=? AND to_id=? AND label=?"
        );
        defer chk.finalize();
        try chk.bindText(1, from_id);
        try chk.bindText(2, to_id);
        try chk.bindText(3, label);
        if (try chk.step()) return; // already exists

        const now = std.time.timestamp();
        // Generate a simple edge ID: sha256 of from+to+label, hex encoded
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(from_id);
        h.update("|");
        h.update(to_id);
        h.update("|");
        h.update(label);
        var edge_digest: [32]u8 = undefined;
        h.final(&edge_digest);
        const edge_id_buf = std.fmt.bytesToHex(edge_digest, .lower);

        var ins = try g.db.prepare(
            "INSERT INTO edges (id, from_id, to_id, label, properties, created_at) VALUES (?,?,?,?,NULL,?)"
        );
        defer ins.finalize();
        try ins.bindText(1, &edge_id_buf);
        try ins.bindText(2, from_id);
        try ins.bindText(3, to_id);
        try ins.bindText(4, label);
        try ins.bindInt(5, now);
        _ = try ins.step();
    }

    pub fn edgesFrom(g: *GraphDb, from_id: []const u8, alloc: Allocator, result: *std.ArrayList(Edge)) !void {
        var st = try g.db.prepare(
            "SELECT id, from_id, to_id, label FROM edges WHERE from_id=?"
        );
        defer st.finalize();
        try st.bindText(1, from_id);
        while (try st.step()) {
            try result.append(alloc, try stmtToEdge(&st, alloc));
        }
    }

    pub fn edgesTo(g: *GraphDb, to_id: []const u8, alloc: Allocator, result: *std.ArrayList(Edge)) !void {
        var st = try g.db.prepare(
            "SELECT id, from_id, to_id, label FROM edges WHERE to_id=?"
        );
        defer st.finalize();
        try st.bindText(1, to_id);
        while (try st.step()) {
            try result.append(alloc, try stmtToEdge(&st, alloc));
        }
    }

    pub fn allEdges(g: *GraphDb, alloc: Allocator, result: *std.ArrayList(Edge)) !void {
        var st = try g.db.prepare(
            "SELECT id, from_id, to_id, label FROM edges ORDER BY from_id, label"
        );
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, try stmtToEdge(&st, alloc));
        }
    }

    // -----------------------------------------------------------------------
    // Suspect propagation
    // -----------------------------------------------------------------------

    fn propagateSuspectLocked(g: *GraphDb, changed_id: []const u8) !void {
        // Forward: from changed_id outward
        var fwd = try g.db.prepare(
            "SELECT label, to_id FROM edges WHERE from_id=?"
        );
        defer fwd.finalize();
        try fwd.bindText(1, changed_id);

        // We must collect before updating to avoid cursor invalidation
        var fwd_targets: [64]struct { label: [64]u8, label_len: usize, to_id: [256]u8, to_id_len: usize } = undefined;
        var fwd_count: usize = 0;
        while (try fwd.step()) {
            if (fwd_count >= fwd_targets.len) break;
            const label = fwd.columnText(0);
            const to_id = fwd.columnText(1);
            @memcpy(fwd_targets[fwd_count].label[0..label.len], label);
            fwd_targets[fwd_count].label_len = label.len;
            @memcpy(fwd_targets[fwd_count].to_id[0..to_id.len], to_id);
            fwd_targets[fwd_count].to_id_len = to_id.len;
            fwd_count += 1;
        }

        for (fwd_targets[0..fwd_count]) |t| {
            const label = t.label[0..t.label_len];
            const to_id = t.to_id[0..t.to_id_len];
            if (isSuspectForward(label)) {
                try g.setSuspectLocked(to_id, changed_id);
            }
        }

        // Backward: nodes pointing TO changed_id
        var bwd = try g.db.prepare(
            "SELECT label, from_id FROM edges WHERE to_id=?"
        );
        defer bwd.finalize();
        try bwd.bindText(1, changed_id);

        var bwd_targets: [64]struct { label: [64]u8, label_len: usize, from_id: [256]u8, from_id_len: usize } = undefined;
        var bwd_count: usize = 0;
        while (try bwd.step()) {
            if (bwd_count >= bwd_targets.len) break;
            const label = bwd.columnText(0);
            const from_id = bwd.columnText(1);
            @memcpy(bwd_targets[bwd_count].label[0..label.len], label);
            bwd_targets[bwd_count].label_len = label.len;
            @memcpy(bwd_targets[bwd_count].from_id[0..from_id.len], from_id);
            bwd_targets[bwd_count].from_id_len = from_id.len;
            bwd_count += 1;
        }

        for (bwd_targets[0..bwd_count]) |t| {
            const label = t.label[0..t.label_len];
            const from_id = t.from_id[0..t.from_id_len];
            if (isSuspectBackward(label)) {
                try g.setSuspectLocked(from_id, changed_id);
            }
        }
    }

    fn setSuspectLocked(g: *GraphDb, node_id: []const u8, reason_node: []const u8) !void {
        var reason_buf: [300]u8 = undefined;
        const reason = std.fmt.bufPrint(&reason_buf, "{s} changed", .{reason_node}) catch reason_buf[0..];
        var st = try g.db.prepare(
            "UPDATE nodes SET suspect=1, suspect_reason=? WHERE id=?"
        );
        defer st.finalize();
        try st.bindText(1, reason);
        try st.bindText(2, node_id);
        _ = try st.step();
    }

    pub fn clearSuspect(g: *GraphDb, id: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare(
            "UPDATE nodes SET suspect=0, suspect_reason=NULL WHERE id=?"
        );
        defer st.finalize();
        try st.bindText(1, id);
        _ = try st.step();
    }

    pub fn suspects(g: *GraphDb, alloc: Allocator, result: *std.ArrayList(Node)) !void {
        var st = try g.db.prepare(
            "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE suspect=1 ORDER BY type, id"
        );
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, try stmtToNode(&st, alloc));
        }
    }

    // -----------------------------------------------------------------------
    // Impact analysis (BFS)
    // -----------------------------------------------------------------------

    pub fn impact(g: *GraphDb, node_id: []const u8, alloc: Allocator, result: *std.ArrayList(ImpactNode)) !void {
        var visited: std.StringHashMapUnmanaged(void) = .{};
        defer visited.deinit(alloc);
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(alloc);
        try queue.append(alloc, try alloc.dupe(u8, node_id));

        var qi: usize = 0;
        while (qi < queue.items.len) {
            const current = queue.items[qi];
            qi += 1;

            // Forward
            var fwd_st = try g.db.prepare(
                "SELECT label, to_id FROM edges WHERE from_id=?"
            );
            defer fwd_st.finalize();
            try fwd_st.bindText(1, current);
            while (try fwd_st.step()) {
                const label = try alloc.dupe(u8, fwd_st.columnText(0));
                const to_id = try alloc.dupe(u8, fwd_st.columnText(1));
                if (isImpactForward(label) and !visited.contains(to_id)) {
                    try visited.put(alloc, to_id, {});
                    if (try g.getNode(to_id, alloc)) |n| {
                        try result.append(alloc, .{
                            .id = n.id,
                            .type = n.type,
                            .properties = n.properties,
                            .via = label,
                            .dir = "→",
                        });
                        try queue.append(alloc, to_id);
                    }
                }
            }

            // Backward
            var bwd_st = try g.db.prepare(
                "SELECT label, from_id FROM edges WHERE to_id=?"
            );
            defer bwd_st.finalize();
            try bwd_st.bindText(1, current);
            while (try bwd_st.step()) {
                const label = try alloc.dupe(u8, bwd_st.columnText(0));
                const from_id = try alloc.dupe(u8, bwd_st.columnText(1));
                if (isImpactBackward(label) and !visited.contains(from_id)) {
                    try visited.put(alloc, from_id, {});
                    if (try g.getNode(from_id, alloc)) |n| {
                        try result.append(alloc, .{
                            .id = n.id,
                            .type = n.type,
                            .properties = n.properties,
                            .via = label,
                            .dir = "←",
                        });
                        try queue.append(alloc, from_id);
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Gap query
    // -----------------------------------------------------------------------

    pub fn nodesMissingEdge(g: *GraphDb, node_type: []const u8, edge_label: []const u8, alloc: Allocator, result: *std.ArrayList(Node)) !void {
        var st = try g.db.prepare(
            \\SELECT n.id, n.type, n.properties, n.suspect, n.suspect_reason FROM nodes n
            \\WHERE n.type = ?
            \\  AND NOT EXISTS (
            \\      SELECT 1 FROM edges e
            \\      WHERE e.from_id = n.id AND e.label = ?
            \\  )
            \\ORDER BY n.id
        );
        defer st.finalize();
        try st.bindText(1, node_type);
        try st.bindText(2, edge_label);
        while (try st.step()) {
            try result.append(alloc, try stmtToNode(&st, alloc));
        }
    }

    // -----------------------------------------------------------------------
    // RTM / Risk / Tests queries
    // -----------------------------------------------------------------------

    pub fn rtm(g: *GraphDb, alloc: Allocator, result: *std.ArrayList(RtmRow)) !void {
        var st = try g.db.prepare(
            \\SELECT
            \\    r.id                                             AS req_id,
            \\    json_extract(r.properties, '$.statement')        AS statement,
            \\    json_extract(r.properties, '$.status')           AS status,
            \\    un.id                                            AS user_need_id,
            \\    json_extract(un.properties, '$.statement')       AS user_need_statement,
            \\    tg.id                                            AS test_group_id,
            \\    t.id                                             AS test_id,
            \\    json_extract(t.properties, '$.test_type')        AS test_type,
            \\    json_extract(t.properties, '$.test_method')      AS test_method,
            \\    json_extract(tr.properties, '$.result')          AS result,
            \\    r.suspect                                        AS req_suspect,
            \\    r.suspect_reason                                 AS req_suspect_reason
            \\FROM nodes r
            \\LEFT JOIN edges e_df  ON e_df.from_id = r.id AND e_df.label = 'DERIVES_FROM'
            \\LEFT JOIN nodes un    ON un.id = e_df.to_id
            \\LEFT JOIN edges e_tb  ON e_tb.from_id = r.id AND e_tb.label = 'TESTED_BY'
            \\LEFT JOIN nodes tg    ON tg.id = e_tb.to_id
            \\LEFT JOIN edges e_ht  ON e_ht.from_id = tg.id AND e_ht.label = 'HAS_TEST'
            \\LEFT JOIN nodes t     ON t.id = e_ht.to_id
            \\LEFT JOIN edges e_ro  ON e_ro.to_id = t.id AND e_ro.label = 'RESULT_OF'
            \\LEFT JOIN nodes tr    ON tr.id = e_ro.from_id
            \\WHERE r.type = 'Requirement'
            \\ORDER BY r.id, tg.id, t.id
        );
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, .{
                .req_id = try alloc.dupe(u8, st.columnText(0)),
                .statement = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
                .status = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
                .user_need_id = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
                .user_need_statement = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
                .test_group_id = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
                .test_id = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
                .test_type = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
                .test_method = if (st.columnIsNull(8)) null else try alloc.dupe(u8, st.columnText(8)),
                .result = if (st.columnIsNull(9)) null else try alloc.dupe(u8, st.columnText(9)),
                .req_suspect = st.columnInt(10) != 0,
                .req_suspect_reason = if (st.columnIsNull(11)) null else try alloc.dupe(u8, st.columnText(11)),
            });
        }
    }

    pub fn risks(g: *GraphDb, alloc: Allocator, result: *std.ArrayList(RiskRow)) !void {
        var st = try g.db.prepare(
            \\SELECT
            \\    r.id                                                AS risk_id,
            \\    json_extract(r.properties, '$.description')        AS description,
            \\    json_extract(r.properties, '$.initial_severity')   AS initial_severity,
            \\    json_extract(r.properties, '$.initial_likelihood') AS initial_likelihood,
            \\    json_extract(r.properties, '$.mitigation')         AS mitigation,
            \\    json_extract(r.properties, '$.residual_severity')  AS residual_severity,
            \\    json_extract(r.properties, '$.residual_likelihood') AS residual_likelihood,
            \\    req.id                                             AS req_id,
            \\    json_extract(req.properties, '$.statement')        AS req_statement
            \\FROM nodes r
            \\LEFT JOIN edges e    ON e.from_id = r.id AND e.label = 'MITIGATED_BY'
            \\LEFT JOIN nodes req  ON req.id = e.to_id
            \\WHERE r.type = 'Risk'
            \\ORDER BY r.id
        );
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, .{
                .risk_id = try alloc.dupe(u8, st.columnText(0)),
                .description = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
                .initial_severity = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
                .initial_likelihood = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
                .mitigation = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
                .residual_severity = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
                .residual_likelihood = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
                .req_id = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
                .req_statement = if (st.columnIsNull(8)) null else try alloc.dupe(u8, st.columnText(8)),
            });
        }
    }

    pub fn tests(g: *GraphDb, alloc: Allocator, result: *std.ArrayList(TestRow)) !void {
        const JoinRow = struct {
            test_group_id: []const u8,
            test_id: ?[]const u8,
            test_type: ?[]const u8,
            test_method: ?[]const u8,
            req_id: ?[]const u8,
            req_statement: ?[]const u8,
            test_suspect: bool,
            test_suspect_reason: ?[]const u8,
        };

        var join_rows: std.ArrayList(JoinRow) = .empty;
        defer {
            for (join_rows.items) |row| {
                alloc.free(row.test_group_id);
                if (row.test_id) |v| alloc.free(v);
                if (row.test_type) |v| alloc.free(v);
                if (row.test_method) |v| alloc.free(v);
                if (row.req_id) |v| alloc.free(v);
                if (row.req_statement) |v| alloc.free(v);
                if (row.test_suspect_reason) |v| alloc.free(v);
            }
            join_rows.deinit(alloc);
        }

        var st = try g.db.prepare(
            \\SELECT
            \\    tg.id                                            AS test_group_id,
            \\    t.id                                             AS test_id,
            \\    json_extract(t.properties, '$.test_type')        AS test_type,
            \\    json_extract(t.properties, '$.test_method')      AS test_method,
            \\    r.id                                             AS req_id,
            \\    json_extract(r.properties, '$.statement')        AS req_statement,
            \\    COALESCE(t.suspect, 0)                           AS test_suspect,
            \\    t.suspect_reason                                 AS test_suspect_reason
            \\FROM nodes tg
            \\LEFT JOIN edges e_ht ON e_ht.from_id = tg.id AND e_ht.label = 'HAS_TEST'
            \\LEFT JOIN nodes t    ON t.id = e_ht.to_id
            \\LEFT JOIN edges e_tb ON e_tb.to_id = tg.id AND e_tb.label = 'TESTED_BY'
            \\LEFT JOIN nodes r    ON r.id = e_tb.from_id
            \\WHERE tg.type = 'TestGroup'
            \\ORDER BY tg.id, t.id
        );
        defer st.finalize();
        while (try st.step()) {
            try join_rows.append(alloc, .{
                .test_group_id = try alloc.dupe(u8, st.columnText(0)),
                .test_id = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
                .test_type = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
                .test_method = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
                .req_id = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
                .req_statement = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
                .test_suspect = st.columnInt(6) != 0,
                .test_suspect_reason = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
            });
        }

        for (join_rows.items) |row| {
            var existing: ?*TestRow = null;
            for (result.items) |*candidate| {
                const same_group = std.mem.eql(u8, candidate.test_group_id, row.test_group_id);
                const same_test = if (candidate.test_id == null and row.test_id == null)
                    true
                else if (candidate.test_id) |candidate_id|
                    if (row.test_id) |row_id| std.mem.eql(u8, candidate_id, row_id) else false
                else
                    false;
                if (same_group and same_test) {
                    existing = candidate;
                    break;
                }
            }

            if (existing == null) {
                try result.append(alloc, .{
                    .test_group_id = try alloc.dupe(u8, row.test_group_id),
                    .test_id = if (row.test_id) |v| try alloc.dupe(u8, v) else null,
                    .test_type = if (row.test_type) |v| try alloc.dupe(u8, v) else null,
                    .test_method = if (row.test_method) |v| try alloc.dupe(u8, v) else null,
                    .req_ids = &.{},
                    .req_statements = &.{},
                    .req_id = null,
                    .req_statement = null,
                    .test_suspect = row.test_suspect,
                    .test_suspect_reason = if (row.test_suspect_reason) |v| try alloc.dupe(u8, v) else null,
                });
                existing = &result.items[result.items.len - 1];
            }

            if (row.req_id) |req_id| {
                var seen = false;
                for (existing.?.req_ids) |existing_req_id| {
                    if (std.mem.eql(u8, existing_req_id, req_id)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    const next_ids = try alloc.alloc([]const u8, existing.?.req_ids.len + 1);
                    @memcpy(next_ids[0..existing.?.req_ids.len], existing.?.req_ids);
                    next_ids[existing.?.req_ids.len] = try alloc.dupe(u8, req_id);
                    if (existing.?.req_ids.len > 0) alloc.free(existing.?.req_ids);
                    existing.?.req_ids = next_ids;

                    const next_statements = try alloc.alloc([]const u8, existing.?.req_statements.len + 1);
                    @memcpy(next_statements[0..existing.?.req_statements.len], existing.?.req_statements);
                    next_statements[existing.?.req_statements.len] = if (row.req_statement) |statement|
                        try alloc.dupe(u8, statement)
                    else
                        try alloc.dupe(u8, "");
                    if (existing.?.req_statements.len > 0) alloc.free(existing.?.req_statements);
                    existing.?.req_statements = next_statements;
                }
            }
        }

        for (result.items) |*row| {
            if (row.req_ids.len == 1) {
                row.req_id = row.req_ids[0];
                row.req_statement = row.req_statements[0];
            } else {
                row.req_id = null;
                row.req_statement = null;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Search
    // -----------------------------------------------------------------------

    pub fn search(g: *GraphDb, query: []const u8, alloc: Allocator, result: *std.ArrayList(Node)) !void {
        var st = try g.db.prepare(
            \\SELECT id, type, properties, suspect, suspect_reason FROM nodes
            \\WHERE lower(properties) LIKE lower(?) OR lower(id) LIKE lower(?)
            \\ORDER BY type, id
        );
        defer st.finalize();
        const like = try std.fmt.allocPrint(alloc, "%{s}%", .{query});
        try st.bindText(1, like);
        try st.bindText(2, like);
        while (try st.step()) {
            try result.append(alloc, try stmtToNode(&st, alloc));
        }
    }

    // -----------------------------------------------------------------------
    // Credentials + Config
    // -----------------------------------------------------------------------

    pub fn storeCredential(g: *GraphDb, content: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();

        // Generate ID from sha256 of content
        var cred_h = std.crypto.hash.sha2.Sha256.init(.{});
        cred_h.update(content);
        var cred_digest: [32]u8 = undefined;
        cred_h.final(&cred_digest);
        const id_buf = std.fmt.bytesToHex(cred_digest, .lower);

        const now = std.time.timestamp();
        var st = try g.db.prepare(
            "INSERT OR REPLACE INTO credentials (id, content, created_at) VALUES (?, ?, ?)"
        );
        defer st.finalize();
        try st.bindText(1, &id_buf);
        try st.bindText(2, content);
        try st.bindInt(3, now);
        _ = try st.step();
    }

    pub fn getLatestCredential(g: *GraphDb, alloc: Allocator) !?[]const u8 {
        var st = try g.db.prepare(
            "SELECT content FROM credentials ORDER BY created_at DESC LIMIT 1"
        );
        defer st.finalize();
        if (!try st.step()) return null;
        return try alloc.dupe(u8, st.columnText(0));
    }

    pub fn hasLegacyCredential(g: *GraphDb) !bool {
        var st = try g.db.prepare("SELECT 1 FROM credentials LIMIT 1");
        defer st.finalize();
        return try st.step();
    }

    pub fn clearLegacyCredentials(g: *GraphDb) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare("DELETE FROM credentials");
        defer st.finalize();
        _ = try st.step();
    }

    pub fn storeConfig(g: *GraphDb, key: []const u8, value: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare(
            "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)"
        );
        defer st.finalize();
        try st.bindText(1, key);
        try st.bindText(2, value);
        _ = try st.step();
    }

    pub fn getConfig(g: *GraphDb, key: []const u8, alloc: Allocator) !?[]const u8 {
        var st = try g.db.prepare(
            "SELECT value FROM config WHERE key=?"
        );
        defer st.finalize();
        try st.bindText(1, key);
        if (!try st.step()) return null;
        return try alloc.dupe(u8, st.columnText(0));
    }

    pub fn upsertRuntimeDiagnostic(
        g: *GraphDb,
        dedupe_key: []const u8,
        code: u16,
        severity: []const u8,
        title: []const u8,
        message: []const u8,
        source: []const u8,
        subject: ?[]const u8,
        details_json: []const u8,
    ) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare(
            \\INSERT OR REPLACE INTO runtime_diagnostics
            \\(dedupe_key, code, severity, title, message, source, subject, details_json, updated_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer st.finalize();
        try st.bindText(1, dedupe_key);
        try st.bindInt(2, code);
        try st.bindText(3, severity);
        try st.bindText(4, title);
        try st.bindText(5, message);
        try st.bindText(6, source);
        if (subject) |s| try st.bindText(7, s) else try st.bindNull(7);
        try st.bindText(8, details_json);
        try st.bindInt(9, std.time.timestamp());
        _ = try st.step();
    }

    pub fn clearRuntimeDiagnosticsBySource(g: *GraphDb, source: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare("DELETE FROM runtime_diagnostics WHERE source=?");
        defer st.finalize();
        try st.bindText(1, source);
        _ = try st.step();
    }

    pub fn clearRuntimeDiagnosticsBySubjectPrefix(g: *GraphDb, source: []const u8, prefix: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare(
            "DELETE FROM runtime_diagnostics WHERE source=? AND subject IS NOT NULL AND subject LIKE ? || '%'"
        );
        defer st.finalize();
        try st.bindText(1, source);
        try st.bindText(2, prefix);
        _ = try st.step();
    }

    pub fn clearRuntimeDiagnostic(g: *GraphDb, dedupe_key: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare("DELETE FROM runtime_diagnostics WHERE dedupe_key=?");
        defer st.finalize();
        try st.bindText(1, dedupe_key);
        _ = try st.step();
    }

    pub fn listRuntimeDiagnostics(
        g: *GraphDb,
        source_filter: ?[]const u8,
        alloc: Allocator,
        result: *std.ArrayList(RuntimeDiagnostic),
    ) !void {
        if (source_filter) |source| {
            var st = try g.db.prepare(
                \\SELECT dedupe_key, code, severity, title, message, source, subject, details_json, updated_at
                \\FROM runtime_diagnostics WHERE source=? ORDER BY severity DESC, code, dedupe_key
            );
            defer st.finalize();
            try st.bindText(1, source);
            while (try st.step()) {
                try result.append(alloc, try stmtToRuntimeDiagnostic(&st, alloc));
            }
        } else {
            var st = try g.db.prepare(
                \\SELECT dedupe_key, code, severity, title, message, source, subject, details_json, updated_at
                \\FROM runtime_diagnostics ORDER BY severity DESC, code, dedupe_key
            );
            defer st.finalize();
            while (try st.step()) {
                try result.append(alloc, try stmtToRuntimeDiagnostic(&st, alloc));
            }
        }
    }

    /// Delete a node and all its edges. Acquires write_mu.
    pub fn deleteNode(g: *GraphDb, id: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        {
            var st = try g.db.prepare("DELETE FROM edges WHERE from_id=? OR to_id=?");
            defer st.finalize();
            try st.bindText(1, id);
            try st.bindText(2, id);
            _ = try st.step();
        }
        {
            var st = try g.db.prepare("DELETE FROM nodes WHERE id=?");
            defer st.finalize();
            try st.bindText(1, id);
            _ = try st.step();
        }
    }

    /// Delete a config key. Acquires write_mu.
    pub fn deleteConfig(g: *GraphDb, key: []const u8) !void {
        g.db.write_mu.lock();
        defer g.db.write_mu.unlock();
        var st = try g.db.prepare("DELETE FROM config WHERE key=?");
        defer st.finalize();
        try st.bindText(1, key);
        _ = try st.step();
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn stmtToNode(st: *Stmt, alloc: Allocator) !Node {
    return .{
        .id = try alloc.dupe(u8, st.columnText(0)),
        .type = try alloc.dupe(u8, st.columnText(1)),
        .properties = try alloc.dupe(u8, st.columnText(2)),
        .suspect = st.columnInt(3) != 0,
        .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
    };
}

fn stmtToEdge(st: *Stmt, alloc: Allocator) !Edge {
    return .{
        .id = try alloc.dupe(u8, st.columnText(0)),
        .from_id = try alloc.dupe(u8, st.columnText(1)),
        .to_id = try alloc.dupe(u8, st.columnText(2)),
        .label = try alloc.dupe(u8, st.columnText(3)),
    };
}

fn stmtToRuntimeDiagnostic(st: *Stmt, alloc: Allocator) !RuntimeDiagnostic {
    return .{
        .dedupe_key = try alloc.dupe(u8, st.columnText(0)),
        .code = @intCast(st.columnInt(1)),
        .severity = try alloc.dupe(u8, st.columnText(2)),
        .title = try alloc.dupe(u8, st.columnText(3)),
        .message = try alloc.dupe(u8, st.columnText(4)),
        .source = try alloc.dupe(u8, st.columnText(5)),
        .subject = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
        .details_json = try alloc.dupe(u8, st.columnText(7)),
        .updated_at = st.columnInt(8),
    };
}

// ---------------------------------------------------------------------------
// Row hash helper (used by sync_live.zig)
// ---------------------------------------------------------------------------

pub fn hashRow(cells: []const []const u8) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (cells, 0..) |cell, i| {
        if (i > 0) h.update("|");
        h.update(cell);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "addNode and getNode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();

    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"The system SHALL work\"}", "hash1");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expect(node != null);
    try testing.expectEqualStrings("REQ-001", node.?.id);
    try testing.expectEqualStrings("Requirement", node.?.type);
    try testing.expect(!node.?.suspect);
    try testing.expect(node.?.suspect_reason == null);
}

test "addNode idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();

    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"first\"}", "h1");
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"second\"}", "h2");
    const node = try g.getNode("REQ-001", alloc);
    // INSERT OR IGNORE: first insert wins
    try testing.expectEqualStrings("{\"statement\":\"first\"}", node.?.properties);
}

test "getNode missing returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try testing.expect(try g.getNode("DOES-NOT-EXIST", alloc) == null);
}

test "upsertNode creates on first call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v1\"}", "hash1");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expect(node != null);
    try testing.expectEqualStrings("{\"statement\":\"v1\"}", node.?.properties);
}

test "upsertNode updates on hash change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v1\"}", "hash1");
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v2\"}", "hash2");
    const node = try g.getNode("REQ-001", alloc);
    try testing.expectEqualStrings("{\"statement\":\"v2\"}", node.?.properties);
}

test "upsertNode no-op on same hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v1\"}", "hash1");
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v2\"}", "hash1");
    const node = try g.getNode("REQ-001", alloc);
    // Same hash → no update → v1 still there
    try testing.expectEqualStrings("{\"statement\":\"v1\"}", node.?.properties);
}

test "upsertNode updates hashless nodes on later overwrite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.upsertNode(
        "file.zig:42",
        "CodeAnnotation",
        "{\"req_id\":\"REQ-001\",\"line_number\":42}",
        null,
    );
    try g.upsertNode(
        "file.zig:42",
        "CodeAnnotation",
        "{\"req_id\":\"REQ-001\",\"line_number\":42,\"blame_author\":\"alice\",\"author_time\":123}",
        null,
    );
    const node = try g.getNode("file.zig:42", alloc);
    try testing.expect(node != null);
    try testing.expect(std.mem.indexOf(u8, node.?.properties, "\"blame_author\":\"alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, node.?.properties, "\"author_time\":123") != null);
}

test "addEdge idempotent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY"); // duplicate

    var edges: std.ArrayList(Edge) = .empty;
    try g.edgesFrom("REQ-001", alloc, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("TESTED_BY", edges.items[0].label);
}

test "suspect propagation forward" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", "h1");
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");

    // Update REQ-001 → TG-001 should become suspect
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"changed\"}", "h2");

    const tg = try g.getNode("TG-001", alloc);
    try testing.expect(tg.?.suspect);
    try testing.expect(tg.?.suspect_reason != null);
}

test "clearSuspect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", "h1");
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.upsertNode("REQ-001", "Requirement", "{\"statement\":\"v2\"}", "h2");

    try g.clearSuspect("TG-001");
    const tg = try g.getNode("TG-001", alloc);
    try testing.expect(!tg.?.suspect);
}

test "nodesMissingEdge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("REQ-002", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");

    var gaps: std.ArrayList(Node) = .empty;
    try g.nodesMissingEdge("Requirement", "TESTED_BY", alloc, &gaps);
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectEqualStrings("REQ-002", gaps.items[0].id);
}

test "rtm basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"SHALL work\",\"status\":\"approved\"}", null);
    try g.addNode("UN-001", "UserNeed", "{\"statement\":\"I need it\"}", null);
    try g.addEdge("REQ-001", "UN-001", "DERIVES_FROM");

    var rows: std.ArrayList(RtmRow) = .empty;
    try g.rtm(alloc, &rows);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_id);
    try testing.expectEqualStrings("UN-001", rows.items[0].user_need_id.?);
}

test "rtm emits multiple rows for multiple linked test groups" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"SHALL work\",\"status\":\"approved\"}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addNode("TG-002", "TestGroup", "{}", null);
    try g.addNode("T-001", "Test", "{\"result\":\"PASS\"}", null);
    try g.addNode("T-002", "Test", "{\"result\":\"PENDING\"}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("REQ-001", "TG-002", "TESTED_BY");
    try g.addEdge("TG-001", "T-001", "HAS_TEST");
    try g.addEdge("TG-002", "T-002", "HAS_TEST");

    var rows: std.ArrayList(RtmRow) = .empty;
    try g.rtm(alloc, &rows);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("TG-001", rows.items[0].test_group_id.?);
    try testing.expectEqualStrings("TG-002", rows.items[1].test_group_id.?);
}

test "tests aggregates multiple linked requirements for shared test group" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"One\"}", null);
    try g.addNode("REQ-002", "Requirement", "{\"statement\":\"Two\"}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addNode("TEST-001", "Test", "{\"test_type\":\"Verification\",\"test_method\":\"Test\"}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("REQ-002", "TG-001", "TESTED_BY");
    try g.addEdge("TG-001", "TEST-001", "HAS_TEST");

    var rows: std.ArrayList(TestRow) = .empty;
    defer {
        for (rows.items) |row| {
            alloc.free(row.test_group_id);
            if (row.test_id) |v| alloc.free(v);
            if (row.test_type) |v| alloc.free(v);
            if (row.test_method) |v| alloc.free(v);
            for (row.req_ids) |v| alloc.free(v);
            if (row.req_ids.len > 0) alloc.free(row.req_ids);
            for (row.req_statements) |v| alloc.free(v);
            if (row.req_statements.len > 0) alloc.free(row.req_statements);
            if (row.test_suspect_reason) |v| alloc.free(v);
        }
        rows.deinit(alloc);
    }
    try g.tests(alloc, &rows);

    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqual(@as(usize, 2), rows.items[0].req_ids.len);
    try testing.expect(rows.items[0].req_id == null);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_ids[0]);
    try testing.expectEqualStrings("REQ-002", rows.items[0].req_ids[1]);
}

test "risks basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("RSK-001", "Risk", "{\"description\":\"GPS loss\",\"initial_severity\":\"4\"}", null);
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");

    var rows: std.ArrayList(RiskRow) = .empty;
    try g.risks(alloc, &rows);
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("RSK-001", rows.items[0].risk_id);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_id.?);
}

test "search" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{\"statement\":\"sterile packaging required\"}", null);
    try g.addNode("REQ-002", "Requirement", "{\"statement\":\"unrelated\"}", null);

    var results: std.ArrayList(Node) = .empty;
    try g.search("sterile", alloc, &results);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("REQ-001", results.items[0].id);
}

test "upsertNode hash change populates node_history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = alloc;

    var g = try GraphDb.init(":memory:");
    defer g.deinit();

    // First upsert — inserts with hash "h1"
    try g.upsertNode("REQ-001", "Requirement", "{\"text\":\"v1\"}", "h1");
    // Second upsert with new hash — should archive v1 into node_history
    try g.upsertNode("REQ-001", "Requirement", "{\"text\":\"v2\"}", "h2");

    // node_history must have exactly 1 row (the archived v1)
    var st = try g.db.prepare("SELECT COUNT(*) FROM node_history WHERE node_id='REQ-001'");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 1), st.columnInt(0));

    // Third upsert with same hash — no additional history entry
    try g.upsertNode("REQ-001", "Requirement", "{\"text\":\"v3\"}", "h2");
    var st2 = try g.db.prepare("SELECT COUNT(*) FROM node_history WHERE node_id='REQ-001'");
    defer st2.finalize();
    _ = try st2.step();
    try testing.expectEqual(@as(i64, 1), st2.columnInt(0));
}

test "storeCredential and getLatestCredential" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.storeCredential("{\"client_email\":\"test@example.com\"}");
    const content = try g.getLatestCredential(alloc);
    try testing.expect(content != null);
    try testing.expectEqualStrings("{\"client_email\":\"test@example.com\"}", content.?);
}

test "hasLegacyCredential and clearLegacyCredentials" {
    var g = try GraphDb.init(":memory:");
    defer g.deinit();

    try testing.expect(!(try g.hasLegacyCredential()));
    try g.storeCredential("{\"client_email\":\"test@example.com\"}");
    try testing.expect(try g.hasLegacyCredential());
    try g.clearLegacyCredentials();
    try testing.expect(!(try g.hasLegacyCredential()));
}

test "storeConfig and getConfig" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.storeConfig("sheet_id", "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms");
    const val = try g.getConfig("sheet_id", alloc);
    try testing.expect(val != null);
    try testing.expectEqualStrings("1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms", val.?);
}

test "getConfig missing returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    const val = try g.getConfig("nonexistent", alloc);
    try testing.expect(val == null);
}

test "runtime diagnostics round-trip and clear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();

    try g.upsertRuntimeDiagnostic(
        "git:/tmp/repo:1001",
        1001,
        "warn",
        "git log command failed",
        "git log failed for /tmp/repo",
        "git",
        "/tmp/repo",
        "{}",
    );

    var diags: std.ArrayList(RuntimeDiagnostic) = .empty;
    defer diags.deinit(alloc);
    try g.listRuntimeDiagnostics(null, alloc, &diags);
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(@as(u16, 1001), diags.items[0].code);
    try testing.expectEqualStrings("git", diags.items[0].source);

    try g.clearRuntimeDiagnosticsBySubjectPrefix("git", "/tmp/repo");

    diags.clearRetainingCapacity();
    try g.listRuntimeDiagnostics(null, alloc, &diags);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "allNodes and allNodeTypes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("UN-001", "UserNeed", "{}", null);

    var all: std.ArrayList(Node) = .empty;
    try g.allNodes(alloc, &all);
    try testing.expectEqual(@as(usize, 2), all.items.len);

    var types: std.ArrayList([]const u8) = .empty;
    try g.allNodeTypes(alloc, &types);
    try testing.expectEqual(@as(usize, 2), types.items.len);
}

test "hashRow stable" {
    const cells = [_][]const u8{ "REQ-001", "The system SHALL work", "approved" };
    const h1 = hashRow(&cells);
    const h2 = hashRow(&cells);
    try testing.expectEqualSlices(u8, &h1, &h2);
}

test "hashRow different input" {
    const a = [_][]const u8{ "REQ-001", "v1" };
    const b = [_][]const u8{ "REQ-001", "v2" };
    const h1 = hashRow(&a);
    const h2 = hashRow(&b);
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "impact forward propagation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");

    var result: std.ArrayList(ImpactNode) = .empty;
    try g.impact("REQ-001", alloc, &result);
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("TG-001", result.items[0].id);
    try testing.expectEqualStrings("→", result.items[0].dir);
}

test "impact from user need includes derived requirements and downstream tests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("UN-001", "UserNeed", "{}", null);
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("TG-001", "TestGroup", "{}", null);
    try g.addNode("TEST-001", "Test", "{}", null);
    try g.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try g.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try g.addEdge("TG-001", "TEST-001", "HAS_TEST");

    var result: std.ArrayList(ImpactNode) = .empty;
    try g.impact("UN-001", alloc, &result);
    try testing.expectEqual(@as(usize, 3), result.items.len);
    try testing.expectEqualStrings("REQ-001", result.items[0].id);
    try testing.expectEqualStrings("←", result.items[0].dir);
    try testing.expectEqualStrings("TG-001", result.items[1].id);
    try testing.expectEqualStrings("→", result.items[1].dir);
    try testing.expectEqualStrings("TEST-001", result.items[2].id);
}

test "impact from requirement includes backward mitigations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("RSK-001", "Risk", "{}", null);
    try g.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");

    var result: std.ArrayList(ImpactNode) = .empty;
    try g.impact("REQ-001", alloc, &result);
    try testing.expectEqual(@as(usize, 1), result.items.len);
    try testing.expectEqualStrings("RSK-001", result.items[0].id);
    try testing.expectEqualStrings("←", result.items[0].dir);
}
