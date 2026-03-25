const std = @import("std");

const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const xlsx = rtmify.xlsx;
const types = @import("types.zig");
const util = @import("util.zig");

pub fn parseRtmWorkbookAssertions(path: []const u8, alloc: Allocator) !std.ArrayList(types.ParsedRequirementAssertion) {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sheets = try xlsx.parse(arena, path);
    try validateRtmWorkbookShape(sheets);
    const requirement_rows = util.findSheetRows(sheets, "Requirements") orelse return error.InvalidXlsx;
    if (requirement_rows.len == 0) return std.ArrayList(types.ParsedRequirementAssertion).empty;

    const headers = requirement_rows[0];
    const c_id = util.findHeaderIndex(headers, &.{ "ID", "Req ID", "Requirement ID" }) orelse return error.InvalidXlsx;
    const c_stmt = util.findHeaderIndex(headers, &.{ "Statement", "Requirement Statement", "Text" }) orelse return error.InvalidXlsx;

    var out: std.ArrayList(types.ParsedRequirementAssertion) = .empty;
    var seen: std.StringHashMap(void) = .init(alloc);
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        seen.deinit();
    }

    for (requirement_rows[1..]) |row| {
        if (c_id >= row.len) continue;
        const req_id = std.mem.trim(u8, row[c_id], " \t\r\n:");
        if (req_id.len == 0 or !rtmify.id.looksLikeStructuredIdForInference(req_id)) continue;
        if (seen.contains(req_id)) continue;
        try seen.put(try alloc.dupe(u8, req_id), {});
        const statement = if (c_stmt < row.len) std.mem.trim(u8, row[c_stmt], " \t\r\n") else "";
        const normalized = if (statement.len > 0) try util.normalizeText(statement, alloc) else null;
        defer if (normalized) |value| alloc.free(value);
        const parse_status = util.classifyExtractedText(if (statement.len > 0) statement else null, normalized);
        try out.append(alloc, .{
            .req_id = try alloc.dupe(u8, req_id),
            .section = try alloc.dupe(u8, "Requirements"),
            .text = if (statement.len > 0) try alloc.dupe(u8, statement) else null,
            .normalized_text = if (normalized) |value| try alloc.dupe(u8, value) else null,
            .parse_status = try alloc.dupe(u8, parse_status),
            .occurrence_count = 1,
        });
    }
    return out;
}

pub fn validateRtmWorkbookShape(sheets: []const xlsx.SheetData) !void {
    if (util.findSheetRows(sheets, "SOUP Components") != null or util.findSheetRows(sheets, "Design BOM") != null) return error.UnsupportedFormat;
    const required = [_][]const u8{ "Requirements", "User Needs", "Tests", "Risks" };
    for (required) |name| {
        if (util.findSheetRows(sheets, name) == null) return error.InvalidXlsx;
    }
}
