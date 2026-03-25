const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const profile_mod = @import("rtmify").profile;
const connection_mod = @import("../connection.zig");
const secure_store_mod = @import("../secure_store.zig");
const online_provider = @import("../online_provider.zig");
const json_util = @import("../json_util.zig");
const workbook = @import("../workbook/mod.zig");
const xlsx = @import("rtmify").xlsx;
const provision_routes = @import("provision.zig");
const shared = @import("shared.zig");

pub fn handleConnectionValidate(store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handleConnectionValidateResponse(store, body, alloc);
    return resp.body;
}

pub fn handleConnectionValidateResponse(store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    if (!secure_store_mod.backendSupported(store.*)) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
    }
    var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
        std.log.warn("connection validate parse failed: {s}", .{@errorName(e)});
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
    };
    defer draft.deinit(alloc);

    var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
        std.log.warn("connection validate failed platform={s}: {s}", .{ online_provider.providerIdString(draft.platform), @errorName(e) });
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to validate connection: {s}\"}}", .{@errorName(e)}), false);
    };
    defer validated.deinit(alloc);
    std.log.info("connection validate ok platform={s} workbook={s}", .{ online_provider.providerIdString(validated.platform), validated.workbook_label });

    const profile_name = draft.profile orelse "generic";
    const pid = profile_mod.fromString(profile_name) orelse .generic;
    const prof = profile_mod.get(pid);
    const preview = try provision_routes.getProvisionPreviewForActive(validated.toActive(), prof, alloc);
    defer alloc.free(preview);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"platform\":");
    try shared.appendJsonStr(&buf, online_provider.providerIdString(validated.platform), alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, validated.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStr(&buf, validated.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"preview\":");
    try buf.appendSlice(alloc, preview);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleConnection(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handleConnectionResponse(registry, store, body, alloc);
    return resp.body;
}

pub fn handleConnectionResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    if (!secure_store_mod.backendSupported(store.*)) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
    }
    var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
        std.log.warn("connection parse failed: {s}", .{@errorName(e)});
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
    };
    defer draft.deinit(alloc);

    var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
        std.log.warn("connection failed platform={s}: {s}", .{ online_provider.providerIdString(draft.platform), @errorName(e) });
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to connect: {s}\"}}", .{@errorName(e)}), false);
    };
    defer validated.deinit(alloc);

    connection_mod.persistActiveWorkbook(registry, store, validated, alloc) catch |e| switch (e) {
        error.SecureStorageUnsupported => {
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
        },
        else => {
            std.log.err("connection persist failed: {s}", .{@errorName(e)});
            return shared.jsonRouteResponse(.internal_server_error, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"failed to persist secure credentials\"}"), false);
        },
    };
    std.log.info("connection persisted platform={s} workbook={s}", .{ online_provider.providerIdString(validated.platform), validated.workbook_label });
    try workbook.config.setActiveProfile(&registry.live_config, draft.profile orelse "generic", alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(alloc);
        runtime.config = try (try registry.activeConfig()).clone(alloc);
        runtime.db.deleteConfig("rtmify_provisioned") catch {};
    }
    try registry.save(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"platform\":");
    try shared.appendJsonStr(&buf, online_provider.providerIdString(validated.platform), alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, validated.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStr(&buf, validated.workbook_label, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleDesignBomSyncValidateResponse(store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    };
    defer parsed.deinit();
    const root = parsed.value;
    const kind = json_util.getString(root, "kind") orelse "";
    if (std.mem.eql(u8, kind, "local_xlsx")) {
        const path = json_util.getString(root, "local_xlsx_path") orelse
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_local_xlsx_path\"}"), false);
        validateLocalDesignBomWorkbook(path, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
        };
        const display_name = json_util.getString(root, "display_name") orelse "Design BOM Workbook";
        return shared.jsonRouteResponse(
            .ok,
            try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"kind\":\"local_xlsx\",\"display_name\":\"{s}\",\"local_xlsx_path\":\"{s}\"}}", .{ display_name, path }),
            true,
        );
    }
    if (!secure_store_mod.backendSupported(store.*)) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
    }
    var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
    };
    defer draft.deinit(alloc);
    var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to validate connection: {s}\"}}", .{@errorName(e)}), false);
    };
    defer validated.deinit(alloc);
    var active = validated.toActive();
    defer active.deinit(alloc);
    var runtime = try online_provider.ProviderRuntime.init(active, alloc);
    defer runtime.deinit(alloc);
    const tabs = try runtime.listTabs(alloc);
    defer online_provider.freeTabRefs(tabs, alloc);
    if (!providerTabExists(tabs, "Design BOM")) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_design_bom_tab\"}"), false);
    }
    const display_name = json_util.getString(root, "display_name") orelse validated.workbook_label;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"kind\":");
    try shared.appendJsonStr(&buf, online_provider.providerIdString(validated.platform), alloc);
    try buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(&buf, display_name, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, validated.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStr(&buf, validated.workbook_label, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleDesignBomSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    };
    defer parsed.deinit();
    const root = parsed.value;
    const kind = json_util.getString(root, "kind") orelse "";

    const active_cfg = try registry.activeConfig();
    const old_credential_ref = if (active_cfg.design_bom_sync) |cfg| if (cfg.credential_ref) |value| try alloc.dupe(u8, value) else null else null;
    defer if (old_credential_ref) |value| alloc.free(value);

    var sync_cfg: workbook.config.DesignBomSyncConfig = undefined;
    if (std.mem.eql(u8, kind, "local_xlsx")) {
        const path = json_util.getString(root, "local_xlsx_path") orelse
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_local_xlsx_path\"}"), false);
        validateLocalDesignBomWorkbook(path, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
        };
        sync_cfg = .{
            .kind = .local_xlsx,
            .enabled = true,
            .display_name = try alloc.dupe(u8, json_util.getString(root, "display_name") orelse "Design BOM Workbook"),
            .local_xlsx_path = try alloc.dupe(u8, path),
        };
    } else {
        if (!secure_store_mod.backendSupported(store.*)) {
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
        }
        var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
        };
        defer draft.deinit(alloc);
        var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to connect: {s}\"}}", .{@errorName(e)}), false);
        };
        defer validated.deinit(alloc);
        const credential_ref = try secure_store_mod.generateCredentialRef(alloc);
        defer alloc.free(credential_ref);
        try store.put(alloc, credential_ref, validated.credential_json);
        errdefer store.delete(alloc, credential_ref) catch {};

        sync_cfg = .{
            .kind = if (validated.platform == .google) .google else .excel,
            .enabled = true,
            .display_name = try alloc.dupe(u8, json_util.getString(root, "display_name") orelse validated.workbook_label),
            .workbook_url = try alloc.dupe(u8, validated.workbook_url),
            .workbook_label = try alloc.dupe(u8, validated.workbook_label),
            .credential_ref = try alloc.dupe(u8, credential_ref),
            .credential_display = if (validated.credential_display) |value| try alloc.dupe(u8, value) else null,
            .google_sheet_id = switch (validated.target) {
                .google => |google| try alloc.dupe(u8, google.sheet_id),
                else => null,
            },
            .excel_drive_id = switch (validated.target) {
                .excel => |excel| try alloc.dupe(u8, excel.drive_id),
                else => null,
            },
            .excel_item_id = switch (validated.target) {
                .excel => |excel| try alloc.dupe(u8, excel.item_id),
                else => null,
            },
        };
    }
    defer sync_cfg.deinit(alloc);

    try workbook.config.replaceActiveDesignBomSync(&registry.live_config, sync_cfg, alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(alloc);
        runtime.config = try (try registry.activeConfig()).clone(alloc);
    }
    try registry.save(alloc);
    if (old_credential_ref) |value| {
        if (sync_cfg.credential_ref == null or !std.mem.eql(u8, value, sync_cfg.credential_ref.?)) {
            store.delete(alloc, value) catch {};
        }
    }
    return handleGetDesignBomSyncResponse(registry, alloc);
}

