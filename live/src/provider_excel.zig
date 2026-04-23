const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const common = @import("provider_common.zig");
const json_util = @import("json_util.zig");

pub const ExcelError = error{
    AuthError,
    ApiError,
    InvalidCredential,
    InvalidWorkbookUrl,
    InvalidResponse,
    NotFound,
    AccessDenied,
    Throttled,
};

const TokenCache = struct {
    access_token: ?[]u8 = null,
    expires_at: i64 = 0,

    fn deinit(self: *TokenCache, alloc: Allocator) void {
        if (self.access_token) |tok| alloc.free(tok);
    }
};

const WorksheetCache = struct {
    tabs: ?[]common.TabRef = null,

    fn deinit(self: *WorksheetCache, alloc: Allocator) void {
        self.invalidate(alloc);
    }

    fn invalidate(self: *WorksheetCache, alloc: Allocator) void {
        if (self.tabs) |tabs| common.freeTabRefs(tabs, alloc);
        self.tabs = null;
    }
};

pub const Runtime = struct {
    http_client: std.http.Client,
    tenant_id: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    drive_id: []const u8,
    item_id: []const u8,
    workbook_url: []const u8,
    workbook_label: []const u8,
    token_cache: TokenCache = .{},
    token_mu: std.Thread.Mutex = .{},
    worksheet_cache: WorksheetCache = .{},
    last_retry_after_seconds: ?u64 = null,

    pub fn init(active: common.ActiveConnection, alloc: Allocator) !Runtime {
        const tenant_id = json_util.extractJsonFieldStatic(active.credential_json, "tenant_id") orelse return error.InvalidCredential;
        const client_id = json_util.extractJsonFieldStatic(active.credential_json, "client_id") orelse return error.InvalidCredential;
        const client_secret = json_util.extractJsonFieldStatic(active.credential_json, "client_secret") orelse return error.InvalidCredential;
        const target = switch (active.target) {
            .excel => |e| e,
            else => return error.InvalidCredential,
        };
        return .{
            .http_client = .{ .allocator = alloc },
            .tenant_id = try alloc.dupe(u8, tenant_id),
            .client_id = try alloc.dupe(u8, client_id),
            .client_secret = try alloc.dupe(u8, client_secret),
            .drive_id = try alloc.dupe(u8, target.drive_id),
            .item_id = try alloc.dupe(u8, target.item_id),
            .workbook_url = try alloc.dupe(u8, active.workbook_url),
            .workbook_label = try alloc.dupe(u8, active.workbook_label),
        };
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.http_client.deinit();
        alloc.free(self.tenant_id);
        alloc.free(self.client_id);
        alloc.free(self.client_secret);
        alloc.free(self.drive_id);
        alloc.free(self.item_id);
        alloc.free(self.workbook_url);
        alloc.free(self.workbook_label);
        self.worksheet_cache.deinit(alloc);
        self.token_cache.deinit(alloc);
    }

    fn getToken(self: *Runtime, alloc: Allocator) ![]u8 {
        self.token_mu.lock();
        defer self.token_mu.unlock();
        const now = std.time.timestamp();
        if (self.token_cache.access_token) |tok| {
            if (now < self.token_cache.expires_at - 60) return alloc.dupe(u8, tok);
        }
        if (self.token_cache.access_token) |tok| {
            alloc.free(tok);
            self.token_cache.access_token = null;
        }
        const token_result = try acquireToken(&self.http_client, self.tenant_id, self.client_id, self.client_secret, alloc);
        self.token_cache.access_token = token_result.access_token;
        self.token_cache.expires_at = token_result.expires_at;
        return alloc.dupe(u8, self.token_cache.access_token.?);
    }

    fn worksheets(self: *Runtime, alloc: Allocator) ![]const common.TabRef {
        if (self.worksheet_cache.tabs == null) {
            const token = try self.getToken(alloc);
            defer alloc.free(token);
            self.worksheet_cache.tabs = try fetchWorksheets(&self.http_client, token, self.drive_id, self.item_id, alloc, &self.last_retry_after_seconds);
        }
        return self.worksheet_cache.tabs.?;
    }

    pub fn takeRetryAfterSeconds(self: *Runtime) ?u64 {
        const value = self.last_retry_after_seconds;
        self.last_retry_after_seconds = null;
        return value;
    }

    pub fn changeToken(self: *Runtime, alloc: Allocator) ![]const u8 {
        const token = try self.getToken(alloc);
        defer alloc.free(token);
        var meta = try getDriveItemMetadata(&self.http_client, token, self.drive_id, self.item_id, alloc, &self.last_retry_after_seconds);
        defer meta.deinit(alloc);
        return alloc.dupe(u8, meta.last_modified);
    }

    pub fn listTabs(self: *Runtime, alloc: Allocator) ![]common.TabRef {
        return cloneTabRefs(try self.worksheets(alloc), alloc);
    }

    pub fn readRows(self: *Runtime, tab_title: []const u8, alloc: Allocator) ![][][]const u8 {
        const token = try self.getToken(alloc);
        defer alloc.free(token);
        const tabs = try self.worksheets(alloc);
        const tab_id = findTabId(tabs, tab_title) orelse return error.NotFound;
        const last_row = try fetchUsedRangeLastRow(&self.http_client, token, self.drive_id, self.item_id, tab_id, alloc, &self.last_retry_after_seconds);
        if (last_row == 0) return try alloc.alloc([][]const u8, 0);
        const a1 = try std.fmt.allocPrint(alloc, "A1:Z{d}", .{last_row});
        defer alloc.free(a1);
        return fetchRangeValues(&self.http_client, token, self.drive_id, self.item_id, tab_id, a1, alloc, &self.last_retry_after_seconds);
    }

    pub fn batchWriteValues(self: *Runtime, updates: []const common.ValueUpdate, alloc: Allocator) !void {
        if (updates.len == 0) return;
        const token = try self.getToken(alloc);
        defer alloc.free(token);
        const tabs = try self.worksheets(alloc);

        for (updates) |update| {
            const parsed = try parseA1Range(update.a1_range, alloc);
            defer parsed.deinit(alloc);
            const tab_id = findTabId(tabs, parsed.tab_title) orelse return error.NotFound;
            try patchRangeValues(&self.http_client, token, self.drive_id, self.item_id, tab_id, parsed.range, update.values, alloc, &self.last_retry_after_seconds);
        }
    }

    pub fn applyRowFormats(self: *Runtime, reqs: []const common.RowFormat, alloc: Allocator) !void {
        if (reqs.len == 0) return;
        const token = try self.getToken(alloc);
        defer alloc.free(token);
        const tabs = try self.worksheets(alloc);

        for (reqs) |req| {
            const tab_id = findTabId(tabs, req.tab_title) orelse continue;
            const range = try std.fmt.allocPrint(alloc, "{s}{d}:{s}{d}", .{
                columnLetters(req.col_start_1based),
                req.row_1based,
                columnLetters(req.col_end_1based),
                req.row_1based,
            });
            defer alloc.free(range);
            try patchRangeFill(&self.http_client, token, self.drive_id, self.item_id, tab_id, range, req.fill_hex, alloc, &self.last_retry_after_seconds);
        }
    }

    pub fn createTab(self: *Runtime, title: []const u8, alloc: Allocator) !void {
        const token = try self.getToken(alloc);
        defer alloc.free(token);
        try addWorksheet(&self.http_client, token, self.drive_id, self.item_id, title, alloc, &self.last_retry_after_seconds);
        self.worksheet_cache.invalidate(alloc);
    }
};

