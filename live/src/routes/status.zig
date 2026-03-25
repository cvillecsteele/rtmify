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
const test_results_auth = @import("../test_results_auth.zig");
const workbook = @import("../workbook/mod.zig");
const workspace_state = @import("../workspace_state.zig");
const shared = @import("shared.zig");

pub fn handleStatus(registry: *workbook.registry.WorkbookRegistry, secure_store: *secure_store_mod.Store, state: *sync_live.SyncState, license_service: *license.Service, alloc: Allocator) ![]const u8 {
    var license_status = try license_service.getStatus(alloc);
    defer license_status.deinit(alloc);
    const license_valid = license_status.permits_use;
    if (registry.active_runtime) |active_runtime| {
        state.product_enabled.store(license_valid, .seq_cst);

        const last_sync = state.last_sync_at.load(.seq_cst);
        const has_error = state.has_error.load(.seq_cst);
        const sync_count = state.sync_count.load(.seq_cst);
        const repo_scan_in_progress = state.repo_scan_in_progress.load(.seq_cst);
        const repo_scan_last_started_at = state.repo_scan_last_started_at.load(.seq_cst);
        const repo_scan_last_finished_at = state.repo_scan_last_finished_at.load(.seq_cst);

        var err_buf: [256]u8 = undefined;
        const err_len = state.getError(&err_buf);
        const err_str = err_buf[0..err_len];
        const workbook_cfg = try registry.activeConfig();
        var loaded = try connection_mod.loadWorkbookConnection(workbook_cfg.*, secure_store, alloc);
        defer loaded.deinit(alloc);
        const configured = loaded == .active;
        const graph_counts = try active_runtime.db.countGraph();
        const inferred_local_workspace = !configured and graph_counts.nodes > 0;
        const workspace_ready = try workspace_state.readWorkspaceReady(&active_runtime.db, configured or inferred_local_workspace, alloc);
        const source_of_truth = (try workspace_state.readSourceOfTruth(&active_runtime.db, alloc)) orelse if (configured or inferred_local_workspace) workspace_state.SourceOfTruth.workbook_first else null;
        const attach_workbook_prompt_dismissed = try workspace_state.readAttachWorkbookPromptDismissed(&active_runtime.db, alloc);
        const block_reason: ?provider_common.ConnectionBlockReason = if (loaded == .blocked) loaded.blocked else null;

        const platform_str = if (configured)
            try alloc.dupe(u8, online_provider.providerIdString(loaded.active.platform))
        else if (workbook_cfg.platform) |platform|
            try alloc.dupe(u8, online_provider.providerIdString(platform))
        else
            null;
        defer if (platform_str) |value| alloc.free(value);
        const credential_display = if (configured)
            if (loaded.active.credential_display) |value| try alloc.dupe(u8, value) else null
        else if (workbook_cfg.credential_display) |value|
            try alloc.dupe(u8, value)
        else
            null;
        defer if (credential_display) |value| alloc.free(value);
        const workbook_label = if (configured)
            try alloc.dupe(u8, loaded.active.workbook_label)
        else if (workbook_cfg.workbook_label) |value|
            try alloc.dupe(u8, value)
        else
            null;
        defer if (workbook_label) |value| alloc.free(value);
        const workbook_url = if (configured)
            try alloc.dupe(u8, loaded.active.workbook_url)
        else if (workbook_cfg.workbook_url) |value|
            try alloc.dupe(u8, value)
        else
            null;
        defer if (workbook_url) |value| alloc.free(value);
        var active_summary = try registry.summaryForWorkbookId(active_runtime.config.id, alloc);
        defer active_summary.deinit(alloc);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try std.fmt.format(buf.writer(alloc), "{{\"configured\":{s},\"workspace_ready\":{s},\"connection_configured\":{s},\"last_sync_at\":{d},\"has_error\":{s},\"error\":", .{
            if (workspace_ready) "true" else "false",
            if (workspace_ready) "true" else "false",
            if (configured) "true" else "false",
            last_sync,
            if (has_error) "true" else "false",
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
        try buf.appendSlice(alloc, ",\"source_of_truth\":");
        try shared.appendJsonStrOpt(&buf, if (source_of_truth) |value| value.asString() else null, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"hobbled_mode\":{s}", .{
            if (!license_valid) "true" else "false",
        });
        try buf.appendSlice(alloc, ",\"license_required_features\":[");
        const feature_list = [_][]const u8{
            "MCP",
            "Reports",
            "Repository Scanning",
            "Code Traceability",
            "Background Sync",
        };
        for (feature_list, 0..) |feature, idx| {
            if (idx > 0) try buf.append(alloc, ',');
            try shared.appendJsonStr(&buf, feature, alloc);
        }
        try buf.append(alloc, ']');
        try std.fmt.format(buf.writer(alloc), ",\"attach_workbook_prompt_dismissed\":{s}", .{
            if (attach_workbook_prompt_dismissed) "true" else "false",
        });
        try buf.appendSlice(alloc, ",\"connection_block_reason\":");
        try shared.appendJsonStrOpt(&buf, if (block_reason) |value| @tagName(value) else null, alloc);
        try buf.appendSlice(alloc, ",\"secure_storage_backend\":");
        try shared.appendJsonStr(&buf, secure_store_mod.backendName(secure_store.backend), alloc);
        try buf.appendSlice(alloc, ",\"profile\":");
        try shared.appendJsonStr(&buf, workbook_cfg.profile, alloc);
        const last_scan = (try active_runtime.db.getConfig("last_scan_at", alloc)) orelse try alloc.dupe(u8, "never");
        defer alloc.free(last_scan);
        try buf.appendSlice(alloc, ",\"last_scan_at\":");
        try shared.appendJsonStr(&buf, last_scan, alloc);
        try std.fmt.format(buf.writer(alloc), ",\"repo_scan_in_progress\":{s},\"repo_scan_last_started_at\":{d},\"repo_scan_last_finished_at\":{d}", .{
            if (repo_scan_in_progress) "true" else "false",
            repo_scan_last_started_at,
            repo_scan_last_finished_at,
        });
        try buf.appendSlice(alloc, ",\"active_workbook\":");
        try appendActiveWorkbookJson(&buf, active_summary, alloc);
        try buf.append(alloc, '}');
        return alloc.dupe(u8, buf.items);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "{{\"configured\":false,\"workspace_ready\":false,\"connection_configured\":false,\"last_sync_at\":0,\"has_error\":false,\"error\":\"\",\"license\":", .{});
    try appendLicenseStatusJson(&buf, license_status, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"sync_count\":0,\"license_valid\":{s},\"platform\":null,\"credential_display\":null,\"workbook_label\":null,\"workbook_url\":null,\"source_of_truth\":null,\"hobbled_mode\":{s},\"license_required_features\":[\"MCP\",\"Reports\",\"Repository Scanning\",\"Code Traceability\",\"Background Sync\"],\"attach_workbook_prompt_dismissed\":false,\"connection_block_reason\":null,\"secure_storage_backend\":", .{
        if (license_valid) "true" else "false",
        if (!license_valid) "true" else "false",
    });
    try shared.appendJsonStr(&buf, secure_store_mod.backendName(secure_store.backend), alloc);
    try buf.appendSlice(alloc, ",\"profile\":null,\"last_scan_at\":\"never\",\"repo_scan_in_progress\":false,\"repo_scan_last_started_at\":0,\"repo_scan_last_finished_at\":0,\"active_workbook\":null}");
    return alloc.dupe(u8, buf.items);
}

pub fn handleInfo(registry: *workbook.registry.WorkbookRegistry, auth: *test_results_auth.AuthState, license_service: *license.Service, instance_info: anytype, alloc: Allocator) ![]const u8 {
    const test_results_endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/api/v1/test-results", .{instance_info.actual_port});
    defer alloc.free(test_results_endpoint);
    const bom_endpoint = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/api/v1/bom", .{instance_info.actual_port});
    defer alloc.free(bom_endpoint);
    const license_path = try license.resolveLicensePath(alloc, license_service.deps.license_path_override);
    defer alloc.free(license_path);
    const license_key_fingerprint = try license.defaultKeyFingerprintHex(alloc);
    defer alloc.free(license_key_fingerprint);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"tray_app_version\":");
    try shared.appendJsonStr(&buf, instance_info.tray_app_version, alloc);
    try buf.appendSlice(alloc, ",\"live_version\":");
    try shared.appendJsonStr(&buf, instance_info.live_version, alloc);
    try buf.appendSlice(alloc, ",\"db_path\":");
    try shared.appendJsonStrOpt(&buf, if (registry.active_runtime) |runtime| runtime.config.db_path else null, alloc);
    try buf.appendSlice(alloc, ",\"log_path\":");
    try shared.appendJsonStr(&buf, instance_info.log_path, alloc);
    try buf.appendSlice(alloc, ",\"test_results_endpoint\":");
    try shared.appendJsonStr(&buf, test_results_endpoint, alloc);
    try buf.appendSlice(alloc, ",\"bom_endpoint\":");
    try shared.appendJsonStr(&buf, bom_endpoint, alloc);
    try buf.appendSlice(alloc, ",\"test_results_token\":");
    if (registry.active_runtime != null) {
        const token = try auth.currentToken(alloc);
        defer alloc.free(token);
        try shared.appendJsonStr(&buf, token, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"inbox_dir\":");
    try shared.appendJsonStrOpt(&buf, if (registry.active_runtime) |runtime| runtime.config.inbox_dir else null, alloc);
    try buf.appendSlice(alloc, ",\"test_results_inbox_dir\":");
    try shared.appendJsonStrOpt(&buf, if (registry.active_runtime) |runtime| runtime.config.inbox_dir else null, alloc);
    try buf.appendSlice(alloc, ",\"test_results_auth_mode\":");
    try shared.appendJsonStr(&buf, "bearer_token", alloc);
    try buf.appendSlice(alloc, ",\"license_path\":");
    try shared.appendJsonStr(&buf, license_path, alloc);
    try buf.appendSlice(alloc, ",\"license_key_fingerprint\":");
    try shared.appendJsonStr(&buf, license_key_fingerprint, alloc);
    try buf.appendSlice(alloc, ",\"active_workbook\":");
    if (registry.live_config.active_workbook_id) |active_id| {
        var summary = try registry.summaryForWorkbookId(active_id, alloc);
        defer summary.deinit(alloc);
        try appendActiveWorkbookJson(&buf, summary, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn handlePostWorkspacePrefsResponse(
    db: *graph_live.GraphDb,
    body: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_json\"}"), false);
    }
    if (root.object.get("attach_workbook_prompt_dismissed")) |value| {
        if (value != .bool) {
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_attach_workbook_prompt_dismissed\"}"), false);
        }
        try workspace_state.writeAttachWorkbookPromptDismissed(db, value.bool);
    }
    if (root.object.get("workspace_ready")) |value| {
        if (value != .bool) {
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_workspace_ready\"}"), false);
        }
        try workspace_state.writeWorkspaceReady(db, value.bool);
    }
    if (root.object.get("workspace_source_of_truth")) |value| {
        if (value == .null) {
            try workspace_state.deleteSourceOfTruth(db);
        } else if (value == .string) {
            const source = if (std.mem.eql(u8, value.string, workspace_state.SourceOfTruth.document_first.asString()))
                workspace_state.SourceOfTruth.document_first
            else if (std.mem.eql(u8, value.string, workspace_state.SourceOfTruth.workbook_first.asString()))
                workspace_state.SourceOfTruth.workbook_first
            else
                return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_workspace_source_of_truth\"}"), false);
            try workspace_state.writeSourceOfTruth(db, source);
        } else {
            return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid_workspace_source_of_truth\"}"), false);
        }
    }
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

