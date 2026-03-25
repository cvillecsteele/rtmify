const std = @import("std");
const Allocator = std.mem.Allocator;

const artifact_discriminator = @import("artifact_discriminator.zig");
const bom = @import("bom.zig");
const design_artifacts = @import("design_artifacts.zig");
const graph_live = @import("graph_live.zig");
const soup = @import("soup.zig");
const shared = @import("routes/shared.zig");
const sync_live = @import("sync_live.zig");
const test_results = @import("test_results.zig");
const xlsx = @import("rtmify").xlsx;

pub const InboxCtx = struct {
    db: *graph_live.GraphDb,
    state: *sync_live.SyncState,
    control: *sync_live.WorkerControl,
    inbox_dir: []const u8,
    alloc: Allocator,
};

pub fn destroyInboxCtx(ctx: *InboxCtx) void {
    ctx.alloc.free(ctx.inbox_dir);
    ctx.alloc.destroy(ctx);
}

pub fn inboxThread(ctx: *InboxCtx) void {
    defer destroyInboxCtx(ctx);

    while (!ctx.control.stop_requested.load(.seq_cst)) {
        if (!ctx.state.product_enabled.load(.seq_cst)) {
            ctx.control.waitTimeout(5 * std.time.ns_per_s);
            continue;
        }

        processInboxOnce(ctx.db, ctx.inbox_dir, ctx.alloc) catch |err| {
            std.log.warn("external ingest inbox poll failed: {s}", .{@errorName(err)});
        };
        ctx.control.waitTimeout(5 * std.time.ns_per_s);
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
        if (!std.mem.endsWith(u8, entry.name, ".json") and !std.mem.endsWith(u8, entry.name, ".csv") and !std.mem.endsWith(u8, entry.name, ".xlsx") and !std.mem.endsWith(u8, entry.name, ".docx")) continue;
        try processOneFile(db, inbox_dir, entry.name, alloc);
    }
}

fn processOneFile(db: *graph_live.GraphDb, inbox_dir: []const u8, name: []const u8, alloc: Allocator) !void {
    const path = try std.fs.path.join(alloc, &.{ inbox_dir, name });
    defer alloc.free(path);
    var discrimination = artifact_discriminator.discriminateInboxPath(path, name, alloc) catch |err| {
        try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
        return;
    };
    defer discrimination.deinit(alloc);
    if (!discrimination.accepted) {
        try rejectDiscriminatedFile(db, inbox_dir, name, alloc, discrimination);
        return;
    }

    switch (discrimination.kind.?) {
        .test_results => {
            const bytes = std.fs.cwd().readFileAlloc(alloc, path, 25 * 1024 * 1024) catch |err| {
                try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
                return;
            };
            defer alloc.free(bytes);
            if (bytes.len > 10 * 1024 * 1024) {
                try rejectFile(db, inbox_dir, name, alloc, "TestResultsTooLarge");
                return;
            }
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
        },
        .bom => {
            const bytes = std.fs.cwd().readFileAlloc(alloc, path, 25 * 1024 * 1024) catch |err| {
                try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
                return;
            };
            defer alloc.free(bytes);
            if (std.mem.endsWith(u8, name, ".xlsx")) {
                var grouped = bom.ingestXlsxBody(db, bytes, alloc) catch |err| {
                    try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
                    return;
                };
                defer grouped.deinit(alloc);

                const archived_path = try archiveFile(inbox_dir, "processed", name, alloc);
                defer alloc.free(archived_path);
                try recordGroupedBomWarnings(db, archived_path, grouped, alloc);
                return;
            }

            var response = bom.ingestInboxFile(db, name, bytes, alloc) catch |err| {
                try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
                return;
            };
            defer response.deinit(alloc);

            const archived_path = try archiveFile(inbox_dir, "processed", name, alloc);
            defer alloc.free(archived_path);
            try recordBomWarnings(db, archived_path, response, alloc);
            return;
        },
        .soup => {
            const full_product_identifier = extractSoupInboxProductIdentifier(name) orelse {
                try rejectFile(db, inbox_dir, name, alloc, "SOUP_NO_PRODUCT_IDENTIFIER");
                return;
            };
            var response = soup.ingestXlsxInboxPath(db, path, full_product_identifier, alloc) catch |err| {
                try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
                return;
            };
            defer response.deinit(alloc);

            const archived_path = try archiveFile(inbox_dir, "processed", name, alloc);
            defer alloc.free(archived_path);
            try recordSoupWarnings(db, archived_path, response, alloc);
            return;
        },
        .rtm_workbook, .srs_docx, .sysrd_docx => {
            const kind_enum = artifact_discriminator.candidateKindToDesignArtifactKind(discrimination.kind.?) orelse unreachable;
            const logical_key = try alloc.dupe(u8, discrimination.filename_stem_slug);
            defer alloc.free(logical_key);
            const archived_path = try archiveDesignArtifactFile(inbox_dir, kind_enum, logical_key, name, alloc);
            defer alloc.free(archived_path);
            switch (kind_enum) {
                .rtm_workbook => {
                    var ingest_result = design_artifacts.ingestRtmWorkbookPath(db, archived_path, logical_key, std.fs.path.basename(archived_path), "external_inbox", alloc) catch |err| {
                        try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
                        return;
                    };
                    defer ingest_result.deinit(alloc);
                },
                .srs_docx, .sysrd_docx => {
                    var ingest_result = design_artifacts.ingestDocxPath(db, archived_path, kind_enum, logical_key, std.fs.path.basename(archived_path), "external_inbox", alloc) catch |err| {
                        try rejectFile(db, inbox_dir, name, alloc, @errorName(err));
                        return;
                    };
                    defer ingest_result.deinit(alloc);
                },
            }
            return;
        },
    }

    const archived_path = try archiveFile(inbox_dir, "processed", name, alloc);
    alloc.free(archived_path);
}

