const std = @import("std");
const Allocator = std.mem.Allocator;

const provider_common = @import("../../provider_common.zig");
const workbook_paths = @import("../paths.zig");
const types = @import("types.zig");
const select = @import("select.zig");
const testing = std.testing;

pub fn setActiveProfile(cfg: *types.LiveConfig, profile: []const u8, alloc: Allocator) !void {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    alloc.free(workbook.profile);
    workbook.profile = try alloc.dupe(u8, profile);
}

pub fn addActiveRepoPath(cfg: *types.LiveConfig, path: []const u8, alloc: Allocator) !void {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    const new_paths = try alloc.alloc([]const u8, workbook.repo_paths.len + 1);
    errdefer alloc.free(new_paths);
    for (workbook.repo_paths, 0..) |repo_path, idx| {
        new_paths[idx] = try alloc.dupe(u8, repo_path);
    }
    new_paths[workbook.repo_paths.len] = try alloc.dupe(u8, path);
    for (workbook.repo_paths) |repo_path| alloc.free(repo_path);
    alloc.free(workbook.repo_paths);
    workbook.repo_paths = new_paths;
}

pub fn deleteActiveRepoAt(cfg: *types.LiveConfig, idx: usize, alloc: Allocator) !bool {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (idx >= workbook.repo_paths.len) return false;

    alloc.free(workbook.repo_paths[idx]);
    const new_paths = try alloc.alloc([]const u8, workbook.repo_paths.len - 1);
    errdefer alloc.free(new_paths);
    var out_idx: usize = 0;
    for (workbook.repo_paths, 0..) |repo_path, in_idx| {
        if (in_idx == idx) continue;
        new_paths[out_idx] = repo_path;
        out_idx += 1;
    }
    alloc.free(workbook.repo_paths);
    workbook.repo_paths = new_paths;
    return true;
}

pub fn replaceActiveConnection(
    cfg: *types.LiveConfig,
    validated: provider_common.ValidatedDraft,
    credential_ref: []const u8,
    alloc: Allocator,
) !void {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;

    workbook.platform = validated.platform;
    try replaceOptionalString(&workbook.workbook_url, validated.workbook_url, alloc);
    try replaceOptionalString(&workbook.workbook_label, validated.workbook_label, alloc);
    try replaceOptionalString(&workbook.credential_ref, credential_ref, alloc);
    try replaceOptionalStringOpt(&workbook.credential_display, validated.credential_display, alloc);

    if (workbook.display_name.len == 0 or std.mem.eql(u8, workbook.display_name, "Workbook")) {
        alloc.free(workbook.display_name);
        workbook.display_name = try alloc.dupe(u8, validated.workbook_label);
    }

    if (validated.profile) |profile| {
        alloc.free(workbook.profile);
        workbook.profile = try alloc.dupe(u8, profile);
    }

    switch (validated.target) {
        .google => |google| {
            try replaceOptionalString(&workbook.google_sheet_id, google.sheet_id, alloc);
            clearOptionalString(&workbook.excel_drive_id, alloc);
            clearOptionalString(&workbook.excel_item_id, alloc);
        },
        .excel => |excel| {
            try replaceOptionalString(&workbook.excel_drive_id, excel.drive_id, alloc);
            try replaceOptionalString(&workbook.excel_item_id, excel.item_id, alloc);
            clearOptionalString(&workbook.google_sheet_id, alloc);
        },
    }
}

pub fn activateWorkbookId(cfg: *types.LiveConfig, id: []const u8, alloc: Allocator) !void {
    const workbook = select.findById(cfg, id) orelse return error.WorkbookNotFound;
    if (workbook.removed_at != null) return error.WorkbookRemoved;
    if (cfg.active_workbook_id) |existing| alloc.free(existing);
    cfg.active_workbook_id = try alloc.dupe(u8, id);
}

pub fn replaceActiveDesignBomSync(cfg: *types.LiveConfig, sync_cfg: types.DesignBomSyncConfig, alloc: Allocator) !void {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.design_bom_sync) |*existing| existing.deinit(alloc);
    workbook.design_bom_sync = try sync_cfg.clone(alloc);
}

