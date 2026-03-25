const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("graph_live.zig");

pub const SourceOfTruth = enum {
    document_first,
    workbook_first,

    pub fn asString(self: SourceOfTruth) []const u8 {
        return switch (self) {
            .document_first => "document_first",
            .workbook_first => "workbook_first",
        };
    }
};

pub const workspace_ready_key = "workspace_ready";
pub const workspace_source_of_truth_key = "workspace_source_of_truth";
pub const attach_workbook_prompt_dismissed_key = "ui_attach_workbook_prompt_dismissed";

pub fn readWorkspaceReady(db: *graph_live.GraphDb, connection_configured: bool, alloc: Allocator) !bool {
    const raw = (try db.getConfig(workspace_ready_key, alloc)) orelse return connection_configured;
    defer alloc.free(raw);
    return parseBool(raw) orelse connection_configured;
}

pub fn writeWorkspaceReady(db: *graph_live.GraphDb, ready: bool) !void {
    try db.storeConfig(workspace_ready_key, if (ready) "1" else "0");
}

pub fn readSourceOfTruth(db: *graph_live.GraphDb, alloc: Allocator) !?SourceOfTruth {
    const raw = (try db.getConfig(workspace_source_of_truth_key, alloc)) orelse return null;
    defer alloc.free(raw);
    return parseSourceOfTruth(raw);
}

pub fn writeSourceOfTruth(db: *graph_live.GraphDb, value: SourceOfTruth) !void {
    try db.storeConfig(workspace_source_of_truth_key, value.asString());
}

pub fn readAttachWorkbookPromptDismissed(db: *graph_live.GraphDb, alloc: Allocator) !bool {
    const raw = (try db.getConfig(attach_workbook_prompt_dismissed_key, alloc)) orelse return false;
    defer alloc.free(raw);
    return parseBool(raw) orelse false;
}

pub fn writeAttachWorkbookPromptDismissed(db: *graph_live.GraphDb, dismissed: bool) !void {
    try db.storeConfig(attach_workbook_prompt_dismissed_key, if (dismissed) "1" else "0");
}

pub fn clearAttachWorkbookPromptDismissed(db: *graph_live.GraphDb) !void {
    try db.deleteConfig(attach_workbook_prompt_dismissed_key);
}

fn parseSourceOfTruth(raw: []const u8) ?SourceOfTruth {
    if (std.mem.eql(u8, raw, "document_first")) return .document_first;
    if (std.mem.eql(u8, raw, "workbook_first")) return .workbook_first;
    return null;
}

fn parseBool(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "1") or std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.mem.eql(u8, raw, "0") or std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return null;
}

const testing = std.testing;

test "workspace ready falls back to connection state when unset" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try testing.expect(try readWorkspaceReady(&db, true, testing.allocator));
    try testing.expect(!(try readWorkspaceReady(&db, false, testing.allocator)));
}

test "source of truth round-trips" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try writeSourceOfTruth(&db, .document_first);
    try testing.expectEqual(SourceOfTruth.document_first, (try readSourceOfTruth(&db, testing.allocator)).?);
}
