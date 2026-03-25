const std = @import("std");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const util = @import("util.zig");
const trace_refs = @import("trace_refs.zig");
const query_metrics = @import("query_metrics.zig");
const query_tree = @import("query_tree.zig");

pub const Allocator = std.mem.Allocator;

pub fn getBomJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_type_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    if (!include_obsolete and query_metrics.productStatusExcludedFromActiveGraph(try query_metrics.productStatusForIdentifier(db, full_product_identifier, alloc))) {
        var hidden_buf: std.ArrayList(u8) = .empty;
        defer hidden_buf.deinit(alloc);
        try hidden_buf.appendSlice(alloc, "{\"full_product_identifier\":");
        try shared.appendJsonStr(&hidden_buf, full_product_identifier, alloc);
        try hidden_buf.appendSlice(alloc, ",\"boms\":[]}");
        return hidden_buf.toOwnedSlice(alloc);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"boms\":[");

    var first = true;
    var st = try db.db.prepare(
        \\SELECT
        \\  id,
        \\  json_extract(properties, '$.bom_name'),
        \\  json_extract(properties, '$.bom_type'),
        \\  json_extract(properties, '$.source_format')
        \\FROM nodes
        \\WHERE type='DesignBOM'
        \\  AND json_extract(properties, '$.full_product_identifier')=?
        \\  AND (? IS NULL OR json_extract(properties, '$.bom_type')=?)
        \\  AND (? IS NULL OR json_extract(properties, '$.bom_name')=?)
        \\ORDER BY json_extract(properties, '$.bom_type'), json_extract(properties, '$.bom_name')
    );
    defer st.finalize();
    try st.bindText(1, full_product_identifier);
    if (bom_type_filter) |value| {
        try st.bindText(2, value);
        try st.bindText(3, value);
    } else {
        try st.bindNull(2);
        try st.bindNull(3);
    }
    if (bom_name_filter) |value| {
        try st.bindText(4, value);
        try st.bindText(5, value);
    } else {
        try st.bindNull(4);
        try st.bindNull(5);
    }
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        const bom_id = st.columnText(0);
        try buf.appendSlice(alloc, "{\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"bom_type\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"source_format\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"tree\":");
        try query_tree.appendBomTreeJson(&buf, db, bom_id, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn listDesignBomsJson(
    db: *graph_live.GraphDb,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\  bom.id,
        \\  json_extract(bom.properties, '$.full_product_identifier'),
        \\  json_extract(bom.properties, '$.bom_name'),
        \\  json_extract(bom.properties, '$.bom_type'),
        \\  json_extract(bom.properties, '$.source_format'),
        \\  json_extract(bom.properties, '$.ingested_at'),
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes bom
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE bom.type='DesignBOM'
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.full_product_identifier')=?)
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.bom_name')=?)
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name'), json_extract(bom.properties, '$.bom_type')
    );
    defer st.finalize();
    if (full_product_identifier_filter) |value| {
        try st.bindText(1, value);
        try st.bindText(2, value);
    } else {
        try st.bindNull(1);
        try st.bindNull(2);
    }
    if (bom_name_filter) |value| {
        try st.bindText(3, value);
        try st.bindText(4, value);
    } else {
        try st.bindNull(3);
        try st.bindNull(4);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"design_boms\":[");
    var first = true;
    while (try st.step()) {
        const product_status = query_metrics.classifyProductStatus(if (st.columnIsNull(6)) null else st.columnText(6));
        if (!include_obsolete and query_metrics.productStatusExcludedFromActiveGraph(product_status)) continue;
        if (!first) try buf.append(alloc, ',');
        first = false;
        const bom_id = st.columnText(0);
        const item_count = try query_metrics.countBomItems(db, bom_id, alloc);
        const warning_count = try query_metrics.countBomWarnings(db, bom_id, alloc);
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, bom_id, alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"bom_type\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"source_format\":");
        try shared.appendJsonStr(&buf, st.columnText(4), alloc);
        try buf.appendSlice(alloc, ",\"ingested_at\":");
        try buf.appendSlice(alloc, if (st.columnIsNull(5)) "null" else st.columnText(5));
        try buf.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&buf, if (st.columnIsNull(6)) "" else st.columnText(6), alloc);
        try std.fmt.format(buf.writer(alloc), ",\"item_count\":{d},\"warning_count\":{d}}}", .{ item_count, warning_count });
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn findPartUsageJson(db: *graph_live.GraphDb, part: []const u8, include_obsolete: bool, alloc: Allocator) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\  child.id,
        \\  json_extract(child.properties, '$.revision'),
        \\  bom.id,
        \\  bom.properties,
        \\  parent.id,
        \\  parent.properties,
        \\  e.properties,
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes child
        \\JOIN edges e ON e.to_id = child.id AND e.label='CONTAINS'
        \\LEFT JOIN nodes parent ON parent.id = e.from_id
        \\JOIN nodes bom ON bom.id = CASE
        \\  WHEN e.from_id LIKE 'bom://%' THEN e.from_id
        \\  ELSE substr(e.from_id, 1, instr(substr(e.from_id, length('bom-item://') + 1), '/') + length('bom-item://') - 1)
        \\END
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE child.type='BOMItem'
        \\  AND json_extract(child.properties, '$.part')=?
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name'), parent.id, child.id
    );
    defer st.finalize();
    try st.bindText(1, part);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"part\":");
    try shared.appendJsonStr(&buf, part, alloc);
    try buf.appendSlice(alloc, ",\"usages\":[");
    var first = true;
    while (try st.step()) {
        const product_status = query_metrics.classifyProductStatus(if (st.columnIsNull(7)) null else st.columnText(7));
        if (!include_obsolete and query_metrics.productStatusExcludedFromActiveGraph(product_status)) continue;
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"item_id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"revision\":");
        try shared.appendJsonStrOpt(&buf, if (st.columnIsNull(1)) null else st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"design_bom_id\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"design_bom\":");
        try buf.appendSlice(alloc, st.columnText(3));
        try buf.appendSlice(alloc, ",\"parent_id\":");
        try shared.appendJsonStrOpt(&buf, if (st.columnIsNull(4)) null else st.columnText(4), alloc);
        try buf.appendSlice(alloc, ",\"parent_properties\":");
        try buf.appendSlice(alloc, if (st.columnIsNull(5)) "null" else st.columnText(5));
        try buf.appendSlice(alloc, ",\"edge_properties\":");
        try buf.appendSlice(alloc, if (st.columnIsNull(6)) "null" else st.columnText(6));
        try buf.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&buf, if (st.columnIsNull(7)) "" else st.columnText(7), alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn bomGapsJson(
    db: *graph_live.GraphDb,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_inactive: bool,
    alloc: Allocator,
) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\  child.id,
        \\  child.properties,
        \\  json_extract(bom.properties, '$.full_product_identifier'),
        \\  json_extract(bom.properties, '$.bom_name'),
        \\  json_extract(bom.properties, '$.bom_type'),
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes child
        \\JOIN nodes bom
        \\  ON child.id LIKE replace(bom.id, 'bom://', 'bom-item://') || '/%'
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE child.type='BOMItem'
        \\  AND bom.type='DesignBOM'
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.full_product_identifier')=?)
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.bom_name')=?)
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name'), child.id
    );
    defer st.finalize();
    if (full_product_identifier_filter) |value| {
        try st.bindText(1, value);
        try st.bindText(2, value);
    } else {
        try st.bindNull(1);
        try st.bindNull(2);
    }
    if (bom_name_filter) |value| {
        try st.bindText(3, value);
        try st.bindText(4, value);
    } else {
        try st.bindNull(3);
        try st.bindNull(4);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"gaps\":[");
    var first = true;
    while (try st.step()) {
        const product_status = query_metrics.classifyProductStatus(if (st.columnIsNull(5)) null else st.columnText(5));
        if (!include_inactive and query_metrics.productStatusExcludedFromGapAnalysis(product_status)) continue;
        const item_id = st.columnText(0);
        const props = st.columnText(1);
        const req_ids = try trace_refs.parseStringArrayProperty(props, "requirement_ids", alloc);
        defer util.freeStringSlice(req_ids, alloc);
        const test_ids = try trace_refs.parseStringArrayProperty(props, "test_ids", alloc);
        defer util.freeStringSlice(test_ids, alloc);

        var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
        defer shared.freeNodeList(&linked_requirements, alloc);
        try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

        var linked_tests: std.ArrayList(graph_live.Node) = .empty;
        defer shared.freeNodeList(&linked_tests, alloc);
        try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
        try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

        const unresolved_requirement_ids = try trace_refs.unresolvedTraceRefs(props, "requirement_ids", linked_requirements.items, alloc);
        defer util.freeStringSlice(unresolved_requirement_ids, alloc);
        const unresolved_test_ids = try trace_refs.unresolvedTraceRefs(props, "test_ids", linked_tests.items, alloc);
        defer util.freeStringSlice(unresolved_test_ids, alloc);

        const has_trace_gap = (req_ids.len > 0 and linked_requirements.items.len == 0) or
            (test_ids.len > 0 and linked_tests.items.len == 0) or
            unresolved_requirement_ids.len > 0 or
            unresolved_test_ids.len > 0;
        if (!has_trace_gap) continue;

        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"item_id\":");
        try shared.appendJsonStr(&buf, item_id, alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"bom_type\":");
        try shared.appendJsonStr(&buf, st.columnText(4), alloc);
        try buf.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&buf, if (st.columnIsNull(5)) "" else st.columnText(5), alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, props);
        try buf.appendSlice(alloc, ",\"linked_requirement_count\":");
        try std.fmt.format(buf.writer(alloc), "{d}", .{linked_requirements.items.len});
        try buf.appendSlice(alloc, ",\"linked_test_count\":");
        try std.fmt.format(buf.writer(alloc), "{d}", .{linked_tests.items.len});
        try buf.appendSlice(alloc, ",\"unresolved_requirement_ids\":");
        try util.appendJsonStringArray(&buf, unresolved_requirement_ids, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
        try util.appendJsonStringArray(&buf, unresolved_test_ids, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn bomImpactAnalysisJson(
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
            \\SELECT id, properties
            \\FROM nodes
            \\WHERE type='BOMItem' AND id LIKE ?
            \\ORDER BY id
        );
        defer st.finalize();
        const pattern = try std.fmt.allocPrint(alloc, "{s}%", .{prefix});
        defer alloc.free(pattern);
        try st.bindText(1, pattern);
        while (try st.step()) {
            if (!first) try buf.append(alloc, ',');
            first = false;
            const item_id = st.columnText(0);
            try buf.appendSlice(alloc, "{\"item_id\":");
            try shared.appendJsonStr(&buf, item_id, alloc);
            try buf.appendSlice(alloc, ",\"properties\":");
            try buf.appendSlice(alloc, st.columnText(1));

            var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
            defer shared.freeNodeList(&linked_requirements, alloc);
            try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);
            try buf.appendSlice(alloc, ",\"linked_requirements\":");
            try @import("json.zig").appendNodeJsonArray(&buf, linked_requirements.items, alloc);

            var linked_tests: std.ArrayList(graph_live.Node) = .empty;
            defer shared.freeNodeList(&linked_tests, alloc);
            try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
            try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);
            try buf.appendSlice(alloc, ",\"linked_tests\":");
            try @import("json.zig").appendNodeJsonArray(&buf, linked_tests.items, alloc);
            try buf.append(alloc, '}');
        }
    }

    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn getDesignBomComponentsJson(
    db: *graph_live.GraphDb,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\  child.id,
        \\  child.properties,
        \\  json_extract(bom.properties, '$.full_product_identifier'),
        \\  json_extract(bom.properties, '$.bom_name'),
        \\  json_extract(bom.properties, '$.bom_type'),
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes child
        \\JOIN nodes bom
        \\  ON child.id LIKE replace(bom.id, 'bom://', 'bom-item://') || '/%'
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE child.type='BOMItem'
        \\  AND bom.type='DesignBOM'
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.full_product_identifier')=?)
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.bom_name')=?)
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name'), child.id
    );
    defer st.finalize();
    if (full_product_identifier_filter) |value| {
        try st.bindText(1, value);
        try st.bindText(2, value);
    } else {
        try st.bindNull(1);
        try st.bindNull(2);
    }
    if (bom_name_filter) |value| {
        try st.bindText(3, value);
        try st.bindText(4, value);
    } else {
        try st.bindNull(3);
        try st.bindNull(4);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"components\":[");
    var first = true;
    while (try st.step()) {
        const product_status = query_metrics.classifyProductStatus(if (st.columnIsNull(5)) null else st.columnText(5));
        if (!include_obsolete and query_metrics.productStatusExcludedFromActiveGraph(product_status)) continue;

        const item_id = st.columnText(0);
        const properties_json = st.columnText(1);
        const counts = try query_metrics.traceLinkCountsForItem(db, item_id, properties_json, alloc);

        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"item_id\":");
        try shared.appendJsonStr(&buf, item_id, alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"bom_type\":");
        try shared.appendJsonStr(&buf, st.columnText(4), alloc);
        try buf.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&buf, if (st.columnIsNull(5)) "" else st.columnText(5), alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, properties_json);
        try std.fmt.format(
            buf.writer(alloc),
            ",\"declared_requirement_count\":{d},\"declared_test_count\":{d},\"linked_requirement_count\":{d},\"linked_test_count\":{d},\"unresolved_requirement_count\":{d},\"unresolved_test_count\":{d}}}",
            .{
                counts.declared_requirement_count,
                counts.declared_test_count,
                counts.linked_requirement_count,
                counts.linked_test_count,
                counts.unresolved_requirement_count,
                counts.unresolved_test_count,
            },
        );
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn getDesignBomCoverageJson(
    db: *graph_live.GraphDb,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\  bom.id,
        \\  json_extract(bom.properties, '$.full_product_identifier'),
        \\  json_extract(bom.properties, '$.bom_name'),
        \\  json_extract(bom.properties, '$.bom_type'),
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes bom
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE bom.type='DesignBOM'
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.full_product_identifier')=?)
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.bom_name')=?)
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name'), json_extract(bom.properties, '$.bom_type')
    );
    defer st.finalize();
    if (full_product_identifier_filter) |value| {
        try st.bindText(1, value);
        try st.bindText(2, value);
    } else {
        try st.bindNull(1);
        try st.bindNull(2);
    }
    if (bom_name_filter) |value| {
        try st.bindText(3, value);
        try st.bindText(4, value);
    } else {
        try st.bindNull(3);
        try st.bindNull(4);
    }

    var overall_total_items: usize = 0;
    var overall_requirement_covered: usize = 0;
    var overall_test_covered: usize = 0;
    var overall_fully_covered: usize = 0;
    var overall_no_trace: usize = 0;
    var overall_warning_count: usize = 0;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"design_boms\":[");
    var first = true;
    while (try st.step()) {
        const product_status = query_metrics.classifyProductStatus(if (st.columnIsNull(4)) null else st.columnText(4));
        if (!include_obsolete and query_metrics.productStatusExcludedFromActiveGraph(product_status)) continue;

        const bom_id = st.columnText(0);
        if (!std.mem.startsWith(u8, bom_id, "bom://")) continue;
        const suffix = bom_id["bom://".len..];
        const prefix = try std.fmt.allocPrint(alloc, "bom-item://{s}/%", .{suffix});
        defer alloc.free(prefix);

        var items_st = try db.db.prepare(
            \\SELECT id, properties
            \\FROM nodes
            \\WHERE type='BOMItem' AND id LIKE ?
            \\ORDER BY id
        );
        defer items_st.finalize();
        try items_st.bindText(1, prefix);

        var total_items: usize = 0;
        var requirement_covered: usize = 0;
        var test_covered: usize = 0;
        var fully_covered: usize = 0;
        var no_trace: usize = 0;
        var warning_count: usize = 0;

        while (try items_st.step()) {
            total_items += 1;
            const counts = try query_metrics.traceLinkCountsForItem(db, items_st.columnText(0), items_st.columnText(1), alloc);
            const has_requirement_coverage = counts.linked_requirement_count > 0;
            const has_test_coverage = counts.linked_test_count > 0;
            if (has_requirement_coverage) requirement_covered += 1;
            if (has_test_coverage) test_covered += 1;
            if (has_requirement_coverage and has_test_coverage) fully_covered += 1;
            if (counts.declared_requirement_count == 0 and counts.declared_test_count == 0 and !has_requirement_coverage and !has_test_coverage) {
                no_trace += 1;
            }
            warning_count += counts.unresolved_requirement_count + counts.unresolved_test_count;
        }

        overall_total_items += total_items;
        overall_requirement_covered += requirement_covered;
        overall_test_covered += test_covered;
        overall_fully_covered += fully_covered;
        overall_no_trace += no_trace;
        overall_warning_count += warning_count;

        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, bom_id, alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"bom_type\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&buf, if (st.columnIsNull(4)) "" else st.columnText(4), alloc);
        try std.fmt.format(
            buf.writer(alloc),
            ",\"item_count\":{d},\"requirement_covered_count\":{d},\"test_covered_count\":{d},\"fully_covered_count\":{d},\"no_trace_count\":{d},\"warning_count\":{d}}}",
            .{ total_items, requirement_covered, test_covered, fully_covered, no_trace, warning_count },
        );
    }
    try buf.appendSlice(alloc, "],\"summary\":{");
    try std.fmt.format(
        buf.writer(alloc),
        "\"item_count\":{d},\"requirement_covered_count\":{d},\"test_covered_count\":{d},\"fully_covered_count\":{d},\"no_trace_count\":{d},\"warning_count\":{d}}}",
        .{
            overall_total_items,
            overall_requirement_covered,
            overall_test_covered,
            overall_fully_covered,
            overall_no_trace,
            overall_warning_count,
        },
    );
    return alloc.dupe(u8, buf.items);
}

