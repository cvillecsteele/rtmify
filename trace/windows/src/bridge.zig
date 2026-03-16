// bridge.zig — C ABI declarations for librtmify + worker thread helpers
//
// All worker threads call one librtmify function, then PostMessageW back to
// the main thread. No shared mutable state between threads.

const std = @import("std");

// ---------------------------------------------------------------------------
// Win32 primitives used in this file
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const WPARAM = usize;
const LPARAM = isize;

extern "user32" fn PostMessageW(
    hWnd: HWND,
    Msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// librtmify C ABI status codes
// ---------------------------------------------------------------------------

pub const RTMIFY_OK: i32 = 0;
pub const RTMIFY_ERR_FILE_NOT_FOUND: i32 = 1;
pub const RTMIFY_ERR_INVALID_XLSX: i32 = 2;
pub const RTMIFY_ERR_MISSING_TAB: i32 = 3;
pub const RTMIFY_ERR_LICENSE: i32 = 4;
pub const RTMIFY_ERR_OUTPUT: i32 = 5;

pub const RtmifyProfile = enum(i32) {
    generic = 0,
    medical = 1,
    aerospace = 2,
    automotive = 3,
};

// ---------------------------------------------------------------------------
// Opaque graph handle
// ---------------------------------------------------------------------------

pub const RtmifyGraph = opaque {};
pub const RtmifyAnalysisSummary = extern struct {
    profile: i32,
    profile_short_name: [16]u8,
    profile_display_name: [32]u8,
    profile_standards: [128]u8,
    warning_count: i32,
    generic_gap_count: i32,
    profile_gap_count: i32,
    total_gap_count: i32,
};

pub const RtmifyLicenseStatus = extern struct {
    state: i32,
    permits_use: i32,
    using_free_run: i32,
    expires_at: i64,
    issued_at: i64,
    detail_code: i32,
    expected_key_fingerprint: [65]u8,
    license_signing_key_fingerprint: [65]u8,
};

// ---------------------------------------------------------------------------
// C ABI extern declarations (librtmify.a)
// ---------------------------------------------------------------------------

pub extern fn rtmify_load(
    xlsx_path: [*:0]const u8,
    out_graph: **RtmifyGraph,
) i32;
pub extern fn rtmify_load_with_profile(
    xlsx_path: [*:0]const u8,
    profile: i32,
    out_graph: **RtmifyGraph,
    out_summary: *RtmifyAnalysisSummary,
) i32;

pub extern fn rtmify_generate(
    graph: *const RtmifyGraph,
    format: [*:0]const u8,
    output_path: [*:0]const u8,
    project_name: ?[*:0]const u8,
) i32;

pub extern fn rtmify_gap_count(graph: *const RtmifyGraph) i32;
pub extern fn rtmify_graph_summary(graph: *const RtmifyGraph, out_summary: *RtmifyAnalysisSummary) i32;
pub extern fn rtmify_warning_count() i32;
pub extern fn rtmify_last_error() [*:0]const u8;
pub extern fn rtmify_free(graph: *RtmifyGraph) void;
pub extern fn rtmify_trace_license_get_status(out_status: *RtmifyLicenseStatus) i32;
pub extern fn rtmify_trace_license_install(path: [*:0]const u8, out_status: *RtmifyLicenseStatus) i32;
pub extern fn rtmify_trace_license_clear(out_status: *RtmifyLicenseStatus) i32;
pub extern fn rtmify_trace_license_record_successful_use() i32;
pub extern fn rtmify_check_license() i32;

// ---------------------------------------------------------------------------
// Custom window messages (worker → main thread via PostMessageW)
// ---------------------------------------------------------------------------

pub const WM_APP: UINT = 0x8000;
pub const WM_LOAD_COMPLETE: UINT = WM_APP + 1;
pub const WM_GENERATE_COMPLETE: UINT = WM_APP + 2;
pub const WM_LICENSE_COMPLETE: UINT = WM_APP + 3;

// ---------------------------------------------------------------------------
// Context structs — heap-allocated, freed by WndProc after receipt
// ---------------------------------------------------------------------------

pub const LoadContext = struct {
    hwnd: HWND,
    path_utf8: [1024:0]u8,
    profile: RtmifyProfile,
};

pub const GenerateContext = struct {
    hwnd: HWND,
    graph: *const RtmifyGraph,
    // Parallel arrays: formats[i] → output_paths[i]
    formats: [3][8:0]u8,
    output_paths: [3][1024:0]u8,
    project_name: [256:0]u8,
    count: usize, // number of generate calls (1 for single, 3 for "All")
};

pub const LicenseInstallContext = struct {
    hwnd: HWND,
    path: [1024:0]u8,
};

pub const LoadResult = struct {
    status: i32,
    graph: ?*RtmifyGraph,
    summary: RtmifyAnalysisSummary,
    path_utf8: [1024:0]u8,
    error_message: [512:0]u8,
};

pub const GenerateResult = struct {
    status: i32,
    error_message: [512:0]u8,
};

pub const LicenseInstallResult = struct {
    status: i32,
    error_message: [512:0]u8,
};

fn copyCString(dest: anytype, src: []const u8) void {
    @memset(dest, 0);
    const n = @min(src.len, dest.len - 1);
    @memcpy(dest[0..n], src[0..n]);
}

fn copyLastError(dest: anytype) void {
    copyCString(dest, std.mem.span(rtmify_last_error()));
}

// ---------------------------------------------------------------------------
// Worker functions
// ---------------------------------------------------------------------------

fn loadWorker(ctx: *LoadContext) void {
    const result = std.heap.page_allocator.create(LoadResult) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    result.* = .{
        .status = RTMIFY_ERR_INVALID_XLSX,
        .graph = null,
        .summary = std.mem.zeroes(RtmifyAnalysisSummary),
        .path_utf8 = std.mem.zeroes([1024:0]u8),
        .error_message = std.mem.zeroes([512:0]u8),
    };
    copyCString(&result.path_utf8, std.mem.sliceTo(&ctx.path_utf8, 0));

    var graph: *RtmifyGraph = undefined;
    result.status = rtmify_load_with_profile(&ctx.path_utf8, @intFromEnum(ctx.profile), &graph, &result.summary);
    if (result.status == RTMIFY_OK) {
        result.graph = graph;
    } else {
        copyLastError(&result.error_message);
    }
    _ = PostMessageW(ctx.hwnd, WM_LOAD_COMPLETE, 0, @bitCast(@intFromPtr(result)));
    std.heap.page_allocator.destroy(ctx);
}

fn generateWorker(ctx: *GenerateContext) void {
    const result = std.heap.page_allocator.create(GenerateResult) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    result.* = .{
        .status = RTMIFY_OK,
        .error_message = std.mem.zeroes([512:0]u8),
    };
    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        result.status = rtmify_generate(
            ctx.graph,
            &ctx.formats[i],
            &ctx.output_paths[i],
            &ctx.project_name,
        );
        if (result.status != RTMIFY_OK) {
            copyLastError(&result.error_message);
            break;
        }
    }
    _ = PostMessageW(ctx.hwnd, WM_GENERATE_COMPLETE, 0, @bitCast(@intFromPtr(result)));
    std.heap.page_allocator.destroy(ctx);
}