fn extractSoupInboxProductIdentifier(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "SOUP__")) return null;
    if (!std.mem.endsWith(u8, name, ".xlsx")) return null;
    return name["SOUP__".len .. name.len - ".xlsx".len];
}

fn rejectFile(db: *graph_live.GraphDb, inbox_dir: []const u8, name: []const u8, alloc: Allocator, reason: []const u8) !void {
    std.log.warn("external design/bom inbox file rejected name={s} reason={s}", .{ name, reason });
    const archived_path = try archiveFile(inbox_dir, "rejected", name, alloc);
    defer alloc.free(archived_path);
    const subject = try alloc.dupe(u8, archived_path);
    defer alloc.free(subject);
    const message = try std.fmt.allocPrint(alloc, "Rejected inbox file {s}: {s}", .{ name, reason });
    defer alloc.free(message);
    const dedupe_key = try std.fmt.allocPrint(alloc, "external_ingest_inbox:{s}", .{name});
    defer alloc.free(dedupe_key);
    try db.upsertRuntimeDiagnostic(
        dedupe_key,
        9501,
        "warn",
        "External ingest inbox file rejected",
        message,
        "external_ingest_inbox",
        subject,
        "{}",
    );
}

fn rejectDiscriminatedFile(
    db: *graph_live.GraphDb,
    inbox_dir: []const u8,
    name: []const u8,
    alloc: Allocator,
    result: artifact_discriminator.DiscriminationResult,
) !void {
    const kind_str = if (result.kind) |kind| kind.toString() else "unknown";
    const confidence = result.confidence.toString();
    const signal_summary = try discriminationSignalSummary(result.signals, alloc);
    defer alloc.free(signal_summary);

    std.log.warn(
        "external design/bom inbox file rejected name={s} reason={s} classified={s} confidence={s}",
        .{ name, result.reason_code, kind_str, confidence },
    );

    const archived_path = try archiveFile(inbox_dir, "rejected", name, alloc);
    defer alloc.free(archived_path);
    const subject = try alloc.dupe(u8, archived_path);
    defer alloc.free(subject);
    const message = try std.fmt.allocPrint(
        alloc,
        "Rejected inbox file {s}: {s} ({s})",
        .{ name, result.reason, result.reason_code },
    );
    defer alloc.free(message);
    const dedupe_key = try std.fmt.allocPrint(alloc, "external_ingest_inbox:{s}", .{name});
    defer alloc.free(dedupe_key);

    var details: std.ArrayList(u8) = .empty;
    defer details.deinit(alloc);
    try details.appendSlice(alloc, "{\"reason_code\":");
    try shared.appendJsonStr(&details, result.reason_code, alloc);
    try details.appendSlice(alloc, ",\"reason\":");
    try shared.appendJsonStr(&details, result.reason, alloc);
    try details.appendSlice(alloc, ",\"classified_kind\":");
    try shared.appendJsonStr(&details, kind_str, alloc);
    try details.appendSlice(alloc, ",\"confidence\":");
    try shared.appendJsonStr(&details, confidence, alloc);
    try details.appendSlice(alloc, ",\"signal_summary\":");
    try shared.appendJsonStr(&details, signal_summary, alloc);
    try details.append(alloc, '}');

    try db.upsertRuntimeDiagnostic(
        dedupe_key,
        9501,
        "warn",
        "External ingest inbox file rejected",
        message,
        "external_ingest_inbox",
        subject,
        details.items,
    );
}

