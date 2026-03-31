const std = @import("std");
const Allocator = std.mem.Allocator;

const design_artifacts = @import("../design_artifacts.zig");

pub fn archiveFile(inbox_dir: []const u8, subdir: []const u8, name: []const u8, alloc: Allocator) ![]const u8 {
    const target_dir_path = try std.fs.path.join(alloc, &.{ inbox_dir, subdir });
    defer alloc.free(target_dir_path);
    try ensureDirPath(target_dir_path);

    const archived = try std.fmt.allocPrint(alloc, "{d}-{s}", .{ std.time.timestamp(), name });
    defer alloc.free(archived);
    const source_path = try std.fs.path.join(alloc, &.{ inbox_dir, name });
    defer alloc.free(source_path);
    const target_path = try std.fs.path.join(alloc, &.{ target_dir_path, archived });
    defer alloc.free(target_path);
    if (std.fs.path.isAbsolute(source_path) and std.fs.path.isAbsolute(target_path)) {
        std.fs.renameAbsolute(source_path, target_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        std.fs.cwd().rename(source_path, target_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    return alloc.dupe(u8, target_path);
}

pub fn archiveDesignArtifactFile(
    inbox_dir: []const u8,
    kind: design_artifacts.ArtifactKind,
    logical_key: []const u8,
    name: []const u8,
    alloc: Allocator,
) ![]const u8 {
    const target_dir_path = try std.fs.path.join(alloc, &.{ inbox_dir, "processed", "design-artifacts", kind.toString() });
    defer alloc.free(target_dir_path);
    try ensureDirPath(target_dir_path);
    const extension = switch (kind) {
        .rtm_workbook => ".xlsx",
        .urs_docx, .srs_docx, .swrs_docx, .hrs_docx, .sysrd_docx => ".docx",
    };
    const target_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ logical_key, extension });
    defer alloc.free(target_name);
    const source_path = try std.fs.path.join(alloc, &.{ inbox_dir, name });
    defer alloc.free(source_path);
    const target_path = try std.fs.path.join(alloc, &.{ target_dir_path, target_name });
    if (std.fs.path.isAbsolute(source_path) and std.fs.path.isAbsolute(target_path)) {
        std.fs.renameAbsolute(source_path, target_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        std.fs.cwd().rename(source_path, target_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    return target_path;
}

pub fn ensureInboxLayout(inbox_dir: []const u8) !void {
    try ensureDirPath(inbox_dir);
    const processed_dir = try std.fs.path.join(std.heap.page_allocator, &.{ inbox_dir, "processed" });
    defer std.heap.page_allocator.free(processed_dir);
    try ensureDirPath(processed_dir);
    const rejected_dir = try std.fs.path.join(std.heap.page_allocator, &.{ inbox_dir, "rejected" });
    defer std.heap.page_allocator.free(rejected_dir);
    try ensureDirPath(rejected_dir);
}

pub fn ensureDirPath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return;
    }
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

const testing = std.testing;

test "ensureInboxLayout creates processed and rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);

    try ensureInboxLayout(inbox_dir);
    try std.fs.cwd().access(inbox_dir, .{});
    const processed_dir = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "processed" });
    defer testing.allocator.free(processed_dir);
    const rejected_dir = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "rejected" });
    defer testing.allocator.free(rejected_dir);
    try std.fs.cwd().access(processed_dir, .{});
    try std.fs.cwd().access(rejected_dir, .{});
}

test "archiveFile tolerates missing source path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try ensureInboxLayout(inbox_dir);

    const archived = try archiveFile(inbox_dir, "processed", "missing.json", testing.allocator);
    defer testing.allocator.free(archived);
    try testing.expect(std.mem.indexOf(u8, archived, "/processed/") != null);
}