pub const TokenResult = struct {
    access_token: []u8,
    expires_at: i64,
};

pub const DriveItemMetadata = struct {
    last_modified: []u8,
    name: []u8,
    web_url: ?[]u8,

    fn deinit(self: *DriveItemMetadata, alloc: Allocator) void {
        alloc.free(self.last_modified);
        alloc.free(self.name);
        if (self.web_url) |v| alloc.free(v);
    }
};

pub const ResolvedWorkbook = struct {
    drive_id: []u8,
    item_id: []u8,
    workbook_label: []u8,

    pub fn deinit(self: *ResolvedWorkbook, alloc: Allocator) void {
        alloc.free(self.drive_id);
        alloc.free(self.item_id);
        alloc.free(self.workbook_label);
    }
};

pub fn resolveWorkbookUrl(client: *std.http.Client, tenant_id: []const u8, client_id: []const u8, client_secret: []const u8, workbook_url: []const u8, alloc: Allocator) !ResolvedWorkbook {
    const token_result = try acquireToken(client, tenant_id, client_id, client_secret, alloc);
    defer alloc.free(token_result.access_token);

    const share_token = try encodeSharingUrl(workbook_url, alloc);
    defer alloc.free(share_token);
    const url = try std.fmt.allocPrint(alloc, "https://graph.microsoft.com/v1.0/shares/{s}/driveItem", .{share_token});
    defer alloc.free(url);
    const body = try httpDoJson(client, .GET, url, token_result.access_token, null, alloc, null);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const item_id = try dupObjectString(root, "id", alloc);
    const name = try dupObjectString(root, "name", alloc);
    const parent_ref = json_util.getObjectField(root, "parentReference") orelse return error.InvalidResponse;
    const drive_id = try dupObjectString(parent_ref, "driveId", alloc);

    return .{
        .drive_id = drive_id,
        .item_id = item_id,
        .workbook_label = name,
    };
}

