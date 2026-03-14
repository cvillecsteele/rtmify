const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const license_types = @import("license_types.zig");
pub const license_file = @import("license_file.zig");
pub const license_provider = @import("license_provider.zig");
pub const license_provider_stub = @import("license_provider_stub.zig");
pub const license_provider_hmac_file = @import("license_provider_hmac_file.zig");
pub const license_store = @import("license_store.zig");
pub const license_store_fs = @import("license_store_fs.zig");
pub const license_store_memory = @import("license_store_memory.zig");
pub const license_support = @import("license_support.zig");
pub const development_hmac_key_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
pub const canonical_key_path_suffix = ".rtmify/secrets/license-hmac-key.txt";

pub const LicenseProduct = license_types.LicenseProduct;
pub const LicenseTier = license_types.LicenseTier;
pub const TrialPolicy = license_types.TrialPolicy;
pub const LicensePayload = license_types.LicensePayload;
pub const LicenseEnvelope = license_types.LicenseEnvelope;
pub const LicenseState = license_types.LicenseState;
pub const LicenseDetailCode = license_types.LicenseDetailCode;
pub const LicenseStatus = license_types.LicenseStatus;
pub const LicenseInfo = license_types.LicenseInfo;
pub const ActivationRequest = license_types.ActivationRequest;
pub const OperationResult = license_types.OperationResult;
pub const Provider = license_provider.Provider;
pub const Store = license_store.Store;
pub const StubConfig = license_provider_stub.StubConfig;

pub const ServiceDeps = struct {
    provider: Provider,
    store: Store,
    clock: license_support.Clock,
    product: LicenseProduct,
    trial_policy: TrialPolicy,
    license_path_override: ?[]const u8 = null,
    marker_path_override: ?[]const u8 = null,
};

pub const ServiceConfig = struct {
    product: LicenseProduct,
    trial_policy: TrialPolicy,
    license_path_override: ?[]const u8 = null,
    marker_path_override: ?[]const u8 = null,
    now: ?i64 = null,
    clock: ?license_support.Clock = null,
};

pub const DefaultOptions = struct {
    license_path_override: ?[]const u8 = null,
    now: ?i64 = null,
    clock: ?license_support.Clock = null,
};

