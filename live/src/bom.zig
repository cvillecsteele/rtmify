const std = @import("std");
const Allocator = std.mem.Allocator;

const db_mod = @import("db.zig");
const graph_live = @import("graph_live.zig");
const json_util = @import("json_util.zig");
const shared = @import("routes/shared.zig");

pub const BomType = enum { hardware, software };
pub const BomFormat = enum { hardware_csv, hardware_json, cyclonedx, spdx };

pub const BomOccurrenceInput = struct {
    parent_key: ?[]const u8,
    child_part: []const u8,
    child_revision: []const u8,
    description: ?[]const u8,
    category: ?[]const u8,
    quantity: ?[]const u8,
    ref_designator: ?[]const u8,
    supplier: ?[]const u8,
    purl: ?[]const u8,
    license: ?[]const u8,
    hashes_json: ?[]const u8,

    pub fn deinit(self: *BomOccurrenceInput, alloc: Allocator) void {
        if (self.parent_key) |value| alloc.free(value);
        alloc.free(self.child_part);
        alloc.free(self.child_revision);
        if (self.description) |value| alloc.free(value);
        if (self.category) |value| alloc.free(value);
        if (self.quantity) |value| alloc.free(value);
        if (self.ref_designator) |value| alloc.free(value);
        if (self.supplier) |value| alloc.free(value);
        if (self.purl) |value| alloc.free(value);
        if (self.license) |value| alloc.free(value);
        if (self.hashes_json) |value| alloc.free(value);
    }
};

pub const BomSubmission = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    bom_type: BomType,
    source_format: BomFormat,
    root_key: ?[]const u8,
    occurrences: []BomOccurrenceInput,

    pub fn deinit(self: *BomSubmission, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        if (self.root_key) |value| alloc.free(value);
        for (self.occurrences) |*occurrence| occurrence.deinit(alloc);
        alloc.free(self.occurrences);
    }
};

pub const BomWarning = struct {
    code: []const u8,
    message: []const u8,
    subject: ?[]const u8,

    pub fn deinit(self: *BomWarning, alloc: Allocator) void {
        alloc.free(self.code);
        alloc.free(self.message);
        if (self.subject) |value| alloc.free(value);
    }
};

pub const BomIngestResponse = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    bom_type: BomType,
    source_format: BomFormat,
    inserted_nodes: usize,
    inserted_edges: usize,
    warnings: []BomWarning,

    pub fn deinit(self: *BomIngestResponse, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        for (self.warnings) |*warning| warning.deinit(alloc);
        alloc.free(self.warnings);
    }
};

pub const BomError = error{
    UnsupportedContentType,
    UnsupportedFormat,
    InvalidJson,
    InvalidCsv,
    MissingBomName,
    MissingFullProductIdentifier,
    EmptyBomItems,
    MissingRequiredField,
    NoProductMatch,
    SbomUnresolvableRoot,
    CircularReference,
};

const PreparedBom = struct {
    submission: BomSubmission,
    warnings: std.ArrayList(BomWarning),

    fn deinit(self: *PreparedBom, alloc: Allocator) void {
        self.submission.deinit(alloc);
        for (self.warnings.items) |*warning| warning.deinit(alloc);
        self.warnings.deinit(alloc);
    }
};

const ItemSpec = struct {
    part: []const u8,
    revision: []const u8,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    purl: ?[]const u8 = null,
    license: ?[]const u8 = null,
    hashes_json: ?[]const u8 = null,
};

const RelationSpec = struct {
    parent_key: ?[]const u8,
    child_key: []const u8,
    quantity: ?[]const u8 = null,
    ref_designator: ?[]const u8 = null,
    supplier: ?[]const u8 = null,
};

pub fn ingestHttpBody(
    db: *graph_live.GraphDb,
    content_type: ?[]const u8,
    body: []const u8,
    alloc: Allocator,
) (BomError || db_mod.DbError || error{OutOfMemory})!BomIngestResponse {
    var prepared = try prepareHttpBody(content_type, body, alloc);
    defer prepared.deinit(alloc);
    return ingestPrepared(db, &prepared, alloc);
}

pub fn ingestInboxFile(
    db: *graph_live.GraphDb,
    name: []const u8,
    body: []const u8,
    alloc: Allocator,
) (BomError || db_mod.DbError || error{OutOfMemory})!BomIngestResponse {
    var prepared = try prepareInboxFile(name, body, alloc);
    defer prepared.deinit(alloc);
    return ingestPrepared(db, &prepared, alloc);
}

