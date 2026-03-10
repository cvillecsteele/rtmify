// state.zig — Application state for rtmify-live Windows shell.

const std = @import("std");

pub const ServerState = enum {
    license_gate,
    stopped,
    starting,
    running,
    @"error",
};

pub const Config = struct {
    port: u16 = 8000,
    last_sync: [64:0]u8 = std.mem.zeroes([64:0]u8),
    last_scan: [64:0]u8 = std.mem.zeroes([64:0]u8),
    license_error: [256:0]u8 = std.mem.zeroes([256:0]u8),
    server_error: [256:0]u8 = std.mem.zeroes([256:0]u8),
};