pub fn acquireToken(client: *std.http.Client, tenant_id: []const u8, client_id: []const u8, client_secret: []const u8, alloc: Allocator) !TokenResult {
    const url = try std.fmt.allocPrint(alloc, "https://login.microsoftonline.com/{s}/oauth2/v2.0/token", .{tenant_id});
    defer alloc.free(url);
    const body = try std.fmt.allocPrint(
        alloc,
        "client_id={s}&client_secret={s}&scope={s}&grant_type=client_credentials",
        .{
            client_id,
            client_secret,
            "https%3A%2F%2Fgraph.microsoft.com%2F.default",
        },
    );
    defer alloc.free(body);

    const resp = try httpDoJsonWithContentType(client, .POST, url, null, body, alloc, "application/x-www-form-urlencoded", null);
    defer alloc.free(resp);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const access_token = try dupObjectString(root, "access_token", alloc);
    const expires_in = objectInt(root, "expires_in") orelse 3600;
    return .{
        .access_token = access_token,
        .expires_at = std.time.timestamp() + expires_in,
    };
}

fn getDriveItemMetadata(client: *std.http.Client, token: []const u8, drive_id: []const u8, item_id: []const u8, alloc: Allocator, retry_after_seconds: ?*?u64) !DriveItemMetadata {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}?$select=lastModifiedDateTime,name,webUrl",
        .{ drive_id, item_id },
    );
    defer alloc.free(url);
    const body = try httpDoJson(client, .GET, url, token, null, alloc, retry_after_seconds);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    return .{
        .last_modified = try dupObjectString(root, "lastModifiedDateTime", alloc),
        .name = try dupObjectString(root, "name", alloc),
        .web_url = if (json_util.getObjectField(root, "webUrl") != null) try dupObjectString(root, "webUrl", alloc) else null,
    };
}

fn fetchWorksheets(client: *std.http.Client, token: []const u8, drive_id: []const u8, item_id: []const u8, alloc: Allocator, retry_after_seconds: ?*?u64) ![]common.TabRef {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}/workbook/worksheets",
        .{ drive_id, item_id },
    );
    defer alloc.free(url);
    const body = try httpDoJson(client, .GET, url, token, null, alloc, retry_after_seconds);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const value = json_util.getObjectField(parsed.value, "value") orelse return error.InvalidResponse;
    if (value != .array) return error.InvalidResponse;

    var result: std.ArrayList(common.TabRef) = .empty;
    defer result.deinit(alloc);
    for (value.array.items) |item| {
        const title = try dupObjectString(item, "name", alloc);
        errdefer alloc.free(title);
        const native_id = try dupObjectString(item, "id", alloc);
        errdefer alloc.free(native_id);
        try result.append(alloc, .{
            .title = title,
            .native_id = native_id,
        });
    }
    return result.toOwnedSlice(alloc);
}

fn cloneTabRefs(tabs: []const common.TabRef, alloc: Allocator) ![]common.TabRef {
    var result = try alloc.alloc(common.TabRef, tabs.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |tab| {
            alloc.free(tab.title);
            alloc.free(tab.native_id);
        }
        alloc.free(result);
    }
    for (tabs, 0..) |tab, idx| {
        const title = try alloc.dupe(u8, tab.title);
        errdefer alloc.free(title);
        const native_id = try alloc.dupe(u8, tab.native_id);
        result[idx] = .{
            .title = title,
            .native_id = native_id,
        };
        initialized += 1;
    }
    return result;
}

fn fetchUsedRangeLastRow(client: *std.http.Client, token: []const u8, drive_id: []const u8, item_id: []const u8, worksheet_id: []const u8, alloc: Allocator, retry_after_seconds: ?*?u64) !usize {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}/workbook/worksheets/{s}/usedRange(valuesOnly=true)",
        .{ drive_id, item_id, worksheet_id },
    );
    defer alloc.free(url);
    const body = try httpDoJson(client, .GET, url, token, null, alloc, retry_after_seconds);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const address = try dupObjectString(root, "address", alloc);
    defer alloc.free(address);
    return parseLastRowFromAddress(address);
}

fn fetchRangeValues(client: *std.http.Client, token: []const u8, drive_id: []const u8, item_id: []const u8, worksheet_id: []const u8, a1_range: []const u8, alloc: Allocator, retry_after_seconds: ?*?u64) ![][][]const u8 {
    const encoded_range = try encodeAddress(a1_range, alloc);
    defer alloc.free(encoded_range);
    const url = try std.fmt.allocPrint(
        alloc,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}/workbook/worksheets/{s}/range(address='{s}')",
        .{ drive_id, item_id, worksheet_id, encoded_range },
    );
    defer alloc.free(url);
    const body = try httpDoJson(client, .GET, url, token, null, alloc, retry_after_seconds);
    defer alloc.free(body);
    return parseValuesArrayJson(body, alloc);
}