fn appendActiveWorkbookJson(buf: *std.ArrayList(u8), summary: workbook.registry.WorkbookSummary, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"id\":");
    try shared.appendJsonStr(buf, summary.id, alloc);
    try buf.appendSlice(alloc, ",\"display_name\":");
    try shared.appendJsonStr(buf, summary.display_name, alloc);
    try buf.appendSlice(alloc, ",\"profile\":");
    try shared.appendJsonStr(buf, summary.profile, alloc);
    try buf.appendSlice(alloc, ",\"provider\":");
    try shared.appendJsonStrOpt(buf, summary.provider, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"last_sync_at\":{d},\"sync_in_progress\":{s},\"inbox_dir\":", .{
        summary.last_sync_at,
        if (summary.sync_in_progress) "true" else "false",
    });
    try shared.appendJsonStr(buf, summary.inbox_dir, alloc);
    try buf.append(alloc, '}');
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
    try buf.appendSlice(alloc, ",\"using_free_run\":");
    try buf.appendSlice(alloc, if (status.using_free_run) "true" else "false");
    try buf.appendSlice(alloc, ",\"license_path\":");
    try shared.appendJsonStr(buf, status.license_path, alloc);
    try buf.appendSlice(alloc, ",\"expected_key_fingerprint\":");
    try shared.appendJsonStr(buf, status.expected_key_fingerprint, alloc);
    try buf.appendSlice(alloc, ",\"license_signing_key_fingerprint\":");
    try shared.appendJsonStrOpt(buf, status.license_signing_key_fingerprint, alloc);
    try buf.appendSlice(alloc, ",\"issued_to\":");
    try shared.appendJsonStrOpt(buf, status.issued_to, alloc);
    try buf.appendSlice(alloc, ",\"org\":");
    try shared.appendJsonStrOpt(buf, status.org, alloc);
    try buf.appendSlice(alloc, ",\"license_id\":");
    try shared.appendJsonStrOpt(buf, status.license_id, alloc);
    try buf.appendSlice(alloc, ",\"product\":");
    try shared.appendJsonStrOpt(buf, if (status.product) |value| @tagName(value) else null, alloc);
    try buf.appendSlice(alloc, ",\"tier\":");
    try shared.appendJsonStrOpt(buf, if (status.tier) |value| @tagName(value) else null, alloc);
    try buf.appendSlice(alloc, ",\"issued_at\":");
    try shared.appendJsonIntOpt(buf, status.issued_at, alloc);
    try buf.appendSlice(alloc, ",\"expires_at\":");
    try shared.appendJsonIntOpt(buf, status.expires_at, alloc);
    try buf.appendSlice(alloc, ",\"detail_code\":");
    try shared.appendJsonStr(buf, @tagName(status.detail_code), alloc);
    try buf.appendSlice(alloc, ",\"message\":");
    try shared.appendJsonStrOpt(buf, status.message, alloc);
    try buf.append(alloc, '}');
}

