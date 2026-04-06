const std = @import("std");
const Allocator = std.mem.Allocator;

const artifact_test_files = @import("../../artifact_test_files.zig");
const connection_mod = @import("../../connection.zig");
const json_util = @import("../../json_util.zig");
const online_provider = @import("../../online_provider.zig");
const provider_common = @import("../../provider_common.zig");
const secure_store_mod = @import("../../secure_store.zig");
const workbook = @import("../../workbook/mod.zig");
const xlsx = @import("rtmify").xlsx;
const shared = @import("../shared.zig");

const SyncDomain = enum { design_bom, soup };

const SyncDomainPolicy = struct {
    domain: SyncDomain,
    provider_tab_name: []const u8,
    local_sheet_name: []const u8,
    missing_tab_error_json: []const u8,
    missing_local_path_error_json: []const u8,
    default_display_name: []const u8,
    needs_product_identifier: bool,
    default_bom_name: ?[]const u8,
};

const SyncValidationRequest = struct {
    kind: []const u8,
    display_name: ?[]const u8,
    local_xlsx_path: ?[]const u8,
    full_product_identifier: ?[]const u8,
    bom_name: ?[]const u8,
};

const ProviderBackedValidation = struct {
    request: SyncValidationRequest,
    validated: provider_common.ValidatedDraft,
};

const SyncConfig = union(SyncDomain) {
    design_bom: workbook.config.DesignBomSyncConfig,
    soup: workbook.config.SoupSyncConfig,

    fn deinit(self: *SyncConfig, alloc: Allocator) void {
        switch (self.*) {
            .design_bom => |*cfg| cfg.deinit(alloc),
            .soup => |*cfg| cfg.deinit(alloc),
        }
    }

    fn credentialRef(self: SyncConfig) ?[]const u8 {
        return switch (self) {
            .design_bom => |cfg| cfg.credential_ref,
            .soup => |cfg| cfg.credential_ref,
        };
    }
};

const SyncStatusFields = struct {
    last_sync_at: ?[]const u8,
    last_sync_ok: ?[]const u8,
    last_sync_error: ?[]const u8,

    fn deinit(self: *SyncStatusFields, alloc: Allocator) void {
        if (self.last_sync_at) |value| alloc.free(value);
        if (self.last_sync_ok) |value| alloc.free(value);
        if (self.last_sync_error) |value| alloc.free(value);
    }
};

const design_bom_policy = SyncDomainPolicy{
    .domain = .design_bom,
    .provider_tab_name = "Design BOM",
    .local_sheet_name = "Design BOM",
    .missing_tab_error_json = "{\"ok\":false,\"error\":\"missing_design_bom_tab\"}",
    .missing_local_path_error_json = "{\"ok\":false,\"error\":\"missing_local_xlsx_path\"}",
    .default_display_name = "Design BOM Workbook",
    .needs_product_identifier = false,
    .default_bom_name = null,
};

const soup_policy = SyncDomainPolicy{
    .domain = .soup,
    .provider_tab_name = "SOUP Components",
    .local_sheet_name = "SOUP Components",
    .missing_tab_error_json = "{\"ok\":false,\"error\":\"missing_soup_tab\"}",
    .missing_local_path_error_json = "{\"ok\":false,\"error\":\"missing_local_xlsx_path\"}",
    .default_display_name = "SOUP Workbook",
    .needs_product_identifier = true,
    .default_bom_name = "SOUP Components",
};

pub fn handleDesignBomSyncValidateResponse(store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    return handleSyncValidateResponse(design_bom_policy, null, store, body, alloc);
}

pub fn handleDesignBomSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    return handleSyncSetResponse(design_bom_policy, registry, store, body, alloc);
}

pub fn handleGetDesignBomSyncResponse(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !shared.JsonRouteResponse {
    return handleGetSyncResponse(design_bom_policy, registry, alloc);
}

pub fn handleDeleteDesignBomSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, alloc: Allocator) !shared.JsonRouteResponse {
    return handleDeleteSyncResponse(design_bom_policy, registry, store, alloc);
}

pub fn handleSoupSyncValidateResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    return handleSyncValidateResponse(soup_policy, registry, store, body, alloc);
}

pub fn handleSoupSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, body: []const u8, alloc: Allocator) !shared.JsonRouteResponse {
    return handleSyncSetResponse(soup_policy, registry, store, body, alloc);
}