pub fn handleGetDesignBomSyncResponse(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !shared.JsonRouteResponse {
    const cfg = try registry.activeConfig();
    const sync_cfg = cfg.design_bom_sync orelse {
        return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"configured\":false}"), true);
    };
    const runtime = registry.active() catch null;
    const db = if (runtime) |value| &value.db else null;
    const last_sync_at = if (db) |db_ref| try db_ref.getConfig("design_bom_last_sync_at", alloc) else null;
    defer if (last_sync_at) |value| alloc.free(value);
    const last_sync_ok = if (db) |db_ref| try db_ref.getConfig("design_bom_last_sync_ok", alloc) else null;
    defer if (last_sync_ok) |value| alloc.free(value);
    const last_sync_error = if (db) |db_ref| try db_ref.getConfig("design_bom_last_sync_error", alloc) else null;
    defer if (last_sync_error) |value| alloc.free(value);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"configured\":true,\"kind\":");
    try shared.appendJsonStr(&buf, @tagName(sync_cfg.kind), alloc);
    try buf.appendSlice(alloc, ",\"enabled\":");
    try buf.appendSlice(alloc, if (sync_cfg.enabled) "true" else "false");
    try buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(&buf, sync_cfg.display_name, alloc);
    try buf.appendSlice(alloc, ",\"workbook_url\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.workbook_url, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"local_xlsx_path\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.local_xlsx_path, alloc);
    try buf.appendSlice(alloc, ",\"last_sync_at\":");
    try shared.appendJsonStrOpt(&buf, last_sync_at, alloc);
    try buf.appendSlice(alloc, ",\"last_sync_ok\":");
    try shared.appendJsonStrOpt(&buf, last_sync_ok, alloc);
    try buf.appendSlice(alloc, ",\"last_error\":");
    try shared.appendJsonStrOpt(&buf, last_sync_error, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleDeleteDesignBomSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, alloc: Allocator) !shared.JsonRouteResponse {
    const cfg = try registry.activeConfig();
    const old_ref = if (cfg.design_bom_sync) |sync_cfg| if (sync_cfg.credential_ref) |value| try alloc.dupe(u8, value) else null else null;
    defer if (old_ref) |value| alloc.free(value);
    try workbook.config.clearActiveDesignBomSync(&registry.live_config, alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(alloc);
        runtime.config = try (try registry.activeConfig()).clone(alloc);
    }
    try registry.save(alloc);
    if (old_ref) |value| store.delete(alloc, value) catch {};
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true,\"configured\":false}"), true);
}

