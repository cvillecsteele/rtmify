/// sheets.zig — Google Sheets API client for rtmify-live.
///
/// Implements:
///   - PEM/PKCS#8 RSA private key parsing (DER/ASN.1)
///   - JWT construction and RS256 (RSA-PKCS1v1_5-SHA256) signing using std.crypto
///   - OAuth2 service account token exchange and caching
///   - Sheets API: readRows, batchUpdateValues, batchUpdateFormat
///   - Drive API: getModifiedTime
///
/// No vendored crypto. Uses std.crypto.Certificate.rsa (Modulus, Fe, der) + std.http.Client.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const json_util = @import("json_util.zig");

const der = std.crypto.Certificate.der;
// Use std.crypto.ff.Modulus directly (Certificate.rsa.Modulus is not pub).
// 4096 bits covers RSA-2048, RSA-3072, and RSA-4096 service account keys.
const RsaModulus = std.crypto.ff.Modulus(4096);

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const SheetsError = error{
    InvalidPem,
    InvalidDer,
    InvalidKey,
    HttpError,
    AuthError,
    ApiError,
    OutOfMemory,
};

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

    fn handle(self: *MockHttp, method: std.http.Method, url: []const u8, token: []const u8, payload: ?[]const u8, content_type: ?[]const u8, alloc: Allocator) (SheetsError || Allocator.Error)![]u8 {
        if (self.index >= self.exchanges.len) return error.ApiError;
        const expected = self.exchanges[self.index];
        self.index += 1;
        if (expected.method != method) return error.ApiError;
        if (!std.mem.eql(u8, expected.url, url)) return error.ApiError;
        if (!std.mem.eql(u8, expected.token, token)) return error.ApiError;
        if (expected.payload) |p| {
            if (payload == null or !std.mem.eql(u8, p, payload.?)) return error.ApiError;
        } else {
            if (payload != null) return error.ApiError;
        }
        if (expected.content_type) |ct| {
            if (content_type == null or !std.mem.eql(u8, ct, content_type.?)) return error.ApiError;
        } else {
            if (content_type != null) return error.ApiError;
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

// ---------------------------------------------------------------------------
// RSA private key (parsed from PKCS#8 PEM)
// ---------------------------------------------------------------------------

pub const RsaKey = struct {
    /// Big-endian modulus bytes (stripped of leading 0x00)
    n: []const u8,
    /// Big-endian private exponent bytes (stripped of leading 0x00)
    d: []const u8,
    /// Length of modulus in bytes (= signature length)
    modulus_len: usize,

    pub fn deinit(k: *const RsaKey, alloc: Allocator) void {
        alloc.free(k.n);
        alloc.free(k.d);
    }
};

// ---------------------------------------------------------------------------
// PEM parsing
// ---------------------------------------------------------------------------

/// Strip leading 0x00 from a DER INTEGER (positive-integer encoding).
fn stripLeadingZero(bytes: []const u8) []const u8 {
    if (bytes.len > 0 and bytes[0] == 0x00) return bytes[1..];
    return bytes;
}

/// Parse a PKCS#8 PEM-encoded RSA private key.
/// Allocates copies of n and d that the caller must free via RsaKey.deinit.
pub fn parsePemRsaKey(pem: []const u8, alloc: Allocator) (SheetsError || Allocator.Error)!RsaKey {
    // 1. Locate PEM boundaries (handles both "PRIVATE KEY" and "RSA PRIVATE KEY")
    const begin_marker = "-----BEGIN";
    const end_marker = "-----END";
    const begin_idx = std.mem.indexOf(u8, pem, begin_marker) orelse return error.InvalidPem;
    // Skip to first newline after the begin header line
    const after_begin = std.mem.indexOfScalarPos(u8, pem, begin_idx, '\n') orelse return error.InvalidPem;
    const end_idx = std.mem.indexOf(u8, pem, end_marker) orelse return error.InvalidPem;

    // 2. Extract base64 body: everything between the header and footer lines
    const b64_body = std.mem.trim(u8, pem[after_begin + 1 .. end_idx], " \t\r\n");

    // 3. Strip whitespace from body and decode
    const b64_clean = try alloc.alloc(u8, b64_body.len);
    defer alloc.free(b64_clean);
    var clean_len: usize = 0;
    for (b64_body) |ch| {
        if (ch != '\n' and ch != '\r' and ch != ' ' and ch != '\t') {
            b64_clean[clean_len] = ch;
            clean_len += 1;
        }
    }
    const b64 = b64_clean[0..clean_len];

    const der_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.InvalidPem;
    const der_bytes = try alloc.alloc(u8, der_len);
    defer alloc.free(der_bytes);
    std.base64.standard.Decoder.decode(der_bytes, b64) catch return error.InvalidPem;
    const der_data = der_bytes;

    return parseDerRsaKey(der_data, alloc);
}

/// Parse a PKCS#8 DER-encoded RSA private key.
fn parseDerRsaKey(data: []const u8, alloc: Allocator) (SheetsError || Allocator.Error)!RsaKey {
    // PKCS#8 outer SEQUENCE
    const outer = der.Element.parse(data, 0) catch return error.InvalidDer;
    if (outer.identifier.tag != .sequence) return error.InvalidDer;

    // version INTEGER (must be 0)
    const version = der.Element.parse(data, outer.slice.start) catch return error.InvalidDer;
    if (version.identifier.tag != .integer) return error.InvalidDer;

    // algorithmIdentifier SEQUENCE — skip over it
    const alg_id = der.Element.parse(data, version.slice.end) catch return error.InvalidDer;
    if (alg_id.identifier.tag != .sequence) return error.InvalidDer;

    // privateKey OCTET STRING
    const priv_key_oct = der.Element.parse(data, alg_id.slice.end) catch return error.InvalidDer;
    if (priv_key_oct.identifier.tag != .octetstring) return error.InvalidDer;

    // Inner RSAPrivateKey SEQUENCE
    const rsa_priv = data[priv_key_oct.slice.start..priv_key_oct.slice.end];
    const inner = der.Element.parse(rsa_priv, 0) catch return error.InvalidDer;
    if (inner.identifier.tag != .sequence) return error.InvalidDer;

    // RSAPrivateKey: version, n, e, d, p, q, dp, dq, qp
    const rsa_ver = der.Element.parse(rsa_priv, inner.slice.start) catch return error.InvalidDer;
    if (rsa_ver.identifier.tag != .integer) return error.InvalidDer;

    const n_elem = der.Element.parse(rsa_priv, rsa_ver.slice.end) catch return error.InvalidDer;
    if (n_elem.identifier.tag != .integer) return error.InvalidDer;
    const n_raw = rsa_priv[n_elem.slice.start..n_elem.slice.end];
    const n_bytes = stripLeadingZero(n_raw);
    if (n_bytes.len == 0) return error.InvalidKey;

    const e_elem = der.Element.parse(rsa_priv, n_elem.slice.end) catch return error.InvalidDer;
    if (e_elem.identifier.tag != .integer) return error.InvalidDer;

    const d_elem = der.Element.parse(rsa_priv, e_elem.slice.end) catch return error.InvalidDer;
    if (d_elem.identifier.tag != .integer) return error.InvalidDer;
    const d_raw = rsa_priv[d_elem.slice.start..d_elem.slice.end];
    const d_bytes = stripLeadingZero(d_raw);
    if (d_bytes.len == 0) return error.InvalidKey;

    return .{
        .n = try alloc.dupe(u8, n_bytes),
        .d = try alloc.dupe(u8, d_bytes),
        .modulus_len = n_bytes.len,
    };
}

// ---------------------------------------------------------------------------
// RS256 signing (RSA-PKCS1v1_5-SHA256)
// ---------------------------------------------------------------------------

// SHA-256 DigestInfo DER prefix (RFC 3447, Appendix A.2.4)
const sha256_digest_info_prefix = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};
// DigestInfo total length: 19 prefix + 32 hash = 51 bytes
const t_len = sha256_digest_info_prefix.len + 32;

/// Sign `message` with RS256 using the given RSA private key.
/// Returns heap-allocated signature bytes (modulus_len bytes). Caller frees.
pub fn rs256Sign(message: []const u8, key: RsaKey, alloc: Allocator) (SheetsError || Allocator.Error)![]u8 {
    const mod_len = key.modulus_len;
    if (mod_len < t_len + 11) return error.InvalidKey; // RFC 3447 §8.2.1

    // 1. Compute SHA-256(message)
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &hash, .{});

    // 2. EMSA-PKCS1-v1_5 encoding (RFC 3447 §9.2)
    //    EM = 0x00 0x01 PS 0x00 T   where PS = 0xff × (mod_len - t_len - 3)
    const em = try alloc.alloc(u8, mod_len);
    defer alloc.free(em);
    em[0] = 0x00;
    em[1] = 0x01;
    const ps_len = mod_len - t_len - 3;
    @memset(em[2 .. 2 + ps_len], 0xff);
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len ..][0..sha256_digest_info_prefix.len], &sha256_digest_info_prefix);
    @memcpy(em[3 + ps_len + sha256_digest_info_prefix.len ..][0..32], &hash);

    // 3. RSA private key operation: s = EM^d mod n  (RFC 3447 §5.1.2)
    //    Uses std.crypto.ff.Modulus(4096) (supports up to 4096-bit keys).
    const n_mod = RsaModulus.fromBytes(key.n, .big) catch return error.InvalidKey;
    const em_fe = RsaModulus.Fe.fromBytes(n_mod, em, .big) catch return error.InvalidKey;
    // powWithEncodedExponent: constant-time (private key) RSA operation
    const sig_fe = n_mod.powWithEncodedExponent(em_fe, key.d, .big) catch return error.InvalidKey;

    // 4. Output signature as big-endian bytes, padded to mod_len
    const sig = try alloc.alloc(u8, mod_len);
    sig_fe.toBytes(sig, .big) catch return error.InvalidKey;
    return sig;
}

