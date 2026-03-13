const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("license_types.zig");

pub fn parseEnvelope(alloc: Allocator, json_bytes: []const u8) !types.LicenseEnvelope {
    const ParsedPayload = struct {
        schema: u32,
        license_id: []const u8,
        product: types.LicenseProduct,
        tier: types.LicenseTier,
        issued_to: []const u8,
        issued_at: i64,
        expires_at: ?i64 = null,
        org: ?[]const u8 = null,
    };
    const ParsedEnvelope = struct {
        payload: ParsedPayload,
        sig: []const u8,
    };

    var parsed = try std.json.parseFromSlice(ParsedEnvelope, alloc, json_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .payload = .{
            .schema = parsed.value.payload.schema,
            .license_id = try alloc.dupe(u8, parsed.value.payload.license_id),
            .product = parsed.value.payload.product,
            .tier = parsed.value.payload.tier,
            .issued_to = try alloc.dupe(u8, parsed.value.payload.issued_to),
            .issued_at = parsed.value.payload.issued_at,
            .expires_at = parsed.value.payload.expires_at,
            .org = if (parsed.value.payload.org) |org| try alloc.dupe(u8, org) else null,
        },
        .sig = try alloc.dupe(u8, parsed.value.sig),
    };
}

pub fn canonicalPayloadAlloc(alloc: Allocator, payload: types.LicensePayload) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const writer = buf.writer(alloc);
    try writer.writeAll("{\"expires_at\":");
    if (payload.expires_at) |expires_at| {
        try writer.print("{d}", .{expires_at});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"issued_at\":");
    try writer.print("{d}", .{payload.issued_at});
    try writer.writeAll(",\"issued_to\":");
    try writeJsonString(writer, payload.issued_to);
    try writer.writeAll(",\"license_id\":");
    try writeJsonString(writer, payload.license_id);
    try writer.writeAll(",\"org\":");
    if (payload.org) |org| {
        try writeJsonString(writer, org);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"product\":");
    try writeJsonString(writer, @tagName(payload.product));
    try writer.writeAll(",\"schema\":");
    try writer.print("{d}", .{payload.schema});
    try writer.writeAll(",\"tier\":");
    try writeJsonString(writer, @tagName(payload.tier));
    try writer.writeAll("}");
    return buf.toOwnedSlice(alloc);
}

pub fn signPayloadHex(alloc: Allocator, payload: types.LicensePayload, key: []const u8) ![]u8 {
    const canonical = try canonicalPayloadAlloc(alloc, payload);
    defer alloc.free(canonical);
    return signCanonicalHex(alloc, canonical, key);
}

pub fn signCanonicalHex(alloc: Allocator, canonical_payload: []const u8, key: []const u8) ![]u8 {
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, canonical_payload, key);
    return alloc.dupe(u8, std.fmt.bytesToHex(&mac, .lower)[0..]);
}

pub fn verifyEnvelope(alloc: Allocator, envelope: *const types.LicenseEnvelope, key: []const u8) !bool {
    const canonical = try canonicalPayloadAlloc(alloc, envelope.payload);
    defer alloc.free(canonical);
    const expected_sig = try signCanonicalHex(alloc, canonical, key);
    defer alloc.free(expected_sig);
    return std.mem.eql(u8, expected_sig, envelope.sig);
}

pub fn envelopeJsonAlloc(alloc: Allocator, envelope: types.LicenseEnvelope) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const writer = buf.writer(alloc);
    try writer.writeAll("{\"payload\":");
    try writePayloadJson(writer, envelope.payload);
    try writer.writeAll(",\"sig\":");
    try writeJsonString(writer, envelope.sig);
    try writer.writeAll("}");
    return buf.toOwnedSlice(alloc);
}

pub fn writePayloadJson(writer: anytype, payload: types.LicensePayload) !void {
    try writer.writeAll("{\"schema\":");
    try writer.print("{d}", .{payload.schema});
    try writer.writeAll(",\"license_id\":");
    try writeJsonString(writer, payload.license_id);
    try writer.writeAll(",\"product\":");
    try writeJsonString(writer, @tagName(payload.product));
    try writer.writeAll(",\"tier\":");
    try writeJsonString(writer, @tagName(payload.tier));
    try writer.writeAll(",\"issued_to\":");
    try writeJsonString(writer, payload.issued_to);
    try writer.writeAll(",\"issued_at\":");
    try writer.print("{d}", .{payload.issued_at});
    try writer.writeAll(",\"expires_at\":");
    if (payload.expires_at) |expires_at| {
        try writer.print("{d}", .{expires_at});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"org\":");
    if (payload.org) |org| {
        try writeJsonString(writer, org);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

test "canonical payload serialization is stable" {
    const alloc = std.testing.allocator;
    var payload = types.LicensePayload{
        .schema = 1,
        .license_id = try alloc.dupe(u8, "TRACE-2026-0001"),
        .product = .trace,
        .tier = .individual,
        .issued_to = try alloc.dupe(u8, "jane@example.com"),
        .issued_at = 123,
        .expires_at = null,
        .org = try alloc.dupe(u8, "Acme"),
    };
    defer payload.deinit(alloc);
    const canonical = try canonicalPayloadAlloc(alloc, payload);
    defer alloc.free(canonical);
    try std.testing.expectEqualStrings(
        "{\"expires_at\":null,\"issued_at\":123,\"issued_to\":\"jane@example.com\",\"license_id\":\"TRACE-2026-0001\",\"org\":\"Acme\",\"product\":\"trace\",\"schema\":1,\"tier\":\"individual\"}",
        canonical,
    );
}
