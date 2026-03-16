// main.zig — wWinMain entry point and WndProc message dispatch
//
// Implements the 3-state UX:
//   license_gate  →  drop_zone / file_loaded  →  done
//
// Workers post WM_APP+N messages back; all UI mutation is on the main thread.

const std = @import("std");
const bridge = @import("bridge.zig");
const state = @import("state.zig");
const ui = @import("ui.zig");
const drop = @import("drop.zig");
const dialogs = @import("dialogs.zig");

// ---------------------------------------------------------------------------
// Win32 types
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = u32;
const WORD = u16;
const LPARAM = isize;
const WPARAM = usize;
const LRESULT = isize;
const ATOM = u16;

const MSG = extern struct {
    hwnd: ?*anyopaque,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt_x: i32,
    pt_y: i32,
    lPrivate: DWORD,
};

const RECT = ui.RECT;

const WNDPROC = *const fn (?*anyopaque, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?*anyopaque,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque,
};

// ---------------------------------------------------------------------------
// Win32 constants
// ---------------------------------------------------------------------------

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const WS_THICKFRAME: DWORD = 0x00040000;
const WS_MAXIMIZEBOX: DWORD = 0x00010000;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_MINIMIZEBOX: DWORD = 0x00020000;

const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

const WM_DESTROY: UINT = 0x0002;
const WM_CREATE: UINT = 0x0001;
const WM_PAINT: UINT = 0x000F;
const WM_COMMAND: UINT = 0x0111;
const WM_DROPFILES: UINT = 0x0233;
const WM_DPICHANGED: UINT = 0x02E0;
const WM_CLOSE: UINT = 0x0010;
const WM_ACTIVATE: UINT = 0x0006;
const WM_CTLCOLORSTATIC: UINT = 0x0138;
const CBN_SELCHANGE: usize = 1;

const IDC_STATIC: usize = 0xFFFF;

const SW_SHOW: c_int = 5;
const SW_HIDE: c_int = 0;

const COLOR_BTNFACE: c_int = 15;
const COLOR_WINDOW: c_int = 5;

// LOGPIXELSX for GetDeviceCaps
const LOGPIXELSX: c_int = 88;

// SWP flags
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;

// SetWindowPos insert-after values
const HWND_TOP: ?*anyopaque = null;

