const std = @import("std");

const types = @import("types.zig");
const testing = std.testing;

pub fn activeWorkbook(cfg: *types.LiveConfig) ?*types.WorkbookConfig {
    const id = cfg.active_workbook_id orelse return null;
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn activeWorkbookConst(cfg: *const types.LiveConfig) ?*const types.WorkbookConfig {
    const id = cfg.active_workbook_id orelse return null;
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn findById(cfg: *types.LiveConfig, id: []const u8) ?*types.WorkbookConfig {
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn findByIdConst(cfg: *const types.LiveConfig, id: []const u8) ?*const types.WorkbookConfig {
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.id, id)) return workbook;
    }
    return null;
}

pub fn findByDisplayName(cfg: *types.LiveConfig, display_name: []const u8) ?*types.WorkbookConfig {
    for (cfg.workbooks) |*workbook| {
        if (std.mem.eql(u8, workbook.display_name, display_name)) return workbook;
    }
    return null;
}

pub fn visibleWorkbookCount(cfg: *const types.LiveConfig) usize {
    var count: usize = 0;
    for (cfg.workbooks) |workbook| {
        if (workbook.removed_at == null) count += 1;
    }
    return count;
}

pub fn firstVisibleWorkbookId(cfg: *const types.LiveConfig) ?[]const u8 {
    for (cfg.workbooks) |workbook| {
        if (workbook.removed_at == null) return workbook.id;
    }
    return null;
}

test "activeWorkbook returns null when active_workbook_id missing" {
    var cfg = types.LiveConfig{ .workbooks = &.{} };
    try testing.expect(activeWorkbook(&cfg) == null);
}

test "activeWorkbookConst returns removed workbook when explicitly active" {
    var workbooks = [_]types.WorkbookConfig{
        .{
            .id = "wb_1",
            .slug = "demo",
            .display_name = "Demo",
            .profile = "generic",
            .repo_paths = &.{},
            .db_path = "/tmp/db",
            .inbox_dir = "/tmp/inbox",
            .removed_at = 1,
        },
    };
    const cfg = types.LiveConfig{
        .active_workbook_id = "wb_1",
        .workbooks = &workbooks,
    };
    try testing.expect(activeWorkbookConst(&cfg) != null);
}

test "firstVisibleWorkbookId skips removed workbooks" {
    var workbooks = [_]types.WorkbookConfig{
        .{
            .id = "wb_removed",
            .slug = "removed",
            .display_name = "Removed",
            .profile = "generic",
            .repo_paths = &.{},
            .db_path = "/tmp/db1",
            .inbox_dir = "/tmp/inbox1",
            .removed_at = 1,
        },
        .{
            .id = "wb_visible",
            .slug = "visible",
            .display_name = "Visible",
            .profile = "generic",
            .repo_paths = &.{},
            .db_path = "/tmp/db2",
            .inbox_dir = "/tmp/inbox2",
        },
    };
    const cfg = types.LiveConfig{ .workbooks = &workbooks };
    try testing.expectEqualStrings("wb_visible", firstVisibleWorkbookId(&cfg).?);
}

test "visibleWorkbookCount counts only non-removed workbooks" {
    var workbooks = [_]types.WorkbookConfig{
        .{
            .id = "wb_1",
            .slug = "one",
            .display_name = "One",
            .profile = "generic",
            .repo_paths = &.{},
            .db_path = "/tmp/db1",
            .inbox_dir = "/tmp/inbox1",
        },
        .{
            .id = "wb_2",
            .slug = "two",
            .display_name = "Two",
            .profile = "generic",
            .repo_paths = &.{},
            .db_path = "/tmp/db2",
            .inbox_dir = "/tmp/inbox2",
            .removed_at = 1,
        },
    };
    const cfg = types.LiveConfig{ .workbooks = &workbooks };
    try testing.expectEqual(@as(usize, 1), visibleWorkbookCount(&cfg));
}
