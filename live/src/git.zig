/// git.zig — Git integration for RTMify Live.
///
/// Runs git log and git blame via subprocess, parses output, and returns
/// structured Commit and BlameEntry values for graph ingestion.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const GitError = error{
    GitLogFailed,
    GitBlameFailed,
    CommitParseErr,
    BlameParseErr,
    Timeout,
};

const git_timeout_ms: u64 = 10_000;
const git_poll_ms: u32 = 50;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Commit = struct {
    hash: []const u8,       // full 40-char SHA
    short_hash: []const u8, // 7-char
    author: []const u8,
    email: []const u8,
    date_iso: []const u8,   // ISO 8601
    message: []const u8,
    req_ids: [][]const u8,  // matched from known_req_ids
    file_changes: []CommitFileChange,
};

pub const CommitFileChange = struct {
    status: []const u8, // e.g. M, A, D, R100
    path: []const u8,
    old_path: ?[]const u8,
};

pub const BlameEntry = struct {
    commit_hash: []const u8,
    author: []const u8,
    author_email: []const u8,
    author_time: i64,
};

pub const GitOptions = struct {
    exe: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
};

const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

// ---------------------------------------------------------------------------
// git log
// ---------------------------------------------------------------------------

/// Run git log and return commits that reference any known_req_ids.
/// `since_hash`: if non-null, only returns commits after that commit (exclusive).
/// Caller owns the returned slice and all strings within it.
pub fn gitLog(
    repo_path: []const u8,
    since_hash: ?[]const u8,
    known_req_ids: []const []const u8,
    alloc: Allocator,
) (GitError || Allocator.Error)![]Commit {
    return gitLogWithOptions(repo_path, since_hash, known_req_ids, .{}, alloc);
}

pub fn gitLogWithOptions(
    repo_path: []const u8,
    since_hash: ?[]const u8,
    known_req_ids: []const []const u8,
    options: GitOptions,
    alloc: Allocator,
) (GitError || Allocator.Error)![]Commit {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, options.exe orelse "git");
    try argv.append(alloc, "log");
    try argv.append(alloc, "--name-status");
    try argv.append(alloc, "--format=%x1e%H|%h|%an|%ae|%aI|%s");
    if (since_hash) |h| {
        const range = try std.fmt.allocPrint(alloc, "{s}..HEAD", .{h});
        try argv.append(alloc, range);
    }
    try argv.append(alloc, "--");
    try argv.append(alloc, ".");

    const result = runCommandWithTimeout(argv.items, repo_path, 10 * 1024 * 1024, options.timeout_ms orelse git_timeout_ms, alloc) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        else => return error.GitLogFailed,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.GitLogFailed,
        else => return error.GitLogFailed,
    }

    return parseGitLog(result.stdout, known_req_ids, alloc);
}

fn parseGitLog(output: []const u8, known_req_ids: []const []const u8, alloc: Allocator) (GitError || Allocator.Error)![]Commit {
    var commits: std.ArrayList(Commit) = .empty;
    var record_it = std.mem.splitScalar(u8, output, 0x1e);
    while (record_it.next()) |record_raw| {
        const record = std.mem.trim(u8, record_raw, "\r\n \t");
        if (record.len == 0) continue;

        var line_it = std.mem.splitScalar(u8, record, '\n');
        const header = line_it.next() orelse return error.CommitParseErr;
        const header_trimmed = std.mem.trim(u8, header, "\r \t");
        if (header_trimmed.len == 0) return error.CommitParseErr;

        var fields: [6][]const u8 = undefined;
        var fi: usize = 0;
        var field_it = std.mem.splitScalar(u8, header_trimmed, '|');
        while (field_it.next()) |f| {
            if (fi >= 6) break;
            fields[fi] = f;
            fi += 1;
        }
        if (fi < 6) return error.CommitParseErr;

        const message = fields[5];
        var matched: std.ArrayList([]const u8) = .empty;
        for (known_req_ids) |req_id| {
            if (std.mem.indexOf(u8, message, req_id) != null) {
                try matched.append(alloc, try alloc.dupe(u8, req_id));
            }
        }

        var file_changes: std.ArrayList(CommitFileChange) = .empty;
        while (line_it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, "\r \t");
            if (line.len == 0) continue;
            const change = try parseCommitFileChange(line, alloc);
            try file_changes.append(alloc, change);
        }

        try commits.append(alloc, .{
            .hash = try alloc.dupe(u8, fields[0]),
            .short_hash = try alloc.dupe(u8, fields[1]),
            .author = try alloc.dupe(u8, fields[2]),
            .email = try alloc.dupe(u8, fields[3]),
            .date_iso = try alloc.dupe(u8, fields[4]),
            .message = try alloc.dupe(u8, message),
            .req_ids = try matched.toOwnedSlice(alloc),
            .file_changes = try file_changes.toOwnedSlice(alloc),
        });
    }

    return commits.toOwnedSlice(alloc);
}

