const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const license = rtmify.license;
const graph_live = @import("../graph_live.zig");
const sync_live = @import("../sync_live.zig");
const connection_mod = @import("../connection.zig");
const provider_common = @import("../provider_common.zig");
const secure_store_mod = @import("../secure_store.zig");
const online_provider = @import("../online_provider.zig");
const shared = @import("shared.zig");

pub fn handleStatus(db: *graph_live.GraphDb, secure_store: *secure_store_mod.Store, state: *sync_live.SyncState, license_service: *license.Service, alloc: Allocator) ![]const u8 {
    const last_sync = state.last_sync_at.load(.seq_cst);
    const has_error = state.has_error.load(.seq_cst);
    const sync_count = state.sync_count.load(.seq_cst);
    const repo_scan_in_progress = state.repo_scan_in_progress.load(.seq_cst);
    const repo_scan_last_started_at = state.repo_scan_last_started_at.load(.seq_cst);
    const repo_scan_last_finished_at = state.repo_scan_last_finished_at.load(.seq_cst);
    var license_status = try license_service.getStatus(alloc);
    defer license_status.deinit(alloc);
    const license_valid = license_status.permits_use;
    state.product_enabled.store(license_valid, .seq_cst);

    var err_buf: [256]u8 = undefined;
    const err_len = state.getError(&err_buf);
    const err_str = err_buf[0..err_len];
    var loaded = try connection_mod.loadActive(db, secure_store, alloc);
    defer loaded.deinit(alloc);
    const configured = loaded == .active;
    const block_reason: ?provider_common.ConnectionBlockReason = if (loaded == .blocked) loaded.blocked else null;

    const platform_str = if (configured) try alloc.dupe(u8, online_provider.providerIdString(loaded.active.platform)) else blk: {
        const stored = try db.getConfig("platform", alloc);
        defer if (stored) |value| alloc.free(value);
        if (stored) |value| break :blk try alloc.dupe(u8, value);
        break :blk null;
    };
    defer if (platform_str) |value| alloc.free(value);
    const credential_display = if (configured) if (loaded.active.credential_display) |value| try alloc.dupe(u8, value) else null else try db.getConfig("credential_display", alloc);
    defer if (credential_display) |value| alloc.free(value);
    const workbook_label = if (configured) try alloc.dupe(u8, loaded.active.workbook_label) else try db.getConfig("workbook_label", alloc);
    defer if (workbook_label) |value| alloc.free(value);
    const workbook_url = if (configured) try alloc.dupe(u8, loaded.active.workbook_url) else try db.getConfig("workbook_url", alloc);
    defer if (workbook_url) |value| alloc.free(value);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "{{\"configured\":{s},\"last_sync_at\":{d},\"has_error\":{s},\"error\":", .{
        if (configured) "true" else "false", last_sync, if (has_error) "true" else "false",
    });
    try shared.appendJsonStr(&buf, err_str, alloc);
    try buf.appendSlice(alloc, ",\"license\":");
    try appendLicenseStatusJson(&buf, license_status, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"sync_count\":{d},\"license_valid\":{s},\"platform\":", .{
        sync_count, if (license_valid) "true" else "false",
    });
    try shared.appendJsonStrOpt(&buf, platform_str, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try shared.appendJsonStrOpt(&buf, credential_display, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try shared.appendJsonStrOpt(&buf, workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"workbook_url\":");
    try shared.appendJsonStrOpt(&buf, workbook_url, alloc);
    try buf.appendSlice(alloc, ",\"connection_block_reason\":");
    try shared.appendJsonStrOpt(&buf, if (block_reason) |value| @tagName(value) else null, alloc);
    try buf.appendSlice(alloc, ",\"secure_storage_backend\":");
    try shared.appendJsonStr(&buf, secure_store_mod.backendName(secure_store.backend), alloc);
    const profile = try db.getConfig("profile", alloc);
    defer if (profile) |value| alloc.free(value);
    try buf.appendSlice(alloc, ",\"profile\":");
    try shared.appendJsonStrOpt(&buf, profile, alloc);
    const last_scan = (try db.getConfig("last_scan_at", alloc)) orelse try alloc.dupe(u8, "never");
    defer alloc.free(last_scan);
    try buf.appendSlice(alloc, ",\"last_scan_at\":");
    try shared.appendJsonStr(&buf, last_scan, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"repo_scan_in_progress\":{s},\"repo_scan_last_started_at\":{d},\"repo_scan_last_finished_at\":{d}", .{
        if (repo_scan_in_progress) "true" else "false",
        repo_scan_last_started_at,
        repo_scan_last_finished_at,
    });
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn handleInfo(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    const tray_version = (try db.getConfig("tray_app_version", alloc)) orelse try alloc.dupe(u8, "not available");
    defer alloc.free(tray_version);
    const live_version = (try db.getConfig("live_version", alloc)) orelse try alloc.dupe(u8, "unknown");
    defer alloc.free(live_version);
    const db_path = (try db.getConfig("db_path", alloc)) orelse try alloc.dupe(u8, "unknown");
    defer alloc.free(db_path);
    const log_path = (try db.getConfig("log_path", alloc)) orelse try alloc.dupe(u8, "unknown");
    defer alloc.free(log_path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"tray_app_version\":");
    try shared.appendJsonStr(&buf, tray_version, alloc);
    try buf.appendSlice(alloc, ",\"live_version\":");
    try shared.appendJsonStr(&buf, live_version, alloc);
    try buf.appendSlice(alloc, ",\"db_path\":");
    try shared.appendJsonStr(&buf, db_path, alloc);
    try buf.appendSlice(alloc, ",\"log_path\":");
    try shared.appendJsonStr(&buf, log_path, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn licenseEnvelopeJson(status: license.LicenseStatus, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"license\":");
    try appendLicenseStatusJson(&buf, status, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn appendLicenseStatusJson(buf: *std.ArrayList(u8), status: license.LicenseStatus, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"state\":");
    try shared.appendJsonStr(buf, @tagName(status.state), alloc);
    try buf.appendSlice(alloc, ",\"permits_use\":");
    try buf.appendSlice(alloc, if (status.permits_use) "true" else "false");
    try buf.appendSlice(alloc, ",\"provider_id\":");
    try shared.appendJsonStr(buf, status.provider_id, alloc);
    try buf.appendSlice(alloc, ",\"activated_at\":");
    try shared.appendJsonIntOpt(buf, status.activated_at, alloc);
    try buf.appendSlice(alloc, ",\"expires_at\":");
    try shared.appendJsonIntOpt(buf, status.expires_at, alloc);
    try buf.appendSlice(alloc, ",\"last_validated_at\":");
    try shared.appendJsonIntOpt(buf, status.last_validated_at, alloc);
    try buf.appendSlice(alloc, ",\"offline_grace_deadline\":");
    try shared.appendJsonIntOpt(buf, status.offline_grace_deadline, alloc);
    try buf.appendSlice(alloc, ",\"detail_code\":");
    try shared.appendJsonStr(buf, @tagName(status.detail_code), alloc);
    try buf.appendSlice(alloc, ",\"message\":");
    try shared.appendJsonStrOpt(buf, status.message, alloc);
    try buf.append(alloc, '}');
}

const testing = std.testing;

test "gitless mode status is configured and repos list is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);

    var state: sync_live.SyncState = .{};

    try db.storeConfig("platform", "google");
    try db.storeConfig("google_sheet_id", "sheet-123");
    try db.storeConfig("workbook_url", "https://docs.google.com/spreadsheets/d/sheet-123/edit");
    try db.storeConfig("workbook_label", "sheet-123");
    try db.storeConfig("credential_display", "svc@example.com");
    try db.storeConfig("credential_ref", "cred_status");
    try db.storeConfig("credential_backend", "test_memory");
    try db.storeConfig("credential_store_version", "1");
    try store.put(alloc, "cred_status", "{\"platform\":\"google\",\"client_email\":\"svc@example.com\",\"private_key\":\"key\"}");

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);
    var activation = try license_service.activate(alloc, .{ .license_key = license.DEV_KEY });
    defer activation.deinit(alloc);

    const status = try handleStatus(&db, &store, &state, &license_service, alloc);
    try testing.expect(std.mem.indexOf(u8, status, "\"configured\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"platform\":\"google\"") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"credential_display\":\"svc@example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"secure_storage_backend\":\"test_memory\"") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"license_valid\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_in_progress\":false") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_last_started_at\":0") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_last_finished_at\":0") != null);
}

