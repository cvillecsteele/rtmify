// license_gate.zig — Win32 dialog for license key entry.

const std = @import("std");
const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = u32;
const LPARAM = isize;
const WPARAM = usize;
const LRESULT = isize;

const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_INITDIALOG: UINT = 0x0110;

const WS_CHILD: DWORD = 0x40000000;
const WS_VISIBLE: DWORD = 0x10000000;
const WS_BORDER: DWORD = 0x00800000;
const WS_TABSTOP: DWORD = 0x00010000;
const WS_CAPTION: DWORD = 0x00C00000;
const WS_SYSMENU: DWORD = 0x00080000;
const WS_POPUP: DWORD = 0x80000000;
const DS_CENTER: DWORD = 0x00000008;
const ES_AUTOHSCROLL: DWORD = 0x0080;
const BS_DEFPUSHBUTTON: DWORD = 0x00000001;
const BS_PUSHBUTTON: DWORD = 0x00000000;
const SS_LEFT: DWORD = 0x00000000;

const IDC_KEY_EDIT: c_int = 1001;
const IDC_ACTIVATE_BTN: c_int = 1002;
const IDC_STATUS_LABEL: c_int = 1003;
const IDCANCEL: c_int = 2;

extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16,
    dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32,
    hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn GetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*:0]u16, nMaxCount: c_int) callconv(.winapi) UINT;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetDlgItem(hDlg: HWND, nIDDlgItem: c_int) callconv(.winapi) ?HWND;
extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: UINT) callconv(.winapi) c_int;

const MB_OK: UINT = 0x00000000;
const MB_ICONERROR: UINT = 0x00000010;

const RtmifyLicenseStatus = extern struct {
    state: i32,
    permits_use: i32,
    activated_at: i64,
    expires_at: i64,
    last_validated_at: i64,
    offline_grace_deadline: i64,
    detail_code: i32,
};

extern fn rtmify_last_error() [*:0]const u8;
extern fn rtmify_license_get_status(out_status: *RtmifyLicenseStatus) i32;
extern fn rtmify_license_activate(license_key: [*:0]const u8, out_status: *RtmifyLicenseStatus) i32;

fn W(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Show a modal license key dialog. Blocks until the user activates or cancels.
/// On successful activation, posts WM_APP+2 to `notify_hwnd`.
pub fn showLicenseDialog(hInstance: HINSTANCE, notify_hwnd: HWND, port: u16) void {
    _ = port;

    const hwnd = CreateWindowExW(
        0,
        W("STATIC"),
        W("RTMify Live — Activate License"),
        WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_CENTER,
        100, 100, 380, 200,
        notify_hwnd, null, hInstance, null,
    ) orelse return;

    // Label
    _ = CreateWindowExW(0, W("STATIC"), W("Enter your license key:"),
        WS_CHILD | WS_VISIBLE | SS_LEFT,
        20, 20, 340, 20,
        hwnd, @ptrFromInt(IDC_STATUS_LABEL), hInstance, null);

    // Edit
    _ = CreateWindowExW(WS_BORDER, W("EDIT"), W(""),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
        20, 50, 340, 28,
        hwnd, @ptrFromInt(IDC_KEY_EDIT), hInstance, null);

    // Activate button
    _ = CreateWindowExW(0, W("BUTTON"), W("Activate"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
        220, 100, 140, 30,
        hwnd, @ptrFromInt(IDC_ACTIVATE_BTN), hInstance, null);

    // Cancel button
    _ = CreateWindowExW(0, W("BUTTON"), W("Cancel"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        60, 100, 140, 30,
        hwnd, @ptrFromInt(IDCANCEL), hInstance, null);

    _ = ShowWindow(hwnd, 5); // SW_SHOW

    // Store references for the message handler
    g_license_hwnd = hwnd;
    g_notify_hwnd = notify_hwnd;
}

pub var g_license_hwnd: ?HWND = null;
pub var g_notify_hwnd: ?HWND = null;

pub fn licensePermitsUse() bool {
    var status: RtmifyLicenseStatus = undefined;
    return rtmify_license_get_status(&status) == 0 and status.permits_use != 0;
}

/// Handle WM_COMMAND in the license dialog.
pub fn handleCommand(hwnd: HWND, ctrl_id: c_int) void {
    if (ctrl_id == IDC_ACTIVATE_BTN) {
        var key_buf: [128:0]u16 = std.mem.zeroes([128:0]u16);
        _ = GetDlgItemTextW(hwnd, IDC_KEY_EDIT, &key_buf, 128);
        var key_utf8: [256]u8 = undefined;
        const key_wide_len = std.mem.indexOfSentinel(u16, 0, &key_buf);
        const key_len = std.unicode.utf16LeToUtf8(&key_utf8, key_buf[0..key_wide_len]) catch return;
        const key = key_utf8[0..key_len];
        if (key.len == 0) return;

        var key_z: [129:0]u8 = std.mem.zeroes([129:0]u8);
        @memcpy(key_z[0..key.len], key);
        var status: RtmifyLicenseStatus = undefined;
        const rc = rtmify_license_activate(&key_z, &status);
        if (rc == 0 and status.permits_use != 0) {
            _ = DestroyWindow(hwnd);
            g_license_hwnd = null;
            // Notify main window
            if (g_notify_hwnd) |nwnd| {
                const WM_APP: UINT = 0x8000;
                _ = SendMessageW(nwnd, WM_APP + 2, 0, 0);
            }
        } else {
            _ = rtmify_last_error();
            _ = SetDlgItemTextW(hwnd, IDC_STATUS_LABEL, W("Activation failed. Check key and internet."));
        }
    } else if (ctrl_id == IDCANCEL) {
        if (g_license_hwnd) |lhwnd| {
            _ = DestroyWindow(lhwnd);
            g_license_hwnd = null;
        }
    }
}