pub fn handleGetSoupSyncResponse(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !shared.JsonRouteResponse {
    return handleGetSyncResponse(soup_policy, registry, alloc);
}

pub fn handleDeleteSoupSyncResponse(registry: *workbook.registry.WorkbookRegistry, store: *secure_store_mod.Store, alloc: Allocator) !shared.JsonRouteResponse {
    return handleDeleteSyncResponse(soup_policy, registry, store, alloc);
}

fn handleSyncValidateResponse(
    policy: SyncDomainPolicy,
    registry: ?*workbook.registry.WorkbookRegistry,
    store: *secure_store_mod.Store,
    body: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    };
    defer parsed.deinit();

    const request = parseSyncValidationRequest(parsed.value, policy) catch |err| {
        return requestErrorResponse(policy, err, alloc);
    };
    validateDomainRequest(policy, registry, request, alloc) catch |err| {
        return requestErrorResponse(policy, err, alloc);
    };

    if (std.mem.eql(u8, request.kind, "local_xlsx")) {
        const path = request.local_xlsx_path orelse unreachable;
        validateLocalWorkbook(policy, path, alloc) catch |err| {
            return validationErrorResponse(policy, err, alloc);
        };
        return buildLocalSyncValidationResponse(policy, request, alloc);
    }

    var provider_backed = validateProviderBackedSync(policy, request, store, body, alloc) catch |err| {
        return validationErrorResponse(policy, err, alloc);
    };
    defer provider_backed.validated.deinit(alloc);
    return buildProviderSyncValidationResponse(policy, provider_backed, alloc);
}

fn handleSyncSetResponse(
    policy: SyncDomainPolicy,
    registry: *workbook.registry.WorkbookRegistry,
    store: *secure_store_mod.Store,
    body: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    };
    defer parsed.deinit();

    const request = parseSyncValidationRequest(parsed.value, policy) catch |err| {
        return requestErrorResponse(policy, err, alloc);
    };
    validateDomainRequest(policy, registry, request, alloc) catch |err| {
        return requestErrorResponse(policy, err, alloc);
    };

    const old_credential_ref = try extractOldCredentialRef(policy, registry, alloc);
    defer if (old_credential_ref) |value| alloc.free(value);

    var sync_cfg = buildSyncConfig(policy, request, store, body, alloc) catch |err| {
        return validationErrorResponse(policy, err, alloc);
    };
    defer sync_cfg.deinit(alloc);

    try replaceActiveSyncAndRefreshRuntime(registry, sync_cfg, alloc);
    try cleanupReplacedCredentialRef(store, old_credential_ref, sync_cfg.credentialRef(), alloc);

    return switch (policy.domain) {
        .design_bom => handleGetDesignBomSyncResponse(registry, alloc),
        .soup => handleGetSoupSyncResponse(registry, alloc),
    };
}

fn handleGetSyncResponse(policy: SyncDomainPolicy, registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !shared.JsonRouteResponse {
    const cfg = try registry.activeConfig();
    switch (policy.domain) {
        .design_bom => {
            const sync_cfg = cfg.design_bom_sync orelse return buildConfiguredFalseResponse(alloc);
            var status_fields = try loadSyncStatusFields(registry, "design_bom", alloc);
            defer status_fields.deinit(alloc);

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
            try shared.appendJsonStrOpt(&buf, status_fields.last_sync_at, alloc);
            try buf.appendSlice(alloc, ",\"last_sync_ok\":");
            try shared.appendJsonStrOpt(&buf, status_fields.last_sync_ok, alloc);
            try buf.appendSlice(alloc, ",\"last_error\":");
            try shared.appendJsonStrOpt(&buf, status_fields.last_sync_error, alloc);
            try buf.append(alloc, '}');
            return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
        },
        .soup => {
            const sync_cfg = cfg.soup_sync orelse return buildConfiguredFalseResponse(alloc);
            var status_fields = try loadSyncStatusFields(registry, "soup", alloc);
            defer status_fields.deinit(alloc);

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
            try shared.appendJsonStrOpt(&buf, status_fields.last_sync_at, alloc);
            try buf.appendSlice(alloc, ",\"last_sync_ok\":");
            try shared.appendJsonStrOpt(&buf, status_fields.last_sync_ok, alloc);
            try buf.appendSlice(alloc, ",\"last_error\":");
            try shared.appendJsonStrOpt(&buf, status_fields.last_sync_error, alloc);
            try buf.append(alloc, '}');
            return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
        },
    }
}

fn handleDeleteSyncResponse(
    policy: SyncDomainPolicy,
    registry: *workbook.registry.WorkbookRegistry,
    store: *secure_store_mod.Store,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    const old_ref = try extractOldCredentialRef(policy, registry, alloc);
    defer if (old_ref) |value| alloc.free(value);

    try clearActiveSyncAndRefreshRuntime(policy, registry, alloc);
    if (old_ref) |value| store.delete(alloc, value) catch {};
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true,\"configured\":false}"), true);
}

