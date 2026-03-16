const std = @import("std");
const rtmify = @import("rtmify");
const graph = rtmify.graph;
const xlsx = rtmify.xlsx;
const schema = rtmify.schema;
const render_md = rtmify.render_md;
const render_docx = rtmify.render_docx;
const render_pdf = rtmify.render_pdf;
const license = rtmify.license;
const diagnostic = rtmify.diagnostic;
const profile_mod = rtmify.profile;
const report_mod = rtmify.report;
const analysis = rtmify.analysis;
const Diagnostics = diagnostic.Diagnostics;

const VERSION = @import("build_options").version;

// ---------------------------------------------------------------------------
// Exit codes
// ---------------------------------------------------------------------------

const EXIT_SUCCESS: u8 = 0;
const EXIT_INPUT: u8 = 1;
const EXIT_LICENSE_REQUIRED: u8 = 2;
const EXIT_LICENSE_EXPIRED: u8 = 3;
const EXIT_LICENSE_INVALID: u8 = 4;
const EXIT_OUTPUT: u8 = 5;

// ---------------------------------------------------------------------------
// Argument types
// ---------------------------------------------------------------------------

pub const Format = enum { md, docx, pdf, all };

pub const Args = struct {
    input: ?[]const u8 = null,
    format: Format = .docx,
    output: ?[]const u8 = null,
    project: ?[]const u8 = null,
    license_path: ?[]const u8 = null,
    license_cmd: ?LicenseCommand = null,
    license_cmd_path: ?[]const u8 = null,
    json: bool = false,
    strict: bool = false,
    version: bool = false,
    help: bool = false,
    gaps_json: ?[]const u8 = null,
    profile: profile_mod.ProfileId = .generic,
};

pub const LicenseCommand = enum {
    info,
    install,
    clear,
};

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    InvalidFormat,
    InvalidProfile,
    ConflictingOptions,
};

/// Parse a flat slice of argument strings (not including argv[0]).
/// Returns a populated Args or a ParseError.
pub fn parseArgs(tokens: []const []const u8) ParseError!Args {
    var args = Args{};
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];
        if (std.mem.eql(u8, tok, "--help") or std.mem.eql(u8, tok, "-h")) {
            args.help = true;
        } else if (std.mem.eql(u8, tok, "--version")) {
            args.version = true;
        } else if (std.mem.eql(u8, tok, "--json")) {
            args.json = true;
        } else if (std.mem.eql(u8, tok, "--strict")) {
            args.strict = true;
        } else if (std.mem.eql(u8, tok, "--license")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.license_path = tokens[i];
        } else if (std.mem.eql(u8, tok, "license")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.license_cmd = std.meta.stringToEnum(LicenseCommand, tokens[i]) orelse return error.UnknownFlag;
            if (args.license_cmd == .install) {
                i += 1;
                if (i >= tokens.len) return error.MissingValue;
                args.license_cmd_path = tokens[i];
            }
        } else if (std.mem.eql(u8, tok, "--format")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            const f = tokens[i];
            if (std.mem.eql(u8, f, "md")) {
                args.format = .md;
            } else if (std.mem.eql(u8, f, "docx")) {
                args.format = .docx;
            } else if (std.mem.eql(u8, f, "all")) {
                args.format = .all;
            } else if (std.mem.eql(u8, f, "pdf")) {
                args.format = .pdf;
            } else {
                return error.InvalidFormat;
            }
        } else if (std.mem.eql(u8, tok, "--output")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.output = tokens[i];
        } else if (std.mem.eql(u8, tok, "--gaps-json")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.gaps_json = tokens[i];
        } else if (std.mem.eql(u8, tok, "--profile")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.profile = profile_mod.fromString(tokens[i]) orelse return error.InvalidProfile;
        } else if (std.mem.eql(u8, tok, "--project")) {
            i += 1;
            if (i >= tokens.len) return error.MissingValue;
            args.project = tokens[i];
        } else if (std.mem.startsWith(u8, tok, "--")) {
            return error.UnknownFlag;
        } else {
            // Positional: input file
            if (args.input != null) return error.ConflictingOptions;
            args.input = tok;
        }
    }
    return args;
}

// ---------------------------------------------------------------------------
// Help / version text
// ---------------------------------------------------------------------------