fn installSampleLiveLicense(service: *license.Service, alloc: Allocator) !void {
    const key = try license.defaultHmacKeyBytes(alloc);
    defer alloc.free(key);
    var payload = license.LicensePayload{
        .schema = 1,
        .license_id = try alloc.dupe(u8, "LIVE-2026-0001"),
        .product = .live,
        .tier = .individual,
        .issued_to = try alloc.dupe(u8, "jane@example.com"),
        .issued_at = 123,
        .expires_at = null,
        .org = try alloc.dupe(u8, "Acme"),
    };
    defer payload.deinit(alloc);
    const sig = try license.license_file.signPayloadHex(alloc, payload, key);
    defer alloc.free(sig);
    var envelope = license.LicenseEnvelope{
        .payload = try payload.clone(alloc),
        .sig = try alloc.dupe(u8, sig),
    };
    defer envelope.deinit(alloc);
    const envelope_json = try license.license_file.envelopeJsonAlloc(alloc, envelope);
    defer alloc.free(envelope_json);
    var status = try service.installFromBytes(alloc, envelope_json);
    defer status.deinit(alloc);
}

const testing = std.testing;

fn makeTestRegistry(alloc: Allocator, store: *secure_store_mod.Store, profile: []const u8, db_path: []const u8, inbox_dir: []const u8) !workbook.registry.WorkbookRegistry {
    var cfg = try workbook.config.bootstrapConfig(alloc, .{ .profile = profile });
    errdefer cfg.deinit(alloc);
    alloc.free(cfg.workbooks[0].db_path);
    cfg.workbooks[0].db_path = try alloc.dupe(u8, db_path);
    alloc.free(cfg.workbooks[0].inbox_dir);
    cfg.workbooks[0].inbox_dir = try alloc.dupe(u8, inbox_dir);
    return workbook.registry.WorkbookRegistry.initForConfig(alloc, cfg, store);
}

