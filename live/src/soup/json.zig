const std = @import("std");
const Allocator = std.mem.Allocator;

const shared = @import("../routes/shared.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn ingestResponseJson(response_value: types.SoupIngestResponse, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, response_value.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, response_value.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"source_format\":");
    try shared.appendJsonStr(&buf, util.bomFormatString(response_value.source_format), alloc);
    try std.fmt.format(
        buf.writer(alloc),
        ",\"rows_received\":{d},\"rows_ingested\":{d},\"inserted_nodes\":{d},\"inserted_edges\":{d},\"row_errors\":[",
        .{ response_value.rows_received, response_value.rows_ingested, response_value.inserted_nodes, response_value.inserted_edges },
    );
    for (response_value.row_errors, 0..) |row_error, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try std.fmt.format(buf.writer(alloc), "{{\"row\":{d},\"code\":", .{row_error.row});
        try shared.appendJsonStr(&buf, row_error.code, alloc);
        try buf.appendSlice(alloc, ",\"message\":");
        try shared.appendJsonStr(&buf, row_error.message, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "],\"warnings\":[");
    for (response_value.warnings, 0..) |warning, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"code\":");
        try shared.appendJsonStr(&buf, warning.code, alloc);
        try buf.appendSlice(alloc, ",\"message\":");
        try shared.appendJsonStr(&buf, warning.message, alloc);
        try buf.appendSlice(alloc, ",\"subject\":");
        try shared.appendJsonStrOpt(&buf, warning.subject, alloc);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn appendJsonStringArray(buf: *std.ArrayList(u8), items: []const []const u8, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try shared.appendJsonStr(buf, item, alloc);
    }
    try buf.append(alloc, ']');
}
