const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("graph_live.zig");
const common = @import("provider_common.zig");
const online_provider = @import("online_provider.zig");
const provider_excel = @import("provider_excel.zig");
const json_util = @import("json_util.zig");
const secure_store = @import("secure_store.zig");
const workbook = @import("workbook/mod.zig");

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
            const tenant_id = getNonEmptyString(credentials, "tenant_id") orelse return error.InvalidCredential;
            const client_id = getNonEmptyString(credentials, "client_id") orelse return error.InvalidCredential;
            const client_secret = getNonEmptyString(credentials, "client_secret") orelse return error.InvalidCredential;
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

pub fn persistActiveWorkbook(registry: *workbook.WorkbookRegistry, store: *secure_store.Store, draft: common.ValidatedDraft, alloc: Allocator) !void {
    if (!secure_store.backendSupported(store.*)) return error.SecureStorageUnsupported;

    const cfg = try registry.activeConfig();
    const old_ref = if (cfg.credential_ref) |value| try alloc.dupe(u8, value) else null;
    defer if (old_ref) |value| alloc.free(value);

    const credential_ref = try secure_store.generateCredentialRef(alloc);
    defer alloc.free(credential_ref);
    try store.put(alloc, credential_ref, draft.credential_json);
    errdefer store.delete(alloc, credential_ref) catch {};

    try workbook.config.replaceActiveConnection(&registry.live_config, draft, credential_ref, alloc);
    const runtime = try registry.active();
    runtime.config.deinit(alloc);
    runtime.config = try (try registry.activeConfig()).clone(alloc);
    try registry.save(alloc);

    if (old_ref) |value| {
        if (!std.mem.eql(u8, value, credential_ref)) {
            store.delete(alloc, value) catch {};
        }
    }
}

