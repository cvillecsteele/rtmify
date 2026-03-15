const std = @import("std");
const Allocator = std.mem.Allocator;

const json_util = @import("../json_util.zig");
const provider_common = @import("../provider_common.zig");
const workbook_paths = @import("paths.zig");

pub const WorkbookConfig = struct {
    id: []const u8,
    slug: []const u8,
    display_name: []const u8,
    profile: []const u8,
    repo_paths: []const []const u8,
    db_path: []const u8,
    inbox_dir: []const u8,
    platform: ?provider_common.ProviderId = null,
    workbook_url: ?[]const u8 = null,
    workbook_label: ?[]const u8 = null,
    credential_ref: ?[]const u8 = null,
    credential_display: ?[]const u8 = null,
    google_sheet_id: ?[]const u8 = null,
    excel_drive_id: ?[]const u8 = null,
    excel_item_id: ?[]const u8 = null,

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
    }

    pub fn clone(self: WorkbookConfig, alloc: Allocator) !WorkbookConfig {
        const repo_paths = try cloneStringSlice(self.repo_paths, alloc);
        errdefer {
            for (repo_paths) |path| alloc.free(path);
            alloc.free(repo_paths);
        }
        return .{
            .id = try alloc.dupe(u8, self.id),
            .slug = try alloc.dupe(u8, self.slug),
            .display_name = try alloc.dupe(u8, self.display_name),
            .profile = try alloc.dupe(u8, self.profile),
            .repo_paths = repo_paths,
            .db_path = try alloc.dupe(u8, self.db_path),
            .inbox_dir = try alloc.dupe(u8, self.inbox_dir),
            .platform = self.platform,
            .workbook_url = if (self.workbook_url) |v| try alloc.dupe(u8, v) else null,
            .workbook_label = if (self.workbook_label) |v| try alloc.dupe(u8, v) else null,
            .credential_ref = if (self.credential_ref) |v| try alloc.dupe(u8, v) else null,
            .credential_display = if (self.credential_display) |v| try alloc.dupe(u8, v) else null,
            .google_sheet_id = if (self.google_sheet_id) |v| try alloc.dupe(u8, v) else null,
            .excel_drive_id = if (self.excel_drive_id) |v| try alloc.dupe(u8, v) else null,
            .excel_item_id = if (self.excel_item_id) |v| try alloc.dupe(u8, v) else null,
        };
    }
};

pub const LiveConfig = struct {
    schema_version: u32 = 1,
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
            try save(&cfg, alloc);
            return cfg;
        },
        else => return err,
    };
    defer alloc.free(bytes);
    return loadFromSlice(bytes, alloc);
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
    replaceOptionalString(&workbook.workbook_url, validated.workbook_url, alloc);
    replaceOptionalString(&workbook.workbook_label, validated.workbook_label, alloc);
    replaceOptionalString(&workbook.credential_ref, credential_ref, alloc);
    replaceOptionalStringOpt(&workbook.credential_display, validated.credential_display, alloc);

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
            replaceOptionalString(&workbook.google_sheet_id, google.sheet_id, alloc);
            clearOptionalString(&workbook.excel_drive_id, alloc);
            clearOptionalString(&workbook.excel_item_id, alloc);
        },
        .excel => |excel| {
            replaceOptionalString(&workbook.excel_drive_id, excel.drive_id, alloc);
            replaceOptionalString(&workbook.excel_item_id, excel.item_id, alloc);
            clearOptionalString(&workbook.google_sheet_id, alloc);
        },
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
        .schema_version = 1,
        .active_workbook_id = try alloc.dupe(u8, id),
        .workbooks = workbooks,
    };
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
        .platform = platform,
        .workbook_url = try dupOptionalString(value, "workbook_url", alloc),
        .workbook_label = try dupOptionalString(value, "workbook_label", alloc),
        .credential_ref = try dupOptionalString(value, "credential_ref", alloc),
        .credential_display = try dupOptionalString(value, "credential_display", alloc),
        .google_sheet_id = try dupOptionalString(value, "google_sheet_id", alloc),
        .excel_drive_id = try dupOptionalString(value, "excel_drive_id", alloc),
        .excel_item_id = try dupOptionalString(value, "excel_item_id", alloc),
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

fn cloneStringSlice(values: []const []const u8, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, values.len);
    errdefer alloc.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try alloc.dupe(u8, value);
    }
    return out;
}

fn replaceOptionalString(dst: *?[]const u8, src: []const u8, alloc: Allocator) void {
    clearOptionalString(dst, alloc);
    dst.* = alloc.dupe(u8, src) catch @panic("OOM");
}

fn replaceOptionalStringOpt(dst: *?[]const u8, src: ?[]const u8, alloc: Allocator) void {
    clearOptionalString(dst, alloc);
    if (src) |value| dst.* = alloc.dupe(u8, value) catch @panic("OOM");
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
