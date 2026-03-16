const std = @import("std");
const structured_id = @import("../id.zig");
const xlsx = @import("../xlsx.zig");
const diagnostic = @import("../diagnostic.zig");
const internal = @import("internal.zig");

const Allocator = internal.Allocator;
const Diagnostics = internal.Diagnostics;
const Row = internal.Row;

pub fn isBlankEquivalent(s: []const u8) bool {
    if (s.len == 0) return true;
    const blanks = [_][]const u8{ "n/a", "na", "tbd", "tbc", "none", "-", "\xe2\x80\x94" };
    for (blanks) |b| {
        if (std.ascii.eqlIgnoreCase(s, b)) return true;
    }
    return false;
}

pub fn isSectionDivider(row: Row, id_col: ?usize) bool {
    if (id_col) |c| {
        if (c < row.len and row[c].len > 0) return false;
    }
    var non_empty: usize = 0;
    var content: []const u8 = "";
    for (row) |c| {
        if (c.len > 0) {
            non_empty += 1;
            content = c;
        }
    }
    if (non_empty == 0) return true;
    if (non_empty > 1) return false;
    if (content.len < 15) return true;
    if (std.mem.indexOf(u8, content, "---") != null or
        std.mem.indexOf(u8, content, "===") != null) return true;
    if (std.ascii.indexOfIgnoreCase(content, "section") != null) return true;
    var all_caps = true;
    for (content) |c| {
        if (std.ascii.isAlphabetic(c) and !std.ascii.isUpper(c)) {
            all_caps = false;
            break;
        }
    }
    return all_caps;
}

pub fn normalizeId(raw: []const u8, alloc: Allocator, diag: *Diagnostics, tab: []const u8, row_num: u32) ![]const u8 {
    const normalized = try structured_id.normalizeStructuredId(raw, alloc);
    if (normalized.len == 0) {
        const normed = try xlsx.normalizeCell(raw, alloc);
        try diag.warn(diagnostic.E.id_invalid, .row_parsing, tab, row_num,
            "ID '{s}' is not a valid structured ID (use hyphen-separated alphanumeric/underscore segments) — skipping", .{ normed });
        return "";
    }
    return normalized;
}

pub fn normalizeProductField(raw: []const u8, alloc: Allocator) ![]const u8 {
    const normalized = try xlsx.normalizeCell(raw, alloc);
    return std.mem.trim(u8, normalized, " ");
}

pub fn parseNumericField(raw: []const u8, diag: *Diagnostics, tab: []const u8, row_num: u32, field: []const u8) !?[]const u8 {
    if (isBlankEquivalent(raw)) return null;

    const Mapping = struct { text: []const u8, num: []const u8 };
    const mappings = [_]Mapping{
        .{ .text = "critical", .num = "5" }, .{ .text = "catastrophic", .num = "5" },
        .{ .text = "very high", .num = "5" },
        .{ .text = "high", .num = "4" }, .{ .text = "h", .num = "4" },
        .{ .text = "medium", .num = "3" }, .{ .text = "m", .num = "3" },
        .{ .text = "moderate", .num = "3" },
        .{ .text = "low", .num = "2" }, .{ .text = "l", .num = "2" },
        .{ .text = "negligible", .num = "1" }, .{ .text = "minimal", .num = "1" },
        .{ .text = "very low", .num = "1" }, .{ .text = "n", .num = "1" },
        .{ .text = "v", .num = "5" }, .{ .text = "iv", .num = "4" },
        .{ .text = "iii", .num = "3" }, .{ .text = "ii", .num = "2" },
        .{ .text = "i", .num = "1" },
    };
    for (mappings) |mp| {
        if (std.ascii.eqlIgnoreCase(raw, mp.text)) return mp.num;
    }

    const trimmed = std.mem.trim(u8, raw, " ");
    if (std.mem.endsWith(u8, trimmed, ".0")) return trimmed[0 .. trimmed.len - 2];
    if (std.fmt.parseInt(i64, trimmed, 10)) |_| return trimmed else |_| {}

    if (std.fmt.parseFloat(f64, trimmed)) |_| {
        try diag.warn(diagnostic.E.numeric_fractional, .row_parsing, tab, row_num,
            "{s}: fractional value '{s}' cannot be used as severity/likelihood; ignoring", .{ field, raw });
        return null;
    } else |_| {}

    try diag.warn(diagnostic.E.numeric_unrecognized, .row_parsing, tab, row_num,
        "{s}: cannot parse '{s}' as numeric severity/likelihood; ignoring", .{ field, raw });
    return null;
}

pub fn splitIds(raw: []const u8, alloc: Allocator) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, ",;/\n\r\t");
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " ");
        if (trimmed.len > 0) try result.append(alloc, trimmed);
    }
    return result.toOwnedSlice(alloc);
}