test "gitless mode status is configured and repos list is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_root);
    const inbox_dir = try std.fs.path.join(alloc, &.{ tmp_root, "inbox" });
    defer alloc.free(inbox_dir);
    var registry = try makeTestRegistry(alloc, &store, "generic", ":memory:", inbox_dir);
    defer registry.deinit(alloc);
    const runtime = try registry.active();

    var state: sync_live.SyncState = .{};

    const cfg = try registry.activeConfig();
    cfg.platform = .google;
    cfg.google_sheet_id = try alloc.dupe(u8, "sheet-123");
    cfg.workbook_url = try alloc.dupe(u8, "https://docs.google.com/spreadsheets/d/sheet-123/edit");
    cfg.workbook_label = try alloc.dupe(u8, "sheet-123");
    cfg.credential_display = try alloc.dupe(u8, "svc@example.com");
    cfg.credential_ref = try alloc.dupe(u8, "cred_status");
    runtime.config.deinit(alloc);
    runtime.config = try cfg.clone(alloc);
    try store.put(alloc, "cred_status", "{\"platform\":\"google\",\"client_email\":\"svc@example.com\",\"private_key\":\"key\"}");

    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const license_path = try std.fs.path.join(alloc, &.{ root, "license.json" });
    defer alloc.free(license_path);
    var license_service = try license.initDefaultHmacFile(alloc, .{
        .product = .live,
        .trial_policy = .requires_license,
        .license_path_override = license_path,
    });
    defer license_service.deinit(alloc);
    try installSampleLiveLicense(&license_service, alloc);

    const status = try handleStatus(&registry, &store, &state, &license_service, alloc);
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

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_root);
    const inbox_dir = try std.fs.path.join(alloc, &.{ tmp_root, "inbox" });
    defer alloc.free(inbox_dir);
    var registry = try makeTestRegistry(alloc, &store, "generic", ":memory:", inbox_dir);
    defer registry.deinit(alloc);

    var state: sync_live.SyncState = .{};
    state.repo_scan_in_progress.store(true, .seq_cst);
    state.repo_scan_last_started_at.store(123, .seq_cst);
    state.repo_scan_last_finished_at.store(456, .seq_cst);

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);
    const status = try handleStatus(&registry, &store, &state, &license_service, alloc);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_in_progress\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_last_started_at\":123") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"repo_scan_last_finished_at\":456") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"license_valid\":false") != null);
}

