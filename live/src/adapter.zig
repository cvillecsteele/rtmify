/// adapter.zig — bridge between SQLite GraphDb and in-memory Graph.
///
/// Builds an ephemeral in-memory Graph from SQLite for report rendering.
/// Caller owns the returned Graph and must call graph.deinit().
const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const graph_mod = rtmify.graph;

const graph_live = @import("graph_live.zig");

/// Build an ephemeral in-memory Graph from the SQLite GraphDb.
/// Caller must call g.deinit() when done.
pub fn buildGraphFromSqlite(db: *graph_live.GraphDb, alloc: Allocator) !graph_mod.Graph {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var g = graph_mod.Graph.init(alloc);
    errdefer g.deinit();

    // Load all nodes
    var nodes: std.ArrayList(graph_live.Node) = .empty;
    defer {
        for (nodes.items) |n| {
            alloc.free(n.id);
            alloc.free(n.type);
            alloc.free(n.properties);
            if (n.suspect_reason) |r| alloc.free(r);
        }
        nodes.deinit(alloc);
    }
    try db.allNodes(alloc, &nodes);

    for (nodes.items) |node| {
        const node_type = graph_mod.NodeType.fromString(node.type) orelse continue;
        // Parse properties JSON into key-value pairs
        const props = try parsePropsJson(node.properties, a);
        try g.addNode(node.id, node_type, props);
    }

    // Load all edges
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
    try db.allEdges(alloc, &edges);

    for (edges.items) |edge| {
        const label = graph_mod.EdgeLabel.fromString(edge.label) orelse continue;
        g.addEdge(edge.from_id, edge.to_id, label) catch |e| {
            if (e == error.Exec) continue; // duplicate edges are ok
            return e;
        };
    }

    return g;
}

/// Minimal JSON object parser: returns a slice of Property pairs.
/// Only handles flat string values (no nesting). Uses arena for allocations.
fn parsePropsJson(json: []const u8, alloc: Allocator) ![]graph_mod.Property {
    var props: std.ArrayList(graph_mod.Property) = .empty;
    defer props.deinit(alloc);

    var pos: usize = 0;
    // Skip opening '{'
    while (pos < json.len and json[pos] != '{') pos += 1;
    if (pos >= json.len) return try alloc.alloc(graph_mod.Property, 0);
    pos += 1;

    while (pos < json.len) {
        // Skip whitespace/commas
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\n' or
            json[pos] == '\r' or json[pos] == '\t' or json[pos] == ',')) pos += 1;

        if (pos >= json.len or json[pos] == '}') break;
        if (json[pos] != '"') break; // malformed

        // Read key
        pos += 1;
        const key_start = pos;
        while (pos < json.len and json[pos] != '"') {
            if (json[pos] == '\\') pos += 1;
            pos += 1;
        }
        const key = json[key_start..pos];
        if (pos < json.len) pos += 1; // closing '"'

        // Skip ':'
        while (pos < json.len and json[pos] != ':') pos += 1;
        if (pos < json.len) pos += 1;

        // Skip whitespace
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;

        if (pos >= json.len) break;

        var value_buf: std.ArrayList(u8) = .empty;
        defer value_buf.deinit(alloc);

        if (json[pos] == '"') {
            pos += 1;
            while (pos < json.len and json[pos] != '"') {
                if (json[pos] == '\\' and pos + 1 < json.len) {
                    pos += 1;
                    const ch: u8 = switch (json[pos]) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        '"' => '"',
                        '\\' => '\\',
                        else => json[pos],
                    };
                    try value_buf.append(alloc, ch);
                } else {
                    try value_buf.append(alloc, json[pos]);
                }
                pos += 1;
            }
            if (pos < json.len) pos += 1; // closing '"'
        } else {
            // number/boolean/null
            const start = pos;
            while (pos < json.len and json[pos] != ',' and json[pos] != '}') pos += 1;
            const raw = std.mem.trim(u8, json[start..pos], " \t");
            if (!std.mem.eql(u8, raw, "null")) {
                try value_buf.appendSlice(alloc, raw);
            }
        }

        const key_copy = try alloc.dupe(u8, key);
        const val_copy = try alloc.dupe(u8, value_buf.items);
        try props.append(alloc, .{ .key = key_copy, .value = val_copy });
    }

    return props.toOwnedSlice(alloc);
}