fn patchRangeValues(client: *std.http.Client, token: []const u8, drive_id: []const u8, item_id: []const u8, worksheet_id: []const u8, a1_range: []const u8, values: []const []const u8, alloc: Allocator, retry_after_seconds: ?*?u64) !void {
    const encoded_range = try encodeAddress(a1_range, alloc);
    defer alloc.free(encoded_range);
    const url = try std.fmt.allocPrint(
        alloc,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}/workbook/worksheets/{s}/range(address='{s}')",
        .{ drive_id, item_id, worksheet_id, encoded_range },
    );
    defer alloc.free(url);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"values\":[");
    for (values, 0..) |value, idx| {
        if (idx > 0) try body.append(alloc, ',');
        try body.appendSlice(alloc, "[\"");
        try appendJsonString(&body, value, alloc);
        try body.appendSlice(alloc, "\"]");
    }
    try body.appendSlice(alloc, "]}");

    const resp = try httpDoJson(client, .PATCH, url, token, body.items, alloc, retry_after_seconds);
    alloc.free(resp);
}

fn patchRangeFill(client: *std.http.Client, token: []const u8, drive_id: []const u8, item_id: []const u8, worksheet_id: []const u8, a1_range: []const u8, fill_hex: []const u8, alloc: Allocator, retry_after_seconds: ?*?u64) !void {
    const encoded_range = try encodeAddress(a1_range, alloc);
    defer alloc.free(encoded_range);
    const url = try std.fmt.allocPrint(
        alloc,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}/workbook/worksheets/{s}/range(address='{s}')/format/fill",
        .{ drive_id, item_id, worksheet_id, encoded_range },
    );
    defer alloc.free(url);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"color\":");
    try json_util.appendJsonQuoted(&body, fill_hex, alloc);
    try body.append(alloc, '}');
    const resp = try httpDoJson(client, .PATCH, url, token, body.items, alloc, retry_after_seconds);
    alloc.free(resp);
}

fn addWorksheet(client: *std.http.Client, token: []const u8, drive_id: []const u8, item_id: []const u8, title: []const u8, alloc: Allocator, retry_after_seconds: ?*?u64) !void {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://graph.microsoft.com/v1.0/drives/{s}/items/{s}/workbook/worksheets/add",
        .{ drive_id, item_id },
    );
    defer alloc.free(url);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, "{\"name\":");
    try json_util.appendJsonQuoted(&body, title, alloc);
    try body.append(alloc, '}');
    const resp = try httpDoJson(client, .POST, url, token, body.items, alloc, retry_after_seconds);
    alloc.free(resp);
}

fn httpDoJson(client: *std.http.Client, method: std.http.Method, url: []const u8, bearer_token: ?[]const u8, payload: ?[]const u8, alloc: Allocator, retry_after_seconds: ?*?u64) ![]u8 {
    return httpDoJsonWithContentType(client, method, url, bearer_token, payload, alloc, null, retry_after_seconds);
}

fn httpDoJsonWithContentType(client: *std.http.Client, method: std.http.Method, url: []const u8, bearer_token: ?[]const u8, payload: ?[]const u8, alloc: Allocator, content_type_override: ?[]const u8, retry_after_seconds: ?*?u64) ![]u8 {
    if (retry_after_seconds) |out| out.* = null;
    if (builtin.is_test) {
        if (test_http_mock) |mock| {
            return mock.handle(method, url, bearer_token, payload, content_type_override, retry_after_seconds, alloc);
        }
    }

    var headers_buf: [3]std.http.Header = undefined;
    var header_count: usize = 0;
    headers_buf[header_count] = .{ .name = "Accept", .value = "application/json" };
    header_count += 1;
    if (bearer_token) |token| {
        const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
        defer alloc.free(auth);
        headers_buf[header_count] = .{ .name = "Authorization", .value = auth };
        header_count += 1;
    }
    const content_type = content_type_override orelse "application/json";
    if (payload != null) {
        headers_buf[header_count] = .{ .name = "Content-Type", .value = content_type };
        header_count += 1;
    }

    const uri = std.Uri.parse(url) catch return error.ApiError;
    var req = client.request(method, uri, .{
        .extra_headers = headers_buf[0..header_count],
        .headers = .{
            .content_type = if (payload != null) .{ .override = content_type } else .omit,
        },
        .redirect_behavior = if (payload == null) @enumFromInt(3) else .unhandled,
    }) catch return error.ApiError;
    defer req.deinit();

    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch return error.ApiError;
        body_writer.writer.writeAll(p) catch return error.ApiError;
        body_writer.end() catch return error.ApiError;
        req.connection.?.flush() catch return error.ApiError;
    } else {
        req.sendBodiless() catch return error.ApiError;
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch return error.ApiError;
    captureRetryAfter(response.head, retry_after_seconds);

    switch (response.head.status) {
        .ok, .created, .accepted, .no_content => {},
        .unauthorized => return error.AuthError,
        .forbidden => return error.AccessDenied,
        .not_found => return error.NotFound,
        .too_many_requests => return error.Throttled,
        else => return error.ApiError,
    }

    var resp_body: std.Io.Writer.Allocating = .init(alloc);
    defer resp_body.deinit();
    try readResponseBody(&response, &resp_body.writer, alloc);
    return alloc.dupe(u8, resp_body.written());
}

