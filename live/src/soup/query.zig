const std = @import("std");
const Allocator = std.mem.Allocator;

const bom = @import("../bom.zig");
const graph_live = @import("../graph_live.zig");
const json_mod = @import("json.zig");
const json_util = @import("../json_util.zig");
const item_specs = @import("item_specs.zig");
const shared = @import("../routes/shared.zig");
const trace_refs = @import("trace_refs.zig");
const util = @import("util.zig");

pub const SoupStatusBundle = struct {
    statuses: []const []const u8,
    unresolved_requirement_ids: []const []const u8,
    unresolved_test_ids: []const []const u8,
    linked_requirement_count: usize,
    linked_test_count: usize,
    declared_requirement_count: usize,
    declared_test_count: usize,

    pub fn deinit(self: *SoupStatusBundle, alloc: Allocator) void {
        item_specs.freeStringSlice(self.statuses, alloc);
        item_specs.freeStringSlice(self.unresolved_requirement_ids, alloc);
        item_specs.freeStringSlice(self.unresolved_test_ids, alloc);
    }
};

pub fn listSoftwareBomsJson(
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
        \\  json_extract(bom.properties, '$.source_format'),
        \\  json_extract(bom.properties, '$.ingested_at'),
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes bom
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE bom.type='DesignBOM'
        \\  AND json_extract(bom.properties, '$.bom_type')='software'
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.full_product_identifier')=?)
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.bom_name')=?)
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name')
    );
    defer st.finalize();
    util.bindOptionalFilter(&st, 1, full_product_identifier_filter);
    util.bindOptionalFilter(&st, 3, bom_name_filter);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"software_boms\":[");
    var first = true;
    while (try st.step()) {
        const product_status = util.classifyProductStatus(if (st.columnIsNull(5)) null else st.columnText(5));
        if (!include_obsolete and product_status == .obsolete) continue;
        if (!first) try buf.append(alloc, ',');
        first = false;
        const bom_id = st.columnText(0);
        const item_count = try countBomItems(db, bom_id, alloc);
        const warning_count = try countSoupWarningsForBom(db, bom_id, alloc);
        try buf.appendSlice(alloc, "{\"id\":");
        try shared.appendJsonStr(&buf, bom_id, alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, st.columnText(1), alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"source_format\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"ingested_at\":");
        try buf.appendSlice(alloc, if (st.columnIsNull(4)) "null" else st.columnText(4));
        try buf.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&buf, if (st.columnIsNull(5)) "" else st.columnText(5), alloc);
        try std.fmt.format(buf.writer(alloc), ",\"item_count\":{d},\"warning_count\":{d}}}", .{ item_count, warning_count });
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn getSoupComponentsJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const product_status = try productStatusForIdentifier(db, full_product_identifier, alloc);
    if (!include_obsolete and product_status == .obsolete) return error.NotFound;

    const prefix = try softwareBomItemPrefix(full_product_identifier, bom_name, alloc);
    defer alloc.free(prefix);
    if (!(try designBomExists(db, full_product_identifier, bom_name))) return error.NotFound;

    var st = try db.db.prepare(
        \\SELECT id, properties
        \\FROM nodes
        \\WHERE type='BOMItem' AND id LIKE ?
        \\ORDER BY json_extract(properties, '$.part'), json_extract(properties, '$.revision')
    );
    defer st.finalize();
    const pattern = try std.fmt.allocPrint(alloc, "{s}%", .{prefix});
    defer alloc.free(pattern);
    try st.bindText(1, pattern);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, bom_name, alloc);
    try buf.appendSlice(alloc, ",\"components\":[");
    var first = true;
    while (try st.step()) {
        const item_id = st.columnText(0);
        const properties_json = st.columnText(1);
        var status_bundle = try buildSoupStatusBundle(db, item_id, properties_json, alloc);
        defer status_bundle.deinit(alloc);
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"item_id\":");
        try shared.appendJsonStr(&buf, item_id, alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, properties_json);
        try std.fmt.format(
            buf.writer(alloc),
            ",\"declared_requirement_count\":{d},\"declared_test_count\":{d},\"linked_requirement_count\":{d},\"linked_test_count\":{d},\"statuses\":",
            .{
                status_bundle.declared_requirement_count,
                status_bundle.declared_test_count,
                status_bundle.linked_requirement_count,
                status_bundle.linked_test_count,
            },
        );
        try json_mod.appendJsonStringArray(&buf, status_bundle.statuses, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_requirement_ids\":");
        try json_mod.appendJsonStringArray(&buf, status_bundle.unresolved_requirement_ids, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
        try json_mod.appendJsonStringArray(&buf, status_bundle.unresolved_test_ids, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn soupGapsJson(
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
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes child
        \\JOIN nodes bom
        \\  ON child.id LIKE replace(bom.id, 'bom://', 'bom-item://') || '/%'
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE child.type='BOMItem'
        \\  AND bom.type='DesignBOM'
        \\  AND json_extract(bom.properties, '$.bom_type')='software'
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.full_product_identifier')=?)
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.bom_name')=?)
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name'), child.id
    );
    defer st.finalize();
    util.bindOptionalFilter(&st, 1, full_product_identifier_filter);
    util.bindOptionalFilter(&st, 3, bom_name_filter);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"gaps\":[");
    var first = true;
    while (try st.step()) {
        const product_status = util.classifyProductStatus(if (st.columnIsNull(4)) null else st.columnText(4));
        if (!include_inactive and util.productStatusExcludedFromGapAnalysis(product_status)) continue;

        const item_id = st.columnText(0);
        const properties_json = st.columnText(1);
        var status_bundle = try buildSoupStatusBundle(db, item_id, properties_json, alloc);
        defer status_bundle.deinit(alloc);
        if (status_bundle.statuses.len == 1 and std.mem.eql(u8, status_bundle.statuses[0], "SOUP_OK")) continue;
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"item_id\":");
        try shared.appendJsonStr(&buf, item_id, alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&buf, if (st.columnIsNull(4)) "" else st.columnText(4), alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, properties_json);
        try buf.appendSlice(alloc, ",\"statuses\":");
        try json_mod.appendJsonStringArray(&buf, status_bundle.statuses, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_requirement_ids\":");
        try json_mod.appendJsonStringArray(&buf, status_bundle.unresolved_requirement_ids, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
        try json_mod.appendJsonStringArray(&buf, status_bundle.unresolved_test_ids, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn soupLicensesJson(
    db: *graph_live.GraphDb,
    full_product_identifier_filter: ?[]const u8,
    license_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    return filteredSoftwareComponentsJson(db, full_product_identifier_filter, include_obsolete, .license, license_filter, alloc);
}

pub fn soupSafetyClassesJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    safety_class_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    return filteredSoftwareComponentsJson(db, full_product_identifier, include_obsolete, .safety_class, safety_class_filter, alloc);
}

fn buildSoupStatusBundle(
    db: *graph_live.GraphDb,
    item_id: []const u8,
    properties_json: []const u8,
    alloc: Allocator,
) !SoupStatusBundle {
    const declared_requirement_ids = try trace_refs.parseStringArrayProperty(properties_json, "requirement_ids", alloc);
    errdefer item_specs.freeStringSlice(declared_requirement_ids, alloc);
    const declared_test_ids = try trace_refs.parseStringArrayProperty(properties_json, "test_ids", alloc);
    errdefer item_specs.freeStringSlice(declared_test_ids, alloc);

    var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_requirements, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

    var linked_tests: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_tests, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

    const unresolved_requirement_ids = try trace_refs.unresolvedTraceRefs(declared_requirement_ids, linked_requirements.items, alloc);
    errdefer item_specs.freeStringSlice(unresolved_requirement_ids, alloc);
    const unresolved_test_ids = try trace_refs.unresolvedTraceRefs(declared_test_ids, linked_tests.items, alloc);
    errdefer item_specs.freeStringSlice(unresolved_test_ids, alloc);

    const version = trace_refs.extractJsonField(properties_json, "revision") orelse "";
    const known_anomalies = trace_refs.extractJsonField(properties_json, "known_anomalies") orelse "";
    const anomaly_evaluation = trace_refs.extractJsonField(properties_json, "anomaly_evaluation") orelse "";

    var statuses: std.ArrayList([]const u8) = .empty;
    errdefer item_specs.freeStringSlice(statuses.items, alloc);
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, version, " \r\n\t"), "unknown")) {
        try statuses.append(alloc, try alloc.dupe(u8, "SOUP_VERSION_UNKNOWN"));
    }
    if (std.mem.trim(u8, known_anomalies, " \r\n\t").len == 0 and std.mem.trim(u8, anomaly_evaluation, " \r\n\t").len == 0) {
        try statuses.append(alloc, try alloc.dupe(u8, "SOUP_NO_ANOMALIES_DOCUMENTED"));
    } else if (std.mem.trim(u8, known_anomalies, " \r\n\t").len > 0 and std.mem.trim(u8, anomaly_evaluation, " \r\n\t").len == 0) {
        try statuses.append(alloc, try alloc.dupe(u8, "SOUP_NO_ANOMALY_EVALUATION"));
    }
    if (declared_requirement_ids.len == 0) try statuses.append(alloc, try alloc.dupe(u8, "SOUP_NO_REQUIREMENT_LINKAGE"));
    if (declared_test_ids.len == 0) try statuses.append(alloc, try alloc.dupe(u8, "SOUP_NO_TEST_LINKAGE"));
    if (unresolved_requirement_ids.len > 0) try statuses.append(alloc, try alloc.dupe(u8, "SOUP_UNRESOLVED_REQUIREMENT_REF"));
    if (unresolved_test_ids.len > 0) try statuses.append(alloc, try alloc.dupe(u8, "SOUP_UNRESOLVED_TEST_REF"));
    if (statuses.items.len == 0) try statuses.append(alloc, try alloc.dupe(u8, "SOUP_OK"));

    const declared_requirement_count = declared_requirement_ids.len;
    const declared_test_count = declared_test_ids.len;
    item_specs.freeStringSlice(declared_requirement_ids, alloc);
    item_specs.freeStringSlice(declared_test_ids, alloc);
    return .{
        .statuses = try statuses.toOwnedSlice(alloc),
        .unresolved_requirement_ids = unresolved_requirement_ids,
        .unresolved_test_ids = unresolved_test_ids,
        .linked_requirement_count = linked_requirements.items.len,
        .linked_test_count = linked_tests.items.len,
        .declared_requirement_count = declared_requirement_count,
        .declared_test_count = declared_test_count,
    };
}