pub fn handleSoupSyncValidateResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    };
    defer parsed.deinit();
    const root = parsed.value;
    const full_product_identifier = json_util.getString(root, "full_product_identifier") orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_full_product_identifier\"}"), false);
    if (!(try activeProductExists(registry, full_product_identifier, alloc))) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"SOUP_PRODUCT_NOT_FOUND\"}"), false);
    }

    const kind = json_util.getString(root, "kind") orelse "";
    if (std.mem.eql(u8, kind, "local_xlsx")) {
        const path = json_util.getString(root, "local_xlsx_path") orelse
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_local_xlsx_path\"}"), false);
        validateLocalSoupWorkbook(path, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
        };
        const display_name = json_util.getString(root, "display_name") orelse "SOUP Workbook";
        const bom_name = json_util.getString(root, "bom_name") orelse "SOUP Components";
        return shared.jsonRouteResponse(
            .ok,
            try std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"kind\":\"local_xlsx\",\"display_name\":\"{s}\",\"local_xlsx_path\":\"{s}\",\"full_product_identifier\":\"{s}\",\"bom_name\":\"{s}\"}}",
                .{ display_name, path, full_product_identifier, bom_name },
            ),
            true,
        );
    }
    if (!secure_store_mod.backendSupported(store.*)) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
    }
    var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
    };
    defer draft.deinit(alloc);
    var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
        return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to validate connection: {s}\"}}", .{@errorName(e)}), false);
    };
    defer validated.deinit(alloc);
    var active = validated.toActive();
    defer active.deinit(alloc);
    var runtime = try online_provider.ProviderRuntime.init(active, alloc);
    defer runtime.deinit(alloc);
    const tabs = try runtime.listTabs(alloc);
    defer online_provider.freeTabRefs(tabs, alloc);
    if (!providerTabExists(tabs, "SOUP Components")) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_soup_tab\"}"), false);
    }
    const display_name = json_util.getString(root, "display_name") orelse validated.workbook_label;
    const bom_name = json_util.getString(root, "bom_name") orelse "SOUP Components";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"kind\":");
    try shared.appendJsonStr(&buf, online_provider.providerIdString(validated.platform), alloc);
    try buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(&buf, display_name, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, validated.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStr(&buf, validated.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStr(&buf, bom_name, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleSoupSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    };
    defer parsed.deinit();
    const root = parsed.value;
    const full_product_identifier = json_util.getString(root, "full_product_identifier") orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_full_product_identifier\"}"), false);
    if (!(try activeProductExists(registry, full_product_identifier, alloc))) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"SOUP_PRODUCT_NOT_FOUND\"}"), false);
    }
    const bom_name = json_util.getString(root, "bom_name") orelse "SOUP Components";
    const kind = json_util.getString(root, "kind") orelse "";

    const active_cfg = try registry.activeConfig();
    const old_credential_ref = if (active_cfg.soup_sync) |cfg| if (cfg.credential_ref) |value| try alloc.dupe(u8, value) else null else null;
    defer if (old_credential_ref) |value| alloc.free(value);

    var sync_cfg: workbook.config.SoupSyncConfig = undefined;
    if (std.mem.eql(u8, kind, "local_xlsx")) {
        const path = json_util.getString(root, "local_xlsx_path") orelse
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_local_xlsx_path\"}"), false);
        validateLocalSoupWorkbook(path, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
        };
        sync_cfg = .{
            .kind = .local_xlsx,
            .enabled = true,
            .display_name = try alloc.dupe(u8, json_util.getString(root, "display_name") orelse "SOUP Workbook"),
            .bom_name = try alloc.dupe(u8, bom_name),
            .full_product_identifier = try alloc.dupe(u8, full_product_identifier),
            .local_xlsx_path = try alloc.dupe(u8, path),
        };
    } else {
        if (!secure_store_mod.backendSupported(store.*)) {
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false);
        }
        var draft = connection_mod.parseDraftFromJson(body, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(e)}), false);
        };
        defer draft.deinit(alloc);
        var validated = connection_mod.validateDraft(draft, alloc) catch |e| {
            return shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"failed to connect: {s}\"}}", .{@errorName(e)}), false);
        };
        defer validated.deinit(alloc);
        const credential_ref = try secure_store_mod.generateCredentialRef(alloc);
        defer alloc.free(credential_ref);
        try store.put(alloc, credential_ref, validated.credential_json);
        errdefer store.delete(alloc, credential_ref) catch {};

        sync_cfg = .{
            .kind = if (validated.platform == .google) .google else .excel,
            .enabled = true,
            .display_name = try alloc.dupe(u8, json_util.getString(root, "display_name") orelse validated.workbook_label),
            .bom_name = try alloc.dupe(u8, bom_name),
            .full_product_identifier = try alloc.dupe(u8, full_product_identifier),
            .workbook_url = try alloc.dupe(u8, validated.workbook_url),
            .workbook_label = try alloc.dupe(u8, validated.workbook_label),
            .credential_ref = try alloc.dupe(u8, credential_ref),
            .credential_display = if (validated.credential_display) |value| try alloc.dupe(u8, value) else null,
            .google_sheet_id = switch (validated.target) {
                .google => |google| try alloc.dupe(u8, google.sheet_id),
                else => null,
            },
            .excel_drive_id = switch (validated.target) {
                .excel => |excel| try alloc.dupe(u8, excel.drive_id),
                else => null,
            },
            .excel_item_id = switch (validated.target) {
                .excel => |excel| try alloc.dupe(u8, excel.item_id),
                else => null,
            },
        };
    }
    defer sync_cfg.deinit(alloc);

    try workbook.config.replaceActiveSoupSync(&registry.live_config, sync_cfg, alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(alloc);
        runtime.config = try (try registry.activeConfig()).clone(alloc);
    }
    try registry.save(alloc);
    if (old_credential_ref) |value| {
        if (sync_cfg.credential_ref == null or !std.mem.eql(u8, value, sync_cfg.credential_ref.?)) {
            store.delete(alloc, value) catch {};
        }
    }
    return handleGetSoupSyncResponse(registry, alloc);
}

