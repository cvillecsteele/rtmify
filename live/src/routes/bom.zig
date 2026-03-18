const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const bom = @import("../bom.zig");
const test_results_auth = @import("../test_results_auth.zig");
const shared = @import("shared.zig");

fn validationErrorJson(code: []const u8, detail: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"error\":");
    try shared.appendJsonStr(&buf, code, alloc);
    try buf.appendSlice(alloc, ",\"detail\":");
    try shared.appendJsonStr(&buf, detail, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

fn ingestErrorResponse(err: anyerror, alloc: Allocator) !shared.JsonRouteResponse {
    return switch (err) {
        error.UnsupportedContentType => shared.jsonRouteResponse(
            .unsupported_media_type,
            try validationErrorJson("unsupported_content_type", "Use application/json or raw text/csv.", alloc),
            false,
        ),
        error.UnsupportedFormat => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("unsupported_bom_format", "Could not classify the BOM payload.", alloc),
            false,
        ),
        error.InvalidJson => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("invalid_json", "Request body must be valid JSON.", alloc),
            false,
        ),
        error.InvalidCsv => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("invalid_csv", "CSV body is malformed or internally inconsistent.", alloc),
            false,
        ),
        error.MissingBomName => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_bom_name", "bom_name is required.", alloc),
            false,
        ),
        error.MissingFullProductIdentifier => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_full_product_identifier", "full_product_identifier is required.", alloc),
            false,
        ),
        error.EmptyBomItems => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("empty_bom_items", "BOM payload must contain at least one component relation.", alloc),
            false,
        ),
        error.MissingRequiredField => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("BOM_MISSING_REQUIRED_FIELD", "A required BOM field is missing.", alloc),
            false,
        ),
        error.NoProductMatch => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("BOM_NO_PRODUCT_MATCH", "No Product node matches full_product_identifier.", alloc),
            false,
        ),
        error.MissingDesignBomTab => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("NO_DESIGN_BOM_TAB", "Workbook must contain a 'Design BOM' tab.", alloc),
            false,
        ),
        error.SbomUnresolvableRoot => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("SBOM_UNRESOLVABLE_ROOT", "SBOM root could not be resolved to a Product.", alloc),
            false,
        ),
        error.CircularReference => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("BOM_CIRCULAR_REFERENCE", "BOM contains a circular parent/child reference.", alloc),
            false,
        ),
        else => return err,
    };
}

pub fn handlePostBomResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    content_type: ?[]const u8,
    body: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    var response = bom.ingestHttpBody(db, content_type, body, alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return ingestErrorResponse(err, alloc),
    };
    defer response.deinit(alloc);

    return shared.jsonRouteResponse(.ok, try bom.ingestResponseJson(response, alloc), true);
}

pub fn handlePostBomXlsxResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    content_type: ?[]const u8,
    body: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    const xlsx_body = try extractXlsxUpload(content_type, body, alloc);
    defer alloc.free(xlsx_body);

    var response = bom.ingestXlsxBody(db, xlsx_body, alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidXlsx => return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("invalid_xlsx", "Uploaded file is not a valid .xlsx workbook.", alloc),
            false,
        ),
        else => return ingestErrorResponse(err, alloc),
    };
    defer response.deinit(alloc);

    return shared.jsonRouteResponse(.ok, try bom.groupedIngestResponseJson(response, alloc), true);
}