pub fn ingestResponseJson(response: BomIngestResponse, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, response.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, response.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"bom_type\":");
    try shared.appendJsonStr(&buf, bomTypeString(response.bom_type), alloc);
    try buf.appendSlice(alloc, ",\"source_format\":");
    try shared.appendJsonStr(&buf, bomFormatString(response.source_format), alloc);
    try std.fmt.format(buf.writer(alloc), ",\"inserted_nodes\":{d},\"inserted_edges\":{d},\"warnings\":[", .{
        response.inserted_nodes,
        response.inserted_edges,
    });
    for (response.warnings, 0..) |warning, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"code\":");
        try shared.appendJsonStr(&buf, warning.code, alloc);
        try buf.appendSlice(alloc, ",\"message\":");
        try shared.appendJsonStr(&buf, warning.message, alloc);
        try buf.appendSlice(alloc, ",\"subject\":");
        try shared.appendJsonStrOpt(&buf, warning.subject, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn getBomJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_type_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    alloc: Allocator,
) ![]const u8 {
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
        \\WHERE type='BOM'
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
        try appendBomTreeJson(&buf, db, bom_id, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

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
    try buf.append(alloc, '}');
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

fn ingestPrepared(
    db: *graph_live.GraphDb,
    prepared: *PreparedBom,
    alloc: Allocator,
) (BomError || db_mod.DbError || error{OutOfMemory})!BomIngestResponse {
    try validateNoCycles(prepared.submission.occurrences);

    const product_id = try std.fmt.allocPrint(alloc, "product://{s}", .{prepared.submission.full_product_identifier});
    defer alloc.free(product_id);
    const product_node = try db.getNode(product_id, alloc);
    defer if (product_node) |node| shared.freeNode(node, alloc);
    if (product_node == null) {
        return if (prepared.submission.bom_type == .hardware) error.NoProductMatch else error.SbomUnresolvableRoot;
    }

    const bom_id = try bomNodeId(prepared.submission.full_product_identifier, prepared.submission.bom_type, prepared.submission.bom_name, alloc);
    defer alloc.free(bom_id);
    const bom_item_prefix = try bomItemPrefix(prepared.submission.full_product_identifier, prepared.submission.bom_type, prepared.submission.bom_name, alloc);
    defer alloc.free(bom_item_prefix);

    var item_specs = std.StringHashMap(ItemSpec).init(alloc);
    defer deinitItemMap(&item_specs, alloc);
    for (prepared.submission.occurrences) |occurrence| {
        const child_key = try partRevisionKey(occurrence.child_part, occurrence.child_revision, alloc);
        defer alloc.free(child_key);
        try upsertItemSpec(&item_specs, child_key, occurrence, alloc);
    }

    try deleteExistingBom(db, bom_id, bom_item_prefix);

    const bom_props = try bomPropertiesJson(prepared.submission, alloc);
    defer alloc.free(bom_props);
    try db.addNode(bom_id, "BOM", bom_props, null);

    const has_bom_props = try alloc.dupe(u8, "{}");
    defer alloc.free(has_bom_props);
    try db.addEdgeWithProperties(product_id, bom_id, "HAS_BOM", has_bom_props);

    var item_it = item_specs.iterator();
    while (item_it.next()) |entry| {
        const item_id = try bomItemNodeId(
            prepared.submission.full_product_identifier,
            prepared.submission.bom_type,
            prepared.submission.bom_name,
            entry.value_ptr.part,
            entry.value_ptr.revision,
            alloc,
        );
        defer alloc.free(item_id);
        const props = try itemPropertiesJson(entry.value_ptr.*, alloc);
        defer alloc.free(props);
        try db.addNode(item_id, "BOMItem", props, null);
    }

    for (prepared.submission.occurrences) |occurrence| {
        const child_id = try bomItemNodeId(
            prepared.submission.full_product_identifier,
            prepared.submission.bom_type,
            prepared.submission.bom_name,
            occurrence.child_part,
            occurrence.child_revision,
            alloc,
        );
        defer alloc.free(child_id);
        const edge_props = try containsEdgePropertiesJson(occurrence, prepared.submission.source_format, alloc);
        defer alloc.free(edge_props);

        if (occurrence.parent_key) |parent_key| {
            const parent = try splitPartRevisionKey(parent_key, alloc);
            defer parent.deinit(alloc);
            const parent_id = try bomItemNodeId(
                prepared.submission.full_product_identifier,
                prepared.submission.bom_type,
                prepared.submission.bom_name,
                parent.part,
                parent.revision,
                alloc,
            );
            defer alloc.free(parent_id);
            try db.addEdgeWithProperties(parent_id, child_id, "CONTAINS", edge_props);
        } else {
            try db.addEdgeWithProperties(bom_id, child_id, "CONTAINS", edge_props);
        }
    }

    return .{
        .full_product_identifier = try alloc.dupe(u8, prepared.submission.full_product_identifier),
        .bom_name = try alloc.dupe(u8, prepared.submission.bom_name),
        .bom_type = prepared.submission.bom_type,
        .source_format = prepared.submission.source_format,
        .inserted_nodes = 1 + item_specs.count(),
        .inserted_edges = 1 + prepared.submission.occurrences.len,
        .warnings = try prepared.warnings.toOwnedSlice(alloc),
    };
}

fn prepareHttpBody(content_type: ?[]const u8, body: []const u8, alloc: Allocator) (BomError || error{OutOfMemory})!PreparedBom {
    if (content_type) |value| {
        if (std.mem.startsWith(u8, value, "text/csv")) return prepareHardwareCsv(body, alloc);
        if (std.mem.startsWith(u8, value, "application/json")) return prepareJsonBody(body, alloc);
    }
    return if (looksLikeJson(body)) prepareJsonBody(body, alloc) else if (looksLikeCsv(body)) prepareHardwareCsv(body, alloc) else error.UnsupportedContentType;
}

fn prepareInboxFile(name: []const u8, body: []const u8, alloc: Allocator) (BomError || error{OutOfMemory})!PreparedBom {
    if (std.mem.endsWith(u8, name, ".csv")) return prepareHardwareCsv(body, alloc);
    if (std.mem.endsWith(u8, name, ".json")) return prepareJsonBody(body, alloc);
    return error.UnsupportedFormat;
}

fn prepareJsonBody(body: []const u8, alloc: Allocator) (BomError || error{OutOfMemory})!PreparedBom {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    if (json_util.getObjectField(root, "bom_items") != null) return prepareHardwareJson(root, alloc);
    if (json_util.getString(root, "bomFormat")) |value| {
        if (std.mem.eql(u8, value, "CycloneDX")) return prepareCycloneDx(root, alloc);
    }
    if (json_util.getString(root, "spdxVersion") != null) return prepareSpdx(root, alloc);
    return error.UnsupportedFormat;
}

fn prepareHardwareCsv(body: []const u8, alloc: Allocator) (BomError || error{OutOfMemory})!PreparedBom {
    var warnings: std.ArrayList(BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| {
            for (row) |cell| alloc.free(cell);
            alloc.free(row);
        }
        rows.deinit(alloc);
    }

    var line_it = std.mem.splitScalar(u8, body, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.trim(u8, line, " ").len == 0) continue;
        try rows.append(alloc, try parseCsvLine(line, alloc));
    }
    if (rows.items.len < 2) return error.EmptyBomItems;

    const header = rows.items[0];
    const bom_name_col = resolveCol(header, "bom_name") orelse return error.MissingRequiredField;
    const full_identifier_col = resolveCol(header, "full_identifier") orelse return error.MissingRequiredField;
    const parent_part_col = resolveCol(header, "parent_part") orelse return error.MissingRequiredField;
    const parent_revision_col = resolveCol(header, "parent_revision") orelse return error.MissingRequiredField;
    const child_part_col = resolveCol(header, "child_part") orelse return error.MissingRequiredField;
    const child_revision_col = resolveCol(header, "child_revision") orelse return error.MissingRequiredField;
    const quantity_col = resolveCol(header, "quantity") orelse return error.MissingRequiredField;
    const ref_designator_col = resolveCol(header, "ref_designator");
    const description_col = resolveCol(header, "description");
    const supplier_col = resolveCol(header, "supplier");
    const category_col = resolveCol(header, "category");

    var relation_seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = relation_seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        relation_seen.deinit();
    }

    var item_seen = std.StringHashMap(ItemSpec).init(alloc);
    defer deinitItemMap(&item_seen, alloc);

    var relations: std.ArrayList(RelationSpec) = .empty;
    defer {
        for (relations.items) |relation| {
            if (relation.parent_key) |value| alloc.free(value);
            alloc.free(relation.child_key);
            if (relation.quantity) |value| alloc.free(value);
            if (relation.ref_designator) |value| alloc.free(value);
            if (relation.supplier) |value| alloc.free(value);
        }
        relations.deinit(alloc);
    }

    var bom_name_value: ?[]const u8 = null;
    errdefer if (bom_name_value) |value| alloc.free(value);
    var full_product_identifier_value: ?[]const u8 = null;
    errdefer if (full_product_identifier_value) |value| alloc.free(value);

    for (rows.items[1..]) |row| {
        const bom_name = try cellAt(row, bom_name_col, alloc);
        defer alloc.free(bom_name);
        const full_identifier = try cellAt(row, full_identifier_col, alloc);
        defer alloc.free(full_identifier);
        const parent_part = try cellAt(row, parent_part_col, alloc);
        defer alloc.free(parent_part);
        const parent_revision = try cellAt(row, parent_revision_col, alloc);
        defer alloc.free(parent_revision);
        const child_part = try cellAt(row, child_part_col, alloc);
        defer alloc.free(child_part);
        const child_revision = try cellAt(row, child_revision_col, alloc);
        defer alloc.free(child_revision);
        const quantity = try cellAt(row, quantity_col, alloc);
        defer alloc.free(quantity);
        if (bom_name.len == 0) return error.MissingBomName;
        if (full_identifier.len == 0) return error.MissingFullProductIdentifier;
        if (parent_part.len == 0 or parent_revision.len == 0 or child_part.len == 0 or child_revision.len == 0 or quantity.len == 0) {
            return error.MissingRequiredField;
        }

        if (bom_name_value == null) bom_name_value = try alloc.dupe(u8, bom_name) else if (!std.mem.eql(u8, bom_name_value.?, bom_name)) return error.InvalidCsv;
        if (full_product_identifier_value == null) full_product_identifier_value = try alloc.dupe(u8, full_identifier) else if (!std.mem.eql(u8, full_product_identifier_value.?, full_identifier)) return error.InvalidCsv;

        const parent_key = try partRevisionKey(parent_part, parent_revision, alloc);
        defer alloc.free(parent_key);
        const child_key = try partRevisionKey(child_part, child_revision, alloc);
        defer alloc.free(child_key);

        try ensureItemSpec(&item_seen, parent_key, parent_part, parent_revision, alloc);
        try upsertItemSpecExplicit(
            &item_seen,
            child_key,
            .{
                .part = try alloc.dupe(u8, child_part),
                .revision = try alloc.dupe(u8, child_revision),
                .description = try optionalCellAt(row, description_col, alloc),
                .category = try optionalCellAt(row, category_col, alloc),
                .purl = null,
                .license = null,
                .hashes_json = null,
            },
            alloc,
        );

        const relation_key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ parent_key, child_key });
        if (relation_seen.contains(relation_key)) {
            alloc.free(relation_key);
            try appendWarning(&warnings, "BOM_DUPLICATE_CHILD", "Duplicate child under same parent skipped", child_part, alloc);
            continue;
        }
        try relation_seen.put(relation_key, {});

        try relations.append(alloc, .{
            .parent_key = try alloc.dupe(u8, parent_key),
            .child_key = try alloc.dupe(u8, child_key),
            .quantity = try alloc.dupe(u8, quantity),
            .ref_designator = try optionalCellAt(row, ref_designator_col, alloc),
            .supplier = try optionalCellAt(row, supplier_col, alloc),
        });
    }

    const occurrences = try finalizeOccurrences(item_seen, relations.items, null, .hardware_csv, alloc);
    return .{
        .submission = .{
            .full_product_identifier = full_product_identifier_value.?,
            .bom_name = bom_name_value.?,
            .bom_type = .hardware,
            .source_format = .hardware_csv,
            .root_key = null,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}

fn prepareHardwareJson(root: std.json.Value, alloc: Allocator) (BomError || error{OutOfMemory})!PreparedBom {
    const bom_name = json_util.getString(root, "bom_name") orelse return error.MissingBomName;
    const full_identifier = json_util.getString(root, "full_product_identifier") orelse return error.MissingFullProductIdentifier;
    const items_value = json_util.getObjectField(root, "bom_items") orelse return error.EmptyBomItems;
    if (items_value != .array or items_value.array.items.len == 0) return error.EmptyBomItems;

    var warnings: std.ArrayList(BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var item_seen = std.StringHashMap(ItemSpec).init(alloc);
    defer deinitItemMap(&item_seen, alloc);
    var relation_seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = relation_seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        relation_seen.deinit();
    }
    var relations: std.ArrayList(RelationSpec) = .empty;
    defer {
        for (relations.items) |relation| {
            if (relation.parent_key) |value| alloc.free(value);
            alloc.free(relation.child_key);
            if (relation.quantity) |value| alloc.free(value);
            if (relation.ref_designator) |value| alloc.free(value);
            if (relation.supplier) |value| alloc.free(value);
        }
        relations.deinit(alloc);
    }

    for (items_value.array.items) |item| {
        if (item != .object) return error.InvalidJson;
        const parent_part = json_util.getString(item, "parent_part") orelse return error.MissingRequiredField;
        const parent_revision = json_util.getString(item, "parent_revision") orelse return error.MissingRequiredField;
        const child_part = json_util.getString(item, "child_part") orelse return error.MissingRequiredField;
        const child_revision = json_util.getString(item, "child_revision") orelse return error.MissingRequiredField;
        const quantity = json_util.getString(item, "quantity") orelse return error.MissingRequiredField;

        const parent_key = try partRevisionKey(parent_part, parent_revision, alloc);
        defer alloc.free(parent_key);
        const child_key = try partRevisionKey(child_part, child_revision, alloc);
        defer alloc.free(child_key);

        try ensureItemSpec(&item_seen, parent_key, parent_part, parent_revision, alloc);
        try upsertItemSpecExplicit(
            &item_seen,
            child_key,
            .{
                .part = try alloc.dupe(u8, child_part),
                .revision = try alloc.dupe(u8, child_revision),
                .description = if (json_util.getString(item, "description")) |value| try alloc.dupe(u8, value) else null,
                .category = if (json_util.getString(item, "category")) |value| try alloc.dupe(u8, value) else null,
                .purl = null,
                .license = null,
                .hashes_json = null,
            },
            alloc,
        );

        const relation_key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ parent_key, child_key });
        if (relation_seen.contains(relation_key)) {
            alloc.free(relation_key);
            try appendWarning(&warnings, "BOM_DUPLICATE_CHILD", "Duplicate child under same parent skipped", child_part, alloc);
            continue;
        }
        try relation_seen.put(relation_key, {});
        try relations.append(alloc, .{
            .parent_key = try alloc.dupe(u8, parent_key),
            .child_key = try alloc.dupe(u8, child_key),
            .quantity = try alloc.dupe(u8, quantity),
            .ref_designator = if (json_util.getString(item, "ref_designator")) |value| try alloc.dupe(u8, value) else null,
            .supplier = if (json_util.getString(item, "supplier")) |value| try alloc.dupe(u8, value) else null,
        });
    }

    const occurrences = try finalizeOccurrences(item_seen, relations.items, null, .hardware_json, alloc);
    return .{
        .submission = .{
            .full_product_identifier = try alloc.dupe(u8, full_identifier),
            .bom_name = try alloc.dupe(u8, bom_name),
            .bom_type = .hardware,
            .source_format = .hardware_json,
            .root_key = null,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}

fn prepareCycloneDx(root: std.json.Value, alloc: Allocator) (BomError || error{OutOfMemory})!PreparedBom {
    const bom_name = json_util.getString(root, "bom_name") orelse return error.MissingBomName;
    const metadata = json_util.getObjectField(root, "metadata") orelse return error.InvalidJson;
    const root_component = json_util.getObjectField(metadata, "component") orelse return error.InvalidJson;
    if (root_component != .object) return error.InvalidJson;
    const root_name = json_util.getString(root_component, "name") orelse return error.InvalidJson;
    const root_version = json_util.getString(root_component, "version") orelse return error.InvalidJson;
    const full_product_identifier = if (json_util.getString(root, "full_product_identifier")) |value|
        try alloc.dupe(u8, value)
    else
        try std.fmt.allocPrint(alloc, "{s} {s}", .{ root_name, root_version });
    errdefer alloc.free(full_product_identifier);

    var warnings: std.ArrayList(BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var item_seen = std.StringHashMap(ItemSpec).init(alloc);
    defer deinitItemMap(&item_seen, alloc);
    var ref_map = std.StringHashMap([]const u8).init(alloc);
    defer {
        var it = ref_map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        ref_map.deinit();
    }
    var relation_seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = relation_seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        relation_seen.deinit();
    }
    var relations: std.ArrayList(RelationSpec) = .empty;
    defer {
        for (relations.items) |relation| {
            if (relation.parent_key) |value| alloc.free(value);
            alloc.free(relation.child_key);
            if (relation.quantity) |value| alloc.free(value);
            if (relation.ref_designator) |value| alloc.free(value);
            if (relation.supplier) |value| alloc.free(value);
        }
        relations.deinit(alloc);
    }

    const root_key_owned = try partRevisionKey(root_name, root_version, alloc);
    errdefer alloc.free(root_key_owned);
    try upsertItemSpecExplicit(&item_seen, root_key_owned, try cycloneDxItemSpec(root_component, alloc), alloc);
    const root_ref = if (json_util.getString(root_component, "bom-ref")) |value| value else root_key_owned;
    try ref_map.put(try alloc.dupe(u8, root_ref), try alloc.dupe(u8, root_key_owned));

    if (json_util.getObjectField(root, "components")) |components| {
        if (components != .array) return error.InvalidJson;
        for (components.array.items) |component| {
            if (component != .object) return error.InvalidJson;
            const name = json_util.getString(component, "name") orelse return error.InvalidJson;
            const version = json_util.getString(component, "version") orelse "";
            const key = try partRevisionKey(name, version, alloc);
            defer alloc.free(key);
            try upsertItemSpecExplicit(&item_seen, key, try cycloneDxItemSpec(component, alloc), alloc);
            const ref_value = if (json_util.getString(component, "bom-ref")) |value| value else key;
            if (!ref_map.contains(ref_value)) {
                try ref_map.put(try alloc.dupe(u8, ref_value), try alloc.dupe(u8, key));
            }
        }
    }

    var saw_dependencies = false;
    if (json_util.getObjectField(root, "dependencies")) |deps| {
        if (deps != .array) return error.InvalidJson;
        for (deps.array.items) |dep| {
            if (dep != .object) return error.InvalidJson;
            const parent_ref = json_util.getString(dep, "ref") orelse continue;
            const parent_key = ref_map.get(parent_ref) orelse {
                try appendWarning(&warnings, "BOM_ORPHAN_CHILD", "Dependency parent was not found in this SBOM", parent_ref, alloc);
                continue;
            };
            const depends_on = json_util.getObjectField(dep, "dependsOn") orelse continue;
            if (depends_on != .array) return error.InvalidJson;
            for (depends_on.array.items) |child_ref_value| {
                if (child_ref_value != .string) return error.InvalidJson;
                const child_key = ref_map.get(child_ref_value.string) orelse {
                    try appendWarning(&warnings, "BOM_ORPHAN_CHILD", "Dependency child was not found in this SBOM", child_ref_value.string, alloc);
                    continue;
                };
                saw_dependencies = true;
                try appendRelation(&relation_seen, &relations, parent_key, child_key, alloc, &warnings, child_ref_value.string);
            }
        }
    }

    if (!saw_dependencies) {
        var item_it = item_seen.iterator();
        while (item_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, root_key_owned)) continue;
            try appendRelation(&relation_seen, &relations, root_key_owned, entry.key_ptr.*, alloc, &warnings, entry.value_ptr.part);
        }
    }

    const occurrences = try finalizeOccurrences(item_seen, relations.items, root_key_owned, .cyclonedx, alloc);
    return .{
        .submission = .{
            .full_product_identifier = full_product_identifier,
            .bom_name = try alloc.dupe(u8, bom_name),
            .bom_type = .software,
            .source_format = .cyclonedx,
            .root_key = root_key_owned,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}

fn prepareSpdx(root: std.json.Value, alloc: Allocator) (BomError || error{OutOfMemory})!PreparedBom {
    const bom_name = json_util.getString(root, "bom_name") orelse return error.MissingBomName;
    const packages = json_util.getObjectField(root, "packages") orelse return error.InvalidJson;
    if (packages != .array or packages.array.items.len == 0) return error.InvalidJson;

    var warnings: std.ArrayList(BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var item_seen = std.StringHashMap(ItemSpec).init(alloc);
    defer deinitItemMap(&item_seen, alloc);
    var ref_map = std.StringHashMap([]const u8).init(alloc);
    defer {
        var it = ref_map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        ref_map.deinit();
    }
    var relation_seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = relation_seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        relation_seen.deinit();
    }
    var relations: std.ArrayList(RelationSpec) = .empty;
    defer {
        for (relations.items) |relation| {
            if (relation.parent_key) |value| alloc.free(value);
            alloc.free(relation.child_key);
            if (relation.quantity) |value| alloc.free(value);
            if (relation.ref_designator) |value| alloc.free(value);
            if (relation.supplier) |value| alloc.free(value);
        }
        relations.deinit(alloc);
    }

    var root_key_owned: ?[]const u8 = null;
    errdefer if (root_key_owned) |value| alloc.free(value);

    for (packages.array.items, 0..) |pkg, idx| {
        if (pkg != .object) return error.InvalidJson;
        const name = json_util.getString(pkg, "name") orelse return error.InvalidJson;
        const version = json_util.getString(pkg, "versionInfo") orelse "";
        const key = try partRevisionKey(name, version, alloc);
        defer alloc.free(key);
        try upsertItemSpecExplicit(&item_seen, key, try spdxItemSpec(pkg, alloc), alloc);
        const ref_value = if (json_util.getString(pkg, "SPDXID")) |value| value else key;
        if (!ref_map.contains(ref_value)) {
            try ref_map.put(try alloc.dupe(u8, ref_value), try alloc.dupe(u8, key));
        }
        if (idx == 0) root_key_owned = try alloc.dupe(u8, key);
    }

    const full_product_identifier = if (json_util.getString(root, "full_product_identifier")) |value|
        try alloc.dupe(u8, value)
    else blk: {
        const root_pkg = packages.array.items[0];
        const root_name = json_util.getString(root_pkg, "name") orelse return error.InvalidJson;
        const root_version = json_util.getString(root_pkg, "versionInfo") orelse "";
        break :blk try std.fmt.allocPrint(alloc, "{s} {s}", .{ root_name, root_version });
    };
    errdefer alloc.free(full_product_identifier);

    var saw_rel = false;
    if (json_util.getObjectField(root, "relationships")) |relationships| {
        if (relationships != .array) return error.InvalidJson;
        for (relationships.array.items) |rel| {
            if (rel != .object) return error.InvalidJson;
            const rel_type = json_util.getString(rel, "relationshipType") orelse continue;
            if (!std.mem.eql(u8, rel_type, "DEPENDS_ON") and !std.mem.eql(u8, rel_type, "CONTAINS")) continue;
            const parent_ref = json_util.getString(rel, "spdxElementId") orelse continue;
            const child_ref = json_util.getString(rel, "relatedSpdxElement") orelse continue;
            const parent_key = ref_map.get(parent_ref) orelse {
                try appendWarning(&warnings, "BOM_ORPHAN_CHILD", "SPDX parent was not found in this BOM", parent_ref, alloc);
                continue;
            };
            const child_key = ref_map.get(child_ref) orelse {
                try appendWarning(&warnings, "BOM_ORPHAN_CHILD", "SPDX child was not found in this BOM", child_ref, alloc);
                continue;
            };
            saw_rel = true;
            try appendRelation(&relation_seen, &relations, parent_key, child_key, alloc, &warnings, child_ref);
        }
    }

    if (!saw_rel) {
        var item_it = item_seen.iterator();
        while (item_it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, root_key_owned.?)) continue;
            try appendRelation(&relation_seen, &relations, root_key_owned.?, entry.key_ptr.*, alloc, &warnings, entry.value_ptr.part);
        }
    }

    const occurrences = try finalizeOccurrences(item_seen, relations.items, root_key_owned.?, .spdx, alloc);
    return .{
        .submission = .{
            .full_product_identifier = full_product_identifier,
            .bom_name = try alloc.dupe(u8, bom_name),
            .bom_type = .software,
            .source_format = .spdx,
            .root_key = root_key_owned,
            .occurrences = occurrences,
        },
        .warnings = warnings,
    };
}

