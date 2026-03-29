const std = @import("std");
const llm = @import("llm");
const traveler = @import("traveler");

const help_text =
    \\traveler — traveler extraction spike CLI
    \\
    \\Usage:
    \\  traveler extract --model <path> --mmproj <path> --image <path> [--format json|pretty] [--ctx-size <n>] [--threads <n>] [--seed <n>] [--show-raw]
    \\  traveler eval --model <path> --mmproj <path> [--manifest <path>] [--out <path>] [--format json|markdown] [--ctx-size <n>] [--threads <n>] [--seed <n>]
    \\  traveler --help
    \\
;

const Command = enum { extract, eval };

const CaseExpectation = struct {
    required_fields: RequiredFields,
    normalized: struct {
        product_full_identifier: ?[]const u8 = null,
    } = .{},
    notes: ?[]const u8 = null,
    acceptable_status: []const u8,
};

const RequiredFields = struct {
    product_name: ?[]const u8 = null,
    assembly: ?[]const u8 = null,
    serial_number: ?[]const u8 = null,
    bom_revision: ?[]const u8 = null,
    atp_test_report_id: ?[]const u8 = null,
};

const CaseFile = struct {
    id: []const u8,
    image: []const u8,
    messiness_tags: ?[]const []const u8 = null,
    expected: CaseExpectation,
};

const CorpusManifest = struct {
    cases: []const []const u8,
};

const ReasonCount = struct {
    reason: traveler.RejectionReason,
    count: usize,
};

const CliOptions = struct {
    command: Command,
    model: []const u8,
    mmproj: []const u8,
    image: ?[]const u8 = null,
    format: []const u8 = "json",
    show_raw: bool = false,
    manifest: []const u8 = "test/fixtures/traveler/corpus.json",
    out: ?[]const u8 = null,
    ctx_size: u32 = 8192,
    threads: u16 = 0,
    seed: ?u32 = null,
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const opts = parseArgs(args) catch |err| {
        try std.fs.File.stderr().writeAll(help_text);
        return err;
    };

    const provider = try llm.llama_mtmd_provider.init(alloc, .{
        .model_path = opts.model,
        .mmproj_path = opts.mmproj,
        .ctx_size = opts.ctx_size,
        .threads = opts.threads,
        .seed = opts.seed,
    });
    var extractor = traveler.Extractor.initWithProvider(provider, true);
    defer extractor.deinit(alloc);

    switch (opts.command) {
        .extract => try runExtract(alloc, &extractor, opts),
        .eval => try runEval(alloc, &extractor, opts),
    }
}

fn parseArgs(args: []const []const u8) !CliOptions {
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try std.fs.File.stdout().writeAll(help_text);
        std.process.exit(0);
    }

    var opts = CliOptions{
        .command = std.meta.stringToEnum(Command, args[1]) orelse return error.InvalidCommand,
        .model = "",
        .mmproj = "",
    };

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--model") and i + 1 < args.len) {
            i += 1;
            opts.model = args[i];
        } else if (std.mem.eql(u8, arg, "--mmproj") and i + 1 < args.len) {
            i += 1;
            opts.mmproj = args[i];
        } else if (std.mem.eql(u8, arg, "--image") and i + 1 < args.len) {
            i += 1;
            opts.image = args[i];
        } else if (std.mem.eql(u8, arg, "--format") and i + 1 < args.len) {
            i += 1;
            opts.format = args[i];
        } else if (std.mem.eql(u8, arg, "--show-raw")) {
            opts.show_raw = true;
        } else if (std.mem.eql(u8, arg, "--manifest") and i + 1 < args.len) {
            i += 1;
            opts.manifest = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            opts.out = args[i];
        } else if (std.mem.eql(u8, arg, "--ctx-size") and i + 1 < args.len) {
            i += 1;
            opts.ctx_size = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--threads") and i + 1 < args.len) {
            i += 1;
            opts.threads = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--seed") and i + 1 < args.len) {
            i += 1;
            opts.seed = try std.fmt.parseInt(u32, args[i], 10);
        } else {
            return error.InvalidArgument;
        }
    }

    if (opts.model.len == 0 or opts.mmproj.len == 0) return error.MissingModelPaths;
    if (opts.command == .extract and opts.image == null) return error.MissingImagePath;
    return opts;
}

