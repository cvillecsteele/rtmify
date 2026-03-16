const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Module re-exports (used by trace/src/main.zig and live/src/main_live.zig)
// ---------------------------------------------------------------------------

pub const graph = @import("graph.zig");
pub const xlsx = @import("xlsx.zig");
pub const schema = @import("schema.zig");
pub const id = @import("id.zig");
pub const render_md = @import("render_md.zig");
pub const render_docx = @import("render_docx.zig");
pub const license = @import("license.zig");
pub const render_pdf = @import("render_pdf.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const profile = @import("profile.zig");
pub const chain = @import("chain.zig");
pub const report = @import("report.zig");
pub const analysis = @import("analysis.zig");

// ---------------------------------------------------------------------------
// C ABI status codes
// ---------------------------------------------------------------------------

pub const RtmifyStatus = enum(c_int) {
    ok = 0,
    err_file_not_found = 1,
    err_invalid_xlsx = 2,
    err_missing_tab = 3,
    err_license = 4,
    err_output = 5,
};

pub const RtmifyLicenseState = enum(c_int) {
    valid = 0,
    not_licensed = 1,
    expired = 3,
    invalid = 4,
    tampered = 5,
};

pub const RtmifyLicenseDetailCode = enum(c_int) {
    none = 0,
    free_run_available = 1,
    trial_exhausted = 2,
    file_not_found = 3,
    invalid_json = 4,
    bad_signature = 5,
    wrong_product = 6,
    unsupported_schema = 7,
    expired = 8,
    install_failed = 9,
    internal_error = 10,
};

pub const RtmifyLicenseStatus = extern struct {
    state: c_int,
    permits_use: c_int,
    using_free_run: c_int,
    expires_at: i64,
    issued_at: i64,
    detail_code: c_int,
    expected_key_fingerprint: [65]u8,
    license_signing_key_fingerprint: [65]u8,
};

pub const RtmifyProfile = enum(c_int) {
    generic = 0,
    medical = 1,
    aerospace = 2,
    automotive = 3,
};

pub const RtmifyAnalysisSummary = extern struct {
    profile: c_int,
    profile_short_name: [16]u8,
    profile_display_name: [32]u8,
    profile_standards: [128]u8,
    warning_count: c_int,
    generic_gap_count: c_int,
    profile_gap_count: c_int,
    total_gap_count: c_int,
};

// ---------------------------------------------------------------------------
// Opaque graph handle (heap-allocated, owns its GPA and Graph)
// ---------------------------------------------------------------------------

pub const RtmifyGraph = struct {
    gpa_state: std.heap.GeneralPurposeAllocator(.{}),
    g: graph.Graph,
    profile: profile.ProfileId,
    warning_count: c_int,
    report_ctx: ?report.ReportContext,
};

// ---------------------------------------------------------------------------
// Thread-local last-error buffer and warning count
// ---------------------------------------------------------------------------

threadlocal var last_error_buf: [512]u8 = .{0} ** 512;
threadlocal var last_warning_count: c_int = 0;

pub export fn rtmify_warning_count() c_int {
    return last_warning_count;
}

fn setError(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], fmt, args) catch
        last_error_buf[0 .. last_error_buf.len - 1];
    last_error_buf[written.len] = 0;
}

pub export fn rtmify_last_error() [*:0]const u8 {
    return @ptrCast(&last_error_buf);
}

fn toRtmifyProfile(profile_id: profile.ProfileId) RtmifyProfile {
    return switch (profile_id) {
        .generic => .generic,
        .medical => .medical,
        .aerospace => .aerospace,
        .automotive => .automotive,
    };
}

fn fromRtmifyProfile(value: c_int) ?profile.ProfileId {
    return switch (value) {
        @intFromEnum(RtmifyProfile.generic) => .generic,
        @intFromEnum(RtmifyProfile.medical) => .medical,
        @intFromEnum(RtmifyProfile.aerospace) => .aerospace,
        @intFromEnum(RtmifyProfile.automotive) => .automotive,
        else => null,
    };
}

fn writeFixedCString(dest: anytype, src: []const u8) void {
    @memset(dest, 0);
    const len = @min(src.len, dest.len - 1);
    @memcpy(dest[0..len], src[0..len]);
}

