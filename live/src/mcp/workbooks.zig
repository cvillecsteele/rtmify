const std = @import("std");
const internal = @import("internal.zig");

pub fn workbookContextJson(registry: *internal.workbook.registry.WorkbookRegistry, alloc: internal.Allocator) ![]u8 {
    if (registry.live_config.active_workbook_id) |active_id| {
        var summary = try registry.summaryForWorkbookId(active_id, alloc);
        defer summary.deinit(alloc);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, "{\"id\":");
        try internal.json_util.appendJsonQuoted(&buf, summary.id, alloc);
        try buf.appendSlice(alloc, ",\"display_name\":");
        try internal.json_util.appendJsonQuoted(&buf, summary.display_name, alloc);
        try buf.appendSlice(alloc, ",\"profile\":");
        try internal.json_util.appendJsonQuoted(&buf, summary.profile, alloc);
        try buf.appendSlice(alloc, ",\"provider\":");
        if (summary.provider) |provider| {
            try internal.json_util.appendJsonQuoted(&buf, provider, alloc);
        } else {
            try buf.appendSlice(alloc, "null");
        }
        try buf.append(alloc, '}');
        return alloc.dupe(u8, buf.items);
    }
    return alloc.dupe(u8, "null");
}

pub fn workbookHeading(registry: *internal.workbook.registry.WorkbookRegistry, alloc: internal.Allocator) ![]u8 {
    if (registry.live_config.active_workbook_id) |active_id| {
        const cfg = internal.workbook.config.findByIdConst(&registry.live_config, active_id) orelse return alloc.dupe(u8, "[Workbook: none]\n\n");
        return std.fmt.allocPrint(alloc, "[Workbook: {s}]\n\n", .{cfg.display_name});
    }
    return alloc.dupe(u8, "[Workbook: none]\n\n");
}

pub fn listWorkbooksJson(registry: *internal.workbook.registry.WorkbookRegistry, alloc: internal.Allocator) ![]u8 {
    const visible = try registry.listVisible(alloc);
    defer internal.workbook.registry.deinitSummarySlice(visible, alloc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"active_workbook_id\":");
    try internal.shared.appendJsonStrOpt(&buf, registry.live_config.active_workbook_id, alloc);
    try buf.appendSlice(alloc, ",\"workbooks\":[");
    for (visible, 0..) |summary, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try appendWorkbookSummaryJson(&buf, summary, alloc);
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn activeWorkbookJson(registry: *internal.workbook.registry.WorkbookRegistry, alloc: internal.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"workbook\":");
    if (registry.live_config.active_workbook_id) |active_id| {
        var summary = try registry.summaryForWorkbookId(active_id, alloc);
        defer summary.deinit(alloc);
        try appendWorkbookSummaryJson(&buf, summary, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn appendWorkbookSummaryJson(buf: *std.ArrayList(u8), summary: internal.workbook.registry.WorkbookSummary, alloc: internal.Allocator) !void {
    try buf.appendSlice(alloc, "{\"id\":");
    try internal.shared.appendJsonStr(buf, summary.id, alloc);
    try buf.appendSlice(alloc, ",\"slug\":");
    try internal.shared.appendJsonStr(buf, summary.slug, alloc);
    try buf.appendSlice(alloc, ",\"display_name\":");
    try internal.shared.appendJsonStr(buf, summary.display_name, alloc);
    try buf.appendSlice(alloc, ",\"profile\":");
    try internal.shared.appendJsonStr(buf, summary.profile, alloc);
    try buf.appendSlice(alloc, ",\"provider\":");
    try internal.shared.appendJsonStrOpt(buf, summary.provider, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try internal.shared.appendJsonStrOpt(buf, summary.workbook_label, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"is_active\":{s},\"removed_at\":", .{
        if (summary.is_active) "true" else "false",
    });
    try internal.shared.appendJsonIntOpt(buf, summary.removed_at, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"last_sync_at\":{d},\"sync_in_progress\":{s},\"has_error\":{s},\"last_error\":", .{
        summary.last_sync_at,
        if (summary.sync_in_progress) "true" else "false",
        if (summary.has_error) "true" else "false",
    });
    try internal.shared.appendJsonStrOpt(buf, summary.last_error, alloc);
    try buf.appendSlice(alloc, ",\"inbox_dir\":");
    try internal.shared.appendJsonStr(buf, summary.inbox_dir, alloc);
    try buf.appendSlice(alloc, ",\"db_path\":");
    try internal.shared.appendJsonStr(buf, summary.db_path, alloc);
    try buf.append(alloc, '}');
}