// ---------------------------------------------------------------------------
// Win32 extern functions
// ---------------------------------------------------------------------------

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32,
    hWndParent: ?*anyopaque, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?*anyopaque, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn DefWindowProcW(hWnd: ?*anyopaque, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn LoadCursorW(hInstance: ?*anyopaque, lpCursorName: usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: c_uint) callconv(.winapi) c_int;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?*anyopaque, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetSysColorBrush(nIndex: c_int) callconv(.winapi) *anyopaque;
extern "user32" fn SetTextColor(hdc: *anyopaque, crColor: u32) callconv(.winapi) u32;
extern "user32" fn GetDC(hWnd: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(hWnd: ?*anyopaque, hDC: *anyopaque) callconv(.winapi) c_int;

extern "shell32" fn DragAcceptFiles(hWnd: HWND, fAccept: BOOL) callconv(.winapi) void;
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: c_int,
) callconv(.winapi) isize;

extern "gdi32" fn GetDeviceCaps(hdc: *anyopaque, nIndex: c_int) callconv(.winapi) c_int;
extern "gdi32" fn DeleteObject(ho: *anyopaque) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Global application state
// ---------------------------------------------------------------------------

var g_state: state.AppState = .{};
var g_hinstance: ?*anyopaque = null;
threadlocal var license_message_buf: [512]u8 = .{0} ** 512;

fn cStringSlice(buf: []const u8) ?[]const u8 {
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    if (len == 0) return null;
    return buf[0..len];
}

fn copyCString(dest: anytype, src: []const u8) void {
    @memset(dest, 0);
    const n = @min(src.len, dest.len - 1);
    @memcpy(dest[0..n], src[0..n]);
}

fn profileDisplayName(profile_id: bridge.RtmifyProfile) []const u8 {
    return switch (profile_id) {
        .generic => "Generic",
        .medical => "Medical",
        .aerospace => "Aerospace",
        .automotive => "Automotive",
    };
}

fn summaryProfile(summary: bridge.RtmifyAnalysisSummary) bridge.RtmifyProfile {
    return switch (summary.profile) {
        1 => .medical,
        2 => .aerospace,
        3 => .automotive,
        else => .generic,
    };
}

fn setLoadStatus(hwnd: HWND) void {
    var msg_buf: [160]u8 = undefined;
    const message = std.fmt.bufPrintZ(&msg_buf, "Analyzing workbook for {s} profile...", .{
        profileDisplayName(g_state.selected_profile),
    }) catch "Analyzing workbook...";
    ui.setStatusText(hwnd, message);
}

fn beginLoad(hwnd: HWND, path: []const u8) void {
    if (g_state.graph) |g| {
        bridge.rtmify_free(g);
        g_state.graph = null;
    }
    g_state.summary = null;
    g_state.result = null;
    g_state.tag = .drop_zone;
    ui.updateVisibility(.drop_zone);
    setLoadStatus(hwnd);
    bridge.spawnLoad(hwnd, path, g_state.selected_profile);
    _ = InvalidateRect(hwnd, null, 1);
}

fn applyAnalysisSummary(summary: *state.FileSummary, raw: bridge.RtmifyAnalysisSummary) void {
    summary.profile = summaryProfile(raw);
    copyCString(&summary.profile_display_name, cStringSlice(&raw.profile_display_name) orelse profileDisplayName(summary.profile));
    copyCString(&summary.profile_standards, cStringSlice(&raw.profile_standards) orelse "Generic");
    summary.generic_gap_count = raw.generic_gap_count;
    summary.profile_gap_count = raw.profile_gap_count;
    summary.total_gap_count = raw.total_gap_count;
    summary.warning_count = raw.warning_count;
}

fn shortFingerprint(buf: []const u8) ?[]const u8 {
    const value = cStringSlice(buf) orelse return null;
    return value[0..@min(value.len, 12)];
}

fn licenseStatusMessage(status: bridge.RtmifyLicenseStatus) [*:0]const u8 {
    const message = switch (status.detail_code) {
        1 => "One full free run is available. The first successful report will consume it.",
        2 => "Your free Trace run has been used. Import a signed license file or place it at ~/.rtmify/license.json.",
        3 => "No license file found. Import a signed license file or place it at ~/.rtmify/license.json.",
        5 => blk: {
            if (shortFingerprint(&status.license_signing_key_fingerprint)) |file_fp| {
                if (shortFingerprint(&status.expected_key_fingerprint)) |expected_fp| {
                    break :blk std.fmt.bufPrintZ(
                        &license_message_buf,
                        "This license was signed with key {s}, but this build expects {s}.",
                        .{ file_fp, expected_fp },
                    ) catch "This license signature does not match this build.";
                }
            }
            if (shortFingerprint(&status.expected_key_fingerprint)) |expected_fp| {
                break :blk std.fmt.bufPrintZ(
                    &license_message_buf,
                    "This build expects licenses signed with key {s}.",
                    .{expected_fp},
                ) catch "This license signature does not match this build.";
            }
            break :blk "This license signature does not match this build.";
        },
        6 => "This license file is for a different RTMify product.",
        8 => "The installed license file has expired.",
        else => "Import a signed RTMify Trace license file to unlock the app.",
    };
    return @ptrCast(message.ptr);
}

// ---------------------------------------------------------------------------
// UTF-16 string helpers
// ---------------------------------------------------------------------------

fn makeW(comptime s: []const u8) [s.len:0]u16 {
    comptime {
        var buf: [s.len:0]u16 = undefined;
        for (s, 0..) |c, i| buf[i] = c;
        return buf;
    }
}

// Returns a static [*:0]const u16 pointer valid for the life of the program.
fn toUtf16Z(comptime s: []const u8) [*:0]const u16 {
    const W = struct {
        const data: [s.len:0]u16 = makeW(s);
    };
    return &W.data;
}

fn utf8ToW(utf8: []const u8, buf: []u16) []u16 {
    return std.unicode.utf8ToUtf16Le(buf, utf8) catch buf[0..0];
}

// ---------------------------------------------------------------------------
// Shell execute helpers
// ---------------------------------------------------------------------------

fn shellOpen(path_utf8: []const u8) void {
    var w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&w, path_utf8) catch return;
    _ = ShellExecuteW(null, toUtf16Z("open"), &w, null, null, SW_SHOW);
}