pub const Service = struct {
    deps: ServiceDeps,
    owns_provider: bool = false,
    owns_store: bool = false,
    owned_clock_state: ?*license_support.FixedClockState = null,

    pub fn deinit(self: *Service, alloc: Allocator) void {
        if (self.owns_provider) self.deps.provider.deinit(alloc);
        if (self.owns_store) self.deps.store.deinit(alloc);
        if (self.deps.license_path_override) |path| alloc.free(path);
        if (self.deps.marker_path_override) |path| alloc.free(path);
        if (self.owned_clock_state) |state| alloc.destroy(state);
        self.* = undefined;
    }

    pub fn getStatus(self: *Service, alloc: Allocator) !LicenseStatus {
        const license_path = try resolveLicensePath(alloc, self.deps.license_path_override);
        const expected_key_fingerprint = try defaultKeyFingerprintHex(alloc);
        var envelope = self.deps.store.readEnvelope(alloc) catch |err| switch (err) {
            error.InvalidLicenseFile => return makeStatus(alloc, .invalid, false, .invalid_json, "license file is not valid JSON", license_path, expected_key_fingerprint, null, null, false),
            else => return err,
        };
        defer if (envelope) |*value| value.deinit(alloc);

        if (envelope == null) {
            return statusWithoutInstalledLicense(self, alloc, license_path, expected_key_fingerprint);
        }

        const now = self.deps.clock.now();
        var outcome = self.deps.provider.verifyEnvelope(alloc, &envelope.?, self.deps.product, now);
        defer outcome.deinit(alloc);
        return switch (outcome) {
            .valid => |payload| makeStatusFromPayload(alloc, .valid, true, .none, null, license_path, expected_key_fingerprint, envelope.?.signing_key_fingerprint, payload, false),
            .expired => |payload| makeStatusFromPayload(alloc, .expired, false, .expired, "license has expired", license_path, expected_key_fingerprint, envelope.?.signing_key_fingerprint, payload, false),
            .invalid => |failure| makeStatus(alloc, .invalid, false, failure.code, failure.message, license_path, expected_key_fingerprint, envelope.?.signing_key_fingerprint, null, false),
            .tampered => |failure| makeStatus(alloc, .tampered, false, failure.code, failure.message, license_path, expected_key_fingerprint, envelope.?.signing_key_fingerprint, null, false),
        };
    }

    pub fn getInfo(self: *Service, alloc: Allocator) !LicenseInfo {
        const license_path = try resolveLicensePath(alloc, self.deps.license_path_override);
        const expected_key_fingerprint = try defaultKeyFingerprintHex(alloc);
        var envelope = self.deps.store.readEnvelope(alloc) catch |err| switch (err) {
            error.InvalidLicenseFile => {
                alloc.free(license_path);
                alloc.free(expected_key_fingerprint);
                return error.InvalidLicenseFile;
            },
            else => {
                alloc.free(license_path);
                alloc.free(expected_key_fingerprint);
                return err;
            },
        };
        defer if (envelope) |*value| value.deinit(alloc);
        if (envelope == null) {
            alloc.free(license_path);
            alloc.free(expected_key_fingerprint);
            return error.FileNotFound;
        }
        const now = self.deps.clock.now();
        var outcome = self.deps.provider.verifyEnvelope(alloc, &envelope.?, self.deps.product, now);
        defer outcome.deinit(alloc);
        return switch (outcome) {
            .valid => |payload| .{
                .payload = try payload.clone(alloc),
                .license_path = license_path,
                .expected_key_fingerprint = expected_key_fingerprint,
                .license_signing_key_fingerprint = if (envelope.?.signing_key_fingerprint) |value| try alloc.dupe(u8, value) else null,
            },
            .expired => |payload| .{
                .payload = try payload.clone(alloc),
                .license_path = license_path,
                .expected_key_fingerprint = expected_key_fingerprint,
                .license_signing_key_fingerprint = if (envelope.?.signing_key_fingerprint) |value| try alloc.dupe(u8, value) else null,
            },
            .invalid => {
                alloc.free(license_path);
                alloc.free(expected_key_fingerprint);
                return error.InvalidLicense;
            },
            .tampered => {
                alloc.free(license_path);
                alloc.free(expected_key_fingerprint);
                return error.InvalidLicense;
            },
        };
    }

    pub fn installFromPath(self: *Service, alloc: Allocator, src_path: []const u8) !LicenseStatus {
        const bytes = try std.fs.cwd().readFileAlloc(alloc, src_path, 128 * 1024);
        defer alloc.free(bytes);
        return self.installFromBytes(alloc, bytes);
    }

    pub fn installFromBytes(self: *Service, alloc: Allocator, license_json: []const u8) !LicenseStatus {
        var envelope = license_file.parseEnvelope(alloc, license_json) catch {
            const path = try resolveLicensePath(alloc, self.deps.license_path_override);
            const expected_key_fingerprint = try defaultKeyFingerprintHex(alloc);
            return makeStatus(alloc, .invalid, false, .invalid_json, "license file is not valid JSON", path, expected_key_fingerprint, null, null, false);
        };
        defer envelope.deinit(alloc);
        const license_path = try resolveLicensePath(alloc, self.deps.license_path_override);
        const expected_key_fingerprint = try defaultKeyFingerprintHex(alloc);
        const now = self.deps.clock.now();
        var outcome = self.deps.provider.verifyEnvelope(alloc, &envelope, self.deps.product, now);
        defer outcome.deinit(alloc);
        switch (outcome) {
            .valid => {},
            .expired => |payload| {
                return makeStatusFromPayload(alloc, .expired, false, .expired, "license has expired", license_path, expected_key_fingerprint, envelope.signing_key_fingerprint, payload, false);
            },
            .invalid => |failure| return makeStatus(alloc, .invalid, false, failure.code, failure.message, license_path, expected_key_fingerprint, envelope.signing_key_fingerprint, null, false),
            .tampered => |failure| return makeStatus(alloc, .tampered, false, failure.code, failure.message, license_path, expected_key_fingerprint, envelope.signing_key_fingerprint, null, false),
        }
        try self.deps.store.writeEnvelope(alloc, envelope);
        return self.getStatus(alloc);
    }

    pub fn clearInstalledLicense(self: *Service, alloc: Allocator) !LicenseStatus {
        try self.deps.store.clearEnvelope(alloc);
        return self.getStatus(alloc);
    }

    pub fn activate(self: *Service, alloc: Allocator, req: ActivationRequest) !OperationResult {
        _ = self;
        _ = req;
        return .{ .status = try makeDetachedStatus(alloc, .invalid, false, .install_failed, "license activation is no longer supported; import a signed license file") };
    }

    pub fn deactivate(self: *Service, alloc: Allocator) !OperationResult {
        _ = self;
        return .{ .status = try makeDetachedStatus(alloc, .invalid, false, .install_failed, "license deactivation is no longer supported; clear the installed signed license file") };
    }

    pub fn refresh(self: *Service, alloc: Allocator) !OperationResult {
        return .{ .status = try self.getStatus(alloc) };
    }

    pub fn recordSuccessfulUse(self: *Service, alloc: Allocator) !void {
        if (self.deps.trial_policy != .single_free_run) return;
        const marker_path = try resolveMarkerPath(alloc, self.deps.marker_path_override);
        defer alloc.free(marker_path);
        try ensureParentDir(marker_path);
        const contents = try std.fmt.allocPrint(alloc, "{{\"used_at\":{d},\"version\":\"{s}\"}}", .{
            self.deps.clock.now(),
            build_options.version,
        });
        defer alloc.free(contents);
        try std.fs.cwd().writeFile(.{ .sub_path = marker_path, .data = contents });
    }
};