pub fn handleGetSoupSyncResponse(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !shared.JsonRouteResponse {
    const cfg = try registry.activeConfig();
    const sync_cfg = cfg.soup_sync orelse {
        return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"configured\":false}"), true);
    };
    const runtime = registry.active() catch null;
    const db = if (runtime) |value| &value.db else null;
    const last_sync_at = if (db) |db_ref| try db_ref.getConfig("soup_last_sync_at", alloc) else null;
    defer if (last_sync_at) |value| alloc.free(value);
    const last_sync_ok = if (db) |db_ref| try db_ref.getConfig("soup_last_sync_ok", alloc) else null;
    defer if (last_sync_ok) |value| alloc.free(value);
    const last_sync_error = if (db) |db_ref| try db_ref.getConfig("soup_last_sync_error", alloc) else null;
    defer if (last_sync_error) |value| alloc.free(value);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"configured\":true,\"kind\":");
    try shared.appendJsonStr(&buf, @tagName(sync_cfg.kind), alloc);
    try buf.appendSlice(alloc, ",\"enabled\":");
    try buf.appendSlice(alloc, if (sync_cfg.enabled) "true" else "false");
    try buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(&buf, sync_cfg.display_name, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, sync_cfg.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"workbook_url\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.workbook_url, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"local_xlsx_path\":");
    try shared.appendJsonStrOpt(&buf, sync_cfg.local_xlsx_path, alloc);
    try buf.appendSlice(alloc, ",\"last_sync_at\":");
    try shared.appendJsonStrOpt(&buf, last_sync_at, alloc);
    try buf.appendSlice(alloc, ",\"last_sync_ok\":");
    try shared.appendJsonStrOpt(&buf, last_sync_ok, alloc);
    try buf.appendSlice(alloc, ",\"last_error\":");
    try shared.appendJsonStrOpt(&buf, last_sync_error, alloc);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn handleDeleteSoupSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, alloc: Allocator) !shared.JsonRouteResponse {
    const cfg = try registry.activeConfig();
    const old_ref = if (cfg.soup_sync) |sync_cfg| if (sync_cfg.credential_ref) |value| try alloc.dupe(u8, value) else null else null;
    defer if (old_ref) |value| alloc.free(value);
    try workbook.config.clearActiveSoupSync(&registry.live_config, alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(alloc);
        runtime.config = try (try registry.activeConfig()).clone(alloc);
    }
    try registry.save(alloc);
    if (old_ref) |value| store.delete(alloc, value) catch {};
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true,\"configured\":false}"), true);
}

