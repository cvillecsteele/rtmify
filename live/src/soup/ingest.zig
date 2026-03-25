const std = @import("std");
const Allocator = std.mem.Allocator;

const bom = @import("../bom.zig");
const db_mod = @import("../db.zig");
const graph_live = @import("../graph_live.zig");
const json_util = @import("../json_util.zig");
const prepare_json = @import("prepare_json.zig");
const prepare_xlsx = @import("prepare_xlsx.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const xlsx = @import("rtmify").xlsx;

pub fn ingestJsonBody(
    db: *graph_live.GraphDb,
    body: []const u8,
    alloc: Allocator,
) (bom.BomError || db_mod.DbError || error{ OutOfMemory, MissingSoupTab, InvalidXlsx })!types.SoupIngestResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    var prepared = try prepare_json.parseSoupJson(parsed.value, alloc);
    errdefer prepared.deinit(alloc);
    return ingestPreparedSoup(db, &prepared, .soup_json, alloc);
}

pub fn ingestXlsxBody(
    db: *graph_live.GraphDb,
    body: []const u8,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    alloc: Allocator,
) anyerror!types.SoupIngestResponse {
    const temp_path = try util.writeTempXlsx(body, alloc);
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
) anyerror!types.SoupIngestResponse {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sheets = try xlsx.parse(arena_state.allocator(), path);
    const rows = util.findSheetRowsTrimmed(sheets, "SOUP Components") orelse return error.MissingSoupTab;

    var prepared = try prepare_xlsx.parseSoupRows(rows, full_product_identifier, bom_name_override, .soup_xlsx, alloc);
    errdefer prepared.deinit(alloc);
    return ingestPreparedSoup(db, &prepared, .soup_xlsx, alloc);
}

pub fn ingestXlsxInboxPath(
    db: *graph_live.GraphDb,
    path: []const u8,
    full_product_identifier: []const u8,
    alloc: Allocator,
) anyerror!types.SoupIngestResponse {
    return ingestXlsxPath(db, path, full_product_identifier, null, alloc);
}

pub fn ingestSheetRows(
    db: *graph_live.GraphDb,
    rows: []const []const []const u8,
    full_product_identifier: []const u8,
    bom_name_override: ?[]const u8,
    alloc: Allocator,
) !types.SoupIngestResponse {
    var prepared = try prepare_xlsx.parseSoupRows(rows, full_product_identifier, bom_name_override, .sheets, alloc);
    errdefer prepared.deinit(alloc);
    return ingestPreparedSoup(db, &prepared, .sheets, alloc);
}

fn ingestPreparedSoup(
    db: *graph_live.GraphDb,
    prepared: *types.ParseResult,
    source_format: bom.BomFormat,
    alloc: Allocator,
) !types.SoupIngestResponse {
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

const testing = std.testing;
const shared = @import("../routes/shared.zig");

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