fn parseSyncValidationRequest(root: std.json.Value, policy: SyncDomainPolicy) !SyncValidationRequest {
    if (root != .object) return error.InvalidJson;
    const request = SyncValidationRequest{
        .kind = json_util.getString(root, "kind") orelse "",
        .display_name = json_util.getString(root, "display_name"),
        .local_xlsx_path = json_util.getString(root, "local_xlsx_path"),
        .full_product_identifier = json_util.getString(root, "full_product_identifier"),
        .bom_name = json_util.getString(root, "bom_name"),
    };
    if (policy.needs_product_identifier and request.full_product_identifier == null) return error.MissingFullProductIdentifier;
    if (std.mem.eql(u8, request.kind, "local_xlsx") and request.local_xlsx_path == null) return error.MissingLocalXlsxPath;
    return request;
}

fn validateDomainRequest(
    policy: SyncDomainPolicy,
    registry: ?*workbook.registry.WorkbookRegistry,
    request: SyncValidationRequest,
    alloc: Allocator,
) !void {
    switch (policy.domain) {
        .design_bom => {},
        .soup => {
            const sync_registry = registry orelse return error.SoupProductNotFound;
            if (!(try activeProductExists(sync_registry, request.full_product_identifier.?, alloc))) {
                return error.SoupProductNotFound;
            }
        },
    }
}

fn validateProviderBackedSync(
    policy: SyncDomainPolicy,
    request: SyncValidationRequest,
    store: *secure_store_mod.Store,
    body: []const u8,
    alloc: Allocator,
) !ProviderBackedValidation {
    if (!secure_store_mod.backendSupported(store.*)) return error.SecureStorageUnsupported;

    var draft = try connection_mod.parseDraftFromJson(body, alloc);
    errdefer draft.deinit(alloc);
    var validated = try connection_mod.validateDraft(draft, alloc);
    draft.deinit(alloc);
    errdefer validated.deinit(alloc);

    var active = validated.toActive();
    defer active.deinit(alloc);
    var runtime = try online_provider.ProviderRuntime.init(active, alloc);
    defer runtime.deinit(alloc);
    const tabs = try runtime.listTabs(alloc);
    defer online_provider.freeTabRefs(tabs, alloc);
    if (!providerTabExists(tabs, policy.provider_tab_name)) {
        return switch (policy.domain) {
            .design_bom => error.MissingDesignBomTab,
            .soup => error.MissingSoupTab,
        };
    }

    return .{
        .request = request,
        .validated = validated,
    };
}

fn buildLocalSyncValidationResponse(policy: SyncDomainPolicy, request: SyncValidationRequest, alloc: Allocator) !shared.JsonRouteResponse {
    return switch (policy.domain) {
        .design_bom => shared.jsonRouteResponse(
            .ok,
            try std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"kind\":\"local_xlsx\",\"display_name\":\"{s}\",\"local_xlsx_path\":\"{s}\"}}",
                .{ request.display_name orelse policy.default_display_name, request.local_xlsx_path.? },
            ),
            true,
        ),
        .soup => shared.jsonRouteResponse(
            .ok,
            try std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"kind\":\"local_xlsx\",\"display_name\":\"{s}\",\"local_xlsx_path\":\"{s}\",\"full_product_identifier\":\"{s}\",\"bom_name\":\"{s}\"}}",
                .{
                    request.display_name orelse policy.default_display_name,
                    request.local_xlsx_path.?,
                    request.full_product_identifier.?,
                    request.bom_name orelse policy.default_bom_name.?,
                },
            ),
            true,
        ),
    };
}

