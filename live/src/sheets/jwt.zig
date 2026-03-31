const std = @import("std");
const Allocator = std.mem.Allocator;

const crypto = @import("crypto.zig");
const testing = std.testing;

pub const OAUTH2_TOKEN_URL = "https://oauth2.googleapis.com/token";
pub const SHEETS_SCOPE = "https://www.googleapis.com/auth/spreadsheets https://www.googleapis.com/auth/drive.readonly";

pub fn buildJwt(email: []const u8, key: crypto.RsaKey, alloc: Allocator) (crypto.SheetsError || Allocator.Error)![]u8 {
    const now = std.time.timestamp();
    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const claims_json = try std.fmt.allocPrint(
        alloc,
        "{{\"iss\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ email, SHEETS_SCOPE, OAUTH2_TOKEN_URL, now, now + 3600 },
    );
    defer alloc.free(claims_json);

    const enc = std.base64.url_safe_no_pad.Encoder;
    const header_b64_len = enc.calcSize(header_json.len);
    const claims_b64_len = enc.calcSize(claims_json.len);

    const signing_input = try alloc.alloc(u8, header_b64_len + 1 + claims_b64_len);
    defer alloc.free(signing_input);
    _ = enc.encode(signing_input[0..header_b64_len], header_json);
    signing_input[header_b64_len] = '.';
    _ = enc.encode(signing_input[header_b64_len + 1 ..], claims_json);

    const sig_bytes = try crypto.rs256Sign(signing_input, key, alloc);
    defer alloc.free(sig_bytes);

    const sig_b64_len = enc.calcSize(sig_bytes.len);
    const sig_b64 = try alloc.alloc(u8, sig_b64_len);
    defer alloc.free(sig_b64);
    _ = enc.encode(sig_b64, sig_bytes);

    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ signing_input, sig_b64 });
}

const test_pem =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCzOEP0lGVvqGuz
    \\aI9SG1hfcAjJw+CtSLYl/QvZKcFgGSwtNcGn4QyfkfDCGea0Jpfa0C8Ud+AQ3vnB
    \\96172P1oQVeWoboYgJp89Q9IWUbCVmf3Xfcu25GdesExeCmNhorELqdchGKHWZVu
    \\Fb4OsO6mefKYVawKWKvKWNtbx/crVFYBIvrawDPb4id1/FU1Tgd9CFVy3XvhMrrC
    \\AAubCCGS9m79EuG912FuMyyhZj8zdyd7ALb8E80nZhKaAnUkjbPtZxM8dw3+TmyB
    \\hv37xUiBfGSTkWOLAyDJrQu4kHJbfa8hHcBQopf8kPPKG90XTGhjSSj/1x4JUr6P
    \\0cIuIrQLAgMBAAECggEAIDy8OIfi8SFF8jkaIqZJkK0533Us+m6MWSv50B/LKWqN
    \\wDodsgFwwFlDid6X2YrhoNn2xgNEGjTJj0LqgU8IUhMC2tUPgO3NHDIGhDiO2lEp
    \\lVzhJBwZxs54Ztoa+1qapmxP7Xvgr0EFeI5PqBvaabag1RcAAcJucFDocEt5YeEV
    \\5GxfFLh5XCb0I6K5Gwa5+pCCH28arm41ibUK5PiH0Lc2qatR3aQuuPP/GhD5PIYc
    \\l7qd0deUlU1DeOEKbIjWyeS4wiRFex4GnXz+BFuhIAhv8zIJhuasP8ToiS54D9Dt
    \\0iKvNamCRqAWmS81tqfd9N5hzEHkRRzFpnYyJAu8JQKBgQDn2Lk8NH7N4rjli8te
    \\j3LPL0N1VHEVS1/0VseO+UBn3CVeAA6QP07D4X0P+bqk5Dxs/+zdkkPtdBs6cggg
    \\z+zP3rnjf8i18M8M6bGc3Ne24A0t2cH3G4+KciCk/E06/p7DCdbuu2to2ygAsdBI
    \\MWthoaaI41i3cton8g/2lI2NdwKBgQDF5ABuuK4sJAALfgxVhR97/IpTKTjmBnpW
    \\R2BjT4sDDgnmZRHhF7qLLMadbhEY3vBZLKrGZBTFC+LtTfWAekzXtOmx7Yqj2ujo
    \\k+wa6n3JJOyG2vMC6xOqAdTnmL7tb1+C0iHtKmZ44uGnT4uMbn48zXaSHL1Hb5v1
    \\SEv2Lg7jDQKBgQDO4L0RMsp/jrJr6ZzTyO6qX0Mze+DYHoUFszWop1LIGlGhmi1k
    \\m4j+EsQUsELShfJBVPCYGb7RMIxnT39fQAnQxq5aiRig+LrYi+L31LwLq8s2wZtp
    \\k0c3Q3VLovKLFM63vJz0M3q5eu0sCX6QHMDzwlmmxi7QqwRtJnsGDTJuKwKBgEtp
    \\oxyOtplNstKuW2bvz1rBl7kvWWaXi2F72+ictH4aiH1LgO/Fyiolix8NhehzdSaW
    \\lhH6q8uXxwfmEKvAb644XGKZAp+E2gNf87ciK4NO1fBiWf9/tEOyZP9JP2Fecwh4
    \\qcMmyFxDIflPn/+JUAQ9zHTMDPm/N7DWt1P+o1+1AoGBANE6ykje+m6+GkOnG5oj
    \\mEGnjMi3QyrK/BQqtw5s083zqTnDGu75Jyjbjb45tG2deiWx8H+xSrLNmmUjXXkV
    \\gsYgkxQBIXGMTLeLliX/6lrvsIi/qAPXkZy0PjJesYP+6+96luEpbOjL+mlTqy29
    \\NchZ0gaGIA3xdY/L6/Ydi+Pw
    \\-----END PRIVATE KEY-----
;

fn parseTestKey(alloc: Allocator) !crypto.RsaKey {
    return crypto.parsePemRsaKey(test_pem, alloc);
}

test "buildJwt returns exactly 3 dot-separated segments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = try parseTestKey(alloc);

    const jwt = try buildJwt("svc@example.com", key, alloc);
    const first = std.mem.indexOfScalar(u8, jwt, '.') orelse unreachable;
    const second = std.mem.indexOfScalarPos(u8, jwt, first + 1, '.') orelse unreachable;
    try testing.expect(first > 0);
    try testing.expect(second > first + 1);
    try testing.expect(second + 1 < jwt.len);
}

test "JWT header decodes to expected JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = try parseTestKey(alloc);
    const jwt = try buildJwt("svc@example.com", key, alloc);

    const first = std.mem.indexOfScalar(u8, jwt, '.') orelse unreachable;
    const header_b64 = jwt[0..first];
    const dec = std.base64.url_safe_no_pad.Decoder;
    const header_len = try dec.calcSizeForSlice(header_b64);
    const header = try alloc.alloc(u8, header_len);
    _ = try dec.decode(header, header_b64);
    try testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", header);
}
