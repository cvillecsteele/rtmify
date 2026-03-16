const std = @import("std");
const internal = @import("internal.zig");

pub fn upsertRuntimeDiag(db: *internal.GraphDb, source: []const u8, code: u16, severity: []const u8, title: []const u8, message: []const u8, subject: ?[]const u8, details_json: []const u8) !void {
    const subject_part = subject orelse "";
    const dedupe_key = try std.fmt.allocPrint(std.heap.page_allocator, "{s}:{s}:{d}", .{ source, subject_part, code });
    defer std.heap.page_allocator.free(dedupe_key);
    try db.upsertRuntimeDiagnostic(dedupe_key, code, severity, title, message, source, subject, details_json);
}

pub fn clearRuntimeDiagByCodeAndSubject(db: *internal.GraphDb, source: []const u8, subject: []const u8, code: u16) !void {
    const dedupe_key = try std.fmt.allocPrint(std.heap.page_allocator, "{s}:{s}:{d}", .{ source, subject, code });
    defer std.heap.page_allocator.free(dedupe_key);
    try db.clearRuntimeDiagnostic(dedupe_key);
}