test "handleStatus reports missing secure secret as blocked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_root);
    const inbox_dir = try std.fs.path.join(alloc, &.{ tmp_root, "inbox" });
    defer alloc.free(inbox_dir);
    var registry = try makeTestRegistry(alloc, &store, "generic", ":memory:", inbox_dir);
    defer registry.deinit(alloc);
    var state: sync_live.SyncState = .{};

    const cfg = try registry.activeConfig();
    cfg.platform = .google;
    cfg.google_sheet_id = try alloc.dupe(u8, "legacy-sheet");
    cfg.workbook_url = try alloc.dupe(u8, "https://docs.google.com/spreadsheets/d/legacy-sheet/edit");
    cfg.workbook_label = try alloc.dupe(u8, "legacy-sheet");
    cfg.credential_display = try alloc.dupe(u8, "svc@example.com");
    cfg.credential_ref = try alloc.dupe(u8, "cred_missing");
    const runtime = try registry.active();
    runtime.config.deinit(alloc);
    runtime.config = try cfg.clone(alloc);

    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);

    const status = try handleStatus(&registry, &store, &state, &license_service, alloc);
    try testing.expect(std.mem.indexOf(u8, status, "\"configured\":false") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"connection_block_reason\":\"secret_not_found\"") != null);
}

test "handleStatus treats non-empty local db as workbook-first workspace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_root);
    const inbox_dir = try std.fs.path.join(alloc, &.{ tmp_root, "inbox" });
    defer alloc.free(inbox_dir);
    var registry = try makeTestRegistry(alloc, &store, "generic", ":memory:", inbox_dir);
    defer registry.deinit(alloc);
    var state: sync_live.SyncState = .{};
    var license_service = try license.initDefaultStub(alloc, .{});
    defer license_service.deinit(alloc);

    const runtime = try registry.active();
    try runtime.db.addNode("product://VS-200-REV-C", "Product", "{\"full_identifier\":\"VS-200-REV-C\"}", null);

    const status = try handleStatus(&registry, &store, &state, &license_service, alloc);
    try testing.expect(std.mem.indexOf(u8, status, "\"configured\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"workspace_ready\":true") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"connection_configured\":false") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"source_of_truth\":\"workbook_first\"") != null);
    try testing.expect(std.mem.indexOf(u8, status, "\"platform\":null") != null);
}

