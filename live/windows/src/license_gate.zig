const std = @import("std");

const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = u32;
const WORD = u16;
const LPARAM = isize;
const WPARAM = usize;
const LRESULT = isize;

const WS_CHILD: DWORD = 0x40000000;
const WS_VISIBLE: DWORD = 0x10000000;
const WS_TABSTOP: DWORD = 0x00010000;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_POPUP: DWORD = 0x80000000;
const DS_CENTER: DWORD = 0x00000008;
const BS_DEFPUSHBUTTON: DWORD = 0x00000001;
const BS_PUSHBUTTON: DWORD = 0x00000000;
const SS_LEFT: DWORD = 0x00000000;

const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_HIDEREADONLY: DWORD = 0x00000004;

const IDC_IMPORT_BTN: c_int = 1001;
const IDC_CLEAR_BTN: c_int = 1002;
const IDC_STATUS_LABEL: c_int = 1003;
const IDCANCEL: c_int = 2;

extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?*anyopaque,
    hInstance: ?*anyopaque,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

const OPENFILENAMEW = extern struct {
    lStructSize: DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?[*:0]const u16 = null,
    lpstrCustomFilter: ?[*:0]u16 = null,
    nMaxCustFilter: DWORD = 0,
    nFilterIndex: DWORD = 1,
    lpstrFile: ?[*:0]u16 = null,
    nMaxFile: DWORD = 0,
    lpstrFileTitle: ?[*:0]u16 = null,
    nMaxFileTitle: DWORD = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: DWORD = 0,
    nFileOffset: WORD = 0,
    nFileExtension: WORD = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,
};

extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;

const RtmifyLicenseStatus = extern struct {
    state: i32,
    permits_use: i32,
    using_free_run: i32,
    expires_at: i64,
    issued_at: i64,
    detail_code: i32,
    expected_key_fingerprint: [65]u8,
    license_signing_key_fingerprint: [65]u8,
};

extern fn rtmify_last_error() [*:0]const u8;
extern fn rtmify_live_license_get_status(out_status: *RtmifyLicenseStatus) i32;
extern fn rtmify_live_license_install(path: [*:0]const u8, out_status: *RtmifyLicenseStatus) i32;
extern fn rtmify_live_license_clear(out_status: *RtmifyLicenseStatus) i32;

threadlocal var license_message_buf: [512]u8 = .{0} ** 512;

