const std = @import("std");
const db_mod = @import("../db.zig");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const xlsx = @import("rtmify").xlsx;
const types = @import("types.zig");
const ids = @import("ids.zig");
const util = @import("util.zig");
const trace_refs = @import("trace_refs.zig");
const item_specs = @import("item_specs.zig");
const prepare = @import("prepare.zig");
const prepare_csv = @import("prepare_csv.zig");
const query_metrics = @import("query_metrics.zig");

pub const Allocator = std.mem.Allocator;

pub fn ingestHttpBody(
    db: *graph_live.GraphDb,
    content_type: ?[]const u8,
    body: []const u8,
    alloc: Allocator,
) (types.BomError || db_mod.DbError || error{OutOfMemory})!types.BomIngestResponse {
    var prepared = try prepare.prepareHttpBody(content_type, body, alloc);
    defer prepared.deinit(alloc);
    return ingestPrepared(db, &prepared, .{}, alloc);
}

pub fn ingestInboxFile(
    db: *graph_live.GraphDb,
    name: []const u8,
    body: []const u8,
    alloc: Allocator,
) (types.BomError || db_mod.DbError || error{OutOfMemory})!types.BomIngestResponse {
    var prepared = try prepare.prepareInboxFile(name, body, alloc);
    defer prepared.deinit(alloc);
    return ingestPrepared(db, &prepared, .{}, alloc);
}

pub fn ingestXlsxBody(
    db: *graph_live.GraphDb,
    body: []const u8,
    alloc: Allocator,
) anyerror!types.GroupedBomIngestResponse {
    const temp_path = try util.writeTempXlsx(body, alloc);
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
) anyerror!types.GroupedBomIngestResponse {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sheets = try xlsx.parse(arena, path);
    const design_bom_rows = util.findSheetRows(sheets, "Design BOM") orelse return error.MissingDesignBomTab;
    return ingestDesignBomRows(db, design_bom_rows, util.findSheetRows(sheets, "Product"), .xlsx, alloc);
}

pub fn ingestSubmission(
    db: *graph_live.GraphDb,
    submission: types.BomSubmission,
    warnings: std.ArrayList(types.BomWarning),
    options: types.IngestOptions,
    alloc: Allocator,
) (types.BomError || db_mod.DbError || error{OutOfMemory})!types.BomIngestResponse {
    var prepared = types.PreparedBom{
        .submission = submission,
        .warnings = warnings,
    };
    defer prepared.deinit(alloc);
    return ingestPrepared(db, &prepared, options, alloc);
}

pub fn ingestDesignBomRows(
    db: *graph_live.GraphDb,
    design_bom_rows: []const []const []const u8,
    product_rows: ?[]const []const []const u8,
    source_format: types.BomFormat,
    alloc: Allocator,
) (types.BomError || db_mod.DbError || error{OutOfMemory})!types.GroupedBomIngestResponse {
    if (product_rows) |rows| try upsertProductRows(db, rows, alloc);
    if (design_bom_rows.len < 2) return .{ .groups = try alloc.alloc(types.GroupedBomResult, 0) };

    const header = design_bom_rows[0];
    const bom_name_col = util.resolveCol(header, "bom_name") orelse return error.MissingRequiredField;
    const full_identifier_col = util.resolveCol(header, "full_product_identifier") orelse util.resolveCol(header, "full_identifier") orelse return error.MissingRequiredField;

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

    var results: std.ArrayList(types.GroupedBomResult) = .empty;
    errdefer {
        for (results.items) |*result| result.deinit(alloc);
        results.deinit(alloc);
    }

    var it = groups.iterator();
    while (it.next()) |entry| {
        const csv_body = try util.groupedRowsToCsv(header, entry.value_ptr.rows.items, alloc);
        defer alloc.free(csv_body);

        var prepared = prepare_csv.prepareHardwareCsv(csv_body, alloc) catch |err| switch (err) {
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
            .warnings = try util.dupWarnings(ingest.warnings, alloc),
        });
    }

    return .{ .groups = try results.toOwnedSlice(alloc) };
}

