const std = @import("std");
const Allocator = std.mem.Allocator;

const db_mod = @import("db.zig");
const bom = @import("bom.zig");
const graph_live = @import("graph_live.zig");
const json_util = @import("json_util.zig");
const shared = @import("routes/shared.zig");
const xlsx = @import("rtmify").xlsx;

pub const default_bom_name = "SOUP Components";

pub const SoupRowError = struct {
    row: usize,
    code: []const u8,
    message: []const u8,

    pub fn deinit(self: *SoupRowError, alloc: Allocator) void {
        alloc.free(self.code);
        alloc.free(self.message);
    }
};

pub const SoupIngestResponse = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    source_format: bom.BomFormat,
    rows_received: usize,
    rows_ingested: usize,
    inserted_nodes: usize,
    inserted_edges: usize,
    row_errors: []SoupRowError,
    warnings: []bom.BomWarning,

    pub fn deinit(self: *SoupIngestResponse, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        for (self.row_errors) |*row_error| row_error.deinit(alloc);
        alloc.free(self.row_errors);
        for (self.warnings) |*warning| warning.deinit(alloc);
        alloc.free(self.warnings);
    }
};

const SoupStatusBundle = struct {
    statuses: []const []const u8,
    unresolved_requirement_ids: []const []const u8,
    unresolved_test_ids: []const []const u8,
    linked_requirement_count: usize,
    linked_test_count: usize,
    declared_requirement_count: usize,
    declared_test_count: usize,

    fn deinit(self: *SoupStatusBundle, alloc: Allocator) void {
        freeStringSlice(self.statuses, alloc);
        freeStringSlice(self.unresolved_requirement_ids, alloc);
        freeStringSlice(self.unresolved_test_ids, alloc);
    }
};

const SoupItemSpec = struct {
    component_name: []const u8,
    version: []const u8,
    supplier: ?[]const u8 = null,
    category: ?[]const u8 = null,
    license: ?[]const u8 = null,
    purl: ?[]const u8 = null,
    safety_class: ?[]const u8 = null,
    known_anomalies: ?[]const u8 = null,
    anomaly_evaluation: ?[]const u8 = null,
    requirement_ids: ?[]const []const u8 = null,
    test_ids: ?[]const []const u8 = null,

    fn deinit(self: *SoupItemSpec, alloc: Allocator) void {
        alloc.free(self.component_name);
        alloc.free(self.version);
        if (self.supplier) |value| alloc.free(value);
        if (self.category) |value| alloc.free(value);
        if (self.license) |value| alloc.free(value);
        if (self.purl) |value| alloc.free(value);
        if (self.safety_class) |value| alloc.free(value);
        if (self.known_anomalies) |value| alloc.free(value);
        if (self.anomaly_evaluation) |value| alloc.free(value);
        if (self.requirement_ids) |values| freeStringSlice(values, alloc);
        if (self.test_ids) |values| freeStringSlice(values, alloc);
    }
};

const ParseResult = struct {
    submission: bom.BomSubmission,
    warnings: std.ArrayList(bom.BomWarning),
    row_errors: std.ArrayList(SoupRowError),
    rows_received: usize,
    rows_ingested: usize,

    fn deinit(self: *ParseResult, alloc: Allocator) void {
        self.submission.deinit(alloc);
        for (self.warnings.items) |*warning| warning.deinit(alloc);
        self.warnings.deinit(alloc);
        for (self.row_errors.items) |*row_error| row_error.deinit(alloc);
        self.row_errors.deinit(alloc);
    }
};

pub fn ingestJsonBody(
    db: *graph_live.GraphDb,
    body: []const u8,
    alloc: Allocator,
) (bom.BomError || db_mod.DbError || error{ OutOfMemory, MissingSoupTab, InvalidXlsx })!SoupIngestResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    var prepared = try parseSoupJson(parsed.value, alloc);
    errdefer prepared.deinit(alloc);
    return ingestPreparedSoup(db, &prepared, .soup_json, alloc);
}

pub fn ingestXlsxBody(
    db: *graph_live.GraphDb,
    body: []const u8,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    alloc: Allocator,
) anyerror!SoupIngestResponse {
    const temp_path = try writeTempXlsx(body, alloc);
    defer {
        std.fs.deleteFileAbsolute(temp_path) catch {};
        alloc.free(temp_path);
    }
    return ingestXlsxPath(db, temp_path, full_product_identifier, bom_name_override, alloc);
}

pub fn ingestXlsxPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    alloc: Allocator,
) anyerror!SoupIngestResponse {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sheets = try xlsx.parse(arena_state.allocator(), path);
    const rows = findSheetRowsTrimmed(sheets, "SOUP Components") orelse return error.MissingSoupTab;

    var prepared = try parseSoupRows(rows, full_product_identifier, bom_name_override, .soup_xlsx, alloc);
    errdefer prepared.deinit(alloc);
    return ingestPreparedSoup(db, &prepared, .soup_xlsx, alloc);
}

