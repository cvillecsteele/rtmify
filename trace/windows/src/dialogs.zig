// dialogs.zig — GetOpenFileNameW browse dialog + MessageBoxW error helper

const std = @import("std");

// ---------------------------------------------------------------------------
// Win32 types / constants
// ---------------------------------------------------------------------------

const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const BOOL = c_int;
const DWORD = u32;
const WORD = u16;
const LPARAM = isize;

const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_HIDEREADONLY: DWORD = 0x00000004;

const MB_OK: c_uint = 0x00000000;
const MB_ICONWARNING: c_uint = 0x00000030;

// ---------------------------------------------------------------------------
// OPENFILENAMEW — manually laid out to match windows.h
// ---------------------------------------------------------------------------

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
    // Windows 2000+ extended fields
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,
};

// ---------------------------------------------------------------------------
// Win32 externs
// ---------------------------------------------------------------------------

extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) DWORD;

extern "user32" fn MessageBoxW(
    hWnd: ?HWND,
    lpText: [*:0]const u16,
    lpCaption: [*:0]const u16,
    uType: c_uint,
) callconv(.winapi) c_int;

fn selectedPathToUtf8(buf: []u8, path_w: []const u16) ![]u8 {
    const nbytes = try std.unicode.utf16LeToUtf8(buf, path_w);
    return buf[0..nbytes];
}

// ---------------------------------------------------------------------------
// browseXlsx — shows an Open dialog filtered to *.xlsx
// Returns a UTF-8 slice into buf, or null if cancelled.
// ---------------------------------------------------------------------------

pub fn browseXlsx(hwnd: HWND, buf: []u8) ?[]u8 {
    // Filter: "Excel Files\0*.xlsx\0\0" in UTF-16
    const filter = [_:0]u16{
        'E', 'x', 'c', 'e', 'l', ' ', 'F', 'i', 'l', 'e', 's', 0,
        '*', '.', 'x', 'l', 's', 'x', 0,
        0,
    };

    var path_w: [1024:0]u16 = std.mem.zeroes([1024:0]u16);

    var ofn = OPENFILENAMEW{
        .hwndOwner = hwnd,
        .lpstrFilter = &filter,
        .lpstrFile = &path_w,
        .nMaxFile = @intCast(path_w.len),
        .Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY,
        .lpstrDefExt = &[_:0]u16{ 'x', 'l', 's', 'x', 0 },
    };

    if (GetOpenFileNameW(&ofn) == 0) {
        const err = CommDlgExtendedError();
        if (err != 0) {
            showError(hwnd, "Could not open file dialog. Please try again.");
        }
        return null;
    }

    // Measure the null-terminated UTF-16 string
    const wlen = std.mem.indexOfScalar(u16, &path_w, 0) orelse path_w.len;

    return selectedPathToUtf8(buf, path_w[0..wlen]) catch {
        showError(hwnd, "Selected file path could not be read.");
        return null;
    };
}

pub fn browseLicenseJson(hwnd: HWND, buf: []u8) ?[]u8 {
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
        // Distinguish user cancellation (0) from dialog failure (non-zero)
        const err = CommDlgExtendedError();
        if (err != 0) {
            showError(hwnd, "Could not open file dialog. Please try again.");
        }
        return null;
    }
    const wlen = std.mem.indexOfScalar(u16, &path_w, 0) orelse path_w.len;
    return selectedPathToUtf8(buf, path_w[0..wlen]) catch {
        showError(hwnd, "Selected file path could not be read.");
        return null;
    };
}

// ---------------------------------------------------------------------------
// showError — MessageBoxW with a UTF-8 error string
// ---------------------------------------------------------------------------

pub fn showError(hwnd: ?HWND, msg_utf8: [*:0]const u8) void {
    const msg_slice = std.mem.span(msg_utf8);
    var msg_w: [512:0]u16 = std.mem.zeroes([512:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&msg_w, msg_slice) catch {};

    const caption = [_:0]u16{ 'R', 'T', 'M', 'i', 'f', 'y', ' ', 'T', 'r', 'a', 'c', 'e', 0 };
    _ = MessageBoxW(hwnd, &msg_w, &caption, MB_OK | MB_ICONWARNING);
}

test "selectedPathToUtf8 converts UTF-16 path" {
    var buf: [64]u8 = undefined;
    const path = [_]u16{ 'C', ':', '\\', 't', 'e', 's', 't', '.', 'x', 'l', 's', 'x' };
    const out = try selectedPathToUtf8(&buf, &path);
    try std.testing.expectEqualStrings("C:\\test.xlsx", out);
}

test "selectedPathToUtf8 rejects invalid UTF-16" {
    var buf: [16]u8 = undefined;
    const invalid = [_]u16{0xD800};
    if (selectedPathToUtf8(&buf, &invalid)) |_| return error.ExpectedFailure else |_| {}
}
