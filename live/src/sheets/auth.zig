const std = @import("std");
const Allocator = std.mem.Allocator;

const crypto = @import("crypto.zig");
const jwt = @import("jwt.zig");
const transport = @import("transport.zig");
const json_fields = @import("json_fields.zig");
const testing = std.testing;

pub const TokenCache = struct {
    token: [1024]u8 = .{0} ** 1024,
    token_len: usize = 0,
    expires_at: i64 = 0,
    mu: std.Thread.Mutex = .{},

    pub fn getToken(
        cache: *TokenCache,
        email: []const u8,
        key: crypto.RsaKey,
        client: *std.http.Client,
        alloc: Allocator,
    ) (crypto.SheetsError || Allocator.Error)![]const u8 {
        cache.mu.lock();
        defer cache.mu.unlock();

        if (std.time.timestamp() < cache.expires_at - 60 and cache.token_len > 0) {
            return cache.token[0..cache.token_len];
        }

        const built_jwt = try jwt.buildJwt(email, key, alloc);
        defer alloc.free(built_jwt);

        const new_token = try exchangeToken(client, built_jwt, alloc);
        defer alloc.free(new_token);

        if (new_token.len > cache.token.len) return error.AuthError;
        @memcpy(cache.token[0..new_token.len], new_token);
        cache.token_len = new_token.len;
        cache.expires_at = std.time.timestamp() + 3600;
        return cache.token[0..cache.token_len];
    }
};

fn exchangeToken(client: *std.http.Client, built_jwt: []const u8, alloc: Allocator) (crypto.SheetsError || Allocator.Error)![]u8 {
    const body_str = try std.fmt.allocPrint(
        alloc,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}",
        .{built_jwt},
    );
    defer alloc.free(body_str);

    const resp = transport.httpDo(
        client,
        .POST,
        jwt.OAUTH2_TOKEN_URL,
        "",
        body_str,
        "application/x-www-form-urlencoded",
        alloc,
    ) catch |err| switch (err) {
        error.ApiError => return error.AuthError,
        else => return err,
    };
    defer alloc.free(resp);

    return json_fields.extractJsonString(resp, "access_token", alloc) orelse error.AuthError;
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

test "cached token reused before expiry" {
    var cache = TokenCache{};
    @memcpy(cache.token[0..3], "tok");
    cache.token_len = 3;
    cache.expires_at = std.time.timestamp() + 3600;

    var client: std.http.Client = .{ .allocator = testing.allocator };
    defer client.deinit();
    const token = try cache.getToken("svc@example.com", .{ .n = &.{}, .d = &.{}, .modulus_len = 0 }, &client, testing.allocator);
    try testing.expectEqualStrings("tok", token);
}

test "expired token triggers refresh" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = try parseTestKey(alloc);
    var cache = TokenCache{ .expires_at = 0 };
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = jwt.OAUTH2_TOKEN_URL,
                .token = "",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"fresh-token\"}",
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    const token = try cache.getToken("svc@example.com", key, &client, alloc);
    try testing.expectEqualStrings("fresh-token", token);
    try mock.expectDone();
}

test "oversized token buffer returns AuthError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const key = try parseTestKey(alloc);
    var cache = TokenCache{ .expires_at = 0 };
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    const long_value = try alloc.alloc(u8, 1025);
    @memset(long_value, 'a');
    const body = try std.fmt.allocPrint(alloc, "{{\"access_token\":\"{s}\"}}", .{long_value});

    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = jwt.OAUTH2_TOKEN_URL,
                .token = "",
                .content_type = "application/x-www-form-urlencoded",
                .body = body,
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    try testing.expectError(error.AuthError, cache.getToken("svc@example.com", key, &client, alloc));
}

test "exchange token parses access token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = jwt.OAUTH2_TOKEN_URL,
                .token = "",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"access_token\":\"ya29.parsed\"}",
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    const token = try exchangeToken(&client, "jwt", alloc);
    defer alloc.free(token);
    try testing.expectEqualStrings("ya29.parsed", token);
}

test "missing access_token returns AuthError" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var mock = transport.MockHttp{
        .exchanges = &.{
            .{
                .method = .POST,
                .url = jwt.OAUTH2_TOKEN_URL,
                .token = "",
                .content_type = "application/x-www-form-urlencoded",
                .body = "{\"token_type\":\"Bearer\"}",
            },
        },
    };
    transport.useMockHttp(&mock);
    defer transport.clearMockHttp();

    try testing.expectError(error.AuthError, exchangeToken(&client, "jwt", alloc));
}