fn filteredSoftwareComponentsJson(
    db: *graph_live.GraphDb,
    full_product_identifier_filter: ?[]const u8,
    include_obsolete: bool,
    comptime field_name: enum { license, safety_class },
    field_filter: ?[]const u8,
    alloc: Allocator,
) ![]const u8 {
    const json_field = switch (field_name) {
        .license => "license",
        .safety_class => "safety_class",
    };
    var st = try db.db.prepare(
        \\SELECT
        \\  child.id,
        \\  child.properties,
        \\  json_extract(bom.properties, '$.full_product_identifier'),
        \\  json_extract(bom.properties, '$.bom_name'),
        \\  json_extract(product.properties, '$.product_status')
        \\FROM nodes child
        \\JOIN nodes bom
        \\  ON child.id LIKE replace(bom.id, 'bom://', 'bom-item://') || '/%'
        \\LEFT JOIN nodes product
        \\  ON product.type='Product'
        \\  AND product.id='product://' || json_extract(bom.properties, '$.full_product_identifier')
        \\WHERE child.type='BOMItem'
        \\  AND bom.type='DesignBOM'
        \\  AND json_extract(bom.properties, '$.bom_type')='software'
        \\  AND (? IS NULL OR json_extract(bom.properties, '$.full_product_identifier')=?)
        \\ORDER BY json_extract(bom.properties, '$.full_product_identifier'), json_extract(bom.properties, '$.bom_name'), child.id
    );
    defer st.finalize();
    util.bindOptionalFilter(&st, 1, full_product_identifier_filter);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"components\":[");
    var first = true;
    while (try st.step()) {
        const product_status = util.classifyProductStatus(if (st.columnIsNull(4)) null else st.columnText(4));
        if (!include_obsolete and product_status == .obsolete) continue;
        const properties_json = st.columnText(1);
        const field_value = trace_refs.extractJsonField(properties_json, json_field) orelse "";
        if (field_filter) |needle| {
            if (needle.len > 0 and std.mem.indexOf(u8, field_value, needle) == null) continue;
        }
        if (!first) try buf.append(alloc, ',');
        first = false;
        try buf.appendSlice(alloc, "{\"item_id\":");
        try shared.appendJsonStr(&buf, st.columnText(0), alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, st.columnText(2), alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, st.columnText(3), alloc);
        try buf.appendSlice(alloc, ",\"properties\":");
        try buf.appendSlice(alloc, properties_json);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

fn designBomExists(db: *graph_live.GraphDb, full_product_identifier: []const u8, bom_name: []const u8) !bool {
    var st = try db.db.prepare(
        \\SELECT 1
        \\FROM nodes
        \\WHERE type='DesignBOM'
        \\  AND json_extract(properties, '$.bom_type')='software'
        \\  AND json_extract(properties, '$.full_product_identifier')=?
        \\  AND json_extract(properties, '$.bom_name')=?
        \\LIMIT 1
    );
    defer st.finalize();
    try st.bindText(1, full_product_identifier);
    try st.bindText(2, bom_name);
    return try st.step();
}

fn softwareBomItemPrefix(full_product_identifier: []const u8, bom_name: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "bom-item://{s}/software/{s}/", .{ full_product_identifier, bom_name });
}

