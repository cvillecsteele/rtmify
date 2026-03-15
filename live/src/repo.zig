/// repo.zig — Repository filesystem scanner.
///
/// Walks a directory tree, classifies files by kind (source/test/ignored),
/// and returns files modified since a given timestamp.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const FileKind = enum { source, test_file, ignored };

pub const ScannedFile = struct {
    path: []const u8,
    kind: FileKind,
    mtime: i64,
};

// ---------------------------------------------------------------------------
// Source/test classification
// ---------------------------------------------------------------------------

const source_extensions = &[_][]const u8{
    ".c", ".h", ".cpp", ".hpp", ".cc", ".cxx",
    ".py", ".js", ".ts", ".jsx", ".tsx",
    ".go", ".rs", ".zig",
    ".java", ".cs", ".swift",
    ".vhdl", ".vhd", ".v", ".sv",
    ".rb", ".kt", ".scala", ".m",
};

const ignored_dirs = &[_][]const u8{
    ".git", "node_modules", "venv", ".venv", "build", "dist",
    "zig-out", "zig-cache", ".zig-cache", "__pycache__",
    ".build", ".gradle", "target", "vendor",
};

/// Classify a file path as source, test_file, or ignored.
pub fn classifyFile(path: []const u8) FileKind {
    // Check for ignored directory components — split on both separators for portability
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        for (ignored_dirs) |d| {
            if (std.mem.eql(u8, component, d)) return .ignored;
        }
    }

    const basename = std.fs.path.basename(path);

    // Classify as test by path patterns
    if (isTestPath(path, basename)) return .test_file;

    // Check for recognized source extension
    const ext = std.fs.path.extension(basename);
    for (source_extensions) |se| {
        if (std.ascii.eqlIgnoreCase(ext, se)) return .source;
    }

    return .ignored;
}

fn isTestPath(path: []const u8, basename: []const u8) bool {
    // Directory components containing test markers — split on both separators for portability
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, "test") or
            std.ascii.eqlIgnoreCase(component, "tests") or
            std.ascii.eqlIgnoreCase(component, "spec") or
            std.ascii.eqlIgnoreCase(component, "specs"))
        {
            return true;
        }
    }
    // Filename patterns: test_*.*, *_test.*, *.test.*, *.spec.*
    if (std.mem.startsWith(u8, basename, "test_")) return true;
    const ext = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext.len];
    if (std.mem.endsWith(u8, stem, "_test")) return true;
    if (std.mem.endsWith(u8, stem, ".test")) return true;
    if (std.mem.endsWith(u8, stem, ".spec")) return true;
    // Also match *.test.* and *.spec.* patterns in the stem
    if (std.mem.indexOf(u8, stem, ".test") != null) return true;
    if (std.mem.indexOf(u8, stem, ".spec") != null) return true;
    return false;
}

// ---------------------------------------------------------------------------
// .gitignore parsing
// ---------------------------------------------------------------------------

/// Read .gitignore in repo_path and return a list of patterns.
/// Simple patterns only: prefix **, suffix *, and exact matches.
/// Caller owns the returned slice and all strings within it.
pub fn parseGitignore(repo_path: []const u8, alloc: Allocator) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const gi_path = std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{repo_path}) catch return result.toOwnedSlice(alloc);

    const content = std.fs.cwd().readFileAlloc(alloc, gi_path, 1024 * 1024) catch return result.toOwnedSlice(alloc);
    defer alloc.free(content);

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        try result.append(alloc, try alloc.dupe(u8, line));
    }
    return result.toOwnedSlice(alloc);
}

fn matchesGitignore(patterns: []const []const u8, path: []const u8, basename: []const u8) bool {
    for (patterns) |pat| {
        if (matchPattern(pat, path, basename)) return true;
    }
    return false;
}