pub fn handleGetBomResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier: []const u8,
    bom_type_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    const body = try bom.getBomJson(db, full_product_identifier, bom_type_filter, bom_name_filter, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetDesignBomListResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    const body = try bom.listDesignBomsJson(db, full_product_identifier_filter, bom_name_filter, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetDesignBomTreeResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier: ?[]const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const product_id = full_product_identifier orelse {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_full_product_identifier", "full_product_identifier query parameter is required.", alloc),
            false,
        );
    };
    const body = bom.getDesignBomTreeJson(db, product_id, bom_name, include_obsolete, alloc) catch |err| switch (err) {
        error.NotFound => return shared.jsonRouteResponse(
            .not_found,
            try validationErrorJson("design_bom_not_found", "No matching Design BOM was found.", alloc),
            false,
        ),
        else => return err,
    };
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetDesignBomItemsResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier: ?[]const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const product_id = full_product_identifier orelse {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_full_product_identifier", "full_product_identifier query parameter is required.", alloc),
            false,
        );
    };
    const body = bom.getDesignBomItemsJson(db, product_id, bom_name, include_obsolete, alloc) catch |err| switch (err) {
        error.NotFound => return shared.jsonRouteResponse(
            .not_found,
            try validationErrorJson("design_bom_not_found", "No matching Design BOM was found.", alloc),
            false,
        ),
        else => return err,
    };
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleFindPartUsageResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    part: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const part_value = part orelse {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_part", "part query parameter is required.", alloc),
            false,
        );
    };
    const body = try bom.findPartUsageJson(db, part_value, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleBomGapsResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_inactive: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    const body = try bom.bomGapsJson(db, full_product_identifier_filter, bom_name_filter, include_inactive, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleBomImpactAnalysisResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier: ?[]const u8,
    bom_name: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const product_id = full_product_identifier orelse {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_full_product_identifier", "full_product_identifier query parameter is required.", alloc),
            false,
        );
    };
    const bom_name_value = bom_name orelse {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_bom_name", "bom_name query parameter is required.", alloc),
            false,
        );
    };
    const body = bom.bomImpactAnalysisJson(db, product_id, bom_name_value, include_obsolete, alloc) catch |err| switch (err) {
        error.NotFound => return shared.jsonRouteResponse(
            .not_found,
            try validationErrorJson("design_bom_not_found", "No matching Design BOM was found.", alloc),
            false,
        ),
        else => return err,
    };
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetDesignBomComponentsResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    const body = try bom.getDesignBomComponentsJson(db, full_product_identifier_filter, bom_name_filter, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetDesignBomCoverageResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier_filter: ?[]const u8,
    bom_name_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }

    const body = try bom.getDesignBomCoverageJson(db, full_product_identifier_filter, bom_name_filter, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

fn extractXlsxUpload(content_type: ?[]const u8, body: []const u8, alloc: Allocator) ![]u8 {
    const value = content_type orelse return error.UnsupportedContentType;
    if (std.mem.startsWith(u8, value, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") or
        std.mem.startsWith(u8, value, "application/octet-stream"))
    {
        return alloc.dupe(u8, body);
    }
    if (!std.mem.startsWith(u8, value, "multipart/form-data")) return error.UnsupportedContentType;

    const boundary_key = "boundary=";
    const boundary_pos = std.mem.indexOf(u8, value, boundary_key) orelse return error.UnsupportedContentType;
    const boundary = value[boundary_pos + boundary_key.len ..];
    if (boundary.len == 0) return error.UnsupportedContentType;

    const header_end = std.mem.indexOf(u8, body, "\r\n\r\n") orelse std.mem.indexOf(u8, body, "\n\n") orelse return error.InvalidCsv;
    const data_start = if (std.mem.indexOf(u8, body, "\r\n\r\n")) |_| header_end + 4 else header_end + 2;
    const marker = try std.fmt.allocPrint(alloc, "\r\n--{s}", .{boundary});
    defer alloc.free(marker);
    const data_end = std.mem.indexOfPos(u8, body, data_start, marker) orelse return error.InvalidCsv;
    return alloc.dupe(u8, body[data_start..data_end]);
}

const testing = std.testing;

test "POST bom without token returns 401" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);

    const resp = try handlePostBomResponse(&db, &auth, null, "application/json", "{}", testing.allocator);
    try testing.expectEqual(std.http.Status.unauthorized, resp.status);
}

test "POST bom ingests valid hardware json" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode(
        "product://ASM-1000-REV-C",
        "Product",
        "{\"full_identifier\":\"ASM-1000-REV-C\"}",
        null,
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const header = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(header);

    const body =
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
        \\      "ref_designator": "C47,C48",
        \\      "description": "10uF capacitor",
        \\      "supplier": "Murata",
        \\      "category": "component"
        \\    }
        \\  ]
        \\}
    ;

    const resp = try handlePostBomResponse(&db, &auth, header, "application/json", body, testing.allocator);
    defer testing.allocator.free(resp.body);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"bom_name\":\"pcba\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"warnings\":[]") != null);
}

test "POST bom rejects unsupported content type with 415" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode(
        "product://ASM-1000-REV-C",
        "Product",
        "{\"full_identifier\":\"ASM-1000-REV-C\"}",
        null,
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const header = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(header);

    const resp = try handlePostBomResponse(
        &db,
        &auth,
        header,
        "application/octet-stream",
        "not a bom",
        testing.allocator,
    );
    defer testing.allocator.free(resp.body);
    try testing.expectEqual(std.http.Status.unsupported_media_type, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"unsupported_content_type\"") != null);
}

test "POST bom fallback classification still rejects unknown body with 415" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode(
        "product://ASM-1000-REV-C",
        "Product",
        "{\"full_identifier\":\"ASM-1000-REV-C\"}",
        null,
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const header = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(header);

    const resp = try handlePostBomResponse(
        &db,
        &auth,
        header,
        null,
        "this is neither csv nor json",
        testing.allocator,
    );
    defer testing.allocator.free(resp.body);
    try testing.expectEqual(std.http.Status.unsupported_media_type, resp.status);
}

test "GET bom returns tree for product" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    var ingest = try bom.ingestHttpBody(
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
    defer ingest.deinit(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const header = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(header);

    const resp = try handleGetBomResponse(&db, &auth, header, "ASM-1000-REV-C", null, null, testing.allocator);
    defer testing.allocator.free(resp.body);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"boms\":[") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"bom_type\":\"hardware\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"edge_properties\":{\"quantity\":\"4\"") != null);
}

test "POST bom returns warning codes for unresolved trace refs without failing" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode(
        "product://ASM-1000-REV-C",
        "Product",
        "{\"full_identifier\":\"ASM-1000-REV-C\"}",
        null,
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const token_path = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "api-token" });
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const header = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(header);

    const body =
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
        \\      "requirement_id": "REQ-404",
        \\      "test_id": "TEST-404"
        \\    }
        \\  ]
        \\}
    ;

    const resp = try handlePostBomResponse(&db, &auth, header, "application/json", body, testing.allocator);
    defer testing.allocator.free(resp.body);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"BOM_UNRESOLVED_REQUIREMENT_REF\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"BOM_UNRESOLVED_TEST_REF\"") != null);
}
