const std = @import("std");
const Allocator = std.mem.Allocator;

const db_mod = @import("db.zig");
const graph_live = @import("graph_live.zig");
const json_util = @import("json_util.zig");
const shared = @import("routes/shared.zig");
const xlsx = @import("rtmify").xlsx;

pub const BomType = enum { hardware, software };
pub const BomFormat = enum { hardware_csv, hardware_json, cyclonedx, spdx, xlsx, sheets, soup_json, soup_xlsx };

const ProductStatus = enum {
    active,
    in_development,
    superseded,
    eol,
    obsolete,
    unknown,
};

pub const BomOccurrenceInput = struct {
    parent_key: ?[]const u8,
    child_part: []const u8,
    child_revision: []const u8,
    description: ?[]const u8,
    category: ?[]const u8,
    requirement_ids: ?[]const []const u8,
    test_ids: ?[]const []const u8,
    quantity: ?[]const u8,
    ref_designator: ?[]const u8,
    supplier: ?[]const u8,
    purl: ?[]const u8,
    license: ?[]const u8,
    hashes_json: ?[]const u8,
    safety_class: ?[]const u8,
    known_anomalies: ?[]const u8,
    anomaly_evaluation: ?[]const u8,

    pub fn deinit(self: *BomOccurrenceInput, alloc: Allocator) void {
        if (self.parent_key) |value| alloc.free(value);
        alloc.free(self.child_part);
        alloc.free(self.child_revision);
        if (self.description) |value| alloc.free(value);
        if (self.category) |value| alloc.free(value);
        if (self.requirement_ids) |values| freeStringSlice(values, alloc);
        if (self.test_ids) |values| freeStringSlice(values, alloc);
        if (self.quantity) |value| alloc.free(value);
        if (self.ref_designator) |value| alloc.free(value);
        if (self.supplier) |value| alloc.free(value);
        if (self.purl) |value| alloc.free(value);
        if (self.license) |value| alloc.free(value);
        if (self.hashes_json) |value| alloc.free(value);
        if (self.safety_class) |value| alloc.free(value);
        if (self.known_anomalies) |value| alloc.free(value);
        if (self.anomaly_evaluation) |value| alloc.free(value);
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

pub const GroupIngestStatus = enum { ok, failed };

pub const GroupedBomResult = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    rows_ingested: usize,
    inserted_nodes: usize,
    inserted_edges: usize,
    status: GroupIngestStatus,
    error_code: ?[]const u8 = null,
    error_detail: ?[]const u8 = null,
    warnings: []BomWarning,

    pub fn deinit(self: *GroupedBomResult, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        if (self.error_code) |value| alloc.free(value);
        if (self.error_detail) |value| alloc.free(value);
        for (self.warnings) |*warning| warning.deinit(alloc);
        alloc.free(self.warnings);
    }
};

pub const GroupedBomIngestResponse = struct {
    groups: []GroupedBomResult,

    pub fn deinit(self: *GroupedBomIngestResponse, alloc: Allocator) void {
        for (self.groups) |*group| group.deinit(alloc);
        alloc.free(self.groups);
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
    MissingDesignBomTab,
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

fn classifyProductStatus(raw_value: ?[]const u8) ProductStatus {
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

fn productStatusExcludedFromActiveGraph(status: ProductStatus) bool {
    return status == .obsolete;
}

fn productStatusExcludedFromGapAnalysis(status: ProductStatus) bool {
    return switch (status) {
        .superseded, .eol, .obsolete => true,
        else => false,
    };
}

fn productStatusForIdentifier(db: *graph_live.GraphDb, full_product_identifier: []const u8, alloc: Allocator) !ProductStatus {
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

pub const IngestOptions = struct {
    allow_missing_product: bool = false,
    unresolved_requirement_warning_code: []const u8 = "BOM_UNRESOLVED_REQUIREMENT_REF",
    unresolved_test_warning_code: []const u8 = "BOM_UNRESOLVED_TEST_REF",
    warning_subject_label: []const u8 = "BOM item",
};

const ItemSpec = struct {
    part: []const u8,
    revision: []const u8,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    supplier: ?[]const u8 = null,
    requirement_ids: ?[]const []const u8 = null,
    test_ids: ?[]const []const u8 = null,
    purl: ?[]const u8 = null,
    license: ?[]const u8 = null,
    hashes_json: ?[]const u8 = null,
    safety_class: ?[]const u8 = null,
    known_anomalies: ?[]const u8 = null,
    anomaly_evaluation: ?[]const u8 = null,
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
    return ingestPrepared(db, &prepared, .{}, alloc);
}

pub fn ingestInboxFile(
    db: *graph_live.GraphDb,
    name: []const u8,
    body: []const u8,
    alloc: Allocator,
) (BomError || db_mod.DbError || error{OutOfMemory})!BomIngestResponse {
    var prepared = try prepareInboxFile(name, body, alloc);
    defer prepared.deinit(alloc);
    return ingestPrepared(db, &prepared, .{}, alloc);
}

pub fn ingestXlsxBody(
    db: *graph_live.GraphDb,
    body: []const u8,
    alloc: Allocator,
) anyerror!GroupedBomIngestResponse {
    const temp_path = try writeTempXlsx(body, alloc);
    defer {
        std.fs.deleteFileAbsolute(temp_path) catch {};
        alloc.free(temp_path);
    }

    return ingestXlsxPath(db, temp_path, alloc);
}

pub fn ingestXlsxPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    alloc: Allocator,
) anyerror!GroupedBomIngestResponse {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sheets = try xlsx.parse(arena, path);
    const design_bom_rows = findSheetRows(sheets, "Design BOM") orelse return error.MissingDesignBomTab;
    return ingestDesignBomRows(db, design_bom_rows, findSheetRows(sheets, "Product"), .xlsx, alloc);
}

pub fn ingestSubmission(
    db: *graph_live.GraphDb,
    submission: BomSubmission,
    warnings: std.ArrayList(BomWarning),
    options: IngestOptions,
    alloc: Allocator,
) (BomError || db_mod.DbError || error{OutOfMemory})!BomIngestResponse {
    var prepared = PreparedBom{
        .submission = submission,
        .warnings = warnings,
    };
    defer prepared.deinit(alloc);
    return ingestPrepared(db, &prepared, options, alloc);
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

pub fn groupedIngestResponseJson(response: GroupedBomIngestResponse, alloc: Allocator) ![]const u8 {
    var ok_count: usize = 0;
    for (response.groups) |group| {
        if (group.status == .ok) ok_count += 1;
    }
    const overall_status = if (response.groups.len == 0 or ok_count == 0)
        "error"
    else if (ok_count == response.groups.len)
        "ok"
    else
        "partial";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"status\":");
    try shared.appendJsonStr(&buf, overall_status, alloc);
    try buf.appendSlice(alloc, ",\"groups\":[");
    for (response.groups, 0..) |group, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"status\":");
        try shared.appendJsonStr(&buf, if (group.status == .ok) "ok" else "error", alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, group.full_product_identifier, alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, group.bom_name, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"rows_ingested\":{d},\"inserted_nodes\":{d},\"inserted_edges\":{d}", .{
            group.rows_ingested,
            group.inserted_nodes,
            group.inserted_edges,
        });
        try buf.appendSlice(alloc, ",\"error\":");
        if (group.error_code) |code| {
            try buf.appendSlice(alloc, "{\"code\":");
            try shared.appendJsonStr(&buf, code, alloc);
            try buf.appendSlice(alloc, ",\"detail\":");
            try shared.appendJsonStrOpt(&buf, group.error_detail, alloc);
            try buf.append(alloc, '}');
        } else {
            try buf.appendSlice(alloc, "null");
        }
        try buf.appendSlice(alloc, ",\"warnings\":[");
        for (group.warnings, 0..) |warning, widx| {
            if (widx > 0) try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"code\":");
            try shared.appendJsonStr(&buf, warning.code, alloc);
            try buf.appendSlice(alloc, ",\"message\":");
            try shared.appendJsonStr(&buf, warning.message, alloc);
            try buf.appendSlice(alloc, ",\"subject\":");
            try shared.appendJsonStrOpt(&buf, warning.subject, alloc);
            try buf.append(alloc, '}');
        }
        try buf.appendSlice(alloc, "]}");
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn ingestDesignBomRows(
    db: *graph_live.GraphDb,
    design_bom_rows: []const []const []const u8,
    product_rows: ?[]const []const []const u8,
    source_format: BomFormat,
    alloc: Allocator,
) (BomError || db_mod.DbError || error{OutOfMemory})!GroupedBomIngestResponse {
    if (product_rows) |rows| try upsertProductRows(db, rows, alloc);
    if (design_bom_rows.len < 2) return .{ .groups = try alloc.alloc(GroupedBomResult, 0) };

    const header = design_bom_rows[0];
    const bom_name_col = resolveCol(header, "bom_name") orelse return error.MissingRequiredField;
    const full_identifier_col = resolveCol(header, "full_product_identifier") orelse resolveCol(header, "full_identifier") orelse return error.MissingRequiredField;

    const GroupBuilder = struct {
        full_product_identifier: []const u8,
        bom_name: []const u8,
        rows: std.ArrayList([]const []const u8),

        fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.full_product_identifier);
            allocator.free(self.bom_name);
            self.rows.deinit(allocator);
        }
    };

    var groups = std.StringHashMap(GroupBuilder).init(alloc);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        groups.deinit();
    }

    for (design_bom_rows[1..]) |row| {
        const bom_name = std.mem.trim(u8, if (bom_name_col < row.len) row[bom_name_col] else "", " \r\n\t");
        const full_identifier = std.mem.trim(u8, if (full_identifier_col < row.len) row[full_identifier_col] else "", " \r\n\t");
        const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ full_identifier, bom_name });
        errdefer alloc.free(key);
        const gop = try groups.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = key;
            gop.value_ptr.* = .{
                .full_product_identifier = try alloc.dupe(u8, full_identifier),
                .bom_name = try alloc.dupe(u8, bom_name),
                .rows = .empty,
            };
        } else {
            alloc.free(key);
        }
        try gop.value_ptr.rows.append(alloc, row);
    }

    var results: std.ArrayList(GroupedBomResult) = .empty;
    errdefer {
        for (results.items) |*result| result.deinit(alloc);
        results.deinit(alloc);
    }

    var it = groups.iterator();
    while (it.next()) |entry| {
        const csv_body = try groupedRowsToCsv(header, entry.value_ptr.rows.items, alloc);
        defer alloc.free(csv_body);

        var prepared = prepareHardwareCsv(csv_body, alloc) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try results.append(alloc, try groupErrorResult(entry.value_ptr.*, entry.value_ptr.rows.items.len, groupedBomErrorCode(err), groupedBomErrorDetail(err), alloc));
                continue;
            },
        };
        defer prepared.deinit(alloc);
        prepared.submission.source_format = source_format;

        var ingest = ingestPrepared(db, &prepared, .{ .allow_missing_product = true }, alloc) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try results.append(alloc, try groupErrorResult(entry.value_ptr.*, entry.value_ptr.rows.items.len, groupedBomErrorCode(err), groupedBomErrorDetail(err), alloc));
                continue;
            },
        };
        defer ingest.deinit(alloc);

        try results.append(alloc, .{
            .full_product_identifier = try alloc.dupe(u8, ingest.full_product_identifier),
            .bom_name = try alloc.dupe(u8, ingest.bom_name),
            .rows_ingested = entry.value_ptr.rows.items.len,
            .inserted_nodes = ingest.inserted_nodes,
            .inserted_edges = ingest.inserted_edges,
            .status = .ok,
            .warnings = try dupWarnings(ingest.warnings, alloc),
        });
    }

    return .{ .groups = try results.toOwnedSlice(alloc) };
}