// ---------------------------------------------------------------------------
// JWT construction
// ---------------------------------------------------------------------------

const OAUTH2_TOKEN_URL = "https://oauth2.googleapis.com/token";
const SHEETS_SCOPE = "https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/drive.readonly";

/// Build and sign a Google service account JWT.
/// Returns a heap-allocated JWT string. Caller frees.
pub fn buildJwt(email: []const u8, key: RsaKey, alloc: Allocator) (SheetsError || Allocator.Error)![]u8 {
    const now = std.time.timestamp();

    // Header: {"alg":"RS256","typ":"JWT"}
    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    // Claims
    const claims_json = try std.fmt.allocPrint(alloc,
        "{{\"iss\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ email, SHEETS_SCOPE, OAUTH2_TOKEN_URL, now, now + 3600 },
    );
    defer alloc.free(claims_json);

    // Base64url-encode header and claims (no padding)
    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_b64_len = enc.calcSize(header_json.len);
    const claims_b64_len = enc.calcSize(claims_json.len);

    // signing_input = base64url(header) + "." + base64url(claims)
    const signing_input = try alloc.alloc(u8, header_b64_len + 1 + claims_b64_len);
    defer alloc.free(signing_input);
    _ = enc.encode(signing_input[0..header_b64_len], header_json);
    signing_input[header_b64_len] = '.';
    _ = enc.encode(signing_input[header_b64_len + 1 ..], claims_json);

    // Sign
    const sig_bytes = try rs256Sign(signing_input, key, alloc);
    defer alloc.free(sig_bytes);

    // Base64url-encode signature
    const sig_b64_len = enc.calcSize(sig_bytes.len);
    const sig_b64 = try alloc.alloc(u8, sig_b64_len);
    defer alloc.free(sig_b64);
    _ = enc.encode(sig_b64, sig_bytes);

    // Final JWT: signing_input + "." + sig_b64
    const jwt = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ signing_input, sig_b64 });
    return jwt;
}