fn validateLocalDesignBomWorkbook(path: []const u8, alloc: Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sheets = try xlsx.parse(arena_state.allocator(), path);
    if (!sheetExists(sheets, "Design BOM")) return error.MissingDesignBomTab;
}

fn validateLocalSoupWorkbook(path: []const u8, alloc: Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sheets = try xlsx.parse(arena_state.allocator(), path);
    if (!sheetExists(sheets, "SOUP Components")) return error.MissingSoupTab;
}

fn activeProductExists(registry: *workbook.registry.WorkbookRegistry, full_product_identifier: []const u8, alloc: Allocator) !bool {
    const runtime = try registry.active();
    const product_id = try std.fmt.allocPrint(alloc, "product://{s}", .{full_product_identifier});
    defer alloc.free(product_id);
    const node = try runtime.db.getNode(product_id, alloc);
    if (node) |value| {
        shared.freeNode(value, alloc);
        return true;
    }
    return false;
}

fn providerTabExists(tabs: []const online_provider.TabRef, want: []const u8) bool {
    for (tabs) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, want)) return true;
    }
    return false;
}

fn sheetExists(sheets: []const xlsx.SheetData, want: []const u8) bool {
    for (sheets) |sheet| {
        if (std.ascii.eqlIgnoreCase(sheet.name, want)) return true;
    }
    return false;
}

