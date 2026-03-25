const std = @import("std");
const shared = @import("../routes/shared.zig");
const xlsx = @import("rtmify").xlsx;
const types = @import("types.zig");

pub const Allocator = std.mem.Allocator;

pub fn freeStringSlice(items: []const []const u8, alloc: Allocator) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

pub fn dupStringSlice(items: []const []const u8, alloc: Allocator) ![]const []const u8 {
    var duped = try alloc.alloc([]const u8, items.len);
    var count: usize = 0;
    errdefer {
        for (duped[0..count]) |item| alloc.free(item);
        alloc.free(duped);
    }
    for (items, 0..) |item, idx| {
        duped[idx] = try alloc.dupe(u8, item);
        count = idx + 1;
    }
    return duped;
}

pub fn dupWarnings(warnings: []const types.BomWarning, alloc: Allocator) ![]types.BomWarning {
    const duped = try alloc.alloc(types.BomWarning, warnings.len);
    errdefer alloc.free(duped);
    for (warnings, 0..) |warning, idx| {
        duped[idx] = .{
            .code = try alloc.dupe(u8, warning.code),
            .message = try alloc.dupe(u8, warning.message),
            .subject = if (warning.subject) |value| try alloc.dupe(u8, value) else null,
        };
    }
    return duped;
}

pub fn appendJsonStringArray(buf: *std.ArrayList(u8), items: ?[]const []const u8, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    if (items) |values| {
        for (values, 0..) |value, idx| {
            if (idx > 0) try buf.append(alloc, ',');
            try shared.appendJsonStr(buf, value, alloc);
        }
    }
    try buf.append(alloc, ']');
}

pub fn groupedRowsToCsv(header: []const []const u8, rows: []const []const []const u8, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try appendCsvRow(&buf, header, true, alloc);
    for (rows) |row| {
        try buf.append(alloc, '\n');
        try appendCsvRow(&buf, row, false, alloc);
    }
    return alloc.dupe(u8, buf.items);
}

pub fn appendCsvRow(buf: *std.ArrayList(u8), row: []const []const u8, normalize_header: bool, alloc: Allocator) !void {
    for (row, 0..) |cell, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        const value = if (normalize_header and std.ascii.eqlIgnoreCase(cell, "full_product_identifier"))
            "full_identifier"
        else
            cell;
        try appendCsvCell(buf, value, alloc);
    }
}

pub fn appendCsvCell(buf: *std.ArrayList(u8), value: []const u8, alloc: Allocator) !void {
    const needs_quotes = std.mem.indexOfAny(u8, value, ",\"\n\r") != null;
    if (!needs_quotes) {
        try buf.appendSlice(alloc, value);
        return;
    }
    try buf.append(alloc, '"');
    for (value) |c| {
        if (c == '"') try buf.append(alloc, '"');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '"');
}

pub fn parseCsvLine(line: []const u8, alloc: Allocator) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| alloc.free(field);
        fields.deinit(alloc);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(alloc);
    var i: usize = 0;
    var in_quotes = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') {
            if (in_quotes and i + 1 < line.len and line[i + 1] == '"') {
                try current.append(alloc, '"');
                i += 1;
            } else {
                in_quotes = !in_quotes;
            }
            continue;
        }
        if (c == ',' and !in_quotes) {
            try fields.append(alloc, try alloc.dupe(u8, std.mem.trim(u8, current.items, " ")));
            current.clearRetainingCapacity();
            continue;
        }
        try current.append(alloc, c);
    }
    if (in_quotes) return error.InvalidCsv;
    try fields.append(alloc, try alloc.dupe(u8, std.mem.trim(u8, current.items, " ")));
    return fields.toOwnedSlice(alloc);
}

pub fn resolveCol(header: []const []const u8, name: []const u8) ?usize {
    for (header, 0..) |field, idx| {
        if (std.ascii.eqlIgnoreCase(field, name)) return idx;
    }
    return null;
}

pub fn cellAt(row: []const []const u8, idx: usize, alloc: Allocator) ![]u8 {
    if (idx >= row.len) return alloc.dupe(u8, "");
    return alloc.dupe(u8, std.mem.trim(u8, row[idx], " "));
}

pub fn defaultCellAt(row: []const []const u8, idx: ?usize, default_value: []const u8, alloc: Allocator) ![]u8 {
    if (idx == null or idx.? >= row.len) return alloc.dupe(u8, default_value);
    const value = std.mem.trim(u8, row[idx.?], " ");
    if (value.len == 0) return alloc.dupe(u8, default_value);
    return alloc.dupe(u8, value);
}

pub fn optionalCellAt(row: []const []const u8, idx: ?usize, alloc: Allocator) !?[]const u8 {
    if (idx == null or idx.? >= row.len) return null;
    const value = std.mem.trim(u8, row[idx.?], " ");
    if (value.len == 0) return null;
    const dup = try alloc.dupe(u8, value);
    return dup;
}

pub fn defaultJsonString(value: ?[]const u8, default_value: []const u8) []const u8 {
    if (value) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r\n\t");
        if (trimmed.len > 0) return trimmed;
    }
    return default_value;
}

pub fn looksLikeJson(body: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, body, " \r\n\t");
    return trimmed.len > 0 and trimmed[0] == '{';
}

pub fn looksLikeCsv(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "bom_name") != null and std.mem.indexOfScalar(u8, body, ',') != null;
}

pub fn appendWarning(warnings: *std.ArrayList(types.BomWarning), code: []const u8, message: []const u8, subject: ?[]const u8, alloc: Allocator) !void {
    try warnings.append(alloc, .{
        .code = try alloc.dupe(u8, code),
        .message = try alloc.dupe(u8, message),
        .subject = if (subject) |value| try alloc.dupe(u8, value) else null,
    });
}

pub fn writeTempXlsx(body: []const u8, alloc: Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/rtmify-design-bom-{d}.xlsx", .{std.time.nanoTimestamp()});
    errdefer alloc.free(path);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
    return path;
}

pub fn findSheetRows(sheets: []const xlsx.SheetData, name: []const u8) ?[]const []const []const u8 {
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(sheet.name, name)) return sheet.rows;
    }
    return null;
}

pub fn hashesJson(value: std.json.Value, field_name: []const u8, alloc: Allocator) !?[]const u8 {
    const hashes = @import("../json_util.zig").getObjectField(value, field_name) orelse return null;
    if (hashes != .array) return null;
    const dup = try std.json.Stringify.valueAlloc(alloc, hashes, .{});
    return dup;
}