fn runExtract(alloc: std.mem.Allocator, extractor: *traveler.Extractor, opts: CliOptions) !void {
    var result = try extractor.extractImage(alloc, opts.image.?);
    defer result.deinit(alloc);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    if (std.mem.eql(u8, opts.format, "pretty")) {
        try writeTravelerPretty(output.writer(alloc), result, opts.show_raw);
    } else {
        try writeTravelerJson(output.writer(alloc), result, opts.show_raw);
        try output.append(alloc, '\n');
    }

    try std.fs.File.stdout().writeAll(output.items);
}

fn runEval(alloc: std.mem.Allocator, extractor: *traveler.Extractor, opts: CliOptions) !void {
    const manifest_bytes = try std.fs.cwd().readFileAlloc(alloc, opts.manifest, 1 << 20);
    defer alloc.free(manifest_bytes);
    const manifest = try std.json.parseFromSlice(CorpusManifest, alloc, manifest_bytes, .{});
    defer manifest.deinit();

    var cases_out: std.ArrayList([]u8) = .empty;
    defer {
        for (cases_out.items) |item| alloc.free(item);
        cases_out.deinit(alloc);
    }

    var total: usize = 0;
    var accepted: usize = 0;
    var normalization_gaps: usize = 0;
    var reason_counts = std.EnumArray(traveler.RejectionReason, usize).initFill(0);

    for (manifest.value.cases) |case_path| {
        const case_bytes = try std.fs.cwd().readFileAlloc(alloc, case_path, 1 << 20);
        defer alloc.free(case_bytes);
        const case_parsed = try std.json.parseFromSlice(CaseFile, alloc, case_bytes, .{});
        defer case_parsed.deinit();

        total += 1;
        var result = try extractor.extractImage(alloc, case_parsed.value.image);
        defer result.deinit(alloc);
        reason_counts.set(
            result.validation.rejection_reason,
            reason_counts.get(result.validation.rejection_reason) + 1,
        );

        const fields_ok = matchesRequired(case_parsed.value.expected.required_fields, result);
        const full_id_ok = std.meta.eql(case_parsed.value.expected.normalized.product_full_identifier, result.normalized.product_full_identifier);
        const acceptable = if (std.mem.eql(u8, case_parsed.value.expected.acceptable_status, "normalization_gap"))
            fields_ok
        else
            fields_ok and full_id_ok and result.validation.status == .accepted;

        if (acceptable and result.validation.status == .accepted) accepted += 1;
        if (acceptable and !full_id_ok and fields_ok) normalization_gaps += 1;

        const line = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"acceptable\":{s},\"status\":\"{s}\",\"reason\":\"{s}\",\"fields_ok\":{s},\"full_identifier_ok\":{s}}}", .{
            case_parsed.value.id,
            if (acceptable) "true" else "false",
            @tagName(result.validation.status),
            @tagName(result.validation.rejection_reason),
            if (fields_ok) "true" else "false",
            if (full_id_ok) "true" else "false",
        });
        try cases_out.append(alloc, line);
    }

    var compact_reason_counts: std.ArrayList(ReasonCount) = .empty;
    defer compact_reason_counts.deinit(alloc);
    for (std.enums.values(traveler.RejectionReason)) |reason| {
        const count = reason_counts.get(reason);
        if (count == 0) continue;
        try compact_reason_counts.append(alloc, .{
            .reason = reason,
            .count = count,
        });
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    if (std.mem.eql(u8, opts.format, "markdown")) {
        try output.writer(alloc).print(
            "# Traveler Eval\n\n- Cases: {d}\n- Accepted: {d}\n- Normalization gaps: {d}\n\n## Rejection Reasons\n",
            .{ total, accepted, normalization_gaps },
        );
        for (compact_reason_counts.items) |entry| {
            try output.writer(alloc).print("- `{s}`: {d}\n", .{ @tagName(entry.reason), entry.count });
        }
        try output.appendSlice(alloc, "\n## Cases\n");
        for (cases_out.items) |line| {
            try output.writer(alloc).print("- `{s}`\n", .{line});
        }
    } else {
        try output.writer(alloc).print(
            "{{\"cases_total\":{d},\"accepted\":{d},\"normalization_gaps\":{d},\"rejection_reasons\":{{",
            .{ total, accepted, normalization_gaps },
        );
        for (compact_reason_counts.items, 0..) |entry, idx| {
            if (idx != 0) try output.append(alloc, ',');
            try output.writer(alloc).print("\"{s}\":{d}", .{ @tagName(entry.reason), entry.count });
        }
        try output.appendSlice(alloc, "},\"cases\":[");
        for (cases_out.items, 0..) |line, idx| {
            if (idx != 0) try output.append(alloc, ',');
            try output.appendSlice(alloc, line);
        }
        try output.appendSlice(alloc, "]}\n");
    }

    if (opts.out) |path| {
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = output.items });
    } else {
        try std.fs.File.stdout().writeAll(output.items);
    }
}

