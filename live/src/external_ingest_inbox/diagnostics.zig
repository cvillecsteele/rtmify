const std = @import("std");
const Allocator = std.mem.Allocator;

const artifact_discriminator = @import("../artifact_discriminator.zig");
const bom = @import("../bom.zig");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const soup = @import("../soup.zig");
const archive = @import("archive.zig");

pub fn rejectFile(db: *graph_live.GraphDb, inbox_dir: []const u8, name: []const u8, alloc: Allocator, reason: []const u8) !void {
    std.log.warn("external design/bom inbox file rejected name={s} reason={s}", .{ name, reason });
    const archived_path = try archive.archiveFile(inbox_dir, "rejected", name, alloc);
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

pub fn rejectDiscriminatedFile(
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

    const archived_path = try archive.archiveFile(inbox_dir, "rejected", name, alloc);
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

pub fn discriminationSignalSummary(signals: []const artifact_discriminator.Signal, alloc: Allocator) ![]const u8 {
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

pub fn recordBomWarnings(db: *graph_live.GraphDb, archived_path: []const u8, response: bom.BomIngestResponse, alloc: Allocator) !void {
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

pub fn recordGroupedBomWarnings(
    db: *graph_live.GraphDb,
    archived_path: []const u8,
    response: bom.GroupedBomIngestResponse,
    alloc: Allocator,
) !void {
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

pub fn recordSoupWarnings(db: *graph_live.GraphDb, archived_path: []const u8, response: soup.SoupIngestResponse, alloc: Allocator) !void {
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

const testing = std.testing;

test "discriminationSignalSummary truncates to first four signals" {
    const signals = [_]artifact_discriminator.Signal{
        .{ .kind = .extension, .detail = "a", .weight = 1 },
        .{ .kind = .filename_token, .detail = "b", .weight = 2 },
        .{ .kind = .docx_heading_keyword, .detail = "c", .weight = 3 },
        .{ .kind = .json_top_level_key, .detail = "d", .weight = 4 },
        .{ .kind = .xlsx_sheet_name, .detail = "e", .weight = 5 },
    };

    const summary = try discriminationSignalSummary(&signals, testing.allocator);
    defer testing.allocator.free(summary);
    try testing.expect(std.mem.indexOf(u8, summary, "a") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "d") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "xlsx_sheet_name:e:5") == null);
}
