const std = @import("std");
const Allocator = std.mem.Allocator;

const common = @import("provider_common.zig");
const provider_google = @import("provider_google.zig");
const provider_excel = @import("provider_excel.zig");

pub const ProviderId = common.ProviderId;
pub const Target = common.Target;
pub const ActiveConnection = common.ActiveConnection;
pub const DraftConnection = common.DraftConnection;
pub const CredentialValidation = common.CredentialValidation;
pub const WorkbookValidation = common.WorkbookValidation;
pub const ValidatedDraft = common.ValidatedDraft;
pub const TabRef = common.TabRef;
pub const ValueUpdate = common.ValueUpdate;
pub const RowFormat = common.RowFormat;
pub const providerIdString = common.providerIdString;
pub const providerIdFromString = common.providerIdFromString;
pub const freeTabRefs = common.freeTabRefs;
pub const freeRows = common.freeRows;

pub const ProviderRuntime = union(common.ProviderId) {
    google: provider_google.Runtime,
    excel: provider_excel.Runtime,

    pub fn init(active: common.ActiveConnection, alloc: Allocator) !ProviderRuntime {
        return switch (active.platform) {
            .google => .{ .google = try provider_google.Runtime.init(active, alloc) },
            .excel => .{ .excel = try provider_excel.Runtime.init(active, alloc) },
        };
    }

    pub fn changeToken(self: *ProviderRuntime, alloc: Allocator) ![]const u8 {
        return switch (self.*) {
            .google => |*runtime| runtime.changeToken(alloc),
            .excel => |*runtime| runtime.changeToken(alloc),
        };
    }

    pub fn listTabs(self: *ProviderRuntime, alloc: Allocator) ![]common.TabRef {
        return switch (self.*) {
            .google => |*runtime| runtime.listTabs(alloc),
            .excel => |*runtime| runtime.listTabs(alloc),
        };
    }

    pub fn readRows(self: *ProviderRuntime, tab_title: []const u8, alloc: Allocator) ![][][]const u8 {
        return switch (self.*) {
            .google => |*runtime| runtime.readRows(tab_title, alloc),
            .excel => |*runtime| runtime.readRows(tab_title, alloc),
        };
    }

    pub fn batchWriteValues(self: *ProviderRuntime, updates: []const common.ValueUpdate, alloc: Allocator) !void {
        return switch (self.*) {
            .google => |*runtime| runtime.batchWriteValues(updates, alloc),
            .excel => |*runtime| runtime.batchWriteValues(updates, alloc),
        };
    }

    pub fn applyRowFormats(self: *ProviderRuntime, reqs: []const common.RowFormat, alloc: Allocator) !void {
        return switch (self.*) {
            .google => |*runtime| runtime.applyRowFormats(reqs, alloc),
            .excel => |*runtime| runtime.applyRowFormats(reqs, alloc),
        };
    }

    pub fn createTab(self: *ProviderRuntime, title: []const u8, alloc: Allocator) !void {
        return switch (self.*) {
            .google => |*runtime| runtime.createTab(title, alloc),
            .excel => |*runtime| runtime.createTab(title, alloc),
        };
    }

    pub fn deinit(self: *ProviderRuntime, alloc: Allocator) void {
        switch (self.*) {
            .google => |*runtime| runtime.deinit(alloc),
            .excel => |*runtime| runtime.deinit(alloc),
        }
    }
};
