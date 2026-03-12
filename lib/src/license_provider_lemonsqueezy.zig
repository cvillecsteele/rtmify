const std = @import("std");
const Allocator = std.mem.Allocator;
const support = @import("license_support.zig");
const provider_mod = @import("license_provider.zig");
const types = @import("license_types.zig");

pub const Config = struct {
    activate_url: []const u8 = "https://api.lemonsqueezy.com/v1/licenses/activate",
    validate_url: []const u8 = "https://api.lemonsqueezy.com/v1/licenses/validate",
    deactivate_url: []const u8 = "https://api.lemonsqueezy.com/v1/licenses/deactivate",
    http_client: support.HttpClient,
};

const ProviderCtx = struct {
    cfg: Config,
};

pub fn create(alloc: Allocator, cfg: Config) !provider_mod.Provider {
    const ctx = try alloc.create(ProviderCtx);
    ctx.* = .{ .cfg = cfg };
    return .{
        .ctx = ctx,
        .vtable = &vtable,
        .provider_id = "lemonsqueezy",
    };
}

fn dupMessage(alloc: Allocator, msg: []const u8) []const u8 {
    return alloc.dupe(u8, msg) catch unreachable;
}

fn failure(alloc: Allocator, code: types.LicenseDetailCode, message: []const u8) provider_mod.ProviderFailure {
    return .{
        .code = code,
        .message = dupMessage(alloc, message),
    };
}

fn isLikelyInvalidKey(msg: ?[]const u8) bool {
    const text = msg orelse return false;
    return std.ascii.indexOfIgnoreCase(text, "invalid") != null or
        std.ascii.indexOfIgnoreCase(text, "not found") != null;
}

fn isLikelyRevoked(status: ?[]const u8, msg: ?[]const u8) bool {
    if (status) |value| {
        if (std.ascii.indexOfIgnoreCase(value, "disabled") != null or
            std.ascii.indexOfIgnoreCase(value, "expired") != null or
            std.ascii.indexOfIgnoreCase(value, "inactive") != null)
        {
            return true;
        }
    }
    if (msg) |text| {
        return std.ascii.indexOfIgnoreCase(text, "revoked") != null or
            std.ascii.indexOfIgnoreCase(text, "expired") != null or
            std.ascii.indexOfIgnoreCase(text, "disabled") != null;
    }
    return false;
}

