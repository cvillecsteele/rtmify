const std = @import("std");
const Allocator = std.mem.Allocator;
const provider_mod = @import("license_provider.zig");
const types = @import("license_types.zig");
const license_file = @import("license_file.zig");

pub const Config = struct {
    hmac_key: []const u8,
};

const HmacProviderCtx = struct {
    hmac_key: []const u8,
};

pub fn create(alloc: Allocator, cfg: Config) !provider_mod.Provider {
    const ctx = try alloc.create(HmacProviderCtx);
    ctx.* = .{
        .hmac_key = try alloc.dupe(u8, cfg.hmac_key),
    };
    return .{
        .ctx = ctx,
        .vtable = &vtable,
    };
}

fn failure(alloc: Allocator, code: types.LicenseDetailCode, message: []const u8) provider_mod.ProviderFailure {
    return .{
        .code = code,
        .message = alloc.dupe(u8, message) catch unreachable,
    };
}

fn verifyEnvelope(ctx_ptr: *anyopaque, alloc: Allocator, envelope: *const types.LicenseEnvelope, product: types.LicenseProduct, now: i64) provider_mod.VerifyOutcome {
    const ctx: *HmacProviderCtx = @ptrCast(@alignCast(ctx_ptr));

    if (envelope.payload.schema != 1) {
        return .{ .invalid = failure(alloc, .unsupported_schema, "unsupported license schema") };
    }
    if (envelope.payload.product != product) {
        return .{ .invalid = failure(alloc, .wrong_product, "license is for a different product") };
    }
    const ok = license_file.verifyEnvelope(alloc, envelope, ctx.hmac_key) catch {
        return .{ .invalid = failure(alloc, .internal_error, "failed to verify license") };
    };
    if (!ok) {
        return .{ .tampered = failure(alloc, .bad_signature, "license signature does not match payload") };
    }
    const payload = envelope.payload.clone(alloc) catch {
        return .{ .invalid = failure(alloc, .internal_error, "failed to copy license payload") };
    };
    if (payload.expires_at) |expires_at| {
        if (now > expires_at) {
            return .{ .expired = payload };
        }
    }
    return .{ .valid = payload };
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *HmacProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    alloc.free(ctx.hmac_key);
    alloc.destroy(ctx);
}

const vtable = provider_mod.Provider.VTable{
    .verifyEnvelope = verifyEnvelope,
    .deinit = deinit,
};