test "handleStatus includes repo scan lifecycle fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);

    var state: sync_live.SyncState = .{};
    state.repo_scan_in_progress.store(true, .seq_cst);
    state.repo_scan_last_started_at.store(123, .seq_cst);
    state.repo_scan_last_finished_at.store(456, .seq_cst);

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);
    const status = try handleStatus(&db, &store, &state, &license_service, alloc);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_in_progress\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_last_started_at\":123") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_last_finished_at\":456") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"license_valid\":false") != null);
}

test "handleStatus reports legacy plaintext connection as blocked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var state: sync_live.SyncState = .{};

    try db.storeConfig("platform", "google");
    try db.storeConfig("google_sheet_id", "legacy-sheet");
    try db.storeConfig("workbook_url", "https://docs.google.com/spreadsheets/d/legacy-sheet/edit");
    try db.storeConfig("workbook_label", "legacy-sheet");
    try db.storeConfig("credential_display", "svc@example.com");
    try db.storeCredential("{\"platform\":\"google\",\"client_email\":\"svc@example.com\",\"private_key\":\"pem\"}");

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);

    const status = try handleStatus(&db, &store, &state, &license_service, alloc);
    try testing.expect(std.mem.indexOf(u8, status, "\"configured\":false") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"connection_block_reason\":\"legacy_plaintext_credentials\"") != null);
}

test "handleInfo returns version and path details" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.storeConfig("tray_app_version", "0.1 (1)");
    try db.storeConfig("live_version", "20260308-a");
    try db.storeConfig("db_path", "/tmp/graph.db");
    try db.storeConfig("log_path", "/tmp/server.log");

    const resp = try handleInfo(&db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("0.1 (1)", obj.get("tray_app_version").?.string);
    try testing.expectEqualStrings("20260308-a", obj.get("live_version").?.string);
    try testing.expectEqualStrings("/tmp/graph.db", obj.get("db_path").?.string);
    try testing.expectEqualStrings("/tmp/server.log", obj.get("log_path").?.string);
}
