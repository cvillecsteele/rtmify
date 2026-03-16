const std = @import("std");
const internal = @import("internal.zig");
const state_mod = @import("state.zig");
const runtime_diag = @import("runtime_diag.zig");
const port_db = @import("port_db.zig");

pub const RepoScanCtx = struct {
    db: *internal.GraphDb,
    repo_paths: []const []const u8,
    state: *state_mod.SyncState,
    control: ?*state_mod.WorkerControl = null,
    alloc: internal.Allocator,
    git_exe_override: ?[]const u8 = null,
    git_timeout_ms_override: ?u64 = null,
};

pub fn destroyRepoScanCtx(ctx: *RepoScanCtx) void {
    for (ctx.repo_paths) |repo_path| ctx.alloc.free(repo_path);
    ctx.alloc.free(ctx.repo_paths);
    ctx.alloc.destroy(ctx);
}

pub fn repoScanThread(ctx: *RepoScanCtx) void {
    defer destroyRepoScanCtx(ctx);

    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    {
        const git_check = std.process.Child.run(.{
            .argv = &.{ "git", "--version" },
            .allocator = gpa,
        }) catch {
            std.log.err("git not found on PATH — repo scan disabled", .{});
            return;
        };
        defer gpa.free(git_check.stdout);
        defer gpa.free(git_check.stderr);
        if (git_check.term != .Exited or git_check.term.Exited != 0) {
            std.log.err("git check failed — repo scan disabled", .{});
            return;
        }
    }

    while (!(if (ctx.control) |control| control.stop_requested.load(.seq_cst) else false)) {
        if (!ctx.state.product_enabled.load(.seq_cst)) {
            if (ctx.control) |control| {
                control.waitTimeout(30 * std.time.ns_per_s);
            } else {
                std.Thread.sleep(30 * std.time.ns_per_s);
            }
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        repoScanCycleSerialized(ctx, a) catch |e| {
            std.log.warn("repo scan cycle failed: {s}", .{@errorName(e)});
        };

        if (ctx.control) |control| {
            control.waitTimeout(60 * std.time.ns_per_s);
        } else {
            std.Thread.sleep(60 * std.time.ns_per_s);
        }
    }
}

pub fn triggerRepoScanNow(db: *internal.GraphDb, state: *state_mod.SyncState, repo_paths: []const []const u8, alloc: internal.Allocator) !void {
    for (repo_paths) |repo_path| {
        const last_scan_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{repo_path});
        defer alloc.free(last_scan_key);
        try db.storeConfig(last_scan_key, "0");
    }

    var ctx = RepoScanCtx{
        .db = db,
        .repo_paths = repo_paths,
        .state = state,
        .alloc = alloc,
    };
    std.log.info("repo scan: manual scan requested", .{});
    try repoScanCycleSerialized(&ctx, alloc);
}

pub fn repoScanCycleSerialized(ctx: *RepoScanCtx, alloc: internal.Allocator) !void {
    ctx.state.repo_scan_mu.lock();
    defer ctx.state.repo_scan_mu.unlock();
    const started_at = std.time.timestamp();
    ctx.state.repo_scan_in_progress.store(true, .seq_cst);
    ctx.state.repo_scan_last_started_at.store(started_at, .seq_cst);
    defer {
        ctx.state.repo_scan_in_progress.store(false, .seq_cst);
        ctx.state.repo_scan_last_finished_at.store(std.time.timestamp(), .seq_cst);
    }
    try repoScanCycle(ctx, alloc);
}

