const std = @import("std");
const Allocator = std.mem.Allocator;

const connection_mod = @import("../../connection.zig");
const secure_store_mod = @import("../../secure_store.zig");
const workbook = @import("../../workbook/mod.zig");
const shared = @import("../shared.zig");
const common = @import("common.zig");

pub fn handleGetWorkbooks(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) ![]const u8 {
    const resp = try handleGetWorkbooksResponse(registry, alloc);
    return resp.body;
}

pub fn handleGetWorkbooksResponse(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !shared.JsonRouteResponse {
    const visible = try registry.listVisible(alloc);
    defer workbook.registry.deinitSummarySlice(visible, alloc);
    const removed = try registry.listRemoved(alloc);
    defer workbook.registry.deinitSummarySlice(removed, alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"active_workbook_id\":");
    try shared.appendJsonStrOpt(&buf, registry.live_config.active_workbook_id, alloc);
    try buf.appendSlice(alloc, ",\"workbooks\":[");
    for (visible, 0..) |summary, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try appendWorkbookSummaryJson(&buf, summary, alloc);
    }
    try buf.appendSlice(alloc, "],\"removed_workbooks\":[");
    for (removed, 0..) |summary, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try appendWorkbookSummaryJson(&buf, summary, alloc);
    }
    try buf.appendSlice(alloc, "]}");
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handlePostWorkbooks(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handlePostWorkbooksResponse(registry, store, body, alloc);
    return resp.body;
}

pub fn handlePostWorkbooksResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    const display_name = try common.parseRequiredStringField(body, "display_name", alloc);
    defer alloc.free(display_name);
    const repo_paths = try common.parseOptionalStringArrayField(body, "repo_paths", alloc);
    defer common.freeStringSlice(repo_paths, alloc);

    var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
    };
    defer draft.deinit(alloc);
    var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to connect: {s}\"}}", .{@errorName(e)}), false);
    };
    defer validated.deinit(alloc);

    var summary = registry.createWorkbook(store, validated, display_name, repo_paths, alloc) catch |e| switch (e) {
        error.SecureStorageUnsupported => {
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
        },
        error.DuplicateDisplayName => {
            return shared.jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"duplicate_display_name\"}"), false);
        },
        else => return e,
    };
    defer summary.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"workbook\":");
    try appendWorkbookSummaryJson(&buf, summary, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handlePatchWorkbookResponse(registry: *workbook.registry.WorkbookRegistry, workbook_id: []const u8, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    const display_name = try common.parseRequiredStringField(body, "display_name", alloc);
    defer alloc.free(display_name);
    registry.renameWorkbook(workbook_id, display_name, alloc) catch |e| switch (e) {
        error.DuplicateDisplayName => return shared.jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"duplicate_display_name\"}"), false),
        error.WorkbookNotFound => return shared.jsonRouteResponse(.not_found, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_not_found\"}"), false),
        else => return e,
    };
    var summary = try registry.summaryForWorkbookId(workbook_id, alloc);
    defer summary.deinit(alloc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"workbook\":");
    try appendWorkbookSummaryJson(&buf, summary, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleActivateWorkbookResponse(registry: *workbook.registry.WorkbookRegistry, workbook_id: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    var summary = registry.activateWorkbook(workbook_id, alloc) catch |e| switch (e) {
        error.WorkbookNotFound => return shared.jsonRouteResponse(.not_found, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_not_found\"}"), false),
        error.WorkbookRemoved => return shared.jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_removed\"}"), false),
        else => return e,
    };
    defer summary.deinit(alloc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"workbook\":");
    try appendWorkbookSummaryJson(&buf, summary, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleRemoveWorkbookResponse(registry: *workbook.registry.WorkbookRegistry, workbook_id: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    _ = registry.removeWorkbook(workbook_id, alloc) catch |e| switch (e) {
        error.WorkbookNotFound => return shared.jsonRouteResponse(.not_found, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_not_found\"}"), false),
        error.WorkbookRemoved => return shared.jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_removed\"}"), false),
        error.NoActiveWorkbook => return shared.jsonRouteResponse(.ok, try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"removed_id\":\"{s}\",\"active_workbook_id\":null}}", .{workbook_id}), true),
        else => return e,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"removed_id\":");
    try shared.appendJsonStr(&buf, workbook_id, alloc);
    try buf.appendSlice(alloc, ",\"active_workbook_id\":");
    try shared.appendJsonStrOpt(&buf, registry.live_config.active_workbook_id, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleDeleteWorkbookResponse(registry: *workbook.registry.WorkbookRegistry, workbook_id: []const u8, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    const confirm_name = try common.parseRequiredStringField(body, "confirm_display_name", alloc);
    defer alloc.free(confirm_name);
    const cfg = workbook.config.findById(&registry.live_config, workbook_id) orelse {
        return shared.jsonRouteResponse(.not_found, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_not_found\"}"), false);
    };
    if (!std.mem.eql(u8, cfg.display_name, confirm_name)) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"confirm_display_name_mismatch\"}"), false);
    }
    registry.purgeWorkbook(workbook_id, alloc) catch |e| switch (e) {
        error.WorkbookNotRemoved => return shared.jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_not_removed\"}"), false),
        error.WorkbookNotFound => return shared.jsonRouteResponse(.not_found, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"workbook_not_found\"}"), false),
        else => return e,
    };
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

fn appendWorkbookSummaryJson(buf: *std.ArrayList(u8), summary: workbook.registry.WorkbookSummary, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"id\":");
    try shared.appendJsonStr(buf, summary.id, alloc);
    try buf.appendSlice(alloc, ",\"slug\":");
    try shared.appendJsonStr(buf, summary.slug, alloc);
    try buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(buf, summary.display_name, alloc);
    try buf.appendSlice(alloc, ",\"profile\":");
    try shared.appendJsonStr(buf, summary.profile, alloc);
    try buf.appendSlice(alloc, ",\"provider\":");
    try shared.appendJsonStrOpt(buf, summary.provider, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStrOpt(buf, summary.workbook_label, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"is_active\":{s},\"last_sync_at\":{d},\"sync_in_progress\":{s},\"has_error\":{s},\"removed_at\":", .{
        if (summary.is_active) "true" else "false",
        summary.last_sync_at,
        if (summary.sync_in_progress) "true" else "false",
        if (summary.has_error) "true" else "false",
    });
    if (summary.removed_at) |removed_at| {
        try std.fmt.format(buf.writer(alloc), "{d}", .{removed_at});
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"last_error\":");
    try shared.appendJsonStrOpt(buf, summary.last_error, alloc);
    try buf.appendSlice(alloc, ",\"inbox_dir\":");
    try shared.appendJsonStr(buf, summary.inbox_dir, alloc);
    try buf.appendSlice(alloc, ",\"db_path\":");
    try shared.appendJsonStr(buf, summary.db_path, alloc);
    try buf.append(alloc, '}');
}