test "handleInfo returns version and path details" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const db_path = try std.fs.path.join(alloc, &.{ root, "graph.db" });
    defer alloc.free(db_path);
    const inbox_dir = try std.fs.path.join(alloc, &.{ root, "inbox" });
    defer alloc.free(inbox_dir);
    const token_path = try std.fs.path.join(alloc, &.{ root, "rtmify-test-results-status-token" });
    defer alloc.free(token_path);
    const log_path = try std.fs.path.join(alloc, &.{ root, "server.log" });
    defer alloc.free(log_path);
    var registry = try makeTestRegistry(alloc, &store, "generic", db_path, inbox_dir);
    defer registry.deinit(alloc);
    const license_path = try std.fs.path.join(alloc, &.{ root, "license.json" });
    defer alloc.free(license_path);
    var license_service = try license.initDefaultHmacFile(alloc, .{
        .product = .live,
        .trial_policy = .requires_license,
        .license_path_override = license_path,
    });
    defer license_service.deinit(alloc);
    var auth = try test_results_auth.AuthState.initForPath(token_path, alloc);
    defer auth.deinit(alloc);

    const resp = try handleInfo(&registry, &auth, &license_service, .{
        .actual_port = @as(u16, 8123),
        .tray_app_version = "0.1 (1)",
        .live_version = "20260308-a",
        .log_path = log_path,
    }, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("0.1 (1)", obj.get("tray_app_version").?.string);
    try testing.expectEqualStrings("20260308-a", obj.get("live_version").?.string);
    try testing.expectEqualStrings(db_path, obj.get("db_path").?.string);
    try testing.expectEqualStrings(log_path, obj.get("log_path").?.string);
    try testing.expectEqualStrings("http://127.0.0.1:8123/api/v1/test-results", obj.get("test_results_endpoint").?.string);
    try testing.expectEqualStrings("http://127.0.0.1:8123/api/v1/bom", obj.get("bom_endpoint").?.string);
    try testing.expectEqualStrings(inbox_dir, obj.get("inbox_dir").?.string);
    try testing.expectEqualStrings(inbox_dir, obj.get("test_results_inbox_dir").?.string);
    try testing.expectEqualStrings("bearer_token", obj.get("test_results_auth_mode").?.string);
    try testing.expectEqualStrings(license_path, obj.get("license_path").?.string);
}

test "handleInfo falls back to legacy inbox config key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const root = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const db_path = try std.fs.path.join(alloc, &.{ root, "graph.db" });
    defer alloc.free(db_path);
    const inbox_dir = try std.fs.path.join(alloc, &.{ root, "legacy-inbox" });
    defer alloc.free(inbox_dir);
    const token_path = try std.fs.path.join(alloc, &.{ root, "rtmify-test-results-status-token-legacy" });
    defer alloc.free(token_path);
    const log_path = try std.fs.path.join(alloc, &.{ root, "server.log" });
    defer alloc.free(log_path);
    var registry = try makeTestRegistry(alloc, &store, "generic", db_path, inbox_dir);
    defer registry.deinit(alloc);
    const license_path = try std.fs.path.join(alloc, &.{ root, "license.json" });
    defer alloc.free(license_path);
    var license_service = try license.initDefaultHmacFile(alloc, .{
        .product = .live,
        .trial_policy = .requires_license,
        .license_path_override = license_path,
    });
    defer license_service.deinit(alloc);
    var auth = try test_results_auth.AuthState.initForPath(token_path, alloc);
    defer auth.deinit(alloc);

    const resp = try handleInfo(&registry, &auth, &license_service, .{
        .actual_port = @as(u16, 8123),
        .tray_app_version = "0.1 (1)",
        .live_version = "20260308-a",
        .log_path = log_path,
    }, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings(inbox_dir, obj.get("inbox_dir").?.string);
    try testing.expectEqualStrings(inbox_dir, obj.get("test_results_inbox_dir").?.string);
}
