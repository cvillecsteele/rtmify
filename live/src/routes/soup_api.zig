const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const soup = @import("../soup.zig");
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
        error.InvalidJson => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("invalid_json", "Request body must be valid JSON.", alloc),
            false,
        ),
        error.MissingFullProductIdentifier => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_full_product_identifier", "full_product_identifier is required.", alloc),
            false,
        ),
        error.EmptyBomItems => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("empty_soup_components", "SOUP payload must contain at least one component.", alloc),
            false,
        ),
        error.MissingRequiredField => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("SOUP_MISSING_REQUIRED_FIELD", "A required SOUP field is missing.", alloc),
            false,
        ),
        error.NoProductMatch => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("SOUP_PRODUCT_NOT_FOUND", "No Product node matches full_product_identifier.", alloc),
            false,
        ),
        error.MissingSoupTab => shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("NO_SOUP_TAB", "Workbook must contain a 'SOUP Components' tab.", alloc),
            false,
        ),
        else => return err,
    };
}

pub fn handlePostSoupResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    body: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    var response = soup.ingestJsonBody(db, body, alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return ingestErrorResponse(err, alloc),
    };
    defer response.deinit(alloc);
    return shared.jsonRouteResponse(.ok, try soup.ingestResponseJson(response, alloc), true);
}

pub fn handlePostSoupXlsxResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    content_type: ?[]const u8,
    body: []const u8,
    full_product_identifier: ?[]const u8,
    bom_name: ?[]const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const product_id = full_product_identifier orelse {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("missing_full_product_identifier", "full_product_identifier is required.", alloc),
            false,
        );
    };
    const xlsx_body = try extractXlsxUpload(content_type, body, alloc);
    defer alloc.free(xlsx_body);
    var response = soup.ingestXlsxBody(db, xlsx_body, product_id, bom_name, alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidXlsx => return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("invalid_xlsx", "Uploaded file is not a valid .xlsx workbook.", alloc),
            false,
        ),
        else => return ingestErrorResponse(err, alloc),
    };
    defer response.deinit(alloc);
    return shared.jsonRouteResponse(.ok, try soup.ingestResponseJson(response, alloc), true);
}

pub fn handleGetSoupListResponse(
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
    const body = try soup.listSoftwareBomsJson(db, full_product_identifier_filter, bom_name_filter, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetSoupComponentsResponse(
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
    const body = soup.getSoupComponentsJson(db, product_id, bom_name orelse soup.default_bom_name, include_obsolete, alloc) catch |err| switch (err) {
        error.NotFound => return shared.jsonRouteResponse(
            .not_found,
            try validationErrorJson("soup_not_found", "No matching SOUP register was found.", alloc),
            false,
        ),
        else => return err,
    };
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetSoupGapsResponse(
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
    const body = try soup.soupGapsJson(db, full_product_identifier_filter, bom_name_filter, include_inactive, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetSoupLicensesResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier_filter: ?[]const u8,
    license_filter: ?[]const u8,
    include_obsolete: bool,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const body = try soup.soupLicensesJson(db, full_product_identifier_filter, license_filter, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetSoupSafetyClassesResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    full_product_identifier: ?[]const u8,
    safety_class_filter: ?[]const u8,
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
    const body = try soup.soupSafetyClassesJson(db, product_id, safety_class_filter, include_obsolete, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

fn extractXlsxUpload(content_type: ?[]const u8, body: []const u8, alloc: Allocator) ![]u8 {
    const value = content_type orelse return error.InvalidXlsx;
    if (std.mem.indexOf(u8, value, "multipart/form-data") == null) return alloc.dupe(u8, body);
    const boundary_key = "boundary=";
    const boundary_pos = std.mem.indexOf(u8, value, boundary_key) orelse return error.InvalidXlsx;
    const boundary = value[boundary_pos + boundary_key.len ..];
    if (boundary.len == 0) return error.InvalidXlsx;
    const delimiter = try std.fmt.allocPrint(alloc, "--{s}", .{boundary});
    defer alloc.free(delimiter);

    var search_start: usize = 0;
    while (true) {
        const start_rel = std.mem.indexOfPos(u8, body, search_start, delimiter) orelse break;
        var part_start = start_rel + delimiter.len;
        if (part_start + 1 < body.len and body[part_start] == '\r' and body[part_start + 1] == '\n') part_start += 2;
        const header_end = std.mem.indexOfPos(u8, body, part_start, "\r\n\r\n") orelse break;
        const headers = body[part_start..header_end];
        const part_body_start = header_end + 4;
        const next_rel = std.mem.indexOfPos(u8, body, part_body_start, delimiter) orelse break;
        var part_body_end = next_rel;
        while (part_body_end > part_body_start and (body[part_body_end - 1] == '\n' or body[part_body_end - 1] == '\r')) : (part_body_end -= 1) {}
        if (std.mem.indexOf(u8, headers, "filename=") != null) {
            return alloc.dupe(u8, body[part_body_start..part_body_end]);
        }
        search_start = next_rel;
    }
    return error.InvalidXlsx;
}