fn readResponseBody(response: *std.http.Client.Response, response_writer: *std.Io.Writer, alloc: Allocator) !void {
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => alloc.alloc(u8, std.compress.zstd.default_window_len) catch return error.ApiError,
        .deflate, .gzip => alloc.alloc(u8, std.compress.flate.max_window_len) catch return error.ApiError,
        .compress => return error.ApiError,
    };
    defer if (decompress_buffer.len != 0) alloc.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(response_writer) catch return error.ApiError;
}

fn captureRetryAfter(head: std.http.Client.Response.Head, retry_after_seconds: ?*?u64) void {
    const out = retry_after_seconds orelse return;
    var header_iter = head.iterateHeaders();
    while (header_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            out.* = parseRetryAfterSeconds(header.value);
            return;
        }
    }
}

fn parseRetryAfterSeconds(value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch null;
}

const MockHttpExchange = struct {
    method: std.http.Method,
    url: []const u8,
    bearer_token: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    status: std.http.Status = .ok,
    body: []const u8 = "{}",
    retry_after_seconds: ?u64 = null,
};

const MockHttp = struct {
    exchanges: []const MockHttpExchange,
    index: usize = 0,

    fn handle(self: *MockHttp, method: std.http.Method, url: []const u8, bearer_token: ?[]const u8, payload: ?[]const u8, content_type: ?[]const u8, retry_after_seconds: ?*?u64, alloc: Allocator) ![]u8 {
        if (self.index >= self.exchanges.len) return error.InvalidResponse;
        const exchange = self.exchanges[self.index];
        self.index += 1;

        if (exchange.method != method) return error.InvalidResponse;
        if (!std.mem.eql(u8, exchange.url, url)) return error.InvalidResponse;
        if (exchange.bearer_token) |expected| {
            if (bearer_token == null or !std.mem.eql(u8, bearer_token.?, expected)) return error.InvalidResponse;
        }
        if (exchange.payload) |expected| {
            if (payload == null or !std.mem.eql(u8, payload.?, expected)) return error.InvalidResponse;
        }
        if (exchange.content_type) |expected| {
            if (content_type == null or !std.mem.eql(u8, content_type.?, expected)) return error.InvalidResponse;
        }

        switch (exchange.status) {
            .ok, .created, .accepted, .no_content => {},
            .unauthorized => return error.AuthError,
            .forbidden => return error.AccessDenied,
            .not_found => return error.NotFound,
            .too_many_requests => {
                if (retry_after_seconds) |out| out.* = exchange.retry_after_seconds;
                return error.Throttled;
            },
            else => return error.ApiError,
        }
        return alloc.dupe(u8, exchange.body);
    }

    fn expectDone(self: *const MockHttp) !void {
        try testing.expectEqual(self.exchanges.len, self.index);
    }
};

var test_http_mock: ?*MockHttp = null;

fn useMockHttp(mock: *MockHttp) void {
    test_http_mock = mock;
}

fn clearMockHttp() void {
    test_http_mock = null;
}

fn encodeSharingUrl(url: []const u8, alloc: Allocator) ![]u8 {
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(url.len);
    var buf = try alloc.alloc(u8, 2 + encoded_len);
    buf[0] = 'u';
    buf[1] = '!';
    _ = std.base64.url_safe_no_pad.Encoder.encode(buf[2..], url);
    return buf;
}

fn encodeAddress(address: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (address) |c| {
        switch (c) {
            ' ' => try buf.appendSlice(alloc, "%20"),
            '#' => try buf.appendSlice(alloc, "%23"),
            else => try buf.append(alloc, c),
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn parseValuesArrayJson(json_body: []const u8, alloc: Allocator) ![][][]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const values = json_util.getObjectField(root, "values") orelse return try alloc.alloc([][]const u8, 0);
    if (values != .array) return error.InvalidResponse;

    var rows: std.ArrayList([][]const u8) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |cell| alloc.free(cell);
            alloc.free(row);
        }
        rows.deinit(alloc);
    }

    for (values.array.items) |row_value| {
        if (row_value != .array) continue;
        var row: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (row.items) |cell| alloc.free(cell);
            row.deinit(alloc);
        }
        for (row_value.array.items) |cell_value| {
            try row.append(alloc, try jsonValueToString(cell_value, alloc));
        }
        try rows.append(alloc, try row.toOwnedSlice(alloc));
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

fn dupObjectString(value: std.json.Value, key: []const u8, alloc: Allocator) ![]u8 {
    const field = json_util.getObjectField(value, key) orelse return error.InvalidResponse;
    if (field != .string) return error.InvalidResponse;
    return alloc.dupe(u8, field.string);
}

fn objectInt(value: std.json.Value, key: []const u8) ?i64 {
    const field = json_util.getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => |v| v,
        else => null,
    };
}