fn shellShowInExplorer(path_utf8: []const u8) void {
    // Explorer /select,path highlights the file in Explorer
    var w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&w, path_utf8) catch return;
    var arg_buf: [1024]u8 = undefined;
    const arg = std.fmt.bufPrint(&arg_buf, "/select,\"{s}\"", .{path_utf8}) catch return;
    var arg_w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&arg_w, arg) catch return;
    _ = ShellExecuteW(null, null, toUtf16Z("explorer.exe"), &arg_w, null, SW_SHOW);
}

// ---------------------------------------------------------------------------
// State transitions
// ---------------------------------------------------------------------------

fn transitionToDropZone(hwnd: HWND) void {
    if (g_state.graph) |g| {
        bridge.rtmify_free(g);
        g_state.graph = null;
    }
    g_state.summary = null;
    g_state.result = null;
    g_state.tag = .drop_zone;
    ui.updateVisibility(.drop_zone);
    _ = InvalidateRect(hwnd, null, 1);
}

fn transitionToFileLoaded(hwnd: HWND, load_result: *const bridge.LoadResult) void {
    var summary = state.FileSummary{};
    const path_utf8 = std.mem.sliceTo(&load_result.path_utf8, 0);
    const n = @min(path_utf8.len, 1023);
    @memcpy(summary.path_utf8[0..n], path_utf8[0..n]);

    const base = std.fs.path.basename(path_utf8);
    const bn = @min(base.len, 255);
    @memcpy(summary.display_name[0..bn], base[0..bn]);
    applyAnalysisSummary(&summary, load_result.summary);

    g_state.graph = load_result.graph;
    g_state.summary = summary;
    g_state.selected_profile = summary.profile;
    g_state.tag = .file_loaded;
    ui.updateVisibility(.file_loaded);
    _ = InvalidateRect(hwnd, null, 1);
}

fn transitionToDone(hwnd: HWND, result: state.GenerateResult) void {
    g_state.result = result;
    g_state.tag = .done;
    ui.updateVisibility(.done);

    // Build output text
    var out_msg_buf: [4096]u8 = undefined;
    var out_msg: []u8 = out_msg_buf[0..0];

    var i: usize = 0;
    while (i < result.path_count) : (i += 1) {
        const p = std.mem.sliceTo(&result.output_paths[i], 0);
        out_msg = std.fmt.bufPrint(&out_msg_buf, "{s}{s}\r\n", .{ out_msg, p }) catch out_msg;
    }
    out_msg = std.fmt.bufPrint(&out_msg_buf, "Profile: {s}\r\nStandards: {s}\r\n\r\n{s}", .{
        std.mem.sliceTo(&result.profile_display_name, 0),
        std.mem.sliceTo(&result.profile_standards, 0),
        out_msg,
    }) catch out_msg;
    if (result.total_gap_count > 0) {
        if (result.profile_gap_count > 0) {
            out_msg = std.fmt.bufPrint(&out_msg_buf, "{s}\r\n\r\n{d} gaps flagged ({d} generic, {d} profile-specific).", .{
                out_msg,
                result.total_gap_count,
                result.generic_gap_count,
                result.profile_gap_count,
            }) catch out_msg;
        } else {
            out_msg = std.fmt.bufPrint(&out_msg_buf, "{s}\r\n\r\n{d} traceability gap{s} flagged in report.", .{
                out_msg,
                result.total_gap_count,
                if (result.total_gap_count == 1) "" else "s",
            }) catch out_msg;
        }
    }
    if (result.warning_count > 0) {
        out_msg = std.fmt.bufPrint(&out_msg_buf, "{s}\r\n{d} warning{s} during analysis.", .{
            out_msg,
            result.warning_count,
            if (result.warning_count == 1) "" else "s",
        }) catch out_msg;
    }

    ui.setOutputText(out_msg);
    _ = InvalidateRect(hwnd, null, 1);
}

