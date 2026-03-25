const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const encode = @import("encode.zig");
const suspect = @import("suspect.zig");

pub fn countGraph(g: anytype) !types.GraphCounts {
    var node_count: i64 = 0;
    var edge_count: i64 = 0;

    {
        var st = try g.db.prepare("SELECT COUNT(*) FROM nodes");
        defer st.finalize();
        if (try st.step()) node_count = st.columnInt(0);
    }
    {
        var st = try g.db.prepare("SELECT COUNT(*) FROM edges");
        defer st.finalize();
        if (try st.step()) edge_count = st.columnInt(0);
    }

    return .{ .nodes = node_count, .edges = edge_count };
}

pub fn addNode(g: anytype, id: []const u8, node_type: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    const sanitized_properties = try encode.sanitizeNodePropertiesJson(node_type, properties_json, std.heap.page_allocator);
    defer std.heap.page_allocator.free(sanitized_properties);
    const now = std.time.timestamp();
    var st = try g.db.prepare(
        \\INSERT OR IGNORE INTO nodes (id, type, properties, row_hash, created_at, updated_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    );
    defer st.finalize();
    try st.bindText(1, id);
    try st.bindText(2, node_type);
    try st.bindText(3, sanitized_properties);
    if (row_hash) |h| try st.bindText(4, h) else try st.bindNull(4);
    try st.bindInt(5, now);
    try st.bindInt(6, now);
    _ = try st.step();
}

pub fn updateNode(g: anytype, id: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
    var type_stmt = try g.db.prepare("SELECT type FROM nodes WHERE id=?");
    defer type_stmt.finalize();
    try type_stmt.bindText(1, id);
    if (!try type_stmt.step()) return;
    const node_type = type_stmt.columnText(0);
    const sanitized_properties = try encode.sanitizeNodePropertiesJson(node_type, properties_json, std.heap.page_allocator);
    defer std.heap.page_allocator.free(sanitized_properties);

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
        try upd.bindText(1, sanitized_properties);
        if (row_hash) |h| try upd.bindText(2, h) else try upd.bindNull(2);
        try upd.bindInt(3, now);
        try upd.bindText(4, id);
        _ = try upd.step();
    }
    try suspect.propagateSuspectLocked(g, id);
}

pub fn upsertNode(g: anytype, id: []const u8, node_type: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();

    var st = try g.db.prepare("SELECT row_hash FROM nodes WHERE id=?");
    defer st.finalize();
    try st.bindText(1, id);
    const has_row = try st.step();

    if (!has_row) {
        const sanitized_properties = try encode.sanitizeNodePropertiesJson(node_type, properties_json, std.heap.page_allocator);
        defer std.heap.page_allocator.free(sanitized_properties);
        const now = std.time.timestamp();
        var ins = try g.db.prepare(
            \\INSERT OR IGNORE INTO nodes (id, type, properties, row_hash, created_at, updated_at)
            \\VALUES (?, ?, ?, ?, ?, ?)
        );
        defer ins.finalize();
        try ins.bindText(1, id);
        try ins.bindText(2, node_type);
        try ins.bindText(3, sanitized_properties);
        if (row_hash) |h| try ins.bindText(4, h) else try ins.bindNull(4);
        try ins.bindInt(5, now);
        try ins.bindInt(6, now);
        _ = try ins.step();
    } else {
        if (row_hash == null) {
            try updateNode(g, id, properties_json, null);
        } else {
            const existing_hash = st.columnText(0);
            const new_hash = row_hash.?;
            if (!std.mem.eql(u8, existing_hash, new_hash)) {
                try updateNode(g, id, properties_json, row_hash);
            }
        }
    }
}

pub fn getNode(g: anytype, id: []const u8, alloc: Allocator) !?types.Node {
    var st = try g.db.prepare(
        "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE id=?"
    );
    defer st.finalize();
    try st.bindText(1, id);
    if (!try st.step()) return null;
    return try encode.stmtToNodeResolved(g, &st, alloc);
}

pub fn allNodes(g: anytype, alloc: Allocator, result: *std.ArrayList(types.Node)) !void {
    var st = try g.db.prepare(
        "SELECT id, type, properties, suspect, suspect_reason FROM nodes ORDER BY type, id"
    );
    defer st.finalize();
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToNodeResolved(g, &st, alloc));
    }
}

pub fn nodesByType(g: anytype, node_type: []const u8, alloc: Allocator, result: *std.ArrayList(types.Node)) !void {
    var st = try g.db.prepare(
        "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE type=? ORDER BY id"
    );
    defer st.finalize();
    try st.bindText(1, node_type);
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToNodeResolved(g, &st, alloc));
    }
}

pub fn nodesByTypePresent(g: anytype, node_type: []const u8, alloc: Allocator, result: *std.ArrayList(types.Node)) !void {
    var st = try g.db.prepare(
        \\SELECT id, type, properties, suspect, suspect_reason FROM nodes
        \\WHERE type=?
        \\  AND COALESCE(json_extract(properties,'$.present'), 1) != 0
        \\ORDER BY id
    );
    defer st.finalize();
    try st.bindText(1, node_type);
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToNodeResolved(g, &st, alloc));
    }
}

pub fn allNodeTypes(g: anytype, alloc: Allocator, result: *std.ArrayList([]const u8)) !void {
    var st = try g.db.prepare("SELECT DISTINCT type FROM nodes ORDER BY type");
    defer st.finalize();
    while (try st.step()) {
        try result.append(alloc, try alloc.dupe(u8, st.columnText(0)));
    }
}

pub fn search(g: anytype, query: []const u8, alloc: Allocator, result: *std.ArrayList(types.Node)) !void {
    var st = try g.db.prepare(
        \\SELECT id, type, properties, suspect, suspect_reason FROM nodes
        \\WHERE (
        \\       type != 'RequirementText'
        \\       AND (
        \\           lower(properties) LIKE lower(?)
        \\           OR lower(id) LIKE lower(?)
        \\       )
        \\   )
        \\   OR (
        \\       type = 'Requirement'
        \\       AND EXISTS (
        \\           SELECT 1
        \\           FROM edges e
        \\           JOIN nodes rt ON rt.id = e.from_id AND rt.type = 'RequirementText'
        \\           WHERE e.to_id = nodes.id
        \\             AND e.label = 'ASSERTS'
        \\             AND lower(COALESCE(json_extract(rt.properties, '$.text'), '')) LIKE lower(?)
        \\       )
        \\   )
        \\ORDER BY type, id
    );
    defer st.finalize();
    const like = try std.fmt.allocPrint(alloc, "%{s}%", .{query});
    try st.bindText(1, like);
    try st.bindText(2, like);
    try st.bindText(3, like);
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToNodeResolved(g, &st, alloc));
    }
}

pub fn deleteNode(g: anytype, id: []const u8) !void {
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