const ParsedA1Range = struct {
    tab_title: []u8,
    range: []u8,

    fn deinit(self: ParsedA1Range, alloc: Allocator) void {
        alloc.free(self.tab_title);
        alloc.free(self.range);
    }
};

fn parseA1Range(a1_range: []const u8, alloc: Allocator) !ParsedA1Range {
    const bang = std.mem.indexOfScalar(u8, a1_range, '!') orelse return error.InvalidResponse;
    return .{
        .tab_title = try alloc.dupe(u8, a1_range[0..bang]),
        .range = try alloc.dupe(u8, a1_range[bang + 1 ..]),
    };
}

fn parseLastRowFromAddress(address: []const u8) !usize {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return 0;
    var end = address.len;
    while (end > colon and !std.ascii.isDigit(address[end - 1])) : (end -= 1) {}
    var start = end;
    while (start > colon and std.ascii.isDigit(address[start - 1])) : (start -= 1) {}
    if (start == end) return 0;
    return std.fmt.parseInt(usize, address[start..end], 10);
}

fn findTabId(tabs: []const common.TabRef, title: []const u8) ?[]const u8 {
    for (tabs) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, title)) return tab.native_id;
    }
    return null;
}

fn appendJsonString(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
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

fn columnLetters(index_1based: usize) []const u8 {
    return switch (index_1based) {
        1 => "A",
        2 => "B",
        3 => "C",
        4 => "D",
        5 => "E",
        6 => "F",
        7 => "G",
        8 => "H",
        9 => "I",
        10 => "J",
        11 => "K",
        12 => "L",
        13 => "M",
        14 => "N",
        15 => "O",
        16 => "P",
        17 => "Q",
        18 => "R",
        19 => "S",
        20 => "T",
        21 => "U",
        22 => "V",
        23 => "W",
        24 => "X",
        25 => "Y",
        26 => "Z",
        else => "Z",
    };
}

const testing = std.testing;

test "encodeSharingUrl prefixes u!" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const encoded = try encodeSharingUrl("https://example.com/test.xlsx", alloc);
    try testing.expect(std.mem.startsWith(u8, encoded, "u!"));
}

test "parseLastRowFromAddress parses usedRange address" {
    try testing.expectEqual(@as(usize, 47), try parseLastRowFromAddress("Requirements!A1:H47"));
    try testing.expectEqual(@as(usize, 9), try parseLastRowFromAddress("'User Needs'!A1:Z9"));
}

test "parseA1Range splits tab and range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try parseA1Range("Requirements!H2:H47", alloc);
    defer parsed.deinit(alloc);
    try testing.expectEqualStrings("Requirements", parsed.tab_title);
    try testing.expectEqualStrings("H2:H47", parsed.range);
}

test "acquireToken parses access token and expiry from mocked oauth response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .status = .ok,
                .body = "{\"access_token\":\"tok-123\",\"expires_in\":1200}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const token = try acquireToken(&client, "tenant", "client", "secret", alloc);
    defer alloc.free(token.access_token);
    try testing.expectEqualStrings("tok-123", token.access_token);
    try testing.expect(token.expires_at > std.time.timestamp());
    try mock.expectDone();
}

test "resolveWorkbookUrl resolves share url to drive and item ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const workbook_url = "https://tenant.sharepoint.com/:x:/r/sites/test/Shared%20Documents/RTMify.xlsx";
    const share_token = try encodeSharingUrl(workbook_url, alloc);
    defer alloc.free(share_token);
    const share_api = try std.fmt.allocPrint(alloc, "https://graph.microsoft.com/v1.0/shares/{s}/driveItem", .{share_token});
    defer alloc.free(share_api);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .GET,
                .url = share_api,
                .bearer_token = "graph-token",
                .body = "{\"id\":\"item-123\",\"name\":\"RTMify.xlsx\",\"parentReference\":{\"driveId\":\"drive-456\"}}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var resolved = try resolveWorkbookUrl(&client, "tenant", "client", "secret", workbook_url, alloc);
    defer resolved.deinit(alloc);
    try testing.expectEqualStrings("drive-456", resolved.drive_id);
    try testing.expectEqualStrings("item-123", resolved.item_id);
    try testing.expectEqualStrings("RTMify.xlsx", resolved.workbook_label);
    try mock.expectDone();
}

