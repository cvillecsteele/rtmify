const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("graph_live.zig");
const common = @import("provider_common.zig");
const online_provider = @import("online_provider.zig");
const provider_excel = @import("provider_excel.zig");
const json_util = @import("json_util.zig");
const secure_store = @import("secure_store.zig");

pub const GraphDb = graph_live.GraphDb;

pub fn parseDraftFromJson(body: []const u8, alloc: Allocator) !common.DraftConnection {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const platform_str = getString(root, "platform") orelse return error.InvalidJson;
    const platform = common.providerIdFromString(platform_str) orelse return error.InvalidJson;
    const workbook_url = getString(root, "workbook_url") orelse return error.InvalidJson;
    const profile = getString(root, "profile");
    const credentials = root.object.get("credentials") orelse return error.InvalidJson;
    if (credentials != .object) return error.InvalidJson;

    const credentials_json = switch (platform) {
        .google => blk: {
            const raw = getString(credentials, "service_account_json") orelse return error.InvalidJson;
            break :blk try normalizeGoogleCredentialJson(raw, alloc);
        },
        .excel => blk: {
            const tenant_id = getString(credentials, "tenant_id") orelse return error.InvalidJson;
            const client_id = getString(credentials, "client_id") orelse return error.InvalidJson;
            const client_secret = getString(credentials, "client_secret") orelse return error.InvalidJson;
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(alloc);
            try buf.appendSlice(alloc, "{\"platform\":\"excel\",\"tenant_id\":");
            try json_util.appendJsonQuoted(&buf, tenant_id, alloc);
            try buf.appendSlice(alloc, ",\"client_id\":");
            try json_util.appendJsonQuoted(&buf, client_id, alloc);
            try buf.appendSlice(alloc, ",\"client_secret\":");
            try json_util.appendJsonQuoted(&buf, client_secret, alloc);
            try buf.append(alloc, '}');
            break :blk try buf.toOwnedSlice(alloc);
        },
    };

    return .{
        .platform = platform,
        .profile = if (profile) |v| try alloc.dupe(u8, v) else null,
        .workbook_url = try alloc.dupe(u8, workbook_url),
        .credentials_json = credentials_json,
    };
}

pub fn validateDraft(draft: common.DraftConnection, alloc: Allocator) !common.ValidatedDraft {
    return switch (draft.platform) {
        .google => validateGoogleDraft(draft, alloc),
        .excel => validateExcelDraft(draft, alloc),
    };
}

pub fn persistActive(db: *GraphDb, store: *secure_store.Store, draft: common.ValidatedDraft, alloc: Allocator) !void {
    if (!secure_store.backendSupported(store.*)) return error.SecureStorageUnsupported;

    const old_ref = try db.getConfig("credential_ref", alloc);
    defer if (old_ref) |value| alloc.free(value);

    const credential_ref = try secure_store.generateCredentialRef(alloc);
    defer alloc.free(credential_ref);
    try store.put(alloc, credential_ref, draft.credential_json);
    errdefer store.delete(alloc, credential_ref) catch {};

    try db.storeConfig("platform", common.providerIdString(draft.platform));
    try db.storeConfig("workbook_url", draft.workbook_url);
    try db.storeConfig("workbook_label", draft.workbook_label);
    try db.storeConfig("credential_ref", credential_ref);
    try db.storeConfig("credential_backend", secure_store.backendName(store.backend));
    try db.storeConfig("credential_store_version", "1");
    if (draft.credential_display) |v| {
        try db.storeConfig("credential_display", v);
    } else {
        db.deleteConfig("credential_display") catch {};
    }
    switch (draft.target) {
        .google => |g| {
            try db.storeConfig("google_sheet_id", g.sheet_id);
            db.deleteConfig("excel_drive_id") catch {};
            db.deleteConfig("excel_item_id") catch {};
        },
        .excel => |e| {
            try db.storeConfig("excel_drive_id", e.drive_id);
            try db.storeConfig("excel_item_id", e.item_id);
            db.deleteConfig("google_sheet_id") catch {};
        },
    }
    try db.clearLegacyCredentials();

    if (old_ref) |value| {
        if (!std.mem.eql(u8, value, credential_ref)) {
            store.delete(alloc, value) catch {};
        }
    }
}

