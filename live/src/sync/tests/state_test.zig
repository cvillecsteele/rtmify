const std = @import("std");
const testing = std.testing;
const state_mod = @import("../state.zig");

test "SyncState error round-trip" {
    var s: state_mod.SyncState = .{};
    s.setError("connection refused");
    try testing.expect(s.has_error.load(.seq_cst));
    var buf: [256]u8 = undefined;
    const n = s.getError(&buf);
    try testing.expectEqualStrings("connection refused", buf[0..n]);
    s.clearError();
    try testing.expect(!s.has_error.load(.seq_cst));
}

test "WorkerControl stop and immediate-sync signaling" {
    var control: state_mod.WorkerControl = .{};
    try testing.expect(!control.stop_requested.load(.seq_cst));
    try testing.expect(!control.immediate_sync_requested.load(.seq_cst));

    control.requestImmediateSync();
    try testing.expect(control.immediate_sync_requested.load(.seq_cst));

    control.requestStop();
    try testing.expect(control.stop_requested.load(.seq_cst));
}