fn testActiveConnectionExcel(alloc: Allocator) !common.ActiveConnection {
    return .{
        .platform = .excel,
        .credential_json = try alloc.dupe(u8, "{\"platform\":\"excel\",\"tenant_id\":\"tenant\",\"client_id\":\"client\",\"client_secret\":\"secret\"}"),
        .workbook_url = try alloc.dupe(u8, "https://tenant.sharepoint.com/:x:/r/sites/test/Shared%20Documents/RTMify.xlsx"),
        .workbook_label = try alloc.dupe(u8, "RTMify.xlsx"),
        .credential_display = try alloc.dupe(u8, "Tenant tenant / App client"),
        .target = .{ .excel = .{
            .drive_id = try alloc.dupe(u8, "drive-456"),
            .item_id = try alloc.dupe(u8, "item-123"),
        } },
    };
}

test "runtime readRows uses worksheets, usedRange, and range endpoints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets",
                .bearer_token = "graph-token",
                .body = "{\"value\":[{\"id\":\"sheet-req\",\"name\":\"Requirements\"}]}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/usedRange(valuesOnly=true)",
                .bearer_token = "graph-token",
                .body = "{\"address\":\"Requirements!A1:H3\"}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/range(address='A1:Z3')",
                .bearer_token = "graph-token",
                .body = "{\"values\":[[\"ID\",\"Statement\"],[\"REQ-1\",\"Do thing\"],[\"REQ-2\",\"Do other thing\"]]}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    const rows = try runtime.readRows("Requirements", alloc);
    defer common.freeRows(rows, alloc);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("REQ-1", rows[1][0]);
    try testing.expectEqualStrings("Do other thing", rows[2][1]);
    try mock.expectDone();
}

test "runtime readRows caches worksheets across reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets",
                .bearer_token = "graph-token",
                .body = "{\"value\":[{\"id\":\"sheet-req\",\"name\":\"Requirements\"}]}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/usedRange(valuesOnly=true)",
                .bearer_token = "graph-token",
                .body = "{\"address\":\"Requirements!A1:A1\"}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/range(address='A1:Z1')",
                .bearer_token = "graph-token",
                .body = "{\"values\":[[\"ID\"]]}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/usedRange(valuesOnly=true)",
                .bearer_token = "graph-token",
                .body = "{\"address\":\"Requirements!A1:A1\"}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/range(address='A1:Z1')",
                .bearer_token = "graph-token",
                .body = "{\"values\":[[\"ID\"]]}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    const first = try runtime.readRows("Requirements", alloc);
    defer common.freeRows(first, alloc);
    const second = try runtime.readRows("Requirements", alloc);
    defer common.freeRows(second, alloc);
    try mock.expectDone();
}

test "runtime batchWriteValues patches excel range values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets",
                .bearer_token = "graph-token",
                .body = "{\"value\":[{\"id\":\"sheet-req\",\"name\":\"Requirements\"}]}",
            },
            .{
                .method = .PATCH,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/range(address='H2:H3')",
                .bearer_token = "graph-token",
                .payload = "{\"values\":[[\"OK\"],[\"MISSING\"]]}",
                .body = "{}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    const updates = [_]common.ValueUpdate{
        .{ .a1_range = "Requirements!H2:H3", .values = &.{ "OK", "MISSING" } },
    };
    try runtime.batchWriteValues(&updates, alloc);
    try mock.expectDone();
}

test "runtime applyRowFormats patches fill color ranges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets",
                .bearer_token = "graph-token",
                .body = "{\"value\":[{\"id\":\"sheet-req\",\"name\":\"Requirements\"}]}",
            },
            .{
                .method = .PATCH,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/sheet-req/range(address='A2:H2')/format/fill",
                .bearer_token = "graph-token",
                .payload = "{\"color\":\"#B6E1CD\"}",
                .body = "{}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    const reqs = [_]common.RowFormat{
        .{ .tab_title = "Requirements", .row_1based = 2, .col_start_1based = 1, .col_end_1based = 8, .fill_hex = "#B6E1CD" },
    };
    try runtime.applyRowFormats(&reqs, alloc);
    try mock.expectDone();
}

test "runtime createTab calls worksheet add endpoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .POST,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/add",
                .bearer_token = "graph-token",
                .payload = "{\"name\":\"Design Inputs\"}",
                .body = "{}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    try runtime.createTab("Design Inputs", alloc);
    try mock.expectDone();
}

