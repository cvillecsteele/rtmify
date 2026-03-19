const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("../json_util.zig");
const provider_common = @import("../provider_common.zig");
const workbook_paths = @import("paths.zig");

pub const DesignBomSyncKind = enum { google, excel, local_xlsx };
pub const SoupSyncKind = enum { google, excel, local_xlsx };

pub const DesignBomSyncConfig = struct {
    kind: DesignBomSyncKind,
    enabled: bool = true,
    display_name: []const u8,
    workbook_url: ?[]const u8 = null,
    workbook_label: ?[]const u8 = null,
    credential_ref: ?[]const u8 = null,
    credential_display: ?[]const u8 = null,
    google_sheet_id: ?[]const u8 = null,
    excel_drive_id: ?[]const u8 = null,
    excel_item_id: ?[]const u8 = null,
    local_xlsx_path: ?[]const u8 = null,
    last_sync_at: i64 = 0,
    last_error: ?[]const u8 = null,

    pub fn deinit(self: *DesignBomSyncConfig, alloc: Allocator) void {
        alloc.free(self.display_name);
        if (self.workbook_url) |v| alloc.free(v);
        if (self.workbook_label) |v| alloc.free(v);
        if (self.credential_ref) |v| alloc.free(v);
        if (self.credential_display) |v| alloc.free(v);
        if (self.google_sheet_id) |v| alloc.free(v);
        if (self.excel_drive_id) |v| alloc.free(v);
        if (self.excel_item_id) |v| alloc.free(v);
        if (self.local_xlsx_path) |v| alloc.free(v);
        if (self.last_error) |v| alloc.free(v);
    }

    pub fn clone(self: DesignBomSyncConfig, alloc: Allocator) !DesignBomSyncConfig {
        return .{
            .kind = self.kind,
            .enabled = self.enabled,
            .display_name = try alloc.dupe(u8, self.display_name),
            .workbook_url = if (self.workbook_url) |v| try alloc.dupe(u8, v) else null,
            .workbook_label = if (self.workbook_label) |v| try alloc.dupe(u8, v) else null,
            .credential_ref = if (self.credential_ref) |v| try alloc.dupe(u8, v) else null,
            .credential_display = if (self.credential_display) |v| try alloc.dupe(u8, v) else null,
            .google_sheet_id = if (self.google_sheet_id) |v| try alloc.dupe(u8, v) else null,
            .excel_drive_id = if (self.excel_drive_id) |v| try alloc.dupe(u8, v) else null,
            .excel_item_id = if (self.excel_item_id) |v| try alloc.dupe(u8, v) else null,
            .local_xlsx_path = if (self.local_xlsx_path) |v| try alloc.dupe(u8, v) else null,
            .last_sync_at = self.last_sync_at,
            .last_error = if (self.last_error) |v| try alloc.dupe(u8, v) else null,
        };
    }
};

pub const SoupSyncConfig = struct {
    kind: SoupSyncKind,
    enabled: bool = true,
    display_name: []const u8,
    bom_name: ?[]const u8 = null,
    full_product_identifier: []const u8,
    workbook_url: ?[]const u8 = null,
    workbook_label: ?[]const u8 = null,
    credential_ref: ?[]const u8 = null,
    credential_display: ?[]const u8 = null,
    google_sheet_id: ?[]const u8 = null,
    excel_drive_id: ?[]const u8 = null,
    excel_item_id: ?[]const u8 = null,
    local_xlsx_path: ?[]const u8 = null,
    last_sync_at: i64 = 0,
    last_error: ?[]const u8 = null,

    pub fn deinit(self: *SoupSyncConfig, alloc: Allocator) void {
        alloc.free(self.display_name);
        if (self.bom_name) |v| alloc.free(v);
        alloc.free(self.full_product_identifier);
        if (self.workbook_url) |v| alloc.free(v);
        if (self.workbook_label) |v| alloc.free(v);
        if (self.credential_ref) |v| alloc.free(v);
        if (self.credential_display) |v| alloc.free(v);
        if (self.google_sheet_id) |v| alloc.free(v);
        if (self.excel_drive_id) |v| alloc.free(v);
        if (self.excel_item_id) |v| alloc.free(v);
        if (self.local_xlsx_path) |v| alloc.free(v);
        if (self.last_error) |v| alloc.free(v);
    }

    pub fn clone(self: SoupSyncConfig, alloc: Allocator) !SoupSyncConfig {
        return .{
            .kind = self.kind,
            .enabled = self.enabled,
            .display_name = try alloc.dupe(u8, self.display_name),
            .bom_name = if (self.bom_name) |v| try alloc.dupe(u8, v) else null,
            .full_product_identifier = try alloc.dupe(u8, self.full_product_identifier),
            .workbook_url = if (self.workbook_url) |v| try alloc.dupe(u8, v) else null,
            .workbook_label = if (self.workbook_label) |v| try alloc.dupe(u8, v) else null,
            .credential_ref = if (self.credential_ref) |v| try alloc.dupe(u8, v) else null,
            .credential_display = if (self.credential_display) |v| try alloc.dupe(u8, v) else null,
            .google_sheet_id = if (self.google_sheet_id) |v| try alloc.dupe(u8, v) else null,
            .excel_drive_id = if (self.excel_drive_id) |v| try alloc.dupe(u8, v) else null,
            .excel_item_id = if (self.excel_item_id) |v| try alloc.dupe(u8, v) else null,
            .local_xlsx_path = if (self.local_xlsx_path) |v| try alloc.dupe(u8, v) else null,
            .last_sync_at = self.last_sync_at,
            .last_error = if (self.last_error) |v| try alloc.dupe(u8, v) else null,
        };
    }
};

