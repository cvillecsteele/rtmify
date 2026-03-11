const std = @import("std");
const cad = @import("lib.zig");

fn usage() void {
    std.debug.print(
        \\usage:
        \\  rtmify-cadinspect detect <file>
        \\  rtmify-cadinspect streams <file>
        \\  rtmify-cadinspect extract <file> [--known-id REQ-001 ...]
        \\  rtmify-cadinspect evaluate <file-or-dir> [--markdown]
        \\  rtmify-cadinspect dump-stream <file> --stream "Components6/Data"
        \\  rtmify-cadinspect dump-stream <file> --stream "FileHeader"
        \\
    , .{});
}

fn printJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try writer.print("\\u{X:0>4}", .{ch}),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

fn printEvidenceJson(records: []const cad.evidence.EvidenceRecord, writer: anytype) !void {
    try writer.writeAll("[\n");
    for (records, 0..) |rec, i| {
        if (i != 0) try writer.writeAll(",\n");
        try writer.writeAll("  {\n");
        try writer.print("    \"artifact_kind\": \"{s}\",\n", .{@tagName(rec.artifact_kind)});
        try writer.print("    \"scope_kind\": \"{s}\",\n", .{@tagName(rec.scope_kind)});
        try writer.writeAll("    \"source_path\": ");
        try printJsonString(writer, rec.source_path);
        try writer.writeAll(",\n    \"scope_identifier\": ");
        if (rec.scope_identifier) |v| try printJsonString(writer, v) else try writer.writeAll("null");
        try writer.writeAll(",\n    \"display_name\": ");
        if (rec.display_name) |v| try printJsonString(writer, v) else try writer.writeAll("null");
        try writer.writeAll(",\n    \"properties\": {\n");
        for (rec.properties, 0..) |prop, prop_idx| {
            try writer.writeAll("      ");
            try printJsonString(writer, prop.key);
            try writer.writeAll(": ");
            try printJsonString(writer, prop.value);
            if (prop_idx + 1 != rec.properties.len) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("    },\n    \"matched_requirement_ids\": [");
        for (rec.matched_requirement_ids, 0..) |match, match_idx| {
            if (match_idx != 0) try writer.writeAll(", ");
            try printJsonString(writer, match.id);
        }
        try writer.writeAll("],\n    \"provenance\": {\n");
        try writer.writeAll("      \"storage_name\": ");
        try printJsonString(writer, rec.provenance.storage_name);
        try writer.writeAll(",\n      \"stream_name\": ");
        try printJsonString(writer, rec.provenance.stream_name);
        try writer.print(",\n      \"record_index\": {},\n", .{rec.provenance.record_index});
        try writer.print("      \"extraction_method\": \"{s}\"\n", .{@tagName(rec.provenance.extraction_method)});
        try writer.writeAll("    }\n  }");
    }
    try writer.writeAll("\n]\n");
}

fn printSummaryJson(summaries: []const cad.eval.EvaluationSummary, writer: anytype) !void {
    var total_records: usize = 0;
    var useful_records: usize = 0;
    try writer.writeAll("{\n  \"files\": [\n");
    for (summaries, 0..) |summary, idx| {
        total_records += summary.total_records;
        useful_records += summary.useful_records;
        if (idx != 0) try writer.writeAll(",\n");
        try writer.writeAll("    {\n");
        try writer.writeAll("      \"fixture_path\": ");
        try printJsonString(writer, summary.fixture_path);
        try writer.print(",\n      \"artifact_kind\": \"{s}\",\n", .{@tagName(summary.artifact_kind)});
        try writer.print("      \"total_records\": {},\n", .{summary.total_records});
        try writer.print("      \"useful_records\": {},\n", .{summary.useful_records});
        try writer.print("      \"unknown_records\": {},\n", .{summary.unknown_records});

        try writer.writeAll("      \"by_scope\": [");
        for (summary.by_scope, 0..) |scope, scope_idx| {
            if (scope_idx != 0) try writer.writeAll(", ");
            try writer.print("{{\"scope_kind\":\"{s}\",\"count\":{}}}", .{ @tagName(scope.scope_kind), scope.count });
        }
        try writer.writeAll("],\n");

        try writer.writeAll("      \"by_usefulness\": [");
        for (summary.by_usefulness, 0..) |item, item_idx| {
            if (item_idx != 0) try writer.writeAll(", ");
            try writer.print("{{\"class\":\"{s}\",\"count\":{}}}", .{ @tagName(item.class), item.count });
        }
        try writer.writeAll("],\n");

        try writer.writeAll("      \"missing_expected\": [");
        for (summary.missing_expected, 0..) |item, item_idx| {
            if (item_idx != 0) try writer.writeAll(", ");
            try printJsonString(writer, item);
        }
        try writer.writeAll("],\n");

        try writer.writeAll("      \"unexpected_reportable\": [");
        for (summary.unexpected_reportable, 0..) |item, item_idx| {
            if (item_idx != 0) try writer.writeAll(", ");
            try printJsonString(writer, item);
        }
        try writer.writeAll("]\n");
        try writer.writeAll("    }");
    }
    try writer.print("\n  ],\n  \"totals\": {{\n    \"files\": {},\n    \"total_records\": {},\n    \"useful_records\": {}\n  }}\n}}\n", .{ summaries.len, total_records, useful_records });
}

fn printSummaryMarkdown(summaries: []const cad.eval.EvaluationSummary, writer: anytype) !void {
    try writer.writeAll("# libcadcruncher evaluation\n\n");
    for (summaries) |summary| {
        try writer.print("## {s}\n- artifact_kind: `{s}`\n- total_records: `{}`\n- useful_records: `{}`\n- unknown_records: `{}`\n", .{
            summary.fixture_path,
            @tagName(summary.artifact_kind),
            summary.total_records,
            summary.useful_records,
            summary.unknown_records,
        });
        try writer.writeAll("- by_scope:\n");
        for (summary.by_scope) |scope| {
            try writer.print("  - `{s}`: `{}`\n", .{ @tagName(scope.scope_kind), scope.count });
        }
        try writer.writeAll("- by_usefulness:\n");
        for (summary.by_usefulness) |item| {
            try writer.print("  - `{s}`: `{}`\n", .{ @tagName(item.class), item.count });
        }
        if (summary.missing_expected.len != 0) {
            try writer.writeAll("- missing_expected:\n");
            for (summary.missing_expected) |item| {
                try writer.print("  - `{s}`\n", .{item});
            }
        }
        if (summary.unexpected_reportable.len != 0) {
            try writer.writeAll("- unexpected_reportable:\n");
            for (summary.unexpected_reportable) |item| {
                try writer.print("  - `{s}`\n", .{item});
            }
        }
        try writer.writeByte('\n');
    }
}

fn collectCadFiles(root_path: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (files.items) |file_path| allocator.free(file_path);
        files.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        if (!std.ascii.eqlIgnoreCase(ext, ".PcbDoc") and !std.ascii.eqlIgnoreCase(ext, ".SchDoc")) continue;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ root_path, entry.path }));
    }
    return try files.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();

    const cmd = args.next() orelse {
        usage();
        return error.InvalidArguments;
    };
    const path = args.next() orelse {
        usage();
        return error.InvalidArguments;
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (std.mem.eql(u8, cmd, "detect")) {
        const det = try cad.detect.detectFile(path, alloc);
        try stdout.print("kind: {s}\nis_cfb: {}\npath: {s}\n", .{ @tagName(det.kind), det.is_cfb, det.path });
        return;
    }

    if (std.mem.eql(u8, cmd, "streams")) {
        var compound = try cad.cfb.open(path, alloc);
        defer compound.deinit(alloc);
        const streams = try compound.listStreams(alloc);
        defer {
            for (streams) |s| alloc.free(s.name);
            alloc.free(streams);
        }
        for (streams) |s| {
            try stdout.print("{d: >4}  {d: >8}  {s}\n", .{ s.entry_id, s.size_bytes, s.name });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "dump-stream")) {
        const flag = args.next() orelse return error.InvalidArguments;
        if (!std.mem.eql(u8, flag, "--stream")) return error.InvalidArguments;
        const stream_name = args.next() orelse return error.InvalidArguments;
        var compound = try cad.cfb.open(path, alloc);
        defer compound.deinit(alloc);
        const data = (try compound.readStreamByName(stream_name, alloc)) orelse return error.StreamNotFound;
        defer alloc.free(data);
        for (data) |b| {
            if (b >= 32 and b <= 126) {
                try stdout.writeByte(b);
            } else if (b == '\n' or b == '\r' or b == '\t') {
                try stdout.writeByte(b);
            } else {
                try stdout.writeByte('.');
            }
        }
        try stdout.writeByte('\n');
        return;
    }

    if (std.mem.eql(u8, cmd, "extract")) {
        var known_ids: std.ArrayList([]const u8) = .empty;
        defer known_ids.deinit(alloc);
        while (args.next()) |arg| {
            if (!std.mem.eql(u8, arg, "--known-id")) return error.InvalidArguments;
            const id = args.next() orelse return error.InvalidArguments;
            try known_ids.append(alloc, id);
        }
        const records = try cad.altium.extractAuto(path, .{
            .known_ids = if (known_ids.items.len == 0) null else known_ids.items,
        }, alloc);
        defer cad.altium.freeRecords(records, alloc);
        try printEvidenceJson(records, stdout);
        return;
    }

    if (std.mem.eql(u8, cmd, "evaluate")) {
        var markdown = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--markdown")) {
                markdown = true;
            } else {
                return error.InvalidArguments;
            }
        }

        const target_is_dir = blk: {
            if (std.fs.cwd().openDir(path, .{ .iterate = true })) |opened_dir| {
                var dir = opened_dir;
                dir.close();
                break :blk true;
            } else |_| break :blk false;
        };

        var summaries: std.ArrayList(cad.eval.EvaluationSummary) = .empty;
        defer {
            for (summaries.items) |summary| cad.eval.freeEvaluationSummary(summary, alloc);
            summaries.deinit(alloc);
        }

        if (target_is_dir) {
            const cad_files = try collectCadFiles(path, alloc);
            defer {
                for (cad_files) |file_path| alloc.free(file_path);
                alloc.free(cad_files);
            }
            for (cad_files) |file_path| {
                const det = try cad.detect.detectFile(file_path, alloc);
                const records = try cad.altium.extractAuto(file_path, .{}, alloc);
                defer cad.altium.freeRecords(records, alloc);
                try summaries.append(alloc, try cad.eval.evaluateExtracted(file_path, det.kind, records, alloc));
            }
        } else {
            const det = try cad.detect.detectFile(path, alloc);
            const records = try cad.altium.extractAuto(path, .{}, alloc);
            defer cad.altium.freeRecords(records, alloc);
            try summaries.append(alloc, try cad.eval.evaluateExtracted(path, det.kind, records, alloc));
        }

        if (markdown) {
            try printSummaryMarkdown(summaries.items, stdout);
        } else {
            try printSummaryJson(summaries.items, stdout);
        }
        return;
    }

    usage();
    return error.InvalidArguments;
}