fn parseCommitFileChange(line: []const u8, alloc: Allocator) (GitError || Allocator.Error)!CommitFileChange {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const status = parts.next() orelse return error.CommitParseErr;
    const first_path = parts.next() orelse return error.CommitParseErr;
    const second_path = parts.next();

    if (status.len > 0 and (status[0] == 'R' or status[0] == 'C')) {
        const new_path = second_path orelse return error.CommitParseErr;
        return .{
            .status = try alloc.dupe(u8, status),
            .path = try alloc.dupe(u8, new_path),
            .old_path = try alloc.dupe(u8, first_path),
        };
    }

    return .{
        .status = try alloc.dupe(u8, status),
        .path = try alloc.dupe(u8, first_path),
        .old_path = null,
    };
}

// ---------------------------------------------------------------------------
// git blame
// ---------------------------------------------------------------------------

/// Run git blame --porcelain on a single line of a file.
/// Caller owns returned struct fields.
pub fn gitBlame(
    repo_path: []const u8,
    file_path: []const u8,
    line: u32,
    alloc: Allocator,
) (GitError || Allocator.Error)!BlameEntry {
    return gitBlameWithOptions(repo_path, file_path, line, .{}, alloc);
}

pub fn gitBlameWithOptions(
    repo_path: []const u8,
    file_path: []const u8,
    line: u32,
    options: GitOptions,
    alloc: Allocator,
) (GitError || Allocator.Error)!BlameEntry {
    const line_range = try std.fmt.allocPrint(alloc, "-L{d},{d}", .{ line, line });
    defer alloc.free(line_range);

    const result = runCommandWithTimeout(
        &.{ options.exe orelse "git", "blame", "--porcelain", line_range, "--", file_path },
        repo_path,
        64 * 1024,
        options.timeout_ms orelse git_timeout_ms,
        alloc,
    ) catch |err| switch (err) {
        error.Timeout => return error.Timeout,
        else => return error.GitBlameFailed,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.GitBlameFailed,
        else => return error.GitBlameFailed,
    }

    return parseBlame(result.stdout, alloc);
}

fn runCommandWithTimeout(
    argv: []const []const u8,
    cwd: []const u8,
    max_output_bytes: usize,
    timeout_ms: u64,
    alloc: Allocator,
) (Allocator.Error || std.process.Child.RunError || std.process.Child.WaitError || std.process.Child.SpawnError || std.os.windows.WaitForSingleObjectError || error{Timeout})!CommandResult {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;

    try child.spawn();
    try child.waitForSpawn();

    if (builtin.os.tag == .windows) {
        return runCommandWithTimeoutWindows(&child, alloc, max_output_bytes, timeout_ms);
    }
    return runCommandWithTimeoutPosix(&child, alloc, max_output_bytes, timeout_ms);
}

fn runCommandWithTimeoutPosix(
    child: *std.process.Child,
    alloc: Allocator,
    max_output_bytes: usize,
    timeout_ms: u64,
) (Allocator.Error || std.process.Child.RunError || error{Timeout})!CommandResult {
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;

    var status: ?u32 = null;
    while (true) {
        const res = std.posix.waitpid(child.id, std.c.W.NOHANG);
        if (res.pid == child.id) {
            status = res.status;
            break;
        }

        if (std.time.nanoTimestamp() - start_ns >= timeout_ns) {
            _ = child.kill() catch {};
            return error.Timeout;
        }

        std.Thread.sleep(@as(u64, git_poll_ms) * std.time.ns_per_ms);
    }

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(alloc);
    errdefer stderr.deinit(alloc);
    errdefer closeChildStreams(child);

    try std.process.Child.collectOutput(child.*, alloc, &stdout, &stderr, max_output_bytes);
    closeChildStreams(child);

    return .{
        .term = statusToTerm(status.?),
        .stdout = try stdout.toOwnedSlice(alloc),
        .stderr = try stderr.toOwnedSlice(alloc),
    };
}

fn runCommandWithTimeoutWindows(
    child: *std.process.Child,
    alloc: Allocator,
    max_output_bytes: usize,
    timeout_ms: u64,
) (Allocator.Error || std.process.Child.RunError || std.process.Child.WaitError || std.os.windows.WaitForSingleObjectError || error{Timeout})!CommandResult {
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;

    while (true) {
        std.os.windows.WaitForSingleObjectEx(child.id, git_poll_ms, false) catch |err| switch (err) {
            error.WaitTimeOut => {},
            else => return err,
        };

        if (std.time.nanoTimestamp() - start_ns >= timeout_ns) {
            _ = child.kill() catch {};
            return error.Timeout;
        }

        if (std.os.windows.WaitForSingleObjectEx(child.id, 0, false)) {
            break;
        } else |err| switch (err) {
            error.WaitTimeOut => continue,
            else => return err,
        }
    }

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    errdefer stdout.deinit(alloc);
    errdefer stderr.deinit(alloc);

    try std.process.Child.collectOutput(child.*, alloc, &stdout, &stderr, max_output_bytes);
    const term = try child.wait();
    return .{
        .term = term,
        .stdout = try stdout.toOwnedSlice(alloc),
        .stderr = try stderr.toOwnedSlice(alloc),
    };
}

