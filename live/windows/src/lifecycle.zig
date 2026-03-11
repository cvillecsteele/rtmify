const state_mod = @import("state.zig");

pub fn handleStart(state: *state_mod.ServerState) void {
    state.* = .starting;
}

pub fn handleStarted(state: *state_mod.ServerState) void {
    state.* = .running;
}

pub fn handleStartupFailed(state: *state_mod.ServerState) void {
    state.* = .@"error";
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
    if ((state.* == .running or state.* == .starting) and !is_running) {
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

test "start transitions to starting" {
    var state: state_mod.ServerState = .stopped;
    handleStart(&state);
    try @import("std").testing.expectEqual(state_mod.ServerState.starting, state);
}

test "started transitions to running" {
    var state: state_mod.ServerState = .starting;
    handleStarted(&state);
    try @import("std").testing.expectEqual(state_mod.ServerState.running, state);
}

test "startup failed transitions to error" {
    var state: state_mod.ServerState = .starting;
    handleStartupFailed(&state);
    try @import("std").testing.expectEqual(state_mod.ServerState.@"error", state);
}

test "timer marks crashed running server as error" {
    var state: state_mod.ServerState = .running;
    handleTimer(&state, false);
    try @import("std").testing.expectEqual(state_mod.ServerState.@"error", state);
}

test "timer marks crashed starting server as error" {
    var state: state_mod.ServerState = .starting;
    handleTimer(&state, false);
    try @import("std").testing.expectEqual(state_mod.ServerState.@"error", state);
}

test "timer leaves stopped server unchanged" {
    var state: state_mod.ServerState = .stopped;
    handleTimer(&state, false);
    try @import("std").testing.expectEqual(state_mod.ServerState.stopped, state);
}
