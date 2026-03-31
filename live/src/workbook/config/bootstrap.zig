const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const select = @import("select.zig");
const workbook_paths = @import("../paths.zig");
const testing = std.testing;

pub fn bootstrapConfig(alloc: Allocator, options: types.BootstrapOptions) !types.LiveConfig {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const id = try std.fmt.allocPrint(alloc, "wb_{s}", .{std.fmt.bytesToHex(bytes, .lower)});
    errdefer alloc.free(id);
    const slug = try workbook_paths.slugify("Workbook", alloc);
    errdefer alloc.free(slug);
    const repo_paths = try types.cloneStringSlice(options.repo_paths, alloc);
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

    const workbooks = try alloc.alloc(types.WorkbookConfig, 1);
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

pub fn hasBootstrapOverrides(options: types.BootstrapOptions) bool {
    return options.db_path_override != null or options.inbox_dir_override != null;
}

pub fn applyBootstrapOverrides(cfg: *types.LiveConfig, options: types.BootstrapOptions, alloc: Allocator) !void {
    const workbook = select.activeWorkbook(cfg) orelse return;
    if (options.db_path_override) |path| {
        alloc.free(workbook.db_path);
        workbook.db_path = try alloc.dupe(u8, path);
        alloc.free(workbook.display_name);
        workbook.display_name = try alloc.dupe(u8, std.fs.path.basename(path));
        workbook.platform = null;
        clearOptionalString(&workbook.workbook_url, alloc);
        clearOptionalString(&workbook.workbook_label, alloc);
        clearOptionalString(&workbook.credential_ref, alloc);
        clearOptionalString(&workbook.credential_display, alloc);
        clearOptionalString(&workbook.google_sheet_id, alloc);
        clearOptionalString(&workbook.excel_drive_id, alloc);
        clearOptionalString(&workbook.excel_item_id, alloc);
    }
    if (options.inbox_dir_override) |path| {
        alloc.free(workbook.inbox_dir);
        workbook.inbox_dir = try alloc.dupe(u8, path);
    }
}

fn clearOptionalString(dst: *?[]const u8, alloc: Allocator) void {
    if (dst.*) |value| alloc.free(value);
    dst.* = null;
}

test "bootstrapConfig creates single workbook entry" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), cfg.workbooks.len);
    try testing.expect(cfg.active_workbook_id != null);
    try testing.expect(cfg.workbooks[0].db_path.len > 0);
    try testing.expect(cfg.workbooks[0].inbox_dir.len > 0);
    try testing.expectEqual(@as(?i64, null), cfg.workbooks[0].removed_at);
}

test "bootstrapConfig honors db_path_override and inbox_dir_override" {
    var cfg = try bootstrapConfig(testing.allocator, .{
        .db_path_override = "/tmp/demo.sqlite",
        .inbox_dir_override = "/tmp/demo-inbox",
    });
    defer cfg.deinit(testing.allocator);
    try testing.expectEqualStrings("/tmp/demo.sqlite", cfg.workbooks[0].db_path);
    try testing.expectEqualStrings("/tmp/demo-inbox", cfg.workbooks[0].inbox_dir);
}

test "applyBootstrapOverrides updates active workbook paths in memory" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    cfg.workbooks[0].platform = .google;
    cfg.workbooks[0].workbook_url = try testing.allocator.dupe(u8, "https://docs.google.com/spreadsheets/d/abc/edit");
    cfg.workbooks[0].workbook_label = try testing.allocator.dupe(u8, "abc");
    cfg.workbooks[0].credential_ref = try testing.allocator.dupe(u8, "cred_demo");
    cfg.workbooks[0].credential_display = try testing.allocator.dupe(u8, "svc@example.com");
    cfg.workbooks[0].google_sheet_id = try testing.allocator.dupe(u8, "abc");

    try applyBootstrapOverrides(&cfg, .{
        .db_path_override = "/tmp/demo.sqlite",
        .inbox_dir_override = "/tmp/demo-inbox",
    }, testing.allocator);

    try testing.expectEqualStrings("/tmp/demo.sqlite", cfg.workbooks[0].db_path);
    try testing.expectEqualStrings("/tmp/demo-inbox", cfg.workbooks[0].inbox_dir);
    try testing.expectEqualStrings("demo.sqlite", cfg.workbooks[0].display_name);
    try testing.expect(cfg.workbooks[0].platform == null);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].workbook_url);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].workbook_label);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].credential_ref);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].credential_display);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].google_sheet_id);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].excel_drive_id);
    try testing.expectEqual(@as(?[]const u8, null), cfg.workbooks[0].excel_item_id);
}

test "applyBootstrapOverrides leaves identity untouched when only inbox override is present" {
    var cfg = try bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    const original_id = cfg.workbooks[0].id;
    const original_slug = cfg.workbooks[0].slug;
    const original_name = cfg.workbooks[0].display_name;
    try applyBootstrapOverrides(&cfg, .{ .inbox_dir_override = "/tmp/alt-inbox" }, testing.allocator);
    try testing.expectEqualStrings(original_id, cfg.workbooks[0].id);
    try testing.expectEqualStrings(original_slug, cfg.workbooks[0].slug);
    try testing.expectEqualStrings(original_name, cfg.workbooks[0].display_name);
    try testing.expectEqualStrings("/tmp/alt-inbox", cfg.workbooks[0].inbox_dir);
}

test "hasBootstrapOverrides matches current semantics exactly" {
    try testing.expect(!hasBootstrapOverrides(.{}));
    try testing.expect(hasBootstrapOverrides(.{ .db_path_override = "/tmp/demo.sqlite" }));
    try testing.expect(hasBootstrapOverrides(.{ .inbox_dir_override = "/tmp/demo-inbox" }));
}
