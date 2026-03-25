const std = @import("std");

const assets = @import("assets.zig");

pub fn shouldLogHttpRequest(method: std.http.Method, path: []const u8) bool {
    return !(method == .GET and std.mem.eql(u8, path, "/mcp"));
}

pub const RouteAccess = enum {
    allowed_always,
    allowed_in_preview,
    requires_license,
};

pub fn routeAccess(method: std.http.Method, path: []const u8) RouteAccess {
    if (std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/index.html") or
        assets.staticAssetForPath(path) != null or
        std.mem.eql(u8, path, "/api/status") or
        std.mem.eql(u8, path, "/api/info") or
        std.mem.eql(u8, path, "/api/license/status") or
        std.mem.eql(u8, path, "/api/license/info") or
        std.mem.eql(u8, path, "/api/license/import") or
        std.mem.eql(u8, path, "/api/license/clear"))
    {
        return .allowed_always;
    }

    if (std.mem.eql(u8, path, "/api/onboarding/source-artifact") or
        std.mem.eql(u8, path, "/api/workspace/preferences") or
        std.mem.eql(u8, path, "/api/connection/validate") or
        std.mem.eql(u8, path, "/api/connection") or
        std.mem.eql(u8, path, "/api/workbooks") or
        std.mem.startsWith(u8, path, "/api/workbooks/") or
        std.mem.eql(u8, path, "/api/profile") or
        std.mem.eql(u8, path, "/api/provision-preview") or
        std.mem.eql(u8, path, "/nodes") or
        std.mem.eql(u8, path, "/nodes/types") or
        std.mem.eql(u8, path, "/edges/labels") or
        std.mem.eql(u8, path, "/search") or
        std.mem.eql(u8, path, "/schema") or
        std.mem.eql(u8, path, "/api/v1/design-artifacts") or
        std.mem.startsWith(u8, path, "/api/v1/design-artifacts/") or
        std.mem.eql(u8, path, "/api/v1/design-artifacts/upload") or
        std.mem.eql(u8, path, "/api/v1/design-artifacts/docx") or
        std.mem.eql(u8, path, "/query/gaps") or
        std.mem.eql(u8, path, "/query/rtm") or
        std.mem.eql(u8, path, "/query/suspects") or
        std.mem.eql(u8, path, "/query/user-needs") or
        std.mem.eql(u8, path, "/query/tests") or
        std.mem.eql(u8, path, "/query/risks") or
        std.mem.startsWith(u8, path, "/query/impact/") or
        std.mem.startsWith(u8, path, "/query/node/") or
        std.mem.eql(u8, path, "/query/chain-gaps") or
        (std.mem.startsWith(u8, path, "/suspect/") and std.mem.endsWith(u8, path, "/clear")) or
        std.mem.eql(u8, path, "/api/diagnostics") or
        std.mem.eql(u8, path, "/api/guide/errors"))
    {
        _ = method;
        return .allowed_in_preview;
    }

    return .requires_license;
}

pub fn isLicenseExempt(method: std.http.Method, path: []const u8) bool {
    return routeAccess(method, path) != .requires_license;
}

pub fn requiresActiveWorkbook(method: std.http.Method, path: []const u8) bool {
    _ = method;
    return !(std.mem.eql(u8, path, "/") or
        std.mem.eql(u8, path, "/index.html") or
        assets.staticAssetForPath(path) != null or
        std.mem.eql(u8, path, "/api/status") or
        std.mem.eql(u8, path, "/api/info") or
        std.mem.eql(u8, path, "/api/license/status") or
        std.mem.eql(u8, path, "/api/license/info") or
        std.mem.eql(u8, path, "/api/license/import") or
        std.mem.eql(u8, path, "/api/license/clear") or
        std.mem.eql(u8, path, "/api/connection/validate") or
        std.mem.eql(u8, path, "/api/workbooks") or
        (std.mem.startsWith(u8, path, "/api/workbooks/") and reqPathIsWorkbookMutation(path)) or
        std.mem.eql(u8, path, "/mcp"));
}

pub fn reqPathIsWorkbookMutation(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "/activate") or
        std.mem.endsWith(u8, path, "/remove") or
        !std.mem.endsWith(u8, path, "/");
}

const testing = std.testing;

test "license exemptions include app js bootstrap asset" {
    try testing.expect(isLicenseExempt(.GET, "/"));
    try testing.expect(isLicenseExempt(.GET, "/index.html"));
    try testing.expect(isLicenseExempt(.GET, "/app.js"));
    try testing.expect(isLicenseExempt(.GET, "/modules/init.js"));
    try testing.expect(isLicenseExempt(.GET, "/query/rtm"));
    try testing.expect(!isLicenseExempt(.GET, "/report/rtm"));
}

test "shouldLogHttpRequest suppresses only mcp polling" {
    try testing.expect(!shouldLogHttpRequest(.GET, "/mcp"));
    try testing.expect(shouldLogHttpRequest(.GET, "/api/status"));
}
