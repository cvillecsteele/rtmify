/// annotations.zig — Source code annotation scanner.
///
/// Scans source files for requirement ID references inside comments.
/// Uses a per-language state machine to distinguish comment context from
/// code and string literals.

const std = @import("std");
const Allocator = std.mem.Allocator;
const GraphDb = @import("graph_live.zig").GraphDb;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Annotation = struct {
    req_id: []const u8,
    file_path: []const u8,
    line_number: u32,
    context: []const u8, // full trimmed line
};

pub const UnknownAnnotationRef = struct {
    ref_id: []const u8,
    file_path: []const u8,
    line_number: u32,
    context: []const u8,
};

pub const ScanResult = struct {
    annotations: []Annotation,
    unknown_refs: []UnknownAnnotationRef,
};

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

const CommentStyle = enum {
    c_style,   // // and /* */ — C, C++, Java, Go, Rust, Zig, JS, TS, Swift, CS, Kotlin, Scala
    python,    // # and """ """
    ruby,      // # and =begin/=end
    unknown,
};

fn detectStyle(path: []const u8) CommentStyle {
    const ext = std.fs.path.extension(path);
    const c_exts = &[_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".java", ".go", ".rs", ".zig", ".js", ".ts", ".jsx", ".tsx", ".swift", ".cs", ".kt", ".scala", ".v", ".sv", ".vhd", ".vhdl" };
    for (c_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .c_style;
    const py_exts = &[_][]const u8{ ".py" };
    for (py_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .python;
    const rb_exts = &[_][]const u8{ ".rb" };
    for (rb_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .ruby;
    return .unknown;
}

// ---------------------------------------------------------------------------
// Core scanner
// ---------------------------------------------------------------------------

/// Scan a single file for req_id references inside comment blocks.
/// Only matches IDs from known_req_ids. Caller owns returned slice and strings.
pub fn scanFile(
    file_path: []const u8,
    known_req_ids: []const []const u8,
    alloc: Allocator,
) ![]Annotation {
    const result = try scanFileDetailed(file_path, known_req_ids, alloc);
    for (result.unknown_refs) |unknown| {
        alloc.free(unknown.ref_id);
        alloc.free(unknown.file_path);
        alloc.free(unknown.context);
    }
    alloc.free(result.unknown_refs);
    return result.annotations;
}

pub fn scanFileDetailed(
    file_path: []const u8,
    known_req_ids: []const []const u8,
    alloc: Allocator,
) !ScanResult {
    var annotations: std.ArrayList(Annotation) = .empty;
    var unknown_refs: std.ArrayList(UnknownAnnotationRef) = .empty;
    if (known_req_ids.len == 0) {
        return .{
            .annotations = try annotations.toOwnedSlice(alloc),
            .unknown_refs = try unknown_refs.toOwnedSlice(alloc),
        };
    }

    const style = detectStyle(file_path);
    if (style == .unknown) {
        return .{
            .annotations = try annotations.toOwnedSlice(alloc),
            .unknown_refs = try unknown_refs.toOwnedSlice(alloc),
        };
    }

    const content = std.fs.cwd().readFileAlloc(alloc, file_path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            return .{
                .annotations = try annotations.toOwnedSlice(alloc),
                .unknown_refs = try unknown_refs.toOwnedSlice(alloc),
            };
        }
        return err;
    };
    defer alloc.free(content);

    // Detect binary: look for null bytes in first 8KB
    const probe = content[0..@min(content.len, 8192)];
    for (probe) |b| {
        if (b == 0) {
            return .{
                .annotations = try annotations.toOwnedSlice(alloc),
                .unknown_refs = try unknown_refs.toOwnedSlice(alloc),
            };
        }
    }

    switch (style) {
        .unknown => {},
        else => try scanLineByLine(content, file_path, known_req_ids, alloc, &annotations, &unknown_refs),
    }

    return .{
        .annotations = try annotations.toOwnedSlice(alloc),
        .unknown_refs = try unknown_refs.toOwnedSlice(alloc),
    };
}

// ---------------------------------------------------------------------------
// C-style comment scanner
// ---------------------------------------------------------------------------

/// Primary scan: iterate lines, track comment state, search for req IDs in comment text.
fn scanLineByLine(
    content: []const u8,
    file_path: []const u8,
    known_req_ids: []const []const u8,
    alloc: Allocator,
    annotations: *std.ArrayList(Annotation),
    unknown_refs: *std.ArrayList(UnknownAnnotationRef),
) !void {
    var line_num: u32 = 0;
    var in_block_comment = false;
    const in_multiline_str = false; // Python triple-quote (reserved for future use)

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        var is_comment_line = in_block_comment;

        // Detect comment start/end on this line
        if (!in_block_comment and !in_multiline_str) {
            if (std.mem.indexOf(u8, trimmed, "//") != null and !isInString(trimmed, "//")) {
                is_comment_line = true;
            } else if (std.mem.indexOf(u8, trimmed, "/*") != null) {
                in_block_comment = true;
                is_comment_line = true;
            } else if (trimmed.len > 0 and trimmed[0] == '#') {
                is_comment_line = true;
            } else if (std.mem.startsWith(u8, trimmed, "=begin")) {
                in_block_comment = true;
                is_comment_line = false; // =begin line itself not a comment body
            }
        }

        if (in_block_comment and std.mem.indexOf(u8, trimmed, "*/") != null) {
            in_block_comment = false;
        }
        if (in_block_comment and std.mem.startsWith(u8, trimmed, "=end")) {
            in_block_comment = false;
            is_comment_line = false;
        }

        if (!is_comment_line) continue;

        // Search for each known req ID in this comment line
        for (known_req_ids) |req_id| {
            if (std.mem.indexOf(u8, line, req_id) != null) {
                try annotations.append(alloc, .{
                    .req_id = try alloc.dupe(u8, req_id),
                    .file_path = try alloc.dupe(u8, file_path),
                    .line_number = line_num,
                    .context = try alloc.dupe(u8, trimmed),
                });
            }
        }

        try scanUnknownRefsInCommentLine(line, trimmed, file_path, line_num, known_req_ids, alloc, unknown_refs);
    }
}

/// Heuristic: check if needle appears to be inside a string literal on the line.
/// Simple check: count unescaped quotes before needle position.
fn isInString(line: []const u8, needle: []const u8) bool {
    const pos = std.mem.indexOf(u8, line, needle) orelse return false;
    var quote_count: usize = 0;
    var i: usize = 0;
    while (i < pos) {
        if (line[i] == '"' or line[i] == '\'') quote_count += 1;
        if (line[i] == '\\') i += 1; // skip escaped char
        i += 1;
    }
    return quote_count % 2 == 1;
}

fn scanUnknownRefsInCommentLine(
    line: []const u8,
    trimmed: []const u8,
    file_path: []const u8,
    line_num: u32,
    known_req_ids: []const []const u8,
    alloc: Allocator,
    unknown_refs: *std.ArrayList(UnknownAnnotationRef),
) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (!isIdChar(line[i])) {
            i += 1;
            continue;
        }

        const start = i;
        while (i < line.len and isIdChar(line[i])) : (i += 1) {}
        const token = line[start..i];

        if (!looksLikeKnownIdPattern(token, known_req_ids)) continue;
        if (containsId(known_req_ids, token)) continue;

        try unknown_refs.append(alloc, .{
            .ref_id = try alloc.dupe(u8, token),
            .file_path = try alloc.dupe(u8, file_path),
            .line_number = line_num,
            .context = try alloc.dupe(u8, trimmed),
        });
    }
}

