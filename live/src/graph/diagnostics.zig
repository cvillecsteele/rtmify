const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const encode = @import("encode.zig");

pub fn upsertRuntimeDiagnostic(
    g: anytype,
    dedupe_key: []const u8,
    code: u16,
    severity: []const u8,
    title: []const u8,
    message: []const u8,
    source: []const u8,
    subject: ?[]const u8,
    details_json: []const u8,
) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare(
        \\INSERT OR REPLACE INTO runtime_diagnostics
        \\(dedupe_key, code, severity, title, message, source, subject, details_json, updated_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    );
    defer st.finalize();
    try st.bindText(1, dedupe_key);
    try st.bindInt(2, code);
    try st.bindText(3, severity);
    try st.bindText(4, title);
    try st.bindText(5, message);
    try st.bindText(6, source);
    if (subject) |s| try st.bindText(7, s) else try st.bindNull(7);
    try st.bindText(8, details_json);
    try st.bindInt(9, std.time.timestamp());
    _ = try st.step();
}

pub fn clearRuntimeDiagnosticsBySource(g: anytype, source: []const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare("DELETE FROM runtime_diagnostics WHERE source=?");
    defer st.finalize();
    try st.bindText(1, source);
    _ = try st.step();
}

pub fn clearRuntimeDiagnosticsBySubjectPrefix(g: anytype, source: []const u8, prefix: []const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare(
        "DELETE FROM runtime_diagnostics WHERE source=? AND subject IS NOT NULL AND subject LIKE ? || '%'"
    );
    defer st.finalize();
    try st.bindText(1, source);
    try st.bindText(2, prefix);
    _ = try st.step();
}

pub fn clearRuntimeDiagnostic(g: anytype, dedupe_key: []const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare("DELETE FROM runtime_diagnostics WHERE dedupe_key=?");
    defer st.finalize();
    try st.bindText(1, dedupe_key);
    _ = try st.step();
}

pub fn listRuntimeDiagnostics(
    g: anytype,
    source_filter: ?[]const u8,
    alloc: Allocator,
    result: *std.ArrayList(types.RuntimeDiagnostic),
) !void {
    if (source_filter) |source| {
        var st = try g.db.prepare(
            \\SELECT dedupe_key, code, severity, title, message, source, subject, details_json, updated_at
            \\FROM runtime_diagnostics WHERE source=? ORDER BY severity DESC, code, dedupe_key
        );
        defer st.finalize();
        try st.bindText(1, source);
        while (try st.step()) {
            try result.append(alloc, try encode.stmtToRuntimeDiagnostic(&st, alloc));
        }
    } else {
        var st = try g.db.prepare(
            \\SELECT dedupe_key, code, severity, title, message, source, subject, details_json, updated_at
            \\FROM runtime_diagnostics ORDER BY severity DESC, code, dedupe_key
        );
        defer st.finalize();
        while (try st.step()) {
            try result.append(alloc, try encode.stmtToRuntimeDiagnostic(&st, alloc));
        }
    }
}
