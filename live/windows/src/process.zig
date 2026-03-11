// process.zig — Process spawning helpers for rtmify-live.exe subprocess.

const std = @import("std");
const HANDLE = *anyopaque;
const BOOL = c_int;
const DWORD = u32;
const UINT = c_uint;
const LPVOID = ?*anyopaque;
const LPCVOID = ?*const anyopaque;

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

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: LPVOID,
    bInheritHandle: BOOL,
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
extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const u16, lpValue: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(
    hFile: ?HANDLE,
    lpBuffer: LPCVOID,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: LPVOID,
) callconv(.winapi) BOOL;

const CREATE_NO_WINDOW: DWORD = 0x08000000;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const FILE_APPEND_DATA: DWORD = 0x00000004;
const FILE_SHARE_READ: DWORD = 0x00000001;
const FILE_SHARE_WRITE: DWORD = 0x00000002;
const OPEN_ALWAYS: DWORD = 4;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
const INVALID_HANDLE_VALUE: isize = -1;

pub const SpawnServerError = enum {
    already_running,
    server_binary_missing,
    localappdata_missing,
    data_dir_create_failed,
    log_open_failed,
    command_line_too_long,
    env_setup_failed,
    spawn_failed,
};

pub const SpawnServerResult = union(enum) {
    ok,
    err: SpawnServerError,
};

pub const ServerPaths = struct {
    data_dir: []u8,
    db_path: []u8,
    log_path: []u8,

    pub fn deinit(self: *ServerPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.data_dir);
        allocator.free(self.db_path);
        allocator.free(self.log_path);
    }
};

/// Returns the directory of the current executable (wide string, null-terminated).
pub fn exeDir(buf: []u16) []u16 {
    var path_buf: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    const len = GetModuleFileNameW(null, &path_buf, 1024);
    if (len == 0) return buf[0..0];
    var i: usize = len;
    while (i > 0 and path_buf[i - 1] != '\\') : (i -= 1) {}
    const dir_len = if (i > 0) i else len;
    const copy_len = @min(dir_len, buf.len - 1);
    @memcpy(buf[0..copy_len], path_buf[0..copy_len]);
    buf[copy_len] = 0;
    return buf[0..copy_len];
}

fn exeDirUtf8(allocator: std.mem.Allocator) ![]u8 {
    var dir_buf: [1024]u16 = undefined;
    const dir = exeDir(&dir_buf);
    if (dir.len == 0) return error.InvalidExeDir;
    return try std.unicode.utf16LeToUtf8Alloc(allocator, dir);
}

pub fn findServerExecutable(allocator: std.mem.Allocator) ![]u8 {
    const dir = try exeDirUtf8(allocator);
    defer allocator.free(dir);
    return try std.fs.path.join(allocator, &.{ dir, "rtmify-live.exe" });
}

pub fn localAppDataDir(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "LOCALAPPDATA");
}

pub fn buildServerPaths(allocator: std.mem.Allocator) !ServerPaths {
    const local_app_data = localAppDataDir(allocator) catch return error.MissingLocalAppData;
    defer allocator.free(local_app_data);

    const data_dir = try std.fs.path.join(allocator, &.{ local_app_data, "RTMify Live" });
    errdefer allocator.free(data_dir);
    const db_path = try std.fs.path.join(allocator, &.{ data_dir, "graph.db" });
    errdefer allocator.free(db_path);
    const log_dir = try std.fs.path.join(allocator, &.{ data_dir, "logs" });
    defer allocator.free(log_dir);
    const log_path = try std.fs.path.join(allocator, &.{ log_dir, "server.log" });
    errdefer allocator.free(log_path);

    return .{ .data_dir = data_dir, .db_path = db_path, .log_path = log_path };
}

pub fn ensureDataDirs(paths: ServerPaths) !void {
    std.fs.makeDirAbsolute(paths.data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const log_dir = try std.fs.path.join(std.heap.page_allocator, &.{ paths.data_dir, "logs" });
    defer std.heap.page_allocator.free(log_dir);
    std.fs.makeDirAbsolute(log_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn utf8ToWideZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

fn quoteIfNeeded(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfAny(u8, text, " \t()") == null) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{text});
}

pub fn buildServerCommandLine(allocator: std.mem.Allocator, port: u16, db_path: []const u8) ![]u8 {
    const quoted_db = try quoteIfNeeded(allocator, db_path);
    defer allocator.free(quoted_db);
    return std.fmt.allocPrint(allocator, "rtmify-live.exe --port {d} --no-browser --db {s}", .{ port, quoted_db });
}

fn appendLogHeader(log_handle: ?HANDLE, port: u16, server_path: []const u8) void {
    if (log_handle == null) return;
    var buf: [512]u8 = undefined;
    const now = std.time.timestamp();
    const line = std.fmt.bufPrint(&buf, "\n=== RTMify Live session {d} port={d} binary={s} ===\r\n", .{ now, port, server_path }) catch return;
    var written: DWORD = 0;
    _ = WriteFile(log_handle, line.ptr, @intCast(line.len), &written, null);
}

fn openLogHandle(allocator: std.mem.Allocator, log_path: []const u8) !?HANDLE {
    _ = allocator;
    var sa = SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };
    const log_path_w = try utf8ToWideZ(std.heap.page_allocator, log_path);
    defer std.heap.page_allocator.free(log_path_w);
    const handle = CreateFileW(log_path_w, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (@intFromPtr(handle) == INVALID_HANDLE_VALUE) return error.LogOpenFailed;
    return handle;
}

fn setChildEnvironment(allocator: std.mem.Allocator, log_path: []const u8) !void {
    const log_path_w = try utf8ToWideZ(allocator, log_path);
    defer allocator.free(log_path_w);
    if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("RTMIFY_LOG_PATH"), log_path_w.ptr) == 0) {
        return error.EnvSetupFailed;
    }
    if (SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("RTMIFY_TRAY_APP_VERSION"), std.unicode.utf8ToUtf16LeStringLiteral("windows-dev")) == 0) {
        return error.EnvSetupFailed;
    }
}