pub fn ingestPrepared(
    db: *graph_live.GraphDb,
    prepared: *types.PreparedBom,
    options: types.IngestOptions,
    alloc: Allocator,
) (types.BomError || db_mod.DbError || error{OutOfMemory})!types.BomIngestResponse {
    try item_specs.validateNoCycles(prepared.submission.occurrences);

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
        try util.appendWarning(&prepared.warnings, "BOM_NO_PRODUCT_MATCH", message, subject, alloc);
    }

    const bom_id = try ids.bomNodeId(prepared.submission.full_product_identifier, prepared.submission.bom_type, prepared.submission.bom_name, alloc);
    defer alloc.free(bom_id);
    const bom_item_prefix = try ids.bomItemPrefix(prepared.submission.full_product_identifier, prepared.submission.bom_type, prepared.submission.bom_name, alloc);
    defer alloc.free(bom_item_prefix);

    var item_map = std.StringHashMap(types.ItemSpec).init(alloc);
    defer item_specs.deinitItemMap(&item_map, alloc);
    for (prepared.submission.occurrences) |occurrence| {
        const child_key = try ids.partRevisionKey(occurrence.child_part, occurrence.child_revision, alloc);
        defer alloc.free(child_key);
        try item_specs.upsertItemSpec(&item_map, child_key, occurrence, alloc);
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

    var item_it = item_map.iterator();
    while (item_it.next()) |entry| {
        const item_id = try ids.bomItemNodeId(
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
    item_it = item_map.iterator();
    while (item_it.next()) |entry| {
        const item_id = try ids.bomItemNodeId(
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
        const child_id = try ids.bomItemNodeId(
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
            const parent = try ids.splitPartRevisionKey(parent_key, alloc);
            defer parent.deinit(alloc);
            const parent_id = try ids.bomItemNodeId(
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
        .inserted_nodes = 1 + item_map.count(),
        .inserted_edges = (if (product_node != null) @as(usize, 1) else 0) + prepared.submission.occurrences.len + trace_edges_inserted,
        .warnings = try prepared.warnings.toOwnedSlice(alloc),
    };
}

pub fn appendBomTraceEdges(
    db: *graph_live.GraphDb,
    item_id: []const u8,
    item: types.ItemSpec,
    source_format: types.BomFormat,
    options: types.IngestOptions,
    warnings: *std.ArrayList(types.BomWarning),
    warning_seen: *std.StringHashMap(void),
    alloc: Allocator,
) !usize {
    var inserted: usize = 0;
    const item_subject = try std.fmt.allocPrint(alloc, "{s}@{s}", .{ item.part, item.revision });
    defer alloc.free(item_subject);

    if (item.requirement_ids) |refs| {
        for (refs) |req_id| {
            if (try nodeExistsOfType(db, req_id, "Requirement")) {
                const edge_props = try trace_refs.referenceEdgePropertiesJson(source_format, "requirement_ids", alloc);
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
                const edge_props = try trace_refs.referenceEdgePropertiesJson(source_format, "test_ids", alloc);
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

pub fn appendUnresolvedTraceRefWarning(
    warnings: *std.ArrayList(types.BomWarning),
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
    try util.appendWarning(warnings, code, message, item_subject, alloc);
}

pub fn nodeExistsOfType(db: *graph_live.GraphDb, node_id: []const u8, node_type: []const u8) !bool {
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

pub fn upsertProductRows(db: *graph_live.GraphDb, rows: []const []const []const u8, alloc: Allocator) !void {
    if (rows.len < 2) return;
    const header = rows[0];
    const assembly_col = util.resolveCol(header, "assembly");
    const revision_col = util.resolveCol(header, "revision");
    const identifier_col = util.resolveCol(header, "full_identifier") orelse return;
    const description_col = util.resolveCol(header, "description");
    const status_col = util.resolveCol(header, "Product Status");

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

pub fn groupedBomErrorCode(err: anyerror) []const u8 {
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

pub fn groupedBomErrorDetail(err: anyerror) []const u8 {
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

pub fn groupErrorResult(
    group: anytype,
    rows_ingested: usize,
    code: []const u8,
    detail: []const u8,
    alloc: Allocator,
) !types.GroupedBomResult {
    return .{
        .full_product_identifier = try alloc.dupe(u8, group.full_product_identifier),
        .bom_name = try alloc.dupe(u8, group.bom_name),
        .rows_ingested = rows_ingested,
        .inserted_nodes = 0,
        .inserted_edges = 0,
        .status = .failed,
        .error_code = try alloc.dupe(u8, code),
        .error_detail = try alloc.dupe(u8, detail),
        .warnings = try alloc.alloc(types.BomWarning, 0),
    };
}

pub fn deleteExistingBom(db: *graph_live.GraphDb, bom_id: []const u8, bom_item_prefix: []const u8) !void {
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

pub fn bomPropertiesJson(submission: types.BomSubmission, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, submission.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, submission.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"bom_type\":");
    try shared.appendJsonStr(&buf, ids.bomTypeString(submission.bom_type), alloc);
    try buf.appendSlice(alloc, ",\"bom_class\":");
    try shared.appendJsonStr(&buf, "design", alloc);
    try buf.appendSlice(alloc, ",\"source_format\":");
    try shared.appendJsonStr(&buf, ids.bomFormatString(submission.source_format), alloc);
    try std.fmt.format(buf.writer(alloc), ",\"ingested_at\":{d}}}", .{std.time.timestamp()});
    return alloc.dupe(u8, buf.items);
}

pub fn itemPropertiesJson(item: types.ItemSpec, alloc: Allocator) ![]const u8 {
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
    try util.appendJsonStringArray(&buf, item.requirement_ids, alloc);
    try buf.appendSlice(alloc, ",\"test_ids\":");
    try util.appendJsonStringArray(&buf, item.test_ids, alloc);
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

pub fn containsEdgePropertiesJson(occurrence: types.BomOccurrenceInput, source_format: types.BomFormat, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"quantity\":");
    try shared.appendJsonStrOpt(&buf, occurrence.quantity, alloc);
    try buf.appendSlice(alloc, ",\"ref_designator\":");
    try shared.appendJsonStrOpt(&buf, occurrence.ref_designator, alloc);
    try buf.appendSlice(alloc, ",\"supplier\":");
    try shared.appendJsonStrOpt(&buf, occurrence.supplier, alloc);
    try buf.appendSlice(alloc, ",\"relation_source\":");
    try shared.appendJsonStr(&buf, ids.bomFormatString(source_format), alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}
