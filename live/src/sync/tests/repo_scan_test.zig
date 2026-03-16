const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const internal = @import("../internal.zig");
const repo_scan = @import("../repo_scan.zig");
const state_mod = @import("../state.zig");
const support = @import("support.zig");
const test_git_repo = @import("../../test_git_repo.zig");

test "repoScanCycle with no repos is a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{},
        .state = &state,
        .alloc = alloc,
    };

    try repo_scan.repoScanCycle(&ctx, alloc);

    var diags: std.ArrayList(internal.graph_live.RuntimeDiagnostic) = .empty;
    defer diags.deinit(alloc);
    try db.listRuntimeDiagnostics(null, alloc, &diags);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "buildFileNodePropsJson escapes quote and backslash in file path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json = try repo_scan.buildFileNodePropsJson("src/\"gps\"\\main.c", "/tmp/repo \"alpha\"", 2, true, alloc);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("src/\"gps\"\\main.c", internal.json_util.getString(parsed.value, "path").?);
    try testing.expectEqualStrings("/tmp/repo \"alpha\"", internal.json_util.getString(parsed.value, "repo").?);
    try testing.expect(internal.json_util.getObjectField(parsed.value, "present").?.bool);
}

test "buildUnknownAnnotationDetailsJson escapes ref ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const json = try repo_scan.buildUnknownAnnotationDetailsJson("REQ-\"999\"", 42, alloc);
    defer alloc.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("REQ-\"999\"", internal.json_util.getString(parsed.value, "ref_id").?);
    try testing.expectEqual(@as(i64, 42), internal.json_util.getObjectField(parsed.value, "line").?.integer);
}

test "repoScanCycle emits E1101 for unknown refs and E1005 for hanging git" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo");
    {
        const f = try tmp.dir.createFile("repo/main.c", .{});
        defer f.close();
        try f.writeAll(
            \\// REQ-001 implemented here
            \\// REQ-999 is stale
            \\int main(void) { return 0; }
        );
    }
    {
        const f = try tmp.dir.createFile("fake-git.sh", .{});
        defer f.close();
        try f.writeAll(
            \\#!/bin/sh
            \\cmd="$1"
            \\if [ "$cmd" = "log" ] || [ "$cmd" = "blame" ]; then
            \\  sleep 1
            \\  exit 0
            \\fi
            \\exit 1
        );
        try f.chmod(0o755);
    }

    var repo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_path = try tmp.dir.realpath("repo", &repo_path_buf);
    var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = try tmp.dir.realpath("fake-git.sh", &git_path_buf);

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{repo_path},
        .state = &state,
        .alloc = alloc,
        .git_exe_override = git_path,
        .git_timeout_ms_override = 100,
    };

    try repo_scan.repoScanCycle(&ctx, alloc);

    var diags: std.ArrayList(internal.graph_live.RuntimeDiagnostic) = .empty;
    defer support.freeRuntimeDiagnostics(&diags, alloc);
    try db.listRuntimeDiagnostics(null, alloc, &diags);

    var found_unknown = false;
    var found_git_timeout = false;
    var found_blame_timeout = false;
    for (diags.items) |d| {
        if (d.code == 1101 and std.mem.eql(u8, d.source, "annotation") and std.mem.indexOf(u8, d.message, "REQ-999") != null) found_unknown = true;
        if (d.code == 1005 and std.mem.eql(u8, d.source, "git")) found_git_timeout = true;
        if (d.code == 1005 and std.mem.eql(u8, d.source, "annotation")) found_blame_timeout = true;
    }

    try testing.expect(found_unknown);
    try testing.expect(found_git_timeout);
    try testing.expect(found_blame_timeout);
}