fn parseTimestamp(text: ?[]const u8) ?i64 {
    const raw = text orelse return null;
    if (raw.len == 0) return null;
    if (raw.len >= 10) {
        const year = std.fmt.parseInt(i64, raw[0..4], 10) catch return null;
        const month = std.fmt.parseInt(u8, raw[5..7], 10) catch return null;
        const day = std.fmt.parseInt(u8, raw[8..10], 10) catch return null;
        return civilToUnixDays(year, month, day) * 24 * 60 * 60;
    }
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

fn civilToUnixDays(year: i64, month: u8, day: u8) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const month_adjust: i64 = if (m > 2) -3 else 9;
    const doy = @divFloor(153 * (m + month_adjust) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const ActivateResponse = struct {
    activated: ?bool = null,
    @"error": ?[]const u8 = null,
    license_key: ?struct {
        status: ?[]const u8 = null,
    } = null,
};

const ValidateResponse = struct {
    valid: ?bool = null,
    @"error": ?[]const u8 = null,
    license_key: ?struct {
        status: ?[]const u8 = null,
    } = null,
    meta: ?struct {
        instance: ?struct {
            id: ?[]const u8 = null,
            name: ?[]const u8 = null,
        } = null,
        license_key: ?struct {
            expires_at: ?[]const u8 = null,
        } = null,
    } = null,
};

const DeactivateResponse = struct {
    deactivated: ?bool = null,
    @"error": ?[]const u8 = null,
};

fn post(ctx: *ProviderCtx, alloc: Allocator, url: []const u8, body: []const u8) !support.HttpResponse {
    return ctx.cfg.http_client.postForm(alloc, url, body);
}

fn validateWithRequest(ctx: *ProviderCtx, alloc: Allocator, license_key: []const u8, fingerprint: []const u8, provider_instance_id: ?[]const u8) provider_mod.ValidateOutcome {
    _ = provider_instance_id;
    const body = std.fmt.allocPrint(alloc, "license_key={s}&instance_name={s}", .{ license_key, fingerprint }) catch |err| {
        return .{ .failure = failure(alloc, .internal_error, @errorName(err)) };
    };
    defer alloc.free(body);

    const response = post(ctx, alloc, ctx.cfg.validate_url, body) catch {
        return .{ .failure = failure(alloc, .network_error, "provider unavailable") };
    };
    defer {
        var owned = response;
        owned.deinit(alloc);
    }

    if (response.status_code >= 500) {
        return .{ .failure = failure(alloc, .server_error, "license server error") };
    }
    if (response.status_code >= 400) {
        return .{ .failure = failure(alloc, .invalid_key, "license validation failed") };
    }

    var parsed = std.json.parseFromSlice(ValidateResponse, alloc, response.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return .{ .failure = failure(alloc, .protocol_error, "invalid provider response") };
    };
    defer parsed.deinit();

    const status = if (parsed.value.license_key) |value| value.status else null;
    const err_msg = parsed.value.@"error";
    if (parsed.value.valid != true) {
        if (isLikelyInvalidKey(err_msg)) return .{ .failure = failure(alloc, .invalid_key, err_msg orelse "invalid key") };
        if (isLikelyRevoked(status, err_msg)) return .{ .failure = failure(alloc, .revoked, err_msg orelse "revoked") };
        return .{ .failure = failure(alloc, .server_error, err_msg orelse "validation failed") };
    }

    const instance_id = if (parsed.value.meta) |meta| blk: {
        if (meta.instance) |instance| {
            if (instance.id) |value| break :blk alloc.dupe(u8, value) catch unreachable;
            if (instance.name) |value| break :blk alloc.dupe(u8, value) catch unreachable;
        }
        break :blk null;
    } else null;

    return .{
        .success = .{
            .active = true,
            .revoked = false,
            .invalid_key = false,
            .expires_at = if (parsed.value.meta) |meta|
                if (meta.license_key) |value| parseTimestamp(value.expires_at) else null
            else
                null,
            .provider_instance_id = instance_id,
            .provider_payload_json = alloc.dupe(u8, response.body) catch unreachable,
        },
    };
}

fn activate(ctx_ptr: *anyopaque, alloc: Allocator, license_key: []const u8, fingerprint: []const u8) provider_mod.ActivateOutcome {
    const ctx: *ProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    const body = std.fmt.allocPrint(alloc, "license_key={s}&instance_name={s}", .{ license_key, fingerprint }) catch |err| {
        return .{ .failure = failure(alloc, .internal_error, @errorName(err)) };
    };
    defer alloc.free(body);

    const response = post(ctx, alloc, ctx.cfg.activate_url, body) catch {
        return .{ .failure = failure(alloc, .network_error, "provider unavailable") };
    };
    defer {
        var owned = response;
        owned.deinit(alloc);
    }

    if (response.status_code >= 500) return .{ .failure = failure(alloc, .server_error, "license server error") };
    if (response.status_code >= 400) return .{ .failure = failure(alloc, .invalid_key, "license activation failed") };

    var parsed = std.json.parseFromSlice(ActivateResponse, alloc, response.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return .{ .failure = failure(alloc, .protocol_error, "invalid provider response") };
    };
    defer parsed.deinit();

    const status = if (parsed.value.license_key) |value| value.status else null;
    if (parsed.value.activated != true) {
        if (isLikelyInvalidKey(parsed.value.@"error")) return .{ .failure = failure(alloc, .invalid_key, parsed.value.@"error" orelse "invalid key") };
        if (isLikelyRevoked(status, parsed.value.@"error")) return .{ .failure = failure(alloc, .revoked, parsed.value.@"error" orelse "revoked") };
        return .{ .failure = failure(alloc, .server_error, parsed.value.@"error" orelse "activation failed") };
    }

    var validated = validateWithRequest(ctx, alloc, license_key, fingerprint, null);
    defer if (validated == .failure) validated.deinit(alloc);
    return switch (validated) {
        .success => |entitlement| .{ .success = entitlement },
        .failure => |err| .{ .failure = err },
    };
}

fn validate(ctx_ptr: *anyopaque, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) provider_mod.ValidateOutcome {
    const ctx: *ProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    return validateWithRequest(ctx, alloc, record.license_key, fingerprint, record.provider_instance_id);
}

fn deactivate(ctx_ptr: *anyopaque, alloc: Allocator, record: *const types.CacheRecord, fingerprint: []const u8) provider_mod.DeactivateOutcome {
    const ctx: *ProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    const body = std.fmt.allocPrint(alloc, "license_key={s}&instance_name={s}", .{ record.license_key, fingerprint }) catch |err| {
        return .{ .failure = failure(alloc, .internal_error, @errorName(err)) };
    };
    defer alloc.free(body);

    const response = post(ctx, alloc, ctx.cfg.deactivate_url, body) catch {
        return .{ .failure = failure(alloc, .network_error, "provider unavailable") };
    };
    defer {
        var owned = response;
        owned.deinit(alloc);
    }

    if (response.status_code >= 500) return .{ .failure = failure(alloc, .server_error, "license server error") };

    var parsed = std.json.parseFromSlice(DeactivateResponse, alloc, response.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return .success;
    };
    defer parsed.deinit();

    if (parsed.value.deactivated == false and parsed.value.@"error" != null) {
        return .{ .failure = failure(alloc, .server_error, parsed.value.@"error".?) };
    }
    return .success;
}

fn deinit(ctx_ptr: *anyopaque, alloc: Allocator) void {
    const ctx: *ProviderCtx = @ptrCast(@alignCast(ctx_ptr));
    alloc.destroy(ctx);
}

const vtable = provider_mod.Provider.VTable{
    .activate = activate,
    .validate = validate,
    .deactivate = deactivate,
    .deinit = deinit,
};