pub fn handleGetProfile(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) ![]const u8 {
    const prof_name = (try registry.activeConfig()).profile;
    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);
    return std.fmt.allocPrint(alloc, "{{\"profile\":\"{s}\",\"name\":\"{s}\"}}", .{ prof_name, prof.name });
}

pub fn handlePostProfile(registry: *workbook.registry.WorkbookRegistry, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handlePostProfileResponse(registry, body, alloc, alloc);
    return resp.body;
}

pub fn handlePostProfileResponse(
    registry: *workbook.registry.WorkbookRegistry,
    body: []const u8,
    alloc: Allocator,
    persistent_alloc: Allocator,
) !shared.JsonRouteResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}"), false);
    defer parsed.deinit();

    const name = json_util.getString(parsed.value, "profile") orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing profile field\"}"), false);
    if (profile_mod.fromString(name) == null) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"unknown profile\"}"), false);
    }
    try workbook.config.setActiveProfile(&registry.live_config, name, persistent_alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(persistent_alloc);
        runtime.config = try (try registry.activeConfig()).clone(persistent_alloc);
        runtime.db.deleteConfig("rtmify_provisioned") catch {};
    }
    try registry.save(persistent_alloc);
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

pub fn handleGetRepos(registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    const cfg = try registry.activeConfig();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"repos\":[");
    var first = true;
    for (cfg.repo_paths, 0..) |path, idx| {
        const ts_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{path});
        defer alloc.free(ts_key);
        const last_scan = (try db.getConfig(ts_key, alloc)) orelse try alloc.dupe(u8, "0");
        defer alloc.free(last_scan);
        const source_file_count = try shared.countNodesForRepo(db, "SourceFile", path);
        const test_file_count = try shared.countNodesForRepo(db, "TestFile", path);
        const annotation_count = try shared.countAnnotationsForRepo(db, path);
        const commit_count = try shared.countCommitsForRepo(db, path);
        if (!first) try buf.append(alloc, ',');
        first = false;
        try std.fmt.format(buf.writer(alloc), "{{\"slot\":{d},\"path\":", .{idx});
        try shared.appendJsonStr(&buf, path, alloc);
        try buf.appendSlice(alloc, ",\"last_scan\":");
        try shared.appendJsonStr(&buf, last_scan, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"source_file_count\":{d},\"test_file_count\":{d},\"file_count\":{d},\"annotation_count\":{d},\"commit_count\":{d}",
            .{ source_file_count, test_file_count, source_file_count + test_file_count, annotation_count, commit_count });
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn handlePostRepo(registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, body: []const u8, alloc: Allocator, persist_alloc: Allocator) ![]const u8 {
    const resp = try handlePostRepoResponse(registry, db, body, alloc, persist_alloc);
    return resp.body;
}