/// Spawn `rtmify-live.exe --activate <key>` and wait for exit.
/// Returns exit code (0 = success).
pub fn spawnActivate(key_utf8: []const u8) u32 {
    var exe_buf: [1024:0]u16 = std.mem.zeroes([1024:0]u16);
    var dir_buf: [1024]u16 = undefined;
    const dir = exeDir(&dir_buf);
    if (dir.len == 0) return 1;

    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("rtmify-live.exe");
    @memcpy(exe_buf[0..dir.len], dir);
    @memcpy(exe_buf[dir.len .. dir.len + suffix.len], suffix);
    exe_buf[dir.len + suffix.len] = 0;

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

    _ = WaitForSingleObject(pi.hProcess, 30_000);
    var exit_code: DWORD = 1;
    _ = GetExitCodeProcess(pi.hProcess, &exit_code);
    return exit_code;
}

pub var server_process: ?HANDLE = null;
pub var server_log_handle: ?HANDLE = null;

pub fn spawnServer(allocator: std.mem.Allocator, port: u16) SpawnServerResult {
    if (server_process != null) return .{ .err = .already_running };

    const server_path = findServerExecutable(allocator) catch return .{ .err = .server_binary_missing };
    defer allocator.free(server_path);
    std.fs.accessAbsolute(server_path, .{}) catch return .{ .err = .server_binary_missing };

    var paths = buildServerPaths(allocator) catch return .{ .err = .localappdata_missing };
    defer paths.deinit(allocator);
    ensureDataDirs(paths) catch return .{ .err = .data_dir_create_failed };

    setChildEnvironment(allocator, paths.log_path) catch return .{ .err = .env_setup_failed };

    const log_handle = openLogHandle(allocator, paths.log_path) catch return .{ .err = .log_open_failed };
    appendLogHeader(log_handle, port, server_path);

    const server_path_w = utf8ToWideZ(allocator, server_path) catch {
        if (log_handle) |h| _ = CloseHandle(h);
        return .{ .err = .spawn_failed };
    };
    defer allocator.free(server_path_w);
    const cmd_utf8 = buildServerCommandLine(allocator, port, paths.db_path) catch {
        if (log_handle) |h| _ = CloseHandle(h);
        return .{ .err = .command_line_too_long };
    };
    defer allocator.free(cmd_utf8);
    const cmd_w = utf8ToWideZ(allocator, cmd_utf8) catch {
        if (log_handle) |h| _ = CloseHandle(h);
        return .{ .err = .spawn_failed };
    };
    defer allocator.free(cmd_w);
    var current_dir_buf: [1024]u16 = undefined;
    const exe_dir = exeDir(&current_dir_buf);
    const current_dir_ptr: ?[*:0]const u16 = if (exe_dir.len > 0) @ptrCast(current_dir_buf[0..exe_dir.len :0].ptr) else null;

    var si: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
    si.cb = @sizeOf(STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = log_handle;
    si.hStdError = log_handle;
    si.hStdInput = null;
    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

    const ok = CreateProcessW(server_path_w.ptr, cmd_w.ptr, null, null, 1, CREATE_NO_WINDOW, null, current_dir_ptr, &si, &pi);
    if (ok == 0) {
        if (log_handle) |h| _ = CloseHandle(h);
        return .{ .err = .spawn_failed };
    }

    _ = CloseHandle(pi.hThread);
    server_process = pi.hProcess;
    server_log_handle = log_handle;
    return .ok;
}

pub fn stopServer() void {
    if (server_process) |h| {
        _ = TerminateProcess(h, 0);
        _ = CloseHandle(h);
        server_process = null;
    }
    if (server_log_handle) |h| {
        _ = CloseHandle(h);
        server_log_handle = null;
    }
}

pub fn serverRunning() bool {
    const h = server_process orelse return false;
    const STILL_ACTIVE: DWORD = 259;
    var exit_code: DWORD = 0;
    _ = GetExitCodeProcess(h, &exit_code);
    return exit_code == STILL_ACTIVE;
}

test "buildServerCommandLine quotes db path with spaces" {
    const alloc = std.testing.allocator;
    const cmd = try buildServerCommandLine(alloc, 8000, "C:\\Users\\Alice\\Local App Data\\RTMify Live\\graph.db");
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "\"C:\\Users\\Alice\\Local App Data\\RTMify Live\\graph.db\"") != null);
}

test "buildServerCommandLine leaves simple db path unquoted" {
    const alloc = std.testing.allocator;
    const cmd = try buildServerCommandLine(alloc, 8001, "C:\\RTMify\\graph.db");
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "--db C:\\RTMify\\graph.db") != null);
}

test "quoteIfNeeded handles parentheses" {
    const alloc = std.testing.allocator;
    const quoted = try quoteIfNeeded(alloc, "C:\\Users\\Alice\\AppData\\Local\\RTMify Live (Dev)\\graph.db");
    defer alloc.free(quoted);
    try std.testing.expectEqualStrings("\"C:\\Users\\Alice\\AppData\\Local\\RTMify Live (Dev)\\graph.db\"", quoted);
}