fn finalizeOccurrences(
    items: std.StringHashMap(ItemSpec),
    relations: []const RelationSpec,
    preferred_root_key: ?[]const u8,
    source_format: BomFormat,
    alloc: Allocator,
) ![]BomOccurrenceInput {
    var incoming = std.StringHashMap(void).init(alloc);
    defer {
        var it = incoming.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        incoming.deinit();
    }
    for (relations) |relation| {
        if (!incoming.contains(relation.child_key)) {
            try incoming.put(try alloc.dupe(u8, relation.child_key), {});
        }
    }

    var occurrences: std.ArrayList(BomOccurrenceInput) = .empty;
    errdefer {
        for (occurrences.items) |*occurrence| occurrence.deinit(alloc);
        occurrences.deinit(alloc);
    }

    var item_it = items.iterator();
    while (item_it.next()) |entry| {
        const is_preferred_root = preferred_root_key != null and std.mem.eql(u8, entry.key_ptr.*, preferred_root_key.?);
        if (is_preferred_root or (!incoming.contains(entry.key_ptr.*) and !is_preferred_root)) {
            try occurrences.append(alloc, try occurrenceFromItem(null, entry.value_ptr.*, alloc));
        }
    }

    for (relations) |relation| {
        const item = items.get(relation.child_key).?;
        var occurrence = try occurrenceFromItem(relation.parent_key, item, alloc);
        if (relation.quantity) |value| occurrence.quantity = try alloc.dupe(u8, value);
        if (relation.ref_designator) |value| occurrence.ref_designator = try alloc.dupe(u8, value);
        if (relation.supplier) |value| occurrence.supplier = try alloc.dupe(u8, value);
        _ = source_format;
        try occurrences.append(alloc, occurrence);
    }

    if (occurrences.items.len == 0) return error.EmptyBomItems;
    return occurrences.toOwnedSlice(alloc);
}