fn buildProviderSyncValidationResponse(policy: SyncDomainPolicy, provider_backed: ProviderBackedValidation, alloc: Allocator) !shared.JsonRouteResponse {
    const request = provider_backed.request;
    const validated = provider_backed.validated;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"kind\":");
    try shared.appendJsonStr(&buf, online_provider.providerIdString(validated.platform), alloc);
    try buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(&buf, request.display_name orelse validated.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, validated.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStr(&buf, validated.workbook_label, alloc);
    switch (policy.domain) {
        .design_bom => {},
        .soup => {
            try buf.appendSlice(alloc, ",\"full_product_identifier\":");
            try shared.appendJsonStr(&buf, request.full_product_identifier.?, alloc);
            try buf.appendSlice(alloc, ",\"bom_name\":");
            try shared.appendJsonStr(&buf, request.bom_name orelse policy.default_bom_name.?, alloc);
        },
    }
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

fn buildSyncConfig(
    policy: SyncDomainPolicy,
    request: SyncValidationRequest,
    store: *secure_store_mod.Store,
    body: []const u8,
    alloc: Allocator,
) !SyncConfig {
    if (std.mem.eql(u8, request.kind, "local_xlsx")) {
        try validateLocalWorkbook(policy, request.local_xlsx_path.?, alloc);
        return switch (policy.domain) {
            .design_bom => SyncConfig{ .design_bom = .{
                .kind = .local_xlsx,
                .enabled = true,
                .display_name = try alloc.dupe(u8, request.display_name orelse policy.default_display_name),
                .local_xlsx_path = try alloc.dupe(u8, request.local_xlsx_path.?),
            } },
            .soup => SyncConfig{ .soup = .{
                .kind = .local_xlsx,
                .enabled = true,
                .display_name = try alloc.dupe(u8, request.display_name orelse policy.default_display_name),
                .bom_name = try alloc.dupe(u8, request.bom_name orelse policy.default_bom_name.?),
                .full_product_identifier = try alloc.dupe(u8, request.full_product_identifier.?),
                .local_xlsx_path = try alloc.dupe(u8, request.local_xlsx_path.?),
            } },
        };
    }

    var provider_backed = try validateProviderBackedSync(policy, request, store, body, alloc);
    defer provider_backed.validated.deinit(alloc);
    const validated = provider_backed.validated;

    const credential_ref = try secure_store_mod.generateCredentialRef(alloc);
    defer alloc.free(credential_ref);
    try store.put(alloc, credential_ref, validated.credential_json);
    errdefer store.delete(alloc, credential_ref) catch {};

    return switch (policy.domain) {
        .design_bom => SyncConfig{ .design_bom = .{
            .kind = if (validated.platform == .google) .google else .excel,
            .enabled = true,
            .display_name = try alloc.dupe(u8, request.display_name orelse validated.workbook_label),
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
        } },
        .soup => SyncConfig{ .soup = .{
            .kind = if (validated.platform == .google) .google else .excel,
            .enabled = true,
            .display_name = try alloc.dupe(u8, request.display_name orelse validated.workbook_label),
            .bom_name = try alloc.dupe(u8, request.bom_name orelse policy.default_bom_name.?),
            .full_product_identifier = try alloc.dupe(u8, request.full_product_identifier.?),
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
        } },
    };
}

fn replaceActiveSyncAndRefreshRuntime(registry: *workbook.registry.WorkbookRegistry, sync_cfg: SyncConfig, alloc: Allocator) !void {
    switch (sync_cfg) {
        .design_bom => |cfg| try workbook.config.replaceActiveDesignBomSync(&registry.live_config, cfg, alloc),
        .soup => |cfg| try workbook.config.replaceActiveSoupSync(&registry.live_config, cfg, alloc),
    }
    try registry.syncRuntimeConfigFromActive(alloc);
    try registry.save(alloc);
}

fn clearActiveSyncAndRefreshRuntime(policy: SyncDomainPolicy, registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !void {
    switch (policy.domain) {
        .design_bom => try workbook.config.clearActiveDesignBomSync(&registry.live_config, alloc),
        .soup => try workbook.config.clearActiveSoupSync(&registry.live_config, alloc),
    }
    try registry.syncRuntimeConfigFromActive(alloc);
    try registry.save(alloc);
}

fn loadSyncStatusFields(registry: *workbook.registry.WorkbookRegistry, prefix: []const u8, alloc: Allocator) !SyncStatusFields {
    const runtime = registry.active() catch null;
    const db = if (runtime) |value| &value.db else null;
    const last_sync_at_key = try std.fmt.allocPrint(alloc, "{s}_last_sync_at", .{prefix});
    defer alloc.free(last_sync_at_key);
    const last_sync_ok_key = try std.fmt.allocPrint(alloc, "{s}_last_sync_ok", .{prefix});
    defer alloc.free(last_sync_ok_key);
    const last_sync_error_key = try std.fmt.allocPrint(alloc, "{s}_last_sync_error", .{prefix});
    defer alloc.free(last_sync_error_key);

    return .{
        .last_sync_at = if (db) |db_ref| try db_ref.getConfig(last_sync_at_key, alloc) else null,
        .last_sync_ok = if (db) |db_ref| try db_ref.getConfig(last_sync_ok_key, alloc) else null,
        .last_sync_error = if (db) |db_ref| try db_ref.getConfig(last_sync_error_key, alloc) else null,
    };
}

fn buildConfiguredFalseResponse(alloc: Allocator) !shared.JsonRouteResponse {
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"configured\":false}"), true);
}

