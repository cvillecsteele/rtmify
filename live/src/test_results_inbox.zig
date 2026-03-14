const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("graph_live.zig");
const sync_live = @import("sync_live.zig");
const test_results = @import("test_results.zig");

pub const InboxCtx = struct {
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    inbox_dir: []const u8,
    alloc: Allocator,
};

pub fn destroyInboxCtx(ctx: *InboxCtx) void {
    ctx.alloc.free(ctx.inbox_dir);
    ctx.alloc.destroy(ctx);
}

pub fn inboxThread(ctx: *InboxCtx) void {
    defer destroyInboxCtx(ctx);

    while (true) {
        if (!ctx.state.product_enabled.load(.seq_cst)) {
            std.Thread.sleep(5 * std.time.ns_per_s);
            continue;
        }

        processInboxOnce(ctx.db, ctx.inbox_dir, ctx.alloc) catch |err| {
            std.log.warn("test results inbox poll failed: {s}", .{@errorName(err)});
        };
        std.Thread.sleep(5 * std.time.ns_per_s);
    }
}

pub fn processInboxOnce(db: *graph_live.GraphDb, inbox_dir: []const u8, alloc: Allocator) !void {
    try ensureInboxLayout(inbox_dir);
    var dir = if (std.fs.path.isAbsolute(inbox_dir))
        try std.fs.openDirAbsolute(inbox_dir, .{ .iterate = true })
    else
        try std.fs.cwd().openDir(inbox_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try processOneFile(db, inbox_dir, entry.name, alloc);
    }
}

fn processOneFile(db: *graph_live.GraphDb, inbox_dir: []const u8, name: []const u8, alloc: Allocator) !void {
    const path = try std.fs.path.join(alloc, &.{ inbox_dir, name });
    defer alloc.free(path);
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
        try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
        return;
    };
    defer alloc.free(bytes);

    var payload = test_results.parsePayload(bytes, alloc) catch |err| {
        try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
        return;
    };
    defer payload.deinit(alloc);

    var response = test_results.ingest(db, payload, alloc) catch |err| {
        try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
        return;
    };
    defer response.deinit(alloc);

    try archiveFile(inbox_dir, "processed", name, alloc);
}

fn rejectFile(db: *graph_live.GraphDb, inbox_dir: []const u8, name: []const u8, alloc: Allocator, reason: []const u8) !void {
    try archiveFile(inbox_dir, "rejected", name, alloc);
    const subject = try std.fs.path.join(alloc, &.{ inbox_dir, "rejected", name });
    defer alloc.free(subject);
    const message = try std.fmt.allocPrint(alloc, "Rejected inbox file {s}: {s}", .{ name, reason });
    defer alloc.free(message);
    const dedupe_key = try std.fmt.allocPrint(alloc, "test_results_inbox:{s}", .{name});
    defer alloc.free(dedupe_key);
    try db.upsertRuntimeDiagnostic(
        dedupe_key,
        9501,
        "warn",
        "Test results inbox file rejected",
        message,
        "test_results_inbox",
        subject,
        "{}",
    );
}

fn archiveFile(inbox_dir: []const u8, subdir: []const u8, name: []const u8, alloc: Allocator) !void {
    const target_dir_path = try std.fs.path.join(alloc, &.{ inbox_dir, subdir });
    defer alloc.free(target_dir_path);
    try ensureDirPath(target_dir_path);

    const archived = try std.fmt.allocPrint(alloc, "{d}-{s}", .{ std.time.timestamp(), name });
    defer alloc.free(archived);
    const source_path = try std.fs.path.join(alloc, &.{ inbox_dir, name });
    defer alloc.free(source_path);
    const target_path = try std.fs.path.join(alloc, &.{ target_dir_path, archived });
    defer alloc.free(target_path);
    if (std.fs.path.isAbsolute(source_path) and std.fs.path.isAbsolute(target_path)) {
        std.fs.renameAbsolute(source_path, target_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        std.fs.cwd().rename(source_path, target_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn ensureInboxLayout(inbox_dir: []const u8) !void {
    try ensureDirPath(inbox_dir);
    const processed_dir = try std.fs.path.join(std.heap.page_allocator, &.{ inbox_dir, "processed" });
    defer std.heap.page_allocator.free(processed_dir);
    try ensureDirPath(processed_dir);
    const rejected_dir = try std.fs.path.join(std.heap.page_allocator, &.{ inbox_dir, "rejected" });
    defer std.heap.page_allocator.free(rejected_dir);
    try ensureDirPath(rejected_dir);
}

fn ensureDirPath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return;
    }
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

const testing = std.testing;

test "valid file in inbox is ingested and moved to processed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try ensureInboxLayout(inbox_dir);

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

test "invalid file is moved to rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try ensureInboxLayout(inbox_dir);

    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "bad.json" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "{not json" });

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try processInboxOnce(&db, inbox_dir, testing.allocator);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |diag| {
            testing.allocator.free(diag.dedupe_key);
            testing.allocator.free(diag.severity);
            testing.allocator.free(diag.title);
            testing.allocator.free(diag.message);
            testing.allocator.free(diag.source);
            if (diag.subject) |value| testing.allocator.free(value);
            testing.allocator.free(diag.details_json);
        }
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("test_results_inbox", testing.allocator, &diags);
    try testing.expect(diags.items.len > 0);
}
