const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LicenseState = enum {
    valid,
    valid_offline_grace,
    not_activated,
    expired,
    fingerprint_mismatch,
    revoked,
    invalid_key,
    provider_unavailable,
    cache_corrupt,
    internal_error,
};

pub const LicenseDetailCode = enum {
    none,
    invalid_key,
    revoked,
    network_error,
    server_error,
    protocol_error,
    cache_corrupt,
    fingerprint_mismatch,
    expired,
    not_activated,
    internal_error,
};

pub const LicenseStatus = struct {
    state: LicenseState,
    permits_use: bool,
    provider_id: []const u8,
    activated_at: ?i64,
    expires_at: ?i64,
    last_validated_at: ?i64,
    offline_grace_deadline: ?i64,
    detail_code: LicenseDetailCode,
    message: ?[]const u8,

    pub fn deinit(self: *LicenseStatus, alloc: Allocator) void {
        alloc.free(self.provider_id);
        if (self.message) |msg| alloc.free(msg);
        self.* = undefined;
    }

    pub fn clone(self: LicenseStatus, alloc: Allocator) !LicenseStatus {
        return .{
            .state = self.state,
            .permits_use = self.permits_use,
            .provider_id = try alloc.dupe(u8, self.provider_id),
            .activated_at = self.activated_at,
            .expires_at = self.expires_at,
            .last_validated_at = self.last_validated_at,
            .offline_grace_deadline = self.offline_grace_deadline,
            .detail_code = self.detail_code,
            .message = if (self.message) |msg| try alloc.dupe(u8, msg) else null,
        };
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

pub const CacheRecord = struct {
    schema_version: u32 = 2,
    provider_id: []const u8,
    license_key: []const u8,
    fingerprint: []const u8,
    activated_at: i64,
    expires_at: ?i64,
    last_validated_at: ?i64,
    provider_instance_id: ?[]const u8,
    provider_payload_json: []const u8,

    pub fn deinit(self: *CacheRecord, alloc: Allocator) void {
        alloc.free(self.provider_id);
        alloc.free(self.license_key);
        alloc.free(self.fingerprint);
        if (self.provider_instance_id) |value| alloc.free(value);
        alloc.free(self.provider_payload_json);
        self.* = undefined;
    }

    pub fn clone(self: CacheRecord, alloc: Allocator) !CacheRecord {
        return .{
            .schema_version = self.schema_version,
            .provider_id = try alloc.dupe(u8, self.provider_id),
            .license_key = try alloc.dupe(u8, self.license_key),
            .fingerprint = try alloc.dupe(u8, self.fingerprint),
            .activated_at = self.activated_at,
            .expires_at = self.expires_at,
            .last_validated_at = self.last_validated_at,
            .provider_instance_id = if (self.provider_instance_id) |value| try alloc.dupe(u8, value) else null,
            .provider_payload_json = try alloc.dupe(u8, self.provider_payload_json),
        };
    }
};