const HELP =
    \\rtmify-trace <input.xlsx> [options]
    \\
    \\Generate a Requirements Traceability Matrix from an RTMify spreadsheet.
    \\
    \\Options:
    \\  --format <md|docx|pdf|all>  Output format (default: docx)
    \\  --output <path>          Output file or directory (default: same dir as input)
    \\  --project <name>         Project name for report header (default: filename)
    \\  --gaps-json <path>       Write diagnostics + gap analysis JSON to path
    \\  --profile <name>         Validation profile: medical, aerospace, automotive, generic
    \\  --license <path>         Use a specific signed license file for this run
    \\  license info [--json]    Show installed license details
    \\  license install <path>   Install a signed license file
    \\  license clear            Remove the installed license file
    \\  --strict                 Exit with gap count when gaps are found (for CI)
    \\  --version                Print version and exit
    \\  --help                   Print this help and exit
    \\
    \\Examples:
    \\  rtmify-trace requirements.xlsx
    \\  rtmify-trace requirements.xlsx --format all --output ./reports/
    \\  rtmify-trace requirements.xlsx --format md --project "Ventilator v2.1"
    \\  rtmify-trace requirements.xlsx --gaps-json gaps.json
    \\  rtmify-trace requirements.xlsx --profile medical --format pdf
    \\  rtmify-trace license install ./license.json
    \\
    \\Exit codes:
    \\  0   success
    \\  1   input file error
    \\  2   license required / trial exhausted
    \\  3   license expired
    \\  4   invalid/tampered/wrong-product license
    \\  5   output error
    \\  N   gap count (with --strict)
    \\
;

fn printVersion(w: anytype) !void {
    const target = @import("builtin").target;
    const cpu_arch = @tagName(target.cpu.arch);
    const os_tag = @tagName(target.os.tag);
    try w.print("rtmify-trace {s} {s}-{s} (zig {s})\n", .{
        VERSION, cpu_arch, os_tag, @import("builtin").zig_version_string,
    });
}

// ---------------------------------------------------------------------------
// Output path resolution
// ---------------------------------------------------------------------------

/// Return the stem of a filename (basename without last extension).
pub fn stem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    if (ext.len == 0) return base;
    return base[0 .. base.len - ext.len];
}

/// Build the output file path for a given format extension ("md" or "docx").
/// Caller owns the returned slice.
fn outputPath(
    gpa: std.mem.Allocator,
    input_path: []const u8,
    fmt_ext: []const u8,
    output_opt: ?[]const u8,
) ![]u8 {
    const filename = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ stem(input_path), fmt_ext });
    defer gpa.free(filename);

    if (output_opt) |out| {
        // If output ends with a path separator, treat as directory
        const last = out[out.len - 1];
        if (last == '/' or last == std.fs.path.sep) {
            return std.fs.path.join(gpa, &.{ out, filename });
        }
        // Otherwise treat as a literal file path
        return gpa.dupe(u8, out);
    }

    // Default: same directory as input
    const dir = std.fs.path.dirname(input_path) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, filename });
}

// ---------------------------------------------------------------------------
// Gap counting
// ---------------------------------------------------------------------------

fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

