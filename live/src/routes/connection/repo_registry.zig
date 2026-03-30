const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../../graph_live.zig");
const secure_store_mod = @import("../../secure_store.zig");
const workbook = @import("../../workbook/mod.zig");
const json_util = @import("../../json_util.zig");
const shared = @import("../shared.zig");

pub fn handleGetRepos(registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    const cfg = try registry.activeConfig();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"repos\":[");
    var first = true;
    for (cfg.repo_paths, 0..) |path, idx| {
        const ts_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{path});
        defer alloc.free(ts_key);
        const last_scan = (try db.getConfig(ts_key, alloc)) orelse try alloc.dupe(u8, "0");
        defer alloc.free(last_scan);
        const source_file_count = try shared.countNodesForRepo(db, "SourceFile", path);
        const test_file_count = try shared.countNodesForRepo(db, "TestFile", path);
        const annotation_count = try shared.countAnnotationsForRepo(db, path);
        const commit_count = try shared.countCommitsForRepo(db, path);
        if (!first) try buf.append(alloc, ',');
        first = false;
        try std.fmt.format(buf.writer(alloc), "{{\"slot\":{d},\"path\":", .{idx});
        try shared.appendJsonStr(&buf, path, alloc);
        try buf.appendSlice(alloc, ",\"last_scan\":");
        try shared.appendJsonStr(&buf, last_scan, alloc);
        try std.fmt.format(
            buf.writer(alloc),
            ",\"source_file_count\":{d},\"test_file_count\":{d},\"file_count\":{d},\"annotation_count\":{d},\"commit_count\":{d}",
            .{ source_file_count, test_file_count, source_file_count + test_file_count, annotation_count, commit_count },
        );
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn handlePostRepo(registry: *workbook.registry.WorkbookRegistry, db: *graph_live.GraphDb, body: []const u8, alloc: Allocator, persist_alloc: Allocator) ![]const u8 {
    const resp = try handlePostRepoResponse(registry, db, body, alloc, persist_alloc);
    return resp.body;
}

pub fn handlePostRepoResponse(
    registry: *workbook.registry.WorkbookRegistry,
    db: *graph_live.GraphDb,
    body: []const u8,
    alloc: Allocator,
    persist_alloc: Allocator,
) !shared.JsonRouteResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}"), false);
    defer parsed.deinit();

    const path = json_util.getString(parsed.value, "path") orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing path field\"}"), false);
    std.fs.accessAbsolute(path, .{}) catch {
        const msg = try std.fmt.allocPrint(alloc, "Repo path does not exist: {s}", .{path});
        defer alloc.free(msg);
        const diag = [_]shared.InlineDiagnostic{
            shared.makeInlineDiagnostic(901, "err", "Repo path does not exist", msg, "repo_validation", path, "{}"),
        };
        return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("repo path does not exist", &diag, alloc), false);
    };
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.NotDir => {
            const msg = try std.fmt.allocPrint(alloc, "Repo path is not a directory: {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(902, "err", "Repo path is not a directory", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("path is not a directory", &diag, alloc), false);
        },
        error.AccessDenied => {
            const msg = try std.fmt.allocPrint(alloc, "Repo path is not readable: {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(904, "err", "Repo path not readable", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("path is not readable", &diag, alloc), false);
        },
        else => {
            const msg = try std.fmt.allocPrint(alloc, "Repo path is not a directory or is not accessible: {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(902, "err", "Repo path is not a directory", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("path is not a directory or is not accessible", &diag, alloc), false);
        },
    };
    dir.close();
    {
        var cur: []const u8 = path;
        var found_git = false;
        while (true) {
            const git_check = std.fmt.allocPrint(alloc, "{s}/.git", .{cur}) catch break;
            defer alloc.free(git_check);
            if (std.fs.accessAbsolute(git_check, .{})) {
                found_git = true;
                break;
            } else |_| {}
            const parent = std.fs.path.dirname(cur) orelse break;
            if (std.mem.eql(u8, parent, cur)) break;
            cur = parent;
        }
        if (!found_git) {
            const msg = try std.fmt.allocPrint(alloc, "No .git directory found at {s}", .{path});
            defer alloc.free(msg);
            const diag = [_]shared.InlineDiagnostic{
                shared.makeInlineDiagnostic(903, "err", "No .git directory found", msg, "repo_validation", path, "{}"),
            };
            return shared.jsonRouteResponse(.bad_request, try shared.errorResponseWithDiagnostics("no .git directory found — is this a git repository?", &diag, alloc), false);
        }
    }
    _ = db;
    const cfg = try registry.activeConfig();
    if (cfg.repo_paths.len >= 64) {
        return shared.jsonRouteResponse(.conflict, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"too many repos\"}"), false);
    }
    try workbook.config.addActiveRepoPath(&registry.live_config, path, persist_alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(persist_alloc);
        runtime.config = try (try registry.activeConfig()).clone(persist_alloc);
    }
    try registry.syncActiveWorkbookIdFromRuntime(persist_alloc);
    try registry.save(persist_alloc);
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

pub fn handleDeleteRepo(registry: *workbook.registry.WorkbookRegistry, idx_str: []const u8, alloc: Allocator, persist_alloc: Allocator) ![]const u8 {
    const resp = try handleDeleteRepoResponse(registry, idx_str, alloc, persist_alloc);
    return resp.body;
}

pub fn handleDeleteRepoResponse(
    registry: *workbook.registry.WorkbookRegistry,
    idx_str: []const u8,
    alloc: Allocator,
    persist_alloc: Allocator,
) !shared.JsonRouteResponse {
    const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
        return shared.jsonRouteResponse(.not_found, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"repo not found\",\"slot\":{s}}}", .{idx_str}), false);
    };
    const removed = try workbook.config.deleteActiveRepoAt(&registry.live_config, idx, persist_alloc);
    if (!removed) {
        return shared.jsonRouteResponse(.not_found, try std.fmt.allocPrint(alloc, "{{\"ok\":false,\"error\":\"repo not found\",\"slot\":{s}}}", .{idx_str}), false);
    }
    {
        const runtime = try registry.active();
        runtime.config.deinit(persist_alloc);
        runtime.config = try (try registry.activeConfig()).clone(persist_alloc);
    }
    try registry.syncActiveWorkbookIdFromRuntime(persist_alloc);
    try registry.save(persist_alloc);
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

