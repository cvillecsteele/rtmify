const state_mod = @import("state.zig");

pub fn handleStart(state: *state_mod.ServerState, spawn_ok: bool) void {
    state.* = .starting;
    state.* = if (spawn_ok) .running else .@"error";
}

pub fn handleStop(state: *state_mod.ServerState, stop_fn: anytype) void {
    stop_fn();
    state.* = .stopped;
}

pub fn handleQuit(stop_fn: anytype) void {
    stop_fn();
}

pub fn handleDestroy(stop_fn: anytype) void {
    stop_fn();
}

pub fn handleTimer(state: *state_mod.ServerState, is_running: bool) void {
    if (state.* == .running and !is_running) {
        state.* = .@"error";
    }
}

test "quit always stops the server" {
    const Ctx = struct {
        var stopped: usize = 0;
        fn stop() void {
            stopped += 1;
        }
    };

    Ctx.stopped = 0;
    handleQuit(Ctx.stop);
    try @import("std").testing.expectEqual(@as(usize, 1), Ctx.stopped);
}

test "destroy always stops the server" {
    const Ctx = struct {
        var stopped: usize = 0;
        fn stop() void {
            stopped += 1;
        }
    };

    Ctx.stopped = 0;
    handleDestroy(Ctx.stop);
    try @import("std").testing.expectEqual(@as(usize, 1), Ctx.stopped);
}

test "start transitions to running on successful spawn" {
    var state: state_mod.ServerState = .stopped;
    handleStart(&state, true);
    try @import("std").testing.expectEqual(state_mod.ServerState.running, state);
}

test "start transitions to error on failed spawn" {
    var state: state_mod.ServerState = .stopped;
    handleStart(&state, false);
    try @import("std").testing.expectEqual(state_mod.ServerState.@"error", state);
}

test "timer marks crashed running server as error" {
    var state: state_mod.ServerState = .running;
    handleTimer(&state, false);
    try @import("std").testing.expectEqual(state_mod.ServerState.@"error", state);
}

test "timer leaves stopped server unchanged" {
    var state: state_mod.ServerState = .stopped;
    handleTimer(&state, false);
    try @import("std").testing.expectEqual(state_mod.ServerState.stopped, state);
}