fn writeGapsJson(path: []const u8, ctx: report_mod.ReportContext, diag: *const Diagnostics, gpa: std.mem.Allocator) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const w = out.writer(gpa);

    try w.writeAll("{\"profile\":\"");
    try w.writeAll(profile_mod.get(ctx.profile).short_name);
    try w.writeAll("\",\"diagnostics\":[");
    for (diag.entries.items, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"level\":\"{s}\"", .{@tagName(e.level)});
        try w.print(",\"code\":{d}", .{e.code});
        try w.print(",\"url\":\"{s}E{d}\"", .{ diagnostic.error_url_base, e.code });
        try w.print(",\"source\":\"{s}\"", .{@tagName(e.source)});
        if (e.tab) |t| {
            try w.writeAll(",\"tab\":\"");
            try writeJsonString(w, t);
            try w.writeByte('"');
        } else {
            try w.writeAll(",\"tab\":null");
        }
        if (e.row) |r| {
            try w.print(",\"row\":{d}", .{r});
        } else {
            try w.writeAll(",\"row\":null");
        }
        try w.writeAll(",\"message\":\"");
        try writeJsonString(w, e.message);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"gaps\":[");
    for (ctx.merged_gaps, 0..) |gap, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{");
        try w.print("\"severity\":\"{s}\"", .{gap.severity.toString()});
        if (gap.code) |code| {
            try w.print(",\"code\":{d}", .{code});
        } else {
            try w.writeAll(",\"code\":null");
        }
        try w.print(",\"kind\":\"{s}\"", .{gap.kind});
        try w.writeAll(",\"primary_id\":\"");
        try writeJsonString(w, gap.primary_id);
        try w.writeByte('"');
        try w.writeAll(",\"node_id\":\"");
        try writeJsonString(w, gap.primary_id);
        try w.writeByte('"');
        if (gap.related_id) |related| {
            try w.writeAll(",\"related_id\":\"");
            try writeJsonString(w, related);
            try w.writeByte('"');
        } else {
            try w.writeAll(",\"related_id\":null");
        }
        if (gap.profile_rule) |profile_rule| {
            try w.writeAll(",\"profile_rule\":\"");
            try writeJsonString(w, profile_rule);
            try w.writeByte('"');
        } else {
            try w.writeAll(",\"profile_rule\":null");
        }
        if (gap.clause) |clause| {
            try w.writeAll(",\"clause\":\"");
            try writeJsonString(w, clause);
            try w.writeByte('"');
        } else {
            try w.writeAll(",\"clause\":null");
        }
        try w.writeAll(",\"message\":\"");
        try writeJsonString(w, gap.message);
        try w.writeByte('"');
        try w.writeByte('}');
    }
    try w.print("],\"gap_count\":{d},\"warning_count\":{d},\"error_count\":{d}}}", .{
        report_mod.hardGapCount(ctx.merged_gaps),
        diag.warning_count,
        diag.error_count,
    });

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

// ---------------------------------------------------------------------------
// Timestamp
// ---------------------------------------------------------------------------

pub fn isoTimestamp(buf: *[20]u8) []u8 {
    const ts = std.time.timestamp();
    const secs_per_min = 60;
    const secs_per_hour = 3600;
    const secs_per_day = 86400;

    var remaining: u64 = @intCast(@max(ts, 0));
    const days = remaining / secs_per_day;
    remaining -= days * secs_per_day;
    const hour = remaining / secs_per_hour;
    remaining -= hour * secs_per_hour;
    const minute = remaining / secs_per_min;
    const second = remaining - minute * secs_per_min;

    // Gregorian date from day count (days since 1970-01-01)
    const z = days + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const yr = if (m <= 2) y + 1 else y;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yr, m, d, hour, minute, second,
    }) catch buf[0..20];
}

// ---------------------------------------------------------------------------
// Generate a single report file
// ---------------------------------------------------------------------------

fn generateReport(
    gpa: std.mem.Allocator,
    g: *const graph.Graph,
    ctx: report_mod.ReportContext,
    fmt: Format,
    input_path: []const u8,
    project_name: []const u8,
    timestamp: []const u8,
    output_opt: ?[]const u8,
) !void {
    switch (fmt) {
        .md => {
            const path = try outputPath(gpa, input_path, "md", output_opt);
            defer gpa.free(path);
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Error: cannot write to {s}: {s}\n", .{ path, @errorName(err) });
                return error.OutputError;
            };
            defer file.close();
            const dw = file.deprecatedWriter();
            try render_md.renderMdWithContext(g, ctx, project_name, timestamp, dw);
            std.debug.print("  → {s}\n", .{path});
        },
        .docx => {
            const path = try outputPath(gpa, input_path, "docx", output_opt);
            defer gpa.free(path);
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Error: cannot write to {s}: {s}\n", .{ path, @errorName(err) });
                return error.OutputError;
            };
            defer file.close();
            const dw = file.deprecatedWriter();
            try render_docx.renderDocxWithContext(g, ctx, project_name, timestamp, dw);
            std.debug.print("  → {s}\n", .{path});
        },
        .pdf => {
            const path = try outputPath(gpa, input_path, "pdf", output_opt);
            defer gpa.free(path);
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Error: cannot write to {s}: {s}\n", .{ path, @errorName(err) });
                return error.OutputError;
            };
            defer file.close();
            const dw = file.deprecatedWriter();
            try render_pdf.renderPdfWithContext(g, ctx, project_name, timestamp, dw);
            std.debug.print("  → {s}\n", .{path});
        },
        .all => {
            try generateReport(gpa, g, ctx, .md, input_path, project_name, timestamp, output_opt);
            try generateReport(gpa, g, ctx, .docx, input_path, project_name, timestamp, output_opt);
            try generateReport(gpa, g, ctx, .pdf, input_path, project_name, timestamp, output_opt);
        },
    }
}

