const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const select = @import("select.zig");
const testing = std.testing;

pub fn normalizeAndValidate(cfg: *types.LiveConfig, alloc: Allocator) !bool {
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
        const active_cfg = select.findById(cfg, active_id);
        if (active_cfg == null or active_cfg.?.removed_at != null) {
            alloc.free(active_id);
            cfg.active_workbook_id = null;
            changed = true;
        }
    }

    if (select.visibleWorkbookCount(cfg) == 0) {
        if (cfg.active_workbook_id) |active_id| {
            alloc.free(active_id);
            cfg.active_workbook_id = null;
            changed = true;
        }
    } else if (cfg.active_workbook_id == null) {
        const first_id = select.firstVisibleWorkbookId(cfg) orelse return error.NoVisibleWorkbook;
        cfg.active_workbook_id = try alloc.dupe(u8, first_id);
        changed = true;
    }

    return changed;
}

fn validateUniqueDisplayNames(cfg: *const types.LiveConfig) !void {
    for (cfg.workbooks, 0..) |left, i| {
        for (cfg.workbooks[i + 1 ..]) |right| {
            if (std.mem.eql(u8, left.display_name, right.display_name)) {
                return error.DuplicateDisplayName;
            }
        }
    }
}

fn validateUniqueSlugs(cfg: *const types.LiveConfig) !void {
    for (cfg.workbooks, 0..) |left, i| {
        for (cfg.workbooks[i + 1 ..]) |right| {
            if (std.mem.eql(u8, left.slug, right.slug)) {
                return error.DuplicateSlug;
            }
        }
    }
}

fn makeConfig(alloc: Allocator) !types.LiveConfig {
    return @import("bootstrap.zig").bootstrapConfig(alloc, .{});
}

test "normalizeAndValidate migrates workbook display name and active id" {
    var cfg = try makeConfig(testing.allocator);
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

test "duplicate display names return DuplicateDisplayName" {
    var cfg = try makeConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);
    cfg.workbooks = try testing.allocator.realloc(cfg.workbooks, 2);
    cfg.workbooks[1] = try cfg.workbooks[0].clone(testing.allocator);
    try testing.expectError(error.DuplicateDisplayName, normalizeAndValidate(&cfg, testing.allocator));
}

test "duplicate slugs return DuplicateSlug" {
    var cfg = try makeConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);
    cfg.workbooks = try testing.allocator.realloc(cfg.workbooks, 2);
    cfg.workbooks[1] = try cfg.workbooks[0].clone(testing.allocator);
    testing.allocator.free(cfg.workbooks[1].display_name);
    cfg.workbooks[1].display_name = try testing.allocator.dupe(u8, "Workbook 2");
    try testing.expectError(error.DuplicateSlug, normalizeAndValidate(&cfg, testing.allocator));
}

test "invalid active workbook id is cleared and repaired to first visible workbook when possible" {
    var cfg = try makeConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);
    testing.allocator.free(cfg.active_workbook_id.?);
    cfg.active_workbook_id = try testing.allocator.dupe(u8, "missing");
    const changed = try normalizeAndValidate(&cfg, testing.allocator);
    try testing.expect(changed);
    try testing.expectEqualStrings(cfg.workbooks[0].id, cfg.active_workbook_id.?);
}

test "config with zero visible workbooks clears active_workbook_id" {
    var cfg = try makeConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);
    cfg.workbooks[0].removed_at = 1;
    const changed = try normalizeAndValidate(&cfg, testing.allocator);
    try testing.expect(changed);
    try testing.expectEqual(@as(?[]const u8, null), cfg.active_workbook_id);
}
