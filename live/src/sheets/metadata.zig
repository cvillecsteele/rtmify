const std = @import("std");
const Allocator = std.mem.Allocator;

const crypto = @import("crypto.zig");
const transport = @import("transport.zig");
const json_fields = @import("json_fields.zig");
const json_util = @import("../json_util.zig");
const testing = std.testing;

pub const SheetTabId = struct {
    title: []u8,
    id: i64,
};

pub fn getSheetTabIds(
    client: *std.http.Client,
    token: []const u8,
    spreadsheet_id: []const u8,
    alloc: Allocator,
) (crypto.SheetsError || Allocator.Error)![]SheetTabId {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}?fields=sheets.properties",
        .{spreadsheet_id},
    );
    defer alloc.free(url);

    const body = try transport.httpDo(client, .GET, url, token, null, null, alloc);
    defer alloc.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.ApiError;
    defer parsed.deinit();
    const sheets = json_util.getObjectField(parsed.value, "sheets") orelse return try alloc.alloc(SheetTabId, 0);
    if (sheets != .array) return try alloc.alloc(SheetTabId, 0);

    var result: std.ArrayList(SheetTabId) = .empty;
    errdefer {
        for (result.items) |item| alloc.free(item.title);
        result.deinit(alloc);
    }

    for (sheets.array.items) |sheet_value| {
        const props = json_util.getObjectField(sheet_value, "properties") orelse continue;
        const title = json_util.getString(props, "title") orelse continue;
        const id_value = json_util.getObjectField(props, "sheetId") orelse continue;
        const sheet_id = switch (id_value) {
            .integer => |v| v,
            else => continue,
        };
        try result.append(alloc, .{ .title = try alloc.dupe(u8, title), .id = sheet_id });
    }

    return result.toOwnedSlice(alloc);
}

pub fn getModifiedTime(
    client: *std.http.Client,
    token: []const u8,
    file_id: []const u8,
    alloc: Allocator,
) (crypto.SheetsError || Allocator.Error)!i64 {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://www.googleapis.com/drive/v3/files/{s}?fields=modifiedTime",
        .{file_id},
    );
    defer alloc.free(url);

    const body = try transport.httpDo(client, .GET, url, token, null, null, alloc);
    defer alloc.free(body);

    const mt = json_fields.extractJsonString(body, "modifiedTime", alloc) orelse return 0;
    defer alloc.free(mt);
    return parseIso8601(mt);
}

fn parseIso8601(s: []const u8) i64 {
    if (s.len < 19) return 0;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const min = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;

    const y: i64 = if (month <= 2) year - 1 else year;
    const m: i64 = if (month <= 2) month + 9 else month - 3;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divFloor(153 * m + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + min * 60 + sec;
}

test "parseIso8601 basic" {
    const ts = parseIso8601("2024-01-15T10:30:00.000Z");
    try testing.expect(ts > 1700000000);
    try testing.expect(ts < 1800000000);
}

test "parseIso8601 known value" {
    const ts = parseIso8601("1970-01-01T00:00:00Z");
    try testing.expectEqual(@as(i64, 0), ts);
}

test "getSheetTabIds parsing tolerates whitespace and reversed field order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://sheets.googleapis.com/v4/spreadsheets/sheet-123?fields=sheets.properties",
                .token = "tok",
                .body =
                \\{"sheets":[{"properties":{"title":"Requirements","sheetId":0,"index":0}},{"properties":{"sheetId" : 1234567,"title" : "User Needs","index":1}},{"properties":{"index":2,"title":"Risks","sheetId":9999}}]}
                ,
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    const result = try getSheetTabIds(&client, "tok", "sheet-123", alloc);
    defer {
        for (result) |item| alloc.free(item.title);
        alloc.free(result);
    }
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(i64, 0), result[0].id);
    try testing.expectEqualStrings("Requirements", result[0].title);
    try testing.expectEqual(@as(i64, 1234567), result[1].id);
    try testing.expectEqualStrings("User Needs", result[1].title);
    try testing.expectEqual(@as(i64, 9999), result[2].id);
    try testing.expectEqualStrings("Risks", result[2].title);
    try mock.expectDone();
}

test "getSheetTabIds returns empty slice when sheets missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://sheets.googleapis.com/v4/spreadsheets/sheet-123?fields=sheets.properties",
                .token = "tok",
                .body = "{\"spreadsheetId\":\"sheet-123\"}",
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    const result = try getSheetTabIds(&client, "tok", "sheet-123", alloc);
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "getModifiedTime returns 0 on missing or unparseable modifiedTime" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://www.googleapis.com/drive/v3/files/file-123?fields=modifiedTime",
                .token = "tok",
                .body = "{\"name\":\"Workbook\"}",
            },
            .{
                .method = .GET,
                .url = "https://www.googleapis.com/drive/v3/files/file-456?fields=modifiedTime",
                .token = "tok",
                .body = "{\"modifiedTime\":\"not-a-time\"}",
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    try testing.expectEqual(@as(i64, 0), try getModifiedTime(&client, "tok", "file-123", alloc));
    try testing.expectEqual(@as(i64, 0), try getModifiedTime(&client, "tok", "file-456", alloc));
}