// ---------------------------------------------------------------------------
// Main run logic (returns exit code)
// ---------------------------------------------------------------------------

fn run(gpa: std.mem.Allocator, args: Args) !u8 {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();
    var license_service = try license.initDefaultHmacFile(gpa, .{
        .product = .trace,
        .trial_policy = .single_free_run,
        .license_path_override = args.license_path,
    });
    defer license_service.deinit(gpa);

    if (args.help) {
        try stdout.writeAll(HELP);
        return EXIT_SUCCESS;
    }

    if (args.version) {
        try printVersion(stdout);
        return EXIT_SUCCESS;
    }

    if (args.license_cmd) |cmd| {
        switch (cmd) {
            .info => {
                var info = license_service.getInfo(gpa) catch |err| {
                    try stderr.print("Error: {s}\n", .{@errorName(err)});
                    return EXIT_LICENSE_INVALID;
                };
                defer info.deinit(gpa);
                if (args.json) {
                    var buf: std.ArrayList(u8) = .empty;
                    defer buf.deinit(gpa);
                    const w = buf.writer(gpa);
                    try w.writeAll("{\"license_path\":");
                    try license.license_file.writeJsonString(w, info.license_path);
                    try w.writeAll(",\"expected_key_fingerprint\":");
                    try license.license_file.writeJsonString(w, info.expected_key_fingerprint);
                    try w.writeAll(",\"license_signing_key_fingerprint\":");
                    if (info.license_signing_key_fingerprint) |value| {
                        try license.license_file.writeJsonString(w, value);
                    } else {
                        try w.writeAll("null");
                    }
                    try w.writeAll(",\"payload\":");
                    try license.license_file.writePayloadJson(w, info.payload);
                    try w.writeAll("}\n");
                    try stdout.writeAll(buf.items);
                } else {
                    try stdout.print("License ID: {s}\nProduct: {s}\nTier: {s}\nIssued To: {s}\n", .{
                        info.payload.license_id,
                        @tagName(info.payload.product),
                        @tagName(info.payload.tier),
                        info.payload.issued_to,
                    });
                    if (info.payload.org) |org| try stdout.print("Org: {s}\n", .{org});
                    if (info.payload.expires_at) |expires_at| {
                        try stdout.print("Expires At: {d}\n", .{expires_at});
                    } else {
                        try stdout.writeAll("Expires At: perpetual\n");
                    }
                    try stdout.print("Expected Key: {s}\n", .{license.displayFingerprint(info.expected_key_fingerprint)});
                    if (info.license_signing_key_fingerprint) |value| {
                        try stdout.print("File Key: {s}\n", .{license.displayFingerprint(value)});
                    }
                    try stdout.print("Path: {s}\n", .{info.license_path});
                }
                return EXIT_SUCCESS;
            },
            .install => {
                const install_path = args.license_cmd_path orelse return EXIT_INPUT;
                var status = try license_service.installFromPath(gpa, install_path);
                defer status.deinit(gpa);
                if (!status.permits_use) {
                    try stderr.print("Error: {s}\n", .{status.message orelse "license install failed"});
                    return switch (status.state) {
                        .expired => EXIT_LICENSE_EXPIRED,
                        .invalid, .tampered => EXIT_LICENSE_INVALID,
                        else => EXIT_LICENSE_REQUIRED,
                    };
                }
                try stdout.writeAll("License installed successfully.\n");
                return EXIT_SUCCESS;
            },
            .clear => {
                var status = try license_service.clearInstalledLicense(gpa);
                defer status.deinit(gpa);
                try stdout.writeAll("Installed license cleared.\n");
                return EXIT_SUCCESS;
            },
        }
    }

    // License gate
    var lic_status = try license_service.getStatus(gpa);
    defer lic_status.deinit(gpa);
    switch (lic_status.state) {
        .valid => {},
        .not_licensed => {
            try stderr.print("Error: {s}\n", .{lic_status.message orelse "license is required"});
            try stderr.writeAll("Install a signed license file with: rtmify-trace license install <path>\n");
            return EXIT_LICENSE_REQUIRED;
        },
        .expired => {
            try stderr.print("Error: {s}\n", .{lic_status.message orelse "license expired"});
            return EXIT_LICENSE_EXPIRED;
        },
        .invalid, .tampered => {
            try stderr.print("Error: {s}\n", .{lic_status.message orelse "license check failed"});
            return EXIT_LICENSE_INVALID;
        },
    }

    const input_path = args.input orelse {
        try stderr.writeAll("Error: no input file specified.\n");
        try stderr.writeAll("Run: rtmify-trace --help\n");
        return EXIT_INPUT;
    };

    // Parse XLSX
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var diag = Diagnostics.init(gpa);
    defer diag.deinit();

    const sheets = xlsx.parseValidated(alloc, input_path, &diag) catch |err| {
        try diag.printSummary(stderr);
        switch (err) {
            error.FileNotFound => {
                try stderr.print("Error: file not found: {s}\n", .{input_path});
            },
            else => {
                try stderr.print("Error: could not read {s}: {s}\n", .{ input_path, @errorName(err) });
            },
        }
        return EXIT_INPUT;
    };

    try analysis.warnMissingProfileTabs(sheets, args.profile, &diag);

    var g = graph.Graph.init(alloc);
    _ = schema.ingestValidatedWithOptions(&g, sheets, &diag, analysis.ingestOptionsForProfile(args.profile)) catch |err| {
        try diag.printSummary(stderr);
        try stderr.print("Error: failed to ingest spreadsheet: {s}\n", .{@errorName(err)});
        return EXIT_INPUT;
    };

    const report_ctx = try report_mod.buildReportContext(&g, args.profile, alloc);
    try diag.printSummary(stderr);
    if (args.gaps_json) |jp| try writeGapsJson(jp, report_ctx, &diag, gpa);

    const gaps = report_mod.hardGapCount(report_ctx.merged_gaps);
    const project_name = args.project orelse stem(input_path);

    var ts_buf: [20]u8 = undefined;
    const timestamp = isoTimestamp(&ts_buf);

    generateReport(gpa, &g, report_ctx, args.format, input_path, project_name, timestamp, args.output) catch |err| switch (err) {
        error.OutputError => return EXIT_OUTPUT,
        else => {
            try stderr.print("Error: report generation failed: {s}\n", .{@errorName(err)});
            return EXIT_OUTPUT;
        },
    };

    if (gaps == 0) {
        try stdout.print("Done. No gaps found.\n", .{});
    } else {
        try stdout.print("Done. {d} gap(s) found.\n", .{gaps});
    }

    try license_service.recordSuccessfulUse(gpa);

    if (args.strict and gaps > 0) {
        return @intCast(@min(gaps, 254));
    }

    return EXIT_SUCCESS;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arg_iter = std.process.argsWithAllocator(gpa) catch {
        std.debug.print("Error: out of memory\n", .{});
        std.posix.exit(1);
    };
    defer arg_iter.deinit();

    var tokens: std.ArrayList([]u8) = .empty;
    defer {
        for (tokens.items) |t| gpa.free(t);
        tokens.deinit(gpa);
    }
    _ = arg_iter.next(); // skip argv[0]
    while (arg_iter.next()) |a| {
        const owned = gpa.dupe(u8, a) catch {
            std.debug.print("Error: out of memory\n", .{});
            std.posix.exit(1);
        };
        tokens.append(gpa, owned) catch {
            std.debug.print("Error: out of memory\n", .{});
            std.posix.exit(1);
        };
    }

    const args = parseArgs(tokens.items) catch |err| {
        const msg = switch (err) {
            error.UnknownFlag => "unknown flag",
            error.MissingValue => "missing value for flag",
            error.InvalidFormat => "invalid format: use md, docx, or all",
            error.InvalidProfile => "invalid profile: use medical, aerospace, automotive, or generic",
            error.ConflictingOptions => "multiple input files specified",
        };
        std.debug.print("Error: {s}\nRun 'rtmify-trace --help' for usage.\n", .{msg});
        std.posix.exit(EXIT_INPUT);
    };

    const code = run(gpa, args) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.posix.exit(EXIT_INPUT);
    };

    std.posix.exit(code);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const user_need_header = [_][]const u8{ "ID", "Need" };