fn validateNoCycles(occurrences: []const BomOccurrenceInput) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var adjacency = std.StringHashMap(std.ArrayList([]const u8)).init(alloc);
    var state = std.StringHashMap(u8).init(alloc);

    for (occurrences) |occurrence| {
        const child_key = try partRevisionKey(occurrence.child_part, occurrence.child_revision, alloc);
        if (!state.contains(child_key)) try state.put(child_key, 0);
        if (occurrence.parent_key) |parent_key| {
            if (!state.contains(parent_key)) try state.put(try alloc.dupe(u8, parent_key), 0);
            const gop = try adjacency.getOrPut(try alloc.dupe(u8, parent_key));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, child_key);
        }
    }

    var it = state.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == 0) {
            try dfsCycle(entry.key_ptr.*, &adjacency, &state);
        }
    }
}

fn dfsCycle(
    key: []const u8,
    adjacency: *std.StringHashMap(std.ArrayList([]const u8)),
    state: *std.StringHashMap(u8),
) !void {
    state.getPtr(key).?.* = 1;
    if (adjacency.getPtr(key)) |children| {
        for (children.items) |child| {
            const child_state = state.get(child) orelse 0;
            if (child_state == 1) return error.CircularReference;
            if (child_state == 0) try dfsCycle(child, adjacency, state);
        }
    }
    state.getPtr(key).?.* = 2;
}