fn makeTestRegistry(alloc: Allocator, store: *secure_store_mod.Store) !workbook.registry.WorkbookRegistry {
    var cfg = try workbook.config.bootstrapConfig(alloc, .{});
    errdefer cfg.deinit(alloc);
    alloc.free(cfg.workbooks[0].db_path);
    cfg.workbooks[0].db_path = try alloc.dupe(u8, ":memory:");
    alloc.free(cfg.workbooks[0].inbox_dir);
    cfg.workbooks[0].inbox_dir = try alloc.dupe(u8, "/tmp/inbox");
    return workbook.registry.WorkbookRegistry.initForConfig(alloc, cfg, store);
}

const testing = std.testing;

test "handlePostRepo returns E902 for file path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const tmp_path = try std.fs.path.join(alloc, &.{ root, "rtmify-routes-file.txt" });
    defer alloc.free(tmp_path);
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("x");
    }
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{tmp_path});
    const resp = try handlePostRepo(&registry, &db, body, alloc, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":902") != null);
}

test "handlePostRepo accepts legal JSON with whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    const body = try std.fmt.allocPrint(alloc, "{{ \"path\" : \"{s}\" }}", .{tmp_path});
    const resp = try handlePostRepo(&registry, &db, body, alloc, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"missing path field\"") == null);
}

test "handlePostRepo accepts escaped path characters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    const resp = try handlePostRepo(&registry, &db, "{ \"path\" : \"/tmp/repo \\\"alpha\\\"\" }", alloc, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":901") != null);
}

test "handlePostRepo returns E903 for directory without git" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("rtmify-routes-nogit");
    const root = try tmp.dir.realpathAlloc(alloc, "rtmify-routes-nogit");
    defer alloc.free(root);
    const body = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\"}}", .{root});
    const resp = try handlePostRepo(&registry, &db, body, alloc, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"code\":903") != null);
}

test "handleGetRepos includes stable slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try workbook.config.addActiveRepoPath(&registry.live_config, "/tmp/repo", alloc);
    try registry.syncRuntimeConfigFromActive(alloc);

    const resp = try handleGetRepos(&registry, &db, alloc);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();

    const repos = parsed.value.object.get("repos").?.array.items;
    try testing.expectEqual(@as(usize, 1), repos.len);
    try testing.expectEqual(@as(i64, 0), repos[0].object.get("slot").?.integer);
}
