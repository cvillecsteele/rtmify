const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("license_types.zig");

pub const ProviderFailure = struct {
    code: types.LicenseDetailCode,
    message: []const u8,

    pub fn deinit(self: *ProviderFailure, alloc: Allocator) void {
        alloc.free(self.message);
        self.* = undefined;
    }
};

pub const VerifyOutcome = union(enum) {
    valid: types.LicensePayload,
    expired: types.LicensePayload,
    invalid: ProviderFailure,
    tampered: ProviderFailure,

    pub fn deinit(self: *VerifyOutcome, alloc: Allocator) void {
        switch (self.*) {
            .valid => |*payload| payload.deinit(alloc),
            .expired => |*payload| payload.deinit(alloc),
            .invalid => |*failure| failure.deinit(alloc),
            .tampered => |*failure| failure.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        verifyEnvelope: *const fn (ctx: *anyopaque, alloc: Allocator, envelope: *const types.LicenseEnvelope, product: types.LicenseProduct, now: i64) VerifyOutcome,
        deinit: *const fn (ctx: *anyopaque, alloc: Allocator) void,
    };

    pub fn verifyEnvelope(self: Provider, alloc: Allocator, envelope: *const types.LicenseEnvelope, product: types.LicenseProduct, now: i64) VerifyOutcome {
        return self.vtable.verifyEnvelope(self.ctx, alloc, envelope, product, now);
    }

    pub fn deinit(self: Provider, alloc: Allocator) void {
        self.vtable.deinit(self.ctx, alloc);
    }
};