pub fn clearActiveDesignBomSync(cfg: *types.LiveConfig, alloc: Allocator) !void {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.design_bom_sync) |*existing| existing.deinit(alloc);
    workbook.design_bom_sync = null;
}

pub fn replaceActiveSoupSync(cfg: *types.LiveConfig, sync_cfg: types.SoupSyncConfig, alloc: Allocator) !void {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.soup_sync) |*existing| existing.deinit(alloc);
    workbook.soup_sync = try sync_cfg.clone(alloc);
}

pub fn clearActiveSoupSync(cfg: *types.LiveConfig, alloc: Allocator) !void {
    const workbook = select.activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.soup_sync) |*existing| existing.deinit(alloc);
    workbook.soup_sync = null;
}

pub fn renameWorkbook(cfg: *types.LiveConfig, id: []const u8, display_name: []const u8, alloc: Allocator) !void {
    try ensureDisplayNameAvailable(cfg, display_name, id);
    const workbook = select.findById(cfg, id) orelse return error.WorkbookNotFound;
    alloc.free(workbook.display_name);
    workbook.display_name = try alloc.dupe(u8, display_name);
}

pub fn removeWorkbook(cfg: *types.LiveConfig, id: []const u8, alloc: Allocator) !void {
    const workbook = select.findById(cfg, id) orelse return error.WorkbookNotFound;
    if (workbook.removed_at != null) return error.WorkbookRemoved;
    workbook.removed_at = std.time.timestamp();

    if (cfg.active_workbook_id) |active_id| {
        if (std.mem.eql(u8, active_id, id)) {
            const next_id = select.firstVisibleWorkbookId(cfg);
            alloc.free(active_id);
            cfg.active_workbook_id = if (next_id) |value| try alloc.dupe(u8, value) else null;
        }
    }
}

pub fn purgeWorkbookAt(cfg: *types.LiveConfig, idx: usize, alloc: Allocator) !void {
    if (idx >= cfg.workbooks.len) return error.WorkbookNotFound;
    var target = cfg.workbooks[idx];
    target.deinit(alloc);

    const new_items = try alloc.alloc(types.WorkbookConfig, cfg.workbooks.len - 1);
    errdefer alloc.free(new_items);

    var out_idx: usize = 0;
    for (cfg.workbooks, 0..) |workbook, in_idx| {
        if (in_idx == idx) continue;
        new_items[out_idx] = workbook;
        out_idx += 1;
    }
    alloc.free(cfg.workbooks);
    cfg.workbooks = new_items;

    const visible_id = select.firstVisibleWorkbookId(cfg);
    if (cfg.active_workbook_id) |active_id| {
        if (select.findByIdConst(cfg, active_id) == null) {
            alloc.free(active_id);
            cfg.active_workbook_id = if (visible_id) |value| try alloc.dupe(u8, value) else null;
        }
    } else if (visible_id) |value| {
        cfg.active_workbook_id = try alloc.dupe(u8, value);
    }
}

