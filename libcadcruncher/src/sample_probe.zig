const std = @import("std");
const cad = @import("lib.zig");

pub fn detectSample(path: []const u8, allocator: std.mem.Allocator) !cad.detect.Detection {
    return cad.detect.detectFile(path, allocator);
}

pub fn fixturePath(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    const fixtures_root = try std.fs.path.join(allocator, &.{ "libcadcruncher", "test", "fixtures" });
    defer allocator.free(fixtures_root);

    const segments = try allocator.alloc([]const u8, parts.len + 1);
    defer allocator.free(segments);
    segments[0] = fixtures_root;
    for (parts, 0..) |part, i| segments[i + 1] = part;

    return std.fs.path.join(allocator, segments);
}

pub fn hasExtraSampleRoot() bool {
    return std.process.getEnvVarOwned(std.heap.page_allocator, "RTMIFY_CAD_SAMPLES") catch return false;
}