pub fn ingestXlsxInboxPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    full_product_identifier: []const u8,
    alloc: Allocator,
) anyerror!SoupIngestResponse {
    return ingestXlsxPath(db, path, full_product_identifier, null, alloc);
}

pub fn ingestSheetRows(
    db: *graph_live.GraphDb,
    rows: []const []const []const u8,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    alloc: Allocator,
) !SoupIngestResponse {
    var prepared = try parseSoupRows(rows, full_product_identifier, bom_name_override, .sheets, alloc);
    errdefer prepared.deinit(alloc);
    return ingestPreparedSoup(db, &prepared, .sheets, alloc);
}

pub fn ingestResponseJson(response: SoupIngestResponse, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, response.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, response.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"source_format\":");
    try shared.appendJsonStr(&buf, bomFormatString(response.source_format), alloc);
    try std.fmt.format(
        buf.writer(alloc),
        ",\"rows_received\":{d},\"rows_ingested\":{d},\"inserted_nodes\":{d},\"inserted_edges\":{d},\"row_errors\":[",
        .{ response.rows_received, response.rows_ingested, response.inserted_nodes, response.inserted_edges },
    );
    for (response.row_errors, 0..) |row_error, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try std.fmt.format(buf.writer(alloc), "{{\"row\":{d},\"code\":", .{row_error.row});
        try shared.appendJsonStr(&buf, row_error.code, alloc);
        try buf.appendSlice(alloc, ",\"message\":");
        try shared.appendJsonStr(&buf, row_error.message, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "],\"warnings\":[");
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
    bindOptionalFilter(&st, 1, full_product_identifier_filter);
    bindOptionalFilter(&st, 3, bom_name_filter);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"software_boms\":[");
    var first = true;
    while (try st.step()) {
        const product_status = classifyProductStatus(if (st.columnIsNull(5)) null else st.columnText(5));
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
        try appendJsonStringArray(&buf, status_bundle.statuses, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_requirement_ids\":");
        try appendJsonStringArray(&buf, status_bundle.unresolved_requirement_ids, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
        try appendJsonStringArray(&buf, status_bundle.unresolved_test_ids, alloc);
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
    bindOptionalFilter(&st, 1, full_product_identifier_filter);
    bindOptionalFilter(&st, 3, bom_name_filter);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"gaps\":[");
    var first = true;
    while (try st.step()) {
        const product_status = classifyProductStatus(if (st.columnIsNull(4)) null else st.columnText(4));
        if (!include_inactive and productStatusExcludedFromGapAnalysis(product_status)) continue;

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
        try appendJsonStringArray(&buf, status_bundle.statuses, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_requirement_ids\":");
        try appendJsonStringArray(&buf, status_bundle.unresolved_requirement_ids, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
        try appendJsonStringArray(&buf, status_bundle.unresolved_test_ids, alloc);
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

pub fn soupRegisterMarkdown(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const components_json = try getSoupComponentsJson(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(components_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, components_json, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# SOUP Register Report\n\n- Product: `{s}`\n- BOM: `{s}`\n\n", .{ full_product_identifier, bom_name });
    try buf.appendSlice(alloc, "## Components\n\n| Component | Version | Supplier | Category | License | Safety Class | Requirement IDs | Test IDs | Statuses |\n|---|---|---|---|---|---|---|---|---|\n");
    const components = json_util.getObjectField(parsed.value, "components") orelse return alloc.dupe(u8, buf.items);
    if (components != .array or components.array.items.len == 0) {
        try buf.appendSlice(alloc, "| — | — | — | — | — | — | — | — | — |\n");
        return alloc.dupe(u8, buf.items);
    }
    for (components.array.items) |component| {
        const props = json_util.getObjectField(component, "properties") orelse continue;
        const reqs = try markdownJoinStringArray(json_util.getObjectField(props, "requirement_ids"), alloc);
        defer alloc.free(reqs);
        const tests = try markdownJoinStringArray(json_util.getObjectField(props, "test_ids"), alloc);
        defer alloc.free(tests);
        const statuses = try markdownJoinStringArray(json_util.getObjectField(component, "statuses"), alloc);
        defer alloc.free(statuses);
        try std.fmt.format(
            buf.writer(alloc),
            "| {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n",
            .{
                json_util.getString(props, "part") orelse "—",
                json_util.getString(props, "revision") orelse "—",
                json_util.getString(props, "supplier") orelse "—",
                json_util.getString(props, "category") orelse "—",
                json_util.getString(props, "license") orelse "—",
                json_util.getString(props, "safety_class") orelse "—",
                reqs,
                tests,
                statuses,
            },
        );
    }
    return alloc.dupe(u8, buf.items);
}

fn ingestPreparedSoup(
    db: *graph_live.GraphDb,
    prepared: *ParseResult,
    source_format: bom.BomFormat,
    alloc: Allocator,
) !SoupIngestResponse {
    prepared.submission.source_format = source_format;
    var ingest = try bom.ingestSubmission(
        db,
        prepared.submission,
        prepared.warnings,
        .{
            .allow_missing_product = false,
            .unresolved_requirement_warning_code = "SOUP_UNRESOLVED_REQUIREMENT_REF",
            .unresolved_test_warning_code = "SOUP_UNRESOLVED_TEST_REF",
            .warning_subject_label = "SOUP item",
        },
        alloc,
    );
    errdefer ingest.deinit(alloc);

    const row_errors = try prepared.row_errors.toOwnedSlice(alloc);
    prepared.row_errors = .empty;
    return .{
        .full_product_identifier = ingest.full_product_identifier,
        .bom_name = ingest.bom_name,
        .source_format = ingest.source_format,
        .rows_received = prepared.rows_received,
        .rows_ingested = prepared.rows_ingested,
        .inserted_nodes = ingest.inserted_nodes,
        .inserted_edges = ingest.inserted_edges,
        .row_errors = row_errors,
        .warnings = ingest.warnings,
    };
}

fn parseSoupJson(root: std.json.Value, alloc: Allocator) !ParseResult {
    const full_product_identifier = json_util.getString(root, "full_product_identifier") orelse return error.MissingFullProductIdentifier;
    const components = json_util.getObjectField(root, "components") orelse return error.EmptyBomItems;
    if (components != .array) return error.InvalidJson;
    return parseSoupComponentArray(
        components.array.items,
        full_product_identifier,
        json_util.getString(root, "bom_name"),
        .soup_json,
        1,
        alloc,
    );
}

fn parseSoupRows(
    rows: []const []const []const u8,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    source_format: bom.BomFormat,
    alloc: Allocator,
) !ParseResult {
    if (rows.len < 1) return error.EmptyBomItems;
    const header = rows[0];
    const name_col = resolveCol(header, "component_name") orelse return error.MissingRequiredField;
    const version_col = resolveCol(header, "version") orelse return error.MissingRequiredField;
    const supplier_col = resolveCol(header, "supplier");
    const category_col = resolveCol(header, "category");
    const license_col = resolveCol(header, "license");
    const purl_col = resolveCol(header, "purl");
    const safety_class_col = resolveCol(header, "safety_class");
    const anomalies_col = resolveCol(header, "known_anomalies");
    const evaluation_col = resolveCol(header, "anomaly_evaluation");
    const requirement_ids_col = resolveCol(header, "requirement_ids");
    const test_ids_col = resolveCol(header, "test_ids");

    var items = std.StringHashMap(SoupItemSpec).init(alloc);
    defer deinitSoupItemMap(&items, alloc);
    var warnings: std.ArrayList(bom.BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var row_errors: std.ArrayList(SoupRowError) = .empty;
    errdefer {
        for (row_errors.items) |*row_error| row_error.deinit(alloc);
        row_errors.deinit(alloc);
    }

    var rows_received: usize = 0;
    var rows_ingested: usize = 0;
    for (rows[1..], 0..) |row, idx| {
        if (rowIsBlank(row)) continue;
        rows_received += 1;
        const row_number = idx + 2;
        const component_name = try cellAt(row, name_col, alloc);
        defer alloc.free(component_name);
        const version = try cellAt(row, version_col, alloc);
        defer alloc.free(version);
        if (component_name.len == 0 or version.len == 0) {
            try appendRowError(&row_errors, row_number, "SOUP_MISSING_REQUIRED_FIELD", "component_name and version are required.", alloc);
            continue;
        }

        const key = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ component_name, version });
        defer alloc.free(key);
        try upsertSoupItemSpec(
            &items,
            key,
            .{
                .component_name = try alloc.dupe(u8, component_name),
                .version = try alloc.dupe(u8, version),
                .supplier = try optionalCellAtAllowBlank(row, supplier_col, alloc),
                .category = try optionalCellAtAllowBlank(row, category_col, alloc),
                .license = try optionalCellAtAllowBlank(row, license_col, alloc),
                .purl = try optionalCellAtAllowBlank(row, purl_col, alloc),
                .safety_class = try optionalCellAtAllowBlank(row, safety_class_col, alloc),
                .known_anomalies = try optionalCellAtAllowBlank(row, anomalies_col, alloc),
                .anomaly_evaluation = try optionalCellAtAllowBlank(row, evaluation_col, alloc),
                .requirement_ids = if (requirement_ids_col) |col| try parseTraceRefCell(if (col < row.len) row[col] else "", alloc) else null,
                .test_ids = if (test_ids_col) |col| try parseTraceRefCell(if (col < row.len) row[col] else "", alloc) else null,
            },
            alloc,
        );
        rows_ingested += 1;
    }

    if (rows_ingested == 0) return error.EmptyBomItems;
    try appendSoupItemWarnings(&warnings, &items, alloc);
    const submission = try soupSubmissionFromItems(items, full_product_identifier, bom_name_override, source_format, alloc);
    return .{
        .submission = submission,
        .warnings = warnings,
        .row_errors = row_errors,
        .rows_received = rows_received,
        .rows_ingested = rows_ingested,
    };
}

fn parseSoupComponentArray(
    components: []const std.json.Value,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    source_format: bom.BomFormat,
    row_base: usize,
    alloc: Allocator,
) !ParseResult {
    var items = std.StringHashMap(SoupItemSpec).init(alloc);
    defer deinitSoupItemMap(&items, alloc);
    var warnings: std.ArrayList(bom.BomWarning) = .empty;
    errdefer {
        for (warnings.items) |*warning| warning.deinit(alloc);
        warnings.deinit(alloc);
    }
    var row_errors: std.ArrayList(SoupRowError) = .empty;
    errdefer {
        for (row_errors.items) |*row_error| row_error.deinit(alloc);
        row_errors.deinit(alloc);
    }

    var rows_received: usize = 0;
    var rows_ingested: usize = 0;
    for (components, 0..) |component, idx| {
        rows_received += 1;
        const row_number = row_base + idx;
        if (component != .object) {
            try appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "Each components[] entry must be an object.", alloc);
            continue;
        }
        const component_name = dupRequiredString(component, "component_name", alloc) catch {
            try appendRowError(&row_errors, row_number, "SOUP_MISSING_REQUIRED_FIELD", "component_name is required.", alloc);
            continue;
        };
        defer alloc.free(component_name);
        const version = dupRequiredString(component, "version", alloc) catch {
            try appendRowError(&row_errors, row_number, "SOUP_MISSING_REQUIRED_FIELD", "version is required.", alloc);
            continue;
        };
        defer alloc.free(version);

        var requirement_ids = parseTraceRefJsonField(component, "requirement_ids", alloc) catch {
            try appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "requirement_ids must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (requirement_ids) |items_ref| freeStringSlice(items_ref, alloc);
        const requirement_id = parseTraceRefJsonField(component, "requirement_id", alloc) catch {
            if (requirement_ids) |items_ref| freeStringSlice(items_ref, alloc);
            try appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "requirement_id must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (requirement_id) |items_ref| freeStringSlice(items_ref, alloc);
        try mergeTraceRefLists(&requirement_ids, requirement_id, alloc);

        var test_ids = parseTraceRefJsonField(component, "test_ids", alloc) catch {
            if (requirement_ids) |items_ref| freeStringSlice(items_ref, alloc);
            try appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "test_ids must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (test_ids) |items_ref| freeStringSlice(items_ref, alloc);
        const test_id = parseTraceRefJsonField(component, "test_id", alloc) catch {
            if (requirement_ids) |items_ref| freeStringSlice(items_ref, alloc);
            if (test_ids) |items_ref| freeStringSlice(items_ref, alloc);
            try appendRowError(&row_errors, row_number, "SOUP_INVALID_ROW", "test_id must be a string or array of strings.", alloc);
            continue;
        };
        errdefer if (test_id) |items_ref| freeStringSlice(items_ref, alloc);
        try mergeTraceRefLists(&test_ids, test_id, alloc);

        const key = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ component_name, version });
        defer alloc.free(key);
        try upsertSoupItemSpec(
            &items,
            key,
            .{
                .component_name = try alloc.dupe(u8, component_name),
                .version = try alloc.dupe(u8, version),
                .supplier = try dupOptionalStringAllowBlank(component, "supplier", alloc),
                .category = try dupOptionalStringAllowBlank(component, "category", alloc),
                .license = try dupOptionalStringAllowBlank(component, "license", alloc),
                .purl = try dupOptionalStringAllowBlank(component, "purl", alloc),
                .safety_class = try dupOptionalStringAllowBlank(component, "safety_class", alloc),
                .known_anomalies = try dupOptionalStringAllowBlank(component, "known_anomalies", alloc),
                .anomaly_evaluation = try dupOptionalStringAllowBlank(component, "anomaly_evaluation", alloc),
                .requirement_ids = requirement_ids,
                .test_ids = test_ids,
            },
            alloc,
        );
        rows_ingested += 1;
    }

    if (rows_ingested == 0) return error.EmptyBomItems;
    try appendSoupItemWarnings(&warnings, &items, alloc);
    const submission = try soupSubmissionFromItems(items, full_product_identifier, bom_name_override, source_format, alloc);
    return .{
        .submission = submission,
        .warnings = warnings,
        .row_errors = row_errors,
        .rows_received = rows_received,
        .rows_ingested = rows_ingested,
    };
}

fn soupSubmissionFromItems(
    items: std.StringHashMap(SoupItemSpec),
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    source_format: bom.BomFormat,
    alloc: Allocator,
) !bom.BomSubmission {
    var occurrences: std.ArrayList(bom.BomOccurrenceInput) = .empty;
    errdefer {
        for (occurrences.items) |*occurrence| occurrence.deinit(alloc);
        occurrences.deinit(alloc);
    }

    var it = items.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        try occurrences.append(alloc, .{
            .parent_key = null,
            .child_part = try alloc.dupe(u8, item.component_name),
            .child_revision = try alloc.dupe(u8, item.version),
            .description = null,
            .category = if (item.category) |value| try alloc.dupe(u8, value) else null,
            .requirement_ids = if (item.requirement_ids) |values| try dupStringSlice(values, alloc) else null,
            .test_ids = if (item.test_ids) |values| try dupStringSlice(values, alloc) else null,
            .quantity = null,
            .ref_designator = null,
            .supplier = if (item.supplier) |value| try alloc.dupe(u8, value) else null,
            .purl = if (item.purl) |value| try alloc.dupe(u8, value) else null,
            .license = if (item.license) |value| try alloc.dupe(u8, value) else null,
            .hashes_json = null,
            .safety_class = if (item.safety_class) |value| try alloc.dupe(u8, value) else null,
            .known_anomalies = if (item.known_anomalies) |value| try alloc.dupe(u8, value) else null,
            .anomaly_evaluation = if (item.anomaly_evaluation) |value| try alloc.dupe(u8, value) else null,
        });
    }

    return .{
        .full_product_identifier = try alloc.dupe(u8, full_product_identifier),
        .bom_name = try alloc.dupe(u8, normalizedBomName(bom_name_override)),
        .bom_type = .software,
        .source_format = source_format,
        .root_key = null,
        .occurrences = try occurrences.toOwnedSlice(alloc),
    };
}

fn appendSoupItemWarnings(
    warnings: *std.ArrayList(bom.BomWarning),
    items: *std.StringHashMap(SoupItemSpec),
    alloc: Allocator,
) !void {
    var it = items.iterator();
    while (it.next()) |entry| {
        const item = entry.value_ptr.*;
        const subject = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ item.component_name, item.version });
        defer alloc.free(subject);
        const known = item.known_anomalies orelse "";
        const evaluation = item.anomaly_evaluation orelse "";
        const known_trimmed = std.mem.trim(u8, known, " \r\n\t");
        const evaluation_trimmed = std.mem.trim(u8, evaluation, " \r\n\t");
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item.version, " \r\n\t"), "unknown")) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has version 'unknown'.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_VERSION_UNKNOWN", message, subject, alloc);
        }
        if (known_trimmed.len == 0 and evaluation_trimmed.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has no anomalies documented.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_ANOMALIES_DOCUMENTED", message, subject, alloc);
        } else if (known_trimmed.len > 0 and evaluation_trimmed.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' is missing anomaly evaluation.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_ANOMALY_EVALUATION", message, subject, alloc);
        }
        if (item.requirement_ids == null or item.requirement_ids.?.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has no requirement linkage.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_REQUIREMENT_LINKAGE", message, subject, alloc);
        }
        if (item.test_ids == null or item.test_ids.?.len == 0) {
            const message = try std.fmt.allocPrint(alloc, "SOUP item '{s}' has no test linkage.", .{subject});
            defer alloc.free(message);
            try appendWarning(warnings, "SOUP_NO_TEST_LINKAGE", message, subject, alloc);
        }
    }
}

