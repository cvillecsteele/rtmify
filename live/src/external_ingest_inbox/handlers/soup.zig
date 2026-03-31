const std = @import("std");

const archive = @import("../archive.zig");
const artifact_test_files = @import("../../artifact_test_files.zig");
const ctx_mod = @import("../context.zig");
const diagnostics = @import("../diagnostics.zig");
const soup = @import("../../soup.zig");

pub fn handle(ctx: ctx_mod.DispatchCtx, name: []const u8, path: []const u8) !void {
    const full_product_identifier = extractSoupInboxProductIdentifier(name) orelse {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, "SOUP_NO_PRODUCT_IDENTIFIER");
        return;
    };
    var response = soup.ingestXlsxInboxPath(ctx.db, path, full_product_identifier, ctx.alloc) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer response.deinit(ctx.alloc);

    const archived_path = try archive.archiveFile(ctx.inbox_dir, "processed", name, ctx.alloc);
    defer ctx.alloc.free(archived_path);
    try diagnostics.recordSoupWarnings(ctx.db, archived_path, response, ctx.alloc);
}

pub fn extractSoupInboxProductIdentifier(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "SOUP__")) return null;
    if (!std.mem.endsWith(u8, name, ".xlsx")) return null;
    return name["SOUP__".len .. name.len - ".xlsx".len];
}

const testing = std.testing;

test "extractSoupInboxProductIdentifier matches current SOUP naming" {
    try testing.expectEqualStrings("ASM-1000-REV-C", extractSoupInboxProductIdentifier("SOUP__ASM-1000-REV-C.xlsx").?);
    try testing.expect(extractSoupInboxProductIdentifier("SOUP__ASM-1000-REV-C.csv") == null);
    try testing.expect(extractSoupInboxProductIdentifier("firmware.xlsx") == null);
}

test "handle rejects file missing SOUP identifier and records reject diagnostic" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "firmware.xlsx" });
    defer testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "not used" });

    try handle(.{ .db = &db, .inbox_dir = inbox_dir, .alloc = testing.allocator }, "firmware.xlsx", path);

    var diags: std.ArrayList(@import("../../graph_live.zig").RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.dedupe_key);
            testing.allocator.free(d.severity);
            testing.allocator.free(d.title);
            testing.allocator.free(d.message);
            testing.allocator.free(d.source);
            if (d.subject) |s| testing.allocator.free(s);
            testing.allocator.free(d.details_json);
        }
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expect(std.mem.indexOf(u8, diags.items[0].message, "SOUP_NO_PRODUCT_IDENTIFIER") != null);
}

test "handle ingests valid SOUP xlsx archives to processed and removes source from inbox root" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const name = "SOUP__ASM-1000-REV-C.xlsx";
    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, name });
    defer testing.allocator.free(path);
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "SOUP Components", .rows = &.{
            &.{ "component_name", "version" },
            &.{ "openssl", "3.2.1" },
        } },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, testing.allocator);

    try handle(.{ .db = &db, .inbox_dir = inbox_dir, .alloc = testing.allocator }, name, path);

    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
    var diags: std.ArrayList(@import("../../graph_live.zig").RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.dedupe_key);
            testing.allocator.free(d.severity);
            testing.allocator.free(d.title);
            testing.allocator.free(d.message);
            testing.allocator.free(d.source);
            if (d.subject) |s| testing.allocator.free(s);
            testing.allocator.free(d.details_json);
        }
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    for (diags.items) |diag| {
        try testing.expect(!std.mem.eql(u8, diag.title, "External ingest inbox file rejected"));
    }
}

test "handle records SOUP warning diagnostics when ingest returns unresolved refs" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const name = "SOUP__ASM-1000-REV-C.xlsx";
    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, name });
    defer testing.allocator.free(path);
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "SOUP Components", .rows = &.{
            &.{ "component_name", "version", "requirement_ids" },
            &.{ "openssl", "3.2.1", "REQ-404" },
        } },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, testing.allocator);

    try handle(.{ .db = &db, .inbox_dir = inbox_dir, .alloc = testing.allocator }, name, path);

    var diags: std.ArrayList(@import("../../graph_live.zig").RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |d| {
            testing.allocator.free(d.dedupe_key);
            testing.allocator.free(d.severity);
            testing.allocator.free(d.title);
            testing.allocator.free(d.message);
            testing.allocator.free(d.source);
            if (d.subject) |s| testing.allocator.free(s);
            testing.allocator.free(d.details_json);
        }
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    try testing.expect(diags.items.len > 0);
    var found = false;
    for (diags.items) |diag| {
        if (std.mem.eql(u8, diag.title, "External SOUP ingested with warnings")) found = true;
    }
    try testing.expect(found);
}
