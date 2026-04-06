const builtin = @import("builtin");
const std = @import("std");

const default_version = "20260325-f";

pub fn createBuildOptionsModule(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const version = b.option([]const u8, "release-version", "Release version string") orelse default_version;

    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);

    const license_hmac_key_hex = loadLicenseHmacKeyHex(b, optimize);
    opts.addOption([]const u8, "license_hmac_key_hex", license_hmac_key_hex);

    const license_hmac_key_bytes = b.allocator.alloc(u8, 32) catch
        @panic("out of memory decoding license_hmac_key_hex");
    _ = std.fmt.hexToBytes(license_hmac_key_bytes, license_hmac_key_hex) catch
        @panic("invalid license_hmac_key_hex");

    const license_hmac_key_fingerprint_hex = fingerprintHex(b, license_hmac_key_bytes);
    opts.addOption([]const u8, "license_hmac_key_fingerprint_hex", license_hmac_key_fingerprint_hex);

    return opts.createModule();
}

fn trimAsciiWhitespace(bytes: []u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn defaultLicenseHmacKeyPath(b: *std.Build) ?[]const u8 {
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = b.graph.env_map.get(home_var) orelse return null;
    return b.pathJoin(&.{ home, ".rtmify", "secrets", "license-hmac-key.txt" });
}

fn fingerprintHex(b: *std.Build, key_bytes: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key_bytes, &digest, .{});
    return b.dupe(std.fmt.bytesToHex(&digest, .lower)[0..]);
}

fn loadLicenseHmacKeyHex(b: *std.Build, optimize: std.builtin.OptimizeMode) []const u8 {
    const key_file_opt = b.option([]const u8, "license-hmac-key-file", "Path to a 64-hex-char HMAC key file for signed RTMify licenses");
    const key_file_env = b.graph.env_map.get("RTMIFY_LICENSE_HMAC_KEY_FILE");
    const key_file_default = defaultLicenseHmacKeyPath(b);
    const key_file = key_file_opt orelse key_file_env orelse key_file_default;

    if (key_file) |path| {
        const bytes = std.fs.cwd().readFileAlloc(b.allocator, path, 1024) catch
            @panic("failed to read license HMAC key file");
        const trimmed = trimAsciiWhitespace(bytes);
        if (trimmed.len != 64) {
            @panic("license HMAC key file must contain exactly 64 lowercase hex chars");
        }
        return b.dupe(trimmed);
    }

    if (optimize != .Debug) {
        @panic("release builds require -Dlicense-hmac-key-file, RTMIFY_LICENSE_HMAC_KEY_FILE, or ~/.rtmify/secrets/license-hmac-key.txt");
    }

    return "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
}