pub fn init(deps: ServiceDeps) Service {
    return .{ .deps = deps };
}

pub fn initDefaultHmacFile(alloc: Allocator, cfg: ServiceConfig) !Service {
    const key = try defaultHmacKeyBytes(alloc);
    defer alloc.free(key);

    const provider = try license_provider_hmac_file.create(alloc, .{ .hmac_key = key });
    const store = try license_store_fs.create(alloc, .{
        .path = cfg.license_path_override,
    });
    var service = Service{
        .deps = .{
            .provider = provider,
            .store = store,
            .clock = undefined,
            .product = cfg.product,
            .trial_policy = cfg.trial_policy,
            .license_path_override = if (cfg.license_path_override) |path| try alloc.dupe(u8, path) else null,
            .marker_path_override = if (cfg.marker_path_override) |path| try alloc.dupe(u8, path) else null,
        },
        .owns_provider = true,
        .owns_store = true,
    };
    if (cfg.clock) |clock| {
        service.deps.clock = clock;
    } else if (cfg.now) |value| {
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
            .product = .live,
            .trial_policy = .requires_license,
            .license_path_override = null,
            .marker_path_override = null,
        },
        .owns_provider = true,
        .owns_store = true,
    };
}

pub fn defaultHmacKeyBytes(alloc: Allocator) ![]u8 {
    const key_hex = if (build_options.license_hmac_key_hex.len != 0) build_options.license_hmac_key_hex else development_hmac_key_hex;
    return decodeHexKey(alloc, key_hex);
}

pub fn keyFingerprintHex(alloc: Allocator, key_bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key_bytes, &digest, .{});
    return alloc.dupe(u8, std.fmt.bytesToHex(&digest, .lower)[0..]);
}

pub fn defaultKeyFingerprintHex(alloc: Allocator) ![]u8 {
    if (build_options.license_hmac_key_fingerprint_hex.len != 0) {
        return alloc.dupe(u8, build_options.license_hmac_key_fingerprint_hex);
    }
    const key = try defaultHmacKeyBytes(alloc);
    defer alloc.free(key);
    return keyFingerprintHex(alloc, key);
}