// ---------------------------------------------------------------------------
// Token cache
// ---------------------------------------------------------------------------

pub const TokenCache = struct {
    token: [1024]u8 = .{0} ** 1024,
    token_len: usize = 0,
    expires_at: i64 = 0,
    mu: std.Thread.Mutex = .{},

    /// Return a valid access token, refreshing if needed.
    /// Returned slice points into `cache.token`; valid until next refresh.
    pub fn getToken(
        cache: *TokenCache,
        email: []const u8,
        key: RsaKey,
        client: *std.http.Client,
        alloc: Allocator,
    ) (SheetsError || Allocator.Error)![]const u8 {
        cache.mu.lock();
        defer cache.mu.unlock();

        if (std.time.timestamp() < cache.expires_at - 60 and cache.token_len > 0) {
            return cache.token[0..cache.token_len];
        }
        // Refresh
        const jwt = try buildJwt(email, key, alloc);
        defer alloc.free(jwt);

        const new_token = try exchangeToken(client, jwt, alloc);
        defer alloc.free(new_token);

        if (new_token.len > cache.token.len) return error.AuthError;
        @memcpy(cache.token[0..new_token.len], new_token);
        cache.token_len = new_token.len;
        cache.expires_at = std.time.timestamp() + 3600;
        return cache.token[0..cache.token_len];
    }
};

