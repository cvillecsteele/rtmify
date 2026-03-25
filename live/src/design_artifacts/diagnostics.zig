const std = @import("std");

const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");

pub fn upsertArtifactDiagnostic(
    db: *graph_live.GraphDb,
    subject_prefix: []const u8,
    subject_suffix: []const u8,
    code: u16,
    code_name: []const u8,
    severity: []const u8,
    title: []const u8,
    alloc: Allocator,
) !void {
    const subject = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ subject_prefix, subject_suffix });
    defer alloc.free(subject);
    const dedupe_key = try std.fmt.allocPrint(alloc, "design-artifacts:{s}:{s}", .{ code_name, subject });
    defer alloc.free(dedupe_key);
    var details: std.ArrayList(u8) = .empty;
    defer details.deinit(alloc);
    try details.appendSlice(alloc, "{\"code\":");
    try shared.appendJsonStr(&details, code_name, alloc);
    try details.appendSlice(alloc, "}");
    try db.upsertRuntimeDiagnostic(dedupe_key, code, severity, title, title, "design_artifacts", subject, details.items);
}

pub fn clearRequirementDiagnostic(db: *graph_live.GraphDb, code_name: []const u8, req_id: []const u8, alloc: Allocator) !void {
    const subject = try std.fmt.allocPrint(alloc, "requirement:{s}", .{req_id});
    defer alloc.free(subject);
    const dedupe_key = try std.fmt.allocPrint(alloc, "design-artifacts:{s}:{s}", .{ code_name, subject });
    defer alloc.free(dedupe_key);
    try db.clearRuntimeDiagnostic(dedupe_key);
}
