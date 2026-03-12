const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("license_types.zig");

pub const ProviderEntitlement = struct {
    active: bool,
    revoked: bool,
    invalid_key: bool,
    expires_at: ?i64,
    provider_instance_id: ?[]const u8,
    provider_payload_json: []const u8,

    pub fn deinit(self: *ProviderEntitlement, alloc: Allocator) void {
        if (self.provider_instance_id) |value| alloc.free(value);
        alloc.free(self.provider_payload_json);
        self.* = undefined;
    }
};

pub const ProviderFailure = struct {
    code: types.LicenseDetailCode,
    message: []const u8,

    pub fn deinit(self: *ProviderFailure, alloc: Allocator) void {
        alloc.free(self.message);
        self.* = undefined;
    }
};

pub const ActivateOutcome = union(enum) {
    success: ProviderEntitlement,
    failure: ProviderFailure,

    pub fn deinit(self: *ActivateOutcome, alloc: Allocator) void {
        switch (self.*) {
            .success => |*value| value.deinit(alloc),
            .failure => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const ValidateOutcome = union(enum) {
    success: ProviderEntitlement,
    failure: ProviderFailure,

    pub fn deinit(self: *ValidateOutcome, alloc: Allocator) void {
        switch (self.*) {
            .success => |*value| value.deinit(alloc),
            .failure => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const DeactivateOutcome = union(enum) {
    success: void,
    failure: ProviderFailure,

    pub fn deinit(self: *DeactivateOutcome, alloc: Allocator) void {
        switch (self.*) {
            .success => {},
            .failure => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    provider_id: []const u8,

    pub const VTable = struct {
        activate: *const fn (ctx: *anyopaque, alloc: Allocator, license_key: []const u8, fingerprint: []const u8) ActivateOutcome,
        validate: *const fn (ctx: *anyopaque, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) ValidateOutcome,
        deactivate: *const fn (ctx: *anyopaque, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) DeactivateOutcome,
        deinit: *const fn (ctx: *anyopaque, alloc: Allocator) void,
    };

    pub fn activate(self: Provider, alloc: Allocator, license_key: []const u8, fingerprint: []const u8) ActivateOutcome {
        return self.vtable.activate(self.ctx, alloc, license_key, fingerprint);
    }

    pub fn validate(self: Provider, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) ValidateOutcome {
        return self.vtable.validate(self.ctx, alloc, record, fingerprint);
    }

    pub fn deactivate(self: Provider, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) DeactivateOutcome {
        return self.vtable.deactivate(self.ctx, alloc, record, fingerprint);
    }

    pub fn deinit(self: Provider, alloc: Allocator) void {
        self.vtable.deinit(self.ctx, alloc);
    }
};

