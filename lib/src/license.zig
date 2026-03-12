const std = @import("std");
const Allocator = std.mem.Allocator;

pub const license_types = @import("license_types.zig");
pub const license_provider = @import("license_provider.zig");
pub const license_provider_stub = @import("license_provider_stub.zig");
pub const license_provider_lemonsqueezy = @import("license_provider_lemonsqueezy.zig");
pub const license_store = @import("license_store.zig");
pub const license_store_fs = @import("license_store_fs.zig");
pub const license_store_memory = @import("license_store_memory.zig");
pub const license_support = @import("license_support.zig");

pub const LicenseState = license_types.LicenseState;
pub const LicenseDetailCode = license_types.LicenseDetailCode;
pub const LicenseStatus = license_types.LicenseStatus;
pub const ActivationRequest = license_types.ActivationRequest;
pub const OperationResult = license_types.OperationResult;
pub const CacheRecord = license_types.CacheRecord;
pub const Provider = license_provider.Provider;
pub const Store = license_store.Store;
pub const StubConfig = license_provider_stub.StubConfig;

pub const DEV_KEY = "RTMIFY-DEV-0000-0000";
pub const GRACE_PERIOD_SECS: i64 = 30 * 24 * 60 * 60;
pub const REVALIDATION_INTERVAL_SECS: i64 = 7 * 24 * 60 * 60;
pub const REVALIDATION_GRACE_SECS: i64 = 30 * 24 * 60 * 60;

pub const ServiceDeps = struct {
    provider: Provider,
    store: Store,
    clock: license_support.Clock,
    fingerprint_source: license_support.FingerprintSource,
};

pub const DefaultOptions = struct {
    dir: ?[]const u8 = null,
    now: ?i64 = null,
    clock: ?license_support.Clock = null,
    fingerprint_source: ?license_support.FingerprintSource = null,
    http_client: ?license_support.HttpClient = null,
};

