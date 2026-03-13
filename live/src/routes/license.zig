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

pub fn handleLicenseActivateResponse(service: *license.Service, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    const Request = struct {
        license_key: ?[]const u8 = null,
    };

    var parsed = std.json.parseFromSlice(Request, alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"error\":\"invalid JSON\"}"), false);
    };
    defer parsed.deinit();
    const key = parsed.value.license_key orelse return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"error\":\"missing license_key\"}"), false);

    var result = try service.activate(alloc, .{ .license_key = key });
    defer result.deinit(alloc);
    const body_json = try status_routes.licenseEnvelopeJson(result.status, alloc);
    return shared.jsonRouteResponse(.ok, body_json, result.status.permits_use);
}

pub fn handleLicenseDeactivateResponse(service: *license.Service, alloc: Allocator) !shared.JsonRouteResponse {
    var result = try service.deactivate(alloc);
    defer result.deinit(alloc);
    const body_json = try status_routes.licenseEnvelopeJson(result.status, alloc);
    return shared.jsonRouteResponse(.ok, body_json, true);
}

pub fn handleLicenseRefreshResponse(service: *license.Service, alloc: Allocator) !shared.JsonRouteResponse {
    var result = try service.refresh(alloc);
    defer result.deinit(alloc);
    const body_json = try status_routes.licenseEnvelopeJson(result.status, alloc);
    return shared.jsonRouteResponse(.ok, body_json, true);
}

const testing = std.testing;

test "handleLicenseStatus returns structured license JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);

    const body = try handleLicenseStatus(&license_service, alloc);
    try testing.expect(std.mem.indexOf(u8, body, "\"license\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"state\":\"not_activated\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"permits_use\":false") != null);
}

test "handleLicenseActivateResponse transitions to valid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);

    const resp = try handleLicenseActivateResponse(&license_service, "{\"license_key\":\"RTMIFY-DEV-0000-0000\"}", alloc);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(resp.ok);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"valid\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"permits_use\":true") != null);
}

test "handleLicenseDeactivateResponse returns not_activated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);
    var activation = try license_service.activate(alloc, .{ .license_key = license.DEV_KEY });
    defer activation.deinit(alloc);

    const resp = try handleLicenseDeactivateResponse(&license_service, alloc);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(resp.ok);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"not_activated\"") != null);
}
