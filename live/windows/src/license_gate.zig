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
const WS_BORDER: DWORD = 0x00800000;
const DS_CENTER: DWORD = 0x00000008;
const BS_DEFPUSHBUTTON: DWORD = 0x00000001;
const BS_PUSHBUTTON: DWORD = 0x00000000;
const SS_LEFT: DWORD = 0x00000000;
const ES_LEFT: DWORD = 0x0000;
const ES_MULTILINE: DWORD = 0x0004;
const ES_AUTOVSCROLL: DWORD = 0x0040;
const ES_READONLY: DWORD = 0x0800;
const WS_EX_DLGMODALFRAME: DWORD = 0x00000001;
const WS_EX_CLIENTEDGE: DWORD = 0x00000200;

const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_HIDEREADONLY: DWORD = 0x00000004;

const IDC_IMPORT_BTN: c_int = 1001;
const IDC_CLEAR_BTN: c_int = 1002;
const IDC_STATUS_LABEL: c_int = 1003;
const IDC_STATUS_BOX: c_int = 1004;
const IDCANCEL: c_int = 2;
const MB_OK: UINT = 0x00000000;
const MB_ICONERROR: UINT = 0x00000010;
const SPI_GETNONCLIENTMETRICS: UINT = 0x0029;
const WM_SETFONT: UINT = 0x0030;
const WM_APP: UINT = 0x8000;
const WM_LICENSE_CHANGED: UINT = WM_APP + 2;

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
extern "user32" fn MessageBoxW(
    hWnd: ?HWND,
    lpText: [*:0]const u16,
    lpCaption: [*:0]const u16,
    uType: UINT,
) callconv(.winapi) c_int;
extern "user32" fn SystemParametersInfoW(uAction: UINT, uParam: UINT, pvParam: *anyopaque, fWinIni: UINT) callconv(.winapi) BOOL;
extern "gdi32" fn CreateFontIndirectW(lplf: *const LOGFONTW) callconv(.winapi) ?*anyopaque;

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
extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) DWORD;

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

const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 400,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 1,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 2,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = std.mem.zeroes([32]u16),
};

const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT,
    iBorderWidth: i32,
    iScrollWidth: i32,
    iScrollHeight: i32,
    iCaptionWidth: i32,
    iCaptionHeight: i32,
    lfCaptionFont: LOGFONTW,
    iSmCaptionWidth: i32,
    iSmCaptionHeight: i32,
    lfSmCaptionFont: LOGFONTW,
    iMenuWidth: i32,
    iMenuHeight: i32,
    lfMenuFont: LOGFONTW,
    lfStatusFont: LOGFONTW,
    lfMessageFont: LOGFONTW,
    iPaddedBorderWidth: i32,
};

extern fn rtmify_last_error() [*:0]const u8;
extern fn rtmify_live_license_get_status(out_status: *RtmifyLicenseStatus) i32;
extern fn rtmify_live_license_install(path: [*:0]const u8, out_status: *RtmifyLicenseStatus) i32;
extern fn rtmify_live_license_clear(out_status: *RtmifyLicenseStatus) i32;

threadlocal var license_message_buf: [512]u8 = .{0} ** 512;
var g_dialog_font: ?*anyopaque = null;
var g_dialog_title_font: ?*anyopaque = null;

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
        3 => "No license file found. Live can run in preview mode, or you can install a signed RTMify Live license file at ~/.rtmify/license.json.",
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
        else => "Live can run in preview mode, or you can install a signed RTMify Live license file at ~/.rtmify/license.json.",
    };
}

fn licensePermitsUseForStatus(status: RtmifyLicenseStatus) bool {
    return status.permits_use != 0;
}

fn setStatusMessage(hwnd: HWND, msg: []const u8) void {
    var msg_buf: [512]u16 = undefined;
    _ = SetDlgItemTextW(hwnd, IDC_STATUS_BOX, toUtf16Message(msg, &msg_buf));
}

fn showDialogError(hwnd: ?HWND, msg: []const u8) void {
    var msg_buf: [512]u16 = undefined;
    _ = MessageBoxW(hwnd, toUtf16Message(msg, &msg_buf), W("RTMify Live"), MB_OK | MB_ICONERROR);
}

fn selectedPathToUtf8(buf: []u8, path_w: []const u16) ![]u8 {
    const nbytes = try std.unicode.utf16LeToUtf8(buf, path_w);
    return buf[0..nbytes];
}

fn requireControl(handle: ?HWND) error{ControlCreationFailed}!HWND {
    return handle orelse error.ControlCreationFailed;
}

fn ensureDialogFonts() void {
    if (g_dialog_font != null and g_dialog_title_font != null) return;

    var ncm: NONCLIENTMETRICSW = std.mem.zeroes(NONCLIENTMETRICSW);
    ncm.cbSize = @sizeOf(NONCLIENTMETRICSW);
    if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, ncm.cbSize, &ncm, 0) == 0) return;

    if (g_dialog_font == null) {
        g_dialog_font = CreateFontIndirectW(&ncm.lfMessageFont);
    }

    if (g_dialog_title_font == null) {
        var title_font = ncm.lfMessageFont;
        title_font.lfWeight = 700;
        title_font.lfHeight = @divTrunc(title_font.lfHeight * 5, 4);
        g_dialog_title_font = CreateFontIndirectW(&title_font);
    }
}

