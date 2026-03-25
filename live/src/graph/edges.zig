const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const encode = @import("encode.zig");

pub fn allEdgeLabels(g: anytype, alloc: Allocator, result: *std.ArrayList([]const u8)) !void {
    var st = try g.db.prepare("SELECT DISTINCT label FROM edges ORDER BY label");
    defer st.finalize();
    while (try st.step()) {
        try result.append(alloc, try alloc.dupe(u8, st.columnText(0)));
    }
}

pub fn addEdge(g: anytype, from_id: []const u8, to_id: []const u8, label: []const u8) !void {
    return addEdgeWithProperties(g, from_id, to_id, label, null);
}

pub fn addEdgeWithProperties(g: anytype, from_id: []const u8, to_id: []const u8, label: []const u8, properties_json: ?[]const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();

    var chk = try g.db.prepare(
        "SELECT id FROM edges WHERE from_id=? AND to_id=? AND label=?"
    );
    defer chk.finalize();
    try chk.bindText(1, from_id);
    try chk.bindText(2, to_id);
    try chk.bindText(3, label);
    if (try chk.step()) return;

    const now = std.time.timestamp();
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
        "INSERT INTO edges (id, from_id, to_id, label, properties, created_at) VALUES (?,?,?,?,?,?)"
    );
    defer ins.finalize();
    try ins.bindText(1, &edge_id_buf);
    try ins.bindText(2, from_id);
    try ins.bindText(3, to_id);
    try ins.bindText(4, label);
    if (properties_json) |value| try ins.bindText(5, value) else try ins.bindNull(5);
    try ins.bindInt(6, now);
    _ = try ins.step();
}

pub fn edgesFrom(g: anytype, from_id: []const u8, alloc: Allocator, result: *std.ArrayList(types.Edge)) !void {
    var st = try g.db.prepare(
        "SELECT id, from_id, to_id, label, properties FROM edges WHERE from_id=?"
    );
    defer st.finalize();
    try st.bindText(1, from_id);
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToEdge(&st, alloc));
    }
}

pub fn edgesTo(g: anytype, to_id: []const u8, alloc: Allocator, result: *std.ArrayList(types.Edge)) !void {
    var st = try g.db.prepare(
        "SELECT id, from_id, to_id, label, properties FROM edges WHERE to_id=?"
    );
    defer st.finalize();
    try st.bindText(1, to_id);
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToEdge(&st, alloc));
    }
}

pub fn allEdges(g: anytype, alloc: Allocator, result: *std.ArrayList(types.Edge)) !void {
    var st = try g.db.prepare(
        "SELECT id, from_id, to_id, label, properties FROM edges ORDER BY from_id, label"
    );
    defer st.finalize();
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToEdge(&st, alloc));
    }
}

pub fn nodesMissingEdge(g: anytype, node_type: []const u8, edge_label: []const u8, alloc: Allocator, result: *std.ArrayList(types.Node)) !void {
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
        try result.append(alloc, try encode.stmtToNodeResolved(g, &st, alloc));
    }
}