test "runtime createTab invalidates worksheet cache" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets",
                .bearer_token = "graph-token",
                .body = "{\"value\":[{\"id\":\"sheet-req\",\"name\":\"Requirements\"}]}",
            },
            .{
                .method = .POST,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/add",
                .bearer_token = "graph-token",
                .payload = "{\"name\":\"Design Inputs\"}",
                .body = "{}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets",
                .bearer_token = "graph-token",
                .body = "{\"value\":[{\"id\":\"sheet-req\",\"name\":\"Requirements\"},{\"id\":\"sheet-di\",\"name\":\"Design Inputs\"}]}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    const before = try runtime.listTabs(alloc);
    defer common.freeTabRefs(before, alloc);
    try testing.expectEqual(@as(usize, 1), before.len);
    try runtime.createTab("Design Inputs", alloc);
    const after = try runtime.listTabs(alloc);
    defer common.freeTabRefs(after, alloc);
    try testing.expectEqual(@as(usize, 2), after.len);
    try mock.expectDone();
}

test "runtime createTab escapes worksheet titles containing quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var runtime = Runtime{
        .http_client = .{ .allocator = alloc },
        .tenant_id = try alloc.dupe(u8, "tenant"),
        .client_id = try alloc.dupe(u8, "client"),
        .client_secret = try alloc.dupe(u8, "secret"),
        .drive_id = try alloc.dupe(u8, "drive-456"),
        .item_id = try alloc.dupe(u8, "item-123"),
        .workbook_url = try alloc.dupe(u8, "https://tenant.sharepoint.com/x"),
        .workbook_label = try alloc.dupe(u8, "RTMify.xlsx"),
        .token_cache = .{ .access_token = try alloc.dupe(u8, "graph-token"), .expires_at = std.time.timestamp() + 3600 },
    };
    defer runtime.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/add",
                .bearer_token = "graph-token",
                .payload = "{\"name\":\"Design \\\"Inputs\\\"\"}",
                .body = "{}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    try runtime.createTab("Design \"Inputs\"", alloc);
    try mock.expectDone();
}

test "runtime createTab escapes worksheet titles containing backslashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var runtime = Runtime{
        .http_client = .{ .allocator = alloc },
        .tenant_id = try alloc.dupe(u8, "tenant"),
        .client_id = try alloc.dupe(u8, "client"),
        .client_secret = try alloc.dupe(u8, "secret"),
        .drive_id = try alloc.dupe(u8, "drive-456"),
        .item_id = try alloc.dupe(u8, "item-123"),
        .workbook_url = try alloc.dupe(u8, "https://tenant.sharepoint.com/x"),
        .workbook_label = try alloc.dupe(u8, "RTMify.xlsx"),
        .token_cache = .{ .access_token = try alloc.dupe(u8, "graph-token"), .expires_at = std.time.timestamp() + 3600 },
    };
    defer runtime.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123/workbook/worksheets/add",
                .bearer_token = "graph-token",
                .payload = "{\"name\":\"Design\\\\Inputs\"}",
                .body = "{}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    try runtime.createTab("Design\\Inputs", alloc);
    try mock.expectDone();
}

test "throttled graph response maps to error.Throttled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .status = .too_many_requests,
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    try testing.expectError(error.Throttled, acquireToken(&client, "tenant", "client", "secret", alloc));
    try mock.expectDone();
}

test "Retry-After parser accepts numeric seconds only" {
    try testing.expectEqual(@as(?u64, 5), parseRetryAfterSeconds("5"));
    try testing.expectEqual(@as(?u64, 5), parseRetryAfterSeconds(" 5\t"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT"));
    try testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("soon"));
}

test "runtime captures numeric Retry-After on throttled graph response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
            .{
                .method = .GET,
                .url = "https://graph.microsoft.com/v1.0/drives/drive-456/items/item-123?$select=lastModifiedDateTime,name,webUrl",
                .bearer_token = "graph-token",
                .status = .too_many_requests,
                .retry_after_seconds = 5,
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    try testing.expectError(error.Throttled, runtime.changeToken(alloc));
    try testing.expectEqual(@as(?u64, 5), runtime.takeRetryAfterSeconds());
    try testing.expectEqual(@as(?u64, null), runtime.takeRetryAfterSeconds());
    try mock.expectDone();
}

test "getToken returns owned copies from the cache" {
    const alloc = testing.allocator;

    var active = try testActiveConnectionExcel(alloc);
    defer active.deinit(alloc);

    var mock = MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = "https://login.microsoftonline.com/tenant/oauth2/v2.0/token",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"graph-token\",\"expires_in\":3600}",
            },
        },
    };
    useMockHttp(&mock);
    defer clearMockHttp();

    var runtime = try Runtime.init(active, alloc);
    defer runtime.deinit(alloc);

    const first = try runtime.getToken(alloc);
    defer alloc.free(first);
    const second = try runtime.getToken(alloc);
    defer alloc.free(second);
    try testing.expectEqualStrings("graph-token", first);
    try testing.expectEqualStrings("graph-token", second);
    try testing.expect(first.ptr != runtime.token_cache.access_token.?.ptr);
    try testing.expect(second.ptr != runtime.token_cache.access_token.?.ptr);
    try testing.expect(first.ptr != second.ptr);
    try mock.expectDone();
}
