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

// ---------------------------------------------------------------------------
// Opaque graph handle
// ---------------------------------------------------------------------------

pub const RtmifyGraph = opaque {};
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

pub extern fn rtmify_generate(
    graph: *const RtmifyGraph,
    format: [*:0]const u8,
    output_path: [*:0]const u8,
    project_name: ?[*:0]const u8,
) i32;

pub extern fn rtmify_gap_count(graph: *const RtmifyGraph) i32;
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

// ---------------------------------------------------------------------------
// Worker functions
// ---------------------------------------------------------------------------

fn loadWorker(ctx: *LoadContext) void {
    var graph: *RtmifyGraph = undefined;
    const status = rtmify_load(&ctx.path_utf8, &graph);
    const lp: LPARAM = if (status == RTMIFY_OK) @bitCast(@intFromPtr(graph)) else 0;
    _ = PostMessageW(ctx.hwnd, WM_LOAD_COMPLETE, @intCast(status), lp);
    std.heap.page_allocator.destroy(ctx);
}

fn generateWorker(ctx: *GenerateContext) void {
    var status: i32 = RTMIFY_OK;
    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        status = rtmify_generate(
            ctx.graph,
            &ctx.formats[i],
            &ctx.output_paths[i],
            &ctx.project_name,
        );
        if (status != RTMIFY_OK) break;
    }
    _ = PostMessageW(ctx.hwnd, WM_GENERATE_COMPLETE, @intCast(status), 0);
    std.heap.page_allocator.destroy(ctx);
}

fn licenseInstallWorker(ctx: *LicenseInstallContext) void {
    var license_status: RtmifyLicenseStatus = undefined;
    const api_status = rtmify_trace_license_install(&ctx.path, &license_status);
    const status: i32 = if (api_status == 0 and license_status.permits_use != 0) RTMIFY_OK else RTMIFY_ERR_LICENSE;
    _ = PostMessageW(ctx.hwnd, WM_LICENSE_COMPLETE, @intCast(status), 0);
    std.heap.page_allocator.destroy(ctx);
}

// ---------------------------------------------------------------------------
// Spawn helpers — allocate context, detach thread
// ---------------------------------------------------------------------------

pub fn spawnLoad(hwnd: HWND, path: []const u8) void {
    const ctx = std.heap.page_allocator.create(LoadContext) catch return;
    ctx.hwnd = hwnd;
    ctx.path_utf8 = std.mem.zeroes([1024:0]u8);
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