fn deleteExistingBom(db: *graph_live.GraphDb, bom_id: []const u8, bom_item_prefix: []const u8) !void {
    const like_pattern = try std.fmt.allocPrint(std.heap.page_allocator, "{s}%", .{bom_item_prefix});
    defer std.heap.page_allocator.free(like_pattern);

    db.db.write_mu.lock();
    defer db.db.write_mu.unlock();
    {
        var st = try db.db.prepare(
            \\DELETE FROM edges
            \\WHERE from_id=? OR to_id=? OR from_id LIKE ? OR to_id LIKE ?
        );
        defer st.finalize();
        try st.bindText(1, bom_id);
        try st.bindText(2, bom_id);
        try st.bindText(3, like_pattern);
        try st.bindText(4, like_pattern);
        _ = try st.step();
    }
    {
        var st = try db.db.prepare(
            \\DELETE FROM nodes
            \\WHERE id=? OR id LIKE ?
        );
        defer st.finalize();
        try st.bindText(1, bom_id);
        try st.bindText(2, like_pattern);
        _ = try st.step();
    }
}

fn appendBomTreeJson(buf: *std.ArrayList(u8), db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !void {
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

fn appendBomItemTreeJson(
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

fn appendParentChainsJson(
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
        if (std.mem.eql(u8, parent.?.type, "BOM")) {
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

fn chainToJson(chain: std.json.Value, edge: graph_live.Edge, parent: graph_live.Node, alloc: Allocator) ![]const u8 {
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

fn partRevisionKey(part: []const u8, revision: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}@{s}", .{ part, revision });
}

const PartRevision = struct {
    part: []const u8,
    revision: []const u8,

    fn deinit(self: PartRevision, alloc: Allocator) void {
        alloc.free(self.part);
        alloc.free(self.revision);
    }
};

fn splitPartRevisionKey(key: []const u8, alloc: Allocator) !PartRevision {
    const idx = std.mem.lastIndexOfScalar(u8, key, '@') orelse return .{
        .part = try alloc.dupe(u8, key),
        .revision = try alloc.dupe(u8, ""),
    };
    return .{
        .part = try alloc.dupe(u8, key[0..idx]),
        .revision = try alloc.dupe(u8, key[idx + 1 ..]),
    };
}

fn bomNodeId(full_product_identifier: []const u8, bom_type: BomType, bom_name: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "bom://{s}/{s}/{s}", .{ full_product_identifier, bomTypeString(bom_type), bom_name });
}

fn bomItemPrefix(full_product_identifier: []const u8, bom_type: BomType, bom_name: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "bom-item://{s}/{s}/{s}/", .{ full_product_identifier, bomTypeString(bom_type), bom_name });
}

fn bomItemNodeId(
    full_product_identifier: []const u8,
    bom_type: BomType,
    bom_name: []const u8,
    part: []const u8,
    revision: []const u8,
    alloc: Allocator,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "bom-item://{s}/{s}/{s}/{s}@{s}", .{
        full_product_identifier,
        bomTypeString(bom_type),
        bom_name,
        part,
        revision,
    });
}

fn bomPropertiesJson(submission: BomSubmission, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, submission.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, submission.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"bom_type\":");
    try shared.appendJsonStr(&buf, bomTypeString(submission.bom_type), alloc);
    try buf.appendSlice(alloc, ",\"source_format\":");
    try shared.appendJsonStr(&buf, bomFormatString(submission.source_format), alloc);
    try std.fmt.format(buf.writer(alloc), ",\"ingested_at\":{d}}}", .{std.time.timestamp()});
    return alloc.dupe(u8, buf.items);
}

fn itemPropertiesJson(item: ItemSpec, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"part\":");
    try shared.appendJsonStr(&buf, item.part, alloc);
    try buf.appendSlice(alloc, ",\"revision\":");
    try shared.appendJsonStr(&buf, item.revision, alloc);
    try buf.appendSlice(alloc, ",\"description\":");
    try shared.appendJsonStrOpt(&buf, item.description, alloc);
    try buf.appendSlice(alloc, ",\"category\":");
    try shared.appendJsonStrOpt(&buf, item.category, alloc);
    try buf.appendSlice(alloc, ",\"purl\":");
    try shared.appendJsonStrOpt(&buf, item.purl, alloc);
    try buf.appendSlice(alloc, ",\"license\":");
    try shared.appendJsonStrOpt(&buf, item.license, alloc);
    try buf.appendSlice(alloc, ",\"hashes\":");
    if (item.hashes_json) |value| try buf.appendSlice(alloc, value) else try buf.appendSlice(alloc, "null");
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn containsEdgePropertiesJson(occurrence: BomOccurrenceInput, source_format: BomFormat, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"quantity\":");
    try shared.appendJsonStrOpt(&buf, occurrence.quantity, alloc);
    try buf.appendSlice(alloc, ",\"ref_designator\":");
    try shared.appendJsonStrOpt(&buf, occurrence.ref_designator, alloc);
    try buf.appendSlice(alloc, ",\"supplier\":");
    try shared.appendJsonStrOpt(&buf, occurrence.supplier, alloc);
    try buf.appendSlice(alloc, ",\"relation_source\":");
    try shared.appendJsonStr(&buf, bomFormatString(source_format), alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn occurrenceFromItem(parent_key: ?[]const u8, item: ItemSpec, alloc: Allocator) !BomOccurrenceInput {
    return .{
        .parent_key = if (parent_key) |value| try alloc.dupe(u8, value) else null,
        .child_part = try alloc.dupe(u8, item.part),
        .child_revision = try alloc.dupe(u8, item.revision),
        .description = if (item.description) |value| try alloc.dupe(u8, value) else null,
        .category = if (item.category) |value| try alloc.dupe(u8, value) else null,
        .quantity = null,
        .ref_designator = null,
        .supplier = null,
        .purl = if (item.purl) |value| try alloc.dupe(u8, value) else null,
        .license = if (item.license) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = if (item.hashes_json) |value| try alloc.dupe(u8, value) else null,
    };
}

fn ensureItemSpec(items: *std.StringHashMap(ItemSpec), key: []const u8, part: []const u8, revision: []const u8, alloc: Allocator) !void {
    if (items.contains(key)) return;
    try items.put(try alloc.dupe(u8, key), .{
        .part = try alloc.dupe(u8, part),
        .revision = try alloc.dupe(u8, revision),
    });
}

fn upsertItemSpec(items: *std.StringHashMap(ItemSpec), key: []const u8, occurrence: BomOccurrenceInput, alloc: Allocator) !void {
    try upsertItemSpecExplicit(items, key, .{
        .part = try alloc.dupe(u8, occurrence.child_part),
        .revision = try alloc.dupe(u8, occurrence.child_revision),
        .description = if (occurrence.description) |value| try alloc.dupe(u8, value) else null,
        .category = if (occurrence.category) |value| try alloc.dupe(u8, value) else null,
        .purl = if (occurrence.purl) |value| try alloc.dupe(u8, value) else null,
        .license = if (occurrence.license) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = if (occurrence.hashes_json) |value| try alloc.dupe(u8, value) else null,
    }, alloc);
}

fn upsertItemSpecExplicit(items: *std.StringHashMap(ItemSpec), key: []const u8, incoming: ItemSpec, alloc: Allocator) !void {
    const gop = try items.getOrPut(try alloc.dupe(u8, key));
    if (!gop.found_existing) {
        gop.value_ptr.* = incoming;
        return;
    }
    alloc.free(incoming.part);
    alloc.free(incoming.revision);

    if (incoming.description) |value| {
        if (gop.value_ptr.description == null) {
            gop.value_ptr.description = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.category) |value| {
        if (gop.value_ptr.category == null) {
            gop.value_ptr.category = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.purl) |value| {
        if (gop.value_ptr.purl == null) {
            gop.value_ptr.purl = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.license) |value| {
        if (gop.value_ptr.license == null) {
            gop.value_ptr.license = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.hashes_json) |value| {
        if (gop.value_ptr.hashes_json == null) {
            gop.value_ptr.hashes_json = value;
        } else {
            alloc.free(value);
        }
    }
}

fn deinitItemMap(items: *std.StringHashMap(ItemSpec), alloc: Allocator) void {
    var it = items.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.part);
        alloc.free(entry.value_ptr.revision);
        if (entry.value_ptr.description) |value| alloc.free(value);
        if (entry.value_ptr.category) |value| alloc.free(value);
        if (entry.value_ptr.purl) |value| alloc.free(value);
        if (entry.value_ptr.license) |value| alloc.free(value);
        if (entry.value_ptr.hashes_json) |value| alloc.free(value);
    }
    items.deinit();
}

fn appendRelation(
    seen: *std.StringHashMap(void),
    relations: *std.ArrayList(RelationSpec),
    parent_key: []const u8,
    child_key: []const u8,
    alloc: Allocator,
    warnings: *std.ArrayList(BomWarning),
    subject: []const u8,
) !void {
    const relation_key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ parent_key, child_key });
    if (seen.contains(relation_key)) {
        alloc.free(relation_key);
        try appendWarning(warnings, "BOM_DUPLICATE_CHILD", "Duplicate child under same parent skipped", subject, alloc);
        return;
    }
    try seen.put(relation_key, {});
    try relations.append(alloc, .{
        .parent_key = try alloc.dupe(u8, parent_key),
        .child_key = try alloc.dupe(u8, child_key),
    });
}

fn cycloneDxItemSpec(component: std.json.Value, alloc: Allocator) !ItemSpec {
    const name = json_util.getString(component, "name") orelse return error.InvalidJson;
    const version = json_util.getString(component, "version") orelse "";
    return .{
        .part = try alloc.dupe(u8, name),
        .revision = try alloc.dupe(u8, version),
        .description = if (json_util.getString(component, "description")) |value| try alloc.dupe(u8, value) else try alloc.dupe(u8, name),
        .category = if (json_util.getString(component, "type")) |value| try alloc.dupe(u8, value) else null,
        .purl = if (json_util.getString(component, "purl")) |value| try alloc.dupe(u8, value) else null,
        .license = try cyclonedxLicense(component, alloc),
        .hashes_json = try hashesJson(component, "hashes", alloc),
    };
}

fn spdxItemSpec(pkg: std.json.Value, alloc: Allocator) !ItemSpec {
    const name = json_util.getString(pkg, "name") orelse return error.InvalidJson;
    const version = json_util.getString(pkg, "versionInfo") orelse "";
    return .{
        .part = try alloc.dupe(u8, name),
        .revision = try alloc.dupe(u8, version),
        .description = if (json_util.getString(pkg, "description")) |value| try alloc.dupe(u8, value) else try alloc.dupe(u8, name),
        .category = null,
        .purl = try spdxPurl(pkg, alloc),
        .license = if (json_util.getString(pkg, "licenseConcluded")) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = try hashesJson(pkg, "checksums", alloc),
    };
}

fn cyclonedxLicense(component: std.json.Value, alloc: Allocator) !?[]const u8 {
    const licenses = json_util.getObjectField(component, "licenses") orelse return null;
    if (licenses != .array or licenses.array.items.len == 0) return null;
    const first = licenses.array.items[0];
    if (first == .object) {
        if (json_util.getString(first, "expression")) |value| {
            const dup = try alloc.dupe(u8, value);
            return dup;
        }
        if (json_util.getObjectField(first, "license")) |license_obj| {
            if (json_util.getString(license_obj, "id")) |value| {
                const dup = try alloc.dupe(u8, value);
                return dup;
            }
            if (json_util.getString(license_obj, "name")) |value| {
                const dup = try alloc.dupe(u8, value);
                return dup;
            }
        }
    }
    return null;
}

fn spdxPurl(pkg: std.json.Value, alloc: Allocator) !?[]const u8 {
    const refs = json_util.getObjectField(pkg, "externalRefs") orelse return null;
    if (refs != .array) return null;
    for (refs.array.items) |ref| {
        if (ref != .object) continue;
        if (json_util.getString(ref, "referenceType")) |ref_type| {
            if (std.mem.eql(u8, ref_type, "purl")) {
                if (json_util.getString(ref, "referenceLocator")) |value| {
                    const dup = try alloc.dupe(u8, value);
                    return dup;
                }
            }
        }
        if (json_util.getString(ref, "referenceLocator")) |value| {
            if (std.mem.startsWith(u8, value, "pkg:")) {
                const dup = try alloc.dupe(u8, value);
                return dup;
            }
        }
    }
    return null;
}

fn hashesJson(value: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const u8 {
    const hashes = json_util.getObjectField(value, field_name) orelse return null;
    if (hashes != .array) return null;
    const dup = try std.json.Stringify.valueAlloc(alloc, hashes, .{});
    return dup;
}

fn parseCsvLine(line: []const u8, alloc: Allocator) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| alloc.free(field);
        fields.deinit(alloc);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);
    var i: usize = 0;
    var in_quotes = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') {
            if (in_quotes and i + 1 < line.len and line[i + 1] == '"') {
                try current.append(alloc, '"');
                i += 1;
            } else {
                in_quotes = !in_quotes;
            }
            continue;
        }
        if (c == ',' and !in_quotes) {
            try fields.append(alloc, try alloc.dupe(u8, std.mem.trim(u8, current.items, " ")));
            current.clearRetainingCapacity();
            continue;
        }
        try current.append(alloc, c);
    }
    if (in_quotes) return error.InvalidCsv;
    try fields.append(alloc, try alloc.dupe(u8, std.mem.trim(u8, current.items, " ")));
    return fields.toOwnedSlice(alloc);
}