fn discriminationSignalSummary(signals: []const artifact_discriminator.Signal, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const limit = @min(signals.len, 4);
    for (signals[0..limit], 0..) |signal, idx| {
        if (idx > 0) try buf.appendSlice(alloc, "; ");
        try std.fmt.format(buf.writer(alloc), "{s}:{s}:{d}", .{
            @tagName(signal.kind),
            signal.detail,
            signal.weight,
        });
    }
    return alloc.dupe(u8, buf.items);
}

fn recordBomWarnings(db: *graph_live.GraphDb, archived_path: []const u8, response: bom.BomIngestResponse, alloc: Allocator) !void {
    for (response.warnings) |warning| {
        var details: std.ArrayList(u8) = .empty;
        defer details.deinit(alloc);
        try details.appendSlice(alloc, "{\"warning_code\":");
        try shared.appendJsonStr(&details, warning.code, alloc);
        try details.appendSlice(alloc, ",\"warning_subject\":");
        try shared.appendJsonStrOpt(&details, warning.subject, alloc);
        try details.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&details, response.full_product_identifier, alloc);
        try details.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&details, response.bom_name, alloc);
        try details.appendSlice(alloc, ",\"bom_type\":");
        try shared.appendJsonStr(&details, @tagName(response.bom_type), alloc);
        try details.append(alloc, '}');

        const message = try std.fmt.allocPrint(
            alloc,
            "Ingested BOM file with warning {s}: {s}",
            .{ warning.code, warning.message },
        );
        defer alloc.free(message);
        const subject = try alloc.dupe(u8, archived_path);
        defer alloc.free(subject);
        const dedupe_key = try std.fmt.allocPrint(
            alloc,
            "external_ingest_inbox:{s}:{s}:{s}",
            .{ archived_path, warning.code, warning.subject orelse "" },
        );
        defer alloc.free(dedupe_key);
        try db.upsertRuntimeDiagnostic(
            dedupe_key,
            9502,
            "warn",
            "External BOM ingested with warnings",
            message,
            "external_ingest_inbox",
            subject,
            details.items,
        );
    }
}

fn recordGroupedBomWarnings(db: *graph_live.GraphDb, archived_path: []const u8, response: bom.GroupedBomIngestResponse, alloc: Allocator) !void {
    for (response.groups) |group| {
        for (group.warnings) |warning| {
            var details: std.ArrayList(u8) = .empty;
            defer details.deinit(alloc);
            try details.appendSlice(alloc, "{\"warning_code\":");
            try shared.appendJsonStr(&details, warning.code, alloc);
            try details.appendSlice(alloc, ",\"warning_subject\":");
            try shared.appendJsonStrOpt(&details, warning.subject, alloc);
            try details.appendSlice(alloc, ",\"full_product_identifier\":");
            try shared.appendJsonStr(&details, group.full_product_identifier, alloc);
            try details.appendSlice(alloc, ",\"bom_name\":");
            try shared.appendJsonStr(&details, group.bom_name, alloc);
            try details.appendSlice(alloc, ",\"bom_type\":\"hardware\"}");

            const message = try std.fmt.allocPrint(
                alloc,
                "Ingested BOM workbook with warning {s}: {s}",
                .{ warning.code, warning.message },
            );
            defer alloc.free(message);
            const subject = try alloc.dupe(u8, archived_path);
            defer alloc.free(subject);
            const dedupe_key = try std.fmt.allocPrint(
                alloc,
                "external_ingest_inbox:{s}:{s}:{s}:{s}",
                .{ archived_path, group.bom_name, warning.code, warning.subject orelse "" },
            );
            defer alloc.free(dedupe_key);
            try db.upsertRuntimeDiagnostic(
                dedupe_key,
                9502,
                "warn",
                "External BOM ingested with warnings",
                message,
                "external_ingest_inbox",
                subject,
                details.items,
            );
        }
    }
}

