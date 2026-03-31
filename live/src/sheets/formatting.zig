const std = @import("std");
const Allocator = std.mem.Allocator;

const crypto = @import("crypto.zig");
const transport = @import("transport.zig");
const testing = std.testing;

pub fn batchUpdateFormat(
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    requests_json: []const u8,
    alloc: Allocator,
) (crypto.SheetsError || Allocator.Error)!void {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}:batchUpdate",
        .{sheet_id},
    );
    defer alloc.free(url);

    const body = try std.fmt.allocPrint(alloc, "{{\"requests\":{s}}}", .{requests_json});
    defer alloc.free(body);

    const resp = try transport.httpDo(client, .POST, url, token, body, "application/json", alloc);
    alloc.free(resp);
}

pub fn buildRepeatCellRequest(
    sheet_id_numeric: i64,
    row_index: i64,
    col_start: i64,
    col_end: i64,
    r: f32,
    g: f32,
    b: f32,
    alloc: Allocator,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        \\{{"repeatCell":{{"range":{{"sheetId":{d},"startRowIndex":{d},"endRowIndex":{d},"startColumnIndex":{d},"endColumnIndex":{d}}},"cell":{{"userEnteredFormat":{{"backgroundColor":{{"red":{d:.3},"green":{d:.3},"blue":{d:.3}}}}}}},"fields":"userEnteredFormat.backgroundColor"}}}}
    ,
        .{ sheet_id_numeric, row_index, row_index + 1, col_start, col_end, r, g, b },
    );
}

test "batchUpdateFormat wraps requests json exactly once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://sheets.googleapis.com/v4/spreadsheets/sheet-123:batchUpdate",
                .token = "tok",
                .content_type = "application/json",
                .payload = "{\"requests\":[{\"addSheet\":{\"properties\":{\"title\":\"T\"}}}]}",
                .body = "{}",
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    try batchUpdateFormat(&client, "tok", "sheet-123", "[{\"addSheet\":{\"properties\":{\"title\":\"T\"}}}]", alloc);
    try mock.expectDone();
}

test "buildRepeatCellRequest preserves numeric boundaries and RGB formatting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const req = try buildRepeatCellRequest(7, 1, 2, 5, 1.0, 0.5, 0.0, arena.allocator());
    try testing.expectEqualStrings(
        "{\"repeatCell\":{\"range\":{\"sheetId\":7,\"startRowIndex\":1,\"endRowIndex\":2,\"startColumnIndex\":2,\"endColumnIndex\":5},\"cell\":{\"userEnteredFormat\":{\"backgroundColor\":{\"red\":1.000,\"green\":0.500,\"blue\":0.000}}},\"fields\":\"userEnteredFormat.backgroundColor\"}}",
        req,
    );
}