fn resolveCol(header: []const []const u8, name: []const u8) ?usize {
    for (header, 0..) |field, idx| {
        if (std.ascii.eqlIgnoreCase(field, name)) return idx;
    }
    return null;
}

fn cellAt(row: []const []const u8, idx: usize, alloc: Allocator) ![]u8 {
    if (idx >= row.len) return alloc.dupe(u8, "");
    return alloc.dupe(u8, std.mem.trim(u8, row[idx], " "));
}

fn optionalCellAt(row: []const []const u8, idx: ?usize, alloc: Allocator) !?[]const u8 {
    if (idx == null or idx.? >= row.len) return null;
    const value = std.mem.trim(u8, row[idx.?], " ");
    if (value.len == 0) return null;
    const dup = try alloc.dupe(u8, value);
    return dup;
}

fn looksLikeJson(body: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, body, " \r\n\t");
    return trimmed.len > 0 and trimmed[0] == '{';
}

fn looksLikeCsv(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "bom_name") != null and std.mem.indexOfScalar(u8, body, ',') != null;
}

fn bomTypeString(value: BomType) []const u8 {
    return switch (value) {
        .hardware => "hardware",
        .software => "software",
    };
}

fn bomFormatString(value: BomFormat) []const u8 {
    return switch (value) {
        .hardware_csv => "hardware_csv",
        .hardware_json => "hardware_json",
        .cyclonedx => "cyclonedx",
        .spdx => "spdx",
    };
}