pub fn repoScanCycle(ctx: *RepoScanCtx, alloc: internal.Allocator) !void {
    const git_options = internal.git_mod.GitOptions{
        .exe = ctx.git_exe_override,
        .timeout_ms = ctx.git_timeout_ms_override,
    };
    var dyn_paths: std.ArrayList([]const u8) = .empty;
    defer dyn_paths.deinit(alloc);
    {
        var idx: usize = 0;
        while (idx < 64) : (idx += 1) {
            const key = try std.fmt.allocPrint(alloc, "repo_path_{d}", .{idx});
            defer alloc.free(key);
            const p = (try ctx.db.getConfig(key, alloc)) orelse continue;
            try dyn_paths.append(alloc, p);
        }
    }
    outer: for (ctx.repo_paths) |p| {
        for (dyn_paths.items) |dp| {
            if (std.mem.eql(u8, dp, p)) continue :outer;
        }
        try dyn_paths.append(alloc, try alloc.dupe(u8, p));
    }

    if (dyn_paths.items.len == 0) return;

    const known_ids = try internal.annotations_mod.buildKnownIds(ctx.db, alloc);

    for (dyn_paths.items) |repo_path| {
        try ctx.db.clearRuntimeDiagnosticsBySubjectPrefix("repo_scan", repo_path);
        try ctx.db.clearRuntimeDiagnosticsBySubjectPrefix("git", repo_path);
        try ctx.db.clearRuntimeDiagnosticsBySubjectPrefix("annotation", repo_path);

        const last_scan_key = try std.fmt.allocPrint(alloc, "last_scan_{s}", .{repo_path});
        const last_scan_str = (try ctx.db.getConfig(last_scan_key, alloc)) orelse "0";
        const last_scan: i64 = std.fmt.parseInt(i64, last_scan_str, 10) catch 0;

        const git_key = try std.fmt.allocPrint(alloc, "git_last_hash_{s}", .{repo_path});
        const last_hash = try ctx.db.getConfig(git_key, alloc);

        const files = internal.repo_mod.scanRepo(repo_path, last_scan, alloc) catch |e| {
            std.log.warn("repo scan {s}: {s}", .{ repo_path, @errorName(e) });
            try runtime_diag.upsertRuntimeDiag(ctx.db, "repo_scan", 904, "err", "Repo path not readable", try std.fmt.allocPrint(alloc, "Repo scan failed for {s}: {s}", .{ repo_path, @errorName(e) }), repo_path, "{}");
            continue;
        };

        var blame_count: usize = 0;

        for (files) |file| {
            var existing_file_ann_ids = std.StringHashMap(void).init(alloc);
            defer existing_file_ann_ids.deinit();
            {
                var st = try ctx.db.db.prepare(
                    "SELECT id FROM nodes WHERE type='CodeAnnotation' AND id LIKE ? || ':%'"
                );
                defer st.finalize();
                try st.bindText(1, file.path);
                while (try st.step()) {
                    const id = try alloc.dupe(u8, st.columnText(0));
                    try existing_file_ann_ids.put(id, {});
                }
            }

            var seen_file_ann_ids = std.StringHashMap(void).init(alloc);
            defer seen_file_ann_ids.deinit();

            const node_type: []const u8 = switch (file.kind) {
                .source => "SourceFile",
                .test_file => "TestFile",
                .ignored => continue,
            };

            const scan = internal.annotations_mod.scanFileDetailed(file.path, known_ids, alloc) catch |e| {
                try runtime_diag.upsertRuntimeDiag(ctx.db, "annotation", 1105, "info", "Unrecognized file extension", try std.fmt.allocPrint(alloc, "Annotation scan failed for {s}: {s}", .{ file.path, @errorName(e) }), file.path, "{}");
                continue;
            };
            const anns = scan.annotations;
            const annotation_count = anns.len;
            const props = try buildFileNodePropsJson(file.path, repo_path, annotation_count, true, alloc);
            try ctx.db.upsertNode(file.path, node_type, props, props);

            if (hasDuplicateAnnotationLine(anns)) {
                try runtime_diag.upsertRuntimeDiag(ctx.db, "annotation", 1106, "info", "Multiple annotations on same line", try std.fmt.allocPrint(alloc, "File {s} has multiple requirement annotations on the same line", .{file.path}), file.path, "{}");
            }

            for (scan.unknown_refs) |unknown| {
                const subject = try std.fmt.allocPrint(alloc, "{s}:{d}:{s}", .{ unknown.file_path, unknown.line_number, unknown.ref_id });
                const details = try buildUnknownAnnotationDetailsJson(unknown.ref_id, unknown.line_number, alloc);
                try runtime_diag.upsertRuntimeDiag(ctx.db, "annotation", 1101, "warn", "Annotation references unknown requirement ID", try std.fmt.allocPrint(alloc, "Unknown annotation reference {s} at {s}:{d}", .{ unknown.ref_id, unknown.file_path, unknown.line_number }), subject, details);
            }

            for (anns) |ann| {
                const ann_id = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ file.path, ann.line_number });
                {
                    var ap: std.ArrayList(u8) = .empty;
                    try ap.appendSlice(alloc, "{\"req_id\":\"");
                    try port_db.appendJsonEscaped(&ap, ann.req_id, alloc);
                    try ap.appendSlice(alloc, "\",\"file_path\":\"");
                    try port_db.appendJsonEscaped(&ap, ann.file_path, alloc);
                    try ap.writer(alloc).print("\",\"line_number\":{d},\"context\":\"", .{ann.line_number});
                    try port_db.appendJsonEscaped(&ap, ann.context, alloc);
                    try ap.appendSlice(alloc, "\"}");
                    try ctx.db.upsertNode(ann_id, "CodeAnnotation", ap.items, null);
                }
                try seen_file_ann_ids.put(try alloc.dupe(u8, ann_id), {});

                ctx.db.addEdge(ann.req_id, ann_id, "ANNOTATED_AT") catch {};
                ctx.db.addEdge(file.path, ann_id, "CONTAINS") catch {};
                if (file.kind == .source) ctx.db.addEdge(ann.req_id, file.path, "IMPLEMENTED_IN") catch {};
                if (file.kind == .test_file) ctx.db.addEdge(ann.req_id, file.path, "VERIFIED_BY_CODE") catch {};

                if (blame_count < 50) {
                    const blame_subject = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ file.path, ann.line_number });
                    if (internal.git_mod.gitBlameWithOptions(repo_path, file.path, ann.line_number, git_options, alloc)) |blame| {
                        var bp: std.ArrayList(u8) = .empty;
                        try bp.appendSlice(alloc, "{\"req_id\":\"");
                        try port_db.appendJsonEscaped(&bp, ann.req_id, alloc);
                        try bp.appendSlice(alloc, "\",\"file_path\":\"");
                        try port_db.appendJsonEscaped(&bp, ann.file_path, alloc);
                        try bp.writer(alloc).print("\",\"line_number\":{d},\"blame_author\":\"", .{ann.line_number});
                        try port_db.appendJsonEscaped(&bp, blame.author, alloc);
                        try bp.appendSlice(alloc, "\",\"author_email\":\"");
                        try port_db.appendJsonEscaped(&bp, blame.author_email, alloc);
                        try bp.writer(alloc).print("\",\"author_time\":{d},\"short_hash\":\"", .{blame.author_time});
                        const sh = blame.commit_hash[0..@min(7, blame.commit_hash.len)];
                        try port_db.appendJsonEscaped(&bp, sh, alloc);
                        try bp.appendSlice(alloc, "\",\"context\":\"");
                        try port_db.appendJsonEscaped(&bp, ann.context, alloc);
                        try bp.appendSlice(alloc, "\"}");
                        try ctx.db.upsertNode(ann_id, "CodeAnnotation", bp.items, null);
                        try runtime_diag.clearRuntimeDiagByCodeAndSubject(ctx.db, "annotation", blame_subject, 1002);
                        try runtime_diag.clearRuntimeDiagByCodeAndSubject(ctx.db, "annotation", blame_subject, 1004);
                        try runtime_diag.clearRuntimeDiagByCodeAndSubject(ctx.db, "annotation", blame_subject, 1005);
                        blame_count += 1;
                    } else |e| {
                        const diag_code: u16 = if (e == error.Timeout)
                            1005
                        else if (e == error.BlameParseErr)
                            1004
                        else
                            1002;
                        const title = if (diag_code == 1005)
                            "git command timed out (> 10s)"
                        else if (diag_code == 1004)
                            "Failed to parse git blame output"
                        else
                            "git blame command failed";
                        try runtime_diag.upsertRuntimeDiag(ctx.db, "annotation", diag_code, "warn", title, try std.fmt.allocPrint(alloc, "git blame failed for {s}:{d}: {s}", .{ file.path, ann.line_number, @errorName(e) }), blame_subject, "{}");
                    }
                }
            }

            var stale_file_it = existing_file_ann_ids.keyIterator();
            while (stale_file_it.next()) |id| {
                if (seen_file_ann_ids.contains(id.*)) continue;
                ctx.db.deleteNode(id.*) catch |e| {
                    std.log.warn("deleteNode {s}: {s}", .{ id.*, @errorName(e) });
                };
            }
        }

        const commits = internal.git_mod.gitLogWithOptions(repo_path, last_hash, known_ids, git_options, alloc) catch |e| blk: {
            const diag_code: u16 = if (e == error.Timeout)
                1005
            else if (e == error.CommitParseErr)
                1003
            else
                1001;
            const title = if (diag_code == 1005)
                "git command timed out (> 10s)"
            else if (diag_code == 1003)
                "Commit message parse error"
            else
                "git log command failed";
            try runtime_diag.upsertRuntimeDiag(ctx.db, "git", diag_code, "warn", title, try std.fmt.allocPrint(alloc, "git log failed for {s}: {s}", .{ repo_path, @errorName(e) }), repo_path, "{}");
            break :blk &.{};
        };
        if (commits.len > 0) {
            try runtime_diag.clearRuntimeDiagByCodeAndSubject(ctx.db, "git", repo_path, 1001);
            try runtime_diag.clearRuntimeDiagByCodeAndSubject(ctx.db, "git", repo_path, 1003);
            try runtime_diag.clearRuntimeDiagByCodeAndSubject(ctx.db, "git", repo_path, 1005);
        }
        var last_hash_new: ?[]const u8 = null;
        for (commits) |commit| {
            var cp: std.ArrayList(u8) = .empty;
            try cp.appendSlice(alloc, "{\"hash\":\"");
            try port_db.appendJsonEscaped(&cp, commit.hash, alloc);
            try cp.appendSlice(alloc, "\",\"short_hash\":\"");
            try port_db.appendJsonEscaped(&cp, commit.short_hash, alloc);
            try cp.appendSlice(alloc, "\",\"author\":\"");
            try port_db.appendJsonEscaped(&cp, commit.author, alloc);
            try cp.appendSlice(alloc, "\",\"email\":\"");
            try port_db.appendJsonEscaped(&cp, commit.email, alloc);
            try cp.appendSlice(alloc, "\",\"date\":\"");
            try port_db.appendJsonEscaped(&cp, commit.date_iso, alloc);
            try cp.appendSlice(alloc, "\",\"message\":\"");
            try port_db.appendJsonEscaped(&cp, commit.message, alloc);
            try cp.appendSlice(alloc, "\",\"req_ids\":[");
            for (commit.req_ids, 0..) |rid, ri| {
                if (ri > 0) try cp.append(alloc, ',');
                try cp.append(alloc, '"');
                try port_db.appendJsonEscaped(&cp, rid, alloc);
                try cp.append(alloc, '"');
            }
            try cp.appendSlice(alloc, "]}");
            try ctx.db.upsertNode(commit.hash, "Commit", cp.items, null);
            for (commit.req_ids) |req_id| {
                ctx.db.addEdge(req_id, commit.hash, "COMMITTED_IN") catch {};
            }
            for (commit.file_changes) |change| {
                const full_changed_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ repo_path, change.path });
                const changed_kind = internal.repo_mod.classifyFile(change.path);
                const changed_node_type: ?[]const u8 = switch (changed_kind) {
                    .source => "SourceFile",
                    .test_file => "TestFile",
                    .ignored => null,
                };
                if (changed_node_type) |nt| {
                    try ensureHistoricalFileNode(ctx.db, full_changed_path, repo_path, nt, alloc);
                    ctx.db.addEdge(full_changed_path, commit.hash, "CHANGED_IN") catch {};
                    ctx.db.addEdge(commit.hash, full_changed_path, "CHANGES") catch {};
                }
            }
            if (last_hash_new == null) last_hash_new = commit.hash;
        }

        const now_str = try std.fmt.allocPrint(alloc, "{d}", .{std.time.timestamp()});
        try ctx.db.storeConfig(last_scan_key, now_str);
        if (last_hash_new) |h| try ctx.db.storeConfig(git_key, h);
    }

    const scan_now_str = try std.fmt.allocPrint(alloc, "{d}", .{std.time.timestamp()});
    ctx.db.storeConfig("last_scan_at", scan_now_str) catch {};
}

