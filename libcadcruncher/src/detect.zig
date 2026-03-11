const std = @import("std");
const sample_probe = @import("sample_probe.zig");

pub const ArtifactKind = enum {
    unknown,
    cfb,
    altium_pcbdoc,
    altium_schdoc,
};

pub const Detection = struct {
    kind: ArtifactKind,
    path: []const u8,
    is_cfb: bool,
};

const cfb_magic = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

pub fn isCfbMagic(header: []const u8) bool {
    return header.len >= cfb_magic.len and std.mem.eql(u8, header[0..cfb_magic.len], &cfb_magic);
}

pub fn detectFile(path: []const u8, allocator: std.mem.Allocator) !Detection {
    _ = allocator;
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [8]u8 = undefined;
    const got = try file.readAll(&header);
    const is_cfb = isCfbMagic(header[0..got]);

    const ext = std.fs.path.extension(path);
    const kind: ArtifactKind = if (is_cfb and std.ascii.eqlIgnoreCase(ext, ".PcbDoc"))
        .altium_pcbdoc
    else if (is_cfb and std.ascii.eqlIgnoreCase(ext, ".SchDoc"))
        .altium_schdoc
    else if (is_cfb)
        .cfb
    else
        .unknown;

    return .{
        .kind = kind,
        .path = path,
        .is_cfb = is_cfb,
    };
}

test "isCfbMagic recognizes compound file magic" {
    try std.testing.expect(isCfbMagic(&cfb_magic));
    try std.testing.expect(!isCfbMagic("not-a-cfb"));
}

test "repo fixture .PcbDoc detects as altium" {
    const sample = try sample_probe.fixturePath(std.testing.allocator, &.{ "altium", "SpiralTest.PcbDoc" });
    defer std.testing.allocator.free(sample);

    const det = try detectFile(sample, std.testing.allocator);
    try std.testing.expectEqual(ArtifactKind.altium_pcbdoc, det.kind);
    try std.testing.expect(det.is_cfb);
}

test "repo fixture .SchDoc detects as altium_schdoc" {
    const sample = try sample_probe.fixturePath(std.testing.allocator, &.{ "altium", "sch.SchDoc" });
    defer std.testing.allocator.free(sample);

    const det = try detectFile(sample, std.testing.allocator);
    try std.testing.expectEqual(ArtifactKind.altium_schdoc, det.kind);
    try std.testing.expect(det.is_cfb);
}