fn licenseInstallWorker(ctx: *LicenseInstallContext) void {
    const result = std.heap.page_allocator.create(LicenseInstallResult) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    result.* = .{
        .status = RTMIFY_ERR_LICENSE,
        .error_message = std.mem.zeroes([512:0]u8),
    };
    var license_status: RtmifyLicenseStatus = undefined;
    const api_status = rtmify_trace_license_install(&ctx.path, &license_status);
    result.status = if (api_status == 0 and license_status.permits_use != 0) RTMIFY_OK else RTMIFY_ERR_LICENSE;
    if (result.status != RTMIFY_OK) {
        copyLastError(&result.error_message);
    }
    _ = PostMessageW(ctx.hwnd, WM_LICENSE_COMPLETE, 0, @bitCast(@intFromPtr(result)));
    std.heap.page_allocator.destroy(ctx);
}

// ---------------------------------------------------------------------------
// Spawn helpers — allocate context, detach thread
// ---------------------------------------------------------------------------

pub fn spawnLoad(hwnd: HWND, path: []const u8, profile: RtmifyProfile) void {
    const ctx = std.heap.page_allocator.create(LoadContext) catch return;
    ctx.hwnd = hwnd;
    ctx.path_utf8 = std.mem.zeroes([1024:0]u8);
    ctx.profile = profile;
    const n = @min(path.len, 1023);
    @memcpy(ctx.path_utf8[0..n], path[0..n]);
    const thread = std.Thread.spawn(.{}, loadWorker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

pub fn spawnGenerate(
    hwnd: HWND,
    graph: *const RtmifyGraph,
    formats: []const []const u8,
    output_paths: []const []const u8,
    project: []const u8,
) void {
    const ctx = std.heap.page_allocator.create(GenerateContext) catch return;
    ctx.hwnd = hwnd;
    ctx.graph = graph;
    ctx.count = @min(formats.len, 3);
    ctx.formats = std.mem.zeroes([3][8:0]u8);
    ctx.output_paths = std.mem.zeroes([3][1024:0]u8);
    ctx.project_name = std.mem.zeroes([256:0]u8);

    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        const fn_len = @min(formats[i].len, 7);
        @memcpy(ctx.formats[i][0..fn_len], formats[i][0..fn_len]);
        const op_len = @min(output_paths[i].len, 1023);
        @memcpy(ctx.output_paths[i][0..op_len], output_paths[i][0..op_len]);
    }
    const pn = @min(project.len, 255);
    @memcpy(ctx.project_name[0..pn], project[0..pn]);

    const thread = std.Thread.spawn(.{}, generateWorker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

pub fn spawnInstallLicense(hwnd: HWND, path: []const u8) void {
    const ctx = std.heap.page_allocator.create(LicenseInstallContext) catch return;
    ctx.hwnd = hwnd;
    ctx.path = std.mem.zeroes([1024:0]u8);
    const n = @min(path.len, 1023);
    @memcpy(ctx.path[0..n], path[0..n]);
    const thread = std.Thread.spawn(.{}, licenseInstallWorker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

pub fn clearLicense() bool {
    var status: RtmifyLicenseStatus = undefined;
    return rtmify_trace_license_clear(&status) == 0;
}

pub fn recordSuccessfulUse() bool {
    return rtmify_trace_license_record_successful_use() == 0;
}
