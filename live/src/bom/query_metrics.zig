const std = @import("std");
const graph_live = @import("../graph_live.zig");
const json_util = @import("../json_util.zig");
const shared = @import("../routes/shared.zig");
const trace_refs = @import("trace_refs.zig");
const util = @import("util.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const Allocator = std.mem.Allocator;

pub fn classifyProductStatus(raw_value: ?[]const u8) types.ProductStatus {
    const raw = raw_value orelse return .active;
    const value = std.mem.trim(u8, raw, " \r\n\t");
    if (value.len == 0) return .active;
    if (std.ascii.eqlIgnoreCase(value, "Active")) return .active;
    if (std.ascii.eqlIgnoreCase(value, "In Development") or std.ascii.eqlIgnoreCase(value, "Development")) return .in_development;
    if (std.ascii.eqlIgnoreCase(value, "Superseded")) return .superseded;
    if (std.ascii.eqlIgnoreCase(value, "EOL") or std.ascii.eqlIgnoreCase(value, "End of Life")) return .eol;
    if (std.ascii.eqlIgnoreCase(value, "Obsolete")) return .obsolete;
    return .unknown;
}

pub fn productStatusExcludedFromActiveGraph(status: types.ProductStatus) bool {
    return status == .obsolete;
}

pub fn productStatusExcludedFromGapAnalysis(status: types.ProductStatus) bool {
    return switch (status) {
        .superseded, .eol, .obsolete => true,
        else => false,
    };
}

pub fn productStatusForIdentifier(db: *graph_live.GraphDb, full_product_identifier: []const u8, alloc: Allocator) !types.ProductStatus {
    const product_id = try std.fmt.allocPrint(alloc, "product://{s}", .{full_product_identifier});
    defer alloc.free(product_id);

    var st = try db.db.prepare(
        \\SELECT json_extract(properties, '$.product_status')
        \\FROM nodes
        \\WHERE id=? AND type='Product'
        \\LIMIT 1
    );
    defer st.finalize();
    try st.bindText(1, product_id);
    if (!(try st.step())) return .active;
    return classifyProductStatus(if (st.columnIsNull(0)) null else st.columnText(0));
}

pub fn countBomItems(db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !usize {
    if (!std.mem.startsWith(u8, bom_id, "bom://")) return 0;
    const suffix = bom_id["bom://".len..];
    const prefix = try std.fmt.allocPrint(alloc, "bom-item://{s}/%", .{suffix});
    defer alloc.free(prefix);

    var st = try db.db.prepare(
        \\SELECT COUNT(*)
        \\FROM nodes
        \\WHERE type='BOMItem' AND id LIKE ?
    );
    defer st.finalize();
    try st.bindText(1, prefix);
    if (!(try st.step())) return 0;
    return @intCast(st.columnInt(0));
}

pub fn traceLinkCountsForItem(
    db: *graph_live.GraphDb,
    item_id: []const u8,
    properties_json: []const u8,
    alloc: Allocator,
) !types.TraceLinkCounts {
    const declared_requirement_ids = try trace_refs.parseStringArrayProperty(properties_json, "requirement_ids", alloc);
    defer util.freeStringSlice(declared_requirement_ids, alloc);
    const declared_test_ids = try trace_refs.parseStringArrayProperty(properties_json, "test_ids", alloc);
    defer util.freeStringSlice(declared_test_ids, alloc);

    var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_requirements, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

    var linked_tests: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_tests, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

    const unresolved_requirement_ids = try trace_refs.unresolvedTraceRefs(properties_json, "requirement_ids", linked_requirements.items, alloc);
    defer util.freeStringSlice(unresolved_requirement_ids, alloc);
    const unresolved_test_ids = try trace_refs.unresolvedTraceRefs(properties_json, "test_ids", linked_tests.items, alloc);
    defer util.freeStringSlice(unresolved_test_ids, alloc);

    return .{
        .declared_requirement_count = declared_requirement_ids.len,
        .declared_test_count = declared_test_ids.len,
        .linked_requirement_count = linked_requirements.items.len,
        .linked_test_count = linked_tests.items.len,
        .unresolved_requirement_count = unresolved_requirement_ids.len,
        .unresolved_test_count = unresolved_test_ids.len,
    };
}

pub fn countBomWarnings(db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !usize {
    if (!std.mem.startsWith(u8, bom_id, "bom://")) return 0;
    const suffix = bom_id["bom://".len..];
    const prefix = try std.fmt.allocPrint(alloc, "bom-item://{s}/%", .{suffix});
    defer alloc.free(prefix);

    var st = try db.db.prepare(
        \\SELECT id, properties
        \\FROM nodes
        \\WHERE type='BOMItem' AND id LIKE ?
    );
    defer st.finalize();
    try st.bindText(1, prefix);

    var warning_count: usize = 0;
    while (try st.step()) {
        const counts = try traceLinkCountsForItem(db, st.columnText(0), st.columnText(1), alloc);
        warning_count += counts.unresolved_requirement_count + counts.unresolved_test_count;
    }
    return warning_count;
}

pub fn designBomPrefixes(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    alloc: Allocator,
) ![]const []const u8 {
    var st = try db.db.prepare(
        \\SELECT json_extract(properties, '$.bom_type')
        \\FROM nodes
        \\WHERE type='DesignBOM'
        \\  AND json_extract(properties, '$.full_product_identifier')=?
        \\  AND json_extract(properties, '$.bom_name')=?
        \\ORDER BY json_extract(properties, '$.bom_type')
    );
    defer st.finalize();
    try st.bindText(1, full_product_identifier);
    try st.bindText(2, bom_name);

    var prefixes: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (prefixes.items) |item| alloc.free(item);
        prefixes.deinit(alloc);
    }
    while (try st.step()) {
        const bom_type_raw = st.columnText(0);
        const bom_type: types.BomType = if (std.mem.eql(u8, bom_type_raw, "software")) .software else .hardware;
        try prefixes.append(alloc, try ids.bomItemPrefix(full_product_identifier, bom_type, bom_name, alloc));
    }
    if (prefixes.items.len == 0) return error.NotFound;
    return prefixes.toOwnedSlice(alloc);
}