fn appendWarning(warnings: *std.ArrayList(BomWarning), code: []const u8, message: []const u8, subject: ?[]const u8, alloc: Allocator) !void {
    try warnings.append(alloc, .{
        .code = try alloc.dupe(u8, code),
        .message = try alloc.dupe(u8, message),
        .subject = if (subject) |value| try alloc.dupe(u8, value) else null,
    });
}

test "prepare hardware csv parses valid body with named bom" {
    const body =
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,ref_designator,description,supplier,category
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4,"C47,C48",10uF capacitor,Murata,component
    ;
    var prepared = try prepareHardwareCsv(body, testing.allocator);
    defer prepared.deinit(testing.allocator);
    try testing.expectEqualStrings("pcba", prepared.submission.bom_name);
    try testing.expectEqualStrings("ASM-1000-REV-C", prepared.submission.full_product_identifier);
    try testing.expect(prepared.submission.occurrences.len >= 2);
}

test "prepare hardware csv rejects mismatched bom name across rows" {
    const body =
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4
        \\firmware,ASM-1000-REV-C,ASM-1000,REV-C,R0402-1K,A,2
    ;
    try testing.expectError(error.InvalidCsv, prepareHardwareCsv(body, testing.allocator));
}

test "edge properties round trip through graph and node detail JSON" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("a", "BOM", "{}", null);
    try db.addNode("b", "BOMItem", "{\"part\":\"X\"}", null);
    try db.addEdgeWithProperties("a", "b", "CONTAINS", "{\"quantity\":\"4\"}");

    var edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges.items) |edge| shared.freeEdge(edge, testing.allocator);
        edges.deinit(testing.allocator);
    }
    try db.edgesFrom("a", testing.allocator, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("{\"quantity\":\"4\"}", edges.items[0].properties.?);

    const resp = try @import("routes/query.zig").handleNode(&db, "a", testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"properties\":{\"quantity\":\"4\"}") != null);
}

