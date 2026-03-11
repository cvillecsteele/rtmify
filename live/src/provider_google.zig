const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("provider_common.zig");
const sheets_mod = @import("sheets.zig");
const json_util = @import("json_util.zig");

pub const Runtime = struct {
    http_client: std.http.Client,
    email: []const u8,
    key: sheets_mod.RsaKey,
    sheet_id: []const u8,
    workbook_url: []const u8,
    workbook_label: []const u8,
    token_cache: sheets_mod.TokenCache = .{},

    pub fn init(active: common.ActiveConnection, alloc: Allocator) !Runtime {
        const email = sheets_mod.extractJsonFieldStatic(active.credential_json, "client_email") orelse return error.AuthError;
        const pem = sheets_mod.extractJsonFieldStatic(active.credential_json, "private_key") orelse return error.AuthError;
        const pem_unescaped = try unescapeNewlines(pem, alloc);
        defer alloc.free(pem_unescaped);
        const key = try sheets_mod.parsePemRsaKey(pem_unescaped, alloc);
        const target = switch (active.target) {
            .google => |g| g,
            else => return error.AuthError,
        };
        return .{
            .http_client = .{ .allocator = alloc },
            .email = try alloc.dupe(u8, email),
            .key = key,
            .sheet_id = try alloc.dupe(u8, target.sheet_id),
            .workbook_url = try alloc.dupe(u8, active.workbook_url),
            .workbook_label = try alloc.dupe(u8, active.workbook_label),
        };
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.http_client.deinit();
        alloc.free(self.email);
        self.key.deinit(alloc);
        alloc.free(self.sheet_id);
        alloc.free(self.workbook_url);
        alloc.free(self.workbook_label);
    }

    fn getToken(self: *Runtime, alloc: Allocator) ![]const u8 {
        return self.token_cache.getToken(self.email, self.key, &self.http_client, alloc);
    }

    pub fn changeToken(self: *Runtime, alloc: Allocator) ![]const u8 {
        const token = try self.getToken(alloc);
        const mt = try sheets_mod.getModifiedTime(&self.http_client, token, self.sheet_id, alloc);
        return std.fmt.allocPrint(alloc, "{d}", .{mt});
    }

    pub fn listTabs(self: *Runtime, alloc: Allocator) ![]common.TabRef {
        const token = try self.getToken(alloc);
        const tabs = try sheets_mod.getSheetTabIds(&self.http_client, token, self.sheet_id, alloc);
        defer {
            for (tabs) |tab| alloc.free(tab.title);
            alloc.free(tabs);
        }

        var result: std.ArrayList(common.TabRef) = .empty;
        defer result.deinit(alloc);
        for (tabs) |tab| {
            try result.append(alloc, .{
                .title = try alloc.dupe(u8, tab.title),
                .native_id = try std.fmt.allocPrint(alloc, "{d}", .{tab.id}),
            });
        }
        return result.toOwnedSlice(alloc);
    }

    pub fn readRows(self: *Runtime, tab_title: []const u8, alloc: Allocator) ![][][]const u8 {
        const token = try self.getToken(alloc);
        const tab_range = try formatA1Range(tab_title, "A1:Z", alloc);
        defer alloc.free(tab_range);
        const encoded = try encodeRangeForUrl(tab_range, alloc);
        defer alloc.free(encoded);
        return sheets_mod.readRows(&self.http_client, token, self.sheet_id, encoded, alloc);
    }

    pub fn batchWriteValues(self: *Runtime, updates: []const common.ValueUpdate, alloc: Allocator) !void {
        if (updates.len == 0) return;
        const token = try self.getToken(alloc);
        var native: std.ArrayList(sheets_mod.ValueRange) = .empty;
        defer {
            for (native.items) |item| alloc.free(item.range);
            native.deinit(alloc);
        }
        for (updates) |u| {
            try native.append(alloc, .{
                .range = try normalizeA1Range(u.a1_range, alloc),
                .values = u.values,
            });
        }
        try sheets_mod.batchUpdateValues(&self.http_client, token, self.sheet_id, native.items, alloc);
    }

    pub fn applyRowFormats(self: *Runtime, reqs: []const common.RowFormat, alloc: Allocator) !void {
        if (reqs.len == 0) return;
        const token = try self.getToken(alloc);
        const tabs = try sheets_mod.getSheetTabIds(&self.http_client, token, self.sheet_id, alloc);
        defer {
            for (tabs) |tab| alloc.free(tab.title);
            alloc.free(tabs);
        }

        var requests: std.ArrayList([]u8) = .empty;
        defer {
            for (requests.items) |req| alloc.free(req);
            requests.deinit(alloc);
        }
        for (reqs) |req| {
            const tab_id = findTabId(tabs, req.tab_title) orelse continue;
            const rgb = try parseFillHex(req.fill_hex);
            const json = try sheets_mod.buildRepeatCellRequest(
                tab_id,
                @intCast(req.row_1based - 1),
                @intCast(req.col_start_1based - 1),
                @intCast(req.col_end_1based),
                rgb[0], rgb[1], rgb[2],
                alloc,
            );
            try requests.append(alloc, json);
        }
        if (requests.items.len == 0) return;

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(alloc);
        try payload.append(alloc, '[');
        for (requests.items, 0..) |req, idx| {
            if (idx > 0) try payload.append(alloc, ',');
            try payload.appendSlice(alloc, req);
        }
        try payload.append(alloc, ']');

        try sheets_mod.batchUpdateFormat(&self.http_client, token, self.sheet_id, payload.items, alloc);
    }

    pub fn createTab(self: *Runtime, title: []const u8, alloc: Allocator) !void {
        const token = try self.getToken(alloc);
        var add_req: std.ArrayList(u8) = .empty;
        defer add_req.deinit(alloc);
        try add_req.appendSlice(alloc, "[{\"addSheet\":{\"properties\":{\"title\":");
        try json_util.appendJsonQuoted(&add_req, title, alloc);
        try add_req.appendSlice(alloc, "}}}]");
        try sheets_mod.batchUpdateFormat(&self.http_client, token, self.sheet_id, add_req.items, alloc);
    }
};

