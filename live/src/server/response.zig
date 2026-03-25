const std = @import("std");

pub const base_headers = [_]std.http.Header{
    .{ .name = "Connection", .value = "close" },
};

pub fn sendJson(req: *std.http.Server.Request, body: []const u8) !void {
    try sendJsonWithStatus(req, body, .ok);
}

pub fn sendJsonWithStatus(req: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try req.respond(body, .{
        .status = status,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

pub fn sendHtml(req: *std.http.Server.Request, body: []const u8) !void {
    try sendStaticText(req, body, "text/html; charset=utf-8");
}

pub fn sendStaticText(req: *std.http.Server.Request, body: []const u8, content_type: []const u8) !void {
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Cache-Control", .value = "no-store, no-cache, must-revalidate, max-age=0" },
        .{ .name = "Pragma", .value = "no-cache" },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

pub fn sendPdf(req: *std.http.Server.Request, body: []const u8) !void {
    try sendPdfNamed(req, body, "rtm.pdf");
}

pub fn sendPdfNamed(req: *std.http.Server.Request, body: []const u8, filename: []const u8) !void {
    const disposition = try std.fmt.allocPrint(std.heap.page_allocator, "attachment; filename=\"{s}\"", .{filename});
    defer std.heap.page_allocator.free(disposition);
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/pdf" },
        .{ .name = "Content-Disposition", .value = disposition },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

pub fn sendText(req: *std.http.Server.Request, body: []const u8, content_type: []const u8) !void {
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = content_type },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

pub fn sendDocx(req: *std.http.Server.Request, body: []const u8) !void {
    try sendDocxNamed(req, body, "rtm.docx");
}

pub fn sendDocxNamed(req: *std.http.Server.Request, body: []const u8, filename: []const u8) !void {
    const mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
    const disposition = try std.fmt.allocPrint(std.heap.page_allocator, "attachment; filename=\"{s}\"", .{filename});
    defer std.heap.page_allocator.free(disposition);
    const headers = base_headers ++ [_]std.http.Header{
        .{ .name = "Content-Type", .value = mime },
        .{ .name = "Content-Disposition", .value = disposition },
    };
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
        .keep_alive = false,
    });
}

pub fn send404(req: *std.http.Server.Request) !void {
    try sendJsonWithStatus(req, "{\"error\":\"not found\"}", .not_found);
}

const testing = std.testing;

test "response helpers keep connection close as the only base header" {
    try testing.expectEqual(@as(usize, 1), base_headers.len);
    try testing.expectEqualStrings("Connection", base_headers[0].name);
    try testing.expectEqualStrings("close", base_headers[0].value);
}
