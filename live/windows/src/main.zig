// main.zig — wWinMain entry point for RTMify Live Windows tray shell.
//
// Creates a message-only window, installs a Shell_NotifyIcon tray icon,
// and runs the message loop. The rtmify-live.exe server is spawned as a
// child process.

const std = @import("std");
const state_mod = @import("state.zig");
const process_mod = @import("process.zig");
const lifecycle_mod = @import("lifecycle.zig");
const license_mod = @import("license_gate.zig");
const tray_mod = @import("tray_menu.zig");

// ---------------------------------------------------------------------------
// Win32 types
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const HICON = *anyopaque;
const HANDLE = *anyopaque;
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

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
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

// NOTIFYICONDATAW (simplified for our use)
const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD,
    hWnd: ?HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?*anyopaque,
    szTip: [128]u16,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u16,
    uTimeout: UINT, // union field, also uVersion
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: [16]u8,
    hBalloonIcon: ?*anyopaque,
};

// ---------------------------------------------------------------------------
// Win32 imports
// ---------------------------------------------------------------------------

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16,
    dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32,
    hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.winapi) BOOL;
extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: [*:0]const u16) callconv(.winapi) ?HICON;
extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpdata: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: c_int,
) callconv(.winapi) isize;
extern "advapi32" fn RegOpenKeyExW(
    hKey: usize, lpSubKey: [*:0]const u16, ulOptions: DWORD, samDesired: DWORD, phkResult: *usize,
) callconv(.winapi) c_long;
extern "advapi32" fn RegSetValueExW(
    hKey: usize, lpValueName: [*:0]const u16, Reserved: DWORD, dwType: DWORD,
    lpData: [*]const u8, cbData: DWORD,
) callconv(.winapi) c_long;
extern "advapi32" fn RegDeleteValueW(hKey: usize, lpValueName: [*:0]const u16) callconv(.winapi) c_long;
extern "advapi32" fn RegQueryValueExW(
    hKey: usize, lpValueName: [*:0]const u16, lpReserved: ?*DWORD, lpType: ?*DWORD,
    lpData: ?[*]u8, lpcbData: ?*DWORD,
) callconv(.winapi) c_long;
extern "advapi32" fn RegCloseKey(hKey: usize) callconv(.winapi) c_long;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HWND_MESSAGE: isize = -3;
const NIM_ADD: DWORD = 0;
const NIM_MODIFY: DWORD = 1;
const NIM_DELETE: DWORD = 2;
const NIF_MESSAGE: UINT = 0x01;
const NIF_ICON: UINT = 0x02;
const NIF_TIP: UINT = 0x04;
const IDI_APPLICATION: usize = 32512;
const WM_APP: UINT = 0x8000;
const WM_TRAYICON: UINT = WM_APP + 1;
const WM_ACTIVATED: UINT = WM_APP + 2; // license activated
const WM_DESTROY: UINT = 0x0002;
const WM_TIMER: UINT = 0x0113;
const WM_COMMAND: UINT = 0x0111;
const TIMER_STATUS: usize = 1;
const TIMER_INTERVAL_MS: UINT = 30_000;

const HKEY_CURRENT_USER: usize = 0x80000001;
const KEY_SET_VALUE: DWORD = 0x0002;
const KEY_QUERY_VALUE: DWORD = 0x0001;
const REG_SZ: DWORD = 1;
const ERROR_SUCCESS: c_long = 0;

fn W(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

var g_hinstance: HINSTANCE = undefined;
var g_hwnd: HWND = undefined;
var g_srv_state: state_mod.ServerState = .stopped;
var g_launch_at_login: bool = false;
var g_port: u16 = 8000;

// ---------------------------------------------------------------------------
// Registry helpers for "Launch at Login"
// ---------------------------------------------------------------------------

const RUN_KEY = W("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run");
const APP_NAME = W("RTMify Live");

fn setLaunchAtLogin(enable: bool) void {
    var hkey: usize = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &hkey) != ERROR_SUCCESS) return;
    defer _ = RegCloseKey(hkey);
    if (enable) {
        var exe_buf: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
        _ = process_mod.exeDir(exe_buf[0..1023]);
        const suffix = W("RTMify Live.exe");
        var i: usize = 0;
        while (i < 1024 and exe_buf[i] != 0) : (i += 1) {}
        @memcpy(exe_buf[i .. i + suffix.len], suffix);
        exe_buf[i + suffix.len] = 0;
        const bytes: [*]const u8 = @ptrCast(&exe_buf);
        const byte_len: DWORD = @intCast((i + suffix.len + 1) * 2);
        _ = RegSetValueExW(hkey, APP_NAME, 0, REG_SZ, bytes, byte_len);
    } else {
        _ = RegDeleteValueW(hkey, APP_NAME);
    }
}

fn checkLaunchAtLogin() bool {
    var hkey: usize = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_QUERY_VALUE, &hkey) != ERROR_SUCCESS) return false;
    defer _ = RegCloseKey(hkey);
    var cb: DWORD = 0;
    return RegQueryValueExW(hkey, APP_NAME, null, null, null, &cb) == ERROR_SUCCESS;
}

// ---------------------------------------------------------------------------
// Tray icon management
// ---------------------------------------------------------------------------

