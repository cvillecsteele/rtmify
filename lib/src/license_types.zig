const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LicenseProduct = enum {
    trace,
    live,
};

pub const LicenseTier = enum {
    lab,
    individual,
    team,
    site,
};

pub const TrialPolicy = enum {
    single_free_run,
    requires_license,
    unlimited,
};

pub const LicensePayload = struct {
    schema: u32,
    license_id: []const u8,
    product: LicenseProduct,
    tier: LicenseTier,
    issued_to: []const u8,
    issued_at: i64,
    expires_at: ?i64,
    org: ?[]const u8 = null,

    pub fn deinit(self: *LicensePayload, alloc: Allocator) void {
        alloc.free(self.license_id);
        alloc.free(self.issued_to);
        if (self.org) |org| alloc.free(org);
        self.* = undefined;
    }

    pub fn clone(self: LicensePayload, alloc: Allocator) !LicensePayload {
        return .{
            .schema = self.schema,
            .license_id = try alloc.dupe(u8, self.license_id),
            .product = self.product,
            .tier = self.tier,
            .issued_to = try alloc.dupe(u8, self.issued_to),
            .issued_at = self.issued_at,
            .expires_at = self.expires_at,
            .org = if (self.org) |org| try alloc.dupe(u8, org) else null,
        };
    }
};

pub const LicenseEnvelope = struct {
    payload: LicensePayload,
    sig: []const u8,
    signing_key_fingerprint: ?[]const u8 = null,

    pub fn deinit(self: *LicenseEnvelope, alloc: Allocator) void {
        self.payload.deinit(alloc);
        alloc.free(self.sig);
        if (self.signing_key_fingerprint) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn clone(self: LicenseEnvelope, alloc: Allocator) !LicenseEnvelope {
        return .{
            .payload = try self.payload.clone(alloc),
            .sig = try alloc.dupe(u8, self.sig),
            .signing_key_fingerprint = if (self.signing_key_fingerprint) |value| try alloc.dupe(u8, value) else null,
        };
    }
};

pub const LicenseState = enum {
    valid,
    not_licensed,
    expired,
    invalid,
    tampered,
};

pub const LicenseDetailCode = enum {
    none,
    free_run_available,
    trial_exhausted,
    file_not_found,
    invalid_json,
    bad_signature,
    wrong_product,
    unsupported_schema,
    expired,
    install_failed,
    internal_error,
};

pub const LicenseStatus = struct {
    state: LicenseState,
    permits_use: bool,
    detail_code: LicenseDetailCode,
    message: ?[]const u8,
    license_path: []const u8,
    expected_key_fingerprint: []const u8,
    license_signing_key_fingerprint: ?[]const u8,
    issued_to: ?[]const u8,
    org: ?[]const u8,
    license_id: ?[]const u8,
    product: ?LicenseProduct,
    tier: ?LicenseTier,
    issued_at: ?i64,
    expires_at: ?i64,
    using_free_run: bool,

    pub fn deinit(self: *LicenseStatus, alloc: Allocator) void {
        alloc.free(self.license_path);
        alloc.free(self.expected_key_fingerprint);
        if (self.message) |message| alloc.free(message);
        if (self.license_signing_key_fingerprint) |value| alloc.free(value);
        if (self.issued_to) |issued_to| alloc.free(issued_to);
        if (self.org) |org| alloc.free(org);
        if (self.license_id) |license_id| alloc.free(license_id);
        self.* = undefined;
    }

    pub fn clone(self: LicenseStatus, alloc: Allocator) !LicenseStatus {
        return .{
            .state = self.state,
            .permits_use = self.permits_use,
            .detail_code = self.detail_code,
            .message = if (self.message) |message| try alloc.dupe(u8, message) else null,
            .license_path = try alloc.dupe(u8, self.license_path),
            .expected_key_fingerprint = try alloc.dupe(u8, self.expected_key_fingerprint),
            .license_signing_key_fingerprint = if (self.license_signing_key_fingerprint) |value| try alloc.dupe(u8, value) else null,
            .issued_to = if (self.issued_to) |issued_to| try alloc.dupe(u8, issued_to) else null,
            .org = if (self.org) |org| try alloc.dupe(u8, org) else null,
            .license_id = if (self.license_id) |license_id| try alloc.dupe(u8, license_id) else null,
            .product = self.product,
            .tier = self.tier,
            .issued_at = self.issued_at,
            .expires_at = self.expires_at,
            .using_free_run = self.using_free_run,
        };
    }
};

pub const LicenseInfo = struct {
    payload: LicensePayload,
    license_path: []const u8,
    expected_key_fingerprint: []const u8,
    license_signing_key_fingerprint: ?[]const u8,

    pub fn deinit(self: *LicenseInfo, alloc: Allocator) void {
        self.payload.deinit(alloc);
        alloc.free(self.license_path);
        alloc.free(self.expected_key_fingerprint);
        if (self.license_signing_key_fingerprint) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ActivationRequest = struct {
    license_key: []const u8,
};

pub const OperationResult = struct {
    status: LicenseStatus,

    pub fn deinit(self: *OperationResult, alloc: Allocator) void {
        self.status.deinit(alloc);
        self.* = undefined;
    }
};