fn buildSoupStatusBundle(
    db: *graph_live.GraphDb,
    item_id: []const u8,
    properties_json: []const u8,
    alloc: Allocator,
) !SoupStatusBundle {
    const declared_requirement_ids = try parseStringArrayProperty(properties_json, "requirement_ids", alloc);
    errdefer freeStringSlice(declared_requirement_ids, alloc);
    const declared_test_ids = try parseStringArrayProperty(properties_json, "test_ids", alloc);
    errdefer freeStringSlice(declared_test_ids, alloc);

    var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_requirements, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

    var linked_tests: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_tests, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

    const unresolved_requirement_ids = try unresolvedTraceRefs(declared_requirement_ids, linked_requirements.items, alloc);
    errdefer freeStringSlice(unresolved_requirement_ids, alloc);
    const unresolved_test_ids = try unresolvedTraceRefs(declared_test_ids, linked_tests.items, alloc);
    errdefer freeStringSlice(unresolved_test_ids, alloc);

    const version = extractJsonField(properties_json, "revision") orelse "";
    const known_anomalies = extractJsonField(properties_json, "known_anomalies") orelse "";
    const anomaly_evaluation = extractJsonField(properties_json, "anomaly_evaluation") orelse "";

    var statuses: std.ArrayList([]const u8) = .empty;
    errdefer freeStringSlice(statuses.items, alloc);
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

    freeStringSlice(declared_requirement_ids, alloc);
    freeStringSlice(declared_test_ids, alloc);
    return .{
        .statuses = try statuses.toOwnedSlice(alloc),
        .unresolved_requirement_ids = unresolved_requirement_ids,
        .unresolved_test_ids = unresolved_test_ids,
        .linked_requirement_count = linked_requirements.items.len,
        .linked_test_count = linked_tests.items.len,
        .declared_requirement_count = declared_requirement_ids.len,
        .declared_test_count = declared_test_ids.len,
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
    bindOptionalFilter(&st, 1, full_product_identifier_filter);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"components\":[");
    var first = true;
    while (try st.step()) {
        const product_status = classifyProductStatus(if (st.columnIsNull(4)) null else st.columnText(4));
        if (!include_obsolete and product_status == .obsolete) continue;
        const properties_json = st.columnText(1);
        const field_value = extractJsonField(properties_json, json_field) orelse "";
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

fn normalizedBomName(value: ?[]const u8) []const u8 {
    const raw = value orelse return default_bom_name;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return default_bom_name;
    return trimmed;
}

fn findSheetRowsTrimmed(sheets: []const xlsx.SheetData, want: []const u8) ?[]const []const []const u8 {
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, sheet.name, " \r\n\t"), want)) return sheet.rows;
    }
    return null;
}

