const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn homeDir(alloc: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, "HOME")) |home| return home else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return std.process.getEnvVarOwned(alloc, "USERPROFILE");
}

pub fn liveRoot(alloc: Allocator) ![]u8 {
    const home = try homeDir(alloc);
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, ".rtmify" });
}

pub fn configPath(alloc: Allocator) ![]u8 {
    const root = try liveRoot(alloc);
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "live.json" });
}

pub fn workbookDir(slug: []const u8, alloc: Allocator) ![]u8 {
    const root = try liveRoot(alloc);
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "workbooks", slug });
}

pub fn inboxesRoot(alloc: Allocator) ![]u8 {
    const root = try liveRoot(alloc);
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "inboxes" });
}

pub fn graphDbPath(slug: []const u8, alloc: Allocator) ![]u8 {
    const dir = try workbookDir(slug, alloc);
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "graph.db" });
}

pub fn apiTokenPath(slug: []const u8, alloc: Allocator) ![]u8 {
    const dir = try workbookDir(slug, alloc);
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, "api-token" });
}

pub fn inboxDir(slug: []const u8, alloc: Allocator) ![]u8 {
    const dir = try inboxesRoot(alloc);
    defer alloc.free(dir);
    return std.fs.path.join(alloc, &.{ dir, slug });
}

pub fn slugify(display_name: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    var prev_dash = false;
    for (display_name) |c| {
        const lowered = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lowered)) {
            try buf.append(alloc, lowered);
            prev_dash = false;
        } else if (!prev_dash and buf.items.len > 0) {
            try buf.append(alloc, '-');
            prev_dash = true;
        }
    }

    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') {
        _ = buf.pop();
    }

    if (buf.items.len == 0) {
        try buf.appendSlice(alloc, "workbook");
    }

    return buf.toOwnedSlice(alloc);
}

/// Creates all directory components of `path`, handling absolute paths correctly
/// on Windows. std.fs.cwd().makePath with an absolute path uses NtCreateFile
/// with RootDirectory set, which treats the path as relative and fails on the
/// drive-letter component. This function uses makeDirAbsolute for absolute paths
/// so Win32 CreateDirectoryW resolves them correctly.
pub fn ensureDirPath(path: []const u8) void {
    if (!std.fs.path.isAbsolute(path)) {
        std.fs.cwd().makePath(path) catch {};
        return;
    }
    var it = std.fs.path.componentIterator(path) catch return;
    var comp = it.first();
    while (comp) |c| : (comp = it.next()) {
        std.fs.makeDirAbsolute(c.path) catch {};
    }
}

const testing = std.testing;

test "slugify normalizes punctuation and case" {
    const slug = try slugify("Motor Controller / Rev A", testing.allocator);
    defer testing.allocator.free(slug);
    try testing.expectEqualStrings("motor-controller-rev-a", slug);
}

test "ensureDirPath creates nested directories under an absolute path" {
    // Regression: on Windows, std.fs.cwd().makePath with an absolute path fails
    // silently because NtCreateFile(RootDirectory=cwd) treats C:\... as relative.
    // ensureDirPath uses makeDirAbsolute to bypass this.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = testing.allocator;
    const tmp_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_root);
    const nested = try std.fs.path.join(alloc, &.{ tmp_root, "a", "b", "c" });
    defer alloc.free(nested);
    ensureDirPath(nested);
    var dir = try std.fs.openDirAbsolute(nested, .{});
    dir.close();
}
