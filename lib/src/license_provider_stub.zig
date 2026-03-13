const std = @import("std");
const Allocator = std.mem.Allocator;
const provider_mod = @import("license_provider.zig");
const types = @import("license_types.zig");

pub const StubAction = enum {
    valid,
    expired,
    invalid,
    tampered,
};

pub const CallLog = struct {
    verify_calls: usize = 0,
};

pub const StubConfig = struct {
    verify_result: StubAction = .valid,
    detail_code: types.LicenseDetailCode = .none,
    expires_at: ?i64 = null,
    call_log: ?*CallLog = null,
};

const StubProviderCtx = struct {
    cfg: StubConfig,
};

pub fn create(alloc: Allocator, cfg: StubConfig) !provider_mod.Provider {
    const ctx = try alloc.create(StubProviderCtx);
    ctx.* = .{ .cfg = cfg };
    return .{
        .ctx = ctx,
        .vtable = &vtable,
    };
}

fn makePayload(alloc: Allocator, product: types.LicenseProduct, cfg: StubConfig) types.LicensePayload {
    return .{
        .schema = 1,
        .license_id = alloc.dupe(u8, "STUB-2026-0001") catch unreachable,
        .product = product,
        .tier = .individual,
        .issued_to = alloc.dupe(u8, "stub@example.com") catch unreachable,
        .issued_at = 1,
        .expires_at = cfg.expires_at,
        .org = alloc.dupe(u8, "Stub Org") catch unreachable,
    };
}

fn makeFailure(alloc: Allocator, code: types.LicenseDetailCode, message: []const u8) provider_mod.ProviderFailure {
    return .{
        .code = code,
        .message = alloc.dupe(u8, message) catch unreachable,
    };
}

fn verifyEnvelope(ctx_ptr: *anyopaque, alloc: Allocator, envelope: *const types.LicenseEnvelope, product: types.LicenseProduct, now: i64) provider_mod.VerifyOutcome {
    _ = envelope;
    _ = now;
    const ctx: *StubProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.cfg.call_log) |log| log.verify_calls += 1;
    return switch (ctx.cfg.verify_result) {
        .valid => .{ .valid = makePayload(alloc, product, ctx.cfg) },
        .expired => .{ .expired = makePayload(alloc, product, ctx.cfg) },
        .invalid => .{ .invalid = makeFailure(alloc, if (ctx.cfg.detail_code == .none) .invalid_json else ctx.cfg.detail_code, "invalid stub license") },
        .tampered => .{ .tampered = makeFailure(alloc, if (ctx.cfg.detail_code == .none) .bad_signature else ctx.cfg.detail_code, "tampered stub license") },
    };
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *StubProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    alloc.destroy(ctx);
}

const vtable = provider_mod.Provider.VTable{
    .verifyEnvelope = verifyEnvelope,
    .deinit = deinit,
};