fn fillAnalysisSummary(handle: *const RtmifyGraph, out_summary: *RtmifyAnalysisSummary) void {
    const prof = profile.get(handle.profile);
    var generic_gap_count: c_int = 0;
    var profile_gap_count: c_int = 0;
    var total_gap_count: c_int = 0;

    if (handle.report_ctx) |ctx| {
        for (ctx.generic_gaps) |gap| {
            if (gap.severity == .hard) generic_gap_count += 1;
        }
        for (ctx.profile_gaps) |gap| {
            if (gap.severity == .err) profile_gap_count += 1;
        }
        total_gap_count = @intCast(@min(report.hardGapCount(ctx.merged_gaps), @as(usize, std.math.maxInt(c_int))));
    } else {
        const count = computeGapCount(&handle.g) catch 0;
        total_gap_count = @intCast(@min(count, @as(usize, std.math.maxInt(c_int))));
        generic_gap_count = total_gap_count;
    }

    out_summary.* = .{
        .profile = @intFromEnum(toRtmifyProfile(handle.profile)),
        .profile_short_name = undefined,
        .profile_display_name = undefined,
        .profile_standards = undefined,
        .warning_count = handle.warning_count,
        .generic_gap_count = generic_gap_count,
        .profile_gap_count = profile_gap_count,
        .total_gap_count = total_gap_count,
    };
    writeFixedCString(&out_summary.profile_short_name, prof.short_name);
    writeFixedCString(&out_summary.profile_display_name, prof.name);
    writeFixedCString(&out_summary.profile_standards, prof.standards);
}

// ---------------------------------------------------------------------------
// Internal helper: load sheets into an already-initialised handle
// ---------------------------------------------------------------------------