fn applyFont(control: HWND, font: ?*anyopaque) void {
    if (font) |hf| {
        _ = SendMessageW(control, WM_SETFONT, @intFromPtr(hf), 1);
    }
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
    if (GetOpenFileNameW(&ofn) == 0) {
        const err = CommDlgExtendedError();
        if (err != 0) {
            setStatusMessage(hwnd, "Could not open file dialog. Please try again.");
        }
        return null;
    }
    const wlen = std.mem.indexOfScalar(u16, &path_w, 0) orelse path_w.len;
    return selectedPathToUtf8(buf, path_w[0..wlen]) catch {
        setStatusMessage(hwnd, "Selected file path could not be read.");
        return null;
    };
}

pub fn showLicenseDialog(hInstance: HINSTANCE, notify_hwnd: HWND, port: u16) void {
    _ = port;
    ensureDialogFonts();

    const hwnd = CreateWindowExW(
        WS_EX_DLGMODALFRAME,
        W("#32770"),
        W("RTMify Live License"),
        WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_CENTER,
        100,
        100,
        520,
        330,
        notify_hwnd,
        null,
        hInstance,
        null,
    ) orelse {
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };

    const title = requireControl(CreateWindowExW(
        0,
        W("STATIC"),
        W("Preview Mode"),
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        24,
        20,
        300,
        26,
        hwnd,
        null,
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(title, g_dialog_title_font);

    const subtitle = requireControl(CreateWindowExW(
        0,
        W("STATIC"),
        W("RTMify Live can run without a license. Install a signed file to unlock locked features."),
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        24,
        54,
        460,
        36,
        hwnd,
        null,
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(subtitle, g_dialog_font);

    const hint = requireControl(CreateWindowExW(
        0,
        W("STATIC"),
        W("Without a license, preview mode keeps MCP, reports, repo scanning, code traceability, and background sync disabled."),
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        24,
        92,
        460,
        36,
        hwnd,
        null,
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(hint, g_dialog_font);

    const status_label = requireControl(CreateWindowExW(
        0,
        W("STATIC"),
        W("Status"),
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        24,
        136,
        120,
        18,
        hwnd,
        @ptrFromInt(IDC_STATUS_LABEL),
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(status_label, g_dialog_font);

    const status_box = requireControl(CreateWindowExW(
        WS_EX_CLIENTEDGE,
        W("EDIT"),
        W(""),
        WS_CHILD | WS_VISIBLE | WS_BORDER | ES_LEFT | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
        24,
        160,
        460,
        86,
        hwnd,
        @ptrFromInt(IDC_STATUS_BOX),
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(status_box, g_dialog_font);

    const import_button = requireControl(CreateWindowExW(
        0,
        W("BUTTON"),
        W("Install License File"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
        24,
        262,
        184,
        34,
        hwnd,
        @ptrFromInt(IDC_IMPORT_BTN),
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(import_button, g_dialog_font);

    const clear_button = requireControl(CreateWindowExW(
        0,
        W("BUTTON"),
        W("Clear Installed License"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        220,
        262,
        168,
        34,
        hwnd,
        @ptrFromInt(IDC_CLEAR_BTN),
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(clear_button, g_dialog_font);

    const cancel_button = requireControl(CreateWindowExW(
        0,
        W("BUTTON"),
        W("Cancel"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        396,
        262,
        88,
        30,
        hwnd,
        @ptrFromInt(IDCANCEL),
        hInstance,
        null,
    )) catch {
        _ = DestroyWindow(hwnd);
        showDialogError(notify_hwnd, "Could not create the RTMify Live license dialog.");
        return;
    };
    applyFont(cancel_button, g_dialog_font);

    var status: RtmifyLicenseStatus = undefined;
    if (rtmify_live_license_get_status(&status) == 0) {
        setStatusMessage(hwnd, licenseMessage(status));
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
                _ = SendMessageW(nwnd, WM_LICENSE_CHANGED, 0, 0);
            }
        } else {
            const msg = if (rc == 0) licenseMessage(status) else std.mem.span(rtmify_last_error());
            setStatusMessage(hwnd, msg);
        }
    } else if (ctrl_id == IDC_CLEAR_BTN) {
        var status: RtmifyLicenseStatus = undefined;
        const rc = rtmify_live_license_clear(&status);
        const msg = if (rc == 0) licenseMessage(status) else std.mem.span(rtmify_last_error());
        setStatusMessage(hwnd, msg);
        if (rc == 0) {
            if (g_notify_hwnd) |nwnd| {
                _ = SendMessageW(nwnd, WM_LICENSE_CHANGED, 0, 0);
            }
        }
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
        "No license file found. Live can run in preview mode, or you can install a signed RTMify Live license file at ~/.rtmify/license.json.",
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

test "selectedPathToUtf8 converts UTF-16 path" {
    var buf: [64]u8 = undefined;
    const path = [_]u16{ 'C', ':', '\\', 'l', 'i', 'c', 'e', 'n', 's', 'e', '.', 'j', 's', 'o', 'n' };
    const out = try selectedPathToUtf8(&buf, &path);
    try std.testing.expectEqualStrings("C:\\license.json", out);
}

test "selectedPathToUtf8 rejects invalid UTF-16" {
    var buf: [16]u8 = undefined;
    const invalid = [_]u16{0xD800};
    if (selectedPathToUtf8(&buf, &invalid)) |_| return error.ExpectedFailure else |_| {}
}

test "requireControl rejects null handle" {
    try std.testing.expectError(error.ControlCreationFailed, requireControl(null));
}
