// process.zig — Process spawning helpers for rtmify-live.exe subprocess.

const std = @import("std");
const HANDLE = *anyopaque;
const BOOL = c_int;
const DWORD = u32;

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?[*]u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE,
    hThread: ?HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

extern "kernel32" fn TerminateProcess(hProcess: ?HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: ?HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: ?HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*:0]u16, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: ?HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;

const UINT = c_uint;
const CREATE_NO_WINDOW: DWORD = 0x08000000;

/// Returns the directory of the current executable (wide string, null-terminated).
pub fn exeDir(buf: []u16) []u16 {
    var path_buf: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    const len = GetModuleFileNameW(null, &path_buf, 1024);
    if (len == 0) return buf[0..0];
    // Find last backslash
    var i: usize = len;
    while (i > 0 and path_buf[i - 1] != '\\') : (i -= 1) {}
    const dir_len = if (i > 0) i else len;
    const copy_len = @min(dir_len, buf.len - 1);
    @memcpy(buf[0..copy_len], path_buf[0..copy_len]);
    buf[copy_len] = 0;
    return buf[0..copy_len];
}

/// Spawn `rtmify-live.exe --activate <key>` and wait for exit.
/// Returns exit code (0 = success).
pub fn spawnActivate(key_utf8: []const u8) u32 {
    var exe_buf: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    var dir_buf: [1024]u16 = undefined;
    const dir = exeDir(&dir_buf);
    if (dir.len == 0) return 1;

    // Build exe path: dir + "rtmify-live.exe"
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("rtmify-live.exe");
    @memcpy(exe_buf[0..dir.len], dir);
    @memcpy(exe_buf[dir.len .. dir.len + suffix.len], suffix);
    exe_buf[dir.len + suffix.len] = 0;

    // Build command line: "rtmify-live.exe" --activate KEY
    var cmd_buf: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    var key_wide: [256:0]u16 = std.mem.zeroes([256:0]u16);
    _ = std.unicode.utf8ToUtf16Le(&key_wide, key_utf8) catch return 1;
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral("rtmify-live.exe --activate ");
    @memcpy(cmd_buf[0..prefix.len], prefix);
    const key_len = std.mem.indexOfSentinel(u16, 0, &key_wide);
    @memcpy(cmd_buf[prefix.len .. prefix.len + key_len], key_wide[0..key_len]);

    var si: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

    const ok = CreateProcessW(&exe_buf, &cmd_buf, null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi);
    if (ok == 0) return 1;
    defer _ = CloseHandle(pi.hThread);
    defer _ = CloseHandle(pi.hProcess);

    _ = WaitForSingleObject(pi.hProcess, 30_000); // 30s timeout
    var exit_code: DWORD = 1;
    _ = GetExitCodeProcess(pi.hProcess, &exit_code);
    return exit_code;
}

/// Process handle for the running server (null when stopped).
pub var server_process: ?HANDLE = null;

/// Spawn `rtmify-live.exe --port <port> --no-browser` in background.
/// Returns true on success.
pub fn spawnServer(port: u16) bool {
    if (server_process != null) return false;

    var exe_buf: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    var dir_buf: [1024]u16 = undefined;
    const dir = exeDir(&dir_buf);
    if (dir.len == 0) return false;

    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("rtmify-live.exe");
    @memcpy(exe_buf[0..dir.len], dir);
    @memcpy(exe_buf[dir.len .. dir.len + suffix.len], suffix);
    exe_buf[dir.len + suffix.len] = 0;

    // Command: rtmify-live.exe --port NNNN --no-browser
    var cmd_buf: [256:0]u16 = std.mem.zeroes([256:0]u16);
    var cmd_utf8: [128]u8 = undefined;
    const cmd_len = std.fmt.bufPrint(&cmd_utf8, "rtmify-live.exe --port {d} --no-browser", .{port}) catch return false;
    _ = std.unicode.utf8ToUtf16Le(&cmd_buf, cmd_len) catch return false;

    var si: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

    const ok = CreateProcessW(&exe_buf, &cmd_buf, null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi);
    if (ok == 0) return false;

    _ = CloseHandle(pi.hThread);
    server_process = pi.hProcess;
    return true;
}

/// Terminate the running server process.
pub fn stopServer() void {
    if (server_process) |h| {
        _ = TerminateProcess(h, 0);
        _ = CloseHandle(h);
        server_process = null;
    }
}

/// Returns true if the server process is still running.
pub fn serverRunning() bool {
    const h = server_process orelse return false;
    const STILL_ACTIVE: DWORD = 259;
    var exit_code: DWORD = 0;
    _ = GetExitCodeProcess(h, &exit_code);
    return exit_code == STILL_ACTIVE;
}
