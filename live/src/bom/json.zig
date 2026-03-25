const std = @import("std");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const Allocator = std.mem.Allocator;

pub fn ingestResponseJson(response: types.BomIngestResponse, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, response.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, response.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"bom_type\":");
    try shared.appendJsonStr(&buf, ids.bomTypeString(response.bom_type), alloc);
    try buf.appendSlice(alloc, ",\"source_format\":");
    try shared.appendJsonStr(&buf, ids.bomFormatString(response.source_format), alloc);
    try std.fmt.format(buf.writer(alloc), ",\"inserted_nodes\":{d},\"inserted_edges\":{d},\"warnings\":[", .{
        response.inserted_nodes,
        response.inserted_edges,
    });
    for (response.warnings, 0..) |warning, idx| {
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

pub fn groupedIngestResponseJson(response: types.GroupedBomIngestResponse, alloc: Allocator) ![]const u8 {
    var ok_count: usize = 0;
    for (response.groups) |group| {
        if (group.status == .ok) ok_count += 1;
    }
    const overall_status = if (response.groups.len == 0 or ok_count == 0)
        "error"
    else if (ok_count == response.groups.len)
        "ok"
    else
        "partial";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"status\":");
    try shared.appendJsonStr(&buf, overall_status, alloc);
    try buf.appendSlice(alloc, ",\"groups\":[");
    for (response.groups, 0..) |group, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"status\":");
        try shared.appendJsonStr(&buf, if (group.status == .ok) "ok" else "error", alloc);
        try buf.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&buf, group.full_product_identifier, alloc);
        try buf.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&buf, group.bom_name, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"rows_ingested\":{d},\"inserted_nodes\":{d},\"inserted_edges\":{d}", .{
            group.rows_ingested,
            group.inserted_nodes,
            group.inserted_edges,
        });
        try buf.appendSlice(alloc, ",\"error\":");
        if (group.error_code) |code| {
            try buf.appendSlice(alloc, "{\"code\":");
            try shared.appendJsonStr(&buf, code, alloc);
            try buf.appendSlice(alloc, ",\"detail\":");
            try shared.appendJsonStrOpt(&buf, group.error_detail, alloc);
            try buf.append(alloc, '}');
        } else {
            try buf.appendSlice(alloc, "null");
        }
        try buf.appendSlice(alloc, ",\"warnings\":[");
        for (group.warnings, 0..) |warning, widx| {
            if (widx > 0) try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"code\":");
            try shared.appendJsonStr(&buf, warning.code, alloc);
            try buf.appendSlice(alloc, ",\"message\":");
            try shared.appendJsonStr(&buf, warning.message, alloc);
            try buf.appendSlice(alloc, ",\"subject\":");
            try shared.appendJsonStrOpt(&buf, warning.subject, alloc);
            try buf.append(alloc, '}');
        }
        try buf.appendSlice(alloc, "]}");
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn appendNodeJsonArray(buf: *std.ArrayList(u8), nodes: []const graph_live.Node, alloc: Allocator) !void {
    try buf.append(alloc, '[');
    for (nodes, 0..) |node, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try shared.appendNodeObject(buf, node, alloc);
    }
    try buf.append(alloc, ']');
}