pub fn createWorkbookEntry(
    cfg: *const types.LiveConfig,
    display_name: []const u8,
    validated: provider_common.ValidatedDraft,
    credential_ref: []const u8,
    repo_paths: []const []const u8,
    alloc: Allocator,
) !types.WorkbookConfig {
    try ensureDisplayNameAvailable(cfg, display_name, null);

    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const id = try std.fmt.allocPrint(alloc, "wb_{s}", .{std.fmt.bytesToHex(bytes, .lower)});
    errdefer alloc.free(id);
    const slug = try uniqueSlug(cfg, display_name, alloc);
    errdefer alloc.free(slug);
    const db_path = try workbook_paths.graphDbPath(slug, alloc);
    errdefer alloc.free(db_path);
    const inbox_dir = try workbook_paths.inboxDir(slug, alloc);
    errdefer alloc.free(inbox_dir);

    const profile = validated.profile orelse "generic";
    const cloned_repos = try types.cloneStringSlice(repo_paths, alloc);
    errdefer {
        for (cloned_repos) |path| alloc.free(path);
        alloc.free(cloned_repos);
    }

    var entry = types.WorkbookConfig{
        .id = id,
        .slug = slug,
        .display_name = try alloc.dupe(u8, display_name),
        .profile = try alloc.dupe(u8, profile),
        .repo_paths = cloned_repos,
        .db_path = db_path,
        .inbox_dir = inbox_dir,
        .platform = validated.platform,
        .workbook_url = try alloc.dupe(u8, validated.workbook_url),
        .workbook_label = try alloc.dupe(u8, validated.workbook_label),
        .credential_ref = try alloc.dupe(u8, credential_ref),
        .credential_display = if (validated.credential_display) |value| try alloc.dupe(u8, value) else null,
    };
    errdefer entry.deinit(alloc);

    switch (validated.target) {
        .google => |google| {
            entry.google_sheet_id = try alloc.dupe(u8, google.sheet_id);
        },
        .excel => |excel| {
            entry.excel_drive_id = try alloc.dupe(u8, excel.drive_id);
            entry.excel_item_id = try alloc.dupe(u8, excel.item_id);
        },
    }

    return entry;
}

pub fn appendWorkbook(cfg: *types.LiveConfig, entry: types.WorkbookConfig, make_active: bool, alloc: Allocator) !void {
    const new_items = try alloc.alloc(types.WorkbookConfig, cfg.workbooks.len + 1);
    errdefer alloc.free(new_items);
    for (cfg.workbooks, 0..) |workbook, idx| {
        new_items[idx] = workbook;
    }
    new_items[cfg.workbooks.len] = entry;
    alloc.free(cfg.workbooks);
    cfg.workbooks = new_items;

    if (make_active or cfg.active_workbook_id == null) {
        if (cfg.active_workbook_id) |existing| alloc.free(existing);
        cfg.active_workbook_id = try alloc.dupe(u8, entry.id);
    }
}

fn ensureDisplayNameAvailable(cfg: *const types.LiveConfig, display_name: []const u8, ignore_id: ?[]const u8) !void {
    for (cfg.workbooks) |workbook| {
        if (ignore_id) |id| {
            if (std.mem.eql(u8, workbook.id, id)) continue;
        }
        if (std.mem.eql(u8, workbook.display_name, display_name)) return error.DuplicateDisplayName;
    }
}

fn uniqueSlug(cfg: *const types.LiveConfig, display_name: []const u8, alloc: Allocator) ![]u8 {
    const base = try workbook_paths.slugify(display_name, alloc);
    errdefer alloc.free(base);

    if (!slugExists(cfg, base)) return base;

    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, suffix });
        if (!slugExists(cfg, candidate)) {
            alloc.free(base);
            return candidate;
        }
        alloc.free(candidate);
    }
}

fn slugExists(cfg: *const types.LiveConfig, slug: []const u8) bool {
    for (cfg.workbooks) |workbook| {
        if (std.mem.eql(u8, workbook.slug, slug)) return true;
    }
    return false;
}

fn replaceOptionalString(dst: *?[]const u8, src: []const u8, alloc: Allocator) !void {
    clearOptionalString(dst, alloc);
    dst.* = try alloc.dupe(u8, src);
}

fn replaceOptionalStringOpt(dst: *?[]const u8, src: ?[]const u8, alloc: Allocator) !void {
    clearOptionalString(dst, alloc);
    if (src) |value| dst.* = try alloc.dupe(u8, value);
}

fn clearOptionalString(dst: *?[]const u8, alloc: Allocator) void {
    if (dst.*) |value| alloc.free(value);
    dst.* = null;
}

fn makeGoogleDraft(alloc: Allocator) !provider_common.ValidatedDraft {
    return .{
        .platform = .google,
        .profile = try alloc.dupe(u8, "medical"),
        .credential_json = try alloc.dupe(u8, "{\"platform\":\"google\"}"),
        .workbook_url = try alloc.dupe(u8, "https://docs.google.com/spreadsheets/d/abc/edit"),
        .workbook_label = try alloc.dupe(u8, "abc"),
        .credential_display = try alloc.dupe(u8, "svc@example.com"),
        .target = .{ .google = .{ .sheet_id = try alloc.dupe(u8, "abc") } },
    };
}

