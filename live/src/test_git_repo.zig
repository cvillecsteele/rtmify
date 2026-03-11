const std = @import("std");

const Allocator = std.mem.Allocator;

pub const RepoFixture = struct {
    path: []const u8,
    alloc: Allocator,

    pub fn init(tmp: *std.testing.TmpDir, alloc: Allocator) !RepoFixture {
        try tmp.dir.makePath("repo");
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const repo_path = try tmp.dir.realpath("repo", &buf);
        return .{
            .path = try alloc.dupe(u8, repo_path),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *RepoFixture) void {
        self.alloc.free(self.path);
    }

    pub fn writeFile(self: *RepoFixture, rel_path: []const u8, contents: []const u8) !void {
        const abs_path = try std.fs.path.join(self.alloc, &.{ self.path, rel_path });
        defer self.alloc.free(abs_path);
        if (std.fs.path.dirname(abs_path)) |dir_name| {
            try std.fs.cwd().makePath(dir_name);
        }
        const file = try std.fs.cwd().createFile(abs_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(contents);
    }

    pub fn deleteFile(self: *RepoFixture, rel_path: []const u8) !void {
        const abs_path = try std.fs.path.join(self.alloc, &.{ self.path, rel_path });
        defer self.alloc.free(abs_path);
        try std.fs.cwd().deleteFile(abs_path);
    }

    pub fn renameFile(self: *RepoFixture, old_rel: []const u8, new_rel: []const u8) !void {
        const new_abs = try std.fs.path.join(self.alloc, &.{ self.path, new_rel });
        defer self.alloc.free(new_abs);
        if (std.fs.path.dirname(new_abs)) |dir_name| {
            try std.fs.cwd().makePath(dir_name);
        }
        _ = try self.runGit(&.{ "mv", old_rel, new_rel }, null);
    }

    pub fn gitInit(self: *RepoFixture) !void {
        _ = try self.runGit(&.{ "init", "-q" }, null);
    }

    pub fn commit(
        self: *RepoFixture,
        message: []const u8,
        author_name: []const u8,
        author_email: []const u8,
        author_date_iso: []const u8,
    ) ![]u8 {
        _ = try self.runGit(&.{ "add", "-A" }, null);
        _ = try self.runGit(&.{ "commit", "-q", "--allow-empty", "-m", message }, .{
            .author_name = author_name,
            .author_email = author_email,
            .author_date_iso = author_date_iso,
        });
        return self.head();
    }

    pub fn head(self: *RepoFixture) ![]u8 {
        const out = try self.runGit(&.{ "rev-parse", "HEAD" }, null);
        defer self.alloc.free(out);
        const trimmed = std.mem.trim(u8, out, "\r\n \t");
        return try self.alloc.dupe(u8, trimmed);
    }

    const CommitEnv = struct {
        author_name: []const u8,
        author_email: []const u8,
        author_date_iso: []const u8,
    };

    fn runGit(self: *RepoFixture, args: []const []const u8, commit_env: ?CommitEnv) ![]u8 {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.alloc);
        try argv.append(self.alloc, "git");
        try argv.appendSlice(self.alloc, args);

        var env_map = try std.process.getEnvMap(self.alloc);
        defer env_map.deinit();

        if (commit_env) |env| {
            try env_map.put("GIT_AUTHOR_NAME", env.author_name);
            try env_map.put("GIT_AUTHOR_EMAIL", env.author_email);
            try env_map.put("GIT_AUTHOR_DATE", env.author_date_iso);
            try env_map.put("GIT_COMMITTER_NAME", env.author_name);
            try env_map.put("GIT_COMMITTER_EMAIL", env.author_email);
            try env_map.put("GIT_COMMITTER_DATE", env.author_date_iso);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.alloc,
            .argv = argv.items,
            .cwd = self.path,
            .env_map = &env_map,
        });
        errdefer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) return result.stdout;
            },
            else => {},
        }

        std.log.err("git command failed in {s}: {s}\nstdout:\n{s}\nstderr:\n{s}", .{
            self.path,
            args[0],
            result.stdout,
            result.stderr,
        });
        return error.GitFixtureCommandFailed;
    }
};

test "RepoFixture can init write and commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try RepoFixture.init(&tmp, std.testing.allocator);
    defer fixture.deinit();

    try fixture.gitInit();
    try fixture.writeFile("src/foo.c", "int main(void) { return 0; }\n");
    const head = try fixture.commit("initial", "Alice", "alice@example.com", "2026-03-10T12:00:00Z");
    defer std.testing.allocator.free(head);
    try std.testing.expect(head.len > 0);
}