fn freeStringSlice(items: []const []const u8, alloc: Allocator) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
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

fn appendJsonStringArray(buf: *std.ArrayList(u8), items: ?[]const []const u8, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    if (items) |values| {
        for (values, 0..) |value, idx| {
            if (idx > 0) try buf.append(alloc, ',');
            try shared.appendJsonStr(buf, value, alloc);
        }
    }
    try buf.append(alloc, ']');
}

fn stringSliceContains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
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

fn parseTraceRefJsonField(item: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const []const u8 {
    const field = json_util.getObjectField(item, field_name) orelse return null;

    var refs: ?[]const []const u8 = null;
    switch (field) {
        .string => refs = try parseTraceRefCell(field.string, alloc),
        .array => {
            for (field.array.items) |entry| {
                if (entry != .string) {
                    if (refs) |items| freeStringSlice(items, alloc);
                    return error.InvalidJson;
                }
                const parsed = try parseTraceRefCell(entry.string, alloc);
                errdefer if (parsed) |items| freeStringSlice(items, alloc);
                try mergeTraceRefLists(&refs, parsed, alloc);
            }
        },
        else => return error.InvalidJson,
    }
    return refs;
}

fn dupWarnings(warnings: []const BomWarning, alloc: Allocator) ![]BomWarning {
    const duped = try alloc.alloc(BomWarning, warnings.len);
    errdefer alloc.free(duped);
    for (warnings, 0..) |warning, idx| {
        duped[idx] = .{
            .code = try alloc.dupe(u8, warning.code),
            .message = try alloc.dupe(u8, warning.message),
            .subject = if (warning.subject) |value| try alloc.dupe(u8, value) else null,
        };
    }
    return duped;
}

fn groupedRowsToCsv(header: []const []const u8, rows: []const []const []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try appendCsvRow(&buf, header, true, alloc);
    for (rows) |row| {
        try buf.append(alloc, '\n');
        try appendCsvRow(&buf, row, false, alloc);
    }
    return alloc.dupe(u8, buf.items);
}

fn appendCsvRow(buf: *std.ArrayList(u8), row: []const []const u8, normalize_header: bool, alloc: Allocator) !void {
    for (row, 0..) |cell, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        const value = if (normalize_header and std.ascii.eqlIgnoreCase(cell, "full_product_identifier"))
            "full_identifier"
        else
            cell;
        try appendCsvCell(buf, value, alloc);
    }
}