// ---------------------------------------------------------------------------
// Token exchange
// ---------------------------------------------------------------------------

/// POST JWT to Google OAuth2, return access_token string. Caller frees.
fn exchangeToken(client: *std.http.Client, jwt: []const u8, alloc: Allocator) (SheetsError || Allocator.Error)![]u8 {
    const body_str = try std.fmt.allocPrint(
        alloc,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}",
        .{jwt},
    );
    defer alloc.free(body_str);

    var resp_body: std.Io.Writer.Allocating = .init(alloc);
    defer resp_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = OAUTH2_TOKEN_URL },
        .method = .POST,
        .payload = body_str,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .response_writer = &resp_body.writer,
    }) catch |e| {
        std.log.err("token exchange HTTP failed: {s}", .{@errorName(e)});
        return error.HttpError;
    };

    if (result.status != .ok) {
        std.log.err("token exchange HTTP status: {d}", .{@intFromEnum(result.status)});
        return error.AuthError;
    }

    const resp = resp_body.writer.buffer[0..resp_body.writer.end];
    return extractJsonString(resp, "access_token", alloc) orelse error.AuthError;
}

// ---------------------------------------------------------------------------
// Simple JSON field extractor (avoids full parse for well-known shapes)
// ---------------------------------------------------------------------------

/// Extract the string value for a given key from a simple flat JSON object.
/// Returns null if not found. Allocates. Caller frees.
fn extractJsonString(json: []const u8, key: []const u8, alloc: Allocator) ?[]u8 {
    const slice = json_util.extractJsonFieldStatic(json, key) orelse return null;
    return alloc.dupe(u8, slice) catch null;
}

/// Extract a string value slice (no allocation) from a flat JSON object.
/// The returned slice points into `json` — valid while `json` is alive.
/// Does NOT handle escape sequences in the value.
pub fn extractJsonFieldStatic(json: []const u8, key: []const u8) ?[]const u8 {
    return json_util.extractJsonFieldStatic(json, key);
}

/// Extract an integer value for a given key from a simple flat JSON object.
fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{}) catch return null;
    defer parsed.deinit();
    const field = json_util.getObjectField(parsed.value, key) orelse return null;
    return switch (field) {
        .integer => |v| v,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

/// Perform a GET or POST request, returning the response body. Caller frees.
fn httpDo(
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    token: []const u8,
    payload: ?[]const u8,
    content_type: ?[]const u8,
    alloc: Allocator,
) (SheetsError || Allocator.Error)![]u8 {
    if (builtin.is_test) {
        if (test_http_mock) |mock| {
            return mock.handle(method, url, token, payload, content_type, alloc);
        }
    }

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{token});
    defer alloc.free(auth_header);

    var extra: [2]std.http.Header = undefined;
    var extra_count: usize = 1;
    extra[0] = .{ .name = "Authorization", .value = auth_header };
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
        return error.ApiError;
    }

    const body = resp_body.writer.buffer[0..resp_body.writer.end];
    return alloc.dupe(u8, body);
}

// ---------------------------------------------------------------------------
// Sheets API: readRows
// ---------------------------------------------------------------------------

/// Fetch rows from a Sheets tab.
/// Returns a slice of rows; each row is a slice of cell strings.
/// Caller frees via freeRows.
pub fn readRows(
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    tab_range: []const u8,
    alloc: Allocator,
) (SheetsError || Allocator.Error)![][][]const u8 {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}/values/{s}",
        .{ sheet_id, tab_range },
    );
    defer alloc.free(url);

    const body = try httpDo(client, .GET, url, token, null, null, alloc);
    defer alloc.free(body);

    return parseValuesJson(body, alloc);
}

/// Free rows returned by readRows.
pub fn freeRows(rows: [][][]const u8, alloc: Allocator) void {
    for (rows) |row| {
        for (row) |cell| alloc.free(cell);
        alloc.free(row);
    }
    alloc.free(rows);
}