fn matchPattern(pat: []const u8, path: []const u8, basename: []const u8) bool {
    // Negation patterns not supported (safe to ignore — just don't exclude)
    if (pat.len > 0 and pat[0] == '!') return false;
    // Exact match against basename
    if (std.mem.eql(u8, pat, basename)) return true;
    // Suffix wildcard: *.ext
    if (pat.len > 1 and pat[0] == '*') {
        const suffix = pat[1..];
        if (std.mem.endsWith(u8, basename, suffix)) return true;
    }
    // Directory match: pat/ matches any path component
    const pat_no_slash = if (std.mem.endsWith(u8, pat, "/")) pat[0 .. pat.len - 1] else pat;
    var it = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, pat_no_slash)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Directory walker
// ---------------------------------------------------------------------------

/// Scan repo_path for source and test files modified after last_scan_time.
/// Returns a caller-owned slice of ScannedFile (paths duped into alloc).
pub fn scanRepo(repo_path: []const u8, last_scan_time: i64, alloc: Allocator) ![]ScannedFile {
    var result: std.ArrayList(ScannedFile) = .empty;

    const patterns = parseGitignore(repo_path, alloc) catch &.{};
    defer alloc.free(patterns);

    var dir = std.fs.cwd().openDir(repo_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return result.toOwnedSlice(alloc);
        return err;
    };
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Skip ignored dirs by checking path components
        const kind = classifyFile(entry.path);
        if (kind == .ignored) continue;

        // Apply .gitignore patterns
        const basename = std.fs.path.basename(entry.path);
        if (matchesGitignore(patterns, entry.path, basename)) continue;

        // Check mtime
        const stat = dir.statFile(entry.path) catch continue;
        const mtime_sec: i64 = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        if (mtime_sec <= last_scan_time) continue;

        const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ repo_path, entry.path });
        try result.append(alloc, .{
            .path = full_path,
            .kind = kind,
            .mtime = mtime_sec,
        });
    }

    return result.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classifyFile source" {
    try testing.expectEqual(FileKind.source, classifyFile("src/gps/timeout.c"));
    try testing.expectEqual(FileKind.source, classifyFile("src/main.py"));
    try testing.expectEqual(FileKind.source, classifyFile("src/lib.zig"));
    try testing.expectEqual(FileKind.source, classifyFile("src/app.ts"));
}

test "classifyFile test_file by directory" {
    try testing.expectEqual(FileKind.test_file, classifyFile("test/gps/test_timeout.c"));
    try testing.expectEqual(FileKind.test_file, classifyFile("tests/test_main.py"));
    try testing.expectEqual(FileKind.test_file, classifyFile("spec/app_spec.rb"));
}

test "classifyFile test_file by filename pattern" {
    try testing.expectEqual(FileKind.test_file, classifyFile("src/gps/test_timeout.c"));
    try testing.expectEqual(FileKind.test_file, classifyFile("src/gps/timeout_test.c"));
}

test "classifyFile ignored by directory" {
    try testing.expectEqual(FileKind.ignored, classifyFile(".git/config"));
    try testing.expectEqual(FileKind.ignored, classifyFile("node_modules/pkg/index.js"));
    try testing.expectEqual(FileKind.ignored, classifyFile("zig-out/bin/main"));
}

test "classifyFile ignored unknown extension" {
    try testing.expectEqual(FileKind.ignored, classifyFile("src/config.yaml"));
    try testing.expectEqual(FileKind.ignored, classifyFile("README.md"));
}

test "parseGitignore returns empty slice when no .gitignore" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try std.fs.cwd().realpathAlloc(arena.allocator(), ".");
    defer arena.allocator().free(root);
    const missing_repo = try std.fs.path.join(arena.allocator(), &.{ root, "nonexistent_repo_xyz" });
    defer arena.allocator().free(missing_repo);
    const patterns = try parseGitignore(missing_repo, arena.allocator());
    try testing.expectEqual(@as(usize, 0), patterns.len);
}