test "re-ingesting same bom key replaces only that bom subtree" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var hardware = try ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer hardware.deinit(testing.allocator);

    var software = try ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bomFormat": "CycloneDX",
        \\  "bom_name": "firmware",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "metadata": { "component": { "name": "fw", "version": "1.0.0", "bom-ref": "fw@1.0.0" } },
        \\  "components": [
        \\    { "name": "zlib", "version": "1.2.13", "bom-ref": "pkg:generic/zlib@1.2.13", "purl": "pkg:generic/zlib@1.2.13" }
        \\  ],
        \\  "dependencies": [
        \\    { "ref": "fw@1.0.0", "dependsOn": ["pkg:generic/zlib@1.2.13"] }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer software.deinit(testing.allocator);

    var replacement = try ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "R0402-1K",
        \\      "child_revision": "B",
        \\      "quantity": "2"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer replacement.deinit(testing.allocator);

    const bom_json = try getBomJson(&db, "ASM-1000-REV-C", null, null, testing.allocator);
    defer testing.allocator.free(bom_json);
    try testing.expect(std.mem.indexOf(u8, bom_json, "R0402-1K") != null);
    try testing.expect(std.mem.indexOf(u8, bom_json, "C0805-10UF") == null);
    try testing.expect(std.mem.indexOf(u8, bom_json, "\"bom_name\":\"firmware\"") != null);
}

test "software component query filters by purl prefix" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var software = try ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bomFormat": "CycloneDX",
        \\  "bom_name": "firmware",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "metadata": { "component": { "name": "fw", "version": "1.0.0", "bom-ref": "fw@1.0.0" } },
        \\  "components": [
        \\    {
        \\      "name": "zlib",
        \\      "version": "1.2.13",
        \\      "bom-ref": "pkg:generic/zlib@1.2.13",
        \\      "purl": "pkg:generic/zlib@1.2.13",
        \\      "licenses": [{ "license": { "id": "Zlib" } }]
        \\    }
        \\  ],
        \\  "dependencies": [
        \\    { "ref": "fw@1.0.0", "dependsOn": ["pkg:generic/zlib@1.2.13"] }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer software.deinit(testing.allocator);

    const components = try getSoftwareComponentsJson(&db, "pkg:generic/zlib", "Zlib", testing.allocator);
    defer testing.allocator.free(components);
    try testing.expect(std.mem.indexOf(u8, components, "pkg:generic/zlib@1.2.13") != null);
}

const testing = std.testing;
