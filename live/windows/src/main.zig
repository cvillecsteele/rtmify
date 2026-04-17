// main.zig — wWinMain entry point for RTMify Live Windows tray shell.

const std = @import("std");
const state_mod = @import("state.zig");
const process_mod = @import("process.zig");
const lifecycle_mod = @import("lifecycle.zig");
const license_mod = @import("license_gate.zig");
const tray_mod = @import("tray_menu.zig");
const status_probe = @import("status_probe.zig");

const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const HICON = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = u32;
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
    uTimeout: UINT,
    szInfoTitle: [64]u16,
    dwInfoFlags: DWORD,
    guidItem: [16]u8,
    hBalloonIcon: ?*anyopaque,
};

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD, lpClassName: [*:0]const u16, lpWindowName: [*:0]const u16,
    dwStyle: DWORD, X: i32, Y: i32, nWidth: i32, nHeight: i32,
    hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn MessageBoxW(
    hWnd: ?HWND,
    lpText: [*:0]const u16,
    lpCaption: [*:0]const u16,
    uType: UINT,
) callconv(.winapi) c_int;
extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.winapi) BOOL;
extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: [*:0]const u16) callconv(.winapi) ?HICON;
extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpdata: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
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
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) i32;

const NIM_ADD: DWORD = 0;
const NIM_DELETE: DWORD = 2;
const NIF_MESSAGE: UINT = 0x01;
const NIF_ICON: UINT = 0x02;
const NIF_TIP: UINT = 0x04;
const IDI_APPLICATION: usize = 32512;
const WM_APP: UINT = 0x8000;
const WM_TRAYICON: UINT = WM_APP + 1;
const WM_LICENSE_CHANGED: UINT = WM_APP + 2;
const WM_STARTUP_COMPLETE: UINT = WM_APP + 3;
const WM_DESTROY: UINT = 0x0002;
const WM_TIMER: UINT = 0x0113;
const WM_COMMAND: UINT = 0x0111;
const TIMER_STATUS: usize = 1;
const TIMER_INTERVAL_MS: UINT = 5_000;
const STARTUP_TIMEOUT_MS: u64 = 10_000;
const STARTUP_INTERVAL_MS: u64 = 250;

const HKEY_CURRENT_USER: usize = 0x80000001;
const KEY_SET_VALUE: DWORD = 0x0002;
const KEY_QUERY_VALUE: DWORD = 0x0001;
const REG_SZ: DWORD = 1;
const ERROR_SUCCESS: c_long = 0;
const COINIT_APARTMENTTHREADED: DWORD = 0x2;
const MB_OK: UINT = 0x00000000;
const MB_ICONERROR: UINT = 0x00000010;

const StartupSpawnError = error{
    OutOfMemory,
    ThreadSpawnFailed,
};

const StartupResult = struct {
    seq: usize = 0,
    user_initiated: bool = false,
    started: bool = false,
    error_message: [256:0]u8 = std.mem.zeroes([256:0]u8),
};

const StartupContext = struct {
    hwnd: HWND,
    port: u16,
    result: StartupResult = .{},
};