pub const Service = struct {
    deps: ServiceDeps,
    owns_provider: bool = false,
    owns_store: bool = false,
    owned_clock_state: ?*license_support.FixedClockState = null,

    pub fn deinit(self: *Service, alloc: Allocator) void {
        if (self.owns_provider) self.deps.provider.deinit(alloc);
        if (self.owns_store) self.deps.store.deinit(alloc);
        if (self.owned_clock_state) |state| alloc.destroy(state);
        self.* = undefined;
    }

    pub fn getStatus(self: *Service, alloc: Allocator) !LicenseStatus {
        return self.getStatusImpl(alloc, false);
    }

    pub fn activate(self: *Service, alloc: Allocator, req: ActivationRequest) !OperationResult {
        const now = self.deps.clock.now();
        const fingerprint = try self.deps.fingerprint_source.currentFingerprint(alloc);
        defer alloc.free(fingerprint);

        if (std.mem.eql(u8, req.license_key, DEV_KEY)) {
            const record = try buildDevRecord(alloc, self.deps.provider.provider_id, req.license_key, fingerprint, now);
            defer {
                var owned = record;
                owned.deinit(alloc);
            }
            try self.deps.store.write(alloc, record);
            const status = try self.getStatusImpl(alloc, false);
            return .{ .status = status };
        }

        var outcome = self.deps.provider.activate(alloc, req.license_key, fingerprint);
        defer outcome.deinit(alloc);
        switch (outcome) {
            .failure => |err| {
                setLastProviderError(err.message);
                return .{ .status = try statusForFailure(alloc, self.deps.provider.provider_id, err.code, err.message) };
            },
            .success => |entitlement| {
                if (!entitlement.active or entitlement.invalid_key) {
                    return .{ .status = try statusForFailure(alloc, self.deps.provider.provider_id, .invalid_key, "invalid key") };
                }
                if (entitlement.revoked) {
                    return .{ .status = try statusForFailure(alloc, self.deps.provider.provider_id, .revoked, "revoked") };
                }
                const record = CacheRecord{
                    .schema_version = 2,
                    .provider_id = try alloc.dupe(u8, self.deps.provider.provider_id),
                    .license_key = try alloc.dupe(u8, req.license_key),
                    .fingerprint = try alloc.dupe(u8, fingerprint),
                    .activated_at = now,
                    .expires_at = entitlement.expires_at,
                    .last_validated_at = now,
                    .provider_instance_id = if (entitlement.provider_instance_id) |value| try alloc.dupe(u8, value) else null,
                    .provider_payload_json = try alloc.dupe(u8, entitlement.provider_payload_json),
                };
                defer {
                    var owned = record;
                    owned.deinit(alloc);
                }
                try self.deps.store.write(alloc, record);
                const status = try self.getStatusImpl(alloc, false);
                return .{ .status = status };
            },
        }
    }

    pub fn deactivate(self: *Service, alloc: Allocator) !OperationResult {
        var record = self.deps.store.read(alloc) catch |err| switch (err) {
            error.InvalidCache => return .{ .status = try makeStatus(alloc, .cache_corrupt, false, "unknown", null, null, null, null, .cache_corrupt, "cache corrupt") },
            else => return err,
        };
        defer if (record) |*value| value.deinit(alloc);

        if (record == null) {
            return .{ .status = try makeStatus(alloc, .not_activated, false, self.deps.provider.provider_id, null, null, null, null, .not_activated, "license not activated") };
        }

        if (!std.mem.eql(u8, record.?.license_key, DEV_KEY)) {
            const fingerprint = try self.deps.fingerprint_source.currentFingerprint(alloc);
            defer alloc.free(fingerprint);
            var outcome = self.deps.provider.deactivate(alloc, &record.?, fingerprint);
            defer outcome.deinit(alloc);
            switch (outcome) {
                .success => {},
                .failure => |err| setLastProviderError(err.message),
            }
        }

        try self.deps.store.clear(alloc);
        return .{ .status = try makeStatus(alloc, .not_activated, false, record.?.provider_id, null, null, null, null, .not_activated, "license not activated") };
    }

    pub fn refresh(self: *Service, alloc: Allocator) !OperationResult {
        return .{ .status = try self.getStatusImpl(alloc, true) };
    }

    fn getStatusImpl(self: *Service, alloc: Allocator, force_refresh: bool) !LicenseStatus {
        var record = self.deps.store.read(alloc) catch |err| switch (err) {
            error.InvalidCache => return makeStatus(alloc, .cache_corrupt, false, self.deps.provider.provider_id, null, null, null, null, .cache_corrupt, "cache corrupt"),
            else => return err,
        };
        defer if (record) |*value| value.deinit(alloc);

        if (record == null) {
            return makeStatus(alloc, .not_activated, false, self.deps.provider.provider_id, null, null, null, null, .not_activated, "license not activated");
        }

        const now = self.deps.clock.now();

        if (std.mem.eql(u8, record.?.license_key, DEV_KEY)) {
            return makeStatus(alloc, .valid, true, record.?.provider_id, record.?.activated_at, null, record.?.last_validated_at, null, .none, null);
        }

        const fingerprint = try self.deps.fingerprint_source.currentFingerprint(alloc);
        defer alloc.free(fingerprint);
        if (!std.mem.eql(u8, fingerprint, record.?.fingerprint)) {
            return makeStatus(alloc, .fingerprint_mismatch, false, record.?.provider_id, record.?.activated_at, record.?.expires_at, record.?.last_validated_at, null, .fingerprint_mismatch, "license is not valid on this machine");
        }

        if (record.?.expires_at) |expires_at| {
            if (now > expires_at + GRACE_PERIOD_SECS) {
                return makeStatus(alloc, .expired, false, record.?.provider_id, record.?.activated_at, record.?.expires_at, record.?.last_validated_at, null, .expired, "license expired");
            }
        }

        const needs_revalidation = force_refresh or
            record.?.last_validated_at == null or
            (now - record.?.last_validated_at.?) > REVALIDATION_INTERVAL_SECS;
        if (!needs_revalidation) {
            return makeStatus(alloc, .valid, true, record.?.provider_id, record.?.activated_at, record.?.expires_at, record.?.last_validated_at, null, .none, null);
        }

        var outcome = self.deps.provider.validate(alloc, &record.?, fingerprint);
        defer outcome.deinit(alloc);
        switch (outcome) {
            .success => |entitlement| {
                if (!entitlement.active or entitlement.invalid_key) {
                    return statusForFailure(alloc, record.?.provider_id, .invalid_key, "invalid key");
                }
                if (entitlement.revoked) {
                    return statusForFailure(alloc, record.?.provider_id, .revoked, "revoked");
                }
                record.?.expires_at = entitlement.expires_at;
                record.?.last_validated_at = now;
                if (record.?.provider_instance_id) |value| alloc.free(value);
                record.?.provider_instance_id = if (entitlement.provider_instance_id) |value| try alloc.dupe(u8, value) else null;
                alloc.free(record.?.provider_payload_json);
                record.?.provider_payload_json = try alloc.dupe(u8, entitlement.provider_payload_json);
                try self.deps.store.write(alloc, record.?);
                if (record.?.expires_at) |expires_at| {
                    if (now > expires_at + GRACE_PERIOD_SECS) {
                        return makeStatus(alloc, .expired, false, record.?.provider_id, record.?.activated_at, record.?.expires_at, record.?.last_validated_at, null, .expired, "license expired");
                    }
                }
                return makeStatus(alloc, .valid, true, record.?.provider_id, record.?.activated_at, record.?.expires_at, record.?.last_validated_at, null, .none, null);
            },
            .failure => |err| {
                setLastProviderError(err.message);
                if (isGraceEligible(err.code)) {
                    const grace_deadline = (record.?.last_validated_at orelse record.?.activated_at) + REVALIDATION_GRACE_SECS;
                    if (now <= grace_deadline) {
                        return makeStatus(alloc, .valid_offline_grace, true, record.?.provider_id, record.?.activated_at, record.?.expires_at, record.?.last_validated_at, grace_deadline, err.code, err.message);
                    }
                }
                return statusForFailure(alloc, record.?.provider_id, err.code, err.message);
            },
        }
    }
};