fn appendCsvCell(buf: *std.ArrayList(u8), value: []const u8, alloc: Allocator) !void {
    const needs_quotes = std.mem.indexOfAny(u8, value, ",\"\n\r") != null;
    if (!needs_quotes) {
        try buf.appendSlice(alloc, value);
        return;
    }
    try buf.append(alloc, '"');
    for (value) |c| {
        if (c == '"') try buf.append(alloc, '"');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '"');
}

fn groupedBomErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidCsv => "invalid_csv",
        error.InvalidJson => "invalid_json",
        error.MissingBomName => "missing_bom_name",
        error.MissingFullProductIdentifier => "missing_full_product_identifier",
        error.EmptyBomItems => "empty_bom_items",
        error.MissingRequiredField => "BOM_MISSING_REQUIRED_FIELD",
        error.NoProductMatch => "BOM_NO_PRODUCT_MATCH",
        error.CircularReference => "BOM_CIRCULAR_REFERENCE",
        else => @errorName(err),
    };
}

fn groupedBomErrorDetail(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidCsv => "CSV body is malformed or internally inconsistent.",
        error.InvalidJson => "Request body must be valid JSON.",
        error.MissingBomName => "bom_name is required.",
        error.MissingFullProductIdentifier => "full_product_identifier is required.",
        error.EmptyBomItems => "BOM payload must contain at least one component relation.",
        error.MissingRequiredField => "A required BOM field is missing.",
        error.NoProductMatch => "No Product node matches full_product_identifier.",
        error.CircularReference => "BOM contains a circular parent/child reference.",
        else => @errorName(err),
    };
}

fn groupErrorResult(
    group: anytype,
    rows_ingested: usize,
    code: []const u8,
    detail: []const u8,
    alloc: Allocator,
) !GroupedBomResult {
    return .{
        .full_product_identifier = try alloc.dupe(u8, group.full_product_identifier),
        .bom_name = try alloc.dupe(u8, group.bom_name),
        .rows_ingested = rows_ingested,
        .inserted_nodes = 0,
        .inserted_edges = 0,
            .status = .failed,
        .error_code = try alloc.dupe(u8, code),
        .error_detail = try alloc.dupe(u8, detail),
        .warnings = try alloc.alloc(BomWarning, 0),
    };
}

fn writeTempXlsx(body: []const u8, alloc: Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/rtmify-design-bom-{d}.xlsx", .{std.time.nanoTimestamp()});
    errdefer alloc.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
    return path;
}

fn findSheetRows(sheets: []const xlsx.SheetData, name: []const u8) ?[]const []const []const u8 {
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(sheet.name, name)) return sheet.rows;
    }
    return null;
}

fn upsertProductRows(db: *graph_live.GraphDb, rows: []const []const []const u8, alloc: Allocator) !void {
    if (rows.len < 2) return;
    const header = rows[0];
    const assembly_col = resolveCol(header, "assembly");
    const revision_col = resolveCol(header, "revision");
    const identifier_col = resolveCol(header, "full_identifier") orelse return;
    const description_col = resolveCol(header, "description");
    const status_col = resolveCol(header, "Product Status");

    for (rows[1..]) |row| {
        const full_identifier = std.mem.trim(u8, if (identifier_col < row.len) row[identifier_col] else "", " \r\n\t");
        if (full_identifier.len == 0) continue;
        const assembly = std.mem.trim(u8, if (assembly_col) |idx| if (idx < row.len) row[idx] else "" else "", " \r\n\t");
        const revision = std.mem.trim(u8, if (revision_col) |idx| if (idx < row.len) row[idx] else "" else "", " \r\n\t");
        const description = std.mem.trim(u8, if (description_col) |idx| if (idx < row.len) row[idx] else "" else "", " \r\n\t");
        const product_status = std.mem.trim(u8, if (status_col) |idx| if (idx < row.len) row[idx] else "" else "", " \r\n\t");

        const product_id = try std.fmt.allocPrint(alloc, "product://{s}", .{full_identifier});
        defer alloc.free(product_id);
        var props: std.ArrayList(u8) = .empty;
        defer props.deinit(alloc);
        try props.appendSlice(alloc, "{\"assembly\":");
        try shared.appendJsonStr(&props, assembly, alloc);
        try props.appendSlice(alloc, ",\"revision\":");
        try shared.appendJsonStr(&props, revision, alloc);
        try props.appendSlice(alloc, ",\"full_identifier\":");
        try shared.appendJsonStr(&props, full_identifier, alloc);
        try props.appendSlice(alloc, ",\"description\":");
        try shared.appendJsonStr(&props, description, alloc);
        try props.appendSlice(alloc, ",\"product_status\":");
        try shared.appendJsonStr(&props, product_status, alloc);
        try props.append(alloc, '}');
        try db.upsertNode(product_id, "Product", props.items, null);
    }
}

