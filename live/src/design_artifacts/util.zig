const std = @import("std");

const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const json_util = @import("../json_util.zig");
const xlsx = @import("rtmify").xlsx;
const rtmify = @import("rtmify");

pub fn isLowConfidenceStatus(parse_status: []const u8) bool {
    return std.mem.eql(u8, parse_status, "low_confidence_long_text") or
        std.mem.eql(u8, parse_status, "low_confidence_nested_ids") or
        std.mem.eql(u8, parse_status, "low_confidence_empty_after_trim");
}

pub fn hashNormalizedText(normalized_text: ?[]const u8) [64]u8 {
    if (normalized_text == null or normalized_text.?.len == 0) return std.mem.zeroes([64]u8);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(normalized_text.?);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn countAssertionsWithStatus(
    assertions: []const graph_live.RequirementSourceAssertion,
    target_status: []const u8,
    treat_missing_text_as_null: bool,
) usize {
    var count: usize = 0;
    for (assertions) |assertion| {
        const parse_status = assertion.parse_status orelse "ok";
        if (std.mem.eql(u8, parse_status, target_status)) {
            count += 1;
        } else if (treat_missing_text_as_null and (assertion.text == null or assertion.text.?.len == 0)) {
            count += 1;
        }
    }
    return count;
}

pub fn countLowConfidenceAssertions(assertions: []const graph_live.RequirementSourceAssertion) usize {
    var count: usize = 0;
    for (assertions) |assertion| {
        const parse_status = assertion.parse_status orelse "ok";
        if (isLowConfidenceStatus(parse_status)) count += 1;
    }
    return count;
}

pub fn extractJsonStringArray(json: []const u8, key: []const u8, alloc: Allocator) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return try alloc.alloc([]const u8, 0);
    const field = root.object.get(key) orelse return try alloc.alloc([]const u8, 0);
    if (field != .array) return try alloc.alloc([]const u8, 0);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(alloc);
    for (field.array.items) |item| {
        if (item != .string) continue;
        try values.append(alloc, try alloc.dupe(u8, item.string));
    }
    return values.toOwnedSlice(alloc);
}

pub fn extractStringField(json: []const u8, key: []const u8) ?[]const u8 {
    return json_util.extractJsonFieldStatic(json, key);
}

pub fn normalizeText(text: []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var last_space = false;
    for (text) |c| {
        const lowered = std.ascii.toLower(c);
        if (std.ascii.isWhitespace(lowered)) {
            if (!last_space and buf.items.len > 0) {
                try buf.append(alloc, ' ');
                last_space = true;
            }
            continue;
        }
        last_space = false;
        try buf.append(alloc, lowered);
    }
    return alloc.dupe(u8, std.mem.trimRight(u8, buf.items, " "));
}

pub fn classifyExtractedText(text: ?[]const u8, normalized_text: ?[]const u8) []const u8 {
    const raw = text orelse return "null_text";
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return "low_confidence_empty_after_trim";
    if (raw.len > 300) return "low_confidence_long_text";

    var token_start: ?usize = null;
    var found_ids: usize = 0;
    var idx: usize = 0;
    while (idx <= raw.len) : (idx += 1) {
        const boundary = idx == raw.len or std.ascii.isWhitespace(raw[idx]) or std.mem.indexOfScalar(u8, ":;,()[]{}", raw[idx]) != null;
        if (token_start == null) {
            if (idx < raw.len and !std.ascii.isWhitespace(raw[idx])) token_start = idx;
            continue;
        }
        if (!boundary) continue;
        const token = std.mem.trim(u8, raw[token_start.?..idx], " \t\r\n:;,.()[]{}");
        token_start = null;
        if (token.len > 0 and rtmify.id.looksLikeStructuredIdForInference(token)) {
            found_ids += 1;
            if (found_ids > 0) return "low_confidence_nested_ids";
        }
    }

    if (normalized_text == null or normalized_text.?.len == 0) return "null_text";
    return "ok";
}

pub fn findSheetRows(sheets: []const xlsx.SheetData, want: []const u8) ?[]const []const []const u8 {
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, sheet.name, " \r\n\t"), want)) return sheet.rows;
    }
    return null;
}

pub fn findHeaderIndex(headers: []const []const u8, candidates: []const []const u8) ?usize {
    for (headers, 0..) |header, idx| {
        const trimmed = std.mem.trim(u8, header, " \r\n\t");
        for (candidates) |candidate| {
            if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return idx;
        }
    }
    return null;
}