pub fn loadActive(db: *GraphDb, store: *secure_store.Store, alloc: Allocator) !common.LoadedConnection {
    const platform_str = (try db.getConfig("platform", alloc)) orelse return .none;
    defer alloc.free(platform_str);
    const platform = common.providerIdFromString(platform_str) orelse return .none;
    const credential_ref = try db.getConfig("credential_ref", alloc);
    defer if (credential_ref) |value| alloc.free(value);

    if (credential_ref == null) {
        if (try db.hasLegacyCredential()) return .{ .blocked = .legacy_plaintext_credentials };
        return .{ .blocked = .credential_ref_missing };
    }

    const credential_json = store.get(alloc, credential_ref.?) catch |err| switch (err) {
        error.Unsupported => return .{ .blocked = .secure_storage_unsupported },
        error.NotFound => return .{ .blocked = .secret_not_found },
        else => return .{ .blocked = .secret_store_error },
    };
    errdefer alloc.free(credential_json);

    const workbook_url = (try db.getConfig("workbook_url", alloc)) orelse return .none;
    errdefer alloc.free(workbook_url);
    const workbook_label = (try db.getConfig("workbook_label", alloc)) orelse return .none;
    errdefer alloc.free(workbook_label);
    const credential_display = try db.getConfig("credential_display", alloc);
    errdefer if (credential_display) |v| alloc.free(v);

    const target = switch (platform) {
        .google => blk: {
            const sheet_id = (try db.getConfig("google_sheet_id", alloc)) orelse (try db.getConfig("sheet_id", alloc)) orelse return .none;
            break :blk common.Target{ .google = .{ .sheet_id = sheet_id } };
        },
        .excel => blk: {
            const drive_id = (try db.getConfig("excel_drive_id", alloc)) orelse return .none;
            errdefer alloc.free(drive_id);
            const item_id = (try db.getConfig("excel_item_id", alloc)) orelse return .none;
            break :blk common.Target{ .excel = .{ .drive_id = drive_id, .item_id = item_id } };
        },
    };

    return .{ .active = .{
        .platform = platform,
        .credential_json = credential_json,
        .workbook_url = workbook_url,
        .workbook_label = workbook_label,
        .credential_display = credential_display,
        .target = target,
    } };
}

pub fn migrateLegacyGoogleConfig(db: *GraphDb, store: *secure_store.Store, alloc: Allocator) !void {
    _ = store;
    const platform = try db.getConfig("platform", alloc);
    defer if (platform) |v| alloc.free(v);
    if (platform != null) return;

    const credential_json = try db.getLatestCredential(alloc);
    defer if (credential_json) |v| alloc.free(v);
    const sheet_id = try db.getConfig("sheet_id", alloc);
    defer if (sheet_id) |v| alloc.free(v);
    if (credential_json == null or sheet_id == null) return;
    if (json_util.extractJsonFieldStatic(credential_json.?, "client_email") == null or json_util.extractJsonFieldStatic(credential_json.?, "private_key") == null) return;

    try db.storeConfig("platform", "google");
    try db.storeConfig("google_sheet_id", sheet_id.?);
    const workbook_url = try std.fmt.allocPrint(alloc, "https://docs.google.com/spreadsheets/d/{s}/edit", .{sheet_id.?});
    defer alloc.free(workbook_url);
    try db.storeConfig("workbook_url", workbook_url);
    try db.storeConfig("workbook_label", sheet_id.?);
    if (json_util.extractJsonFieldStatic(credential_json.?, "client_email")) |email| {
        try db.storeConfig("credential_display", email);
    }
}