pub fn getBomJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_type_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    if (!include_obsolete and productStatusExcludedFromActiveGraph(try productStatusForIdentifier(db, full_product_identifier, alloc))) {
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

    var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_requirements, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

    var linked_tests: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_tests, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

    try buf.appendSlice(alloc, ",\"linked_requirements\":");
    try appendNodeJsonArray(&buf, linked_requirements.items, alloc);
    try buf.appendSlice(alloc, ",\"linked_tests\":");
    try appendNodeJsonArray(&buf, linked_tests.items, alloc);

    const unresolved_requirement_ids = try unresolvedTraceRefs(node.?.properties, "requirement_ids", linked_requirements.items, alloc);
    defer freeStringSlice(unresolved_requirement_ids, alloc);
    const unresolved_test_ids = try unresolvedTraceRefs(node.?.properties, "test_ids", linked_tests.items, alloc);
    defer freeStringSlice(unresolved_test_ids, alloc);
    try buf.appendSlice(alloc, ",\"unresolved_requirement_ids\":");
    try appendJsonStringArray(&buf, unresolved_requirement_ids, alloc);
    try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
    try appendJsonStringArray(&buf, unresolved_test_ids, alloc);
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
    if (!include_obsolete and productStatusExcludedFromActiveGraph(try productStatusForIdentifier(db, full_product_identifier, alloc))) {
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
        const product_status = classifyProductStatus(if (st.columnIsNull(6)) null else st.columnText(6));
        if (!include_obsolete and productStatusExcludedFromActiveGraph(product_status)) continue;
        if (!first) try buf.append(alloc, ',');
        first = false;
        const bom_id = st.columnText(0);
        const item_count = try countBomItems(db, bom_id, alloc);
        const warning_count = try countBomWarnings(db, bom_id, alloc);
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

pub fn getDesignBomItemsJson(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    if (!include_obsolete and productStatusExcludedFromActiveGraph(try productStatusForIdentifier(db, full_product_identifier, alloc))) {
        return error.NotFound;
    }
    const prefixes = try designBomPrefixes(db, full_product_identifier, bom_name, alloc);
    defer freeStringSlice(prefixes, alloc);

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
        const product_status = classifyProductStatus(if (st.columnIsNull(7)) null else st.columnText(7));
        if (!include_obsolete and productStatusExcludedFromActiveGraph(product_status)) continue;
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
        const product_status = classifyProductStatus(if (st.columnIsNull(5)) null else st.columnText(5));
        if (!include_inactive and productStatusExcludedFromGapAnalysis(product_status)) continue;
        const item_id = st.columnText(0);
        const props = st.columnText(1);
        const req_ids = try parseStringArrayProperty(props, "requirement_ids", alloc);
        defer freeStringSlice(req_ids, alloc);
        const test_ids = try parseStringArrayProperty(props, "test_ids", alloc);
        defer freeStringSlice(test_ids, alloc);

        var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
        defer shared.freeNodeList(&linked_requirements, alloc);
        try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

        var linked_tests: std.ArrayList(graph_live.Node) = .empty;
        defer shared.freeNodeList(&linked_tests, alloc);
        try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
        try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

        const unresolved_requirement_ids = try unresolvedTraceRefs(props, "requirement_ids", linked_requirements.items, alloc);
        defer freeStringSlice(unresolved_requirement_ids, alloc);
        const unresolved_test_ids = try unresolvedTraceRefs(props, "test_ids", linked_tests.items, alloc);
        defer freeStringSlice(unresolved_test_ids, alloc);

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
        try appendJsonStringArray(&buf, unresolved_requirement_ids, alloc);
        try buf.appendSlice(alloc, ",\"unresolved_test_ids\":");
        try appendJsonStringArray(&buf, unresolved_test_ids, alloc);
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
    if (!include_obsolete and productStatusExcludedFromActiveGraph(try productStatusForIdentifier(db, full_product_identifier, alloc))) {
        return error.NotFound;
    }
    const prefixes = try designBomPrefixes(db, full_product_identifier, bom_name, alloc);
    defer freeStringSlice(prefixes, alloc);

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
            try appendNodeJsonArray(&buf, linked_requirements.items, alloc);

            var linked_tests: std.ArrayList(graph_live.Node) = .empty;
            defer shared.freeNodeList(&linked_tests, alloc);
            try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
            try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);
            try buf.appendSlice(alloc, ",\"linked_tests\":");
            try appendNodeJsonArray(&buf, linked_tests.items, alloc);
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
        const product_status = classifyProductStatus(if (st.columnIsNull(5)) null else st.columnText(5));
        if (!include_obsolete and productStatusExcludedFromActiveGraph(product_status)) continue;

        const item_id = st.columnText(0);
        const properties_json = st.columnText(1);
        const counts = try traceLinkCountsForItem(db, item_id, properties_json, alloc);

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
        const product_status = classifyProductStatus(if (st.columnIsNull(4)) null else st.columnText(4));
        if (!include_obsolete and productStatusExcludedFromActiveGraph(product_status)) continue;

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
            const counts = try traceLinkCountsForItem(db, items_st.columnText(0), items_st.columnText(1), alloc);
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

fn appendNodeJsonArray(buf: *std.ArrayList(u8), nodes: []const graph_live.Node, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    for (nodes, 0..) |node, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try shared.appendNodeObject(buf, node, alloc);
    }
    try buf.append(alloc, ']');
}

fn countBomItems(db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !usize {
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

const TraceLinkCounts = struct {
    declared_requirement_count: usize = 0,
    declared_test_count: usize = 0,
    linked_requirement_count: usize = 0,
    linked_test_count: usize = 0,
    unresolved_requirement_count: usize = 0,
    unresolved_test_count: usize = 0,
};

fn traceLinkCountsForItem(
    db: *graph_live.GraphDb,
    item_id: []const u8,
    properties_json: []const u8,
    alloc: Allocator,
) !TraceLinkCounts {
    const declared_requirement_ids = try parseStringArrayProperty(properties_json, "requirement_ids", alloc);
    defer freeStringSlice(declared_requirement_ids, alloc);
    const declared_test_ids = try parseStringArrayProperty(properties_json, "test_ids", alloc);
    defer freeStringSlice(declared_test_ids, alloc);

    var linked_requirements: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_requirements, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_REQUIREMENT", "Requirement", alloc, &linked_requirements);

    var linked_tests: std.ArrayList(graph_live.Node) = .empty;
    defer shared.freeNodeList(&linked_tests, alloc);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "Test", alloc, &linked_tests);
    try shared.collectNodesViaOutgoingEdge(db, item_id, "REFERENCES_TEST", "TestGroup", alloc, &linked_tests);

    const unresolved_requirement_ids = try unresolvedTraceRefs(properties_json, "requirement_ids", linked_requirements.items, alloc);
    defer freeStringSlice(unresolved_requirement_ids, alloc);
    const unresolved_test_ids = try unresolvedTraceRefs(properties_json, "test_ids", linked_tests.items, alloc);
    defer freeStringSlice(unresolved_test_ids, alloc);

    return .{
        .declared_requirement_count = declared_requirement_ids.len,
        .declared_test_count = declared_test_ids.len,
        .linked_requirement_count = linked_requirements.items.len,
        .linked_test_count = linked_tests.items.len,
        .unresolved_requirement_count = unresolved_requirement_ids.len,
        .unresolved_test_count = unresolved_test_ids.len,
    };
}

fn countBomWarnings(db: *graph_live.GraphDb, bom_id: []const u8, alloc: Allocator) !usize {
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

fn designBomPrefixes(
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
        const bom_type: BomType = if (std.mem.eql(u8, bom_type_raw, "software")) .software else .hardware;
        try prefixes.append(alloc, try bomItemPrefix(full_product_identifier, bom_type, bom_name, alloc));
    }
    if (prefixes.items.len == 0) return error.NotFound;
    return prefixes.toOwnedSlice(alloc);
}

fn unresolvedTraceRefs(
    properties_json: []const u8,
    field_name: []const u8,
    linked_nodes: []const graph_live.Node,
    alloc: Allocator,
) ![]const []const u8 {
    const declared = try parseStringArrayProperty(properties_json, field_name, alloc);
    errdefer freeStringSlice(declared, alloc);

    var unresolved: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unresolved.items) |item| alloc.free(item);
        unresolved.deinit(alloc);
    }
    for (declared) |declared_id| {
        var matched = false;
        for (linked_nodes) |node| {
            if (std.mem.eql(u8, node.id, declared_id)) {
                matched = true;
                break;
            }
        }
        if (!matched) try unresolved.append(alloc, try alloc.dupe(u8, declared_id));
    }
    freeStringSlice(declared, alloc);
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
    options: IngestOptions,
    alloc: Allocator,
) (BomError || db_mod.DbError || error{OutOfMemory})!BomIngestResponse {
    try validateNoCycles(prepared.submission.occurrences);

    const product_id = try std.fmt.allocPrint(alloc, "product://{s}", .{prepared.submission.full_product_identifier});
    defer alloc.free(product_id);
    const product_node = try db.getNode(product_id, alloc);
    defer if (product_node) |node| shared.freeNode(node, alloc);
    if (product_node == null and !options.allow_missing_product) {
        return if (prepared.submission.bom_type == .hardware) error.NoProductMatch else error.SbomUnresolvableRoot;
    }
    if (product_node == null) {
        const subject = try alloc.dupe(u8, prepared.submission.full_product_identifier);
        defer alloc.free(subject);
        const message = try std.fmt.allocPrint(alloc, "No Product node matches full_product_identifier '{s}'", .{prepared.submission.full_product_identifier});
        defer alloc.free(message);
        try appendWarning(&prepared.warnings, "BOM_NO_PRODUCT_MATCH", message, subject, alloc);
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
    try db.addNode(bom_id, "DesignBOM", bom_props, null);

    if (product_node != null) {
        const has_bom_props = try alloc.dupe(u8, "{}");
        defer alloc.free(has_bom_props);
        try db.addEdgeWithProperties(product_id, bom_id, "HAS_DESIGN_BOM", has_bom_props);
    }

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

    var trace_edges_inserted: usize = 0;
    var warning_seen = std.StringHashMap(void).init(alloc);
    defer {
        var it = warning_seen.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        warning_seen.deinit();
    }
    item_it = item_specs.iterator();
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
        trace_edges_inserted += try appendBomTraceEdges(
            db,
            item_id,
            entry.value_ptr.*,
            prepared.submission.source_format,
            options,
            &prepared.warnings,
            &warning_seen,
            alloc,
        );
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
        .inserted_edges = (if (product_node != null) @as(usize, 1) else 0) + prepared.submission.occurrences.len + trace_edges_inserted,
        .warnings = try prepared.warnings.toOwnedSlice(alloc),
    };
}