pub fn displayFingerprint(full_hex: []const u8) []const u8 {
    return if (full_hex.len > 12) full_hex[0..12] else full_hex;
}

pub fn usingDevelopmentHmacKey() bool {
    return std.mem.eql(u8, build_options.license_hmac_key_hex, development_hmac_key_hex);
}

pub fn decodeHexKey(alloc: Allocator, key_hex: []const u8) ![]u8 {
    if (key_hex.len != 64) return error.InvalidHmacKey;
    const out = try alloc.alloc(u8, 32);
    errdefer alloc.free(out);
    _ = try std.fmt.hexToBytes(out, key_hex);
    return out;
}

pub fn defaultKeyFilePath(alloc: Allocator) ![]u8 {
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = try std.process.getEnvVarOwned(alloc, home_var);
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, canonical_key_path_suffix });
}

pub fn resolveKeyFilePath(alloc: Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| return alloc.dupe(u8, path);
    if (std.process.getEnvVarOwned(alloc, "RTMIFY_LICENSE_HMAC_KEY_FILE")) |env_path| {
        return env_path;
    } else |_| {}
    return defaultKeyFilePath(alloc);
}

pub fn resolveLicensePath(alloc: Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| return alloc.dupe(u8, path);
    if (std.process.getEnvVarOwned(alloc, "RTMIFY_LICENSE")) |env_path| {
        return env_path;
    } else |_| {}
    return license_store_fs.defaultLicensePath(alloc);
}

pub fn resolveMarkerPath(alloc: Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |path| return alloc.dupe(u8, path);
    const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const home = try std.process.getEnvVarOwned(alloc, home_var);
    defer alloc.free(home);
    const dir = try std.fs.path.join(alloc, &.{ home, ".rtmify" });
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, ".trace-used" });
}