fn parseTraceRefCell(value: []const u8, alloc: Allocator) !?[]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (refs.items) |item| alloc.free(item);
        refs.deinit(alloc);
    }
    var it = std.mem.tokenizeAny(u8, value, ",;|");
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \r\n\t");
        if (trimmed.len == 0 or stringSliceContains(refs.items, trimmed)) continue;
        try refs.append(alloc, try alloc.dupe(u8, trimmed));
    }
    if (refs.items.len == 0) {
        refs.deinit(alloc);
        return null;
    }
    return @constCast(try refs.toOwnedSlice(alloc));
}

fn parseTraceRefJsonField(value: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const []const u8 {
    const field = json_util.getObjectField(value, field_name) orelse return null;
    var refs: ?[]const []const u8 = null;
    switch (field) {
        .null => return null,
        .string => refs = try parseTraceRefCell(field.string, alloc),
        .array => {
            for (field.array.items) |entry| {
                if (entry != .string) return error.InvalidJson;
                const parsed = try parseTraceRefCell(entry.string, alloc);
                errdefer if (parsed) |items| freeStringSlice(items, alloc);
                try mergeTraceRefLists(&refs, parsed, alloc);
            }
        },
        else => return error.InvalidJson,
    }
    return refs;
}

fn unresolvedTraceRefs(
    declared_ids: []const []const u8,
    linked_nodes: []const graph_live.Node,
    alloc: Allocator,
) ![]const []const u8 {
    var unresolved: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unresolved.items) |item| alloc.free(item);
        unresolved.deinit(alloc);
    }
    for (declared_ids) |declared_id| {
        var matched = false;
        for (linked_nodes) |node| {
            if (std.mem.eql(u8, node.id, declared_id)) {
                matched = true;
                break;
            }
        }
        if (!matched) try unresolved.append(alloc, try alloc.dupe(u8, declared_id));
    }
    return unresolved.toOwnedSlice(alloc);
}