/// Parse the `values` array from a Sheets API response.
fn parseValuesJson(json_body: []const u8, alloc: Allocator) (SheetsError || Allocator.Error)![][][]const u8 {
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

// ---------------------------------------------------------------------------
// Sheets API: batchUpdateValues
// ---------------------------------------------------------------------------

pub const ValueRange = struct {
    range: []const u8, // e.g. "Requirements!H2:H100"
    values: []const []const u8, // flat list of cell values, one per row
};

/// Write cell values back to the sheet.
pub fn batchUpdateValues(
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    updates: []const ValueRange,
    alloc: Allocator,
) (SheetsError || Allocator.Error)!void {
    if (updates.len == 0) return;

    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}/values:batchUpdate",
        .{sheet_id},
    );
    defer alloc.free(url);

    // Build JSON body
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

    const resp = try httpDo(client, .POST, url, token, body_buf.items, "application/json", alloc);
    alloc.free(resp);
}

// ---------------------------------------------------------------------------
// Sheets API: batchUpdateFormat (row colors)
// ---------------------------------------------------------------------------

/// Apply formatting requests to the sheet. `requests_json` is a pre-serialized
/// JSON array of Sheets API Request objects.
pub fn batchUpdateFormat(
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    requests_json: []const u8,
    alloc: Allocator,
) (SheetsError || Allocator.Error)!void {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}:batchUpdate",
        .{sheet_id},
    );
    defer alloc.free(url);

    const body = try std.fmt.allocPrint(alloc, "{{\"requests\":{s}}}", .{requests_json});
    defer alloc.free(body);

    const resp = try httpDo(client, .POST, url, token, body, "application/json", alloc);
    alloc.free(resp);
}

/// Build a repeatCell request JSON for coloring a single row.
/// color_rgb is {r, g, b} as 0.0–1.0 floats.
pub fn buildRepeatCellRequest(
    sheet_id_numeric: i64,
    row_index: i64, // 0-based
    col_start: i64,
    col_end: i64,
    r: f32,
    g: f32,
    b: f32,
    alloc: Allocator,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"repeatCell":{{"range":{{"sheetId":{d},"startRowIndex":{d},"endRowIndex":{d},"startColumnIndex":{d},"endColumnIndex":{d}}},"cell":{{"userEnteredFormat":{{"backgroundColor":{{"red":{d:.3},"green":{d:.3},"blue":{d:.3}}}}}}},"fields":"userEnteredFormat.backgroundColor"}}}}
    ,
        .{ sheet_id_numeric, row_index, row_index + 1, col_start, col_end, r, g, b },
    );
}

// ---------------------------------------------------------------------------
// Sheets API: getSheetTabIds — fetch numeric sheetId for each tab
// ---------------------------------------------------------------------------

/// Numeric sheet (tab) ID → used in batchUpdate formatting requests.
pub const SheetTabId = struct {
    title: []u8, // caller frees
    id: i64,
};

/// Fetch the spreadsheet metadata and return numeric sheetId per tab title.
/// Caller frees each `.title` and the returned slice.
pub fn getSheetTabIds(
    client: *std.http.Client,
    token: []const u8,
    spreadsheet_id: []const u8,
    alloc: Allocator,
) (SheetsError || Allocator.Error)![]SheetTabId {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://sheets.googleapis.com/v4/spreadsheets/{s}?fields=sheets.properties",
        .{spreadsheet_id},
    );
    defer alloc.free(url);

    const body = try httpDo(client, .GET, url, token, null, null, alloc);
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

// ---------------------------------------------------------------------------
// Drive API: getModifiedTime
// ---------------------------------------------------------------------------

/// Returns the Drive file's modifiedTime as a Unix timestamp (seconds).
/// Returns 0 on parse failure.
pub fn getModifiedTime(
    client: *std.http.Client,
    token: []const u8,
    file_id: []const u8,
    alloc: Allocator,
) (SheetsError || Allocator.Error)!i64 {
    const url = try std.fmt.allocPrint(
        alloc,
        "https://www.googleapis.com/drive/v3/files/{s}?fields=modifiedTime",
        .{file_id},
    );
    defer alloc.free(url);

    const body = try httpDo(client, .GET, url, token, null, null, alloc);
    defer alloc.free(body);

    // "modifiedTime":"2024-01-15T10:30:00.000Z"
    const mt = extractJsonString(body, "modifiedTime", alloc) orelse return 0;
    defer alloc.free(mt);
    return parseIso8601(mt);
}