const requirement_header = [_][]const u8{ "ID", "Statement" };
const tests_header = [_][]const u8{ "ID", "Procedure" };
const risks_header = [_][]const u8{ "ID", "Hazard" };

const user_need_rows = [_]xlsx.Row{user_need_header[0..]};
const requirement_rows = [_]xlsx.Row{requirement_header[0..]};
const tests_rows = [_]xlsx.Row{tests_header[0..]};
const risks_rows = [_]xlsx.Row{risks_header[0..]};

const minimal_core_sheets = [_]xlsx.SheetData{
    .{ .name = "User Needs", .rows = user_need_rows[0..] },
    .{ .name = "Requirements", .rows = requirement_rows[0..] },
    .{ .name = "Tests", .rows = tests_rows[0..] },
    .{ .name = "Risks", .rows = risks_rows[0..] },
};

fn addNode(g: *graph.Graph, id: []const u8, node_type: graph.NodeType) !void {
    try g.addNode(id, node_type, &.{});
}

test "parseArgs no args" {
    const args = try parseArgs(&.{});
    try testing.expectEqual(@as(?[]const u8, null), args.input);
    try testing.expectEqual(Format.docx, args.format);
    try testing.expectEqual(profile_mod.ProfileId.generic, args.profile);
    try testing.expect(!args.strict);
    try testing.expect(!args.help);
    try testing.expect(!args.version);
}