fn parseStringArrayProperty(properties_json: []const u8, field_name: []const u8, alloc: Allocator) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, properties_json, .{});
    defer parsed.deinit();
    const field = json_util.getObjectField(parsed.value, field_name) orelse return try alloc.alloc([]const u8, 0);
    if (field != .array) return error.InvalidJson;

    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |item| alloc.free(item);
        items.deinit(alloc);
    }
    for (field.array.items) |entry| {
        if (entry != .string) return error.InvalidJson;
        try items.append(alloc, try alloc.dupe(u8, entry.string));
    }
    return items.toOwnedSlice(alloc);
}

fn extractJsonField(properties_json: []const u8, field_name: []const u8) ?[]const u8 {
    return json_util.extractJsonFieldStatic(properties_json, field_name);
}

fn resolveCol(header: []const []const u8, want: []const u8) ?usize {
    for (header, 0..) |cell, idx| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, cell, " \r\n\t"), want)) return idx;
    }
    return null;
}

fn rowIsBlank(row: []const []const u8) bool {
    for (row) |cell| {
        if (std.mem.trim(u8, cell, " \r\n\t").len != 0) return false;
    }
    return true;
}

fn cellAt(row: []const []const u8, idx: usize, alloc: Allocator) ![]u8 {
    if (idx >= row.len) return alloc.dupe(u8, "");
    return alloc.dupe(u8, std.mem.trim(u8, row[idx], " \r\n\t"));
}