// ---------------------------------------------------------------------------
// handleGenerate — build context and spawn worker
// ---------------------------------------------------------------------------

fn handleGenerate(hwnd: HWND) void {
    const graph = g_state.graph orelse return;
    const summary = g_state.summary orelse return;
    const fmt = ui.getSelectedFormat();

    const path_utf8 = std.mem.sliceTo(&summary.path_utf8, 0);
    var proj_buf: [256]u8 = undefined;
    const proj = state.projectName(path_utf8, &proj_buf);

    var fmts: [3][]const u8 = undefined;
    var paths: [3][]const u8 = undefined;
    var path_storage: [3][1024]u8 = undefined;
    var count: usize = 0;

    var result = state.GenerateResult{};

    if (fmt == .all) {
        const all_fmts = [_][]const u8{ "pdf", "docx", "md" };
        for (all_fmts, 0..) |f, fi| {
            fmts[fi] = f;
            const out = state.outputPath(path_utf8, f, &path_storage[fi]);
            paths[fi] = out;
            const on = @min(out.len, 1023);
            @memcpy(result.output_paths[fi][0..on], out[0..on]);
        }
        count = 3;
    } else {
        const fstr = state.formatSlice(fmt);
        fmts[0] = fstr;
        const out = state.outputPath(path_utf8, fstr, &path_storage[0]);
        paths[0] = out;
        const on = @min(out.len, 1023);
        @memcpy(result.output_paths[0][0..on], out[0..on]);
        count = 1;
    }

    result.path_count = count;
    result.profile = summary.profile;
    result.profile_display_name = summary.profile_display_name;
    result.profile_standards = summary.profile_standards;
    result.generic_gap_count = summary.generic_gap_count;
    result.profile_gap_count = summary.profile_gap_count;
    result.total_gap_count = summary.total_gap_count;
    result.warning_count = summary.warning_count;

    // Store result in state (worker will complete it via WM_GENERATE_COMPLETE)
    g_state.result = result;

    // Update UI to "generating" state
    g_state.tag = .generating;
    ui.updateVisibility(.generating);
    if (ui.generate_btn) |b| _ = SetWindowTextW(b, toUtf16Z("Generating\xe2\x80\xa6"));

    bridge.spawnGenerate(hwnd, graph, fmts[0..count], paths[0..count], proj);
}

// ---------------------------------------------------------------------------
// WndProc — main window message handler
// ---------------------------------------------------------------------------