fn trayIcon(hwnd: HWND, msg: DWORD) void {
    var nid: NOTIFYICONDATAW = std.mem.zeroes(NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon = LoadIconW(null, @ptrFromInt(IDI_APPLICATION));
    const tip = W("RTMify Live");
    @memcpy(nid.szTip[0..tip.len], tip);
    _ = Shell_NotifyIconW(msg, &nid);
}

// ---------------------------------------------------------------------------
// WndProc
// ---------------------------------------------------------------------------

fn wndProc(hwnd: ?HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const h = hwnd orelse return DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        WM_TRAYICON => {
            const lword: UINT = @intCast(lparam & 0xFFFF);
            // WM_RBUTTONUP = 0x0205
            if (lword == 0x0205 or lword == 0x0204) {
                const cmd = tray_mod.showMenu(h, g_srv_state, g_launch_at_login);
                handleMenuCmd(h, cmd);
            }
        },
        WM_ACTIVATED => {
            // License activated — start server and open dashboard
            if (g_srv_state != .running) {
                lifecycle_mod.handleStart(&g_srv_state, process_mod.spawnServer(g_port));
            }
            if (g_srv_state == .running) {
                var url_buf: [64]u8 = undefined;
                const url_utf8 = std.fmt.bufPrintZ(&url_buf, "http://localhost:{d}", .{g_port}) catch return 0;
                var url_wide: [64:0]u16 = std.mem.zeroes([64:0]u16);
                _ = std.unicode.utf8ToUtf16Le(&url_wide, url_utf8) catch {};
                _ = ShellExecuteW(hwnd, W("open"), &url_wide, null, null, 1);
            }
        },
        WM_TIMER => {
            if (wparam == TIMER_STATUS) {
                // Check if server process died
                lifecycle_mod.handleTimer(&g_srv_state, process_mod.serverRunning());
            }
        },
        WM_COMMAND => {
            const ctrl_id: c_int = @intCast(wparam & 0xFFFF);
            if (license_mod.g_license_hwnd != null) {
                license_mod.handleCommand(license_mod.g_license_hwnd.?, ctrl_id);
            }
        },
        WM_DESTROY => {
            trayIcon(h, NIM_DELETE);
            lifecycle_mod.handleDestroy(process_mod.stopServer);
            PostQuitMessage(0);
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

fn handleMenuCmd(hwnd: HWND, cmd: usize) void {
    switch (cmd) {
        tray_mod.CMD_OPEN_DASHBOARD => {
            var url_buf: [64]u8 = undefined;
            const url_utf8 = std.fmt.bufPrintZ(&url_buf, "http://localhost:{d}", .{g_port}) catch return;
            var url_wide: [64:0]u16 = std.mem.zeroes([64:0]u16);
            _ = std.unicode.utf8ToUtf16Le(&url_wide, url_utf8) catch return;
            _ = ShellExecuteW(hwnd, W("open"), &url_wide, null, null, 1);
        },
        tray_mod.CMD_START => {
            lifecycle_mod.handleStart(&g_srv_state, process_mod.spawnServer(g_port));
        },
        tray_mod.CMD_STOP => {
            lifecycle_mod.handleStop(&g_srv_state, process_mod.stopServer);
        },
        tray_mod.CMD_LICENSE => {
            license_mod.showLicenseDialog(g_hinstance, hwnd, g_port);
        },
        tray_mod.CMD_LAUNCH_AT_LOGIN => {
            g_launch_at_login = !g_launch_at_login;
            setLaunchAtLogin(g_launch_at_login);
        },
        tray_mod.CMD_QUIT => {
            lifecycle_mod.handleQuit(process_mod.stopServer);
            trayIcon(hwnd, NIM_DELETE);
            PostQuitMessage(0);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// wWinMain
// ---------------------------------------------------------------------------

pub export fn wWinMain(
    hinstance: HINSTANCE,
    _: ?HINSTANCE,
    _: [*:0]u16,
    _: c_int,
) callconv(.winapi) c_int {
    g_hinstance = hinstance;
    g_launch_at_login = checkLaunchAtLogin();

    // Check license by running --version (quick exit code check)
    const lic_ok = (process_mod.spawnActivate("") == 1); // --activate "" should fail fast
    _ = lic_ok;
    // We optimistically start — the server itself enforces the license check.
    // The tray will show .license_gate only if the server fails to start.

    // Register window class
    const class_name = W("RTMifyLiveTray");
    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.lpszClassName = class_name;
    _ = RegisterClassExW(&wc);

    // Create message-only window
    const hwnd = CreateWindowExW(
        0, class_name, W("RTMify Live"),
        0, 0, 0, 0, 0,
        @ptrFromInt(@as(usize, @bitCast(@as(isize, HWND_MESSAGE)))),
        null, hinstance, null,
    ) orelse return 1;
    g_hwnd = hwnd;

    // Install tray icon
    trayIcon(hwnd, NIM_ADD);

    // Start status check timer
    _ = SetTimer(hwnd, TIMER_STATUS, TIMER_INTERVAL_MS, null);

    // Auto-start server
    if (process_mod.spawnServer(g_port)) {
        g_srv_state = .running;
    } else {
        g_srv_state = .license_gate;
    }

    // Message loop
    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    return 0;
}
