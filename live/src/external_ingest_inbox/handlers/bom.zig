const std = @import("std");

const archive = @import("../archive.zig");
const artifact_test_files = @import("../../artifact_test_files.zig");
const bom = @import("../../bom.zig");
const bom_ids = @import("../../bom/ids.zig");
const ctx_mod = @import("../context.zig");
const diagnostics = @import("../diagnostics.zig");

pub fn handle(ctx: ctx_mod.DispatchCtx, name: []const u8, path: []const u8) !void {
    const bytes = std.fs.cwd().readFileAlloc(ctx.alloc, path, 25 * 1024 * 1024) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer ctx.alloc.free(bytes);

    if (std.mem.endsWith(u8, name, ".xlsx")) {
        var grouped = bom.ingestXlsxBody(ctx.db, bytes, ctx.alloc) catch |err| {
            try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
            return;
        };
        defer grouped.deinit(ctx.alloc);

        const archived_path = try archive.archiveFile(ctx.inbox_dir, "processed", name, ctx.alloc);
        defer ctx.alloc.free(archived_path);
        try diagnostics.recordGroupedBomWarnings(ctx.db, archived_path, grouped, ctx.alloc);
        return;
    }

    var response = bom.ingestInboxFile(ctx.db, name, bytes, ctx.alloc) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer response.deinit(ctx.alloc);

    const archived_path = try archive.archiveFile(ctx.inbox_dir, "processed", name, ctx.alloc);
    defer ctx.alloc.free(archived_path);
    try diagnostics.recordBomWarnings(ctx.db, archived_path, response, ctx.alloc);
}

const testing = std.testing;

test "xlsx handle ingests valid design bom workbook and archives to processed" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const name = "bom.xlsx";
    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, name });
    defer testing.allocator.free(path);
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "Design BOM", .rows = &.{
            &.{ "bom_name", "full_product_identifier", "parent_part", "parent_revision", "child_part", "child_revision", "quantity" },
            &.{ "pcba", "ASM-1000-REV-C", "ASM-1000", "REV-C", "R1", "A", "1" },
        } },
        .{ .name = "Product", .rows = &.{
            &.{ "assembly", "revision", "full_identifier", "description", "Product Status" },
            &.{ "ASM-1000", "REV-C", "ASM-1000-REV-C", "Desc", "Active" },
        } },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, testing.allocator);

    try handle(.{ .db = &db, .inbox_dir = inbox_dir, .alloc = testing.allocator }, name, path);

    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
    const bom_id = try bom_ids.bomNodeId("ASM-1000-REV-C", .hardware, "pcba", testing.allocator);
    defer testing.allocator.free(bom_id);
    const bom_node = (try db.getNode(bom_id, testing.allocator)).?;
    defer {
        testing.allocator.free(bom_node.id);
        testing.allocator.free(bom_node.type);
        testing.allocator.free(bom_node.properties);
        if (bom_node.suspect_reason) |r| testing.allocator.free(r);
    }
    try testing.expectEqualStrings("DesignBOM", bom_node.type);
}

test "xlsx handle records grouped BOM warnings when unresolved refs exist" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const name = "bom-warn.xlsx";
    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, name });
    defer testing.allocator.free(path);
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "Design BOM", .rows = &.{
            &.{ "bom_name", "full_product_identifier", "parent_part", "parent_revision", "child_part", "child_revision", "quantity", "requirement_ids" },
            &.{ "pcba", "ASM-1000-REV-C", "ASM-1000", "REV-C", "R1", "A", "1", "REQ-404" },
        } },
        .{ .name = "Product", .rows = &.{
            &.{ "assembly", "revision", "full_identifier", "description", "Product Status" },
            &.{ "ASM-1000", "REV-C", "ASM-1000-REV-C", "Desc", "Active" },
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
    try testing.expectEqualStrings("External BOM ingested with warnings", diags.items[0].title);
}

test "csv handle ingests valid bom file and archives to processed" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const name = "bom.csv";
    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, name });
    defer testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
            \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity
            \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,R1,A,1
        ,
    });

    try handle(.{ .db = &db, .inbox_dir = inbox_dir, .alloc = testing.allocator }, name, path);

    try testing.expectError(error.FileNotFound, std.fs.cwd().access(path, .{}));
    const bom_id = try bom_ids.bomNodeId("ASM-1000-REV-C", .hardware, "pcba", testing.allocator);
    defer testing.allocator.free(bom_id);
    const bom_node = (try db.getNode(bom_id, testing.allocator)).?;
    defer {
        testing.allocator.free(bom_node.id);
        testing.allocator.free(bom_node.type);
        testing.allocator.free(bom_node.properties);
        if (bom_node.suspect_reason) |r| testing.allocator.free(r);
    }
    try testing.expectEqualStrings("DesignBOM", bom_node.type);
}

test "csv handle records flat BOM warnings when unresolved refs exist" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const name = "bom-warn.csv";
    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, name });
    defer testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
            \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,requirement_ids
            \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,R1,A,1,REQ-404
        ,
    });

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
    try testing.expectEqualStrings("External BOM ingested with warnings", diags.items[0].title);
}

test "invalid xlsx reject path records 9501 diagnostic" {
    var db = try @import("../../graph_live.zig").GraphDb.init(":memory:");
    defer db.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const name = "bad.xlsx";
    const path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, name });
    defer testing.allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = "not an xlsx" });

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
    try testing.expectEqual(@as(u16, 9501), diags.items[0].code);
}