pub const WorkbookConfig = struct {
    id: []const u8,
    slug: []const u8,
    display_name: []const u8,
    profile: []const u8,
    repo_paths: []const []const u8,
    db_path: []const u8,
    inbox_dir: []const u8,
    removed_at: ?i64 = null,
    platform: ?provider_common.ProviderId = null,
    workbook_url: ?[]const u8 = null,
    workbook_label: ?[]const u8 = null,
    credential_ref: ?[]const u8 = null,
    credential_display: ?[]const u8 = null,
    google_sheet_id: ?[]const u8 = null,
    excel_drive_id: ?[]const u8 = null,
    excel_item_id: ?[]const u8 = null,
    design_bom_sync: ?DesignBomSyncConfig = null,
    soup_sync: ?SoupSyncConfig = null,

    pub fn deinit(self: *WorkbookConfig, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.slug);
        alloc.free(self.display_name);
        alloc.free(self.profile);
        for (self.repo_paths) |path| alloc.free(path);
        alloc.free(self.repo_paths);
        alloc.free(self.db_path);
        alloc.free(self.inbox_dir);
        if (self.workbook_url) |v| alloc.free(v);
        if (self.workbook_label) |v| alloc.free(v);
        if (self.credential_ref) |v| alloc.free(v);
        if (self.credential_display) |v| alloc.free(v);
        if (self.google_sheet_id) |v| alloc.free(v);
        if (self.excel_drive_id) |v| alloc.free(v);
        if (self.excel_item_id) |v| alloc.free(v);
        if (self.design_bom_sync) |*v| v.deinit(alloc);
        if (self.soup_sync) |*v| v.deinit(alloc);
    }

    pub fn clone(self: WorkbookConfig, alloc: Allocator) !WorkbookConfig {
        return .{
            .id = try alloc.dupe(u8, self.id),
            .slug = try alloc.dupe(u8, self.slug),
            .display_name = try alloc.dupe(u8, self.display_name),
            .profile = try alloc.dupe(u8, self.profile),
            .repo_paths = try cloneStringSlice(self.repo_paths, alloc),
            .db_path = try alloc.dupe(u8, self.db_path),
            .inbox_dir = try alloc.dupe(u8, self.inbox_dir),
            .removed_at = self.removed_at,
            .platform = self.platform,
            .workbook_url = if (self.workbook_url) |v| try alloc.dupe(u8, v) else null,
            .workbook_label = if (self.workbook_label) |v| try alloc.dupe(u8, v) else null,
            .credential_ref = if (self.credential_ref) |v| try alloc.dupe(u8, v) else null,
            .credential_display = if (self.credential_display) |v| try alloc.dupe(u8, v) else null,
            .google_sheet_id = if (self.google_sheet_id) |v| try alloc.dupe(u8, v) else null,
            .excel_drive_id = if (self.excel_drive_id) |v| try alloc.dupe(u8, v) else null,
            .excel_item_id = if (self.excel_item_id) |v| try alloc.dupe(u8, v) else null,
            .design_bom_sync = if (self.design_bom_sync) |v| try v.clone(alloc) else null,
            .soup_sync = if (self.soup_sync) |v| try v.clone(alloc) else null,
        };
    }
};

pub const LiveConfig = struct {
    schema_version: u32 = 2,
    active_workbook_id: ?[]const u8 = null,
    workbooks: []WorkbookConfig,

    pub fn deinit(self: *LiveConfig, alloc: Allocator) void {
        if (self.active_workbook_id) |v| alloc.free(v);
        for (self.workbooks) |*workbook| workbook.deinit(alloc);
        alloc.free(self.workbooks);
    }
};

pub const BootstrapOptions = struct {
    profile: []const u8 = "generic",
    repo_paths: []const []const u8 = &.{},
    db_path_override: ?[]const u8 = null,
    inbox_dir_override: ?[]const u8 = null,
};

pub fn loadOrInit(alloc: Allocator, options: BootstrapOptions) !LiveConfig {
    const path = try workbook_paths.configPath(alloc);
    defer alloc.free(path);

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            var cfg = try bootstrapConfig(alloc, options);
            errdefer cfg.deinit(alloc);
            if (!hasBootstrapOverrides(options)) try save(&cfg, alloc);
            return cfg;
        },
        else => return err,
    };
    defer alloc.free(bytes);

    var cfg = try loadFromSlice(bytes, alloc);
    errdefer cfg.deinit(alloc);
    const changed = try normalizeAndValidate(&cfg, alloc);
    if (changed and !hasBootstrapOverrides(options)) try save(&cfg, alloc);
    try applyBootstrapOverrides(&cfg, options, alloc);
    return cfg;
}

pub fn save(cfg: *const LiveConfig, alloc: Allocator) !void {
    const path = try workbook_paths.configPath(alloc);
    defer alloc.free(path);
    const dir_name = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir_name);
    const json = try toJson(cfg, alloc);
    defer alloc.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}