fn appendBomTraceEdges(
    db: *graph_live.GraphDb,
    item_id: []const u8,
    item: ItemSpec,
    source_format: BomFormat,
    options: IngestOptions,
    warnings: *std.ArrayList(BomWarning),
    warning_seen: *std.StringHashMap(void),
    alloc: Allocator,
) !usize {
    var inserted: usize = 0;
    const item_subject = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ item.part, item.revision });
    defer alloc.free(item_subject);

    if (item.requirement_ids) |refs| {
        for (refs) |req_id| {
            if (try nodeExistsOfType(db, req_id, "Requirement")) {
                const edge_props = try referenceEdgePropertiesJson(source_format, "requirement_ids", alloc);
                defer alloc.free(edge_props);
                try db.addEdgeWithProperties(item_id, req_id, "REFERENCES_REQUIREMENT", edge_props);
                inserted += 1;
            } else {
                try appendUnresolvedTraceRefWarning(
                    warnings,
                    warning_seen,
                    options.unresolved_requirement_warning_code,
                    options.warning_subject_label,
                    item_subject,
                    "Requirement",
                    req_id,
                    alloc,
                );
            }
        }
    }

    if (item.test_ids) |refs| {
        for (refs) |test_id| {
            if (try nodeExistsOfType(db, test_id, "Test") or try nodeExistsOfType(db, test_id, "TestGroup")) {
                const edge_props = try referenceEdgePropertiesJson(source_format, "test_ids", alloc);
                defer alloc.free(edge_props);
                try db.addEdgeWithProperties(item_id, test_id, "REFERENCES_TEST", edge_props);
                inserted += 1;
            } else {
                try appendUnresolvedTraceRefWarning(
                    warnings,
                    warning_seen,
                    options.unresolved_test_warning_code,
                    options.warning_subject_label,
                    item_subject,
                    "Test/TestGroup",
                    test_id,
                    alloc,
                );
            }
        }
    }

    return inserted;
}

fn appendUnresolvedTraceRefWarning(
    warnings: *std.ArrayList(BomWarning),
    warning_seen: *std.StringHashMap(void),
    code: []const u8,
    subject_label: []const u8,
    item_subject: []const u8,
    ref_type: []const u8,
    ref_id: []const u8,
    alloc: Allocator,
) !void {
    const dedupe_key = try std.fmt.allocPrint(alloc, "{s}|{s}|{s}", .{ item_subject, code, ref_id });
    if (warning_seen.contains(dedupe_key)) {
        alloc.free(dedupe_key);
        return;
    }
    try warning_seen.put(dedupe_key, {});

    const message = try std.fmt.allocPrint(alloc, "{s} '{s}' references missing {s} '{s}'", .{ subject_label, item_subject, ref_type, ref_id });
    defer alloc.free(message);
    try appendWarning(warnings, code, message, item_subject, alloc);
}