test "repoScanCycle creates file commit edges without committed_in and preserves historical file presence" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/src");
    {
        const f = try tmp.dir.createFile("repo/src/current.c", .{});
        defer f.close();
        try f.writeAll("// REQ-001 implemented here\nint main(void) { return 0; }\n");
    }
    {
        const f = try tmp.dir.createFile("fake-git.sh", .{});
        defer f.close();
        try f.writeAll(
            \\#!/bin/sh
            \\cmd="$1"
            \\shift
            \\if [ "$cmd" = "--version" ]; then
            \\  echo "git version fake"
            \\  exit 0
            \\fi
            \\if [ "$cmd" = "log" ]; then
            \\  printf '\036aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|aaaaaaa|Alice|alice@example.com|2026-03-06T12:00:00+00:00|refactor without req id\n'
            \\  printf 'M\tsrc/current.c\n'
            \\  printf 'D\tsrc/historical_only.c\n\n'
            \\  exit 0
            \\fi
            \\if [ "$cmd" = "blame" ]; then
            \\  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1\nauthor Alice\nauthor-mail <alice@example.com>\nauthor-time 1770000000\n'
            \\  exit 0
            \\fi
            \\exit 1
        );
        try f.chmod(0o755);
    }

    var repo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_path = try tmp.dir.realpath("repo", &repo_path_buf);
    var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = try tmp.dir.realpath("fake-git.sh", &git_path_buf);

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{repo_path},
        .state = &state,
        .alloc = alloc,
        .git_exe_override = git_path,
        .git_timeout_ms_override = 1000,
    };

    try repo_scan.repoScanCycle(&ctx, alloc);

    const current_path = try std.fmt.allocPrint(alloc, "{s}/src/current.c", .{repo_path});
    const historical_path = try std.fmt.allocPrint(alloc, "{s}/src/historical_only.c", .{repo_path});
    try testing.expect((try db.getNode(current_path, alloc)) != null);
    try testing.expect((try db.getNode(historical_path, alloc)) != null);
    const current = (try db.getNode(current_path, alloc)).?;
    defer {
        alloc.free(current_path);
        alloc.free(historical_path);
        alloc.free(current.id);
        alloc.free(current.type);
        alloc.free(current.properties);
    }
    var parsed_current = try std.json.parseFromSlice(std.json.Value, alloc, current.properties, .{});
    defer parsed_current.deinit();
    try testing.expect(internal.json_util.getObjectField(parsed_current.value, "present").?.bool);

    const historical = (try db.getNode(historical_path, alloc)).?;
    defer {
        alloc.free(historical.id);
        alloc.free(historical.type);
        alloc.free(historical.properties);
    }
    var parsed_hist = try std.json.parseFromSlice(std.json.Value, alloc, historical.properties, .{});
    defer parsed_hist.deinit();
    try testing.expect(!internal.json_util.getObjectField(parsed_hist.value, "present").?.bool);

    var from_current: std.ArrayList(internal.graph_live.Edge) = .empty;
    defer support.freeEdges(&from_current, alloc);
    try db.edgesFrom(current_path, alloc, &from_current);
    var has_changed_in = false;
    for (from_current.items) |e| {
        if (std.mem.eql(u8, e.label, "CHANGED_IN") and std.mem.eql(u8, e.to_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")) has_changed_in = true;
    }
    try testing.expect(has_changed_in);

    var commit_edges: std.ArrayList(internal.graph_live.Edge) = .empty;
    defer support.freeEdges(&commit_edges, alloc);
    try db.edgesFrom("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", alloc, &commit_edges);
    var has_changes = false;
    for (commit_edges.items) |e| {
        if (std.mem.eql(u8, e.label, "CHANGES") and std.mem.eql(u8, e.to_id, current_path)) has_changes = true;
        try testing.expect(!std.mem.eql(u8, e.label, "COMMITTED_IN"));
    }
    try testing.expect(has_changes);

    var req_edges: std.ArrayList(internal.graph_live.Edge) = .empty;
    defer support.freeEdges(&req_edges, alloc);
    try db.edgesFrom("REQ-001", alloc, &req_edges);
    for (req_edges.items) |e| try testing.expect(!std.mem.eql(u8, e.label, "COMMITTED_IN"));
}

test "repoScanCycle backfills full history first then uses git cursor incrementally" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/src");
    {
        const f = try tmp.dir.createFile("repo/src/current.c", .{});
        defer f.close();
        try f.writeAll("// REQ-001 implemented here\nint main(void) { return 0; }\n");
    }
    {
        const f = try tmp.dir.createFile("fake-git.sh", .{});
        defer f.close();
        try f.writeAll(
            \\#!/bin/sh
            \\if [ "$1" = "--version" ]; then
            \\  echo "git version fake"
            \\  exit 0
            \\fi
            \\if [ "$1" = "log" ]; then
            \\  for arg in "$@"; do
            \\    if echo "$arg" | grep -q '\.\.HEAD'; then
            \\      printf '\036bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|bbbbbbb|Bob|bob@example.com|2026-03-07T12:00:00+00:00|REQ-001 incremental commit\n'
            \\      printf 'M\tsrc/current.c\n\n'
            \\      exit 0
            \\    fi
            \\  done
            \\  printf '\036aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|aaaaaaa|Alice|alice@example.com|2026-03-06T12:00:00+00:00|initial history\n'
            \\  printf 'M\tsrc/current.c\n\n'
            \\  exit 0
            \\fi
            \\if [ "$1" = "blame" ]; then
            \\  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1 1 1\nauthor Alice\nauthor-mail <alice@example.com>\nauthor-time 1770000000\n'
            \\  exit 0
            \\fi
            \\exit 1
        );
        try f.chmod(0o755);
    }

    var repo_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_path = try tmp.dir.realpath("repo", &repo_path_buf);
    var git_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = try tmp.dir.realpath("fake-git.sh", &git_path_buf);

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{repo_path},
        .state = &state,
        .alloc = alloc,
        .git_exe_override = git_path,
        .git_timeout_ms_override = 1000,
    };

    try repo_scan.repoScanCycle(&ctx, alloc);
    const git_key = try std.fmt.allocPrint(alloc, "git_last_hash_{s}", .{repo_path});
    defer alloc.free(git_key);
    const stored_hash_1 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_1);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", stored_hash_1);

    try repo_scan.repoScanCycle(&ctx, alloc);
    const stored_hash_2 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_2);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", stored_hash_2);

    try testing.expect((try db.getNode("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", alloc)) != null);
    try testing.expect((try db.getNode("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", alloc)) != null);

    var req_edges: std.ArrayList(internal.graph_live.Edge) = .empty;
    defer support.freeEdges(&req_edges, alloc);
    try db.edgesFrom("REQ-001", alloc, &req_edges);
    var committed_count: usize = 0;
    for (req_edges.items) |e| {
        if (std.mem.eql(u8, e.label, "COMMITTED_IN")) committed_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), committed_count);
}