fn validateGoogleDraft(draft: common.DraftConnection, alloc: Allocator) !common.ValidatedDraft {
    const sheet_id = extractGoogleSheetId(draft.workbook_url) orelse return error.InvalidWorkbookUrl;
    const credential_display = json_util.extractJsonFieldStatic(draft.credentials_json, "client_email") orelse return error.InvalidCredential;

    var active = common.ActiveConnection{
        .platform = .google,
        .credential_json = try alloc.dupe(u8, draft.credentials_json),
        .workbook_url = try alloc.dupe(u8, draft.workbook_url),
        .workbook_label = try alloc.dupe(u8, sheet_id),
        .credential_display = try alloc.dupe(u8, credential_display),
        .target = .{ .google = .{ .sheet_id = try alloc.dupe(u8, sheet_id) } },
    };
    defer active.deinit(alloc);

    var runtime = try online_provider.ProviderRuntime.init(active, alloc);
    defer runtime.deinit(alloc);
    const tabs = try runtime.listTabs(alloc);
    common.freeTabRefs(tabs, alloc);

    return .{
        .platform = .google,
        .profile = if (draft.profile) |v| try alloc.dupe(u8, v) else null,
        .credential_json = try alloc.dupe(u8, draft.credentials_json),
        .workbook_url = try alloc.dupe(u8, draft.workbook_url),
        .workbook_label = try alloc.dupe(u8, sheet_id),
        .credential_display = try alloc.dupe(u8, credential_display),
        .target = .{ .google = .{ .sheet_id = try alloc.dupe(u8, sheet_id) } },
    };
}

fn validateExcelDraft(draft: common.DraftConnection, alloc: Allocator) !common.ValidatedDraft {
    const tenant_id = json_util.extractJsonFieldStatic(draft.credentials_json, "tenant_id") orelse return error.InvalidCredential;
    const client_id = json_util.extractJsonFieldStatic(draft.credentials_json, "client_id") orelse return error.InvalidCredential;
    const client_secret = json_util.extractJsonFieldStatic(draft.credentials_json, "client_secret") orelse return error.InvalidCredential;

    var http_client = std.http.Client{ .allocator = alloc };
    defer http_client.deinit();
    var resolved = try provider_excel.resolveWorkbookUrl(&http_client, tenant_id, client_id, client_secret, draft.workbook_url, alloc);
    errdefer resolved.deinit(alloc);

    const credential_display = try std.fmt.allocPrint(alloc, "Tenant {s} / App {s}", .{ tenant_id, client_id });
    errdefer alloc.free(credential_display);

    var active = common.ActiveConnection{
        .platform = .excel,
        .credential_json = try alloc.dupe(u8, draft.credentials_json),
        .workbook_url = try alloc.dupe(u8, draft.workbook_url),
        .workbook_label = try alloc.dupe(u8, resolved.workbook_label),
        .credential_display = try alloc.dupe(u8, credential_display),
        .target = .{ .excel = .{ .drive_id = try alloc.dupe(u8, resolved.drive_id), .item_id = try alloc.dupe(u8, resolved.item_id) } },
    };
    defer active.deinit(alloc);
    var runtime = try online_provider.ProviderRuntime.init(active, alloc);
    defer runtime.deinit(alloc);
    const tabs = try runtime.listTabs(alloc);
    common.freeTabRefs(tabs, alloc);

    return .{
        .platform = .excel,
        .profile = if (draft.profile) |v| try alloc.dupe(u8, v) else null,
        .credential_json = try alloc.dupe(u8, draft.credentials_json),
        .workbook_url = try alloc.dupe(u8, draft.workbook_url),
        .workbook_label = resolved.workbook_label,
        .credential_display = credential_display,
        .target = .{ .excel = .{ .drive_id = resolved.drive_id, .item_id = resolved.item_id } },
    };
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn normalizeGoogleCredentialJson(raw_json: []const u8, alloc: Allocator) ![]u8 {
    var trimmed = std.mem.trim(u8, raw_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.InvalidCredential;
    trimmed = trimmed[1 .. trimmed.len - 1];
    if (trimmed.len == 0) {
        return alloc.dupe(u8, "{\"platform\":\"google\"}");
    }
    return std.fmt.allocPrint(alloc, "{{\"platform\":\"google\",{s}}}", .{trimmed});
}

fn extractGoogleSheetId(url: []const u8) ?[]const u8 {
    const marker = "/spreadsheets/d/";
    const idx = std.mem.indexOf(u8, url, marker) orelse return null;
    const start = idx + marker.len;
    const end = std.mem.indexOfScalarPos(u8, url, start, '/') orelse url.len;
    if (end <= start) return null;
    return url[start..end];
}

const testing = std.testing;

test "parseDraftFromJson handles google payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"google\",\"profile\":\"medical\",\"workbook_url\":\"https://docs.google.com/spreadsheets/d/abc/edit\",\"credentials\":{\"service_account_json\":\"{\\\"client_email\\\":\\\"svc@example.com\\\",\\\"private_key\\\":\\\"pem\\\"}\"}}";
    var draft = try parseDraftFromJson(body, alloc);
    defer draft.deinit(alloc);
    try testing.expectEqual(common.ProviderId.google, draft.platform);
    try testing.expect(std.mem.indexOf(u8, draft.credentials_json, "\"platform\":\"google\"") != null);
}

test "parseDraftFromJson preserves pretty printed google credential fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"google\",\"profile\":\"medical\",\"workbook_url\":\"https://docs.google.com/spreadsheets/d/abc/edit\",\"credentials\":{\"service_account_json\":\"{\\n  \\\"type\\\": \\\"service_account\\\",\\n  \\\"client_email\\\": \\\"svc@example.com\\\",\\n  \\\"private_key\\\": \\\"pem\\\"\\n}\"}}";
    var draft = try parseDraftFromJson(body, alloc);
    defer draft.deinit(alloc);
    try testing.expectEqualStrings("svc@example.com", json_util.extractJsonFieldStatic(draft.credentials_json, "client_email").?);
    try testing.expectEqualStrings("pem", json_util.extractJsonFieldStatic(draft.credentials_json, "private_key").?);
}

