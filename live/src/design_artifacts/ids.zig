const std = @import("std");

const Allocator = std.mem.Allocator;

const types = @import("types.zig");

pub fn artifactIdFor(kind: types.ArtifactKind, logical_key: []const u8, alloc: Allocator) ![]u8 {
    return switch (kind) {
        .rtm_workbook => std.fmt.allocPrint(alloc, "artifact://rtm/{s}", .{logical_key}),
        else => std.fmt.allocPrint(alloc, "artifact://{s}/{s}", .{ kind.toString(), logical_key }),
    };
}

pub fn buildRequirementTextId(artifact_id: []const u8, req_id: []const u8, alloc: Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}:{s}", .{ artifact_id, req_id });
}

pub fn reqIdFromTextId(text_id: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, text_id, ':') orelse return text_id;
    return text_id[idx + 1 ..];
}

pub fn inferDisposition(ingest_source: []const u8) types.IngestDisposition {
    if (std.mem.eql(u8, ingest_source, "migration")) return .migration;
    if (std.mem.eql(u8, ingest_source, "external_inbox")) return .external_inbox;
    if (std.mem.eql(u8, ingest_source, "reingest")) return .reingested;
    if (std.mem.eql(u8, ingest_source, "workbook_sync") or std.mem.eql(u8, ingest_source, "sync_cycle")) return .sync_cycle;
    return .uploaded;
}
