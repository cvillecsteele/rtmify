const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Module re-exports (used by trace/src/main.zig and live/src/main_live.zig)
// ---------------------------------------------------------------------------

pub const graph = @import("graph.zig");
pub const xlsx = @import("xlsx.zig");
pub const schema = @import("schema.zig");
pub const render_md = @import("render_md.zig");
pub const render_docx = @import("render_docx.zig");
pub const license = @import("license.zig");
pub const render_pdf = @import("render_pdf.zig");
pub const diagnostic = @import("diagnostic.zig");

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
    valid_offline_grace = 1,
    not_activated = 2,
    expired = 3,
    fingerprint_mismatch = 4,
    revoked = 5,
    invalid_key = 6,
    provider_unavailable = 7,
    cache_corrupt = 8,
    internal_error = 9,
};

pub const RtmifyLicenseDetailCode = enum(c_int) {
    none = 0,
    invalid_key = 1,
    revoked = 2,
    network_error = 3,
    server_error = 4,
    protocol_error = 5,
    cache_corrupt = 6,
    fingerprint_mismatch = 7,
    expired = 8,
    not_activated = 9,
    internal_error = 10,
};

pub const RtmifyLicenseStatus = extern struct {
    state: c_int,
    permits_use: c_int,
    activated_at: i64,
    expires_at: i64,
    last_validated_at: i64,
    offline_grace_deadline: i64,
    detail_code: c_int,
};

// ---------------------------------------------------------------------------
// Opaque graph handle (heap-allocated, owns its GPA and Graph)
// ---------------------------------------------------------------------------