test "parseDraftFromJson handles excel payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"excel\",\"workbook_url\":\"https://tenant.sharepoint.com/x\",\"credentials\":{\"tenant_id\":\"t\",\"client_id\":\"c\",\"client_secret\":\"s\"}}";
    var draft = try parseDraftFromJson(body, alloc);
    defer draft.deinit(alloc);
    try testing.expectEqual(common.ProviderId.excel, draft.platform);
    try testing.expect(std.mem.indexOf(u8, draft.credentials_json, "\"tenant_id\":\"t\"") != null);
}

test "parseDraftFromJson preserves excel client_secret containing quote and backslash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"excel\",\"workbook_url\":\"https://tenant.sharepoint.com/x\",\"credentials\":{\"tenant_id\":\"t\",\"client_id\":\"c\",\"client_secret\":\"s3cr\\\"et\\\\with\\nchars\"}}";
    var draft = try parseDraftFromJson(body, alloc);
    defer draft.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, draft.credentials_json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("s3cr\"et\\with\nchars", json_util.getString(parsed.value, "client_secret").?);
}

test "persistActive and loadActive roundtrip excel escaped credential content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store.initTestMemory(alloc);
    defer store.deinit(alloc);
    const validated = common.ValidatedDraft{
        .platform = .excel,
        .profile = null,
        .credential_json = try alloc.dupe(u8, "{\"platform\":\"excel\",\"tenant_id\":\"tenant\",\"client_id\":\"client\",\"client_secret\":\"s3cr\\\"et\\\\with\\nchars\"}"),
        .workbook_url = try alloc.dupe(u8, "https://tenant.sharepoint.com/x"),
        .workbook_label = try alloc.dupe(u8, "RTMify.xlsx"),
        .credential_display = try alloc.dupe(u8, "Tenant tenant / App client"),
        .target = .{ .excel = .{ .drive_id = try alloc.dupe(u8, "drive"), .item_id = try alloc.dupe(u8, "item") } },
    };
    defer {
        var tmp = validated;
        tmp.deinit(alloc);
    }
    try persistActive(&db, &store, validated, alloc);
    var loaded = try loadActive(&db, &store, alloc);
    defer loaded.deinit(alloc);
    try testing.expect(loaded == .active);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, loaded.active.credential_json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("s3cr\"et\\with\nchars", json_util.getString(parsed.value, "client_secret").?);
}

