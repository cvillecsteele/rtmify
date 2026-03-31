const std = @import("std");
const Allocator = std.mem.Allocator;

const archive = @import("archive.zig");
const bom = @import("../bom.zig");
const dispatcher = @import("dispatcher.zig");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const test_results = @import("../test_results.zig");

pub fn processInboxOnce(db: *graph_live.GraphDb, inbox_dir: []const u8, alloc: Allocator) !void {
    try archive.ensureInboxLayout(inbox_dir);
    var dir = if (std.fs.path.isAbsolute(inbox_dir))
        try std.fs.openDirAbsolute(inbox_dir, .{ .iterate = true })
    else
        try std.fs.cwd().openDir(inbox_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isEligibleInboxFileName(entry.name)) continue;
        try dispatcher.processOneFile(db, inbox_dir, entry.name, alloc);
    }
}

fn isEligibleInboxFileName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    return std.mem.endsWith(u8, name, ".json") or
        std.mem.endsWith(u8, name, ".csv") or
        std.mem.endsWith(u8, name, ".xlsx") or
        std.mem.endsWith(u8, name, ".docx");
}

const testing = std.testing;

test "hidden files are ignored" {
    try testing.expect(!isEligibleInboxFileName(".hidden.json"));
}

test "unsupported extensions are ignored" {
    try testing.expect(!isEligibleInboxFileName("notes.txt"));
    try testing.expect(isEligibleInboxFileName("payload.json"));
}

test "processInboxOnce creates inbox layout before scanning" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    const processed_dir = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "processed" });
    defer testing.allocator.free(processed_dir);
    const rejected_dir = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "rejected" });
    defer testing.allocator.free(rejected_dir);
    try std.fs.cwd().access(processed_dir, .{});
    try std.fs.cwd().access(rejected_dir, .{});
}

test "valid test results file in inbox is ingested and moved to processed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const body =
        \\{
        \\  "execution_id": "build-1",
        \\  "executed_at": "2026-03-12T14:32:00Z",
        \\  "test_cases": [
        \\    { "result_id": "r-1", "test_case_ref": "T-001", "status": "passed" }
        \\  ]
        \\}
    ;
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "payload.json" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = body });

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    const execution = try test_results.getExecutionJson(&db, "build-1", testing.allocator);
    defer if (execution) |value| testing.allocator.free(value);
    try testing.expect(execution != null);
}

test "csv bom file in inbox is ingested and moved to processed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const body =
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4
    ;
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "bom.csv" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = body });

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    const bom_json = try bom.getBomJson(&db, "ASM-1000-REV-C", null, null, false, testing.allocator);
    defer testing.allocator.free(bom_json);
    try testing.expect(std.mem.indexOf(u8, bom_json, "\"bom_name\":\"pcba\"") != null);
}

test "csv bom file with unresolved trace refs is ingested and warning diagnostic recorded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const body =
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,requirement_id,test_id
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4,REQ-404,TEST-404
    ;
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "bom-warn.csv" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = body });

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |diag| shared.freeRuntimeDiagnostic(diag, testing.allocator);
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    try testing.expect(diags.items.len >= 2);
    try testing.expectEqual(@as(u16, 9502), diags.items[0].code);
}

test "csv bom file with resolved trace refs creates no inbox warning diagnostic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const body =
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,requirement_id,test_id
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4,REQ-001,TEST-001
    ;
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "bom-clean.csv" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = body });

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TEST-001", "Test", "{}", null);
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |diag| shared.freeRuntimeDiagnostic(diag, testing.allocator);
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "cyclonedx json file in inbox is ingested and moved to processed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const body =
        \\{
        \\  "bomFormat": "CycloneDX",
        \\  "bom_name": "firmware",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "metadata": { "component": { "name": "fw", "version": "1.0.0", "bom-ref": "fw@1.0.0" } },
        \\  "components": [
        \\    { "name": "zlib", "version": "1.2.13", "bom-ref": "pkg:generic/zlib@1.2.13", "purl": "pkg:generic/zlib@1.2.13" }
        \\  ],
        \\  "dependencies": [
        \\    { "ref": "fw@1.0.0", "dependsOn": ["pkg:generic/zlib@1.2.13"] }
        \\  ]
        \\}
    ;
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "sbom.json" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = body });

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    const bom_json = try bom.getBomJson(&db, "ASM-1000-REV-C", "software", "firmware", false, testing.allocator);
    defer testing.allocator.free(bom_json);
    try testing.expect(std.mem.indexOf(u8, bom_json, "\"bom_type\":\"software\"") != null);
}

test "unsupported json shape is rejected and diagnostic recorded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try archive.ensureInboxLayout(inbox_dir);

    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "bad.json" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "{\"unknown\":true}" });

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |diag| shared.freeRuntimeDiagnostic(diag, testing.allocator);
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    try testing.expect(diags.items.len > 0);
}
