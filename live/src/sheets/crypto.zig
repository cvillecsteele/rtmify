const std = @import("std");
const Allocator = std.mem.Allocator;

const der = std.crypto.Certificate.der;
const RsaModulus = std.crypto.ff.Modulus(4096);
const testing = std.testing;

pub const SheetsError = error{
    InvalidPem,
    InvalidDer,
    InvalidKey,
    HttpError,
    AuthError,
    ApiError,
    OutOfMemory,
};

pub const RsaKey = struct {
    n: []const u8,
    d: []const u8,
    modulus_len: usize,

    pub fn deinit(k: *const RsaKey, alloc: Allocator) void {
        alloc.free(k.n);
        alloc.free(k.d);
    }
};

fn stripLeadingZero(bytes: []const u8) []const u8 {
    if (bytes.len > 0 and bytes[0] == 0x00) return bytes[1..];
    return bytes;
}

pub fn parsePemRsaKey(pem: []const u8, alloc: Allocator) (SheetsError || Allocator.Error)!RsaKey {
    const begin_marker = "-----BEGIN";
    const end_marker = "-----END";
    const begin_idx = std.mem.indexOf(u8, pem, begin_marker) orelse return error.InvalidPem;
    const after_begin = std.mem.indexOfScalarPos(u8, pem, begin_idx, '\n') orelse return error.InvalidPem;
    const end_idx = std.mem.indexOf(u8, pem, end_marker) orelse return error.InvalidPem;

    const b64_body = std.mem.trim(u8, pem[after_begin + 1 .. end_idx], " \t\r\n");
    const b64_clean = try alloc.alloc(u8, b64_body.len);
    defer alloc.free(b64_clean);

    var clean_len: usize = 0;
    for (b64_body) |ch| {
        if (ch != '\n' and ch != '\r' and ch != ' ' and ch != '\t') {
            b64_clean[clean_len] = ch;
            clean_len += 1;
        }
    }
    const b64 = b64_clean[0..clean_len];
    const der_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.InvalidPem;
    const der_bytes = try alloc.alloc(u8, der_len);
    defer alloc.free(der_bytes);
    std.base64.standard.Decoder.decode(der_bytes, b64) catch return error.InvalidPem;

    return parseDerRsaKey(der_bytes, alloc);
}

fn parseDerRsaKey(data: []const u8, alloc: Allocator) (SheetsError || Allocator.Error)!RsaKey {
    const outer = der.Element.parse(data, 0) catch return error.InvalidDer;
    if (outer.identifier.tag != .sequence) return error.InvalidDer;

    const version = der.Element.parse(data, outer.slice.start) catch return error.InvalidDer;
    if (version.identifier.tag != .integer) return error.InvalidDer;

    const alg_id = der.Element.parse(data, version.slice.end) catch return error.InvalidDer;
    if (alg_id.identifier.tag != .sequence) return error.InvalidDer;

    const priv_key_oct = der.Element.parse(data, alg_id.slice.end) catch return error.InvalidDer;
    if (priv_key_oct.identifier.tag != .octetstring) return error.InvalidDer;

    const rsa_priv = data[priv_key_oct.slice.start..priv_key_oct.slice.end];
    const inner = der.Element.parse(rsa_priv, 0) catch return error.InvalidDer;
    if (inner.identifier.tag != .sequence) return error.InvalidDer;

    const rsa_ver = der.Element.parse(rsa_priv, inner.slice.start) catch return error.InvalidDer;
    if (rsa_ver.identifier.tag != .integer) return error.InvalidDer;

    const n_elem = der.Element.parse(rsa_priv, rsa_ver.slice.end) catch return error.InvalidDer;
    if (n_elem.identifier.tag != .integer) return error.InvalidDer;
    const n_bytes = stripLeadingZero(rsa_priv[n_elem.slice.start..n_elem.slice.end]);
    if (n_bytes.len == 0) return error.InvalidKey;

    const e_elem = der.Element.parse(rsa_priv, n_elem.slice.end) catch return error.InvalidDer;
    if (e_elem.identifier.tag != .integer) return error.InvalidDer;

    const d_elem = der.Element.parse(rsa_priv, e_elem.slice.end) catch return error.InvalidDer;
    if (d_elem.identifier.tag != .integer) return error.InvalidDer;
    const d_bytes = stripLeadingZero(rsa_priv[d_elem.slice.start..d_elem.slice.end]);
    if (d_bytes.len == 0) return error.InvalidKey;

    return .{
        .n = try alloc.dupe(u8, n_bytes),
        .d = try alloc.dupe(u8, d_bytes),
        .modulus_len = n_bytes.len,
    };
}

const sha256_digest_info_prefix = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};
const t_len = sha256_digest_info_prefix.len + 32;

pub fn rs256Sign(message: []const u8, key: RsaKey, alloc: Allocator) (SheetsError || Allocator.Error)![]u8 {
    const mod_len = key.modulus_len;
    if (mod_len < t_len + 11) return error.InvalidKey;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &hash, .{});

    const em = try alloc.alloc(u8, mod_len);
    defer alloc.free(em);
    em[0] = 0x00;
    em[1] = 0x01;
    const ps_len = mod_len - t_len - 3;
    @memset(em[2 .. 2 + ps_len], 0xff);
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len ..][0..sha256_digest_info_prefix.len], &sha256_digest_info_prefix);
    @memcpy(em[3 + ps_len + sha256_digest_info_prefix.len ..][0..32], &hash);

    const n_mod = RsaModulus.fromBytes(key.n, .big) catch return error.InvalidKey;
    const em_fe = RsaModulus.Fe.fromBytes(n_mod, em, .big) catch return error.InvalidKey;
    const sig_fe = n_mod.powWithEncodedExponent(em_fe, key.d, .big) catch return error.InvalidKey;

    const sig = try alloc.alloc(u8, mod_len);
    sig_fe.toBytes(sig, .big) catch return error.InvalidKey;
    return sig;
}

test "invalid PEM returns InvalidPem" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidPem, parsePemRsaKey("not a pem", arena.allocator()));
}

test "invalid DER returns InvalidDer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidDer, parseDerRsaKey(&[_]u8{ 0x01, 0x02 }, arena.allocator()));
}

test "empty modulus or private exponent returns InvalidKey" {
    const invalid_pkcs8 = [_]u8{
        0x30, 0x15,
        0x02, 0x01,
        0x00, 0x30,
        0x00, 0x04,
        0x0e, 0x30,
        0x0c, 0x02,
        0x01, 0x00,
        0x02, 0x01,
        0x00, 0x02,
        0x01, 0x01,
        0x02, 0x01,
        0x00,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidKey, parseDerRsaKey(&invalid_pkcs8, arena.allocator()));
}

test "rs256Sign rejects too-small modulus" {
    const key = RsaKey{
        .n = &[_]u8{0x01},
        .d = &[_]u8{0x01},
        .modulus_len = 1,
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidKey, rs256Sign("msg", key, arena.allocator()));
}

test "stripLeadingZero" {
    const a = [_]u8{ 0x00, 0x01, 0x02 };
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, stripLeadingZero(&a));
    const b = [_]u8{ 0x01, 0x02 };
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, stripLeadingZero(&b));
}

test "sha256_digest_info_prefix length" {
    try testing.expectEqual(@as(usize, 19), sha256_digest_info_prefix.len);
    try testing.expectEqual(@as(usize, 51), t_len);
}