fn recordSoupWarnings(db: *graph_live.GraphDb, archived_path: []const u8, response: soup.SoupIngestResponse, alloc: Allocator) !void {
    for (response.warnings) |warning| {
        var details: std.ArrayList(u8) = .empty;
        defer details.deinit(alloc);
        try details.appendSlice(alloc, "{\"warning_code\":");
        try shared.appendJsonStr(&details, warning.code, alloc);
        try details.appendSlice(alloc, ",\"warning_subject\":");
        try shared.appendJsonStrOpt(&details, warning.subject, alloc);
        try details.appendSlice(alloc, ",\"full_product_identifier\":");
        try shared.appendJsonStr(&details, response.full_product_identifier, alloc);
        try details.appendSlice(alloc, ",\"bom_name\":");
        try shared.appendJsonStr(&details, response.bom_name, alloc);
        try details.appendSlice(alloc, ",\"bom_type\":\"software\"}");

        const message = try std.fmt.allocPrint(
            alloc,
            "Ingested SOUP file with warning {s}: {s}",
            .{ warning.code, warning.message },
        );
        defer alloc.free(message);
        const subject = try alloc.dupe(u8, archived_path);
        defer alloc.free(subject);
        const dedupe_key = try std.fmt.allocPrint(
            alloc,
            "external_ingest_inbox:{s}:{s}:{s}",
            .{ archived_path, warning.code, warning.subject orelse "" },
        );
        defer alloc.free(dedupe_key);
        try db.upsertRuntimeDiagnostic(
            dedupe_key,
            9502,
            "warn",
            "External SOUP ingested with warnings",
            message,
            "external_ingest_inbox",
            subject,
            details.items,
        );
    }
}

fn archiveFile(inbox_dir: []const u8, subdir: []const u8, name: []const u8, alloc: Allocator) ![]const u8 {
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
    return alloc.dupe(u8, target_path);
}

fn archiveDesignArtifactFile(
    inbox_dir: []const u8,
    kind: design_artifacts.ArtifactKind,
    logical_key: []const u8,
    name: []const u8,
    alloc: Allocator,
) ![]const u8 {
    const target_dir_path = try std.fs.path.join(alloc, &.{ inbox_dir, "processed", "design-artifacts", kind.toString() });
    defer alloc.free(target_dir_path);
    try ensureDirPath(target_dir_path);
    const extension = switch (kind) {
        .rtm_workbook => ".xlsx",
        .srs_docx, .sysrd_docx => ".docx",
    };
    const target_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ logical_key, extension });
    defer alloc.free(target_name);
    const source_path = try std.fs.path.join(alloc, &.{ inbox_dir, name });
    defer alloc.free(source_path);
    const target_path = try std.fs.path.join(alloc, &.{ target_dir_path, target_name });
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
    return target_path;
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

test "valid test results file in inbox is ingested and moved to processed" {
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

test "csv bom file in inbox is ingested and moved to processed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, "inbox" });
    defer testing.allocator.free(inbox_dir);
    try ensureInboxLayout(inbox_dir);

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
    try ensureInboxLayout(inbox_dir);

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
    try ensureInboxLayout(inbox_dir);

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
    try ensureInboxLayout(inbox_dir);

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
    try ensureInboxLayout(inbox_dir);

    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "bad.json" });
    defer testing.allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "{\"unknown\":true}" });

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
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    try testing.expect(diags.items.len > 0);
}
