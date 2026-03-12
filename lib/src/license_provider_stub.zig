const std = @import("std");
const Allocator = std.mem.Allocator;
const provider_mod = @import("license_provider.zig");
const types = @import("license_types.zig");

pub const StubAction = enum {
    success,
    invalid_key,
    revoked,
    provider_unavailable,
    protocol_error,
};

pub const CallLog = struct {
    activate_calls: usize = 0,
    validate_calls: usize = 0,
    deactivate_calls: usize = 0,
};

pub const StubConfig = struct {
    activate_result: StubAction = .success,
    validate_result: StubAction = .success,
    deactivate_result: StubAction = .success,
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
        .provider_id = "stub",
    };
}

fn makeFailure(alloc: Allocator, action: StubAction) provider_mod.ProviderFailure {
    const msg, const code = switch (action) {
        .invalid_key => .{ "invalid key", types.LicenseDetailCode.invalid_key },
        .revoked => .{ "revoked", types.LicenseDetailCode.revoked },
        .provider_unavailable => .{ "provider unavailable", types.LicenseDetailCode.network_error },
        .protocol_error => .{ "protocol error", types.LicenseDetailCode.protocol_error },
        .success => .{ "ok", types.LicenseDetailCode.none },
    };
    return .{
        .code = code,
        .message = alloc.dupe(u8, msg) catch unreachable,
    };
}

fn makeEntitlement(alloc: Allocator, cfg: StubConfig) provider_mod.ProviderEntitlement {
    return .{
        .active = true,
        .revoked = false,
        .invalid_key = false,
        .expires_at = cfg.expires_at,
        .provider_instance_id = alloc.dupe(u8, "stub-instance") catch unreachable,
        .provider_payload_json = alloc.dupe(u8, "{\"provider\":\"stub\"}") catch unreachable,
    };
}

fn activate(ctx_ptr: *anyopaque, alloc: Allocator, license_key: []const u8, fingerprint: []const u8) provider_mod.ActivateOutcome {
    _ = license_key;
    _ = fingerprint;
    const ctx: *StubProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.cfg.call_log) |log| log.activate_calls += 1;
    return switch (ctx.cfg.activate_result) {
        .success => .{ .success = makeEntitlement(alloc, ctx.cfg) },
        else => .{ .failure = makeFailure(alloc, ctx.cfg.activate_result) },
    };
}

fn validate(ctx_ptr: *anyopaque, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) provider_mod.ValidateOutcome {
    _ = record;
    _ = fingerprint;
    const ctx: *StubProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.cfg.call_log) |log| log.validate_calls += 1;
    return switch (ctx.cfg.validate_result) {
        .success => .{ .success = makeEntitlement(alloc, ctx.cfg) },
        else => .{ .failure = makeFailure(alloc, ctx.cfg.validate_result) },
    };
}

fn deactivate(ctx_ptr: *anyopaque, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) provider_mod.DeactivateOutcome {
    _ = record;
    _ = fingerprint;
    const ctx: *StubProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.cfg.call_log) |log| log.deactivate_calls += 1;
    return switch (ctx.cfg.deactivate_result) {
        .success => .success,
        else => .{ .failure = makeFailure(alloc, ctx.cfg.deactivate_result) },
    };
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *StubProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    alloc.destroy(ctx);
}

const vtable = provider_mod.Provider.VTable{
    .activate = activate,
    .validate = validate,
    .deactivate = deactivate,
    .deinit = deinit,
};