fn W(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

var g_hinstance: HINSTANCE = undefined;
var g_hwnd: HWND = undefined;
var g_srv_state: state_mod.ServerState = .stopped;
var g_license_permits_use: bool = false;
var g_launch_at_login: bool = false;
var g_port: u16 = 8000;
var g_cfg: state_mod.Config = .{};
var g_startup_seq = std.atomic.Value(usize).init(0);

const RUN_KEY = W("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run");
const APP_NAME = W("RTMify Live");

fn setServerError(msg: []const u8) void {
    @memset(&g_cfg.server_error, 0);
    const len = @min(msg.len, g_cfg.server_error.len - 1);
    @memcpy(g_cfg.server_error[0..len], msg[0..len]);
}

fn copyCString(dest: anytype, src: []const u8) void {
    @memset(dest, 0);
    const len = @min(src.len, dest.len - 1);
    @memcpy(dest[0..len], src[0..len]);
}

fn clearServerError() void {
    @memset(&g_cfg.server_error, 0);
}

fn showFatalError(msg: []const u8) void {
    var msg_buf: [512]u16 = undefined;
    _ = MessageBoxW(null, toUtf16Message(msg, &msg_buf), W("RTMify Live"), MB_OK | MB_ICONERROR);
}

fn nextStartupSeq() usize {
    return g_startup_seq.fetchAdd(1, .seq_cst) + 1;
}

fn cancelPendingStartup() void {
    _ = g_startup_seq.fetchAdd(1, .seq_cst);
}

fn startupStillRelevant(seq: usize) bool {
    return g_startup_seq.load(.seq_cst) == seq;
}

fn toUtf16Message(text: []const u8, buf: []u16) [*:0]const u16 {
    @memset(buf, 0);
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch 0;
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

fn setLaunchAtLogin(enable: bool) bool {
    var hkey: usize = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, &hkey) != ERROR_SUCCESS) return false;
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
        return RegSetValueExW(hkey, APP_NAME, 0, REG_SZ, bytes, byte_len) == ERROR_SUCCESS;
    } else {
        return RegDeleteValueW(hkey, APP_NAME) == ERROR_SUCCESS;
    }
}

fn checkLaunchAtLogin() bool {
    var hkey: usize = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_QUERY_VALUE, &hkey) != ERROR_SUCCESS) return false;
    defer _ = RegCloseKey(hkey);
    var cb: DWORD = 0;
    return RegQueryValueExW(hkey, APP_NAME, null, null, null, &cb) == ERROR_SUCCESS;
}