fn makeExcelDraft(alloc: Allocator) !provider_common.ValidatedDraft {
    return .{
        .platform = .excel,
        .profile = try alloc.dupe(u8, "medical"),
        .credential_json = try alloc.dupe(u8, "{\"platform\":\"excel\"}"),
        .workbook_url = try alloc.dupe(u8, "https://onedrive.live.com/edit"),
        .workbook_label = try alloc.dupe(u8, "excel-book"),
        .credential_display = try alloc.dupe(u8, "excel@example.com"),
        .target = .{ .excel = .{
            .drive_id = try alloc.dupe(u8, "drive"),
            .item_id = try alloc.dupe(u8, "item"),
        } },
    };
}

test "replaceActiveConnection clears Google fields when switching to Excel and vice versa" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);

    var google = try makeGoogleDraft(testing.allocator);
    defer google.deinit(testing.allocator);
    try replaceActiveConnection(&cfg, google, "cred-g", testing.allocator);
    try testing.expectEqualStrings("abc", cfg.workbooks[0].google_sheet_id.?);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].excel_drive_id);

    var excel = try makeExcelDraft(testing.allocator);
    defer excel.deinit(testing.allocator);
    try replaceActiveConnection(&cfg, excel, "cred-e", testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].google_sheet_id);
    try testing.expectEqualStrings("drive", cfg.workbooks[0].excel_drive_id.?);
    try testing.expectEqualStrings("item", cfg.workbooks[0].excel_item_id.?);
}

test "replaceActiveConnection upgrades default display name to validated label" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    var google = try makeGoogleDraft(testing.allocator);
    defer google.deinit(testing.allocator);
    try replaceActiveConnection(&cfg, google, "cred-g", testing.allocator);
    try testing.expectEqualStrings("abc", cfg.workbooks[0].display_name);
}

test "deleteActiveRepoAt returns false on out-of-range index" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{ .repo_paths = &.{"/tmp/repo"} });
    defer cfg.deinit(testing.allocator);
    try testing.expect(!(try deleteActiveRepoAt(&cfg, 9, testing.allocator)));
}

test "removeWorkbook rotates active workbook to next visible workbook" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    var google = try makeGoogleDraft(testing.allocator);
    defer google.deinit(testing.allocator);
    var entry = try createWorkbookEntry(&cfg, "Workbook 2", google, "cred_2", &.{}, testing.allocator);
    defer entry.deinit(testing.allocator);
    try appendWorkbook(&cfg, try entry.clone(testing.allocator), true, testing.allocator);
    try removeWorkbook(&cfg, entry.id, testing.allocator);
    try testing.expectEqualStrings(cfg.workbooks[0].id, cfg.active_workbook_id.?);
}

test "purgeWorkbookAt repairs active_workbook_id when active workbook is purged" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    var google = try makeGoogleDraft(testing.allocator);
    defer google.deinit(testing.allocator);
    var entry = try createWorkbookEntry(&cfg, "Workbook 2", google, "cred_2", &.{}, testing.allocator);
    defer entry.deinit(testing.allocator);
    try appendWorkbook(&cfg, try entry.clone(testing.allocator), true, testing.allocator);
    try purgeWorkbookAt(&cfg, 1, testing.allocator);
    try testing.expectEqualStrings(cfg.workbooks[0].id, cfg.active_workbook_id.?);
}