test "parseArgs input file only" {
    const args = try parseArgs(&.{"requirements.xlsx"});
    try testing.expectEqualStrings("requirements.xlsx", args.input.?);
    try testing.expectEqual(Format.docx, args.format);
}

test "parseArgs --format md" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "md" });
    try testing.expectEqual(Format.md, args.format);
}

test "parseArgs --format all" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "all" });
    try testing.expectEqual(Format.all, args.format);
}

test "parseArgs --format docx" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "docx" });
    try testing.expectEqual(Format.docx, args.format);
}

test "parseArgs --output and --project" {
    const args = try parseArgs(&.{ "in.xlsx", "--output", "./out/", "--project", "My Project" });
    try testing.expectEqualStrings("./out/", args.output.?);
    try testing.expectEqualStrings("My Project", args.project.?);
}

test "parseArgs --version and --help" {
    const v = try parseArgs(&.{"--version"});
    try testing.expect(v.version);

    const h = try parseArgs(&.{"--help"});
    try testing.expect(h.help);

    const hh = try parseArgs(&.{"-h"});
    try testing.expect(hh.help);
}

test "parseArgs license info --json" {
    const args = try parseArgs(&.{ "license", "info", "--json" });
    try testing.expectEqual(LicenseCommand.info, args.license_cmd.?);
    try testing.expect(args.json);
}

test "parseArgs license install" {
    const args = try parseArgs(&.{ "license", "install", "./license.json" });
    try testing.expectEqual(LicenseCommand.install, args.license_cmd.?);
    try testing.expectEqualStrings("./license.json", args.license_cmd_path.?);
}

test "parseArgs license clear --strict" {
    const args = try parseArgs(&.{ "license", "clear", "--strict" });
    try testing.expectEqual(LicenseCommand.clear, args.license_cmd.?);
    try testing.expect(args.strict);
}

test "parseArgs unknown flag" {
    try testing.expectError(error.UnknownFlag, parseArgs(&.{"--unknown"}));
}