pub fn loadWorkbookConnection(cfg: workbook.WorkbookConfig, store: *secure_store.Store, alloc: Allocator) !common.LoadedConnection {
    const platform = cfg.platform orelse return .none;
    const credential_ref = if (cfg.credential_ref) |value| try alloc.dupe(u8, value) else null;
    defer if (credential_ref) |value| alloc.free(value);

    if (credential_ref == null) {
        return .{ .blocked = .credential_ref_missing };
    }

    const credential_json = store.get(alloc, credential_ref.?) catch |err| switch (err) {
        error.Unsupported => return .{ .blocked = .secure_storage_unsupported },
        error.NotFound => return .{ .blocked = .secret_not_found },
        else => return .{ .blocked = .secret_store_error },
    };
    errdefer alloc.free(credential_json);

    const workbook_url = if (cfg.workbook_url) |value| try alloc.dupe(u8, value) else return .none;
    errdefer alloc.free(workbook_url);
    const workbook_label = if (cfg.workbook_label) |value| try alloc.dupe(u8, value) else return .none;
    errdefer alloc.free(workbook_label);
    const credential_display = if (cfg.credential_display) |value| try alloc.dupe(u8, value) else null;
    errdefer if (credential_display) |v| alloc.free(v);

    const target = switch (platform) {
        .google => blk: {
            const sheet_id = if (cfg.google_sheet_id) |value| try alloc.dupe(u8, value) else return .none;
            break :blk common.Target{ .google = .{ .sheet_id = sheet_id } };
        },
        .excel => blk: {
            const drive_id = if (cfg.excel_drive_id) |value| try alloc.dupe(u8, value) else return .none;
            errdefer alloc.free(drive_id);
            const item_id = if (cfg.excel_item_id) |value| try alloc.dupe(u8, value) else return .none;
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
    _ = db;
    _ = store;
    _ = alloc;
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
    try validateExcelCredentialJsonShape(draft.credentials_json, alloc);
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

fn getNonEmptyString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const raw = getString(value, key) orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

fn normalizeGoogleCredentialJson(raw_json: []const u8, alloc: Allocator) ![]u8 {
    try validateGoogleCredentialJsonShape(raw_json, alloc);
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

fn validateGoogleCredentialJsonShape(raw_json: []const u8, alloc: Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw_json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidCredential;
    const ty = getString(root, "type") orelse return error.InvalidCredential;
    if (!std.mem.eql(u8, ty, "service_account")) return error.InvalidCredential;
    const client_email = getString(root, "client_email") orelse return error.InvalidCredential;
    if (std.mem.trim(u8, client_email, " \t\r\n").len == 0) return error.InvalidCredential;
    const private_key = getString(root, "private_key") orelse return error.InvalidCredential;
    if (std.mem.trim(u8, private_key, " \t\r\n").len == 0) return error.InvalidCredential;
}

fn validateExcelCredentialJsonShape(raw_json: []const u8, alloc: Allocator) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw_json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidCredential;
    const tenant_id = getString(root, "tenant_id") orelse return error.InvalidCredential;
    if (std.mem.trim(u8, tenant_id, " \t\r\n").len == 0) return error.InvalidCredential;
    const client_id = getString(root, "client_id") orelse return error.InvalidCredential;
    if (std.mem.trim(u8, client_id, " \t\r\n").len == 0) return error.InvalidCredential;
    const client_secret = getString(root, "client_secret") orelse return error.InvalidCredential;
    if (std.mem.trim(u8, client_secret, " \t\r\n").len == 0) return error.InvalidCredential;
}

const testing = std.testing;

fn makeTestRegistry(alloc: Allocator, store: *secure_store.Store) !workbook.registry.WorkbookRegistry {
    var cfg = try workbook.config.bootstrapConfig(alloc, .{});
    errdefer cfg.deinit(alloc);
    alloc.free(cfg.workbooks[0].db_path);
    cfg.workbooks[0].db_path = try alloc.dupe(u8, ":memory:");
    alloc.free(cfg.workbooks[0].inbox_dir);
    cfg.workbooks[0].inbox_dir = try alloc.dupe(u8, "/tmp/inbox");
    return workbook.registry.WorkbookRegistry.initForConfig(alloc, cfg, store);
}

test "parseDraftFromJson handles google payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"google\",\"profile\":\"medical\",\"workbook_url\":\"https://docs.google.com/spreadsheets/d/abc/edit\",\"credentials\":{\"service_account_json\":\"{\\\"type\\\":\\\"service_account\\\",\\\"client_email\\\":\\\"svc@example.com\\\",\\\"private_key\\\":\\\"pem\\\"}\"}}";
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

test "parseDraftFromJson rejects non service-account google json" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"google\",\"profile\":\"medical\",\"workbook_url\":\"https://docs.google.com/spreadsheets/d/abc/edit\",\"credentials\":{\"service_account_json\":\"{\\\"payload\\\":{\\\"schema\\\":1},\\\"sig\\\":\\\"abc\\\"}\"}}";
    try testing.expectError(error.InvalidCredential, parseDraftFromJson(body, alloc));
}

test "parseDraftFromJson rejects google json missing private key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"google\",\"profile\":\"medical\",\"workbook_url\":\"https://docs.google.com/spreadsheets/d/abc/edit\",\"credentials\":{\"service_account_json\":\"{\\\"type\\\":\\\"service_account\\\",\\\"client_email\\\":\\\"svc@example.com\\\"}\"}}";
    try testing.expectError(error.InvalidCredential, parseDraftFromJson(body, alloc));
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

test "parseDraftFromJson rejects blank excel credential fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body =
        "{\"platform\":\"excel\",\"workbook_url\":\"https://tenant.sharepoint.com/x\",\"credentials\":{\"tenant_id\":\" \",\"client_id\":\"c\",\"client_secret\":\"s\"}}";
    try testing.expectError(error.InvalidCredential, parseDraftFromJson(body, alloc));
}

test "persistActive and loadActive roundtrip excel escaped credential content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
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
    try persistActiveWorkbook(&registry, &store, validated, alloc);
    var loaded = try loadWorkbookConnection((try registry.activeConfig()).*, &store, alloc);
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

    var store = try secure_store.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
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
    try persistActiveWorkbook(&registry, &store, validated, alloc);
    var loaded = try loadWorkbookConnection((try registry.activeConfig()).*, &store, alloc);
    defer loaded.deinit(alloc);
    try testing.expect(loaded == .active);
    try testing.expectEqual(common.ProviderId.google, loaded.active.platform);
    try testing.expectEqualStrings("abc", loaded.active.target.google.sheet_id);

    const credential_ref = (try registry.activeConfig()).credential_ref.?;
    try testing.expect(std.mem.startsWith(u8, credential_ref, "cred_"));
}

test "loadActive blocks when secure secret is missing" {
    var store = try secure_store.initTestMemory(testing.allocator);
    defer store.deinit(testing.allocator);
    var registry = try makeTestRegistry(testing.allocator, &store);
    defer registry.deinit(testing.allocator);
    {
        const cfg = try registry.activeConfig();
        cfg.platform = .google;
        cfg.workbook_url = try testing.allocator.dupe(u8, "https://docs.google.com/spreadsheets/d/secure-sheet/edit");
        cfg.workbook_label = try testing.allocator.dupe(u8, "secure-sheet");
        cfg.credential_display = try testing.allocator.dupe(u8, "svc@example.com");
        cfg.google_sheet_id = try testing.allocator.dupe(u8, "secure-sheet");
        cfg.credential_ref = try testing.allocator.dupe(u8, "cred_missing");
    }
    const loaded = try loadWorkbookConnection((try registry.activeConfig()).*, &store, testing.allocator);
    try testing.expectEqual(common.LoadedConnection{ .blocked = .secret_not_found }, loaded);
}