fn countBomItems(db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !usize {
    if (!std.mem.startsWith(u8, bom_id, "bom://")) return 0;
    const suffix = bom_id["bom://".len..];
    const prefix = try std.fmt.allocPrint(alloc, "bom-item://{s}/%", .{suffix});
    defer alloc.free(prefix);
    var st = try db.db.prepare("SELECT COUNT(*) FROM nodes WHERE type='BOMItem' AND id LIKE ?");
    defer st.finalize();
    try st.bindText(1, prefix);
    if (!(try st.step())) return 0;
    return @intCast(st.columnInt(0));
}

fn countSoupWarningsForBom(db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !usize {
    if (!std.mem.startsWith(u8, bom_id, "bom://")) return 0;
    const suffix = bom_id["bom://".len..];
    const prefix = try std.fmt.allocPrint(alloc, "bom-item://{s}/%", .{suffix});
    defer alloc.free(prefix);

    var st = try db.db.prepare("SELECT id, properties FROM nodes WHERE type='BOMItem' AND id LIKE ?");
    defer st.finalize();
    try st.bindText(1, prefix);
    var count: usize = 0;
    while (try st.step()) {
        var bundle = try buildSoupStatusBundle(db, st.columnText(0), st.columnText(1), alloc);
        defer bundle.deinit(alloc);
        for (bundle.statuses) |status| {
            if (!std.mem.eql(u8, status, "SOUP_OK")) count += 1;
        }
    }
    return count;
}

fn productStatusForIdentifier(db: *graph_live.GraphDb, full_product_identifier: []const u8, alloc: Allocator) !@TypeOf(util.classifyProductStatus(null)) {
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
    return util.classifyProductStatus(if (st.columnIsNull(0)) null else st.columnText(0));
}