pub fn activeWorkbook(cfg: *LiveConfig) ?*WorkbookConfig {
    const id = cfg.active_workbook_id orelse return null;
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn activeWorkbookConst(cfg: *const LiveConfig) ?*const WorkbookConfig {
    const id = cfg.active_workbook_id orelse return null;
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn findById(cfg: *LiveConfig, id: []const u8) ?*WorkbookConfig {
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn findByIdConst(cfg: *const LiveConfig, id: []const u8) ?*const WorkbookConfig {
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn findByDisplayName(cfg: *LiveConfig, display_name: []const u8) ?*WorkbookConfig {
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.display_name, display_name)) return workbook;
    }
    return null;
}

pub fn visibleWorkbookCount(cfg: *const LiveConfig) usize {
    var count: usize = 0;
    for (cfg.workbooks) |workbook| {
        if (workbook.removed_at == null) count += 1;
    }
    return count;
}

pub fn firstVisibleWorkbookId(cfg: *const LiveConfig) ?[]const u8 {
    for (cfg.workbooks) |workbook| {
        if (workbook.removed_at == null) return workbook.id;
    }
    return null;
}

pub fn setActiveProfile(cfg: *LiveConfig, profile: []const u8, alloc: Allocator) !void {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    alloc.free(workbook.profile);
    workbook.profile = try alloc.dupe(u8, profile);
}

pub fn addActiveRepoPath(cfg: *LiveConfig, path: []const u8, alloc: Allocator) !void {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
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

pub fn deleteActiveRepoAt(cfg: *LiveConfig, idx: usize, alloc: Allocator) !bool {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
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
    cfg: *LiveConfig,
    validated: provider_common.ValidatedDraft,
    credential_ref: []const u8,
    alloc: Allocator,
) !void {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;

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

pub fn activateWorkbookId(cfg: *LiveConfig, id: []const u8, alloc: Allocator) !void {
    const workbook = findById(cfg, id) orelse return error.WorkbookNotFound;
    if (workbook.removed_at != null) return error.WorkbookRemoved;
    if (cfg.active_workbook_id) |existing| alloc.free(existing);
    cfg.active_workbook_id = try alloc.dupe(u8, id);
}

pub fn replaceActiveDesignBomSync(cfg: *LiveConfig, sync_cfg: DesignBomSyncConfig, alloc: Allocator) !void {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.design_bom_sync) |*existing| existing.deinit(alloc);
    workbook.design_bom_sync = try sync_cfg.clone(alloc);
}

pub fn clearActiveDesignBomSync(cfg: *LiveConfig, alloc: Allocator) !void {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.design_bom_sync) |*existing| existing.deinit(alloc);
    workbook.design_bom_sync = null;
}

pub fn replaceActiveSoupSync(cfg: *LiveConfig, sync_cfg: SoupSyncConfig, alloc: Allocator) !void {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.soup_sync) |*existing| existing.deinit(alloc);
    workbook.soup_sync = try sync_cfg.clone(alloc);
}

pub fn clearActiveSoupSync(cfg: *LiveConfig, alloc: Allocator) !void {
    const workbook = activeWorkbook(cfg) orelse return error.NoActiveWorkbook;
    if (workbook.soup_sync) |*existing| existing.deinit(alloc);
    workbook.soup_sync = null;
}

pub fn renameWorkbook(cfg: *LiveConfig, id: []const u8, display_name: []const u8, alloc: Allocator) !void {
    ensureDisplayNameAvailable(cfg, display_name, id) catch |err| return err;
    const workbook = findById(cfg, id) orelse return error.WorkbookNotFound;
    alloc.free(workbook.display_name);
    workbook.display_name = try alloc.dupe(u8, display_name);
}

pub fn removeWorkbook(cfg: *LiveConfig, id: []const u8, alloc: Allocator) !void {
    const workbook = findById(cfg, id) orelse return error.WorkbookNotFound;
    if (workbook.removed_at != null) return error.WorkbookRemoved;
    workbook.removed_at = std.time.timestamp();

    if (cfg.active_workbook_id) |active_id| {
        if (std.mem.eql(u8, active_id, id)) {
            const next_id = firstVisibleWorkbookId(cfg);
            alloc.free(active_id);
            cfg.active_workbook_id = if (next_id) |value|
                try alloc.dupe(u8, value)
            else
                null;
        }
    }
}

pub fn purgeWorkbookAt(cfg: *LiveConfig, idx: usize, alloc: Allocator) !void {
    if (idx >= cfg.workbooks.len) return error.WorkbookNotFound;
    var target = cfg.workbooks[idx];
    target.deinit(alloc);

    const new_items = try alloc.alloc(WorkbookConfig, cfg.workbooks.len - 1);
    errdefer alloc.free(new_items);

    var out_idx: usize = 0;
    for (cfg.workbooks, 0..) |workbook, in_idx| {
        if (in_idx == idx) continue;
        new_items[out_idx] = workbook;
        out_idx += 1;
    }
    alloc.free(cfg.workbooks);
    cfg.workbooks = new_items;

    const visible_id = firstVisibleWorkbookId(cfg);
    if (cfg.active_workbook_id) |active_id| {
        if (findByIdConst(cfg, active_id) == null) {
            alloc.free(active_id);
            cfg.active_workbook_id = if (visible_id) |value| try alloc.dupe(u8, value) else null;
        }
    } else if (visible_id) |value| {
        cfg.active_workbook_id = try alloc.dupe(u8, value);
    }
}

