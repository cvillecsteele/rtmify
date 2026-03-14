const std = @import("std");
const Allocator = std.mem.Allocator;
const xlsx = @import("xlsx.zig");

pub fn isStructuredId(s: []const u8) bool {
    if (s.len < 3) return false;
    if (s[0] == '-' or s[s.len - 1] == '-') return false;

    var saw_hyphen = false;
    var segment_len: usize = 0;
    for (s) |c| {
        if (c == '-') {
            if (segment_len == 0) return false;
            saw_hyphen = true;
            segment_len = 0;
            continue;
        }
        if (!isSegmentChar(c)) return false;
        segment_len += 1;
    }
    return saw_hyphen and segment_len > 0;
}

pub fn normalizeStructuredId(raw: []const u8, alloc: Allocator) ![]const u8 {
    const normed = try xlsx.normalizeCell(raw, alloc);
    if (normed.len == 0) return normed;

    const trimmed = std.mem.trim(u8, normed, " \t\r\n");
    if (!isStructuredId(trimmed)) {
        alloc.free(normed);
        return "";
    }
    if (trimmed.ptr == normed.ptr and trimmed.len == normed.len) return normed;
    const out = try alloc.dupe(u8, trimmed);
    alloc.free(normed);
    return out;
}

pub fn looksLikeStructuredIdForInference(s: []const u8) bool {
    return isStructuredId(s);
}

fn isSegmentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "isStructuredId accepts valid structured IDs" {
    try std.testing.expect(isStructuredId("REQ-001"));
    try std.testing.expect(isStructuredId("REQ-OQ-001"));
    try std.testing.expect(isStructuredId("TST-IQ-003"));
    try std.testing.expect(isStructuredId("Foo-1AF5-Bar-Q5"));
    try std.testing.expect(isStructuredId("ABC_DEF-01_A"));
}

test "isStructuredId rejects invalid structured IDs" {
    try std.testing.expect(!isStructuredId("REQ001"));
    try std.testing.expect(!isStructuredId("hello"));
    try std.testing.expect(!isStructuredId("REQ--001"));
    try std.testing.expect(!isStructuredId("-REQ-001"));
    try std.testing.expect(!isStructuredId("REQ-001-"));
    try std.testing.expect(!isStructuredId("REQ/001"));
    try std.testing.expect(!isStructuredId("REQ 001"));
    try std.testing.expect(!isStructuredId("()"));
    try std.testing.expect(!isStructuredId("_"));
    try std.testing.expect(!isStructuredId("A"));
}

test "normalizeStructuredId preserves exact authored ID" {
    const alloc = std.testing.allocator;
    const normalized = try normalizeStructuredId("  Foo-1AF5-Bar-Q5  ", alloc);
    defer if (normalized.len > 0) alloc.free(normalized);

    try std.testing.expectEqualStrings("Foo-1AF5-Bar-Q5", normalized);
}

test "normalizeStructuredId rejects malformed IDs without repair" {
    const alloc = std.testing.allocator;

    const parenthetical = try normalizeStructuredId("REQ-001 (old)", alloc);
    try std.testing.expectEqual(@as(usize, 0), parenthetical.len);

    const stripped = try normalizeStructuredId("-REQ-001-", alloc);
    try std.testing.expectEqual(@as(usize, 0), stripped.len);
}
