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

const testing = std.testing;

fn freeProps(props: []graph_mod.Property, alloc: Allocator) void {
    for (props) |p| {
        alloc.free(p.key);
        alloc.free(p.value);
    }
    alloc.free(props);
}

test "parsePropsJson handles strings numbers bools and null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const props = try parsePropsJson("{\"name\":\"gps\",\"count\":3,\"enabled\":true,\"skip\":null}", alloc);
    defer freeProps(props, alloc);

    try testing.expectEqual(@as(usize, 4), props.len);
    try testing.expectEqualStrings("name", props[0].key);
    try testing.expectEqualStrings("gps", props[0].value);
    try testing.expectEqualStrings("count", props[1].key);
    try testing.expectEqualStrings("3", props[1].value);
    try testing.expectEqualStrings("enabled", props[2].key);
    try testing.expectEqualStrings("true", props[2].value);
    try testing.expectEqualStrings("skip", props[3].key);
    try testing.expectEqualStrings("", props[3].value);
}

test "buildGraphFromSqlite ports extended live nodes and edges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Detect GPS loss\"}", null);
    try db.addNode("DI-001", "DesignInput", "{\"description\":\"Timing spec\"}", null);
    try db.addNode("DO-001", "DesignOutput", "{\"description\":\"Firmware\"}", null);
    try db.addNode("CI-001", "ConfigurationItem", "{\"version\":\"1.0\"}", null);
    try db.addNode("src/gps.c", "SourceFile", "{\"path\":\"src/gps.c\"}", null);

    try db.addEdge("REQ-001", "DI-001", "ALLOCATED_TO");
    try db.addEdge("DI-001", "DO-001", "SATISFIED_BY");
    try db.addEdge("DO-001", "CI-001", "CONTROLLED_BY");
    try db.addEdge("DO-001", "src/gps.c", "IMPLEMENTED_IN");

    var g = try buildGraphFromSqlite(&db, alloc);
    defer g.deinit();

    try testing.expect(g.getNode("REQ-001") != null);
    try testing.expect(g.getNode("DI-001") != null);
    try testing.expect(g.getNode("DO-001") != null);
    try testing.expect(g.getNode("CI-001") != null);

    var edges: std.ArrayList(graph_mod.Edge) = .empty;
    defer edges.deinit(alloc);
    try g.edgesFrom("DO-001", alloc, &edges);

    var found_controlled_by = false;
    var found_implemented_in = false;
    for (edges.items) |e| {
        if (e.label == .controlled_by and std.mem.eql(u8, e.to_id, "CI-001")) found_controlled_by = true;
        if (e.label == .implemented_in and std.mem.eql(u8, e.to_id, "src/gps.c")) found_implemented_in = true;
    }
    try testing.expect(found_controlled_by);
    try testing.expect(found_implemented_in);
}
