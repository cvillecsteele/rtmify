const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const crypto = @import("crypto.zig");
const testing = std.testing;

pub const MockExchange = struct {
    method: std.http.Method,
    url: []const u8,
    token: []const u8,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    status: std.http.Status = .ok,
    body: []const u8,
};

pub const MockHttp = struct {
    exchanges: []const MockExchange,
    index: usize = 0,

    fn handle(
        self: *MockHttp,
        method: std.http.Method,
        url: []const u8,
        token: []const u8,
        payload: ?[]const u8,
        content_type: ?[]const u8,
        alloc: Allocator,
    ) (crypto.SheetsError || Allocator.Error)![]u8 {
        if (self.index >= self.exchanges.len) return error.ApiError;
        const expected = self.exchanges[self.index];
        self.index += 1;
        if (expected.method != method) return error.ApiError;
        if (!std.mem.eql(u8, expected.url, url)) return error.ApiError;
        if (!std.mem.eql(u8, expected.token, token)) return error.ApiError;
        if (expected.payload) |p| {
            if (payload == null or !std.mem.eql(u8, p, payload.?)) return error.ApiError;
        }
        if (expected.content_type) |ct| {
            if (content_type == null or !std.mem.eql(u8, ct, content_type.?)) return error.ApiError;
        }
        switch (expected.status) {
            .ok, .created, .accepted, .no_content => {},
            .unauthorized => return error.AuthError,
            else => return error.ApiError,
        }
        return alloc.dupe(u8, expected.body);
    }

    pub fn expectDone(self: *const MockHttp) !void {
        try testing.expectEqual(self.exchanges.len, self.index);
    }
};

var test_http_mock: ?*MockHttp = null;

pub fn useMockHttp(mock: *MockHttp) void {
    test_http_mock = mock;
}

pub fn clearMockHttp() void {
    test_http_mock = null;
}

pub fn httpDo(
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    token: []const u8,
    payload: ?[]const u8,
    content_type: ?[]const u8,
    alloc: Allocator,
) (crypto.SheetsError || Allocator.Error)![]u8 {
    if (builtin.is_test) {
        if (test_http_mock) |mock| {
            return mock.handle(method, url, token, payload, content_type, alloc);
        }
    }

    var extra: [2]std.http.Header = undefined;
    var extra_count: usize = 0;
    var auth_header: ?[]u8 = null;
    defer if (auth_header) |header| alloc.free(header);

    if (token.len > 0) {
        auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
        extra[extra_count] = .{ .name = "Authorization", .value = auth_header.? };
        extra_count += 1;
    }
    if (content_type) |ct| {
        extra[extra_count] = .{ .name = "Content-Type", .value = ct };
        extra_count += 1;
    }

    var resp_body: std.Io.Writer.Allocating = .init(alloc);
    defer resp_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = extra[0..extra_count],
        .response_writer = &resp_body.writer,
    }) catch |e| {
        std.log.err("HTTP {s} {s} failed: {s}", .{ @tagName(method), url, @errorName(e) });
        return error.HttpError;
    };

    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        const body_preview = resp_body.writer.buffer[0..@min(resp_body.writer.end, 200)];
        std.log.err("HTTP {d} for {s}: {s}", .{ @intFromEnum(result.status), url, body_preview });
        return if (result.status == .unauthorized) error.AuthError else error.ApiError;
    }

    const body = resp_body.writer.buffer[0..resp_body.writer.end];
    return alloc.dupe(u8, body);
}

test "mocked httpDo enforces method url token payload and content type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://example.com",
                .token = "tok",
                .payload = "{\"ok\":true}",
                .content_type = "application/json",
                .body = "{}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    const body = try httpDo(&client, .POST, "https://example.com", "tok", "{\"ok\":true}", "application/json", alloc);
    defer alloc.free(body);
    try testing.expectEqualStrings("{}", body);
    try mock.expectDone();
}

test "mocked httpDo maps unauthorized to AuthError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://example.com",
                .token = "tok",
                .status = .unauthorized,
                .body = "nope",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();
    try testing.expectError(error.AuthError, httpDo(&client, .GET, "https://example.com", "tok", null, null, alloc));
}

test "mocked httpDo maps other non-2xx to ApiError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://example.com",
                .token = "tok",
                .status = .internal_server_error,
                .body = "boom",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();
    try testing.expectError(error.ApiError, httpDo(&client, .GET, "https://example.com", "tok", null, null, alloc));
}