test "triggerRepoScanNow forces full file rescan regardless of last_scan cursor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    _ = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T12:00:00Z");

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.storeConfig("repo_path_0", fixture.path);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repo_scan.repoScanCycle(&ctx, alloc);

    const file_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/foo.c" });
    defer alloc.free(file_path);

    var delete_ann = try db.db.prepare("DELETE FROM nodes WHERE type='CodeAnnotation'");
    defer delete_ann.finalize();
    _ = try delete_ann.step();

    const stale_props = try repo_scan.buildFileNodePropsJson(file_path, fixture.path, 0, true, alloc);
    defer alloc.free(stale_props);
    try db.upsertNode(file_path, "SourceFile", stale_props, stale_props);

    const last_scan_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{fixture.path});
    defer alloc.free(last_scan_key);
    try db.storeConfig(last_scan_key, "9999999999");

    try repo_scan.triggerRepoScanNow(&db, &state, &.{fixture.path}, alloc);

    const annotation_id = try std.fmt.allocPrint(alloc, "{s}:1", .{file_path});
    defer alloc.free(annotation_id);
    try testing.expect((try db.getNode(annotation_id, alloc)) != null);
    try testing.expect(try repo_scan.testEdgeExists(&db, "REQ-001", annotation_id, "ANNOTATED_AT", alloc));
}

test "repoScanCycle real git repo links source annotation commit and file changes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    const commit_hash = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T12:00:00Z");

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repo_scan.repoScanCycle(&ctx, alloc);

    const current_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/foo.c" });
    const annotation_id = try std.fmt.allocPrint(alloc, "{s}:1", .{current_path});
    defer alloc.free(current_path);
    defer alloc.free(annotation_id);

    try testing.expect((try db.getNode(current_path, alloc)) != null);
    try testing.expect((try db.getNode(annotation_id, alloc)) != null);
    try testing.expect((try db.getNode(commit_hash, alloc)) != null);

    try testing.expect(try repo_scan.testEdgeExists(&db, "REQ-001", current_path, "IMPLEMENTED_IN", alloc));
    try testing.expect(try repo_scan.testEdgeExists(&db, "REQ-001", annotation_id, "ANNOTATED_AT", alloc));
    try testing.expect(try repo_scan.testEdgeExists(&db, "REQ-001", commit_hash, "COMMITTED_IN", alloc));
    try testing.expect(try repo_scan.testEdgeExists(&db, current_path, commit_hash, "CHANGED_IN", alloc));
    try testing.expect(try repo_scan.testEdgeExists(&db, commit_hash, current_path, "CHANGES", alloc));
    try testing.expect(try repo_scan.testGetNodeJsonBool(&db, current_path, "present", alloc));
}

test "repoScanCycle real git repo records later file change without inferring committed_in from later commit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    const commit_1 = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T12:00:00Z");

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repo_scan.repoScanCycle(&ctx, alloc);

    std.Thread.sleep(1200 * std.time.ns_per_ms);
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here (bob)
        \\int main(void) { return 1; }
        \\
    );
    const commit_2 = try fixture.commit("refactor without req id", "Bob", "bob@example.com", "2026-03-07T15:45:00Z");
    try repo_scan.repoScanCycle(&ctx, alloc);

    const current_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/foo.c" });
    const annotation_id = try std.fmt.allocPrint(alloc, "{s}:1", .{current_path});
    defer alloc.free(current_path);
    defer alloc.free(annotation_id);

    try testing.expect((try db.getNode(annotation_id, alloc)) != null);
    try testing.expect(try repo_scan.testEdgeExists(&db, current_path, commit_2, "CHANGED_IN", alloc));
    try testing.expect(try repo_scan.testEdgeExists(&db, commit_2, current_path, "CHANGES", alloc));

    var req_edges: std.ArrayList(internal.graph_live.Edge) = .empty;
    defer support.freeEdges(&req_edges, alloc);
    try db.edgesFrom("REQ-001", alloc, &req_edges);
    var committed_to_first = false;
    var committed_to_second = false;
    for (req_edges.items) |e| {
        if (std.mem.eql(u8, e.label, "COMMITTED_IN") and std.mem.eql(u8, e.to_id, commit_1)) committed_to_first = true;
        if (std.mem.eql(u8, e.label, "COMMITTED_IN") and std.mem.eql(u8, e.to_id, commit_2)) committed_to_second = true;
    }
    try testing.expect(committed_to_first);
    try testing.expect(!committed_to_second);
}

