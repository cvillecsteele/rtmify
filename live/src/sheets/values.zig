const std = @import("std");
const Allocator = std.mem.Allocator;

const crypto = @import("crypto.zig");
const transport = @import("transport.zig");
const json_util = @import("../json_util.zig");
const testing = std.testing;

pub fn readRows(
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    tab_range: []const u8,
    alloc: Allocator,
) (crypto.SheetsError || Allocator.Error)![][][]const u8 {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}/values/{s}",
        .{ sheet_id, tab_range },
    );
    defer alloc.free(url);

    const body = try transport.httpDo(client, .GET, url, token, null, null, alloc);
    defer alloc.free(body);

    return parseValuesJson(body, alloc);
}

pub fn freeRows(rows: [][][]const u8, alloc: Allocator) void {
    for (rows) |row| {
        for (row) |cell| alloc.free(cell);
        alloc.free(row);
    }
    alloc.free(rows);
}

fn parseValuesJson(json_body: []const u8, alloc: Allocator) (crypto.SheetsError || Allocator.Error)![][][]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_body, .{}) catch return error.ApiError;
    defer parsed.deinit();
    const values = json_util.getObjectField(parsed.value, "values") orelse return try alloc.alloc([][]const u8, 0);
    if (values != .array) return try alloc.alloc([][]const u8, 0);

    var rows: std.ArrayList([][]const u8) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |c| alloc.free(c);
            alloc.free(row);
        }
        rows.deinit(alloc);
    }

    for (values.array.items) |row_value| {
        if (row_value != .array) continue;
        var cells: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (cells.items) |c| alloc.free(c);
            cells.deinit(alloc);
        }
        for (row_value.array.items) |cell_value| {
            try cells.append(alloc, try jsonValueToString(cell_value, alloc));
        }
        try rows.append(alloc, try cells.toOwnedSlice(alloc));
    }

    return rows.toOwnedSlice(alloc);
}

fn jsonValueToString(value: std.json.Value, alloc: Allocator) ![]const u8 {
    return switch (value) {
        .null => alloc.dupe(u8, ""),
        .string => |s| alloc.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(alloc, "{d}", .{f}),
        .bool => |b| alloc.dupe(u8, if (b) "true" else "false"),
        else => alloc.dupe(u8, ""),
    };
}

pub const ValueRange = struct {
    range: []const u8,
    values: []const []const u8,
};

pub fn batchUpdateValues(
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    updates: []const ValueRange,
    alloc: Allocator,
) (crypto.SheetsError || Allocator.Error)!void {
    if (updates.len == 0) return;

    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}/values:batchUpdate",
        .{sheet_id},
    );
    defer alloc.free(url);

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(alloc);
    try body_buf.appendSlice(alloc, "{\"valueInputOption\":\"RAW\",\"data\":[");
    for (updates, 0..) |u, i| {
        if (i > 0) try body_buf.append(alloc, ',');
        try body_buf.appendSlice(alloc, "{\"range\":\"");
        try appendJsonString(&body_buf, u.range, alloc);
        try body_buf.appendSlice(alloc, "\",\"values\":[");
        for (u.values, 0..) |v, j| {
            if (j > 0) try body_buf.append(alloc, ',');
            try body_buf.append(alloc, '[');
            try body_buf.append(alloc, '"');
            try appendJsonString(&body_buf, v, alloc);
            try body_buf.appendSlice(alloc, "\"]");
        }
        try body_buf.appendSlice(alloc, "]}");
    }
    try body_buf.appendSlice(alloc, "]}");

    const resp = try transport.httpDo(client, .POST, url, token, body_buf.items, "application/json", alloc);
    alloc.free(resp);
}

fn appendJsonString(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) Allocator.Error!void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

test "parseValuesJson empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const rows = try parseValuesJson("{\"range\":\"Sheet1!A1\"}", alloc);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

test "parseValuesJson basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const json =
        \\{"range":"Sheet1!A1:C2","majorDimension":"ROWS","values":[["ID","Statement","Status"],["REQ-001","The system SHALL work","approved"]]}
    ;
    const rows = try parseValuesJson(json, alloc);
    defer freeRows(rows, alloc);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(usize, 3), rows[0].len);
    try testing.expectEqualStrings("ID", rows[0][0]);
    try testing.expectEqualStrings("Statement", rows[0][1]);
    try testing.expectEqualStrings("REQ-001", rows[1][0]);
    try testing.expectEqualStrings("approved", rows[1][2]);
}

test "parseValuesJson tolerates whitespace after values key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const json =
        \\{"range":"Sheet1!A1:A1","values" : [["A"]]}
    ;
    const rows = try parseValuesJson(json, alloc);
    defer freeRows(rows, alloc);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("A", rows[0][0]);
}

test "parseValuesJson escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const json =
        \\{"values":[["a \"quoted\" value","line\nbreak"]]}
    ;
    const rows = try parseValuesJson(json, alloc);
    defer freeRows(rows, alloc);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("a \"quoted\" value", rows[0][0]);
    try testing.expectEqualStrings("line\nbreak", rows[0][1]);
}

test "appendJsonString escaping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try appendJsonString(&buf, "hello \"world\"\nnewline", alloc);
    try testing.expectEqualStrings("hello \\\"world\\\"\\nnewline", buf.items);
}

test "batchUpdateValues json body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(alloc);
    try body_buf.appendSlice(alloc, "{\"valueInputOption\":\"RAW\",\"data\":[");
    const updates = [_]ValueRange{
        .{ .range = "Sheet1!H2", .values = &[_][]const u8{"OK"} },
    };
    for (updates, 0..) |u, i| {
        if (i > 0) try body_buf.append(alloc, ',');
        try body_buf.appendSlice(alloc, "{\"range\":\"");
        try appendJsonString(&body_buf, u.range, alloc);
        try body_buf.appendSlice(alloc, "\",\"values\":[");
        for (u.values, 0..) |v, j| {
            if (j > 0) try body_buf.append(alloc, ',');
            try body_buf.append(alloc, '[');
            try body_buf.append(alloc, '"');
            try appendJsonString(&body_buf, v, alloc);
            try body_buf.appendSlice(alloc, "\"]");
        }
        try body_buf.appendSlice(alloc, "]}");
    }
    try body_buf.appendSlice(alloc, "]}");

    try testing.expectEqualStrings(
        "{\"valueInputOption\":\"RAW\",\"data\":[{\"range\":\"Sheet1!H2\",\"values\":[[\"OK\"]]}]}",
        body_buf.items,
    );
}

test "readRows delegates through mock transport correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://sheets.googleapis.com/v4/spreadsheets/sheet-123/values/Sheet1%21A1%3AZ",
                .token = "tok",
                .body = "{\"values\":[[\"ID\"],[true],[123],[1.5]]}",
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    const rows = try readRows(&client, "tok", "sheet-123", "Sheet1%21A1%3AZ", alloc);
    defer freeRows(rows, alloc);
    try testing.expectEqualStrings("ID", rows[0][0]);
    try testing.expectEqualStrings("true", rows[1][0]);
    try testing.expectEqualStrings("123", rows[2][0]);
    try testing.expectEqualStrings("1.5", rows[3][0]);
    try mock.expectDone();
}

test "batchUpdateValues no-ops on empty update list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    try batchUpdateValues(&client, "tok", "sheet-123", &.{}, alloc);
}

test "malformed values JSON maps to ApiError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.ApiError, parseValuesJson("{", arena.allocator()));
}