fn nodeExistsOfType(db: *graph_live.GraphDb, node_id: []const u8, node_type: []const u8) !bool {
    var st = try db.db.prepare(
        \\SELECT 1
        \\FROM nodes
        \\WHERE id=? AND type=?
        \\LIMIT 1
    );
    defer st.finalize();
    try st.bindText(1, node_id);
    try st.bindText(2, node_type);
    return try st.step();
}

fn referenceEdgePropertiesJson(source_format: BomFormat, declared_field: []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"relation_source\":");
    try shared.appendJsonStr(&buf, bomFormatString(source_format), alloc);
    try buf.appendSlice(alloc, ",\"declared_field\":");
    try shared.appendJsonStr(&buf, declared_field, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
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
    if (std.mem.endsWith(u8, name, ".xlsx")) return error.UnsupportedFormat;
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
    const full_identifier_col = resolveCol(header, "full_identifier") orelse resolveCol(header, "full_product_identifier") orelse return error.MissingRequiredField;
    const parent_part_col = resolveCol(header, "parent_part") orelse return error.MissingRequiredField;
    const parent_revision_col = resolveCol(header, "parent_revision");
    const child_part_col = resolveCol(header, "child_part") orelse return error.MissingRequiredField;
    const child_revision_col = resolveCol(header, "child_revision");
    const quantity_col = resolveCol(header, "quantity") orelse return error.MissingRequiredField;
    const ref_designator_col = resolveCol(header, "ref_designator");
    const description_col = resolveCol(header, "description");
    const supplier_col = resolveCol(header, "supplier");
    const category_col = resolveCol(header, "category");
    const requirement_ids_col = resolveCol(header, "requirement_ids");
    const requirement_id_col = resolveCol(header, "requirement_id");
    const test_ids_col = resolveCol(header, "test_ids");
    const test_id_col = resolveCol(header, "test_id");

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
        const parent_revision = try defaultCellAt(row, parent_revision_col, "-", alloc);
        defer alloc.free(parent_revision);
        const child_part = try cellAt(row, child_part_col, alloc);
        defer alloc.free(child_part);
        const child_revision = try defaultCellAt(row, child_revision_col, "-", alloc);
        defer alloc.free(child_revision);
        const quantity = try cellAt(row, quantity_col, alloc);
        defer alloc.free(quantity);
        if (bom_name.len == 0) return error.MissingBomName;
        if (full_identifier.len == 0) return error.MissingFullProductIdentifier;
        if (parent_part.len == 0 or child_part.len == 0 or quantity.len == 0) {
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
                .supplier = try optionalCellAt(row, supplier_col, alloc),
                .requirement_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    if (requirement_ids_col) |idx| {
                        const parsed = try parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| freeStringSlice(items, alloc);
                        try mergeTraceRefLists(&refs, parsed, alloc);
                    }
                    if (requirement_id_col) |idx| {
                        const parsed = try parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| freeStringSlice(items, alloc);
                        try mergeTraceRefLists(&refs, parsed, alloc);
                    }
                    break :blk refs;
                },
                .test_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    if (test_ids_col) |idx| {
                        const parsed = try parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| freeStringSlice(items, alloc);
                        try mergeTraceRefLists(&refs, parsed, alloc);
                    }
                    if (test_id_col) |idx| {
                        const parsed = try parseTraceRefCell(if (idx < row.len) row[idx] else "", alloc);
                        errdefer if (parsed) |items| freeStringSlice(items, alloc);
                        try mergeTraceRefLists(&refs, parsed, alloc);
                    }
                    break :blk refs;
                },
                .purl = null,
                .license = null,
                .hashes_json = null,
                .safety_class = null,
                .known_anomalies = null,
                .anomaly_evaluation = null,
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
        const parent_revision = defaultJsonString(json_util.getString(item, "parent_revision"), "-");
        const child_part = json_util.getString(item, "child_part") orelse return error.MissingRequiredField;
        const child_revision = defaultJsonString(json_util.getString(item, "child_revision"), "-");
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
                .supplier = if (json_util.getString(item, "supplier")) |value| try alloc.dupe(u8, value) else null,
                .requirement_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    const plural = try parseTraceRefJsonField(item, "requirement_ids", alloc);
                    errdefer if (plural) |items| freeStringSlice(items, alloc);
                    try mergeTraceRefLists(&refs, plural, alloc);
                    const singular = try parseTraceRefJsonField(item, "requirement_id", alloc);
                    errdefer if (singular) |items| freeStringSlice(items, alloc);
                    try mergeTraceRefLists(&refs, singular, alloc);
                    break :blk refs;
                },
                .test_ids = blk: {
                    var refs: ?[]const []const u8 = null;
                    const plural = try parseTraceRefJsonField(item, "test_ids", alloc);
                    errdefer if (plural) |items| freeStringSlice(items, alloc);
                    try mergeTraceRefLists(&refs, plural, alloc);
                    const singular = try parseTraceRefJsonField(item, "test_id", alloc);
                    errdefer if (singular) |items| freeStringSlice(items, alloc);
                    try mergeTraceRefLists(&refs, singular, alloc);
                    break :blk refs;
                },
                .purl = null,
                .license = null,
                .hashes_json = null,
                .safety_class = null,
                .known_anomalies = null,
                .anomaly_evaluation = null,
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
        if (relation.supplier) |value| {
            if (occurrence.supplier) |existing| alloc.free(existing);
            occurrence.supplier = try alloc.dupe(u8, value);
        }
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
    try buf.appendSlice(alloc, ",\"bom_class\":");
    try shared.appendJsonStr(&buf, "design", alloc);
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
    try buf.appendSlice(alloc, ",\"supplier\":");
    try shared.appendJsonStrOpt(&buf, item.supplier, alloc);
    try buf.appendSlice(alloc, ",\"requirement_ids\":");
    try appendJsonStringArray(&buf, item.requirement_ids, alloc);
    try buf.appendSlice(alloc, ",\"test_ids\":");
    try appendJsonStringArray(&buf, item.test_ids, alloc);
    try buf.appendSlice(alloc, ",\"purl\":");
    try shared.appendJsonStrOpt(&buf, item.purl, alloc);
    try buf.appendSlice(alloc, ",\"license\":");
    try shared.appendJsonStrOpt(&buf, item.license, alloc);
    try buf.appendSlice(alloc, ",\"safety_class\":");
    try shared.appendJsonStrOpt(&buf, item.safety_class, alloc);
    try buf.appendSlice(alloc, ",\"known_anomalies\":");
    try shared.appendJsonStrOpt(&buf, item.known_anomalies, alloc);
    try buf.appendSlice(alloc, ",\"anomaly_evaluation\":");
    try shared.appendJsonStrOpt(&buf, item.anomaly_evaluation, alloc);
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
        .supplier = if (item.supplier) |value| try alloc.dupe(u8, value) else null,
        .requirement_ids = if (item.requirement_ids) |values| try dupStringSlice(values, alloc) else null,
        .test_ids = if (item.test_ids) |values| try dupStringSlice(values, alloc) else null,
        .quantity = null,
        .ref_designator = null,
        .purl = if (item.purl) |value| try alloc.dupe(u8, value) else null,
        .license = if (item.license) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = if (item.hashes_json) |value| try alloc.dupe(u8, value) else null,
        .safety_class = if (item.safety_class) |value| try alloc.dupe(u8, value) else null,
        .known_anomalies = if (item.known_anomalies) |value| try alloc.dupe(u8, value) else null,
        .anomaly_evaluation = if (item.anomaly_evaluation) |value| try alloc.dupe(u8, value) else null,
    };
}

