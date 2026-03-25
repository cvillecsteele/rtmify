const std = @import("std");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const util = @import("util.zig");
const trace_refs = @import("trace_refs.zig");
const query_metrics = @import("query_metrics.zig");
const json_mod = @import("json.zig");

pub const Allocator = std.mem.Allocator;

pub fn getBomItemJson(
    db: *graph_live.GraphDb,
    item_id: []const u8,
    alloc: Allocator,
) ![]const u8 {
    const node = try db.getNode(item_id, alloc);
    if (node == null) return error.NotFound;
    defer shared.freeNode(node.?, alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"node\":");
    try shared.appendNodeObject(&buf, node.?, alloc);
    try buf.appendSlice(alloc, ",\"parent_chains\":");

    var visited: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        visited.deinit();
    }
    try appendParentChainsJson(&buf, db, item_id, &visited, alloc);

    var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_requirements, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

    var linked_tests: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_tests, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

    try buf.appendSlice(alloc, ",\"linked_requirements\":");
    try json_mod.appendNodeJsonArray(&buf, linked_requirements.items, alloc);
    try buf.appendSlice(alloc, ",\"linked_tests\":");
    try json_mod.appendNodeJsonArray(&buf, linked_tests.items, alloc);

    const unresolved_requirement_ids = try trace_refs.unresolvedTraceRefs(node.?.properties, "requirement_ids", linked_requirements.items, alloc);
    defer util.freeStringSlice(unresolved_requirement_ids, alloc);
    const unresolved_test_ids = try trace_refs.unresolvedTraceRefs(node.?.properties, "test_ids", linked_tests.items, alloc);
    defer util.freeStringSlice(unresolved_test_ids, alloc);
    try buf.appendSlice(alloc, ",\"unresolved_requirement_ids\":");
    try util.appendJsonStringArray(&buf, unresolved_requirement_ids, alloc);
    try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
    try util.appendJsonStringArray(&buf, unresolved_test_ids, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn getDesignBomTreeJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    if (!include_obsolete and query_metrics.productStatusExcludedFromActiveGraph(try query_metrics.productStatusForIdentifier(db, full_product_identifier, alloc))) {
        return error.NotFound;
    }
    var st = try db.db.prepare(
        \\SELECT
        \\  id,
        \\  json_extract(properties, '$.bom_type'),
        \\  json_extract(properties, '$.source_format'),
        \\  properties
        \\FROM nodes
        \\WHERE type='DesignBOM'
        \\  AND json_extract(properties, '$.full_product_identifier')=?
        \\  AND json_extract(properties, '$.bom_name')=?
        \\ORDER BY json_extract(properties, '$.bom_type')
    );
    defer st.finalize();
    try st.bindText(1, full_product_identifier);
    try st.bindText(2, bom_name);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, bom_name, alloc);
    try buf.appendSlice(alloc, ",\"design_boms\":[");
    var first = true;
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        const bom_id = st.columnText(0);
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, bom_id, alloc);
        try buf.appendSlice(alloc, ",\"bom_type\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"source_format\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, st.columnText(3));
        try buf.appendSlice(alloc, ",\"tree\":");
        try appendBomTreeJson(&buf, db, bom_id, alloc);
        try buf.append(alloc, '}');
    }
    if (first) return error.NotFound;
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn getDesignBomItemsJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    if (!include_obsolete and query_metrics.productStatusExcludedFromActiveGraph(try query_metrics.productStatusForIdentifier(db, full_product_identifier, alloc))) {
        return error.NotFound;
    }
    const prefixes = try query_metrics.designBomPrefixes(db, full_product_identifier, bom_name, alloc);
    defer util.freeStringSlice(prefixes, alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, bom_name, alloc);
    try buf.appendSlice(alloc, ",\"items\":[");
    var first = true;
    for (prefixes) |prefix| {
        var st = try db.db.prepare(
            \\SELECT id
            \\FROM nodes
            \\WHERE type='BOMItem' AND id LIKE ?
            \\ORDER BY id
        );
        defer st.finalize();
        const pattern = try std.fmt.allocPrint(alloc, "{s}%", .{prefix});
        defer alloc.free(pattern);
        try st.bindText(1, pattern);
        while (try st.step()) {
            const item_json = try getBomItemJson(db, st.columnText(0), alloc);
            defer alloc.free(item_json);
            if (!first) try buf.append(alloc, ',');
            first = false;
            try buf.appendSlice(alloc, item_json);
        }
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn appendBomTreeJson(buf: *std.ArrayList(u8), db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !void {
    var roots: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (roots.items) |edge| shared.freeEdge(edge, alloc);
        roots.deinit(alloc);
    }
    try db.edgesFrom(bom_id, alloc, &roots);

    try buf.appendSlice(alloc, "{\"roots\":[");
    var first = true;
    for (roots.items) |edge| {
        if (!std.mem.eql(u8, edge.label, "CONTAINS")) continue;
        if (!first) try buf.append(alloc, ',');
        first = false;
        var visited = std.StringHashMap(void).init(alloc);
        defer {
            var it = visited.keyIterator();
            while (it.next()) |key| alloc.free(key.*);
            visited.deinit();
        }
        try appendBomItemTreeJson(buf, db, edge.to_id, edge.properties, &visited, alloc);
    }
    try buf.appendSlice(alloc, "]}");
}

pub fn appendBomItemTreeJson(
    buf: *std.ArrayList(u8),
    db: *graph_live.GraphDb,
    item_id: []const u8,
    edge_properties: ?[]const u8,
    visited: *std.StringHashMap(void),
    alloc: Allocator,
) !void {
    const node = try db.getNode(item_id, alloc);
    if (node == null) {
        try buf.appendSlice(alloc, "null");
        return;
    }
    defer shared.freeNode(node.?, alloc);

    if (!visited.contains(item_id)) try visited.put(try alloc.dupe(u8, item_id), {});

    try buf.appendSlice(alloc, "{\"id\":");
    try shared.appendJsonStr(buf, node.?.id, alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try shared.appendJsonStr(buf, node.?.type, alloc);
    try buf.appendSlice(alloc, ",\"properties\":");
    try buf.appendSlice(alloc, node.?.properties);
    try buf.appendSlice(alloc, ",\"edge_properties\":");
    if (edge_properties) |value| try buf.appendSlice(alloc, value) else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"children\":[");

    var edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges.items) |edge| shared.freeEdge(edge, alloc);
        edges.deinit(alloc);
    }
    try db.edgesFrom(item_id, alloc, &edges);

    var first = true;
    for (edges.items) |edge| {
        if (!std.mem.eql(u8, edge.label, "CONTAINS")) continue;
        if (visited.contains(edge.to_id)) continue;
        if (!first) try buf.append(alloc, ',');
        first = false;
        try appendBomItemTreeJson(buf, db, edge.to_id, edge.properties, visited, alloc);
    }
    try buf.appendSlice(alloc, "]}");
}

