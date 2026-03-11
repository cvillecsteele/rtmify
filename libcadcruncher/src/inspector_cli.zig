const std = @import("std");
const cad = @import("lib.zig");

fn usage() void {
    std.debug.print(
        \\usage:
        \\  rtmify-cadinspect detect <file>
        \\  rtmify-cadinspect streams <file>
        \\  rtmify-cadinspect extract <file> [--known-id REQ-001 ...]
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
        defer {
            for (records) |rec| {
                alloc.free(rec.source_path);
                if (rec.scope_identifier) |v| alloc.free(v);
                if (rec.display_name) |v| alloc.free(v);
                for (rec.properties) |prop| {
                    alloc.free(prop.key);
                    alloc.free(prop.value);
                }
                alloc.free(rec.properties);
                for (rec.matched_requirement_ids) |match| {
                    alloc.free(match.id);
                    alloc.free(match.source_property);
                    alloc.free(match.matched_from_value);
                }
                alloc.free(rec.matched_requirement_ids);
                alloc.free(rec.provenance.storage_name);
                alloc.free(rec.provenance.stream_name);
            }
            alloc.free(records);
        }
        try printEvidenceJson(records, stdout);
        return;
    }

    usage();
    return error.InvalidArguments;
}