fn matchesRequired(expected: RequiredFields, result: traveler.TravelerResult) bool {
    return eqOpt(expected.product_name, result.header.product_name) and
        eqOpt(expected.assembly, result.header.assembly) and
        eqOpt(expected.serial_number, result.header.serial_number) and
        eqOpt(expected.bom_revision, result.header.bom_revision) and
        eqOpt(expected.atp_test_report_id, result.verification.atp_test_report_id);
}

fn eqOpt(expected: ?[]const u8, actual: ?[]const u8) bool {
    if (expected == null and actual == null) return true;
    if (expected == null or actual == null) return false;
    return std.mem.eql(u8, expected.?, actual.?);
}

fn writeTravelerPretty(writer: anytype, result: traveler.TravelerResult, show_raw: bool) !void {
    try writer.print("status: {s}\nreason: {s}\n", .{ @tagName(result.validation.status), @tagName(result.validation.rejection_reason) });
    try writer.print("product_name: {s}\n", .{result.header.product_name orelse "null"});
    try writer.print("assembly: {s}\n", .{result.header.assembly orelse "null"});
    try writer.print("serial_number: {s}\n", .{result.header.serial_number orelse "null"});
    try writer.print("bom_revision: {s}\n", .{result.header.bom_revision orelse "null"});
    try writer.print("atp_test_report_id: {s}\n", .{result.verification.atp_test_report_id orelse "null"});
    try writer.print("product_full_identifier: {s}\n", .{result.normalized.product_full_identifier orelse "null"});
    if (show_raw) {
        try writer.print("\nraw_response:\n{s}\n", .{result.raw_response_text});
    }
}

fn writeTravelerJson(writer: anytype, result: traveler.TravelerResult, show_raw: bool) !void {
    try writer.writeAll("{");
    try writer.print("\"status\":\"{s}\",\"rejection_reason\":\"{s}\",", .{ @tagName(result.validation.status), @tagName(result.validation.rejection_reason) });
    try writer.writeAll("\"header\":{");
    try writeJsonField(writer, "product_name", result.header.product_name, true);
    try writeJsonField(writer, "assembly", result.header.assembly, false);
    try writeJsonField(writer, "serial_number", result.header.serial_number, false);
    try writeJsonField(writer, "bom_revision", result.header.bom_revision, false);
    try writer.writeAll("},\"verification\":{");
    try writeJsonField(writer, "atp_test_report_id", result.verification.atp_test_report_id, true);
    try writeJsonField(writer, "final_disposition", result.verification.final_disposition, false);
    try writeJsonField(writer, "rework_ncr_number", result.verification.rework_ncr_number, false);
    try writer.writeAll("},\"normalized\":{");
    try writeJsonField(writer, "product_full_identifier", result.normalized.product_full_identifier, true);
    try writer.writeAll("}");
    if (show_raw) {
        try writer.writeAll(",\"raw_response_text\":");
        try writeJsonEscapedString(writer, result.raw_response_text);
    }
    try writer.writeAll("}");
}

fn writeJsonField(writer: anytype, key: []const u8, value: ?[]const u8, first: bool) !void {
    if (!first) try writer.writeAll(",");
    try writer.print("\"{s}\":", .{key});
    if (value) |item| {
        try writeJsonEscapedString(writer, item);
    } else {
        try writer.writeAll("null");
    }
}

fn writeJsonEscapedString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{X:0>4}", .{@as(u8, ch)}),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}
