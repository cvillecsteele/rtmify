const std = @import("std");
const Allocator = std.mem.Allocator;

const provider_common = @import("../../provider_common.zig");
const testing = std.testing;

pub const DesignBomSyncKind = enum { google, excel, local_xlsx };
pub const SoupSyncKind = enum { google, excel, local_xlsx };

pub fn cloneStringSlice(values: []const []const u8, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, values.len);
    errdefer alloc.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try alloc.dupe(u8, value);
    }
    return out;
}

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

fn testPath(parts: []const []const u8, alloc: Allocator) ![]u8 {
    return std.fs.path.join(alloc, parts);
}

test "WorkbookConfig clone deep-copies repo paths and optional strings" {
    const repo_a = try testPath(&.{ "tmp", "repo-a" }, testing.allocator);
    defer testing.allocator.free(repo_a);
    const repo_b = try testPath(&.{ "tmp", "repo-b" }, testing.allocator);
    defer testing.allocator.free(repo_b);
    const db_path = try testPath(&.{ "tmp", "demo.sqlite" }, testing.allocator);
    defer testing.allocator.free(db_path);
    const inbox_dir = try testPath(&.{ "tmp", "demo-inbox" }, testing.allocator);
    defer testing.allocator.free(inbox_dir);
    var cfg = WorkbookConfig{
        .id = try testing.allocator.dupe(u8, "wb_1"),
        .slug = try testing.allocator.dupe(u8, "demo"),
        .display_name = try testing.allocator.dupe(u8, "Demo"),
        .profile = try testing.allocator.dupe(u8, "medical"),
        .repo_paths = try cloneStringSlice(&.{ repo_a, repo_b }, testing.allocator),
        .db_path = try testing.allocator.dupe(u8, db_path),
        .inbox_dir = try testing.allocator.dupe(u8, inbox_dir),
        .workbook_url = try testing.allocator.dupe(u8, "https://example.com"),
        .workbook_label = try testing.allocator.dupe(u8, "Workbook"),
        .credential_ref = try testing.allocator.dupe(u8, "cred"),
        .credential_display = try testing.allocator.dupe(u8, "svc@example.com"),
        .google_sheet_id = try testing.allocator.dupe(u8, "sheet"),
    };
    defer cfg.deinit(testing.allocator);

    var cloned = try cfg.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);

    try testing.expectEqualStrings(cfg.id, cloned.id);
    try testing.expect(cfg.id.ptr != cloned.id.ptr);
    try testing.expectEqualStrings(cfg.repo_paths[0], cloned.repo_paths[0]);
    try testing.expect(cfg.repo_paths[0].ptr != cloned.repo_paths[0].ptr);
    try testing.expectEqualStrings(cfg.workbook_url.?, cloned.workbook_url.?);
    try testing.expect(cfg.workbook_url.?.ptr != cloned.workbook_url.?.ptr);
}

test "sync config clones preserve optional fields" {
    var design = DesignBomSyncConfig{
        .kind = .google,
        .display_name = try testing.allocator.dupe(u8, "Design"),
        .workbook_url = try testing.allocator.dupe(u8, "https://google"),
        .last_error = try testing.allocator.dupe(u8, "boom"),
    };
    defer design.deinit(testing.allocator);
    var design_clone = try design.clone(testing.allocator);
    defer design_clone.deinit(testing.allocator);
    try testing.expectEqualStrings(design.workbook_url.?, design_clone.workbook_url.?);
    try testing.expect(design.workbook_url.?.ptr != design_clone.workbook_url.?.ptr);

    const soup_path = try testPath(&.{ "tmp", "soup.xlsx" }, testing.allocator);
    defer testing.allocator.free(soup_path);
    var soup = SoupSyncConfig{
        .kind = .local_xlsx,
        .display_name = try testing.allocator.dupe(u8, "Soup"),
        .bom_name = try testing.allocator.dupe(u8, "Main"),
        .full_product_identifier = try testing.allocator.dupe(u8, "product://main"),
        .local_xlsx_path = try testing.allocator.dupe(u8, soup_path),
    };
    defer soup.deinit(testing.allocator);
    var soup_clone = try soup.clone(testing.allocator);
    defer soup_clone.deinit(testing.allocator);
    try testing.expectEqualStrings(soup.bom_name.?, soup_clone.bom_name.?);
    try testing.expect(soup.bom_name.?.ptr != soup_clone.bom_name.?.ptr);
}

test "LiveConfig deinit frees nested workbook sync configs safely" {
    const repo_path = try testPath(&.{ "tmp", "repo" }, testing.allocator);
    defer testing.allocator.free(repo_path);
    const db_path = try testPath(&.{ "tmp", "demo.sqlite" }, testing.allocator);
    defer testing.allocator.free(db_path);
    const inbox_dir = try testPath(&.{ "tmp", "demo-inbox" }, testing.allocator);
    defer testing.allocator.free(inbox_dir);
    const design_path = try testPath(&.{ "tmp", "design.xlsx" }, testing.allocator);
    defer testing.allocator.free(design_path);
    const soup_path = try testPath(&.{ "tmp", "soup.xlsx" }, testing.allocator);
    defer testing.allocator.free(soup_path);
    var live = LiveConfig{
        .active_workbook_id = try testing.allocator.dupe(u8, "wb_1"),
        .workbooks = try testing.allocator.alloc(WorkbookConfig, 1),
    };
    live.workbooks[0] = .{
        .id = try testing.allocator.dupe(u8, "wb_1"),
        .slug = try testing.allocator.dupe(u8, "demo"),
        .display_name = try testing.allocator.dupe(u8, "Demo"),
        .profile = try testing.allocator.dupe(u8, "generic"),
        .repo_paths = try cloneStringSlice(&.{repo_path}, testing.allocator),
        .db_path = try testing.allocator.dupe(u8, db_path),
        .inbox_dir = try testing.allocator.dupe(u8, inbox_dir),
        .design_bom_sync = .{
            .kind = .local_xlsx,
            .display_name = try testing.allocator.dupe(u8, "Design"),
            .local_xlsx_path = try testing.allocator.dupe(u8, design_path),
        },
        .soup_sync = .{
            .kind = .local_xlsx,
            .display_name = try testing.allocator.dupe(u8, "Soup"),
            .full_product_identifier = try testing.allocator.dupe(u8, "product://demo"),
            .local_xlsx_path = try testing.allocator.dupe(u8, soup_path),
        },
    };
    live.deinit(testing.allocator);
}