test "persistActive and loadActive roundtrip google" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store.initTestMemory(alloc);
    defer store.deinit(alloc);
    const validated = common.ValidatedDraft{
        .platform = .google,
        .profile = null,
        .credential_json = try alloc.dupe(u8, "{\"platform\":\"google\",\"client_email\":\"svc@example.com\",\"private_key\":\"pem\"}"),
        .workbook_url = try alloc.dupe(u8, "https://docs.google.com/spreadsheets/d/abc/edit"),
        .workbook_label = try alloc.dupe(u8, "abc"),
        .credential_display = try alloc.dupe(u8, "svc@example.com"),
        .target = .{ .google = .{ .sheet_id = try alloc.dupe(u8, "abc") } },
    };
    defer {
        var tmp = validated;
        tmp.deinit(alloc);
    }
    try persistActive(&db, &store, validated, alloc);
    var loaded = try loadActive(&db, &store, alloc);
    defer loaded.deinit(alloc);
    try testing.expect(loaded == .active);
    try testing.expectEqual(common.ProviderId.google, loaded.active.platform);
    try testing.expectEqualStrings("abc", loaded.active.target.google.sheet_id);

    try testing.expect((try db.getLatestCredential(alloc)) == null);
    const credential_ref = (try db.getConfig("credential_ref", alloc)).?;
    defer alloc.free(credential_ref);
    try testing.expect(std.mem.startsWith(u8, credential_ref, "cred_"));
}

test "migrateLegacyGoogleConfig populates provider keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store.initTestMemory(alloc);
    defer store.deinit(alloc);
    try db.storeCredential("{\"client_email\":\"svc@example.com\",\"private_key\":\"pem\"}");
    try db.storeConfig("sheet_id", "legacy-sheet");
    try migrateLegacyGoogleConfig(&db, &store, alloc);
    const platform = (try db.getConfig("platform", alloc)).?;
    defer alloc.free(platform);
    try testing.expectEqualStrings("google", platform);
    const google_sheet_id = (try db.getConfig("google_sheet_id", alloc)).?;
    defer alloc.free(google_sheet_id);
    try testing.expectEqualStrings("legacy-sheet", google_sheet_id);
}

test "loadActive blocks on legacy plaintext credentials" {
    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);

    try db.storeConfig("platform", "google");
    try db.storeConfig("workbook_url", "https://docs.google.com/spreadsheets/d/legacy-sheet/edit");
    try db.storeConfig("workbook_label", "legacy-sheet");
    try db.storeConfig("credential_display", "svc@example.com");
    try db.storeConfig("google_sheet_id", "legacy-sheet");
    try db.storeCredential("{\"client_email\":\"svc@example.com\",\"private_key\":\"pem\"}");

    const loaded = try loadActive(&db, &store, testing.allocator);
    try testing.expectEqual(common.LoadedConnection{ .blocked = .legacy_plaintext_credentials }, loaded);
}

test "loadActive blocks when secure secret is missing" {
    var db = try GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);

    try db.storeConfig("platform", "google");
    try db.storeConfig("workbook_url", "https://docs.google.com/spreadsheets/d/secure-sheet/edit");
    try db.storeConfig("workbook_label", "secure-sheet");
    try db.storeConfig("credential_display", "svc@example.com");
    try db.storeConfig("google_sheet_id", "secure-sheet");
    try db.storeConfig("credential_ref", "cred_missing");
    try db.storeConfig("credential_backend", "test_memory");
    try db.storeConfig("credential_store_version", "1");

    const loaded = try loadActive(&db, &store, testing.allocator);
    try testing.expectEqual(common.LoadedConnection{ .blocked = .secret_not_found }, loaded);
}