fn optionalCellAtAllowBlank(row: []const []const u8, idx: ?usize, alloc: Allocator) !?[]const u8 {
    if (idx == null or idx.? >= row.len) return null;
    return @as([]const u8, try alloc.dupe(u8, std.mem.trim(u8, row[idx.?], " \r\n\t")));
}

fn dupRequiredString(value: std.json.Value, field_name: []const u8, alloc: Allocator) ![]u8 {
    const raw = json_util.getString(value, field_name) orelse return error.MissingRequiredField;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return error.MissingRequiredField;
    return alloc.dupe(u8, trimmed);
}

fn dupOptionalStringAllowBlank(value: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const u8 {
    const field = json_util.getObjectField(value, field_name) orelse return null;
    return switch (field) {
        .null => null,
        .string => try alloc.dupe(u8, std.mem.trim(u8, field.string, " \r\n\t")),
        else => return error.InvalidJson,
    };
}

fn appendRowError(row_errors: *std.ArrayList(SoupRowError), row: usize, code: []const u8, message: []const u8, alloc: Allocator) !void {
    try row_errors.append(alloc, .{
        .row = row,
        .code = try alloc.dupe(u8, code),
        .message = try alloc.dupe(u8, message),
    });
}

fn appendWarning(
    warnings: *std.ArrayList(bom.BomWarning),
    code: []const u8,
    message: []const u8,
    subject: ?[]const u8,
    alloc: Allocator,
) !void {
    try warnings.append(alloc, .{
        .code = try alloc.dupe(u8, code),
        .message = try alloc.dupe(u8, message),
        .subject = if (subject) |value| try alloc.dupe(u8, value) else null,
    });
}

fn upsertSoupItemSpec(items: *std.StringHashMap(SoupItemSpec), key: []const u8, incoming: SoupItemSpec, alloc: Allocator) !void {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const gop = try items.getOrPut(key_copy);
    if (!gop.found_existing) {
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = incoming;
        return;
    }
    alloc.free(key_copy);
    alloc.free(incoming.component_name);
    alloc.free(incoming.version);
    mergeOptionalString(&gop.value_ptr.supplier, incoming.supplier, alloc);
    mergeOptionalString(&gop.value_ptr.category, incoming.category, alloc);
    mergeOptionalString(&gop.value_ptr.license, incoming.license, alloc);
    mergeOptionalString(&gop.value_ptr.purl, incoming.purl, alloc);
    mergeOptionalString(&gop.value_ptr.safety_class, incoming.safety_class, alloc);
    mergeOptionalString(&gop.value_ptr.known_anomalies, incoming.known_anomalies, alloc);
    mergeOptionalString(&gop.value_ptr.anomaly_evaluation, incoming.anomaly_evaluation, alloc);
    try mergeTraceRefLists(&gop.value_ptr.requirement_ids, incoming.requirement_ids, alloc);
    try mergeTraceRefLists(&gop.value_ptr.test_ids, incoming.test_ids, alloc);
}

fn mergeOptionalString(target: *?[]const u8, incoming: ?[]const u8, alloc: Allocator) void {
    if (incoming) |value| {
        if (target.* == null) {
            target.* = value;
        } else {
            alloc.free(value);
        }
    }
}

fn mergeTraceRefLists(existing: *?[]const []const u8, incoming: ?[]const []const u8, alloc: Allocator) !void {
    if (incoming == null) return;
    if (existing.* == null) {
        existing.* = incoming;
        return;
    }
    const old_items = existing.*.?;
    const incoming_items = incoming.?;
    var merged = try alloc.alloc([]const u8, old_items.len + incoming_items.len);
    var count: usize = 0;
    for (old_items) |item| {
        merged[count] = item;
        count += 1;
    }
    for (incoming_items) |item| {
        if (stringSliceContains(merged[0..count], item)) {
            alloc.free(item);
            continue;
        }
        merged[count] = item;
        count += 1;
    }
    alloc.free(old_items);
    alloc.free(incoming_items);
    existing.* = merged[0..count];
}

fn stringSliceContains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn dupStringSlice(items: []const []const u8, alloc: Allocator) ![]const []const u8 {
    var duped = try alloc.alloc([]const u8, items.len);
    var count: usize = 0;
    errdefer {
        for (duped[0..count]) |item| alloc.free(item);
        alloc.free(duped);
    }
    for (items, 0..) |item, idx| {
        duped[idx] = try alloc.dupe(u8, item);
        count = idx + 1;
    }
    return duped;
}

fn freeStringSlice(items: []const []const u8, alloc: Allocator) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

fn deinitSoupItemMap(items: *std.StringHashMap(SoupItemSpec), alloc: Allocator) void {
    var it = items.iterator();
    while (it.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        entry.value_ptr.deinit(alloc);
    }
    items.deinit();
}

fn bindOptionalFilter(st: anytype, first_idx: usize, value: ?[]const u8) void {
    if (value) |actual| {
        st.bindText(@intCast(first_idx), actual) catch unreachable;
        st.bindText(@intCast(first_idx + 1), actual) catch unreachable;
    } else {
        st.bindNull(@intCast(first_idx)) catch unreachable;
        st.bindNull(@intCast(first_idx + 1)) catch unreachable;
    }
}

fn writeTempXlsx(body: []const u8, alloc: Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/rtmify-soup-{d}.xlsx", .{std.time.nanoTimestamp()});
    errdefer alloc.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
    return path;
}

fn classifyProductStatus(raw_value: ?[]const u8) enum { active, in_development, superseded, eol, obsolete, unknown } {
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

fn productStatusExcludedFromGapAnalysis(status: @TypeOf(classifyProductStatus(null))) bool {
    return switch (status) {
        .superseded, .eol, .obsolete => true,
        else => false,
    };
}

fn productStatusForIdentifier(db: *graph_live.GraphDb, full_product_identifier: []const u8, alloc: Allocator) !@TypeOf(classifyProductStatus(null)) {
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

fn bomFormatString(value: bom.BomFormat) []const u8 {
    return switch (value) {
        .hardware_csv => "hardware_csv",
        .hardware_json => "hardware_json",
        .cyclonedx => "cyclonedx",
        .spdx => "spdx",
        .xlsx => "xlsx",
        .sheets => "sheets",
        .soup_json => "soup_json",
        .soup_xlsx => "soup_xlsx",
    };
}

fn markdownJoinStringArray(value: ?std.json.Value, alloc: Allocator) ![]const u8 {
    const field = value orelse return alloc.dupe(u8, "—");
    if (field != .array or field.array.items.len == 0) return alloc.dupe(u8, "—");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (field.array.items, 0..) |entry, idx| {
        if (entry != .string) continue;
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, entry.string);
    }
    if (buf.items.len == 0) return alloc.dupe(u8, "—");
    return alloc.dupe(u8, buf.items);
}

fn appendJsonStringArray(buf: *std.ArrayList(u8), items: []const []const u8, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try shared.appendJsonStr(buf, item, alloc);
    }
    try buf.append(alloc, ']');
}

const testing = std.testing;

test "SOUP json ingest stores SOUP-specific fields and warning statuses" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-RevC", "Product", "{\"full_identifier\":\"ASM-1000-RevC\"}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TG-001", "TestGroup", "{}", null);

    var resp = try ingestJsonBody(
        &db,
        \\{
        \\  "full_product_identifier":"ASM-1000-RevC",
        \\  "components":[
        \\    {
        \\      "component_name":"FreeRTOS",
        \\      "version":"10.5.1",
        \\      "supplier":"Amazon/AWS",
        \\      "safety_class":"C",
        \\      "known_anomalies":"None known",
        \\      "anomaly_evaluation":"Reviewed",
        \\      "requirement_ids":["REQ-001"],
        \\      "test_ids":["TG-001"]
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), resp.rows_ingested);

    const item = try db.getNode("bom-item://ASM-1000-RevC/software/SOUP Components/FreeRTOS@10.5.1", testing.allocator);
    defer shared.freeNode(item.?, testing.allocator);
    try testing.expect(item != null);
    try testing.expect(std.mem.indexOf(u8, item.?.properties, "\"supplier\":\"Amazon/AWS\"") != null);
    try testing.expect(std.mem.indexOf(u8, item.?.properties, "\"safety_class\":\"C\"") != null);
    try testing.expect(std.mem.indexOf(u8, item.?.properties, "\"known_anomalies\":\"None known\"") != null);
}

test "SOUP json row errors skip invalid rows" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-RevC", "Product", "{\"full_identifier\":\"ASM-1000-RevC\"}", null);

    var resp = try ingestJsonBody(
        &db,
        \\{
        \\  "full_product_identifier":"ASM-1000-RevC",
        \\  "components":[
        \\    {"component_name":"","version":"1.0.0"},
        \\    {"component_name":"lwIP","version":"unknown"}
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), resp.rows_received);
    try testing.expectEqual(@as(usize, 1), resp.rows_ingested);
    try testing.expectEqual(@as(usize, 1), resp.row_errors.len);
}