fn wndProc(hwnd: ?*anyopaque, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const hw = hwnd orelse return DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        WM_CREATE => {
            ui.createControls(hw, g_hinstance orelse hw);
            ui.setFont(hw);
            DragAcceptFiles(hw, 1);
            // Check license on startup
            var lic_status: bridge.RtmifyLicenseStatus = undefined;
            const rc = bridge.rtmify_trace_license_get_status(&lic_status);
            if (rc == 0 and lic_status.permits_use != 0) {
                g_state.tag = .drop_zone;
            } else {
                g_state.tag = .license_gate;
                g_state.has_activation_error = true;
                ui.setActivationError(licenseStatusMessage(lic_status));
            }
            ui.updateVisibility(g_state.tag);
            return 0;
        },

        WM_DESTROY => {
            if (g_state.graph) |g| bridge.rtmify_free(g);
            if (ui.g_hfont) |f| _ = DeleteObject(f);
            PostQuitMessage(0);
            return 0;
        },

        WM_PAINT => {
            ui.paint(hw, &g_state);
            return 0;
        },

        WM_DROPFILES => {
            const h_drop: *anyopaque = @ptrFromInt(wparam);
            drop.handleDrop(hw, h_drop, &uiSetStatus, &bridgeSpawnLoad);
            return 0;
        },

        WM_DPICHANGED => {
            // lParam = pointer to RECT with suggested new window position/size
            const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowPos(hw, HWND_TOP,
                suggested.left, suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            return 0;
        },

        WM_CTLCOLORSTATIC => {
            // Color the activation error label red
            const ctrl_hwnd: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (ctrl_hwnd != null and ctrl_hwnd == ui.activ_err) {
                const hdc: *anyopaque = @ptrFromInt(wparam);
                _ = SetTextColor(hdc, 0x000000CC);
                return @bitCast(@intFromPtr(GetSysColorBrush(COLOR_BTNFACE)));
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        WM_COMMAND => {
            const ctrl_id = wparam & 0xFFFF;
            const notify_code = (wparam >> 16) & 0xFFFF;
            switch (ctrl_id) {
                ui.IDC_IMPORT_LICENSE_BTN => handleImportLicense(hw),
                ui.IDC_CLEAR_LICENSE_BTN => handleClearLicense(hw),
                ui.IDC_PROFILE_COMBO => if (notify_code == CBN_SELCHANGE) handleProfileChange(hw),
                ui.IDC_BROWSE_BTN => handleBrowse(hw),
                ui.IDC_GENERATE_BTN => handleGenerate(hw),
                ui.IDC_CLEAR_BTN => transitionToDropZone(hw),
                ui.IDC_SHOW_BTN => handleShowInExplorer(),
                ui.IDC_OPEN_BTN => handleOpenFile(),
                ui.IDC_AGAIN_BTN => transitionToDropZone(hw),
                else => {},
            }
            return 0;
        },

        bridge.WM_LOAD_COMPLETE => {
            const load_result: *bridge.LoadResult = @ptrFromInt(@as(usize, @bitCast(lparam)));
            defer std.heap.page_allocator.destroy(load_result);
            if (load_result.status == bridge.RTMIFY_OK and load_result.graph != null) {
                transitionToFileLoaded(hw, load_result);
            } else {
                dialogs.showError(hw, &load_result.error_message);
                g_state.tag = .drop_zone;
                ui.updateVisibility(.drop_zone);
                _ = InvalidateRect(hw, null, 1);
            }
        },

        bridge.WM_GENERATE_COMPLETE => {
            const generate_result: *bridge.GenerateResult = @ptrFromInt(@as(usize, @bitCast(lparam)));
            defer std.heap.page_allocator.destroy(generate_result);
            // Restore button text
            if (ui.generate_btn) |b| _ = SetWindowTextW(b, toUtf16Z("Generate"));
            if (generate_result.status == bridge.RTMIFY_OK) {
                _ = bridge.recordSuccessfulUse();
                if (g_state.result) |r| {
                    transitionToDone(hw, r);
                }
            } else {
                dialogs.showError(hw, &generate_result.error_message);
                g_state.tag = .file_loaded;
                ui.updateVisibility(.file_loaded);
                _ = InvalidateRect(hw, null, 1);
            }
        },

        bridge.WM_LICENSE_COMPLETE => {
            const license_result: *bridge.LicenseInstallResult = @ptrFromInt(@as(usize, @bitCast(lparam)));
            defer std.heap.page_allocator.destroy(license_result);
            if (ui.import_license_btn) |b| _ = SetWindowTextW(b, toUtf16Z("Import License File"));
            if (ui.import_license_btn) |b| _ = EnableWindow(b, 1);
            if (license_result.status == bridge.RTMIFY_OK) {
                g_state.has_activation_error = false;
                ui.setActivationError("");
                if (ui.activ_err) |c| _ = ShowWindow(c, SW_HIDE);
                g_state.tag = .drop_zone;
                ui.updateVisibility(.drop_zone);
                _ = InvalidateRect(hw, null, 1);
            } else {
                g_state.has_activation_error = true;
                ui.setActivationError(&license_result.error_message);
            }
        },

        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

// ---------------------------------------------------------------------------
// WM_COMMAND handlers
// ---------------------------------------------------------------------------

fn handleImportLicense(hwnd: HWND) void {
    var path_buf: [1024]u8 = undefined;
    const path = dialogs.browseLicenseJson(hwnd, &path_buf) orelse return;
    if (ui.import_license_btn) |b| {
        _ = SetWindowTextW(b, toUtf16Z("Importing\xe2\x80\xa6"));
        _ = EnableWindow(b, 0);
    }
    bridge.spawnInstallLicense(hwnd, path);
}

fn handleClearLicense(hwnd: HWND) void {
    if (!bridge.clearLicense()) {
        dialogs.showError(hwnd, bridge.rtmify_last_error());
        return;
    }
    var status: bridge.RtmifyLicenseStatus = undefined;
    _ = bridge.rtmify_trace_license_get_status(&status);
    g_state.has_activation_error = true;
    ui.setActivationError(licenseStatusMessage(status));
    g_state.tag = .license_gate;
    ui.updateVisibility(.license_gate);
    _ = InvalidateRect(hwnd, null, 1);
}

extern "user32" fn EnableWindow(hWnd: *anyopaque, bEnable: BOOL) callconv(.winapi) BOOL;

fn handleBrowse(hwnd: HWND) void {
    var path_buf: [1024]u8 = undefined;
    const path = dialogs.browseXlsx(hwnd, &path_buf) orelse return;
    beginLoad(hwnd, path);
}

fn handleProfileChange(hwnd: HWND) void {
    const selected = ui.getSelectedProfile();
    if (g_state.tag == .generating) {
        ui.setSelectedProfile(g_state.selected_profile);
        return;
    }
    if (g_state.selected_profile == selected) return;
    g_state.selected_profile = selected;
    if (g_state.summary) |summary| {
        beginLoad(hwnd, std.mem.sliceTo(&summary.path_utf8, 0));
    } else {
        _ = InvalidateRect(hwnd, null, 1);
    }
}

fn handleShowInExplorer() void {
    const result = g_state.result orelse return;
    if (result.path_count == 0) return;
    const first = std.mem.sliceTo(&result.output_paths[0], 0);
    shellShowInExplorer(first);
}

fn handleOpenFile() void {
    const result = g_state.result orelse return;
    if (result.path_count == 0) return;
    const first = std.mem.sliceTo(&result.output_paths[0], 0);
    shellOpen(first);
}

// ---------------------------------------------------------------------------
// Adapter callbacks for drop.zig (avoid circular imports)
// ---------------------------------------------------------------------------

fn uiSetStatus(hwnd: HWND, msg: [*:0]const u8) void {
    ui.setStatusText(hwnd, msg);
}

fn bridgeSpawnLoad(hwnd: HWND, path: []const u8) void {
    beginLoad(hwnd, path);
}

// ---------------------------------------------------------------------------
// wWinMain — entry point for .windows subsystem
// ---------------------------------------------------------------------------

pub export fn wWinMain(
    hInstance: *anyopaque,
    _: ?*anyopaque,
    _: [*:0]u16,
    nCmdShow: c_int,
) callconv(.winapi) c_int {
    g_hinstance = hInstance;

    // Window class
    const cls_name = toUtf16Z("RTMifyTraceWnd");
    var wc = WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0x0003, // CS_HREDRAW | CS_VREDRAW
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hInstance,
        .hIcon = LoadIconW(null, 32512), // IDI_APPLICATION = 32512
        .hCursor = LoadCursorW(null, 32512), // IDC_ARROW = 32512
        .hbrBackground = GetSysColorBrush(COLOR_BTNFACE),
        .lpszMenuName = null,
        .lpszClassName = cls_name,
        .hIconSm = null,
    };
    _ = RegisterClassExW(&wc);

    // Fixed-size window: overlapped without resize/maximize
    const win_style = (WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX) & ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    const hwnd_opt = CreateWindowExW(
        0,
        cls_name,
        toUtf16Z("RTMify Trace"),
        win_style,
        CW_USEDEFAULT, CW_USEDEFAULT,
        480, 520,
        null, null,
        hInstance,
        null,
    );

    const hwnd = hwnd_opt orelse return 1;

    _ = ShowWindow(hwnd, nCmdShow);
    _ = UpdateWindow(hwnd);

    // Message loop
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    return @intCast(msg.wParam & 0xFFFFFFFF);
}