pub fn init(deps: ServiceDeps) Service {
    return .{ .deps = deps };
}

pub fn initDefaultLemonSqueezy(alloc: Allocator, opts: DefaultOptions) !Service {
    const provider = try license_provider_lemonsqueezy.create(alloc, .{
        .http_client = opts.http_client orelse license_support.stdHttpClient(),
    });
    const store = try license_store_fs.create(alloc, .{ .dir = opts.dir });
    var service = Service{
        .deps = .{
            .provider = provider,
            .store = store,
            .clock = undefined,
            .fingerprint_source = opts.fingerprint_source orelse license_support.machineFingerprintSource(),
        },
        .owns_provider = true,
        .owns_store = true,
    };
    if (opts.clock) |clock| {
        service.deps.clock = clock;
    } else if (opts.now) |value| {
        const state = try alloc.create(license_support.FixedClockState);
        state.* = .{ .now_value = value };
        service.deps.clock = license_support.fixedClock(state);
        service.owned_clock_state = state;
    } else {
        service.deps.clock = license_support.systemClock();
    }
    return service;
}

pub fn initDefaultStub(alloc: Allocator, cfg: StubConfig) !Service {
    return .{
        .deps = .{
            .provider = try license_provider_stub.create(alloc, cfg),
            .store = try license_store_memory.create(alloc),
            .clock = license_support.systemClock(),
            .fingerprint_source = license_support.machineFingerprintSource(),
        },
        .owns_provider = true,
        .owns_store = true,
    };
}

pub const LicenseRecord = struct {
    license_key: []const u8,
    activated_at: i64,
    fingerprint: []const u8,
    expires_at: ?i64 = null,
    last_validated_at: ?i64 = null,
};

pub const CheckResult = enum {
    ok,
    not_activated,
    expired,
    fingerprint_mismatch,
};

pub const Options = struct {
    dir: ?[]const u8 = null,
    now: ?i64 = null,
};

threadlocal var last_provider_error_buf: [512]u8 = .{0} ** 512;

pub fn lastLsError() []const u8 {
    return std.mem.sliceTo(&last_provider_error_buf, 0);
}

fn setLastProviderError(msg: []const u8) void {
    const len = @min(msg.len, last_provider_error_buf.len - 1);
    @memcpy(last_provider_error_buf[0..len], msg[0..len]);
    last_provider_error_buf[len] = 0;
}

pub fn machineFingerprint(buf: *[64]u8) ![]u8 {
    return license_support.machineFingerprint(buf);
}

pub fn readCache(gpa: Allocator, opts: Options) !?LicenseRecord {
    var store = try license_store_fs.create(gpa, .{ .dir = opts.dir });
    defer store.deinit(gpa);
    var record = store.read(gpa) catch |err| switch (err) {
        error.InvalidCache => return error.InvalidCache,
        else => return err,
    };
    defer if (record) |*value| value.deinit(gpa);
    if (record == null) return null;
    return .{
        .license_key = try gpa.dupe(u8, record.?.license_key),
        .activated_at = record.?.activated_at,
        .fingerprint = try gpa.dupe(u8, record.?.fingerprint),
        .expires_at = record.?.expires_at,
        .last_validated_at = record.?.last_validated_at,
    };
}