pub fn buildFileNodePropsJson(path: []const u8, repo: []const u8, annotation_count: usize, present: bool, alloc: internal.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"path\":");
    try internal.json_util.appendJsonQuoted(&buf, path, alloc);
    try buf.appendSlice(alloc, ",\"repo\":");
    try internal.json_util.appendJsonQuoted(&buf, repo, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"annotation_count\":{d}", .{annotation_count});
    try buf.appendSlice(alloc, ",\"present\":");
    try buf.appendSlice(alloc, if (present) "true" else "false");
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

pub fn ensureHistoricalFileNode(db: *internal.GraphDb, path: []const u8, repo: []const u8, node_type: []const u8, alloc: internal.Allocator) !void {
    if (try db.getNode(path, alloc)) |existing| {
        alloc.free(existing.id);
        alloc.free(existing.type);
        alloc.free(existing.properties);
        if (existing.suspect_reason) |reason| alloc.free(reason);
        return;
    }
    const props = try buildFileNodePropsJson(path, repo, 0, false, alloc);
    try db.upsertNode(path, node_type, props, props);
}

pub fn buildUnknownAnnotationDetailsJson(ref_id: []const u8, line_number: usize, alloc: internal.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"ref_id\":");
    try internal.json_util.appendJsonQuoted(&buf, ref_id, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"line\":{d}", .{line_number});
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

