const std = @import("std");
const internal = @import("internal.zig");

pub fn portGraphToDb(db: *internal.GraphDb, g: *internal.graph_mod.Graph, alloc: internal.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var node_iter = g.nodes.iterator();
    while (node_iter.next()) |entry| {
        const node = entry.value_ptr.*;
        const props_json = try serializeProperties(&node.properties, a);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(props_json);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hash_hex = std.fmt.bytesToHex(digest, .lower);
        try db.upsertNode(node.id, node.node_type.toString(), props_json, &hash_hex);
    }

    for (g.edges.items) |edge| {
        db.addEdge(edge.from_id, edge.to_id, edge.label.toString()) catch |e| {
            if (e != error.Exec) return e;
        };
    }
}

pub fn serializeProperties(props: *const std.StringHashMapUnmanaged([]const u8), alloc: internal.Allocator) ![]const u8 {
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

pub fn appendJsonEscaped(buf: *std.ArrayList(u8), s: []const u8, alloc: internal.Allocator) !void {
    try internal.json_util.appendJsonEscaped(buf, s, alloc);
}