fn markerExists(self: *Service, alloc: Allocator) bool {
    const path = resolveMarkerPath(alloc, self.deps.marker_path_override) catch return false;
    defer alloc.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn statusWithoutInstalledLicense(self: *Service, alloc: Allocator, license_path: []u8, expected_key_fingerprint: []u8) !LicenseStatus {
    return switch (self.deps.trial_policy) {
        .single_free_run => if (markerExists(self, alloc))
            makeStatus(alloc, .not_licensed, false, .trial_exhausted, "trial exhausted; install a signed license file to continue", license_path, expected_key_fingerprint, null, null, false)
        else
            makeStatus(alloc, .not_licensed, true, .free_run_available, "one free run is available before a license is required", license_path, expected_key_fingerprint, null, null, true),
        .requires_license => makeStatus(alloc, .not_licensed, false, .file_not_found, "license file not found", license_path, expected_key_fingerprint, null, null, false),
        .unlimited => makeStatus(alloc, .valid, true, .none, null, license_path, expected_key_fingerprint, null, null, false),
    };
}

fn makeStatusFromPayload(
    alloc: Allocator,
    state: LicenseState,
    permits_use: bool,
    detail_code: LicenseDetailCode,
    message: ?[]const u8,
    license_path: []u8,
    expected_key_fingerprint: []u8,
    license_signing_key_fingerprint: ?[]const u8,
    payload: LicensePayload,
    using_free_run: bool,
) !LicenseStatus {
    return .{
        .state = state,
        .permits_use = permits_use,
        .detail_code = detail_code,
        .message = if (message) |msg| try alloc.dupe(u8, msg) else null,
        .license_path = license_path,
        .expected_key_fingerprint = expected_key_fingerprint,
        .license_signing_key_fingerprint = if (license_signing_key_fingerprint) |value| try alloc.dupe(u8, value) else null,
        .issued_to = try alloc.dupe(u8, payload.issued_to),
        .org = if (payload.org) |org| try alloc.dupe(u8, org) else null,
        .license_id = try alloc.dupe(u8, payload.license_id),
        .product = payload.product,
        .tier = payload.tier,
        .issued_at = payload.issued_at,
        .expires_at = payload.expires_at,
        .using_free_run = using_free_run,
    };
}

fn makeStatus(
    alloc: Allocator,
    state: LicenseState,
    permits_use: bool,
    detail_code: LicenseDetailCode,
    message: ?[]const u8,
    license_path: []u8,
    expected_key_fingerprint: []u8,
    license_signing_key_fingerprint: ?[]const u8,
    payload: ?LicensePayload,
    using_free_run: bool,
) !LicenseStatus {
    const resolved_message = if (detail_code == .bad_signature)
        try mismatchMessage(alloc, expected_key_fingerprint, license_signing_key_fingerprint)
    else if (message) |msg|
        try alloc.dupe(u8, msg)
    else
        null;
    return .{
        .state = state,
        .permits_use = permits_use,
        .detail_code = detail_code,
        .message = resolved_message,
        .license_path = license_path,
        .expected_key_fingerprint = expected_key_fingerprint,
        .license_signing_key_fingerprint = if (license_signing_key_fingerprint) |value| try alloc.dupe(u8, value) else null,
        .issued_to = if (payload) |value| try alloc.dupe(u8, value.issued_to) else null,
        .org = if (payload) |value| if (value.org) |org| try alloc.dupe(u8, org) else null else null,
        .license_id = if (payload) |value| try alloc.dupe(u8, value.license_id) else null,
        .product = if (payload) |value| value.product else null,
        .tier = if (payload) |value| value.tier else null,
        .issued_at = if (payload) |value| value.issued_at else null,
        .expires_at = if (payload) |value| value.expires_at else null,
        .using_free_run = using_free_run,
    };
}

fn mismatchMessage(alloc: Allocator, expected_key_fingerprint: []const u8, license_signing_key_fingerprint: ?[]const u8) !?[]u8 {
    if (license_signing_key_fingerprint) |file_fp| {
        const message = try std.fmt.allocPrint(
            alloc,
            "license was signed with key {s}, but this build expects {s}",
            .{ displayFingerprint(file_fp), displayFingerprint(expected_key_fingerprint) },
        );
        return message;
    }
    const message = try std.fmt.allocPrint(
        alloc,
        "license signature does not match this build; expected key {s}",
        .{displayFingerprint(expected_key_fingerprint)},
    );
    return message;
}

fn makeDetachedStatus(
    alloc: Allocator,
    state: LicenseState,
    permits_use: bool,
    detail_code: LicenseDetailCode,
    message: ?[]const u8,
) !LicenseStatus {
    const expected_key_fingerprint = try defaultKeyFingerprintHex(alloc);
    return .{
        .state = state,
        .permits_use = permits_use,
        .detail_code = detail_code,
        .message = if (message) |msg| try alloc.dupe(u8, msg) else null,
        .license_path = try alloc.dupe(u8, ""),
        .expected_key_fingerprint = expected_key_fingerprint,
        .license_signing_key_fingerprint = null,
        .issued_to = null,
        .org = null,
        .license_id = null,
        .product = null,
        .tier = null,
        .issued_at = null,
        .expires_at = null,
        .using_free_run = false,
    };
}

fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(dir);
}

test "single free run is available when marker is absent" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const alloc = std.testing.allocator;

    const tmp_path = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const license_path = try std.fs.path.join(alloc, &.{ tmp_path, "license.json" });
    defer alloc.free(license_path);
    const marker_path = try std.fs.path.join(alloc, &.{ tmp_path, ".trace-used" });
    defer alloc.free(marker_path);

    var service = try initDefaultHmacFile(alloc, .{
        .product = .trace,
        .trial_policy = .single_free_run,
        .license_path_override = license_path,
        .marker_path_override = marker_path,
        .now = 1,
    });
    defer service.deinit(alloc);

    var status = try service.getStatus(alloc);
    defer status.deinit(alloc);
    try std.testing.expect(status.permits_use);
    try std.testing.expect(status.using_free_run);
    try std.testing.expectEqual(LicenseDetailCode.free_run_available, status.detail_code);
}