pub fn appendParentChainsJson(
    buf: *std.ArrayList(u8),
    db: *graph_live.GraphDb,
    item_id: []const u8,
    visited: *std.StringHashMap(void),
    alloc: Allocator,
) !void {
    if (visited.contains(item_id)) {
        try buf.appendSlice(alloc, "[]");
        return;
    }
    try visited.put(try alloc.dupe(u8, item_id), {});

    var incoming: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (incoming.items) |edge| shared.freeEdge(edge, alloc);
        incoming.deinit(alloc);
    }
    try db.edgesTo(item_id, alloc, &incoming);

    try buf.append(alloc, '[');
    var first = true;
    for (incoming.items) |edge| {
        if (!std.mem.eql(u8, edge.label, "CONTAINS")) continue;
        const parent = try db.getNode(edge.from_id, alloc);
        if (parent == null) continue;
        defer shared.freeNode(parent.?, alloc);

        if (!first) try buf.append(alloc, ',');
        first = false;
        if (std.mem.eql(u8, parent.?.type, "DesignBOM")) {
            try buf.append(alloc, '[');
            try buf.appendSlice(alloc, "{\"id\":");
            try shared.appendJsonStr(buf, parent.?.id, alloc);
            try buf.appendSlice(alloc, ",\"type\":");
            try shared.appendJsonStr(buf, parent.?.type, alloc);
            try buf.appendSlice(alloc, ",\"properties\":");
            try buf.appendSlice(alloc, parent.?.properties);
            try buf.appendSlice(alloc, ",\"edge_properties\":");
            if (edge.properties) |value| try buf.appendSlice(alloc, value) else try buf.appendSlice(alloc, "null");
            try buf.appendSlice(alloc, "}]");
        } else {
            var nested_visited = std.StringHashMap(void).init(alloc);
            defer {
                var it = nested_visited.keyIterator();
                while (it.next()) |key| alloc.free(key.*);
                nested_visited.deinit();
            }
            try nested_visited.put(try alloc.dupe(u8, item_id), {});

            var parent_chains_buf: std.ArrayList(u8) = .empty;
            defer parent_chains_buf.deinit(alloc);
            try appendParentChainsJson(&parent_chains_buf, db, edge.from_id, &nested_visited, alloc);
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, parent_chains_buf.items, .{});
            defer parsed.deinit();
            for (parsed.value.array.items, 0..) |chain, idx| {
                if (idx > 0) try buf.append(alloc, ',');
                const chain_json = try chainToJson(chain, edge, parent.?, alloc);
                defer alloc.free(chain_json);
                try buf.appendSlice(alloc, chain_json);
            }
        }
    }
    try buf.append(alloc, ']');
}

pub fn chainToJson(chain: std.json.Value, edge: graph_live.Edge, parent: graph_live.Node, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    if (chain != .array) return alloc.dupe(u8, "[]");
    try buf.append(alloc, '[');
    for (chain.array.items, 0..) |item, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        const item_json = try std.json.Stringify.valueAlloc(alloc, item, .{});
        defer alloc.free(item_json);
        try buf.appendSlice(alloc, item_json);
    }
    if (chain.array.items.len > 0) try buf.append(alloc, ',');
    try buf.appendSlice(alloc, "{\"id\":");
    try shared.appendJsonStr(&buf, parent.id, alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try shared.appendJsonStr(&buf, parent.type, alloc);
    try buf.appendSlice(alloc, ",\"properties\":");
    try buf.appendSlice(alloc, parent.properties);
    try buf.appendSlice(alloc, ",\"edge_properties\":");
    if (edge.properties) |value| try buf.appendSlice(alloc, value) else try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, "}]");
    return alloc.dupe(u8, buf.items);
}