pub fn writeCache(gpa: Allocator, opts: Options, record: LicenseRecord) !void {
    var store = try license_store_fs.create(gpa, .{ .dir = opts.dir });
    defer store.deinit(gpa);
    const cache_record = CacheRecord{
        .schema_version = 2,
        .provider_id = try gpa.dupe(u8, "lemonsqueezy"),
        .license_key = try gpa.dupe(u8, record.license_key),
        .fingerprint = try gpa.dupe(u8, record.fingerprint),
        .activated_at = record.activated_at,
        .expires_at = record.expires_at,
        .last_validated_at = record.last_validated_at,
        .provider_instance_id = null,
        .provider_payload_json = try gpa.dupe(u8, "{}"),
    };
    defer {
        var owned = cache_record;
        owned.deinit(gpa);
    }
    try store.write(gpa, cache_record);
}

pub fn removeCache(gpa: Allocator, opts: Options) !void {
    var store = try license_store_fs.create(gpa, .{ .dir = opts.dir });
    defer store.deinit(gpa);
    try store.clear(gpa);
}

pub fn checkRecord(record: LicenseRecord, now: i64) CheckResult {
    if (record.expires_at) |exp| {
        if (now > exp + GRACE_PERIOD_SECS) return .expired;
    }
    return .ok;
}

pub fn check(gpa: Allocator, opts: Options) !CheckResult {
    var service = try initDefaultLemonSqueezy(gpa, .{
        .dir = opts.dir,
        .now = opts.now,
    });
    defer service.deinit(gpa);
    var status = try service.getStatus(gpa);
    defer status.deinit(gpa);
    return switch (status.state) {
        .valid, .valid_offline_grace => .ok,
        .not_activated, .invalid_key, .revoked, .provider_unavailable, .cache_corrupt, .internal_error => .not_activated,
        .expired => .expired,
        .fingerprint_mismatch => .fingerprint_mismatch,
    };
}

pub fn activate(gpa: Allocator, opts: Options, license_key: []const u8) !void {
    var service = try initDefaultLemonSqueezy(gpa, .{
        .dir = opts.dir,
        .now = opts.now,
    });
    defer service.deinit(gpa);
    var result = try service.activate(gpa, .{ .license_key = license_key });
    defer result.deinit(gpa);
    if (!result.status.permits_use) {
        if (result.status.message) |msg| setLastProviderError(msg);
        return error.LicenseActivationFailed;
    }
}

pub fn deactivate(gpa: Allocator, opts: Options) !void {
    var service = try initDefaultLemonSqueezy(gpa, .{
        .dir = opts.dir,
        .now = opts.now,
    });
    defer service.deinit(gpa);
    var result = try service.deactivate(gpa);
    defer result.deinit(gpa);
}

fn buildDevRecord(alloc: Allocator, provider_id: []const u8, license_key: []const u8, fingerprint: []const u8, now: i64) !CacheRecord {
    return .{
        .schema_version = 2,
        .provider_id = try alloc.dupe(u8, provider_id),
        .license_key = try alloc.dupe(u8, license_key),
        .fingerprint = try alloc.dupe(u8, fingerprint),
        .activated_at = now,
        .expires_at = null,
        .last_validated_at = std.math.maxInt(i64),
        .provider_instance_id = null,
        .provider_payload_json = try alloc.dupe(u8, "{\"provider\":\"dev\"}"),
    };
}

fn isGraceEligible(code: LicenseDetailCode) bool {
    return switch (code) {
        .network_error, .server_error, .protocol_error => true,
        else => false,
    };
}

fn statusForFailure(alloc: Allocator, provider_id: []const u8, code: LicenseDetailCode, message: []const u8) !LicenseStatus {
    const state: LicenseState = switch (code) {
        .invalid_key => .invalid_key,
        .revoked => .revoked,
        .cache_corrupt => .cache_corrupt,
        .fingerprint_mismatch => .fingerprint_mismatch,
        .expired => .expired,
        .not_activated => .not_activated,
        .network_error, .server_error => .provider_unavailable,
        .protocol_error, .internal_error, .none => .internal_error,
    };
    return makeStatus(alloc, state, false, provider_id, null, null, null, null, code, message);
}

