const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

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

pub fn machineFingerprint(buf: *[64]u8) ![]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});

    if (builtin.os.tag == .windows) {
        var hostname_buf: [256]u8 = undefined;
        var size: std.os.windows.DWORD = @intCast(hostname_buf.len);
        const GetComputerNameA = struct {
            extern "kernel32" fn GetComputerNameA(lpBuffer: [*]u8, nSize: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
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