pub fn handlePostRepoResponse(
    registry: *workbook.registry.WorkbookRegistry,
    db: *graph_live.GraphDb,
    body: []const u8,
    alloc: Allocator,
    persist_alloc: Allocator,
) !shared.JsonRouteResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}"), false);
    defer parsed.deinit();

    const path = json_util.getString(parsed.value, "path") orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing path field\"}"), false);
    std.fs.accessAbsolute(path, .{}) catch {
        const msg = try std.fmt.allocPrint(alloc, "Repo path does not exist: {s}", .{path});
        defer alloc.free(msg);
        const diag = [_]shared.InlineDiagnostic{
            shared.makeInlineDiagnostic(901, "err", "Repo path does not exist", msg, "repo_validation", path, "{}"),
        };
        return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("repo path does not exist", &diag, alloc), false);
    };
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.NotDir => {
            const msg = try std.fmt.allocPrint(alloc, "Repo path is not a directory: {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(902, "err", "Repo path is not a directory", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("path is not a directory", &diag, alloc), false);
        },
        error.AccessDenied => {
            const msg = try std.fmt.allocPrint(alloc, "Repo path is not readable: {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(904, "err", "Repo path not readable", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("path is not readable", &diag, alloc), false);
        },
        else => {
            const msg = try std.fmt.allocPrint(alloc, "Repo path is not a directory or is not accessible: {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(902, "err", "Repo path is not a directory", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("path is not a directory or is not accessible", &diag, alloc), false);
        },
    };
    dir.close();
    {
        var cur: []const u8 = path;
        var found_git = false;
        while (true) {
            const git_check = std.fmt.allocPrint(alloc, "{s}/.git", .{cur}) catch break;
            defer alloc.free(git_check);
            if (std.fs.accessAbsolute(git_check, .{})) {
                found_git = true;
                break;
            } else |_| {}
            const parent = std.fs.path.dirname(cur) orelse break;
            if (std.mem.eql(u8, parent, cur)) break;
            cur = parent;
        }
        if (!found_git) {
            const msg = try std.fmt.allocPrint(alloc, "No .git directory found at {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(903, "err", "No .git directory found", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("no .git directory found — is this a git repository?", &diag, alloc), false);
        }
    }
    _ = db;
    const cfg = try registry.activeConfig();
    if (cfg.repo_paths.len >= 64) {
        return shared.jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"too many repos\"}"), false);
    }
    try workbook.config.addActiveRepoPath(&registry.live_config, path, persist_alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(persist_alloc);
        runtime.config = try (try registry.activeConfig()).clone(persist_alloc);
    }
    try registry.syncActiveWorkbookIdFromRuntime(persist_alloc);
    try registry.save(persist_alloc);
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

pub fn handleDeleteRepo(registry: *workbook.registry.WorkbookRegistry, idx_str: []const u8, alloc: Allocator, persist_alloc: Allocator) ![]const u8 {
    const resp = try handleDeleteRepoResponse(registry, idx_str, alloc, persist_alloc);
    return resp.body;
}

pub fn handleDeleteRepoResponse(
    registry: *workbook.registry.WorkbookRegistry,
    idx_str: []const u8,
    alloc: Allocator,
    persist_alloc: Allocator,
) !shared.JsonRouteResponse {
    const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
        return shared.jsonRouteResponse(.not_found, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"repo not found\",\"slot\":{s}}}", .{idx_str}), false);
    };
    const removed = try workbook.config.deleteActiveRepoAt(&registry.live_config, idx, persist_alloc);
    if (!removed) {
        return shared.jsonRouteResponse(.not_found, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"repo not found\",\"slot\":{s}}}", .{idx_str}), false);
    }
    {
        const runtime = try registry.active();
        runtime.config.deinit(persist_alloc);
        runtime.config = try (try registry.activeConfig()).clone(persist_alloc);
    }
    try registry.syncActiveWorkbookIdFromRuntime(persist_alloc);
    try registry.save(persist_alloc);
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

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
    const display_name = try parseRequiredStringField(body, "display_name", alloc);
    defer alloc.free(display_name);
    const repo_paths = try parseOptionalStringArrayField(body, "repo_paths", alloc);
    defer freeStringSlice(repo_paths, alloc);

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
    const display_name = try parseRequiredStringField(body, "display_name", alloc);
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
    const confirm_name = try parseRequiredStringField(body, "confirm_display_name", alloc);
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