pub fn getProductSerialsJson(db: *graph_live.GraphDb, full_product_identifier: []const u8, alloc: Allocator) ![]const u8 {
    const product_id = try std.fmt.allocPrint(alloc, "product://{s}", .{full_product_identifier});
    defer alloc.free(product_id);

    var st = try db.db.prepare(
        \\SELECT
        \\  json_extract(exec.properties, '$.execution_id'),
        \\  json_extract(exec.properties, '$.executed_at'),
        \\  json_extract(exec.properties, '$.serial_number'),
        \\  json_extract(exec.properties, '$.computed_status')
        \\FROM edges fp
        \\JOIN nodes exec ON exec.id = fp.from_id AND exec.type='TestExecution'
        \\WHERE fp.label='FOR_PRODUCT'
        \\  AND fp.to_id=?
        \\  AND json_extract(exec.properties, '$.serial_number') IS NOT NULL
        \\ORDER BY json_extract(exec.properties, '$.executed_at') DESC, json_extract(exec.properties, '$.execution_id') DESC
    );
    defer st.finalize();
    try st.bindText(1, product_id);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"executions\":[");
    var first = true;
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"execution_id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"executed_at\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"serial_number\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"computed_status\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn getComponentsBySupplierJson(db: *graph_live.GraphDb, supplier: []const u8, alloc: Allocator) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\  child.id,
        \\  child.properties,
        \\  parent.id,
        \\  e.properties
        \\FROM edges e
        \\JOIN nodes child ON child.id = e.to_id AND child.type='BOMItem'
        \\LEFT JOIN nodes parent ON parent.id = e.from_id
        \\WHERE e.label='CONTAINS'
        \\  AND json_extract(e.properties, '$.supplier')=?
        \\ORDER BY child.id, parent.id
    );
    defer st.finalize();
    try st.bindText(1, supplier);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"supplier\":");
    try shared.appendJsonStr(&buf, supplier, alloc);
    try buf.appendSlice(alloc, ",\"components\":[");
    var first = true;
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, st.columnText(1));
        try buf.appendSlice(alloc, ",\"parent_id\":");
        try shared.appendJsonStrOpt(&buf, if (st.columnIsNull(2)) null else st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"edge_properties\":");
        try buf.appendSlice(alloc, if (st.columnIsNull(3)) "null" else st.columnText(3));
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn getSoftwareComponentsJson(db: *graph_live.GraphDb, purl_prefix: ?[]const u8, license_filter: ?[]const u8, alloc: Allocator) ![]const u8 {
    var st = try db.db.prepare(
        \\SELECT
        \\  id,
        \\  properties
        \\FROM nodes
        \\WHERE type='BOMItem'
        \\  AND id LIKE 'bom-item://%/software/%'
        \\  AND (? IS NULL OR json_extract(properties, '$.purl') LIKE ?)
        \\  AND (? IS NULL OR json_extract(properties, '$.license') = ?)
        \\ORDER BY id
    );
    defer st.finalize();
    var purl_pattern: ?[]u8 = null;
    defer if (purl_pattern) |value| alloc.free(value);
    if (purl_prefix) |value| {
        purl_pattern = try std.fmt.allocPrint(alloc, "{s}%", .{value});
        try st.bindText(1, value);
        try st.bindText(2, purl_pattern.?);
    } else {
        try st.bindNull(1);
        try st.bindNull(2);
    }
    if (license_filter) |value| {
        try st.bindText(3, value);
        try st.bindText(4, value);
    } else {
        try st.bindNull(3);
        try st.bindNull(4);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"components\":[");
    var first = true;
    while (try st.step()) {
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, st.columnText(1));
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}