pub const RtmifyGraph = struct {
    gpa_state: std.heap.GeneralPurposeAllocator(.{}),
    g: graph.Graph,
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

// ---------------------------------------------------------------------------
// Internal helper: load sheets into an already-initialised handle
// ---------------------------------------------------------------------------

fn loadSheets(handle: *RtmifyGraph, path: []const u8) RtmifyStatus {
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

    _ = schema.ingestValidated(&handle.g, sheets, &diag) catch |err| {
        last_warning_count = @intCast(diag.warning_count);
        setError("failed to ingest spreadsheet: {s}", .{@errorName(err)});
        return .err_missing_tab;
    };

    last_warning_count = @intCast(diag.warning_count);
    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_load
// ---------------------------------------------------------------------------

pub export fn rtmify_load(xlsx_path: [*:0]const u8, out_graph: **RtmifyGraph) RtmifyStatus {
    const path = std.mem.span(xlsx_path);

    const handle = std.heap.page_allocator.create(RtmifyGraph) catch {
        setError("out of memory", .{});
        return .err_invalid_xlsx;
    };
    handle.gpa_state = .init;
    const gpa = handle.gpa_state.allocator();
    handle.g = graph.Graph.init(gpa);

    const status = loadSheets(handle, path);
    if (status != .ok) {
        handle.g.deinit();
        _ = handle.gpa_state.deinit();
        std.heap.page_allocator.destroy(handle);
        return status;
    }

    out_graph.* = handle;
    return .ok;
}

// ---------------------------------------------------------------------------
// C ABI: rtmify_free
// ---------------------------------------------------------------------------

pub export fn rtmify_free(handle: *RtmifyGraph) void {
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
    const count = computeGapCount(&handle.g) catch return -1;
    return @intCast(@min(count, @as(usize, std.math.maxInt(c_int))));
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

    if (std.mem.eql(u8, fmt_str, "md")) {
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
        .valid_offline_grace => .valid_offline_grace,
        .not_activated => .not_activated,
        .expired => .expired,
        .fingerprint_mismatch => .fingerprint_mismatch,
        .revoked => .revoked,
        .invalid_key => .invalid_key,
        .provider_unavailable => .provider_unavailable,
        .cache_corrupt => .cache_corrupt,
        .internal_error => .internal_error,
    };
}

fn mapLicenseDetail(code: license.LicenseDetailCode) RtmifyLicenseDetailCode {
    return switch (code) {
        .none => .none,
        .invalid_key => .invalid_key,
        .revoked => .revoked,
        .network_error => .network_error,
        .server_error => .server_error,
        .protocol_error => .protocol_error,
        .cache_corrupt => .cache_corrupt,
        .fingerprint_mismatch => .fingerprint_mismatch,
        .expired => .expired,
        .not_activated => .not_activated,
        .internal_error => .internal_error,
    };
}

fn fillLicenseStatus(out_status: *RtmifyLicenseStatus, status: license.LicenseStatus) void {
    out_status.* = .{
        .state = @intFromEnum(mapLicenseState(status.state)),
        .permits_use = @intFromBool(status.permits_use),
        .activated_at = nullableTime(status.activated_at),
        .expires_at = nullableTime(status.expires_at),
        .last_validated_at = nullableTime(status.last_validated_at),
        .offline_grace_deadline = nullableTime(status.offline_grace_deadline),
        .detail_code = @intFromEnum(mapLicenseDetail(status.detail_code)),
    };
}

fn withDefaultLicenseService(comptime func: anytype) RtmifyStatus {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultLemonSqueezy(gpa, .{}) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return .err_license;
    };
    defer service.deinit(gpa);
    return func(gpa, &service);
}

pub export fn rtmify_license_get_status(out_status: *RtmifyLicenseStatus) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultLemonSqueezy(gpa, .{}) catch |err| {
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

pub export fn rtmify_license_activate(license_key: [*:0]const u8, out_status: *RtmifyLicenseStatus) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultLemonSqueezy(gpa, .{}) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer service.deinit(gpa);

    const key = std.mem.span(license_key);
    var result = service.activate(gpa, .{ .license_key = key }) catch |err| {
        setError("license activation failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer result.deinit(gpa);
    if (result.status.message) |msg| setError("{s}", .{msg});
    fillLicenseStatus(out_status, result.status);
    return 0;
}

pub export fn rtmify_license_deactivate(out_status: *RtmifyLicenseStatus) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultLemonSqueezy(gpa, .{}) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer service.deinit(gpa);

    var result = service.deactivate(gpa) catch |err| {
        setError("license deactivation failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer result.deinit(gpa);
    if (result.status.message) |msg| setError("{s}", .{msg});
    fillLicenseStatus(out_status, result.status);
    return 0;
}

pub export fn rtmify_license_refresh(out_status: *RtmifyLicenseStatus) c_int {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var service = license.initDefaultLemonSqueezy(gpa, .{}) catch |err| {
        setError("license service init failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer service.deinit(gpa);

    var result = service.refresh(gpa) catch |err| {
        setError("license refresh failed: {s}", .{@errorName(err)});
        return 1;
    };
    defer result.deinit(gpa);
    if (result.status.message) |msg| setError("{s}", .{msg});
    fillLicenseStatus(out_status, result.status);
    return 0;
}

pub export fn rtmify_activate_license(license_key: [*:0]const u8) RtmifyStatus {
    var out_status: RtmifyLicenseStatus = undefined;
    if (rtmify_license_activate(license_key, &out_status) != 0) return .err_license;
    return if (out_status.permits_use != 0) .ok else .err_license;
}

pub export fn rtmify_check_license() RtmifyStatus {
    var out_status: RtmifyLicenseStatus = undefined;
    if (rtmify_license_get_status(&out_status) != 0) return .err_license;
    return if (out_status.permits_use != 0) .ok else .err_license;
}

pub export fn rtmify_deactivate_license() RtmifyStatus {
    var out_status: RtmifyLicenseStatus = undefined;
    if (rtmify_license_deactivate(&out_status) != 0) return .err_license;
    return .ok;
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

    try testing.expectEqual(@as(c_int, 0), rtmify_gap_count(handle));
}

test "rtmify_gap_count counts only hard gaps" {
    const handle = try std.heap.page_allocator.create(RtmifyGraph);
    defer std.heap.page_allocator.destroy(handle);
    handle.gpa_state = .init;
    defer _ = handle.gpa_state.deinit();
    handle.g = graph.Graph.init(handle.gpa_state.allocator());
    defer handle.g.deinit();

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