pub fn hasDuplicateAnnotationLine(anns: []const internal.annotations_mod.Annotation) bool {
    for (anns, 0..) |ann, i| {
        for (anns[i + 1 ..]) |other| {
            if (ann.line_number == other.line_number) return true;
        }
    }
    return false;
}

pub fn testEdgeExists(db: *internal.GraphDb, from_id: []const u8, to_id: []const u8, label: []const u8, alloc: internal.Allocator) !bool {
    var edges: std.ArrayList(internal.graph_live.Edge) = .empty;
    defer {
        for (edges.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        edges.deinit(alloc);
    }
    try db.edgesFrom(from_id, alloc, &edges);
    for (edges.items) |e| {
        if (std.mem.eql(u8, e.to_id, to_id) and std.mem.eql(u8, e.label, label)) return true;
    }
    return false;
}

pub fn testGetNodeJsonBool(db: *internal.GraphDb, node_id: []const u8, field: []const u8, alloc: internal.Allocator) !bool {
    const node = (try db.getNode(node_id, alloc)) orelse return error.TestExpectedNodeMissing;
    defer {
        alloc.free(node.id);
        alloc.free(node.type);
        alloc.free(node.properties);
        if (node.suspect_reason) |s| alloc.free(s);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, node.properties, .{});
    defer parsed.deinit();
    return internal.json_util.getObjectField(parsed.value, field).?.bool;
}