test "appendWorkbook makes entry active when requested and when active workbook is null" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    var google = try makeGoogleDraft(testing.allocator);
    defer google.deinit(testing.allocator);

    var entry = try createWorkbookEntry(&cfg, "Workbook 2", google, "cred_2", &.{}, testing.allocator);
    defer entry.deinit(testing.allocator);
    try appendWorkbook(&cfg, try entry.clone(testing.allocator), true, testing.allocator);
    try testing.expectEqualStrings(entry.id, cfg.active_workbook_id.?);

    testing.allocator.free(cfg.active_workbook_id.?);
    cfg.active_workbook_id = null;
    var second = try createWorkbookEntry(&cfg, "Workbook 3", google, "cred_3", &.{}, testing.allocator);
    defer second.deinit(testing.allocator);
    try appendWorkbook(&cfg, try second.clone(testing.allocator), false, testing.allocator);
    try testing.expectEqualStrings(second.id, cfg.active_workbook_id.?);
}

test "renameWorkbook rejects duplicate display names while allowing same-id rename" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    var google = try makeGoogleDraft(testing.allocator);
    defer google.deinit(testing.allocator);
    var entry = try createWorkbookEntry(&cfg, "Workbook 2", google, "cred_2", &.{}, testing.allocator);
    defer entry.deinit(testing.allocator);
    try appendWorkbook(&cfg, try entry.clone(testing.allocator), false, testing.allocator);
    try renameWorkbook(&cfg, entry.id, "Workbook 2", testing.allocator);
    try testing.expectError(error.DuplicateDisplayName, renameWorkbook(&cfg, entry.id, "Workbook", testing.allocator));
}

test "replaceActive sync configs replace prior configs without leaks" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    var first_design = types.DesignBomSyncConfig{
        .kind = .local_xlsx,
        .display_name = try testing.allocator.dupe(u8, "First"),
        .local_xlsx_path = try testing.allocator.dupe(u8, "/tmp/first.xlsx"),
    };
    defer first_design.deinit(testing.allocator);
    try replaceActiveDesignBomSync(&cfg, first_design, testing.allocator);

    var second_design = types.DesignBomSyncConfig{
        .kind = .local_xlsx,
        .display_name = try testing.allocator.dupe(u8, "Second"),
        .local_xlsx_path = try testing.allocator.dupe(u8, "/tmp/second.xlsx"),
    };
    defer second_design.deinit(testing.allocator);
    try replaceActiveDesignBomSync(&cfg, second_design, testing.allocator);
    try testing.expectEqualStrings("Second", cfg.workbooks[0].design_bom_sync.?.display_name);

    var first_soup = types.SoupSyncConfig{
        .kind = .local_xlsx,
        .display_name = try testing.allocator.dupe(u8, "Soup 1"),
        .full_product_identifier = try testing.allocator.dupe(u8, "product://one"),
    };
    defer first_soup.deinit(testing.allocator);
    try replaceActiveSoupSync(&cfg, first_soup, testing.allocator);

    var second_soup = types.SoupSyncConfig{
        .kind = .local_xlsx,
        .display_name = try testing.allocator.dupe(u8, "Soup 2"),
        .full_product_identifier = try testing.allocator.dupe(u8, "product://two"),
    };
    defer second_soup.deinit(testing.allocator);
    try replaceActiveSoupSync(&cfg, second_soup, testing.allocator);
    try testing.expectEqualStrings("Soup 2", cfg.workbooks[0].soup_sync.?.display_name);
}

test "createWorkbookEntry enforces unique display names and unique slugs" {
    var cfg = try @import("bootstrap.zig").bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);

    var validated = try makeGoogleDraft(testing.allocator);
    defer validated.deinit(testing.allocator);

    var entry = try createWorkbookEntry(&cfg, "Workbook 2", validated, "cred_2", &.{}, testing.allocator);
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("workbook-2", entry.slug);

    try appendWorkbook(&cfg, try entry.clone(testing.allocator), false, testing.allocator);

    var second = try createWorkbookEntry(&cfg, "Workbook-2", validated, "cred_3", &.{}, testing.allocator);
    defer second.deinit(testing.allocator);
    try testing.expect(std.mem.startsWith(u8, second.slug, "workbook-2-"));
    try testing.expectError(error.DuplicateDisplayName, createWorkbookEntry(&cfg, "Workbook 2", validated, "cred_4", &.{}, testing.allocator));
}