test "repoScanCycle real git repo classifies test annotations as verified by code" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("tests/foo_test.c",
        \\// REQ-001 verified here
        \\int test_foo(void) { return 0; }
        \\
    );
    const commit_hash = try fixture.commit("add test coverage", "Alice", "alice@example.com", "2026-03-08T09:00:00Z");

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repo_scan.repoScanCycle(&ctx, alloc);

    const test_path = try std.fs.path.join(alloc, &.{ fixture.path, "tests/foo_test.c" });
    defer alloc.free(test_path);

    const file_node = (try db.getNode(test_path, alloc)).?;
    defer {
        alloc.free(file_node.id);
        alloc.free(file_node.type);
        alloc.free(file_node.properties);
        if (file_node.suspect_reason) |s| alloc.free(s);
    }
    try testing.expectEqualStrings("TestFile", file_node.type);
    try testing.expect(try repo_scan.testEdgeExists(&db, "REQ-001", test_path, "VERIFIED_BY_CODE", alloc));
    try testing.expect(try repo_scan.testEdgeExists(&db, test_path, commit_hash, "CHANGED_IN", alloc));
}

test "repoScanCycle real git repo preserves historical rename path with present false" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/old_name.c",
        \\// REQ-001 implemented here
        \\int old_name(void) { return 0; }
        \\
    );
    _ = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T08:00:00Z");
    try fixture.renameFile("src/old_name.c", "src/new_name.c");
    const rename_commit = try fixture.commit("rename implementation file", "Alice", "alice@example.com", "2026-03-07T08:00:00Z");

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repo_scan.repoScanCycle(&ctx, alloc);

    const old_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/old_name.c" });
    const new_path = try std.fs.path.join(alloc, &.{ fixture.path, "src/new_name.c" });
    defer alloc.free(old_path);
    defer alloc.free(new_path);

    try testing.expect((try db.getNode(old_path, alloc)) != null);
    try testing.expect((try db.getNode(new_path, alloc)) != null);
    try testing.expect(!try repo_scan.testGetNodeJsonBool(&db, old_path, "present", alloc));
    try testing.expect(try repo_scan.testGetNodeJsonBool(&db, new_path, "present", alloc));
    try testing.expect(try repo_scan.testEdgeExists(&db, new_path, rename_commit, "CHANGED_IN", alloc));
}

test "repoScanCycle real git repo backfills and advances cursor incrementally" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture = try test_git_repo.RepoFixture.init(&tmp, alloc);
    defer fixture.deinit();
    try fixture.gitInit();
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 0; }
        \\
    );
    const commit_1 = try fixture.commit("REQ-001 initial implementation", "Alice", "alice@example.com", "2026-03-06T11:00:00Z");

    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    var state: state_mod.SyncState = .{};
    var ctx = repo_scan.RepoScanCtx{
        .db = &db,
        .repo_paths = &.{fixture.path},
        .state = &state,
        .alloc = alloc,
    };
    try repo_scan.repoScanCycle(&ctx, alloc);

    const git_key = try std.fmt.allocPrint(alloc, "git_last_hash_{s}", .{fixture.path});
    defer alloc.free(git_key);
    const stored_hash_1 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_1);
    try testing.expectEqualStrings(commit_1, stored_hash_1);

    std.Thread.sleep(1200 * std.time.ns_per_ms);
    try fixture.writeFile("src/foo.c",
        \\// REQ-001 implemented here
        \\int main(void) { return 2; }
        \\
    );
    const commit_2 = try fixture.commit("REQ-001 follow-up implementation", "Bob", "bob@example.com", "2026-03-07T11:00:00Z");
    try repo_scan.repoScanCycle(&ctx, alloc);

    const stored_hash_2 = (try db.getConfig(git_key, alloc)).?;
    defer alloc.free(stored_hash_2);
    try testing.expectEqualStrings(commit_2, stored_hash_2);
    try testing.expect((try db.getNode(commit_1, alloc)) != null);
    try testing.expect((try db.getNode(commit_2, alloc)) != null);
}