fn makeStatus(
    alloc: Allocator,
    state: LicenseState,
    permits_use: bool,
    provider_id: []const u8,
    activated_at: ?i64,
    expires_at: ?i64,
    last_validated_at: ?i64,
    offline_grace_deadline: ?i64,
    detail_code: LicenseDetailCode,
    message: ?[]const u8,
) !LicenseStatus {
    return .{
        .state = state,
        .permits_use = permits_use,
        .provider_id = try alloc.dupe(u8, provider_id),
        .activated_at = activated_at,
        .expires_at = expires_at,
        .last_validated_at = last_validated_at,
        .offline_grace_deadline = offline_grace_deadline,
        .detail_code = detail_code,
        .message = if (message) |value| try alloc.dupe(u8, value) else null,
    };
}

const testing = std.testing;

test "service getStatus returns not_activated when store is empty" {
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var provider = try license_provider_stub.create(testing.allocator, .{});
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = undefined,
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });
    var fixed_clock = license_support.FixedClockState{ .now_value = 100 };
    service.deps.clock = license_support.fixedClock(&fixed_clock);

    var status = try service.getStatus(testing.allocator);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.not_activated, status.state);
    try testing.expect(!status.permits_use);
}

test "service activation writes cache and returns valid" {
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var clock_state = license_support.FixedClockState{ .now_value = 100 };
    var provider = try license_provider_stub.create(testing.allocator, .{});
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    var result = try service.activate(testing.allocator, .{ .license_key = "LIVE-1234" });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.valid, result.status.state);
    try testing.expect(result.status.permits_use);
}

test "service activation with invalid key returns invalid_key" {
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var clock_state = license_support.FixedClockState{ .now_value = 100 };
    var provider = try license_provider_stub.create(testing.allocator, .{ .activate_result = .invalid_key });
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    var result = try service.activate(testing.allocator, .{ .license_key = "LIVE-1234" });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.invalid_key, result.status.state);
    try testing.expectEqual(LicenseDetailCode.invalid_key, result.status.detail_code);
}

test "service fingerprint mismatch returns fingerprint_mismatch" {
    var clock_state = license_support.FixedClockState{ .now_value = 100 };
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "real-fp" };
    var provider = try license_provider_stub.create(testing.allocator, .{});
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    const record = CacheRecord{
        .schema_version = 2,
        .provider_id = try testing.allocator.dupe(u8, "stub"),
        .license_key = try testing.allocator.dupe(u8, "LIVE-1234"),
        .fingerprint = try testing.allocator.dupe(u8, "other-fp"),
        .activated_at = 90,
        .expires_at = null,
        .last_validated_at = 95,
        .provider_instance_id = null,
        .provider_payload_json = try testing.allocator.dupe(u8, "{}"),
    };
    defer {
        var owned = record;
        owned.deinit(testing.allocator);
    }
    try store.write(testing.allocator, record);

    var status = try service.getStatus(testing.allocator);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.fingerprint_mismatch, status.state);
}

test "service expired entitlement returns expired" {
    var clock_state = license_support.FixedClockState{ .now_value = GRACE_PERIOD_SECS + 200 };
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var provider = try license_provider_stub.create(testing.allocator, .{});
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    const record = CacheRecord{
        .schema_version = 2,
        .provider_id = try testing.allocator.dupe(u8, "stub"),
        .license_key = try testing.allocator.dupe(u8, "LIVE-1234"),
        .fingerprint = try testing.allocator.dupe(u8, "fp-1"),
        .activated_at = 0,
        .expires_at = 0,
        .last_validated_at = 10,
        .provider_instance_id = null,
        .provider_payload_json = try testing.allocator.dupe(u8, "{}"),
    };
    defer {
        var owned = record;
        owned.deinit(testing.allocator);
    }
    try store.write(testing.allocator, record);

    var status = try service.getStatus(testing.allocator);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.expired, status.state);
}

test "service provider unavailable within grace returns valid_offline_grace" {
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var clock_state = license_support.FixedClockState{ .now_value = REVALIDATION_INTERVAL_SECS + 100 };
    var provider = try license_provider_stub.create(testing.allocator, .{ .validate_result = .provider_unavailable });
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    const record = CacheRecord{
        .schema_version = 2,
        .provider_id = try testing.allocator.dupe(u8, "stub"),
        .license_key = try testing.allocator.dupe(u8, "LIVE-1234"),
        .fingerprint = try testing.allocator.dupe(u8, "fp-1"),
        .activated_at = 0,
        .expires_at = null,
        .last_validated_at = 1,
        .provider_instance_id = null,
        .provider_payload_json = try testing.allocator.dupe(u8, "{}"),
    };
    defer {
        var owned = record;
        owned.deinit(testing.allocator);
    }
    try store.write(testing.allocator, record);

    var status = try service.getStatus(testing.allocator);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.valid_offline_grace, status.state);
    try testing.expect(status.permits_use);
}