fn ensureItemSpec(items: *std.StringHashMap(ItemSpec), key: []const u8, part: []const u8, revision: []const u8, alloc: Allocator) !void {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const gop = try items.getOrPut(key_copy);
    if (gop.found_existing) {
        alloc.free(key_copy);
        return;
    }
    gop.key_ptr.* = key_copy;
    gop.value_ptr.* = .{
        .part = try alloc.dupe(u8, part),
        .revision = try alloc.dupe(u8, revision),
        .requirement_ids = null,
        .test_ids = null,
    };
}

fn upsertItemSpec(items: *std.StringHashMap(ItemSpec), key: []const u8, occurrence: BomOccurrenceInput, alloc: Allocator) !void {
    try upsertItemSpecExplicit(items, key, .{
        .part = try alloc.dupe(u8, occurrence.child_part),
        .revision = try alloc.dupe(u8, occurrence.child_revision),
        .description = if (occurrence.description) |value| try alloc.dupe(u8, value) else null,
        .category = if (occurrence.category) |value| try alloc.dupe(u8, value) else null,
        .supplier = if (occurrence.supplier) |value| try alloc.dupe(u8, value) else null,
        .requirement_ids = if (occurrence.requirement_ids) |values| try dupStringSlice(values, alloc) else null,
        .test_ids = if (occurrence.test_ids) |values| try dupStringSlice(values, alloc) else null,
        .purl = if (occurrence.purl) |value| try alloc.dupe(u8, value) else null,
        .license = if (occurrence.license) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = if (occurrence.hashes_json) |value| try alloc.dupe(u8, value) else null,
        .safety_class = if (occurrence.safety_class) |value| try alloc.dupe(u8, value) else null,
        .known_anomalies = if (occurrence.known_anomalies) |value| try alloc.dupe(u8, value) else null,
        .anomaly_evaluation = if (occurrence.anomaly_evaluation) |value| try alloc.dupe(u8, value) else null,
    }, alloc);
}

fn upsertItemSpecExplicit(items: *std.StringHashMap(ItemSpec), key: []const u8, incoming: ItemSpec, alloc: Allocator) !void {
    const key_copy = try alloc.dupe(u8, key);
    errdefer alloc.free(key_copy);
    const gop = try items.getOrPut(key_copy);
    if (!gop.found_existing) {
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = incoming;
        return;
    }
    alloc.free(key_copy);
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
    if (incoming.supplier) |value| {
        if (gop.value_ptr.supplier == null) {
            gop.value_ptr.supplier = value;
        } else {
            alloc.free(value);
        }
    }
    try mergeTraceRefLists(&gop.value_ptr.requirement_ids, incoming.requirement_ids, alloc);
    try mergeTraceRefLists(&gop.value_ptr.test_ids, incoming.test_ids, alloc);
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
    if (incoming.safety_class) |value| {
        if (gop.value_ptr.safety_class == null) {
            gop.value_ptr.safety_class = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.known_anomalies) |value| {
        if (gop.value_ptr.known_anomalies == null) {
            gop.value_ptr.known_anomalies = value;
        } else {
            alloc.free(value);
        }
    }
    if (incoming.anomaly_evaluation) |value| {
        if (gop.value_ptr.anomaly_evaluation == null) {
            gop.value_ptr.anomaly_evaluation = value;
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
        if (entry.value_ptr.supplier) |value| alloc.free(value);
        if (entry.value_ptr.requirement_ids) |values| freeStringSlice(values, alloc);
        if (entry.value_ptr.test_ids) |values| freeStringSlice(values, alloc);
        if (entry.value_ptr.purl) |value| alloc.free(value);
        if (entry.value_ptr.license) |value| alloc.free(value);
        if (entry.value_ptr.hashes_json) |value| alloc.free(value);
        if (entry.value_ptr.safety_class) |value| alloc.free(value);
        if (entry.value_ptr.known_anomalies) |value| alloc.free(value);
        if (entry.value_ptr.anomaly_evaluation) |value| alloc.free(value);
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
        .supplier = null,
        .requirement_ids = null,
        .test_ids = null,
        .purl = if (json_util.getString(component, "purl")) |value| try alloc.dupe(u8, value) else null,
        .license = try cyclonedxLicense(component, alloc),
        .hashes_json = try hashesJson(component, "hashes", alloc),
        .safety_class = null,
        .known_anomalies = null,
        .anomaly_evaluation = null,
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
        .supplier = null,
        .requirement_ids = null,
        .test_ids = null,
        .purl = try spdxPurl(pkg, alloc),
        .license = if (json_util.getString(pkg, "licenseConcluded")) |value| try alloc.dupe(u8, value) else null,
        .hashes_json = try hashesJson(pkg, "checksums", alloc),
        .safety_class = null,
        .known_anomalies = null,
        .anomaly_evaluation = null,
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

fn defaultCellAt(row: []const []const u8, idx: ?usize, default_value: []const u8, alloc: Allocator) ![]u8 {
    if (idx == null or idx.? >= row.len) return alloc.dupe(u8, default_value);
    const value = std.mem.trim(u8, row[idx.?], " ");
    if (value.len == 0) return alloc.dupe(u8, default_value);
    return alloc.dupe(u8, value);
}

fn optionalCellAt(row: []const []const u8, idx: ?usize, alloc: Allocator) !?[]const u8 {
    if (idx == null or idx.? >= row.len) return null;
    const value = std.mem.trim(u8, row[idx.?], " ");
    if (value.len == 0) return null;
    const dup = try alloc.dupe(u8, value);
    return dup;
}

fn defaultJsonString(value: ?[]const u8, default_value: []const u8) []const u8 {
    if (value) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r\n\t");
        if (trimmed.len > 0) return trimmed;
    }
    return default_value;
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
        .xlsx => "xlsx",
        .sheets => "sheets",
        .soup_json => "soup_json",
        .soup_xlsx => "soup_xlsx",
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

test "hardware csv trace refs create BOM item properties and typed edges" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Req 2\"}", null);
    try db.addNode("TEST-001", "Test", "{\"name\":\"Test 1\"}", null);

    var ingest = try ingestHttpBody(
        &db,
        "text/csv",
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,requirement_ids,test_id
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4,"REQ-001;REQ-002",TEST-001
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ingest.warnings.len);

    const item_id = "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A";
    const item_json = try getBomItemJson(&db, item_id, testing.allocator);
    defer testing.allocator.free(item_json);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"requirement_ids\":[\"REQ-001\",\"REQ-002\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"test_ids\":[\"TEST-001\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"linked_requirements\":[") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-002\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"linked_tests\":[") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"TEST-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_requirement_ids\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_test_ids\":[]") != null);
}