pub fn createWorkbookEntry(
    cfg: *const LiveConfig,
    display_name: []const u8,
    validated: provider_common.ValidatedDraft,
    credential_ref: []const u8,
    repo_paths: []const []const u8,
    alloc: Allocator,
) !WorkbookConfig {
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
    const cloned_repos = try cloneStringSlice(repo_paths, alloc);
    errdefer {
        for (cloned_repos) |path| alloc.free(path);
        alloc.free(cloned_repos);
    }

    var entry = WorkbookConfig{
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

pub fn appendWorkbook(cfg: *LiveConfig, entry: WorkbookConfig, make_active: bool, alloc: Allocator) !void {
    const new_items = try alloc.alloc(WorkbookConfig, cfg.workbooks.len + 1);
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

pub fn bootstrapConfig(alloc: Allocator, options: BootstrapOptions) !LiveConfig {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const id = try std.fmt.allocPrint(alloc, "wb_{s}", .{std.fmt.bytesToHex(bytes, .lower)});
    errdefer alloc.free(id);
    const slug = try workbook_paths.slugify("Workbook", alloc);
    errdefer alloc.free(slug);
    const repo_paths = try cloneStringSlice(options.repo_paths, alloc);
    errdefer {
        for (repo_paths) |path| alloc.free(path);
        alloc.free(repo_paths);
    }
    const db_path = if (options.db_path_override) |path|
        try alloc.dupe(u8, path)
    else
        try workbook_paths.graphDbPath(slug, alloc);
    errdefer alloc.free(db_path);
    const inbox_dir = if (options.inbox_dir_override) |path|
        try alloc.dupe(u8, path)
    else
        try workbook_paths.inboxDir(slug, alloc);
    errdefer alloc.free(inbox_dir);

    const workbooks = try alloc.alloc(WorkbookConfig, 1);
    workbooks[0] = .{
        .id = id,
        .slug = slug,
        .display_name = try alloc.dupe(u8, "Workbook"),
        .profile = try alloc.dupe(u8, options.profile),
        .repo_paths = repo_paths,
        .db_path = db_path,
        .inbox_dir = inbox_dir,
    };
    return .{
        .schema_version = 2,
        .active_workbook_id = try alloc.dupe(u8, id),
        .workbooks = workbooks,
    };
}

fn hasBootstrapOverrides(options: BootstrapOptions) bool {
    return options.db_path_override != null or options.inbox_dir_override != null;
}

fn applyBootstrapOverrides(cfg: *LiveConfig, options: BootstrapOptions, alloc: Allocator) !void {
    const workbook = activeWorkbook(cfg) orelse return;
    if (options.db_path_override) |path| {
        alloc.free(workbook.db_path);
        workbook.db_path = try alloc.dupe(u8, path);
    }
    if (options.inbox_dir_override) |path| {
        alloc.free(workbook.inbox_dir);
        workbook.inbox_dir = try alloc.dupe(u8, path);
    }
}

fn loadFromSlice(bytes: []const u8, alloc: Allocator) !LiveConfig {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const schema_version = if (json_util.getObjectField(root, "schema_version")) |value| switch (value) {
        .integer => @as(u32, @intCast(value.integer)),
        else => return error.InvalidJson,
    } else 1;
    const active_id = try dupOptionalString(root, "active_workbook_id", alloc);
    errdefer if (active_id) |value| alloc.free(value);
    const workbooks_val = json_util.getObjectField(root, "workbooks") orelse return error.InvalidJson;
    if (workbooks_val != .array) return error.InvalidJson;
    const workbooks = try alloc.alloc(WorkbookConfig, workbooks_val.array.items.len);
    errdefer alloc.free(workbooks);
    for (workbooks_val.array.items, 0..) |item, idx| {
        workbooks[idx] = try parseWorkbook(item, alloc);
    }
    return .{
        .schema_version = schema_version,
        .active_workbook_id = active_id,
        .workbooks = workbooks,
    };
}

fn normalizeAndValidate(cfg: *LiveConfig, alloc: Allocator) !bool {
    var changed = false;
    if (cfg.schema_version < 2) {
        cfg.schema_version = 2;
        changed = true;
    }

    for (cfg.workbooks) |*workbook| {
        if (workbook.removed_at == null and std.mem.eql(u8, workbook.display_name, "Workbook")) {
            if (workbook.workbook_label) |label| {
                alloc.free(workbook.display_name);
                workbook.display_name = try alloc.dupe(u8, label);
                changed = true;
            }
        }
    }

    try validateUniqueDisplayNames(cfg);
    try validateUniqueSlugs(cfg);

    if (cfg.active_workbook_id) |active_id| {
        const active_cfg = findById(cfg, active_id);
        if (active_cfg == null or active_cfg.?.removed_at != null) {
            alloc.free(active_id);
            cfg.active_workbook_id = null;
            changed = true;
        }
    }

    if (visibleWorkbookCount(cfg) == 0) {
        if (cfg.active_workbook_id) |active_id| {
            alloc.free(active_id);
            cfg.active_workbook_id = null;
            changed = true;
        }
    } else if (cfg.active_workbook_id == null) {
        const first_id = firstVisibleWorkbookId(cfg) orelse return error.NoVisibleWorkbook;
        cfg.active_workbook_id = try alloc.dupe(u8, first_id);
        changed = true;
    }

    return changed;
}

fn validateUniqueDisplayNames(cfg: *const LiveConfig) !void {
    for (cfg.workbooks, 0..) |left, i| {
        for (cfg.workbooks[i + 1 ..]) |right| {
            if (std.mem.eql(u8, left.display_name, right.display_name)) {
                return error.DuplicateDisplayName;
            }
        }
    }
}

fn validateUniqueSlugs(cfg: *const LiveConfig) !void {
    for (cfg.workbooks, 0..) |left, i| {
        for (cfg.workbooks[i + 1 ..]) |right| {
            if (std.mem.eql(u8, left.slug, right.slug)) {
                return error.DuplicateSlug;
            }
        }
    }
}

fn uniqueSlug(cfg: *const LiveConfig, display_name: []const u8, alloc: Allocator) ![]u8 {
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

fn slugExists(cfg: *const LiveConfig, slug: []const u8) bool {
    for (cfg.workbooks) |workbook| {
        if (std.mem.eql(u8, workbook.slug, slug)) return true;
    }
    return false;
}

fn ensureDisplayNameAvailable(cfg: *const LiveConfig, display_name: []const u8, ignore_id: ?[]const u8) !void {
    for (cfg.workbooks) |workbook| {
        if (ignore_id) |id| {
            if (std.mem.eql(u8, workbook.id, id)) continue;
        }
        if (std.mem.eql(u8, workbook.display_name, display_name)) return error.DuplicateDisplayName;
    }
}

fn parseWorkbook(value: std.json.Value, alloc: Allocator) !WorkbookConfig {
    if (value != .object) return error.InvalidJson;
    const id = json_util.getString(value, "id") orelse return error.InvalidJson;
    const slug = json_util.getString(value, "slug") orelse return error.InvalidJson;
    const display_name = json_util.getString(value, "display_name") orelse return error.InvalidJson;
    const profile = json_util.getString(value, "profile") orelse return error.InvalidJson;
    const db_path = json_util.getString(value, "db_path") orelse return error.InvalidJson;
    const inbox_dir = json_util.getString(value, "inbox_dir") orelse return error.InvalidJson;
    const repos_val = json_util.getObjectField(value, "repo_paths") orelse return error.InvalidJson;
    if (repos_val != .array) return error.InvalidJson;
    const repo_paths = try alloc.alloc([]const u8, repos_val.array.items.len);
    errdefer alloc.free(repo_paths);
    for (repos_val.array.items, 0..) |repo, idx| {
        if (repo != .string) return error.InvalidJson;
        repo_paths[idx] = try alloc.dupe(u8, repo.string);
    }
    const platform = if (try dupOptionalString(value, "platform", alloc)) |platform_str| blk: {
        defer alloc.free(platform_str);
        break :blk provider_common.providerIdFromString(platform_str) orelse return error.InvalidJson;
    } else null;

    return .{
        .id = try alloc.dupe(u8, id),
        .slug = try alloc.dupe(u8, slug),
        .display_name = try alloc.dupe(u8, display_name),
        .profile = try alloc.dupe(u8, profile),
        .repo_paths = repo_paths,
        .db_path = try alloc.dupe(u8, db_path),
        .inbox_dir = try alloc.dupe(u8, inbox_dir),
        .removed_at = try dupOptionalInt(value, "removed_at"),
        .platform = platform,
        .workbook_url = try dupOptionalString(value, "workbook_url", alloc),
        .workbook_label = try dupOptionalString(value, "workbook_label", alloc),
        .credential_ref = try dupOptionalString(value, "credential_ref", alloc),
        .credential_display = try dupOptionalString(value, "credential_display", alloc),
        .google_sheet_id = try dupOptionalString(value, "google_sheet_id", alloc),
        .excel_drive_id = try dupOptionalString(value, "excel_drive_id", alloc),
        .excel_item_id = try dupOptionalString(value, "excel_item_id", alloc),
        .design_bom_sync = try parseDesignBomSync(value, alloc),
        .soup_sync = try parseSoupSync(value, alloc),
    };
}

fn toJson(cfg: *const LiveConfig, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"schema_version\":");
    try std.fmt.format(buf.writer(alloc), "{d}", .{cfg.schema_version});
    try buf.appendSlice(alloc, ",\"active_workbook_id\":");
    try appendJsonStringOpt(&buf, cfg.active_workbook_id, alloc);
    try buf.appendSlice(alloc, ",\"workbooks\":[");
    for (cfg.workbooks, 0..) |workbook, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try appendWorkbookJson(&buf, workbook, alloc);
    }
    try buf.appendSlice(alloc, "]}");
    return buf.toOwnedSlice(alloc);
}

fn appendWorkbookJson(buf: *std.ArrayList(u8), workbook: WorkbookConfig, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"id\":");
    try json_util.appendJsonQuoted(buf, workbook.id, alloc);
    try buf.appendSlice(alloc, ",\"slug\":");
    try json_util.appendJsonQuoted(buf, workbook.slug, alloc);
    try buf.appendSlice(alloc, ",\"display_name\":");
    try json_util.appendJsonQuoted(buf, workbook.display_name, alloc);
    try buf.appendSlice(alloc, ",\"profile\":");
    try json_util.appendJsonQuoted(buf, workbook.profile, alloc);
    try buf.appendSlice(alloc, ",\"repo_paths\":[");
    for (workbook.repo_paths, 0..) |path, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try json_util.appendJsonQuoted(buf, path, alloc);
    }
    try buf.appendSlice(alloc, "],\"db_path\":");
    try json_util.appendJsonQuoted(buf, workbook.db_path, alloc);
    try buf.appendSlice(alloc, ",\"inbox_dir\":");
    try json_util.appendJsonQuoted(buf, workbook.inbox_dir, alloc);
    try buf.appendSlice(alloc, ",\"removed_at\":");
    if (workbook.removed_at) |removed_at| {
        try std.fmt.format(buf.writer(alloc), "{d}", .{removed_at});
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"platform\":");
    try appendJsonStringOpt(buf, if (workbook.platform) |p| provider_common.providerIdString(p) else null, alloc);
    try buf.appendSlice(alloc, ",\"workbook_url\":");
    try appendJsonStringOpt(buf, workbook.workbook_url, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try appendJsonStringOpt(buf, workbook.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"credential_ref\":");
    try appendJsonStringOpt(buf, workbook.credential_ref, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try appendJsonStringOpt(buf, workbook.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"google_sheet_id\":");
    try appendJsonStringOpt(buf, workbook.google_sheet_id, alloc);
    try buf.appendSlice(alloc, ",\"excel_drive_id\":");
    try appendJsonStringOpt(buf, workbook.excel_drive_id, alloc);
    try buf.appendSlice(alloc, ",\"excel_item_id\":");
    try appendJsonStringOpt(buf, workbook.excel_item_id, alloc);
    try buf.appendSlice(alloc, ",\"design_bom_sync\":");
    if (workbook.design_bom_sync) |design_bom_sync| {
        try appendDesignBomSyncJson(buf, design_bom_sync, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, ",\"soup_sync\":");
    if (workbook.soup_sync) |soup_sync| {
        try appendSoupSyncJson(buf, soup_sync, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.append(alloc, '}');
}

fn parseDesignBomSyncKind(value: []const u8) ?DesignBomSyncKind {
    if (std.mem.eql(u8, value, "google")) return .google;
    if (std.mem.eql(u8, value, "excel")) return .excel;
    if (std.mem.eql(u8, value, "local_xlsx")) return .local_xlsx;
    return null;
}

fn parseSoupSyncKind(value: []const u8) ?SoupSyncKind {
    if (std.mem.eql(u8, value, "google")) return .google;
    if (std.mem.eql(u8, value, "excel")) return .excel;
    if (std.mem.eql(u8, value, "local_xlsx")) return .local_xlsx;
    return null;
}

fn parseDesignBomSync(value: std.json.Value, alloc: Allocator) !?DesignBomSyncConfig {
    const field = json_util.getObjectField(value, "design_bom_sync") orelse return null;
    if (field == .null) return null;
    if (field != .object) return error.InvalidJson;
    const kind_raw = json_util.getString(field, "kind") orelse return error.InvalidJson;
    const kind = parseDesignBomSyncKind(kind_raw) orelse return error.InvalidJson;
    const enabled = if (json_util.getObjectField(field, "enabled")) |raw| switch (raw) {
        .bool => raw.bool,
        else => return error.InvalidJson,
    } else true;
    const display_name = json_util.getString(field, "display_name") orelse return error.InvalidJson;
    return .{
        .kind = kind,
        .enabled = enabled,
        .display_name = try alloc.dupe(u8, display_name),
        .workbook_url = try dupOptionalString(field, "workbook_url", alloc),
        .workbook_label = try dupOptionalString(field, "workbook_label", alloc),
        .credential_ref = try dupOptionalString(field, "credential_ref", alloc),
        .credential_display = try dupOptionalString(field, "credential_display", alloc),
        .google_sheet_id = try dupOptionalString(field, "google_sheet_id", alloc),
        .excel_drive_id = try dupOptionalString(field, "excel_drive_id", alloc),
        .excel_item_id = try dupOptionalString(field, "excel_item_id", alloc),
        .local_xlsx_path = try dupOptionalString(field, "local_xlsx_path", alloc),
        .last_sync_at = (try dupOptionalInt(field, "last_sync_at")) orelse 0,
        .last_error = try dupOptionalString(field, "last_error", alloc),
    };
}

fn appendDesignBomSyncJson(buf: *std.ArrayList(u8), design_bom_sync: DesignBomSyncConfig, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"kind\":");
    try json_util.appendJsonQuoted(buf, @tagName(design_bom_sync.kind), alloc);
    try buf.appendSlice(alloc, ",\"enabled\":");
    try buf.appendSlice(alloc, if (design_bom_sync.enabled) "true" else "false");
    try buf.appendSlice(alloc, ",\"display_name\":");
    try json_util.appendJsonQuoted(buf, design_bom_sync.display_name, alloc);
    try buf.appendSlice(alloc, ",\"workbook_url\":");
    try appendJsonStringOpt(buf, design_bom_sync.workbook_url, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try appendJsonStringOpt(buf, design_bom_sync.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"credential_ref\":");
    try appendJsonStringOpt(buf, design_bom_sync.credential_ref, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try appendJsonStringOpt(buf, design_bom_sync.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"google_sheet_id\":");
    try appendJsonStringOpt(buf, design_bom_sync.google_sheet_id, alloc);
    try buf.appendSlice(alloc, ",\"excel_drive_id\":");
    try appendJsonStringOpt(buf, design_bom_sync.excel_drive_id, alloc);
    try buf.appendSlice(alloc, ",\"excel_item_id\":");
    try appendJsonStringOpt(buf, design_bom_sync.excel_item_id, alloc);
    try buf.appendSlice(alloc, ",\"local_xlsx_path\":");
    try appendJsonStringOpt(buf, design_bom_sync.local_xlsx_path, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"last_sync_at\":{d}", .{design_bom_sync.last_sync_at});
    try buf.appendSlice(alloc, ",\"last_error\":");
    try appendJsonStringOpt(buf, design_bom_sync.last_error, alloc);
    try buf.append(alloc, '}');
}

fn parseSoupSync(value: std.json.Value, alloc: Allocator) !?SoupSyncConfig {
    const field = json_util.getObjectField(value, "soup_sync") orelse return null;
    if (field == .null) return null;
    if (field != .object) return error.InvalidJson;
    const kind_raw = json_util.getString(field, "kind") orelse return error.InvalidJson;
    const kind = parseSoupSyncKind(kind_raw) orelse return error.InvalidJson;
    const enabled = if (json_util.getObjectField(field, "enabled")) |raw| switch (raw) {
        .bool => raw.bool,
        else => return error.InvalidJson,
    } else true;
    const display_name = json_util.getString(field, "display_name") orelse return error.InvalidJson;
    const full_product_identifier = json_util.getString(field, "full_product_identifier") orelse return error.InvalidJson;
    return .{
        .kind = kind,
        .enabled = enabled,
        .display_name = try alloc.dupe(u8, display_name),
        .bom_name = try dupOptionalString(field, "bom_name", alloc),
        .full_product_identifier = try alloc.dupe(u8, full_product_identifier),
        .workbook_url = try dupOptionalString(field, "workbook_url", alloc),
        .workbook_label = try dupOptionalString(field, "workbook_label", alloc),
        .credential_ref = try dupOptionalString(field, "credential_ref", alloc),
        .credential_display = try dupOptionalString(field, "credential_display", alloc),
        .google_sheet_id = try dupOptionalString(field, "google_sheet_id", alloc),
        .excel_drive_id = try dupOptionalString(field, "excel_drive_id", alloc),
        .excel_item_id = try dupOptionalString(field, "excel_item_id", alloc),
        .local_xlsx_path = try dupOptionalString(field, "local_xlsx_path", alloc),
        .last_sync_at = (try dupOptionalInt(field, "last_sync_at")) orelse 0,
        .last_error = try dupOptionalString(field, "last_error", alloc),
    };
}

fn appendSoupSyncJson(buf: *std.ArrayList(u8), soup_sync: SoupSyncConfig, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"kind\":");
    try json_util.appendJsonQuoted(buf, @tagName(soup_sync.kind), alloc);
    try buf.appendSlice(alloc, ",\"enabled\":");
    try buf.appendSlice(alloc, if (soup_sync.enabled) "true" else "false");
    try buf.appendSlice(alloc, ",\"display_name\":");
    try json_util.appendJsonQuoted(buf, soup_sync.display_name, alloc);
    try buf.appendSlice(alloc, ",\"bom_name\":");
    try appendJsonStringOpt(buf, soup_sync.bom_name, alloc);
    try buf.appendSlice(alloc, ",\"full_product_identifier\":");
    try json_util.appendJsonQuoted(buf, soup_sync.full_product_identifier, alloc);
    try buf.appendSlice(alloc, ",\"workbook_url\":");
    try appendJsonStringOpt(buf, soup_sync.workbook_url, alloc);
    try buf.appendSlice(alloc, ",\"workbook_label\":");
    try appendJsonStringOpt(buf, soup_sync.workbook_label, alloc);
    try buf.appendSlice(alloc, ",\"credential_ref\":");
    try appendJsonStringOpt(buf, soup_sync.credential_ref, alloc);
    try buf.appendSlice(alloc, ",\"credential_display\":");
    try appendJsonStringOpt(buf, soup_sync.credential_display, alloc);
    try buf.appendSlice(alloc, ",\"google_sheet_id\":");
    try appendJsonStringOpt(buf, soup_sync.google_sheet_id, alloc);
    try buf.appendSlice(alloc, ",\"excel_drive_id\":");
    try appendJsonStringOpt(buf, soup_sync.excel_drive_id, alloc);
    try buf.appendSlice(alloc, ",\"excel_item_id\":");
    try appendJsonStringOpt(buf, soup_sync.excel_item_id, alloc);
    try buf.appendSlice(alloc, ",\"local_xlsx_path\":");
    try appendJsonStringOpt(buf, soup_sync.local_xlsx_path, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"last_sync_at\":{d}", .{soup_sync.last_sync_at});
    try buf.appendSlice(alloc, ",\"last_error\":");
    try appendJsonStringOpt(buf, soup_sync.last_error, alloc);
    try buf.append(alloc, '}');
}

fn dupOptionalString(value: std.json.Value, key: []const u8, alloc: Allocator) !?[]u8 {
    const field = json_util.getObjectField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .string => try alloc.dupe(u8, field.string),
        else => return error.InvalidJson,
    };
}

fn dupOptionalInt(value: std.json.Value, key: []const u8) !?i64 {
    const field = json_util.getObjectField(value, key) orelse return null;
    return switch (field) {
        .null => null,
        .integer => field.integer,
        else => return error.InvalidJson,
    };
}

fn cloneStringSlice(values: []const []const u8, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, values.len);
    errdefer alloc.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try alloc.dupe(u8, value);
    }
    return out;
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

fn appendJsonStringOpt(buf: *std.ArrayList(u8), value: ?[]const u8, alloc: Allocator) !void {
    if (value) |text| {
        try json_util.appendJsonQuoted(buf, text, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

const testing = std.testing;

test "bootstrapConfig creates single workbook entry" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), cfg.workbooks.len);
    try testing.expect(cfg.active_workbook_id != null);
    try testing.expect(cfg.workbooks[0].db_path.len > 0);
    try testing.expect(cfg.workbooks[0].inbox_dir.len > 0);
    try testing.expectEqual(@as(?i64, null), cfg.workbooks[0].removed_at);
}

test "applyBootstrapOverrides updates active workbook paths in memory" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);

    try applyBootstrapOverrides(&cfg, .{
        .db_path_override = "/tmp/demo.sqlite",
        .inbox_dir_override = "/tmp/demo-inbox",
    }, testing.allocator);

    try testing.expectEqualStrings("/tmp/demo.sqlite", cfg.workbooks[0].db_path);
    try testing.expectEqualStrings("/tmp/demo-inbox", cfg.workbooks[0].inbox_dir);
}

test "save and load roundtrip" {
    var cfg = try bootstrapConfig(testing.allocator, .{
        .profile = "aerospace",
        .repo_paths = &.{"/tmp/repo"},
    });
    defer cfg.deinit(testing.allocator);
    const json = try toJson(&cfg, testing.allocator);
    defer testing.allocator.free(json);
    var loaded = try loadFromSlice(json, testing.allocator);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("aerospace", loaded.workbooks[0].profile);
    try testing.expectEqualStrings("/tmp/repo", loaded.workbooks[0].repo_paths[0]);
}

test "normalizeAndValidate migrates workbook display name and active id" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    cfg.schema_version = 1;
    testing.allocator.free(cfg.workbooks[0].display_name);
    cfg.workbooks[0].display_name = try testing.allocator.dupe(u8, "Workbook");
    cfg.workbooks[0].workbook_label = try testing.allocator.dupe(u8, "sheet-123");
    testing.allocator.free(cfg.active_workbook_id.?);
    cfg.active_workbook_id = null;

    const changed = try normalizeAndValidate(&cfg, testing.allocator);
    try testing.expect(changed);
    try testing.expectEqual(@as(u32, 2), cfg.schema_version);
    try testing.expectEqualStrings("sheet-123", cfg.workbooks[0].display_name);
    try testing.expect(cfg.active_workbook_id != null);
}

