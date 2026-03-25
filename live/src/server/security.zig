const std = @import("std");

const request_utils = @import("request_utils.zig");

pub const RequestValidationError = error{
    ForbiddenHost,
    ForbiddenOrigin,
};

pub fn requestHost(req: *const std.http.Server.Request) ?[]const u8 {
    return request_utils.requestHeaderValue(req, "Host");
}

pub fn hostWithoutPort(host: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, host, " \t");
    if (trimmed.len == 0 or trimmed[0] == '[') return trimmed;
    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |idx| {
        return trimmed[0..idx];
    }
    return trimmed;
}

pub fn hostPort(host: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, host, " \t");
    if (trimmed.len == 0 or trimmed[0] == '[') return null;
    const idx = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
    return std.fmt.parseInt(u16, trimmed[idx + 1 ..], 10) catch null;
}

pub fn isAllowedLocalHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or std.ascii.eqlIgnoreCase(host, "localhost");
}

pub fn parseOriginHost(origin_or_referer: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(origin_or_referer) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    const component = uri.host orelse return null;
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| if (std.mem.indexOfScalar(u8, encoded, '%') == null) encoded else null,
    };
}

pub fn parseOriginPort(origin_or_referer: []const u8) ?u16 {
    const uri = std.Uri.parse(origin_or_referer) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return null;
    return uri.port;
}

pub fn hasAllowedOriginValue(origin_or_referer: []const u8, req_host: []const u8) bool {
    const origin_host = parseOriginHost(origin_or_referer) orelse return false;
    if (!isAllowedLocalHost(origin_host)) return false;

    const req_port = hostPort(req_host) orelse return true;
    const origin_port = parseOriginPort(origin_or_referer) orelse return false;
    return origin_port == req_port;
}

pub fn requestHasAllowedBrowserOrigin(req: *const std.http.Server.Request) bool {
    const req_host = requestHost(req) orelse return false;
    if (request_utils.requestHeaderValue(req, "Origin")) |origin| {
        return hasAllowedOriginValue(origin, req_host);
    }
    if (request_utils.requestHeaderValue(req, "Referer")) |referer| {
        return hasAllowedOriginValue(referer, req_host);
    }
    return true;
}

pub fn requiresBrowserOriginCheck(method: std.http.Method, path: []const u8) bool {
    return method == .POST or method == .DELETE or (method == .GET and std.mem.eql(u8, path, "/mcp"));
}

pub fn validateLocalRequest(req: *const std.http.Server.Request) RequestValidationError!void {
    const host = requestHost(req) orelse return error.ForbiddenHost;
    if (!isAllowedLocalHost(hostWithoutPort(host))) return error.ForbiddenHost;

    const path = request_utils.stripQuery(req.head.target);
    if (requiresBrowserOriginCheck(req.head.method, path) and !requestHasAllowedBrowserOrigin(req)) {
        return error.ForbiddenOrigin;
    }
}

const testing = std.testing;

test "hostWithoutPort strips loopback host port and preserves bare host" {
    try testing.expectEqualStrings("127.0.0.1", hostWithoutPort("127.0.0.1:8000"));
    try testing.expectEqualStrings("localhost", hostWithoutPort("localhost"));
}

test "isAllowedLocalHost accepts only loopback aliases" {
    try testing.expect(isAllowedLocalHost("127.0.0.1"));
    try testing.expect(isAllowedLocalHost("localhost"));
    try testing.expect(!isAllowedLocalHost("example.com"));
    try testing.expect(!isAllowedLocalHost("192.168.1.10"));
}

test "parseOriginHost extracts host from local origins and rejects foreign schemes" {
    try testing.expectEqualStrings("127.0.0.1", parseOriginHost("http://127.0.0.1:8000/mcp").?);
    try testing.expectEqualStrings("localhost", parseOriginHost("http://localhost:8000/app").?);
    try testing.expect(parseOriginHost("https://evil.test") == null);
}

test "hasAllowedOriginValue requires local host and matching port" {
    try testing.expect(hasAllowedOriginValue("http://127.0.0.1:8000", "127.0.0.1:8000"));
    try testing.expect(hasAllowedOriginValue("http://localhost:8000/dashboard", "127.0.0.1:8000"));
    try testing.expect(!hasAllowedOriginValue("http://localhost:8001/dashboard", "127.0.0.1:8000"));
    try testing.expect(!hasAllowedOriginValue("http://192.168.1.10:8000", "127.0.0.1:8000"));
}

test "requiresBrowserOriginCheck covers unsafe methods and mcp sse" {
    try testing.expect(requiresBrowserOriginCheck(.POST, "/api/repos"));
    try testing.expect(requiresBrowserOriginCheck(.DELETE, "/api/repos/1"));
    try testing.expect(requiresBrowserOriginCheck(.GET, "/mcp"));
    try testing.expect(!requiresBrowserOriginCheck(.GET, "/api/status"));
}