fn isIdChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn containsId(known_req_ids: []const []const u8, candidate: []const u8) bool {
    for (known_req_ids) |req_id| {
        if (std.mem.eql(u8, req_id, candidate)) return true;
    }
    return false;
}

fn looksLikeKnownIdPattern(candidate: []const u8, known_req_ids: []const []const u8) bool {
    const dash_idx = std.mem.indexOfScalar(u8, candidate, '-') orelse return false;
    if (dash_idx == 0 or dash_idx + 1 >= candidate.len) return false;

    const prefix = candidate[0..dash_idx];
    const suffix = candidate[dash_idx + 1 ..];
    var suffix_has_alnum = false;
    for (suffix) |c| {
        if (!isIdChar(c)) return false;
        if (std.ascii.isAlphanumeric(c)) suffix_has_alnum = true;
    }
    if (!suffix_has_alnum) return false;

    for (known_req_ids) |known| {
        const known_dash_idx = std.mem.indexOfScalar(u8, known, '-') orelse continue;
        if (std.mem.eql(u8, known[0..known_dash_idx], prefix)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// ID list builder
// ---------------------------------------------------------------------------

/// Build a list of known requirement IDs from the graph database.
/// Returns types: Requirement, UserNeed, DesignInput, DesignOutput.
/// Caller owns the returned slice and all strings within it.
pub fn buildKnownIds(db: *GraphDb, alloc: Allocator) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    const types = &[_][]const u8{ "Requirement", "UserNeed", "DesignInput", "DesignOutput" };
    for (types) |t| {
        var st = try db.db.prepare(
            "SELECT id FROM nodes WHERE type=? ORDER BY id"
        );
        defer st.finalize();
        try st.bindText(1, t);
        while (try st.step()) {
            try result.append(alloc, try alloc.dupe(u8, st.columnText(0)));
        }
    }
    return result.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "scanFile C-style line comment with req ID" {
    // Write a temp file
    const tmp = "/tmp/test_annotations_c.c";
    {
        const f = try std.fs.cwd().createFile(tmp, .{});
        defer f.close();
        try f.writeAll(
            \\int foo() {
            \\    // REQ-001: GPS loss detection
            \\    return 0;
            \\}
        );
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ids = &[_][]const u8{ "REQ-001", "REQ-002" };
    const annotations = try scanFile(tmp, ids, alloc);
    try testing.expectEqual(@as(usize, 1), annotations.len);
    try testing.expectEqualStrings("REQ-001", annotations[0].req_id);
    try testing.expectEqual(@as(u32, 2), annotations[0].line_number);
}

test "scanFile Python hash comment with req ID" {
    const tmp = "/tmp/test_annotations_py.py";
    {
        const f = try std.fs.cwd().createFile(tmp, .{});
        defer f.close();
        try f.writeAll(
            \\def foo():
            \\    # REQ-001 verification
            \\    pass
        );
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ids = &[_][]const u8{"REQ-001"};
    const annotations = try scanFile(tmp, ids, alloc);
    try testing.expectEqual(@as(usize, 1), annotations.len);
    try testing.expectEqualStrings("REQ-001", annotations[0].req_id);
}

test "scanFile no match for unknown ID" {
    const tmp = "/tmp/test_annotations_nomatch.c";
    {
        const f = try std.fs.cwd().createFile(tmp, .{});
        defer f.close();
        try f.writeAll("// REQ-999: something\n");
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ids = &[_][]const u8{"REQ-001"}; // REQ-999 not in known list
    const annotations = try scanFile(tmp, ids, alloc);
    try testing.expectEqual(@as(usize, 0), annotations.len);
}

test "scanFile returns empty for unknown extension" {
    const tmp = "/tmp/test_annotations.yaml";
    {
        const f = try std.fs.cwd().createFile(tmp, .{});
        defer f.close();
        try f.writeAll("# REQ-001: yaml comment\n");
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ids = &[_][]const u8{"REQ-001"};
    const annotations = try scanFile(tmp, ids, alloc);
    try testing.expectEqual(@as(usize, 0), annotations.len);
}

test "scanFile multiple IDs on same line" {
    const tmp = "/tmp/test_annotations_multi.c";
    {
        const f = try std.fs.cwd().createFile(tmp, .{});
        defer f.close();
        try f.writeAll("// REQ-001 and REQ-002 both apply here\n");
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ids = &[_][]const u8{ "REQ-001", "REQ-002" };
    const annotations = try scanFile(tmp, ids, alloc);
    try testing.expectEqual(@as(usize, 2), annotations.len);
}

test "scanFileDetailed reports unknown requirement references in comments" {
    const tmp = "/tmp/test_annotations_unknown.c";
    {
        const f = try std.fs.cwd().createFile(tmp, .{});
        defer f.close();
        try f.writeAll(
            \\// REQ-001 implemented here
            \\// REQ-999 is stale
            \\const char *s = "REQ-888";
        );
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ids = &[_][]const u8{"REQ-001"};
    const scan = try scanFileDetailed(tmp, ids, alloc);
    try testing.expectEqual(@as(usize, 1), scan.annotations.len);
    try testing.expectEqual(@as(usize, 1), scan.unknown_refs.len);
    try testing.expectEqualStrings("REQ-999", scan.unknown_refs[0].ref_id);
    try testing.expectEqual(@as(u32, 2), scan.unknown_refs[0].line_number);
}
