const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("../../json_util.zig");
const provider_common = @import("../../provider_common.zig");
const workbook_paths = @import("../paths.zig");
const bootstrap = @import("bootstrap.zig");
const normalize = @import("normalize.zig");
const types = @import("types.zig");
const testing = std.testing;

pub fn loadOrInit(alloc: Allocator, options: types.BootstrapOptions) !types.LiveConfig {
    const path = try workbook_paths.configPath(alloc);
    defer alloc.free(path);

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            var cfg = try bootstrap.bootstrapConfig(alloc, options);
            errdefer cfg.deinit(alloc);
            if (!bootstrap.hasBootstrapOverrides(options)) try save(&cfg, alloc);
            return cfg;
        },
        else => return err,
    };
    defer alloc.free(bytes);

    var cfg = try loadFromSlice(bytes, alloc);
    errdefer cfg.deinit(alloc);
    const changed = try normalize.normalizeAndValidate(&cfg, alloc);
    if (changed and !bootstrap.hasBootstrapOverrides(options)) try save(&cfg, alloc);
    try bootstrap.applyBootstrapOverrides(&cfg, options, alloc);
    return cfg;
}

pub fn save(cfg: *const types.LiveConfig, alloc: Allocator) !void {
    const path = try workbook_paths.configPath(alloc);
    defer alloc.free(path);
    const dir_name = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir_name);
    const json = try toJson(cfg, alloc);
    defer alloc.free(json);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}

fn loadFromSlice(bytes: []const u8, alloc: Allocator) !types.LiveConfig {
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
    const workbooks = try alloc.alloc(types.WorkbookConfig, workbooks_val.array.items.len);
    errdefer alloc.free(workbooks);
    var init_count: usize = 0;
    errdefer {
        for (workbooks[0..init_count]) |*w| w.deinit(alloc);
    }
    for (workbooks_val.array.items, 0..) |item, idx| {
        workbooks[idx] = try parseWorkbook(item, alloc);
        init_count += 1;
    }
    return .{
        .schema_version = schema_version,
        .active_workbook_id = active_id,
        .workbooks = workbooks,
    };
}

