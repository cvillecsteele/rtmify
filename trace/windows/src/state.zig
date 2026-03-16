// state.zig — App state machine, output path logic, project name derivation

const std = @import("std");
const bridge = @import("bridge.zig");

// ---------------------------------------------------------------------------
// Enumerations
// ---------------------------------------------------------------------------

pub const Format = enum { pdf, docx, md, all };

pub const AppStateTag = enum {
    license_gate,
    drop_zone,
    file_loaded,
    generating,
    done,
};

// ---------------------------------------------------------------------------
// Data structs
// ---------------------------------------------------------------------------

pub const FileSummary = struct {
    path_utf8: [1024:0]u8 = std.mem.zeroes([1024:0]u8),
    display_name: [256:0]u8 = std.mem.zeroes([256:0]u8),
    profile: bridge.RtmifyProfile = .generic,
    profile_display_name: [32:0]u8 = std.mem.zeroes([32:0]u8),
    profile_standards: [128:0]u8 = std.mem.zeroes([128:0]u8),
    generic_gap_count: i32 = 0,
    profile_gap_count: i32 = 0,
    total_gap_count: i32 = 0,
    warning_count: i32 = 0,
};

pub const GenerateResult = struct {
    output_paths: [3][1024:0]u8 = std.mem.zeroes([3][1024:0]u8),
    path_count: usize = 0,
    profile: bridge.RtmifyProfile = .generic,
    profile_display_name: [32:0]u8 = std.mem.zeroes([32:0]u8),
    profile_standards: [128:0]u8 = std.mem.zeroes([128:0]u8),
    generic_gap_count: i32 = 0,
    profile_gap_count: i32 = 0,
    total_gap_count: i32 = 0,
    warning_count: i32 = 0,
};

pub const AppState = struct {
    tag: AppStateTag = .drop_zone,
    graph: ?*bridge.RtmifyGraph = null,
    summary: ?FileSummary = null,
    result: ?GenerateResult = null,
    activation_error: [256:0]u8 = std.mem.zeroes([256:0]u8),
    has_activation_error: bool = false,
    selected_profile: bridge.RtmifyProfile = .generic,
    format: Format = .pdf,
};

// ---------------------------------------------------------------------------
// outputPath — "requirements.xlsx" + "pdf" → "C:\dir\requirements-rtm.pdf"
// Appends numeric suffix if the candidate file already exists.
// ---------------------------------------------------------------------------

fn defaultPathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn outputPathWithExists(
    input: []const u8,
    fmt: []const u8,
    buf: []u8,
    path_exists: *const fn ([]const u8) bool,
    fallback_seed: u64,
) []u8 {
    const basename = std.fs.path.basenameWindows(input);
    const ext_str = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext_str.len];
    const dir = std.fs.path.dirnameWindows(input) orelse ".";

    const candidate = std.fmt.bufPrint(buf, "{s}\\{s}-rtm.{s}", .{ dir, stem, fmt }) catch
        return buf[0..0];

    if (!path_exists(candidate)) return candidate;

    var tmp: [1024]u8 = undefined;
    var i: u32 = 2;
    while (i <= 99) : (i += 1) {
        const numbered = std.fmt.bufPrint(&tmp, "{s}\\{s}-rtm-{d}.{s}", .{ dir, stem, i, fmt }) catch break;
        if (!path_exists(numbered)) {
            const n = @min(numbered.len, buf.len);
            @memcpy(buf[0..n], numbered[0..n]);
            return buf[0..n];
        }
    }

    var attempt: u32 = 0;
    while (attempt < 1024) : (attempt += 1) {
        const suffix = fallback_seed + attempt;
        const unique = std.fmt.bufPrint(&tmp, "{s}\\{s}-rtm-{d}.{s}", .{ dir, stem, suffix, fmt }) catch
            return buf[0..0];
        if (!path_exists(unique)) {
            const n = @min(unique.len, buf.len);
            @memcpy(buf[0..n], unique[0..n]);
            return buf[0..n];
        }
    }

    return buf[0..0];
}

pub fn outputPath(input: []const u8, fmt: []const u8, buf: []u8) []u8 {
    const fallback_seed: u64 = @intCast(@max(std.time.milliTimestamp(), 0));
    return outputPathWithExists(input, fmt, buf, defaultPathExists, fallback_seed);
}

// ---------------------------------------------------------------------------
// projectName — "requirements.xlsx" → "requirements"
// ---------------------------------------------------------------------------

pub fn projectName(input: []const u8, buf: []u8) []u8 {
    const basename = std.fs.path.basenameWindows(input);
    const ext_str = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext_str.len];
    const n = @min(stem.len, buf.len);
    @memcpy(buf[0..n], stem[0..n]);
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// formatSlice — Format enum → format string slice
// ---------------------------------------------------------------------------

pub fn formatSlice(fmt: Format) []const u8 {
    return switch (fmt) {
        .pdf => "pdf",
        .docx => "docx",
        .md => "md",
        .all => "all",
    };
}

const testing = std.testing;

test "outputPath keeps base name when unused" {
    const Probe = struct {
        fn exists(_: []const u8) bool {
            return false;
        }
    };

    var buf: [1024]u8 = undefined;
    const out = outputPathWithExists("C:\\work\\requirements.xlsx", "pdf", &buf, Probe.exists, 123456);
    try testing.expectEqualStrings("C:\\work\\requirements-rtm.pdf", out);
}

test "outputPath uses numbered suffix when base export exists" {
    const Probe = struct {
        fn exists(path: []const u8) bool {
            return std.mem.eql(u8, path, "C:\\work\\requirements-rtm.pdf");
        }
    };

    var buf: [1024]u8 = undefined;
    const out = outputPathWithExists("C:\\work\\requirements.xlsx", "pdf", &buf, Probe.exists, 123456);
    try testing.expectEqualStrings("C:\\work\\requirements-rtm-2.pdf", out);
}

test "outputPath uses timestamp-based suffix after numbered slots are exhausted" {
    const Probe = struct {
        fn exists(path: []const u8) bool {
            if (std.mem.eql(u8, path, "C:\\work\\requirements-rtm.pdf")) return true;

            var tmp: [1024]u8 = undefined;
            var i: u32 = 2;
            while (i <= 99) : (i += 1) {
                const numbered = std.fmt.bufPrint(&tmp, "C:\\work\\requirements-rtm-{d}.pdf", .{i}) catch unreachable;
                if (std.mem.eql(u8, path, numbered)) return true;
            }

            return false;
        }
    };

    var buf: [1024]u8 = undefined;
    const out = outputPathWithExists("C:\\work\\requirements.xlsx", "pdf", &buf, Probe.exists, 123456);
    try testing.expectEqualStrings("C:\\work\\requirements-rtm-123456.pdf", out);
}