test "hardware json unresolved trace refs warn and preserve declared ids" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req\"}", null);

    var ingest = try ingestHttpBody(
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
        \\      "quantity": "4",
        \\      "requirement_ids": "REQ-001|REQ-404",
        \\      "test_ids": ["TEST-404"]
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), ingest.warnings.len);
    try testing.expectEqualStrings("BOM_UNRESOLVED_REQUIREMENT_REF", ingest.warnings[0].code);
    try testing.expectEqualStrings("BOM_UNRESOLVED_TEST_REF", ingest.warnings[1].code);

    const item_id = "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A";
    const item_json = try getBomItemJson(&db, item_id, testing.allocator);
    defer testing.allocator.free(item_json);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"requirement_ids\":[\"REQ-001\",\"REQ-404\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"test_ids\":[\"TEST-404\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_requirement_ids\":[\"REQ-404\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_test_ids\":[\"TEST-404\"]") != null);
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

    const bom_json = try getBomJson(&db, "ASM-1000-REV-C", null, null, false, testing.allocator);
    defer testing.allocator.free(bom_json);
    try testing.expect(std.mem.indexOf(u8, bom_json, "R0402-1K") != null);
    try testing.expect(std.mem.indexOf(u8, bom_json, "C0805-10UF") == null);
    try testing.expect(std.mem.indexOf(u8, bom_json, "\"bom_name\":\"firmware\"") != null);
}

test "re-ingesting same bom key replaces stale BOM trace edges" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req 1\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Req 2\"}", null);

    var first = try ingestHttpBody(
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
        \\      "quantity": "4",
        \\      "requirement_id": "REQ-001"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer first.deinit(testing.allocator);

    var second = try ingestHttpBody(
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
        \\      "quantity": "4",
        \\      "requirement_id": "REQ-002"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer second.deinit(testing.allocator);

    const item_json = try getBomItemJson(&db, "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A", testing.allocator);
    defer testing.allocator.free(item_json);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-002\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-001\"") == null);
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

test "listDesignBomsJson excludes obsolete products by default" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\",\"product_status\":\"Active\"}", null);
    try db.addNode("product://ASM-2000-REV-A", "Product", "{\"full_identifier\":\"ASM-2000-REV-A\",\"product_status\":\"Obsolete\"}", null);

    var active_ingest = try ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {"parent_part":"ASM-1000","child_part":"R1","quantity":"1"}
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer active_ingest.deinit(testing.allocator);
    var obsolete_ingest = try ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-2000-REV-A",
        \\  "bom_items": [
        \\    {"parent_part":"ASM-2000","child_part":"R2","quantity":"1"}
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer obsolete_ingest.deinit(testing.allocator);

    const filtered = try listDesignBomsJson(&db, null, null, false, testing.allocator);
    defer testing.allocator.free(filtered);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-1000-REV-C\"") != null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-2000-REV-A\"") == null);

    const all = try listDesignBomsJson(&db, null, null, true, testing.allocator);
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "\"ASM-2000-REV-A\"") != null);
    try testing.expect(std.mem.indexOf(u8, all, "\"product_status\":\"Obsolete\"") != null);
}

test "bomGapsJson excludes superseded and obsolete products by default" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\",\"product_status\":\"Active\"}", null);
    try db.addNode("product://ASM-2000-REV-A", "Product", "{\"full_identifier\":\"ASM-2000-REV-A\",\"product_status\":\"Superseded\"}", null);
    try db.addNode("product://ASM-3000-REV-A", "Product", "{\"full_identifier\":\"ASM-3000-REV-A\",\"product_status\":\"Obsolete\"}", null);

    inline for ([_][]const u8{ "ASM-1000-REV-C", "ASM-2000-REV-A", "ASM-3000-REV-A" }) |product_id| {
        const body = try std.fmt.allocPrint(
            testing.allocator,
            \\{{
            \\  "bom_name": "pcba",
            \\  "full_product_identifier": "{s}",
            \\  "bom_items": [
            \\    {{"parent_part":"ASSY","child_part":"FBRFET-3300","quantity":"1","requirement_id":"REQ-404"}}
            \\  ]
            \\}}
        ,
            .{product_id},
        );
        defer testing.allocator.free(body);
        var ingest = try ingestHttpBody(&db, "application/json", body, testing.allocator);
        defer ingest.deinit(testing.allocator);
    }

    const filtered = try bomGapsJson(&db, null, null, false, testing.allocator);
    defer testing.allocator.free(filtered);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-1000-REV-C\"") != null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-2000-REV-A\"") == null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-3000-REV-A\"") == null);

    const all = try bomGapsJson(&db, null, null, true, testing.allocator);
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "\"ASM-2000-REV-A\"") != null);
    try testing.expect(std.mem.indexOf(u8, all, "\"ASM-3000-REV-A\"") != null);
}

const testing = std.testing;