test "service provider unavailable beyond grace returns provider_unavailable" {
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var clock_state = license_support.FixedClockState{ .now_value = REVALIDATION_GRACE_SECS + REVALIDATION_INTERVAL_SECS + 100 };
    var provider = try license_provider_stub.create(testing.allocator, .{ .validate_result = .provider_unavailable });
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    const record = CacheRecord{
        .schema_version = 2,
        .provider_id = try testing.allocator.dupe(u8, "stub"),
        .license_key = try testing.allocator.dupe(u8, "LIVE-1234"),
        .fingerprint = try testing.allocator.dupe(u8, "fp-1"),
        .activated_at = 0,
        .expires_at = null,
        .last_validated_at = 1,
        .provider_instance_id = null,
        .provider_payload_json = try testing.allocator.dupe(u8, "{}"),
    };
    defer {
        var owned = record;
        owned.deinit(testing.allocator);
    }
    try store.write(testing.allocator, record);

    var status = try service.getStatus(testing.allocator);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.provider_unavailable, status.state);
    try testing.expect(!status.permits_use);
}

test "service refresh updates last_validated_at" {
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var clock_state = license_support.FixedClockState{ .now_value = 500 };
    var provider = try license_provider_stub.create(testing.allocator, .{});
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    const record = CacheRecord{
        .schema_version = 2,
        .provider_id = try testing.allocator.dupe(u8, "stub"),
        .license_key = try testing.allocator.dupe(u8, "LIVE-1234"),
        .fingerprint = try testing.allocator.dupe(u8, "fp-1"),
        .activated_at = 0,
        .expires_at = null,
        .last_validated_at = 10,
        .provider_instance_id = null,
        .provider_payload_json = try testing.allocator.dupe(u8, "{}"),
    };
    defer {
        var owned = record;
        owned.deinit(testing.allocator);
    }
    try store.write(testing.allocator, record);

    var result = try service.refresh(testing.allocator);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(?i64, 500), result.status.last_validated_at);
}

test "service deactivate clears cache and returns not_activated" {
    var fp_state = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    var clock_state = license_support.FixedClockState{ .now_value = 500 };
    var provider = try license_provider_stub.create(testing.allocator, .{});
    defer provider.deinit(testing.allocator);
    var store = try license_store_memory.create(testing.allocator);
    defer store.deinit(testing.allocator);
    var service = init(.{
        .provider = provider,
        .store = store,
        .clock = license_support.fixedClock(&clock_state),
        .fingerprint_source = license_support.fixedFingerprintSource(&fp_state),
    });

    const record = CacheRecord{
        .schema_version = 2,
        .provider_id = try testing.allocator.dupe(u8, "stub"),
        .license_key = try testing.allocator.dupe(u8, "LIVE-1234"),
        .fingerprint = try testing.allocator.dupe(u8, "fp-1"),
        .activated_at = 0,
        .expires_at = null,
        .last_validated_at = 10,
        .provider_instance_id = null,
        .provider_payload_json = try testing.allocator.dupe(u8, "{}"),
    };
    defer {
        var owned = record;
        owned.deinit(testing.allocator);
    }
    try store.write(testing.allocator, record);

    var result = try service.deactivate(testing.allocator);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.not_activated, result.status.state);

    const after = try store.read(testing.allocator);
    try testing.expect(after == null);
}

test "service returns cache_corrupt on invalid cache" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const file = try std.fs.path.join(testing.allocator, &.{ dir, "license.json" });
    defer testing.allocator.free(file);
    try std.fs.cwd().writeFile(.{ .sub_path = file, .data = "{not json" });

    var service = try initDefaultLemonSqueezy(testing.allocator, .{
        .dir = dir,
        .now = 100,
        .http_client = license_support.stdHttpClient(),
        .fingerprint_source = undefined,
    });
    var fixed_fp = license_support.FixedFingerprintState{ .fingerprint = "fp-1" };
    service.deps.fingerprint_source = license_support.fixedFingerprintSource(&fixed_fp);
    defer service.deinit(testing.allocator);

    var status = try service.getStatus(testing.allocator);
    defer status.deinit(testing.allocator);
    try testing.expectEqual(LicenseState.cache_corrupt, status.state);
}