fn loadSheetsWithProfile(handle: *RtmifyGraph, path: []const u8, profile_id: profile.ProfileId) RtmifyStatus {
    const gpa = handle.gpa_state.allocator();
    var parse_arena = std.heap.ArenaAllocator.init(gpa);
    defer parse_arena.deinit();

    var diag = diagnostic.Diagnostics.init(gpa);
    defer diag.deinit();

    const sheets = xlsx.parseValidated(parse_arena.allocator(), path, &diag) catch |err| {
        last_warning_count = @intCast(diag.warning_count);
        switch (err) {
            error.FileNotFound => {
                setError("file not found: {s}", .{path});
                return .err_file_not_found;
            },
            else => {
                setError("failed to parse XLSX: {s}", .{@errorName(err)});
                return .err_invalid_xlsx;
            },
        }
    };

    analysis.warnMissingProfileTabs(sheets, profile_id, &diag) catch |err| {
        last_warning_count = @intCast(diag.warning_count);
        setError("failed to inspect workbook tabs: {s}", .{@errorName(err)});
        return .err_missing_tab;
    };

    _ = schema.ingestValidatedWithOptions(&handle.g, sheets, &diag, analysis.ingestOptionsForProfile(profile_id)) catch |err| {
        last_warning_count = @intCast(diag.warning_count);
        setError("failed to ingest spreadsheet: {s}", .{@errorName(err)});
        return .err_missing_tab;
    };

    last_warning_count = @intCast(diag.warning_count);
    handle.warning_count = last_warning_count;
    handle.profile = profile_id;
    handle.report_ctx = report.buildReportContext(&handle.g, profile_id, gpa) catch |err| {
        setError("failed to analyze workbook: {s}", .{@errorName(err)});
        return .err_missing_tab;
    };
    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_load
// ---------------------------------------------------------------------------

pub export fn rtmify_load(xlsx_path: [*:0]const u8, out_graph: **RtmifyGraph) RtmifyStatus {
    var summary: RtmifyAnalysisSummary = undefined;
    return rtmify_load_with_profile(xlsx_path, @intFromEnum(RtmifyProfile.generic), out_graph, &summary);
}

pub export fn rtmify_load_with_profile(
    xlsx_path: [*:0]const u8,
    profile_value: c_int,
    out_graph: **RtmifyGraph,
    out_summary: *RtmifyAnalysisSummary,
) RtmifyStatus {
    const path = std.mem.span(xlsx_path);
    const profile_id = fromRtmifyProfile(profile_value) orelse {
        setError("invalid profile: {d}", .{profile_value});
        return .err_invalid_xlsx;
    };

    const handle = std.heap.page_allocator.create(RtmifyGraph) catch {
        setError("out of memory", .{});
        return .err_invalid_xlsx;
    };
    handle.gpa_state = .init;
    const gpa = handle.gpa_state.allocator();
    handle.g = graph.Graph.init(gpa);
    handle.profile = .generic;
    handle.warning_count = 0;
    handle.report_ctx = null;

    const status = loadSheetsWithProfile(handle, path, profile_id);
    if (status != .ok) {
        handle.g.deinit();
        _ = handle.gpa_state.deinit();
        std.heap.page_allocator.destroy(handle);
        return status;
    }

    fillAnalysisSummary(handle, out_summary);
    out_graph.* = handle;
    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_free
// ---------------------------------------------------------------------------

pub export fn rtmify_free(handle: *RtmifyGraph) void {
    if (handle.report_ctx) |ctx| report.deinitReportContext(ctx, handle.gpa_state.allocator());
    handle.g.deinit();
    _ = handle.gpa_state.deinit();
    std.heap.page_allocator.destroy(handle);
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_gap_count
// ---------------------------------------------------------------------------

fn computeGapCount(g: *const graph.Graph) !usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return g.hardGapCount(arena.allocator());
}

pub export fn rtmify_gap_count(handle: *const RtmifyGraph) c_int {
    if (handle.report_ctx) |ctx| {
        return @intCast(@min(report.hardGapCount(ctx.merged_gaps), @as(usize, std.math.maxInt(c_int))));
    }
    const count = computeGapCount(&handle.g) catch return -1;
    return @intCast(@min(count, @as(usize, std.math.maxInt(c_int))));
}

pub export fn rtmify_graph_summary(handle: *const RtmifyGraph, out_summary: *RtmifyAnalysisSummary) RtmifyStatus {
    fillAnalysisSummary(handle, out_summary);
    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_generate
// ---------------------------------------------------------------------------

fn isoTimestamp(buf: *[20]u8) []u8 {
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

pub export fn rtmify_generate(
    handle: *const RtmifyGraph,
    format: [*:0]const u8,
    output_path: [*:0]const u8,
    project_name: ?[*:0]const u8,
) RtmifyStatus {
    const fmt_str = std.mem.span(format);
    const out_path = std.mem.span(output_path);
    const proj_name: []const u8 = if (project_name) |p| std.mem.span(p) else "RTMify Report";

    var ts_buf: [20]u8 = undefined;
    const timestamp = isoTimestamp(&ts_buf);

    const file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        setError("cannot write to {s}: {s}", .{ out_path, @errorName(err) });
        return .err_output;
    };
    defer file.close();
    const dw = file.deprecatedWriter();

    if (handle.report_ctx) |ctx| {
        if (std.mem.eql(u8, fmt_str, "md")) {
            render_md.renderMdWithContext(&handle.g, ctx, proj_name, timestamp, dw) catch |err| {
                setError("markdown render failed: {s}", .{@errorName(err)});
                return .err_output;
            };
        } else if (std.mem.eql(u8, fmt_str, "docx")) {
            render_docx.renderDocxWithContext(&handle.g, ctx, proj_name, timestamp, dw) catch |err| {
                setError("docx render failed: {s}", .{@errorName(err)});
                return .err_output;
            };
        } else if (std.mem.eql(u8, fmt_str, "pdf")) {
            render_pdf.renderPdfWithContext(&handle.g, ctx, proj_name, timestamp, dw) catch |err| {
                setError("pdf render failed: {s}", .{@errorName(err)});
                return .err_output;
            };
        } else {
            setError("unknown format: {s}", .{fmt_str});
            return .err_output;
        }
    } else if (std.mem.eql(u8, fmt_str, "md")) {
        render_md.renderMd(&handle.g, proj_name, timestamp, dw) catch |err| {
            setError("markdown render failed: {s}", .{@errorName(err)});
            return .err_output;
        };
    } else if (std.mem.eql(u8, fmt_str, "docx")) {
        render_docx.renderDocx(&handle.g, proj_name, timestamp, dw) catch |err| {
            setError("docx render failed: {s}", .{@errorName(err)});
            return .err_output;
        };
    } else if (std.mem.eql(u8, fmt_str, "pdf")) {
        render_pdf.renderPdf(&handle.g, proj_name, timestamp, dw) catch |err| {
            setError("pdf render failed: {s}", .{@errorName(err)});
            return .err_output;
        };
    } else {
        setError("unknown format: {s}", .{fmt_str});
        return .err_output;
    }

    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: license functions
// ---------------------------------------------------------------------------

fn nullableTime(value: ?i64) i64 {
    return value orelse -1;
}

fn mapLicenseState(state: license.LicenseState) RtmifyLicenseState {
    return switch (state) {
        .valid => .valid,
        .not_licensed => .not_licensed,
        .expired => .expired,
        .invalid => .invalid,
        .tampered => .tampered,
    };
}

fn mapLicenseDetail(code: license.LicenseDetailCode) RtmifyLicenseDetailCode {
    return switch (code) {
        .none => .none,
        .free_run_available => .free_run_available,
        .trial_exhausted => .trial_exhausted,
        .file_not_found => .file_not_found,
        .invalid_json => .invalid_json,
        .bad_signature => .bad_signature,
        .wrong_product => .wrong_product,
        .unsupported_schema => .unsupported_schema,
        .expired => .expired,
        .install_failed => .install_failed,
        .internal_error => .internal_error,
    };
}

fn writeCString(dest: *[65]u8, src: ?[]const u8) void {
    @memset(dest, 0);
    if (src) |value| {
        const len = @min(value.len, dest.len - 1);
        @memcpy(dest[0..len], value[0..len]);
    }
}

fn fillLicenseStatus(out_status: *RtmifyLicenseStatus, status: license.LicenseStatus) void {
    out_status.* = .{
        .state = @intFromEnum(mapLicenseState(status.state)),
        .permits_use = @intFromBool(status.permits_use),
        .using_free_run = @intFromBool(status.using_free_run),
        .expires_at = nullableTime(status.expires_at),
        .issued_at = nullableTime(status.issued_at),
        .detail_code = @intFromEnum(mapLicenseDetail(status.detail_code)),
        .expected_key_fingerprint = undefined,
        .license_signing_key_fingerprint = undefined,
    };
    writeCString(&out_status.expected_key_fingerprint, status.expected_key_fingerprint);
    writeCString(&out_status.license_signing_key_fingerprint, status.license_signing_key_fingerprint);
}

fn withLicenseService(comptime product: license.LicenseProduct, comptime trial_policy: license.TrialPolicy, func: anytype) RtmifyStatus {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultHmacFile(gpa, .{
        .product = product,
        .trial_policy = trial_policy,
    }) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return .err_license;
    };
    defer service.deinit(gpa);
    return func(gpa, &service);
}

fn fillStatusForProduct(out_status: *RtmifyLicenseStatus, product: license.LicenseProduct, trial_policy: license.TrialPolicy) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultHmacFile(gpa, .{
        .product = product,
        .trial_policy = trial_policy,
    }) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer service.deinit(gpa);

    var status = service.getStatus(gpa) catch |err| {
        setError("license status failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer status.deinit(gpa);
    if (status.message) |msg| setError("{s}", .{msg});
    fillLicenseStatus(out_status, status);
    return 0;
}

fn installLicenseForProduct(path: [*:0]const u8, out_status: *RtmifyLicenseStatus, product: license.LicenseProduct, trial_policy: license.TrialPolicy) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultHmacFile(gpa, .{
        .product = product,
        .trial_policy = trial_policy,
    }) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer service.deinit(gpa);

    var status = service.installFromPath(gpa, std.mem.span(path)) catch |err| {
        setError("license install failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer status.deinit(gpa);
    if (status.message) |msg| setError("{s}", .{msg});
    fillLicenseStatus(out_status, status);
    return 0;
}

fn clearLicenseForProduct(out_status: *RtmifyLicenseStatus, product: license.LicenseProduct, trial_policy: license.TrialPolicy) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultHmacFile(gpa, .{
        .product = product,
        .trial_policy = trial_policy,
    }) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer service.deinit(gpa);

    var status = service.clearInstalledLicense(gpa) catch |err| {
        setError("license clear failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer status.deinit(gpa);
    if (status.message) |msg| setError("{s}", .{msg});
    fillLicenseStatus(out_status, status);
    return 0;
}

fn infoJsonForProduct(product: license.LicenseProduct, trial_policy: license.TrialPolicy) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultHmacFile(gpa, .{
        .product = product,
        .trial_policy = trial_policy,
    }) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer service.deinit(gpa);

    var info = service.getInfo(gpa) catch |err| {
        setError("license info failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer info.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const w = buf.writer(gpa);
    w.writeAll("{\"license_path\":") catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    license.license_file.writeJsonString(w, info.license_path) catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    w.writeAll(",\"expected_key_fingerprint\":") catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    license.license_file.writeJsonString(w, info.expected_key_fingerprint) catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    w.writeAll(",\"license_signing_key_fingerprint\":") catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    if (info.license_signing_key_fingerprint) |value| {
        license.license_file.writeJsonString(w, value) catch {
            setError("license info serialization failed", .{});
            return 1;
        };
    } else {
        w.writeAll("null") catch {
            setError("license info serialization failed", .{});
            return 1;
        };
    }
    w.writeAll(",\"payload\":") catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    license.license_file.writePayloadJson(w, info.payload) catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    w.writeAll("}") catch {
        setError("license info serialization failed", .{});
        return 1;
    };
    setError("{s}", .{buf.items});
    return 0;
}

pub export fn rtmify_trace_license_get_status(out_status: *RtmifyLicenseStatus) c_int {
    return fillStatusForProduct(out_status, .trace, .single_free_run);
}

pub export fn rtmify_trace_license_install(path: [*:0]const u8, out_status: *RtmifyLicenseStatus) c_int {
    return installLicenseForProduct(path, out_status, .trace, .single_free_run);
}

pub export fn rtmify_trace_license_clear(out_status: *RtmifyLicenseStatus) c_int {
    return clearLicenseForProduct(out_status, .trace, .single_free_run);
}

pub export fn rtmify_trace_license_record_successful_use() c_int {
    const status = withLicenseService(.trace, .single_free_run, struct {
        fn call(gpa: Allocator, service: *license.Service) RtmifyStatus {
            service.recordSuccessfulUse(gpa) catch |err| {
                setError("license marker write failed: {s}", .{@errorName(err)});
                return .err_license;
            };
            return .ok;
        }
    }.call);
    return if (status == .ok) 0 else 1;
}

pub export fn rtmify_trace_license_info_json() c_int {
    return infoJsonForProduct(.trace, .single_free_run);
}

pub export fn rtmify_live_license_get_status(out_status: *RtmifyLicenseStatus) c_int {
    return fillStatusForProduct(out_status, .live, .requires_license);
}

pub export fn rtmify_live_license_install(path: [*:0]const u8, out_status: *RtmifyLicenseStatus) c_int {
    return installLicenseForProduct(path, out_status, .live, .requires_license);
}

pub export fn rtmify_live_license_clear(out_status: *RtmifyLicenseStatus) c_int {
    return clearLicenseForProduct(out_status, .live, .requires_license);
}

pub export fn rtmify_live_license_info_json() c_int {
    return infoJsonForProduct(.live, .requires_license);
}

pub export fn rtmify_license_get_status(out_status: *RtmifyLicenseStatus) c_int {
    return fillStatusForProduct(out_status, .trace, .single_free_run);
}

pub export fn rtmify_license_activate(license_key: [*:0]const u8, out_status: *RtmifyLicenseStatus) c_int {
    _ = license_key;
    _ = out_status;
    setError("license activation is no longer supported; import a signed license file", .{});
    return 1;
}

pub export fn rtmify_license_deactivate(out_status: *RtmifyLicenseStatus) c_int {
    _ = out_status;
    setError("license deactivation is no longer supported; clear the installed signed license file", .{});
    return 1;
}

pub export fn rtmify_license_refresh(out_status: *RtmifyLicenseStatus) c_int {
    _ = out_status;
    setError("license refresh is no longer supported for offline signed license files", .{});
    return 1;
}

pub export fn rtmify_activate_license(license_key: [*:0]const u8) RtmifyStatus {
    _ = license_key;
    setError("license activation is no longer supported; import a signed license file", .{});
    return .err_license;
}

pub export fn rtmify_check_license() RtmifyStatus {
    var out_status: RtmifyLicenseStatus = undefined;
    if (rtmify_trace_license_get_status(&out_status) != 0) return .err_license;
    return if (out_status.permits_use != 0) .ok else .err_license;
}

pub export fn rtmify_deactivate_license() RtmifyStatus {
    setError("license deactivation is no longer supported; clear the installed signed license file", .{});
    return .err_license;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lib imports" {
    _ = graph;
    _ = xlsx;
    _ = schema;
    _ = render_md;
    _ = render_docx;
    _ = license;
    _ = render_pdf;
    _ = diagnostic;
    _ = analysis;
}

test "rtmify_last_error is valid pointer" {
    const err_ptr = rtmify_last_error();
    _ = std.mem.span(err_ptr);
}

test "rtmify_load nonexistent file returns err_file_not_found" {
    var handle: *RtmifyGraph = undefined;
    const status = rtmify_load("/nonexistent/path/to/file.xlsx", &handle);
    try testing.expectEqual(RtmifyStatus.err_file_not_found, status);
    const err_msg = std.mem.span(rtmify_last_error());
    try testing.expect(err_msg.len > 0);
}

test "rtmify_gap_count empty graph" {
    const handle = try std.heap.page_allocator.create(RtmifyGraph);
    defer std.heap.page_allocator.destroy(handle);
    handle.gpa_state = .init;
    defer _ = handle.gpa_state.deinit();
    handle.g = graph.Graph.init(handle.gpa_state.allocator());
    defer handle.g.deinit();
    handle.profile = .generic;
    handle.warning_count = 0;
    handle.report_ctx = null;

    try testing.expectEqual(@as(c_int, 0), rtmify_gap_count(handle));
}

test "rtmify_gap_count counts only hard gaps" {
    const handle = try std.heap.page_allocator.create(RtmifyGraph);
    defer std.heap.page_allocator.destroy(handle);
    handle.gpa_state = .init;
    defer _ = handle.gpa_state.deinit();
    handle.g = graph.Graph.init(handle.gpa_state.allocator());
    defer handle.g.deinit();
    handle.profile = .generic;
    handle.warning_count = 0;
    handle.report_ctx = null;

    try handle.g.addNode("REQ-001", .requirement, &.{});
    try handle.g.addNode("REQ-002", .requirement, &.{.{ .key = "declared_test_group_ref_count", .value = "1" }});
    try handle.g.addNode("UN-001", .user_need, &.{});
    try handle.g.addNode("TG-001", .test_group, &.{});
    try handle.g.addNode("RSK-001", .risk, &.{.{ .key = "declared_mitigation_req_ref_count", .value = "0" }});

    // REQ-001 = no user need + no test group = 2 hard gaps
    // REQ-002 = no user need + unresolved test-group refs = 2 hard gaps
    // RSK-001 = no mitigation requirement = 1 hard gap
    // UN-001 and TG-001 contribute advisory gaps only
    try testing.expectEqual(@as(c_int, 5), rtmify_gap_count(handle));
}

test "rtmify_load_with_profile on missing file returns file-not-found" {
    var handle: *RtmifyGraph = undefined;
    var summary: RtmifyAnalysisSummary = undefined;
    const status = rtmify_load_with_profile("/nonexistent/path/to/file.xlsx", @intFromEnum(RtmifyProfile.medical), &handle, &summary);
    try testing.expectEqual(RtmifyStatus.err_file_not_found, status);
}

test "rtmify_load_with_profile populates medical summary" {
    var handle: *RtmifyGraph = undefined;
    var summary: RtmifyAnalysisSummary = undefined;
    const status = rtmify_load_with_profile("test/fixtures/RTMify_Profile_Tabs_Golden.xlsx", @intFromEnum(RtmifyProfile.medical), &handle, &summary);
    try testing.expectEqual(RtmifyStatus.ok, status);
    defer rtmify_free(handle);

    try testing.expectEqual(@as(c_int, @intFromEnum(RtmifyProfile.medical)), summary.profile);
    try testing.expect(summary.profile_gap_count > 0);
    try testing.expect(summary.total_gap_count >= summary.profile_gap_count);
}