fn validateLocalWorkbook(policy: SyncDomainPolicy, path: []const u8, alloc: Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sheets = try xlsx.parse(arena_state.allocator(), path);
    if (!sheetExists(sheets, policy.local_sheet_name)) {
        return switch (policy.domain) {
            .design_bom => error.MissingDesignBomTab,
            .soup => error.MissingSoupTab,
        };
    }
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

fn extractOldCredentialRef(policy: SyncDomainPolicy, registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) !?[]u8 {
    const cfg = try registry.activeConfig();
    return switch (policy.domain) {
        .design_bom => if (cfg.design_bom_sync) |sync_cfg|
            if (sync_cfg.credential_ref) |value| try alloc.dupe(u8, value) else null
        else
            null,
        .soup => if (cfg.soup_sync) |sync_cfg|
            if (sync_cfg.credential_ref) |value| try alloc.dupe(u8, value) else null
        else
            null,
    };
}

fn cleanupReplacedCredentialRef(
    store: *secure_store_mod.Store,
    old_credential_ref: ?[]const u8,
    new_credential_ref: ?[]const u8,
    alloc: Allocator,
) !void {
    if (old_credential_ref) |value| {
        if (new_credential_ref == null or !std.mem.eql(u8, value, new_credential_ref.?)) {
            store.delete(alloc, value) catch {};
        }
    }
}

fn requestErrorResponse(policy: SyncDomainPolicy, err: anyerror, alloc: Allocator) !shared.JsonRouteResponse {
    return switch (err) {
        error.InvalidJson => shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false),
        error.MissingLocalXlsxPath => shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, policy.missing_local_path_error_json), false),
        error.MissingFullProductIdentifier => shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing_full_product_identifier\"}"), false),
        error.SoupProductNotFound => shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"SOUP_PRODUCT_NOT_FOUND\"}"), false),
        else => shared.jsonRouteResponse(.bad_request, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(err)}), false),
    };
}

fn validationErrorResponse(policy: SyncDomainPolicy, err: anyerror, alloc: Allocator) !shared.JsonRouteResponse {
    return switch (err) {
        error.SecureStorageUnsupported => shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"secure_storage_unavailable\"}"), false),
        error.MissingDesignBomTab, error.MissingSoupTab => shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, policy.missing_tab_error_json), false),
        else => requestErrorResponse(policy, err, alloc),
    };
}

fn makeTestRegistry(alloc: Allocator, store: *secure_store_mod.Store) !workbook.registry.WorkbookRegistry {
    var cfg = try workbook.config.bootstrapConfig(alloc, .{});
    errdefer cfg.deinit(alloc);
    alloc.free(cfg.workbooks[0].db_path);
    cfg.workbooks[0].db_path = try alloc.dupe(u8, ":memory:");
    alloc.free(cfg.workbooks[0].inbox_dir);
    const inbox_dir = try std.fs.path.join(alloc, &.{ "tmp", "inbox" });
    defer alloc.free(inbox_dir);
    cfg.workbooks[0].inbox_dir = try alloc.dupe(u8, inbox_dir);
    return workbook.registry.WorkbookRegistry.initForConfig(alloc, cfg, store);
}

fn localXlsxRequestBody(path: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"kind\":\"local_xlsx\",\"local_xlsx_path\":");
    try shared.appendJsonStr(&buf, path, alloc);
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

