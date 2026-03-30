const std = @import("std");
const Allocator = std.mem.Allocator;

const profile_mod = @import("rtmify").profile;
const connection_mod = @import("../../connection.zig");
const online_provider = @import("../../online_provider.zig");
const secure_store_mod = @import("../../secure_store.zig");
const workbook = @import("../../workbook/mod.zig");
const provision_routes = @import("../provision.zig");
const shared = @import("../shared.zig");

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

const testing = std.testing;

test "handleConnectionValidateResponse rejects unsupported secure store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try @import("../../secure_store_unsupported.zig").init(alloc);
    defer store.deinit(alloc);

    const body =
        "{\"platform\":\"google\",\"profile\":\"medical\",\"workbook_url\":\"https://docs.google.com/spreadsheets/d/abc/edit\",\"credentials\":{\"service_account_json\":\"{\\\"type\\\":\\\"service_account\\\",\\\"client_email\\\":\\\"svc@example.com\\\",\\\"private_key\\\":\\\"pem\\\"}\"}}";
    const resp = try handleConnectionValidateResponse(&store, body, alloc);
    try testing.expectEqual(std.http.Status.bad_request, resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"secure_storage_unavailable\"") != null);
}