fn trayIcon(hwnd: HWND, msg: DWORD) bool {
    var nid: NOTIFYICONDATAW = std.mem.zeroes(NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon = LoadIconW(null, @ptrFromInt(IDI_APPLICATION));
    const tip = W("RTMify Live");
    @memcpy(nid.szTip[0..tip.len], tip);
    return Shell_NotifyIconW(msg, &nid) != 0;
}

fn openDashboard(hwnd: HWND) void {
    var url_buf: [64]u8 = undefined;
    const url_utf8 = std.fmt.bufPrintZ(&url_buf, "http://127.0.0.1:{d}", .{g_port}) catch {
        setServerError("Failed to build dashboard URL");
        return;
    };
    var url_wide: [64:0]u16 = std.mem.zeroes([64:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&url_wide, url_utf8) catch {
        setServerError("Failed to open dashboard in browser");
        return;
    };
    if (ShellExecuteW(hwnd, W("open"), &url_wide, null, null, 1) <= 32) {
        setServerError("Failed to open dashboard in browser");
    }
}

fn startupErrorMessage(err: process_mod.SpawnServerError) []const u8 {
    return switch (err) {
        .already_running => "Server already running",
        .server_binary_missing => "Server binary not found beside RTMify Live.exe",
        .localappdata_missing => "LOCALAPPDATA is not available",
        .data_dir_create_failed => "Failed to create RTMify Live data directory",
        .log_open_failed => "Failed to open Windows server log file",
        .command_line_too_long => "Failed to build server command line",
        .env_setup_failed => "Failed to prepare child environment",
        .spawn_failed => "Failed to spawn rtmify-live.exe",
    };
}

fn startupThreadFailureMessage(err: StartupSpawnError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "Not enough memory to start RTMify Live",
        error.ThreadSpawnFailed => "Could not start RTMify Live. Please try again.",
    };
}

fn waitForStartupReady(seq: usize, port: u16, timeout_ms: u64, interval_ms: u64) bool {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (startupStillRelevant(seq) and std.time.milliTimestamp() < deadline) {
        if (status_probe.probeStatus(std.heap.page_allocator, port)) return true;
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }
    return false;
}

fn startupWorker(ctx: *StartupContext) void {
    if (!startupStillRelevant(ctx.result.seq)) {
        std.heap.page_allocator.destroy(ctx);
        return;
    }

    switch (process_mod.spawnServer(std.heap.page_allocator, ctx.port)) {
        .ok => {
            if (!startupStillRelevant(ctx.result.seq)) {
                process_mod.stopServer();
                std.heap.page_allocator.destroy(ctx);
                return;
            }

            if (!waitForStartupReady(ctx.result.seq, ctx.port, STARTUP_TIMEOUT_MS, STARTUP_INTERVAL_MS)) {
                if (!startupStillRelevant(ctx.result.seq)) {
                    process_mod.stopServer();
                    std.heap.page_allocator.destroy(ctx);
                    return;
                }

                if (process_mod.serverRunning()) {
                    process_mod.stopServer();
                    copyCString(&ctx.result.error_message, "Server did not become ready within 10s");
                } else {
                    copyCString(&ctx.result.error_message, "Server exited during startup");
                }
            } else {
                ctx.result.started = true;
            }
        },
        .err => |err| {
            if (!startupStillRelevant(ctx.result.seq)) {
                std.heap.page_allocator.destroy(ctx);
                return;
            }
            copyCString(&ctx.result.error_message, startupErrorMessage(err));
        },
    }

    if (PostMessageW(ctx.hwnd, WM_STARTUP_COMPLETE, 0, @bitCast(@intFromPtr(ctx))) == 0) {
        if (ctx.result.started) process_mod.stopServer();
        std.heap.page_allocator.destroy(ctx);
    }
}

fn spawnStartupWorker(hwnd: HWND, user_initiated: bool) StartupSpawnError!void {
    const ctx = std.heap.page_allocator.create(StartupContext) catch return error.OutOfMemory;
    ctx.* = .{
        .hwnd = hwnd,
        .port = g_port,
        .result = .{
            .seq = nextStartupSeq(),
            .user_initiated = user_initiated,
        },
    };
    const thread = std.Thread.spawn(.{}, startupWorker, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return error.ThreadSpawnFailed;
    };
    thread.detach();
}

fn startServer(hwnd: HWND, user_initiated: bool) void {
    if (g_srv_state == .running or g_srv_state == .starting) return;

    clearServerError();
    lifecycle_mod.handleStart(&g_srv_state);
    spawnStartupWorker(hwnd, user_initiated) catch |err| {
        setServerError(startupThreadFailureMessage(err));
        lifecycle_mod.handleStartupFailed(&g_srv_state);
    };
}

fn handleLicenseChanged(hwnd: HWND) void {
    const should_restart = g_srv_state == .running or g_srv_state == .starting;
    g_license_permits_use = license_mod.licensePermitsUse();

    cancelPendingStartup();
    _ = KillTimer(hwnd, TIMER_STATUS);
    clearServerError();
    lifecycle_mod.handleStop(&g_srv_state, process_mod.stopServer);

    if (should_restart) {
        startServer(hwnd, true);
    }
}

fn wndProc(hwnd: ?HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const h = hwnd orelse return DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        WM_TRAYICON => {
            const lword: UINT = @intCast(lparam & 0xFFFF);
            if (lword == 0x0205 or lword == 0x0204) {
                const cmd = tray_mod.showMenu(
                    h,
                    g_srv_state,
                    g_license_permits_use,
                    g_launch_at_login,
                    std.mem.sliceTo(&g_cfg.server_error, 0),
                );
                handleMenuCmd(h, cmd);
            }
        },
        WM_LICENSE_CHANGED => {
            handleLicenseChanged(h);
        },
        WM_STARTUP_COMPLETE => {
            const startup_ctx: *StartupContext = @ptrFromInt(@as(usize, @bitCast(lparam)));
            defer std.heap.page_allocator.destroy(startup_ctx);
            if (!startupStillRelevant(startup_ctx.result.seq) or g_srv_state != .starting) {
                return 0;
            }
            if (startup_ctx.result.started) {
                lifecycle_mod.handleStarted(&g_srv_state);
                _ = SetTimer(h, TIMER_STATUS, TIMER_INTERVAL_MS, null);
                if (startup_ctx.result.user_initiated) openDashboard(h);
            } else {
                setServerError(std.mem.sliceTo(&startup_ctx.result.error_message, 0));
                lifecycle_mod.handleStartupFailed(&g_srv_state);
            }
        },
        WM_TIMER => {
            if (wparam == TIMER_STATUS) {
                const was_running = g_srv_state == .running;
                lifecycle_mod.handleTimer(&g_srv_state, process_mod.serverRunning());
                if (was_running and g_srv_state == .@"error") {
                    setServerError("Server process terminated unexpectedly");
                    _ = KillTimer(h, TIMER_STATUS);
                    process_mod.stopServer();
                }
            }
        },
        WM_COMMAND => {
            const ctrl_id: c_int = @intCast(wparam & 0xFFFF);
            if (license_mod.g_license_hwnd != null) {
                license_mod.handleCommand(license_mod.g_license_hwnd.?, ctrl_id);
            }
        },
        WM_DESTROY => {
            cancelPendingStartup();
            _ = trayIcon(h, NIM_DELETE);
            _ = KillTimer(h, TIMER_STATUS);
            lifecycle_mod.handleDestroy(process_mod.stopServer);
            PostQuitMessage(0);
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

fn handleMenuCmd(hwnd: HWND, cmd: usize) void {
    switch (cmd) {
        tray_mod.CMD_OPEN_DASHBOARD => openDashboard(hwnd),
        tray_mod.CMD_START => startServer(hwnd, true),
        tray_mod.CMD_STOP => {
            cancelPendingStartup();
            _ = KillTimer(hwnd, TIMER_STATUS);
            clearServerError();
            lifecycle_mod.handleStop(&g_srv_state, process_mod.stopServer);
        },
        tray_mod.CMD_LICENSE => {
            license_mod.showLicenseDialog(g_hinstance, hwnd, g_port);
        },
        tray_mod.CMD_LAUNCH_AT_LOGIN => {
            const desired = !g_launch_at_login;
            if (setLaunchAtLogin(desired)) {
                g_launch_at_login = desired;
            } else {
                setServerError("Could not update Launch at Login setting");
            }
        },
        tray_mod.CMD_QUIT => {
            cancelPendingStartup();
            _ = KillTimer(hwnd, TIMER_STATUS);
            lifecycle_mod.handleQuit(process_mod.stopServer);
            _ = trayIcon(hwnd, NIM_DELETE);
            PostQuitMessage(0);
        },
        else => {},
    }
}

pub export fn wWinMain(
    hinstance: HINSTANCE,
    _: ?HINSTANCE,
    _: [*:0]u16,
    _: c_int,
) callconv(.winapi) c_int {
    g_hinstance = hinstance;
    _ = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    g_launch_at_login = checkLaunchAtLogin();
    g_cfg.port = g_port;
    g_license_permits_use = license_mod.licensePermitsUse();
    g_srv_state = .stopped;

    const class_name = W("RTMifyLiveTray");
    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.lpszClassName = class_name;
    if (RegisterClassExW(&wc) == 0) {
        showFatalError("Could not register the RTMify Live tray window class.");
        return 1;
    }

    const hwnd = CreateWindowExW(
        0,
        class_name,
        W("RTMify Live"),
        0,
        0,
        0,
        0,
        0,
        @ptrFromInt(@as(usize, @bitCast(@as(isize, -3)))),
        null,
        hinstance,
        null,
    ) orelse {
        showFatalError("Could not create the RTMify Live tray window.");
        return 1;
    };
    g_hwnd = hwnd;

    if (!trayIcon(hwnd, NIM_ADD)) {
        showFatalError("Could not create the RTMify Live tray icon.");
        return 1;
    }

    var msg_struct: MSG = undefined;
    while (GetMessageW(&msg_struct, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg_struct);
        _ = DispatchMessageW(&msg_struct);
    }
    return 0;
}
