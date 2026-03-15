const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const profile_mod = @import("../profile.zig");
const provision_mod = @import("../provision.zig");
const connection_mod = @import("../connection.zig");
const secure_store_mod = @import("../secure_store.zig");
const online_provider = @import("../online_provider.zig");
const workbook = @import("../workbook/mod.zig");
const shared = @import("shared.zig");

pub fn handleProvisionPreview(
    registry: *workbook.registry.WorkbookRegistry,
    secure_store: *secure_store_mod.Store,
    query_profile: ?[]const u8,
    alloc: Allocator,
) ![]const u8 {
    const prof_name = if (query_profile) |qp| qp
        else (try registry.activeConfig()).profile;
    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);
    var loaded = try connection_mod.loadWorkbookConnection((try registry.activeConfig()).*, secure_store, alloc);
    defer loaded.deinit(alloc);
    if (loaded != .active) {
        return alloc.dupe(u8, "{\"ready\":false,\"reason\":\"missing_credentials_or_sheet\"}");
    }

    const preview = getProvisionPreviewForActive(loaded.active, prof, alloc) catch {
        return alloc.dupe(u8, "{\"ready\":false,\"reason\":\"preview_failed\"}");
    };
    return preview;
}

pub fn handleProvision(registry: *workbook.registry.WorkbookRegistry, secure_store: *secure_store_mod.Store, alloc: Allocator) ![]const u8 {
    const resp = try handleProvisionResponse(registry, secure_store, alloc);
    return resp.body;
}

pub fn handleProvisionResponse(registry: *workbook.registry.WorkbookRegistry, secure_store: *secure_store_mod.Store, alloc: Allocator) !shared.JsonRouteResponse {
    const active_runtime = try registry.active();
    const prof_name = active_runtime.config.profile;
    var loaded = try connection_mod.loadWorkbookConnection(active_runtime.config, secure_store, alloc);
    defer loaded.deinit(alloc);

    if (loaded != .active) {
        const diag = [_]shared.InlineDiagnostic{
            shared.makeInlineDiagnostic(1207, "info", "Industry profile not configured", "Missing credential or sheet configuration for provisioning", "profile", null, "{}"),
        };
        return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("missing sheet or credential for provisioning", &diag, alloc), false);
    }

    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);
    var provider_runtime = try online_provider.ProviderRuntime.init(loaded.active, alloc);
    defer provider_runtime.deinit(alloc);
    const created = try provision_mod.provisionWorkbook(&provider_runtime, prof, alloc);
    defer {
        for (created) |tab| alloc.free(tab);
        alloc.free(created);
    }

    var already_present: std.ArrayList([]const u8) = .empty;
    defer {
        for (already_present.items) |tab| alloc.free(tab);
        already_present.deinit(alloc);
    }
    for (prof.tabs) |tab| {
        var found = false;
        for (created) |c| {
            if (std.mem.eql(u8, c, tab)) {
                found = true;
                break;
            }
        }
        if (!found) try already_present.append(alloc, try alloc.dupe(u8, tab));
    }

    try (try registry.active()).db.storeConfig("rtmify_provisioned", "1");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ok\":true,\"created\":");
    const created_json = try shared.jsonStringArray(created, alloc);
    defer alloc.free(created_json);
    try buf.appendSlice(alloc, created_json);
    try buf.appendSlice(alloc, ",\"already_present\":");
    const present_json = try shared.jsonStringArray(already_present.items, alloc);
    defer alloc.free(present_json);
    try buf.appendSlice(alloc, present_json);
    try buf.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, buf.items), true);
}

pub fn getProvisionPreviewForActive(active: online_provider.ActiveConnection, prof: profile_mod.Profile, alloc: Allocator) ![]const u8 {
    var runtime = try online_provider.ProviderRuntime.init(active, alloc);
    defer runtime.deinit(alloc);
    const tab_ids = try runtime.listTabs(alloc);
    defer online_provider.freeTabRefs(tab_ids, alloc);

    return buildProvisionPreviewJson(prof, tab_ids, alloc);
}

pub fn buildProvisionPreviewJson(prof: profile_mod.Profile, tab_ids: []const online_provider.TabRef, alloc: Allocator) ![]const u8 {
    var existing: std.ArrayList([]const u8) = .empty;
    defer existing.deinit(alloc);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ready\":true,\"profile\":");
    try shared.appendJsonStr(&buf, @tagName(prof.id), alloc);
    try buf.appendSlice(alloc, ",\"tabs\":[");
    for (prof.tabs, 0..) |tab, i| {
        if (i > 0) try buf.append(alloc, ',');
        const exists = previewTabExists(tab_ids, tab);
        if (exists) try existing.append(alloc, tab) else try missing.append(alloc, tab);
        try buf.appendSlice(alloc, "{\"name\":");
        try shared.appendJsonStr(&buf, tab, alloc);
        try buf.appendSlice(alloc, ",\"exists\":");
        try buf.appendSlice(alloc, if (exists) "true" else "false");
        try buf.append(alloc, '}');
    }
    try buf.append(alloc, ']');
    try std.fmt.format(buf.writer(alloc), ",\"existing_count\":{d},\"missing_count\":{d},\"existing\":", .{ existing.items.len, missing.items.len });
    const existing_json = try shared.jsonStringArray(existing.items, alloc);
    defer alloc.free(existing_json);
    try buf.appendSlice(alloc, existing_json);
    try buf.appendSlice(alloc, ",\"missing\":");
    const missing_json = try shared.jsonStringArray(missing.items, alloc);
    defer alloc.free(missing_json);
    try buf.appendSlice(alloc, missing_json);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn previewTabExists(existing_tabs: []const online_provider.TabRef, want: []const u8) bool {
    for (existing_tabs) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, want)) return true;
        if (containsIgnoreCase(tab.title, want) or containsIgnoreCase(want, tab.title)) return true;
    }
    return false;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var hay_buf: [128]u8 = undefined;
    var needle_buf: [128]u8 = undefined;
    const hay_len = @min(haystack.len, hay_buf.len);
    const needle_len = @min(needle.len, needle_buf.len);
    for (haystack[0..hay_len], 0..) |c, i| hay_buf[i] = std.ascii.toLower(c);
    for (needle[0..needle_len], 0..) |c, i| needle_buf[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, hay_buf[0..hay_len], needle_buf[0..needle_len]) != null;
}

const testing = std.testing;

test "handleProvisionPreview returns ready false without credential or sheet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);

    const resp = try handleProvisionPreview(&db, &store, null, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"ready\":false") != null);
}

test "buildProvisionPreviewJson closes tabs array before summary fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prof = profile_mod.get(.medical);
    const tabs = [_]online_provider.TabRef{
        .{ .title = "User Needs", .native_id = "1" },
        .{ .title = "Requirements", .native_id = "2" },
        .{ .title = "Tests", .native_id = "3" },
        .{ .title = "Risks", .native_id = "4" },
    };
    const preview = try buildProvisionPreviewJson(prof, &tabs, alloc);
    defer alloc.free(preview);

    try testing.expect(std.mem.indexOf(u8, preview, "],\"existing_count\"") != null);
}