fn W(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn toUtf16Message(text: []const u8, buf: []u16) [*:0]const u16 {
    @memset(buf, 0);
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch 0;
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

fn cStringSlice(buf: []const u8) ?[]const u8 {
    const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    if (len == 0) return null;
    return buf[0..len];
}

fn shortFingerprint(buf: []const u8) ?[]const u8 {
    const value = cStringSlice(buf) orelse return null;
    return value[0..@min(value.len, 12)];
}

fn licenseMessage(status: RtmifyLicenseStatus) []const u8 {
    return switch (status.detail_code) {
        3 => "No license file found. Import a signed RTMify Live license file or place it at ~/.rtmify/license.json.",
        5 => blk: {
            if (shortFingerprint(status.license_signing_key_fingerprint[0..])) |file_fp| {
                if (shortFingerprint(status.expected_key_fingerprint[0..])) |expected_fp| {
                    break :blk std.fmt.bufPrint(
                        &license_message_buf,
                        "This license was signed with key {s}, but this build expects {s}.",
                        .{ file_fp, expected_fp },
                    ) catch "This license signature does not match this build.";
                }
            }
            if (shortFingerprint(status.expected_key_fingerprint[0..])) |expected_fp| {
                break :blk std.fmt.bufPrint(
                    &license_message_buf,
                    "This build expects licenses signed with key {s}.",
                    .{expected_fp},
                ) catch "This license signature does not match this build.";
            }
            break :blk "This license signature does not match this build.";
        },
        6 => "This license file is for a different RTMify product.",
        8 => "The installed license file has expired.",
        else => "Import a signed RTMify Live license file, or place it manually at ~/.rtmify/license.json.",
    };
}

fn licensePermitsUseForStatus(status: RtmifyLicenseStatus) bool {
    return status.permits_use != 0;
}

fn browseLicenseJson(hwnd: HWND, buf: []u8) ?[]u8 {
    const filter = [_:0]u16{
        'L', 'i', 'c', 'e', 'n', 's', 'e', ' ', 'F', 'i', 'l', 'e', 's', 0,
        '*', '.', 'j', 's', 'o', 'n', 0,
        0,
    };
    var path_w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    var ofn = OPENFILENAMEW{
        .hwndOwner = hwnd,
        .lpstrFilter = &filter,
        .lpstrFile = &path_w,
        .nMaxFile = @intCast(path_w.len),
        .Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY,
        .lpstrDefExt = &[_:0]u16{ 'j', 's', 'o', 'n', 0 },
    };
    if (GetOpenFileNameW(&ofn) == 0) return null;
    const wlen = std.mem.indexOfScalar(u16, &path_w, 0) orelse path_w.len;
    const nbytes = std.unicode.utf16LeToUtf8(buf, path_w[0..wlen]) catch return null;
    return buf[0..nbytes];
}

pub fn showLicenseDialog(hInstance: HINSTANCE, notify_hwnd: HWND, port: u16) void {
    _ = port;

    const hwnd = CreateWindowExW(
        0,
        W("STATIC"),
        W("RTMify Live — Install License"),
        WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_CENTER,
        100,
        100,
        420,
        245,
        notify_hwnd,
        null,
        hInstance,
        null,
    ) orelse return;

    _ = CreateWindowExW(
        0,
        W("STATIC"),
        W("Import a signed license file, or place it at ~/.rtmify/license.json."),
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        20,
        20,
        380,
        68,
        hwnd,
        @ptrFromInt(IDC_STATUS_LABEL),
        hInstance,
        null,
    );

    _ = CreateWindowExW(
        0,
        W("BUTTON"),
        W("Import License File"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
        20,
        112,
        180,
        30,
        hwnd,
        @ptrFromInt(IDC_IMPORT_BTN),
        hInstance,
        null,
    );

    _ = CreateWindowExW(
        0,
        W("BUTTON"),
        W("Clear Installed License"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        220,
        112,
        180,
        30,
        hwnd,
        @ptrFromInt(IDC_CLEAR_BTN),
        hInstance,
        null,
    );

    _ = CreateWindowExW(
        0,
        W("BUTTON"),
        W("Cancel"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        140,
        165,
        140,
        30,
        hwnd,
        @ptrFromInt(IDCANCEL),
        hInstance,
        null,
    );

    var status: RtmifyLicenseStatus = undefined;
    if (rtmify_live_license_get_status(&status) == 0) {
        var msg_buf: [512]u16 = undefined;
        _ = SetDlgItemTextW(hwnd, IDC_STATUS_LABEL, toUtf16Message(licenseMessage(status), &msg_buf));
    }

    _ = ShowWindow(hwnd, 5);
    g_license_hwnd = hwnd;
    g_notify_hwnd = notify_hwnd;
}

pub var g_license_hwnd: ?HWND = null;
pub var g_notify_hwnd: ?HWND = null;

pub fn licensePermitsUse() bool {
    var status: RtmifyLicenseStatus = undefined;
    return rtmify_live_license_get_status(&status) == 0 and licensePermitsUseForStatus(status);
}

pub fn handleCommand(hwnd: HWND, ctrl_id: c_int) void {
    if (ctrl_id == IDC_IMPORT_BTN) {
        var path_buf: [1024]u8 = undefined;
        const path = browseLicenseJson(hwnd, &path_buf) orelse return;
        var path_z: [1025:0]u8 = std.mem.zeroes([1025:0]u8);
        @memcpy(path_z[0..path.len], path);

        var status: RtmifyLicenseStatus = undefined;
        const rc = rtmify_live_license_install(&path_z, &status);
        if (rc == 0 and status.permits_use != 0) {
            _ = DestroyWindow(hwnd);
            g_license_hwnd = null;
            if (g_notify_hwnd) |nwnd| {
                const WM_APP: UINT = 0x8000;
                _ = SendMessageW(nwnd, WM_APP + 2, 0, 0);
            }
        } else {
            var msg_buf: [512]u16 = undefined;
            const msg = if (rc == 0) licenseMessage(status) else std.mem.span(rtmify_last_error());
            _ = SetDlgItemTextW(hwnd, IDC_STATUS_LABEL, toUtf16Message(msg, &msg_buf));
        }
    } else if (ctrl_id == IDC_CLEAR_BTN) {
        var status: RtmifyLicenseStatus = undefined;
        const rc = rtmify_live_license_clear(&status);
        var msg_buf: [512]u16 = undefined;
        const msg = if (rc == 0) licenseMessage(status) else std.mem.span(rtmify_last_error());
        _ = SetDlgItemTextW(hwnd, IDC_STATUS_LABEL, toUtf16Message(msg, &msg_buf));
    } else if (ctrl_id == IDCANCEL) {
        if (g_license_hwnd) |lhwnd| {
            _ = DestroyWindow(lhwnd);
            g_license_hwnd = null;
        }
    }
}

test "license message describes missing file" {
    const status = RtmifyLicenseStatus{
        .state = 0,
        .permits_use = 0,
        .using_free_run = 0,
        .expires_at = -1,
        .issued_at = -1,
        .detail_code = 3,
        .expected_key_fingerprint = std.mem.zeroes([65]u8),
        .license_signing_key_fingerprint = std.mem.zeroes([65]u8),
    };
    try std.testing.expectEqualStrings(
        "No license file found. Import a signed RTMify Live license file or place it at ~/.rtmify/license.json.",
        licenseMessage(status),
    );
}

test "license message describes wrong product" {
    const status = RtmifyLicenseStatus{
        .state = 0,
        .permits_use = 0,
        .using_free_run = 0,
        .expires_at = -1,
        .issued_at = -1,
        .detail_code = 6,
        .expected_key_fingerprint = std.mem.zeroes([65]u8),
        .license_signing_key_fingerprint = std.mem.zeroes([65]u8),
    };
    try std.testing.expectEqualStrings(
        "This license file is for a different RTMify product.",
        licenseMessage(status),
    );
}

test "license permits use follows status bit" {
    try std.testing.expect(licensePermitsUseForStatus(.{
        .state = 0,
        .permits_use = 1,
        .using_free_run = 0,
        .expires_at = -1,
        .issued_at = -1,
        .detail_code = 0,
        .expected_key_fingerprint = std.mem.zeroes([65]u8),
        .license_signing_key_fingerprint = std.mem.zeroes([65]u8),
    }));
    try std.testing.expect(!licensePermitsUseForStatus(.{
        .state = 0,
        .permits_use = 0,
        .using_free_run = 0,
        .expires_at = -1,
        .issued_at = -1,
        .detail_code = 0,
        .expected_key_fingerprint = std.mem.zeroes([65]u8),
        .license_signing_key_fingerprint = std.mem.zeroes([65]u8),
    }));
}
