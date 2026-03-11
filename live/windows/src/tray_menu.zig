// tray_menu.zig — System tray popup menu for rtmify-live.

const std = @import("std");
const state = @import("state.zig");
const HWND = *anyopaque;
const BOOL = c_int;
const UINT = c_uint;

const HMENU = *anyopaque;
const POINT = extern struct { x: i32, y: i32 };

extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: c_int, hWnd: HWND, prcRect: ?*anyopaque) callconv(.winapi) BOOL;
extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;

const MF_STRING: UINT = 0x00000000;
const MF_GRAYED: UINT = 0x00000001;
const MF_SEPARATOR: UINT = 0x00000800;
const MF_CHECKED: UINT = 0x00000008;
const TPM_RIGHTBUTTON: UINT = 0x0002;
const TPM_NONOTIFY: UINT = 0x0080;
const TPM_RETURNCMD: UINT = 0x0100;

pub const CMD_OPEN_DASHBOARD: usize = 1;
pub const CMD_START: usize = 2;
pub const CMD_STOP: usize = 3;
pub const CMD_LICENSE: usize = 4;
pub const CMD_LAUNCH_AT_LOGIN: usize = 5;
pub const CMD_QUIT: usize = 6;

fn W(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

pub fn showMenu(hwnd: HWND, srv_state: state.ServerState, launch_at_login: bool, server_error: []const u8) usize {
    const menu = CreatePopupMenu() orelse return 0;
    defer _ = DestroyMenu(menu);

    var dynamic_status: [256:0]u16 = std.mem.zeroes([256:0]u16);
    const status_label: [*:0]const u16 = switch (srv_state) {
        .license_gate => W("License required"),
        .stopped => W("Server stopped"),
        .starting => W("Starting..."),
        .running => W("Running"),
        .@"error" => blk: {
            if (server_error.len == 0) break :blk W("Error");
            const prefix = "Error: ";
            var utf8_buf: [256]u8 = undefined;
            const len = std.fmt.bufPrint(&utf8_buf, "{s}{s}", .{ prefix, server_error }) catch break :blk W("Error");
            const wide_len = std.unicode.utf8ToUtf16Le(dynamic_status[0 .. dynamic_status.len - 1], len) catch break :blk W("Error");
            dynamic_status[wide_len] = 0;
            break :blk &dynamic_status;
        },
    };
    _ = AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, status_label);
    _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);

    switch (srv_state) {
        .license_gate => {
            _ = AppendMenuW(menu, MF_STRING, CMD_LICENSE, W("Enter License Key..."));
        },
        .stopped, .@"error" => {
            _ = AppendMenuW(menu, MF_STRING, CMD_START, W("Start Server"));
        },
        .starting => {
            _ = AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, W("Starting..."));
        },
        .running => {
            _ = AppendMenuW(menu, MF_STRING, CMD_OPEN_DASHBOARD, W("Open Dashboard"));
            _ = AppendMenuW(menu, MF_STRING, CMD_STOP, W("Stop Server"));
        },
    }

    _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);

    const login_flags: UINT = if (launch_at_login) MF_STRING | MF_CHECKED else MF_STRING;
    _ = AppendMenuW(menu, login_flags, CMD_LAUNCH_AT_LOGIN, W("Launch at Login"));

    _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
    _ = AppendMenuW(menu, MF_STRING, CMD_QUIT, W("Quit RTMify Live"));

    var pt: POINT = undefined;
    _ = GetCursorPos(&pt);
    _ = SetForegroundWindow(hwnd);

    const cmd = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY, pt.x, pt.y, 0, hwnd, null);
    return if (cmd > 0) @intCast(cmd) else 0;
}