fn unescapeNewlines(s: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == 'n') {
            try buf.append(alloc, '\n');
            i += 1;
        } else {
            try buf.append(alloc, s[i]);
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn normalizeA1Range(range: []const u8, alloc: Allocator) ![]u8 {
    const bang = std.mem.indexOfScalar(u8, range, '!') orelse return alloc.dupe(u8, range);
    const sheet_ref = try quoteSheetTitle(range[0..bang], alloc);
    defer alloc.free(sheet_ref);
    return std.fmt.allocPrint(alloc, "{s}!{s}", .{ sheet_ref, range[bang + 1 ..] });
}

fn formatA1Range(tab_title: []const u8, suffix: []const u8, alloc: Allocator) ![]u8 {
    const sheet_ref = try quoteSheetTitle(tab_title, alloc);
    defer alloc.free(sheet_ref);
    return std.fmt.allocPrint(alloc, "{s}!{s}", .{ sheet_ref, suffix });
}

fn quoteSheetTitle(tab_title: []const u8, alloc: Allocator) ![]u8 {
    if (!needsQuoting(tab_title)) return alloc.dupe(u8, tab_title);
    const escaped = try std.mem.replaceOwned(u8, alloc, tab_title, "'", "''");
    defer alloc.free(escaped);
    return std.fmt.allocPrint(alloc, "'{s}'", .{escaped});
}

fn needsQuoting(tab_title: []const u8) bool {
    for (tab_title) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return true;
    }
    return false;
}

fn encodeRangeForUrl(range: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (range) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '~') {
            try buf.append(alloc, c);
        } else {
            try std.fmt.format(buf.writer(alloc), "%{X:0>2}", .{@as(u8, c)});
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn findTabId(tabs: []const sheets_mod.SheetTabId, title: []const u8) ?i64 {
    for (tabs) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, title)) return tab.id;
    }
    return null;
}

fn parseFillHex(fill_hex: []const u8) ![3]f32 {
    const hex = if (std.mem.startsWith(u8, fill_hex, "#")) fill_hex[1..] else fill_hex;
    if (hex.len != 6) return error.InvalidHexColor;
    const r = try std.fmt.parseInt(u8, hex[0..2], 16);
    const g = try std.fmt.parseInt(u8, hex[2..4], 16);
    const b = try std.fmt.parseInt(u8, hex[4..6], 16);
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
    };
}

const testing = std.testing;

