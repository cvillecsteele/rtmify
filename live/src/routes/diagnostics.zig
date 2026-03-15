const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const profile_mod = @import("../profile.zig");
const chain_mod = @import("../chain.zig");
const guide_catalog = @import("../guide_catalog.zig");
const shared = @import("shared.zig");

pub fn handleCoverageReport(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var total: i64 = 0;
    {
        var st = try db.db.prepare("SELECT COUNT(*) FROM nodes WHERE type='Requirement'");
        defer st.finalize();
        if (try st.step()) total = st.columnInt(0);
    }

    var implemented: i64 = 0;
    {
        var st = try db.db.prepare(
            "SELECT COUNT(DISTINCT n.id) FROM nodes n JOIN edges e ON e.from_id=n.id AND e.label='IMPLEMENTED_IN' WHERE n.type='Requirement'"
        );
        defer st.finalize();
        if (try st.step()) implemented = st.columnInt(0);
    }

    var orphan_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (orphan_files.items) |s| alloc.free(s);
        orphan_files.deinit(alloc);
    }
    {
        var st = try db.db.prepare(
            \\SELECT id FROM nodes WHERE type='SourceFile'
            \\AND id NOT IN (SELECT to_id FROM edges WHERE label='IMPLEMENTED_IN')
        );
        defer st.finalize();
        while (try st.step()) {
            try orphan_files.append(alloc, try alloc.dupe(u8, st.columnText(0)));
        }
    }

    const pct: i64 = if (total > 0) @divTrunc(implemented * 100, total) else 0;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.writer(alloc).print(
        "# Code Coverage Report\n\n| Metric | Count |\n|--------|-------|\n| Total Requirements | {d} |\n| Implemented | {d} ({d}%) |\n| Orphan Source Files | {d} |\n",
        .{ total, implemented, pct, orphan_files.items.len },
    );
    if (orphan_files.items.len > 0) {
        try buf.appendSlice(alloc, "\n## Orphan Source Files\n\n");
        for (orphan_files.items) |path| {
            try buf.writer(alloc).print("- `{s}`\n", .{path});
        }
    }
    return alloc.dupe(u8, buf.items);
}

pub fn handleClearSuspect(db: *graph_live.GraphDb, node_id: []const u8, alloc: Allocator) ![]const u8 {
    try db.clearSuspect(node_id);
    return alloc.dupe(u8, "{\"ok\":true}");
}

pub fn handleIngest(db: *graph_live.GraphDb, body: []const u8, alloc: Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return alloc.dupe(u8, "{\"ok\":false,\"error\":\"expected object\"}");

    const type_val = root.object.get("type") orelse
        return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing type\"}");
    if (type_val != .string) return alloc.dupe(u8, "{\"ok\":false,\"error\":\"type must be string\"}");

    if (std.mem.eql(u8, type_val.string, "node")) {
        const id_val = root.object.get("id") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing id\"}");
        const nt_val = root.object.get("node_type") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing node_type\"}");
        if (id_val != .string or nt_val != .string)
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"id and node_type must be strings\"}");

        var props_buf: std.ArrayList(u8) = .empty;
        defer props_buf.deinit(alloc);
        if (root.object.get("properties")) |props| {
            const props_json_str = try std.json.Stringify.valueAlloc(alloc, props, .{});
            defer alloc.free(props_json_str);
            try props_buf.appendSlice(alloc, props_json_str);
        } else {
            try props_buf.appendSlice(alloc, "{}");
        }

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(props_buf.items);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hash_hex = std.fmt.bytesToHex(digest, .lower);

        try db.upsertNode(id_val.string, nt_val.string, props_buf.items, &hash_hex);
        return alloc.dupe(u8, "{\"ok\":true}");
    } else if (std.mem.eql(u8, type_val.string, "edge")) {
        const from_val = root.object.get("from") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing from\"}");
        const to_val = root.object.get("to") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing to\"}");
        const label_val = root.object.get("label") orelse
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing label\"}");
        if (from_val != .string or to_val != .string or label_val != .string)
            return alloc.dupe(u8, "{\"ok\":false,\"error\":\"from, to, label must be strings\"}");

        db.addEdge(from_val.string, to_val.string, label_val.string) catch |e| {
            if (e != error.Exec) return e;
        };
        return alloc.dupe(u8, "{\"ok\":true}");
    } else {
        return alloc.dupe(u8, "{\"ok\":false,\"error\":\"type must be node or edge\"}");
    }
}

pub fn handleDiagnostics(db: *graph_live.GraphDb, source_filter: ?[]const u8, alloc: Allocator) ![]const u8 {
    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |d| shared.freeRuntimeDiagnostic(d, alloc);
        diags.deinit(alloc);
    }
    const source = if (source_filter) |s|
        if (std.mem.eql(u8, s, "all")) null else shared.sourceFilterValue(s)
    else
        null;
    try db.listRuntimeDiagnostics(source, alloc, &diags);
    return shared.runtimeDiagnosticsJson(diags.items, alloc);
}

pub fn handleGuideErrors(alloc: Allocator) ![]const u8 {
    return guide_catalog.guideErrorsJson(alloc);
}

pub fn handleChainGaps(db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) ![]const u8 {
    const pid = profile_mod.fromString(profile_name) orelse .generic;
    const prof = profile_mod.get(pid);

    const edge_gaps = try chain_mod.walkChain(db, prof, alloc);
    defer alloc.free(edge_gaps);
    const special_gaps = try chain_mod.walkSpecialGaps(db, prof, alloc);
    defer alloc.free(special_gaps);

    var all: std.ArrayList(chain_mod.Gap) = .empty;
    defer all.deinit(alloc);
    try all.appendSlice(alloc, edge_gaps);
    try all.appendSlice(alloc, special_gaps);
    return chain_mod.gapsToJson(all.items, alloc);
}

const testing = std.testing;

test "handleIngest node payload inserts node" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const body = "{\"type\":\"node\",\"id\":\"REQ-001\",\"node_type\":\"Requirement\",\"properties\":{\"text\":\"shall do X\"}}";
    const resp = try handleIngest(&db, body, alloc);
    try testing.expectEqualStrings("{\"ok\":true}", resp);

    const node = try db.getNode("REQ-001", alloc);
    try testing.expect(node != null);
    try testing.expectEqualStrings("Requirement", node.?.type);
}

test "handleIngest edge payload inserts edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TEST-001", "TestGroup", "{}", null);

    const body = "{\"type\":\"edge\",\"from\":\"REQ-001\",\"to\":\"TEST-001\",\"label\":\"TESTED_BY\"}";
    const resp = try handleIngest(&db, body, alloc);
    try testing.expectEqualStrings("{\"ok\":true}", resp);

    var edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges.items) |e| shared.freeEdge(e, alloc);
        edges.deinit(alloc);
    }
    try db.edgesFrom("REQ-001", alloc, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("TESTED_BY", edges.items[0].label);
}

test "handleIngest malformed JSON returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handleIngest(&db, "not json{{{", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "handleChainGaps includes code and title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    const resp = try handleChainGaps(&db, "medical", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"title\":") != null);
}

test "handleChainGaps returns empty for generic profile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    const resp = try handleChainGaps(&db, "generic", alloc);
    try testing.expectEqualStrings("[]", resp);
}

test "handleGuideErrors returns grouped guide catalog" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const resp = try handleGuideErrors(alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"groups\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code_label\":\"E901\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"anchor\":\"guide-code-E901\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"surface\":\"chain_gap\"") != null);
}