fn closeChildStreams(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
    if (child.stdout) |*stdout| {
        stdout.close();
        child.stdout = null;
    }
    if (child.stderr) |*stderr| {
        stderr.close();
        child.stderr = null;
    }
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

fn parseBlame(output: []const u8, alloc: Allocator) (GitError || Allocator.Error)!BlameEntry {
    var commit_hash: ?[]const u8 = null;
    var author: []const u8 = "";
    var author_email: []const u8 = "";
    var author_time: i64 = 0;

    var line_it = std.mem.splitScalar(u8, output, '\n');

    // First line: "<hash> <orig_line> <final_line> [<num_lines>]"
    if (line_it.next()) |first| {
        var tok = std.mem.splitScalar(u8, std.mem.trim(u8, first, " \r"), ' ');
        if (tok.next()) |h| {
            if (h.len >= 7) commit_hash = try alloc.dupe(u8, h);
        }
    }
    if (commit_hash == null) return error.BlameParseErr;

    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r ");
        if (std.mem.startsWith(u8, line, "author ")) {
            author = try alloc.dupe(u8, line["author ".len..]);
        } else if (std.mem.startsWith(u8, line, "author-mail ")) {
            var mail = line["author-mail ".len..];
            // Strip < > angle brackets
            if (mail.len >= 2 and mail[0] == '<' and mail[mail.len - 1] == '>') {
                mail = mail[1 .. mail.len - 1];
            }
            author_email = try alloc.dupe(u8, mail);
        } else if (std.mem.startsWith(u8, line, "author-time ")) {
            author_time = std.fmt.parseInt(i64, line["author-time ".len..], 10) catch 0;
        }
    }

    return BlameEntry{
        .commit_hash = commit_hash.?,
        .author = author,
        .author_email = author_email,
        .author_time = author_time,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseGitLog parses commits and changed files" {
    const output =
        "\x1eabc1234567890123456789012345678901234567890|abc1234|Alice Smith|alice@example.com|2026-03-01T12:00:00+00:00|REQ-001: implement GPS timeout\n" ++
        "M\tsrc/gps/timeout.c\n" ++
        "R100\tsrc/old.c\tsrc/new.c\n" ++
        "\n" ++
        "\x1edef1234567890123456789012345678901234567890|def1234|Bob Jones|bob@example.com|2026-03-02T09:00:00+00:00|refactor: clean up code\n" ++
        "A\ttests/test_main.py\n" ++
        "\n";
    const known = &[_][]const u8{ "REQ-001", "REQ-002" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const commits = try parseGitLog(output, known, alloc);
    try testing.expectEqual(@as(usize, 2), commits.len);

    try testing.expectEqualStrings("REQ-001: implement GPS timeout", commits[0].message);
    try testing.expectEqual(@as(usize, 1), commits[0].req_ids.len);
    try testing.expectEqualStrings("REQ-001", commits[0].req_ids[0]);
    try testing.expectEqual(@as(usize, 2), commits[0].file_changes.len);
    try testing.expectEqualStrings("M", commits[0].file_changes[0].status);
    try testing.expectEqualStrings("src/gps/timeout.c", commits[0].file_changes[0].path);
    try testing.expect(commits[0].file_changes[0].old_path == null);
    try testing.expectEqualStrings("R100", commits[0].file_changes[1].status);
    try testing.expectEqualStrings("src/new.c", commits[0].file_changes[1].path);
    try testing.expectEqualStrings("src/old.c", commits[0].file_changes[1].old_path.?);

    // Second commit has no matching req ID
    try testing.expectEqual(@as(usize, 0), commits[1].req_ids.len);
    try testing.expectEqual(@as(usize, 1), commits[1].file_changes.len);
    try testing.expectEqualStrings("tests/test_main.py", commits[1].file_changes[0].path);
}

test "parseGitLog empty output returns empty slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const commits = try parseGitLog("", &.{}, arena.allocator());
    try testing.expectEqual(@as(usize, 0), commits.len);
}

test "parseBlame parses porcelain output" {
    const output =
        \\abc1234567890123456789012345678901234567890 5 5 1
        \\author Alice Smith
        \\author-mail <alice@example.com>
        \\author-time 1741000000
        \\author-tz +0000
        \\committer Alice Smith
        \\committer-mail <alice@example.com>
        \\committer-time 1741000000
        \\committer-tz +0000
        \\summary REQ-001: add GPS timeout
        \\filename src/gps/timeout.c
        \\        // REQ-001: GPS loss detection
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entry = try parseBlame(output, alloc);
    try testing.expectEqualStrings("Alice Smith", entry.author);
    try testing.expectEqualStrings("alice@example.com", entry.author_email);
    try testing.expectEqual(@as(i64, 1741000000), entry.author_time);
}

test "parseBlame returns parse error for empty output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BlameParseErr, parseBlame("", arena.allocator()));
}

test "runCommandWithTimeout returns timeout for long-running command" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.Timeout,
        runCommandWithTimeout(&.{ "zsh", "-c", "sleep 11" }, ".", 1024, 100, arena.allocator()),
    );
}
