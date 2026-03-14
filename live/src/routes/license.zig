const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const license = rtmify.license;
const shared = @import("shared.zig");
const status_routes = @import("status.zig");

pub fn handleLicenseStatus(service: *license.Service, alloc: Allocator) ![]const u8 {
    var status = try service.getStatus(alloc);
    defer status.deinit(alloc);
    return status_routes.licenseEnvelopeJson(status, alloc);
}

pub fn handleLicenseInfo(service: *license.Service, alloc: Allocator) !shared.JsonRouteResponse {
    var info = service.getInfo(alloc) catch |err| switch (err) {
        error.FileNotFound => return shared.jsonRouteResponse(.not_found, try alloc.dupe(u8, "{\"error\":\"license_not_found\"}"), false),
        error.InvalidLicenseFile, error.InvalidLicense => return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"error\":\"invalid_license\"}"), false),
        else => return err,
    };
    defer info.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const writer = buf.writer(alloc);
    try writer.writeAll("{\"license_path\":");
    try license.license_file.writeJsonString(writer, info.license_path);
    try writer.writeAll(",\"expected_key_fingerprint\":");
    try license.license_file.writeJsonString(writer, info.expected_key_fingerprint);
    try writer.writeAll(",\"license_signing_key_fingerprint\":");
    if (info.license_signing_key_fingerprint) |value| {
        try license.license_file.writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"payload\":");
    try license.license_file.writePayloadJson(writer, info.payload);
    try writer.writeByte('}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleLicenseImportResponse(service: *license.Service, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    const Request = struct {
        license_json: ?[]const u8 = null,
    };

    var parsed = std.json.parseFromSlice(Request, alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"error\":\"invalid_json\",\"detail\":\"Request body must be valid JSON.\"}"), false);
    };
    defer parsed.deinit();

    const license_json = parsed.value.license_json orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"error\":\"missing_license_json\",\"detail\":\"license_json is required.\"}"), false);

    var status = try service.installFromBytes(alloc, license_json);
    defer status.deinit(alloc);
    const body_json = try status_routes.licenseEnvelopeJson(status, alloc);
    const ok = status.permits_use;
    return shared.jsonRouteResponse(if (ok) .ok else .bad_request, body_json, ok);
}

pub fn handleLicenseClearResponse(service: *license.Service, alloc: Allocator) !shared.JsonRouteResponse {
    var status = try service.clearInstalledLicense(alloc);
    defer status.deinit(alloc);
    const body_json = try status_routes.licenseEnvelopeJson(status, alloc);
    return shared.jsonRouteResponse(.ok, body_json, true);
}

const testing = std.testing;

fn sampleEnvelopeJson(alloc: Allocator, product: license.LicenseProduct) ![]u8 {
    var payload = license.LicensePayload{
        .schema = 1,
        .license_id = try alloc.dupe(u8, "LIVE-2026-0001"),
        .product = product,
        .tier = .individual,
        .issued_to = try alloc.dupe(u8, "jane@example.com"),
        .issued_at = 123,
        .expires_at = null,
        .org = try alloc.dupe(u8, "Acme"),
    };
    defer payload.deinit(alloc);
    const key = try license.defaultHmacKeyBytes(alloc);
    defer alloc.free(key);
    const sig = try license.license_file.signPayloadHex(alloc, payload, key);
    defer alloc.free(sig);
    var envelope = license.LicenseEnvelope{
        .payload = try payload.clone(alloc),
        .sig = try alloc.dupe(u8, sig),
    };
    defer envelope.deinit(alloc);
    return license.license_file.envelopeJsonAlloc(alloc, envelope);
}

test "handleLicenseStatus returns structured license JSON" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const alloc = testing.allocator;
    const root = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const license_path = try std.fs.path.join(alloc, &.{ root, "license.json" });
    defer alloc.free(license_path);

    var service = try license.initDefaultHmacFile(alloc, .{
        .product = .live,
        .trial_policy = .requires_license,
        .license_path_override = license_path,
    });
    defer service.deinit(alloc);

    const body = try handleLicenseStatus(&service, alloc);
    try testing.expect(std.mem.indexOf(u8, body, "\"license\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"state\":\"not_licensed\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"permits_use\":false") != null);
}

test "handleLicenseImportResponse installs a valid license" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const alloc = testing.allocator;
    const root = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const license_path = try std.fs.path.join(alloc, &.{ root, "license.json" });
    defer alloc.free(license_path);

    var service = try license.initDefaultHmacFile(alloc, .{
        .product = .live,
        .trial_policy = .requires_license,
        .license_path_override = license_path,
    });
    defer service.deinit(alloc);

    const envelope_json = try sampleEnvelopeJson(alloc, .live);
    defer alloc.free(envelope_json);
    const req_body = try std.fmt.allocPrint(alloc, "{{\"license_json\":{s}}}", .{envelope_json});
    defer alloc.free(req_body);

    const resp = try handleLicenseImportResponse(&service, req_body, alloc);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(resp.ok);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"valid\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"permits_use\":true") != null);
}

test "handleLicenseClearResponse returns not_licensed" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const alloc = testing.allocator;
    const root = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const license_path = try std.fs.path.join(alloc, &.{ root, "license.json" });
    defer alloc.free(license_path);

    var service = try license.initDefaultHmacFile(alloc, .{
        .product = .live,
        .trial_policy = .requires_license,
        .license_path_override = license_path,
    });
    defer service.deinit(alloc);

    const envelope_json = try sampleEnvelopeJson(alloc, .live);
    defer alloc.free(envelope_json);
    var status = try service.installFromBytes(alloc, envelope_json);
    defer status.deinit(alloc);

    const resp = try handleLicenseClearResponse(&service, alloc);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(resp.ok);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"not_licensed\"") != null);
}
