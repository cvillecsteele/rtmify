const std = @import("std");
const Allocator = std.mem.Allocator;

pub const test_results_body_limit_bytes = 10 * 1024 * 1024;
pub const bom_body_limit_bytes = 25 * 1024 * 1024;
pub const payload_too_large_json = "{\"error\":\"payload_too_large\"}";

pub fn requestHeaderValue(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return std.mem.trim(u8, header.value, " \t");
        }
    }
    return null;
}

pub fn readBody(req: *std.http.Server.Request, alloc: Allocator) ![]u8 {
    return readBodyLimited(req, alloc, 1024 * 1024);
}

pub fn readBodyLimited(req: *std.http.Server.Request, alloc: Allocator, max_bytes: usize) ![]u8 {
    const body_buf = try alloc.alloc(u8, max_bytes);
    defer alloc.free(body_buf);
    const reader = req.readerExpectNone(body_buf);
    return readReaderLimited(reader, alloc, max_bytes);
}

pub fn readReaderLimited(reader: anytype, alloc: Allocator, max_bytes: usize) ![]u8 {
    if (@TypeOf(reader) == *std.Io.Reader) {
        return readIoReaderLimited(reader, alloc, max_bytes);
    }
    return reader.readAllAlloc(alloc, max_bytes);
}

pub fn readIoReaderLimited(reader: *std.Io.Reader, alloc: Allocator, max_bytes: usize) ![]u8 {
    return reader.allocRemaining(alloc, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => error.StreamTooLong,
        else => err,
    };
}

pub fn queryParamRaw(target: []const u8, key: []const u8) ?[]const u8 {
    const q_pos = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[q_pos + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

pub fn queryParamDecoded(target: []const u8, key: []const u8, alloc: Allocator) !?[]u8 {
    const raw = queryParamRaw(target, key) orelse return null;
    const buf = try alloc.dupe(u8, raw);
    for (buf) |*c| {
        if (c.* == '+') c.* = ' ';
    }
    return std.Uri.percentDecodeInPlace(buf);
}

pub fn queryParamBool(target: []const u8, key: []const u8) bool {
    const raw = queryParamRaw(target, key) orelse return false;
    return std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1");
}

pub fn stripQuery(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
}

pub fn decodePathParam(raw: []const u8, alloc: Allocator) ![]u8 {
    const buf = try alloc.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

const testing = std.testing;

test "readReaderLimited enforces max bytes" {
    var stream = std.io.fixedBufferStream("abcdef");
    try testing.expectError(error.StreamTooLong, readReaderLimited(stream.reader(), testing.allocator, 3));
}

test "ingest body limits are explicit and stable" {
    try testing.expectEqual(@as(usize, 10 * 1024 * 1024), test_results_body_limit_bytes);
    try testing.expectEqual(@as(usize, 25 * 1024 * 1024), bom_body_limit_bytes);
    try testing.expectEqualStrings("{\"error\":\"payload_too_large\"}", payload_too_large_json);
}

test "stripQuery removes query string and preserves bare path" {
    try testing.expectEqualStrings("/api/provision-preview", stripQuery("/api/provision-preview?profile=medical"));
    try testing.expectEqualStrings("/query/chain-gaps", stripQuery("/query/chain-gaps"));
}

test "queryParam extracts expected values" {
    try testing.expectEqualStrings("medical", queryParamRaw("/api/provision-preview?profile=medical", "profile").?);
    try testing.expect(queryParamRaw("/api/provision-preview?profile=medical", "sheet_url") == null);
    try testing.expect(queryParamRaw("/api/provision-preview?profile=medical", "missing") == null);
}

test "queryParamDecoded decodes percent-encoded values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = (try queryParamDecoded("/query/file-annotations?file_path=src%2Ffoo%20bar.c", "file_path", alloc)).?;
    try testing.expectEqualStrings("src/foo bar.c", decoded);
}

test "queryParamDecoded converts plus to space for form-style query strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = (try queryParamDecoded("/api/v1/soup/components?bom_name=SOUP+Components", "bom_name", alloc)).?;
    try testing.expectEqualStrings("SOUP Components", decoded);
}

test "queryParamDecoded leaves simple values unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = (try queryParamDecoded("/api/provision-preview?profile=medical", "profile", alloc)).?;
    try testing.expectEqualStrings("medical", decoded);
}

test "queryParamBool accepts true and one only" {
    try testing.expect(queryParamBool("/api/v1/bom/design?include_obsolete=true", "include_obsolete"));
    try testing.expect(queryParamBool("/api/v1/bom/design?include_obsolete=1", "include_obsolete"));
    try testing.expect(!queryParamBool("/api/v1/bom/design?include_obsolete=false", "include_obsolete"));
    try testing.expect(!queryParamBool("/api/v1/bom/design", "include_obsolete"));
}

test "decodePathParam decodes percent-encoded route IDs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = try decodePathParam("FOO%2FBAR%2FBAZ%3FBLOW%3DUP", alloc);
    try testing.expectEqualStrings("FOO/BAR/BAZ?BLOW=UP", decoded);
}

test "decodePathParam leaves simple IDs unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const decoded = try decodePathParam("REQ-014", alloc);
    try testing.expectEqualStrings("REQ-014", decoded);
}