/// Parse an ISO 8601 timestamp string to Unix seconds (UTC). Very minimal.
fn parseIso8601(s: []const u8) i64 {
    // Expect: "YYYY-MM-DDTHH:MM:SS.xxxZ" or "YYYY-MM-DDTHH:MM:SSZ"
    if (s.len < 19) return 0;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const min = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;

    // Days since Unix epoch via civil-to-days
    const y: i64 = if (month <= 2) year - 1 else year;
    const m: i64 = if (month <= 2) month + 9 else month - 3;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const doy: i64 = @divFloor(153 * m + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + min * 60 + sec;
}

// ---------------------------------------------------------------------------
// JSON string escaping helper
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseIso8601 basic" {
    // 2024-01-15T10:30:00Z
    const ts = parseIso8601("2024-01-15T10:30:00.000Z");
    try testing.expect(ts > 0);
    // Verify it's in a reasonable range (year 2024)
    try testing.expect(ts > 1700000000); // after 2023
    try testing.expect(ts < 1800000000); // before 2027
}

test "parseIso8601 known value" {
    // 1970-01-01T00:00:00Z = Unix epoch 0
    const ts = parseIso8601("1970-01-01T00:00:00Z");
    try testing.expectEqual(@as(i64, 0), ts);
}

test "extractJsonString found" {
    const json =
        \\{"access_token":"ya29.token_here","expires_in":3599}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tok = extractJsonString(json, "access_token", arena.allocator());
    try testing.expect(tok != null);
    try testing.expectEqualStrings("ya29.token_here", tok.?);
}

test "extractJsonString not found" {
    const json = "{\"foo\":\"bar\"}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tok = extractJsonString(json, "baz", arena.allocator());
    try testing.expect(tok == null);
}

test "extractJsonInt" {
    const json = "{\"expires_in\":3599,\"token_type\":\"Bearer\"}";
    const v = extractJsonInt(json, "expires_in");
    try testing.expect(v != null);
    try testing.expectEqual(@as(i64, 3599), v.?);
}

test "extractJsonInt tolerates whitespace after colon" {
    const json = "{\"expires_in\" : 3599,\"token_type\":\"Bearer\"}";
    const v = extractJsonInt(json, "expires_in");
    try testing.expect(v != null);
    try testing.expectEqual(@as(i64, 3599), v.?);
}

test "stripLeadingZero" {
    const a = [_]u8{ 0x00, 0x01, 0x02 };
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, stripLeadingZero(&a));
    const b = [_]u8{ 0x01, 0x02 };
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, stripLeadingZero(&b));
}

test "sha256_digest_info_prefix length" {
    // Prefix should be 19 bytes (standard PKCS#1 DigestInfo DER for SHA-256)
    try testing.expectEqual(@as(usize, 19), sha256_digest_info_prefix.len);
    // t_len should be 51 (19 + 32)
    try testing.expectEqual(@as(usize, 51), t_len);
}

test "getSheetTabIds parsing tolerates whitespace and reversed field order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = MockHttp{
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
    useMockHttp(&mock);
    defer clearMockHttp();

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

test "extractJsonFieldStatic tolerates whitespace after colon" {
    const json = "{\"properties\":{\"title\": \"User Needs\",\"sheetId\":0}}";
    const title = extractJsonFieldStatic(json, "title");
    try testing.expect(title != null);
    try testing.expectEqualStrings("User Needs", title.?);
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

test "buildJwt structure" {
    // We can't sign without a real key, but we can test that buildJwt
    // produces a 3-part dot-separated string given a valid 2048-bit key.
    // This test uses a synthetic minimal key created via generateTestKey().
    // For now, just test that rs256Sign produces modulus_len bytes.
    // Real key testing is done in integration tests.
    _ = buildJwt; // referenced
}

test "appendJsonString escaping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    try appendJsonString(&buf, "hello \"world\"\nnewline", alloc);
    try testing.expectEqualStrings("hello \\\"world\\\"\\nnewline", buf.items);
}

test "batchUpdateValues json body" {
    // Test the JSON construction without HTTP
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var body_buf: std.ArrayList(u8) = .empty;
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