fn parseRequiredStringField(body: []const u8, key: []const u8, alloc: Allocator) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const value = json_util.getString(parsed.value, key) orelse return error.InvalidJson;
    return alloc.dupe(u8, value);
}

fn parseOptionalStringArrayField(body: []const u8, key: []const u8, alloc: Allocator) ![]const []const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const field = json_util.getObjectField(parsed.value, key) orelse return alloc.alloc([]const u8, 0);
    if (field != .array) return error.InvalidJson;
    const out = try alloc.alloc([]const u8, field.array.items.len);
    errdefer alloc.free(out);
    for (field.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidJson;
        out[idx] = try alloc.dupe(u8, item.string);
    }
    return out;
}

fn freeStringSlice(values: []const []const u8, alloc: Allocator) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

const testing = std.testing;

test "handlePostProfile accepts legal JSON with whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handlePostProfile(&db, "{ \"profile\" : \"aerospace\" }", alloc);
    try testing.expectEqualStrings("{\"ok\":true}", resp);
}

test "handleConnectionValidateResponse rejects unsupported secure store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try @import("../secure_store_unsupported.zig").init(alloc);
    defer store.deinit(alloc);

    const body =
        "{\"platform\":\"google\",\"profile\":\"medical\",\"workbook_url\":\"https://docs.google.com/spreadsheets/d/abc/edit\",\"credentials\":{\"service_account_json\":\"{\\\"type\\\":\\\"service_account\\\",\\\"client_email\\\":\\\"svc@example.com\\\",\\\"private_key\\\":\\\"pem\\\"}\"}}";
    const resp = try handleConnectionValidateResponse(&store, body, alloc);
    try testing.expectEqual(std.http.Status.bad_request, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"secure_storage_unavailable\"") != null);
}

test "handlePostRepo returns E902 for file path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const tmp_path = try std.fs.path.join(alloc, &.{ root, "rtmify-routes-file.txt" });
    defer alloc.free(tmp_path);
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("x");
    }
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{tmp_path});
    const resp = try handlePostRepo(&db, body, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":902") != null);
}

test "handlePostRepo accepts legal JSON with whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    const body = try std.fmt.allocPrint(alloc, "{{ \"path\" : \"{s}\" }}", .{tmp_path});
    const resp = try handlePostRepo(&db, body, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"missing path field\"") == null);
}

test "handlePostRepo accepts escaped path characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handlePostRepo(&db, "{ \"path\" : \"/tmp/repo \\\"alpha\\\"\" }", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":901") != null);
}

test "handlePostRepo returns E903 for directory without git" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("rtmify-routes-nogit");
    const root = try tmp.dir.realpathAlloc(alloc, "rtmify-routes-nogit");
    defer alloc.free(root);
    const tmp_dir = root;
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{tmp_dir});
    const resp = try handlePostRepo(&db, body, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":903") != null);
}

test "handleGetRepos includes stable slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.storeConfig("repo_path_3", "/tmp/repo");

    const resp = try handleGetRepos(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const repos = parsed.value.object.get("repos").?.array.items;
    try testing.expectEqual(@as(usize, 1), repos.len);
    try testing.expectEqual(@as(i64, 3), repos[0].object.get("slot").?.integer);
}