fn testRuntime(alloc: Allocator) !Runtime {
    var runtime: Runtime = .{
        .http_client = .{ .allocator = alloc },
        .email = try alloc.dupe(u8, "svc@example.com"),
        .key = .{
            .n = try alloc.dupe(u8, ""),
            .d = try alloc.dupe(u8, ""),
            .modulus_len = 0,
        },
        .sheet_id = try alloc.dupe(u8, "sheet-123"),
        .workbook_url = try alloc.dupe(u8, "https://docs.google.com/spreadsheets/d/sheet-123/edit"),
        .workbook_label = try alloc.dupe(u8, "Workbook"),
        .token_cache = .{
            .token = [_]u8{0} ** 1024,
            .token_len = 3,
            .expires_at = std.time.timestamp() + 3600,
        },
    };
    @memcpy(runtime.token_cache.token[0..3], "tok");
    return runtime;
}

test "parseFillHex parses rgb components" {
    const rgb = try parseFillHex("#FFE0C8");
    try testing.expect(rgb[0] > 0.99);
    try testing.expect(rgb[1] > 0.87);
    try testing.expect(rgb[2] > 0.78);
}

test "normalizeA1Range quotes sheet names with spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const range = try normalizeA1Range("Design Inputs!A1", alloc);
    defer alloc.free(range);
    try testing.expectEqualStrings("'Design Inputs'!A1", range);
}

test "encodeRangeForUrl percent-encodes quoted A1 ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const encoded = try encodeRangeForUrl("'Design Inputs'!A1:Z", alloc);
    defer alloc.free(encoded);
    try testing.expectEqualStrings("%27Design%20Inputs%27%21A1%3AZ", encoded);
}

test "readRows requests quoted sheet title for spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var runtime = try testRuntime(alloc);
    defer runtime.deinit(alloc);

    var mock = sheets_mod.MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://sheets.googleapis.com/v4/spreadsheets/sheet-123/values/%27Design%20Inputs%27%21A1%3AZ",
                .token = "tok",
                .body = "{\"values\":[[\"ID\"]]}",
            },
        },
    };
    sheets_mod.useMockHttp(&mock);
    defer sheets_mod.clearMockHttp();

    const rows = try runtime.readRows("Design Inputs", alloc);
    defer sheets_mod.freeRows(rows, alloc);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("ID", rows[0][0]);
    try mock.expectDone();
}

test "readRows requests quoted sheet title for apostrophe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var runtime = try testRuntime(alloc);
    defer runtime.deinit(alloc);

    var mock = sheets_mod.MockHttp{
        .exchanges = &.{
            .{
                .method = .GET,
                .url = "https://sheets.googleapis.com/v4/spreadsheets/sheet-123/values/%27Bob%27%27s%20Inputs%27%21A1%3AZ",
                .token = "tok",
                .body = "{\"values\":[[\"ID\"]]}",
            },
        },
    };
    sheets_mod.useMockHttp(&mock);
    defer sheets_mod.clearMockHttp();

    const rows = try runtime.readRows("Bob's Inputs", alloc);
    defer sheets_mod.freeRows(rows, alloc);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try mock.expectDone();
}

test "batchWriteValues normalizes spaced and apostrophe titles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var runtime = try testRuntime(alloc);
    defer runtime.deinit(alloc);

    var mock = sheets_mod.MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://sheets.googleapis.com/v4/spreadsheets/sheet-123/values:batchUpdate",
                .token = "tok",
                .content_type = "application/json",
                .payload = "{\"valueInputOption\":\"RAW\",\"data\":[{\"range\":\"'User Needs'!H2:H3\",\"values\":[[\"OK\"],[\"MISSING\"]]},{\"range\":\"'Bob''s Inputs'!A1:A2\",\"values\":[[\"X\"],[\"Y\"]]}]}",
                .body = "{}",
            },
        },
    };
    sheets_mod.useMockHttp(&mock);
    defer sheets_mod.clearMockHttp();

    try runtime.batchWriteValues(&.{
        .{ .a1_range = "User Needs!H2:H3", .values = &.{ "OK", "MISSING" } },
        .{ .a1_range = "Bob's Inputs!A1:A2", .values = &.{ "X", "Y" } },
    }, alloc);
    try mock.expectDone();
}