fn toJson(cfg: *const types.LiveConfig, alloc: Allocator) ![]u8 {
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

fn parseWorkbook(value: std.json.Value, alloc: Allocator) !types.WorkbookConfig {
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
    errdefer for (repo_paths[0..repos_val.array.items.len]) |path| alloc.free(path);
    for (repos_val.array.items, 0..) |repo, idx| {
        if (repo != .string) return error.InvalidJson;
        repo_paths[idx] = try alloc.dupe(u8, repo.string);
    }
    const platform = if (try dupOptionalString(value, "platform", alloc)) |platform_str| blk: {
        defer alloc.free(platform_str);
        break :blk provider_common.providerIdFromString(platform_str) orelse return error.InvalidJson;
    } else null;

    var workbook = types.WorkbookConfig{
        .id = try alloc.dupe(u8, id),
        .slug = try alloc.dupe(u8, slug),
        .display_name = try alloc.dupe(u8, display_name),
        .profile = try alloc.dupe(u8, profile),
        .repo_paths = repo_paths,
        .db_path = try alloc.dupe(u8, db_path),
        .inbox_dir = try alloc.dupe(u8, inbox_dir),
        .removed_at = try dupOptionalInt(value, "removed_at"),
        .platform = platform,
    };
    errdefer workbook.deinit(alloc);
    workbook.workbook_url = try dupOptionalString(value, "workbook_url", alloc);
    workbook.workbook_label = try dupOptionalString(value, "workbook_label", alloc);
    workbook.credential_ref = try dupOptionalString(value, "credential_ref", alloc);
    workbook.credential_display = try dupOptionalString(value, "credential_display", alloc);
    workbook.google_sheet_id = try dupOptionalString(value, "google_sheet_id", alloc);
    workbook.excel_drive_id = try dupOptionalString(value, "excel_drive_id", alloc);
    workbook.excel_item_id = try dupOptionalString(value, "excel_item_id", alloc);
    workbook.design_bom_sync = try parseDesignBomSync(value, alloc);
    workbook.soup_sync = try parseSoupSync(value, alloc);
    return workbook;
}

fn appendWorkbookJson(buf: *std.ArrayList(u8), workbook: types.WorkbookConfig, alloc: Allocator) !void {
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

fn parseDesignBomSyncKind(value: []const u8) ?types.DesignBomSyncKind {
    if (std.mem.eql(u8, value, "google")) return .google;
    if (std.mem.eql(u8, value, "excel")) return .excel;
    if (std.mem.eql(u8, value, "local_xlsx")) return .local_xlsx;
    return null;
}

fn parseSoupSyncKind(value: []const u8) ?types.SoupSyncKind {
    if (std.mem.eql(u8, value, "google")) return .google;
    if (std.mem.eql(u8, value, "excel")) return .excel;
    if (std.mem.eql(u8, value, "local_xlsx")) return .local_xlsx;
    return null;
}

fn parseDesignBomSync(value: std.json.Value, alloc: Allocator) !?types.DesignBomSyncConfig {
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

fn appendDesignBomSyncJson(buf: *std.ArrayList(u8), design_bom_sync: types.DesignBomSyncConfig, alloc: Allocator) !void {
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

fn parseSoupSync(value: std.json.Value, alloc: Allocator) !?types.SoupSyncConfig {
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

fn appendSoupSyncJson(buf: *std.ArrayList(u8), soup_sync: types.SoupSyncConfig, alloc: Allocator) !void {
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

fn appendJsonStringOpt(buf: *std.ArrayList(u8), value: ?[]const u8, alloc: Allocator) !void {
    if (value) |text| {
        try json_util.appendJsonQuoted(buf, text, alloc);
    } else {
        try buf.appendSlice(alloc, "null");
    }
}

test "save and load roundtrip" {
    var cfg = try bootstrap.bootstrapConfig(testing.allocator, .{
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

test "invalid root JSON type returns InvalidJson" {
    try testing.expectError(error.InvalidJson, loadFromSlice("[]", testing.allocator));
}

test "missing required workbook fields returns InvalidJson" {
    try testing.expectError(error.InvalidJson, loadFromSlice("{\"workbooks\":[{}]}", testing.allocator));
}

test "invalid platform string returns InvalidJson" {
    const json =
        \\{"schema_version":2,"active_workbook_id":null,"workbooks":[{"id":"wb_1","slug":"demo","display_name":"Demo","profile":"generic","repo_paths":[],"db_path":"/tmp/db","inbox_dir":"/tmp/inbox","removed_at":null,"platform":"bogus"}]}
    ;
    try testing.expectError(error.InvalidJson, loadFromSlice(json, testing.allocator));
}

test "invalid sync kinds return InvalidJson" {
    const design_json =
        \\{"schema_version":2,"active_workbook_id":null,"workbooks":[{"id":"wb_1","slug":"demo","display_name":"Demo","profile":"generic","repo_paths":[],"db_path":"/tmp/db","inbox_dir":"/tmp/inbox","design_bom_sync":{"kind":"bogus","display_name":"BOM"}}]}
    ;
    try testing.expectError(error.InvalidJson, loadFromSlice(design_json, testing.allocator));

    const soup_json =
        \\{"schema_version":2,"active_workbook_id":null,"workbooks":[{"id":"wb_1","slug":"demo","display_name":"Demo","profile":"generic","repo_paths":[],"db_path":"/tmp/db","inbox_dir":"/tmp/inbox","soup_sync":{"kind":"bogus","display_name":"SOUP","full_product_identifier":"product://demo"}}]}
    ;
    try testing.expectError(error.InvalidJson, loadFromSlice(soup_json, testing.allocator));
}

test "save JSON includes null for nullable fields" {
    var cfg = try bootstrap.bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    const json = try toJson(&cfg, testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"workbook_url\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"design_bom_sync\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"soup_sync\":null") != null);
}

test "roundtrip preserves soup_sync optional fields" {
    var cfg = try bootstrap.bootstrapConfig(testing.allocator, .{});
    defer cfg.deinit(testing.allocator);
    cfg.workbooks[0].soup_sync = .{
        .kind = .local_xlsx,
        .enabled = true,
        .display_name = try testing.allocator.dupe(u8, "SOUP Workbook"),
        .bom_name = try testing.allocator.dupe(u8, "Main"),
        .full_product_identifier = try testing.allocator.dupe(u8, "product://demo"),
        .local_xlsx_path = try testing.allocator.dupe(u8, "/tmp/soup.xlsx"),
        .last_sync_at = 456,
        .last_error = try testing.allocator.dupe(u8, "none"),
    };
    const json = try toJson(&cfg, testing.allocator);
    defer testing.allocator.free(json);
    var loaded = try loadFromSlice(json, testing.allocator);
    defer loaded.deinit(testing.allocator);
    try testing.expect(loaded.workbooks[0].soup_sync != null);
    try testing.expectEqual(types.SoupSyncKind.local_xlsx, loaded.workbooks[0].soup_sync.?.kind);
    try testing.expectEqualStrings("Main", loaded.workbooks[0].soup_sync.?.bom_name.?);
    try testing.expectEqualStrings("/tmp/soup.xlsx", loaded.workbooks[0].soup_sync.?.local_xlsx_path.?);
    try testing.expectEqual(@as(i64, 456), loaded.workbooks[0].soup_sync.?.last_sync_at);
}

test "workbook config roundtrips optional design bom sync" {
    var cfg = try bootstrap.bootstrapConfig(testing.allocator, .{});
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
    try testing.expectEqual(types.DesignBomSyncKind.local_xlsx, loaded.workbooks[0].design_bom_sync.?.kind);
    try testing.expectEqualStrings("/tmp/design-bom.xlsx", loaded.workbooks[0].design_bom_sync.?.local_xlsx_path.?);
    try testing.expectEqual(@as(i64, 123), loaded.workbooks[0].design_bom_sync.?.last_sync_at);
}