fn soupLocalXlsxRequestBody(path: []const u8, full_product_identifier: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"kind\":\"local_xlsx\",\"local_xlsx_path\":");
    try shared.appendJsonStr(&buf, path, alloc);
    try buf.appendSlice(alloc, ",\"full_product_identifier\":");
    try shared.appendJsonStr(&buf, full_product_identifier, alloc);
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

const testing = std.testing;

test "design bom validate local_xlsx success" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "design-bom.xlsx" });
    defer alloc.free(path);

    const rows = [_][]const []const u8{};
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "Design BOM", .rows = &rows },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, alloc);

    const body = try localXlsxRequestBody(path, alloc);
    defer alloc.free(body);
    const resp = try handleDesignBomSyncValidateResponse(&store, body, alloc);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"kind\":\"local_xlsx\"") != null);
}

test "design bom validate local_xlsx missing tab" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "wrong-design-bom.xlsx" });
    defer alloc.free(path);

    const rows = [_][]const []const u8{};
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "Wrong Tab", .rows = &rows },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, alloc);

    const body = try localXlsxRequestBody(path, alloc);
    defer alloc.free(body);
    const resp = try handleDesignBomSyncValidateResponse(&store, body, alloc);
    try testing.expectEqual(std.http.Status.bad_request, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"missing_design_bom_tab\"") != null);
}

test "soup validate rejects missing full_product_identifier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);

    const resp = try handleSoupSyncValidateResponse(&registry, &store, "{\"kind\":\"local_xlsx\"}", alloc);
    try testing.expectEqual(std.http.Status.bad_request, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"missing_full_product_identifier\"") != null);
}

test "soup validate rejects product not found" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);

    const soup_path = try std.fs.path.join(alloc, &.{ "tmp", "unused.xlsx" });
    defer alloc.free(soup_path);
    const body = try soupLocalXlsxRequestBody(soup_path, "VS-200-REV-C", alloc);
    defer alloc.free(body);

    const resp = try handleSoupSyncValidateResponse(
        &registry,
        &store,
        body,
        alloc,
    );
    try testing.expectEqual(std.http.Status.bad_request, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"SOUP_PRODUCT_NOT_FOUND\"") != null);
}

test "provider-backed sync enforces expected provider tab by domain" {
    const tabs = [_]online_provider.TabRef{
        .{ .id = "1", .title = "Design BOM" },
        .{ .id = "2", .title = "Other" },
    };
    try testing.expect(providerTabExists(&tabs, design_bom_policy.provider_tab_name));
    try testing.expect(!providerTabExists(&tabs, soup_policy.provider_tab_name));
}

test "delete sync removes previous credential ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);

    try store.put(alloc, "cred_old", "{\"token\":\"old\"}");
    try workbook.config.replaceActiveDesignBomSync(&registry.live_config, .{
        .kind = .google,
        .enabled = true,
        .display_name = try alloc.dupe(u8, "Old BOM"),
        .credential_ref = try alloc.dupe(u8, "cred_old"),
    }, alloc);
    try registry.syncRuntimeConfigFromActive(alloc);

    const resp = try handleDeleteDesignBomSyncResponse(&registry, &store, alloc);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expectError(error.NotFound, store.get(alloc, "cred_old"));
}

test "replace sync deletes stale credential ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "replace-design-bom.xlsx" });
    defer alloc.free(path);

    const rows = [_][]const []const u8{};
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "Design BOM", .rows = &rows },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, alloc);

    try store.put(alloc, "cred_old", "{\"token\":\"old\"}");
    try workbook.config.replaceActiveDesignBomSync(&registry.live_config, .{
        .kind = .google,
        .enabled = true,
        .display_name = try alloc.dupe(u8, "Old BOM"),
        .credential_ref = try alloc.dupe(u8, "cred_old"),
    }, alloc);
    try registry.syncRuntimeConfigFromActive(alloc);

    const body = try std.fmt.allocPrint(alloc, "{{\"kind\":\"local_xlsx\",\"local_xlsx_path\":\"{s}\"}}", .{path});
    const resp = try handleDesignBomSyncResponse(&registry, &store, body, alloc);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expectError(error.NotFound, store.get(alloc, "cred_old"));

    const active_cfg = try registry.activeConfig();
    try testing.expect(active_cfg.design_bom_sync != null);
    try testing.expectEqualStrings(path, active_cfg.design_bom_sync.?.local_xlsx_path.?);
    try testing.expect(active_cfg.design_bom_sync.?.credential_ref == null);
}