test "createWorkbookEntry enforces unique display names and unique slugs" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);

    var validated = provider_common.ValidatedDraft{
        .platform = .google,
        .profile = try testing.allocator.dupe(u8, "medical"),
        .credential_json = try testing.allocator.dupe(u8, "{\"platform\":\"google\"}"),
        .workbook_url = try testing.allocator.dupe(u8, "https://docs.google.com/spreadsheets/d/abc/edit"),
        .workbook_label = try testing.allocator.dupe(u8, "abc"),
        .credential_display = try testing.allocator.dupe(u8, "svc@example.com"),
        .target = .{ .google = .{ .sheet_id = try testing.allocator.dupe(u8, "abc") } },
    };
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

test "workbook config roundtrips optional design bom sync" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    cfg.workbooks[0].design_bom_sync = .{
        .kind = .local_xlsx,
        .enabled = true,
        .display_name = try testing.allocator.dupe(u8, "Design BOM Workbook"),
        .local_xlsx_path = try testing.allocator.dupe(u8, "/tmp/design-bom.xlsx"),
        .last_sync_at = 123,
        .last_error = try testing.allocator.dupe(u8, "none"),
    };

    const json = try toJson(&cfg, testing.allocator);
    defer testing.allocator.free(json);
    var loaded = try loadFromSlice(json, testing.allocator);
    defer loaded.deinit(testing.allocator);
    try testing.expect(loaded.workbooks[0].design_bom_sync != null);
    try testing.expectEqual(DesignBomSyncKind.local_xlsx, loaded.workbooks[0].design_bom_sync.?.kind);
    try testing.expectEqualStrings("/tmp/design-bom.xlsx", loaded.workbooks[0].design_bom_sync.?.local_xlsx_path.?);
    try testing.expectEqual(@as(i64, 123), loaded.workbooks[0].design_bom_sync.?.last_sync_at);
}
