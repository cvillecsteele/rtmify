const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const HttpResponse = struct {
    status_code: u16,
    body: []const u8,

    pub fn deinit(self: *HttpResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const Clock = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (ctx: *anyopaque) i64,
    };

    pub fn now(self: Clock) i64 {
        return self.vtable.now(self.ctx);
    }
};

pub const FingerprintSource = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        currentFingerprint: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror![]const u8,
    };

    pub fn currentFingerprint(self: FingerprintSource, alloc: Allocator) ![]const u8 {
        return self.vtable.currentFingerprint(self.ctx, alloc);
    }
};

pub const HttpClient = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        postForm: *const fn (ctx: *anyopaque, alloc: Allocator, url: []const u8, body: []const u8) anyerror!HttpResponse,
    };

    pub fn postForm(self: HttpClient, alloc: Allocator, url: []const u8, body: []const u8) !HttpResponse {
        return self.vtable.postForm(self.ctx, alloc, url, body);
    }
};

const SystemClockCtx = struct {};
const system_clock_ctx = SystemClockCtx{};

fn systemClockNow(ctx: *anyopaque) i64 {
    _ = ctx;
    return std.time.timestamp();
}

const system_clock_vtable = Clock.VTable{
    .now = systemClockNow,
};

pub fn systemClock() Clock {
    return .{
        .ctx = @constCast(@ptrCast(&system_clock_ctx)),
        .vtable = &system_clock_vtable,
    };
}

pub fn machineFingerprint(buf: *[64]u8) ![]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});

    if (builtin.os.tag == .windows) {
        var hostname_buf: [256]u8 = undefined;
        var size: std.os.windows.DWORD = @intCast(hostname_buf.len);
        const GetComputerNameA = struct {
            extern "kernel32" fn GetComputerNameA(
                lpBuffer: [*]u8,
                nSize: *std.os.windows.DWORD,
            ) callconv(.winapi) std.os.windows.BOOL;
        }.GetComputerNameA;
        if (GetComputerNameA(&hostname_buf, &size) != 0) {
            sha.update(hostname_buf[0..size]);
        }
    } else {
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try std.posix.gethostname(&hostname_buf);
        sha.update(hostname);
    }

    sha.update("\x00");
    sha.update(@tagName(builtin.os.tag));

    var digest: [32]u8 = undefined;
    sha.final(&digest);

    const hex = std.fmt.bytesToHex(&digest, .lower);
    @memcpy(buf, &hex);
    return buf[0..];
}

const MachineFingerprintCtx = struct {};
const machine_fingerprint_ctx = MachineFingerprintCtx{};

fn machineFingerprintCurrent(ctx: *anyopaque, alloc: Allocator) ![]const u8 {
    _ = ctx;
    var buf: [64]u8 = undefined;
    const fp = try machineFingerprint(&buf);
    return alloc.dupe(u8, fp);
}

const machine_fingerprint_vtable = FingerprintSource.VTable{
    .currentFingerprint = machineFingerprintCurrent,
};

pub fn machineFingerprintSource() FingerprintSource {
    return .{
        .ctx = @constCast(@ptrCast(&machine_fingerprint_ctx)),
        .vtable = &machine_fingerprint_vtable,
    };
}

const StdHttpClientCtx = struct {};
const std_http_client_ctx = StdHttpClientCtx{};

fn stdHttpPostForm(ctx: *anyopaque, alloc: Allocator, url: []const u8, body: []const u8) !HttpResponse {
    _ = ctx;
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    var response_buf = std.Io.Writer.Allocating.init(alloc);
    defer response_buf.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_buf.writer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        },
    });

    return .{
        .status_code = @intFromEnum(result.status),
        .body = try response_buf.toOwnedSlice(),
    };
}

const std_http_client_vtable = HttpClient.VTable{
    .postForm = stdHttpPostForm,
};

pub fn stdHttpClient() HttpClient {
    return .{
        .ctx = @constCast(@ptrCast(&std_http_client_ctx)),
        .vtable = &std_http_client_vtable,
    };
}

pub const FixedClockState = struct {
    now_value: i64,
};

fn fixedClockNow(ctx: *anyopaque) i64 {
    const state: *FixedClockState = @ptrCast(@alignCast(ctx));
    return state.now_value;
}

const fixed_clock_vtable = Clock.VTable{
    .now = fixedClockNow,
};

pub fn fixedClock(state: *FixedClockState) Clock {
    return .{
        .ctx = state,
        .vtable = &fixed_clock_vtable,
    };
}

pub const FixedFingerprintState = struct {
    fingerprint: []const u8,
};

fn fixedFingerprintCurrent(ctx: *anyopaque, alloc: Allocator) ![]const u8 {
    const state: *FixedFingerprintState = @ptrCast(@alignCast(ctx));
    return alloc.dupe(u8, state.fingerprint);
}

const fixed_fingerprint_vtable = FingerprintSource.VTable{
    .currentFingerprint = fixedFingerprintCurrent,
};

pub fn fixedFingerprintSource(state: *FixedFingerprintState) FingerprintSource {
    return .{
        .ctx = state,
        .vtable = &fixed_fingerprint_vtable,
    };
}