test "parseArgs missing value" {
    try testing.expectError(error.MissingValue, parseArgs(&.{"--format"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{"--output"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{"--project"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{"--license"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{"license"}));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "license", "install" }));
}

test "parseArgs --format pdf" {
    const args = try parseArgs(&.{ "input.xlsx", "--format", "pdf" });
    try testing.expectEqual(Format.pdf, args.format);
}

test "parseArgs invalid format" {
    try testing.expectError(error.InvalidFormat, parseArgs(&.{ "--format", "html" }));
    try testing.expectError(error.InvalidFormat, parseArgs(&.{ "--format", "rtf" }));
}

test "parseArgs --profile medical" {
    const args = try parseArgs(&.{ "input.xlsx", "--profile", "medical" });
    try testing.expectEqual(profile_mod.ProfileId.medical, args.profile);
}

test "parseArgs invalid profile" {
    try testing.expectError(error.InvalidProfile, parseArgs(&.{ "input.xlsx", "--profile", "wrong" }));
}

test "ingestOptionsForProfile enables expected tabs" {
    const medical = analysis.ingestOptionsForProfile(.medical);
    try testing.expect(medical.enable_product_tab);
    try testing.expect(medical.enable_design_inputs_tab);
    try testing.expect(medical.enable_design_outputs_tab);
    try testing.expect(medical.enable_config_items_tab);

    const aerospace = analysis.ingestOptionsForProfile(.aerospace);
    try testing.expect(aerospace.enable_product_tab);
    try testing.expect(aerospace.enable_decomposition_tab);
    try testing.expect(aerospace.enable_config_items_tab);
    try testing.expect(!aerospace.enable_design_inputs_tab);

    const generic = analysis.ingestOptionsForProfile(.generic);
    try testing.expect(!generic.enable_product_tab);
    try testing.expect(!generic.enable_design_inputs_tab);
    try testing.expect(!generic.enable_decomposition_tab);
}

test "warnMissingProfileTabs emits warnings and is non-fatal" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    try analysis.warnMissingProfileTabs(minimal_core_sheets[0..], .medical, &diag);

    try testing.expect(diag.warning_count >= 1);
    try testing.expectEqual(@as(u32, 0), diag.error_count);

    var found = false;
    for (diag.entries.items) |entry| {
        if (entry.code == diagnostic.E.profile_expected_tab_missing and
            std.mem.indexOf(u8, entry.message, "Design Inputs") != null)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "writeGapsJson emits merged gap schema with profile metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = graph.Graph.init(testing.allocator);
    defer g.deinit();
    try addNode(&g, "REQ-001", .requirement);

    const ctx = try report_mod.buildReportContext(&g, .medical, alloc);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try diag.warn(diagnostic.E.profile_expected_tab_missing, .profile, null, null, "Profile '{s}' expects tab '{s}'", .{ "medical", "Design Inputs" });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_buf);
    const json_path = try std.fs.path.join(alloc, &.{ tmp_path, "gaps.json" });

    try writeGapsJson(json_path, ctx, &diag, alloc);
    const json = try std.fs.cwd().readFileAlloc(alloc, json_path, 64 * 1024);

    try testing.expect(std.mem.indexOf(u8, json, "\"profile\":\"medical\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"node_id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"primary_id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"profile_rule\":\"iso13485_requirement_design_input_chain\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"clause\":\"ISO 13485 §7.3.3\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"warning_count\":1") != null);
}

test "parseArgs multiple positionals" {
    try testing.expectError(error.ConflictingOptions, parseArgs(&.{ "a.xlsx", "b.xlsx" }));
}

test "parseArgs --gaps-json" {
    const args = try parseArgs(&.{ "input.xlsx", "--gaps-json", "/tmp/gaps.json" });
    try testing.expectEqualStrings("/tmp/gaps.json", args.gaps_json.?);
}

test "parseArgs --gaps-json missing value" {
    try testing.expectError(error.MissingValue, parseArgs(&.{"--gaps-json"}));
}

test "stem helper" {
    try testing.expectEqualStrings("requirements", stem("requirements.xlsx"));
    try testing.expectEqualStrings("requirements", stem("/path/to/requirements.xlsx"));
    try testing.expectEqualStrings("file", stem("file"));
    try testing.expectEqualStrings("my.report", stem("my.report.xlsx"));
}

test "isoTimestamp format" {
    var buf: [20]u8 = undefined;
    const ts = isoTimestamp(&buf);
    try testing.expectEqual(@as(usize, 20), ts.len);
    try testing.expectEqual('T', ts[10]);
    try testing.expectEqual('Z', ts[19]);
    try testing.expectEqual('-', ts[4]);
    try testing.expectEqual('-', ts[7]);
    try testing.expectEqual(':', ts[13]);
    try testing.expectEqual(':', ts[16]);
}
