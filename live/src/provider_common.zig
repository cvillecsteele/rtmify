const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ProviderId = enum { google, excel };

pub fn providerIdString(id: ProviderId) []const u8 {
    return @tagName(id);
}

pub fn providerIdFromString(s: []const u8) ?ProviderId {
    if (std.mem.eql(u8, s, "google")) return .google;
    if (std.mem.eql(u8, s, "excel")) return .excel;
    return null;
}

pub const Target = union(ProviderId) {
    google: struct {
        sheet_id: []const u8,
    },
    excel: struct {
        drive_id: []const u8,
        item_id: []const u8,
    },
};

pub const ActiveConnection = struct {
    platform: ProviderId,
    credential_json: []const u8,
    workbook_url: []const u8,
    workbook_label: []const u8,
    credential_display: ?[]const u8,
    target: Target,

    pub fn clone(self: ActiveConnection, alloc: Allocator) !ActiveConnection {
        return .{
            .platform = self.platform,
            .credential_json = try alloc.dupe(u8, self.credential_json),
            .workbook_url = try alloc.dupe(u8, self.workbook_url),
            .workbook_label = try alloc.dupe(u8, self.workbook_label),
            .credential_display = if (self.credential_display) |v| try alloc.dupe(u8, v) else null,
            .target = switch (self.target) {
                .google => |g| .{ .google = .{ .sheet_id = try alloc.dupe(u8, g.sheet_id) } },
                .excel => |e| .{ .excel = .{ .drive_id = try alloc.dupe(u8, e.drive_id), .item_id = try alloc.dupe(u8, e.item_id) } },
            },
        };
    }

    pub fn deinit(self: *ActiveConnection, alloc: Allocator) void {
        alloc.free(self.credential_json);
        alloc.free(self.workbook_url);
        alloc.free(self.workbook_label);
        if (self.credential_display) |v| alloc.free(v);
        switch (self.target) {
            .google => |g| alloc.free(g.sheet_id),
            .excel => |e| {
                alloc.free(e.drive_id);
                alloc.free(e.item_id);
            },
        }
    }
};

pub const ConnectionBlockReason = enum {
    legacy_plaintext_credentials,
    secure_storage_unsupported,
    credential_ref_missing,
    secret_not_found,
    secret_store_error,
};

pub const LoadedConnection = union(enum) {
    none,
    active: ActiveConnection,
    blocked: ConnectionBlockReason,

    pub fn deinit(self: *LoadedConnection, alloc: Allocator) void {
        switch (self.*) {
            .active => |*active| active.deinit(alloc),
            else => {},
        }
    }
};

pub const DraftConnection = struct {
    platform: ProviderId,
    profile: ?[]const u8,
    workbook_url: []const u8,
    credentials_json: []const u8,

    pub fn deinit(self: *DraftConnection, alloc: Allocator) void {
        if (self.profile) |v| alloc.free(v);
        alloc.free(self.workbook_url);
        alloc.free(self.credentials_json);
    }
};

pub const CredentialValidation = struct {
    credential_display: ?[]const u8,
};

pub const WorkbookValidation = struct {
    workbook_label: []const u8,
    target: Target,
};

pub const ValidatedDraft = struct {
    platform: ProviderId,
    profile: ?[]const u8,
    credential_json: []const u8,
    workbook_url: []const u8,
    workbook_label: []const u8,
    credential_display: ?[]const u8,
    target: Target,

    pub fn toActive(self: ValidatedDraft) ActiveConnection {
        return .{
            .platform = self.platform,
            .credential_json = self.credential_json,
            .workbook_url = self.workbook_url,
            .workbook_label = self.workbook_label,
            .credential_display = self.credential_display,
            .target = self.target,
        };
    }

    pub fn deinit(self: *ValidatedDraft, alloc: Allocator) void {
        if (self.profile) |v| alloc.free(v);
        var active = self.toActive();
        active.deinit(alloc);
    }
};

pub const TabRef = struct {
    title: []const u8,
    native_id: []const u8,
};

pub fn freeTabRefs(tabs: []TabRef, alloc: Allocator) void {
    for (tabs) |tab| {
        alloc.free(tab.title);
        alloc.free(tab.native_id);
    }
    alloc.free(tabs);
}

pub const ValueUpdate = struct {
    a1_range: []const u8,
    values: []const []const u8,
};

pub const RowFormat = struct {
    tab_title: []const u8,
    row_1based: usize,
    col_start_1based: usize,
    col_end_1based: usize,
    fill_hex: []const u8,
};

pub fn freeRows(rows: [][][]const u8, alloc: Allocator) void {
    for (rows) |row| {
        for (row) |cell| alloc.free(cell);
        alloc.free(row);
    }
    alloc.free(rows);
}

pub fn activeConnectionEqual(a: ActiveConnection, b: ActiveConnection) bool {
    if (a.platform != b.platform) return false;
    if (!std.mem.eql(u8, a.credential_json, b.credential_json)) return false;
    if (!std.mem.eql(u8, a.workbook_url, b.workbook_url)) return false;
    switch (a.target) {
        .google => |ag| switch (b.target) {
            .google => |bg| return std.mem.eql(u8, ag.sheet_id, bg.sheet_id),
            else => return false,
        },
        .excel => |ae| switch (b.target) {
            .excel => |be| return std.mem.eql(u8, ae.drive_id, be.drive_id) and std.mem.eql(u8, ae.item_id, be.item_id),
            else => return false,
        },
    }
}
