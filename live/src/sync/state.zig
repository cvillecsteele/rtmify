const std = @import("std");
const internal = @import("internal.zig");

pub const SyncState = struct {
    last_sync_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    has_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sync_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sync_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sync_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    product_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    repo_scan_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    repo_scan_last_started_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    repo_scan_last_finished_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    last_error: [256:0]u8 = .{0} ** 256,
    last_error_len: usize = 0,
    mu: std.Thread.Mutex = .{},
    repo_scan_mu: std.Thread.Mutex = .{},

    pub fn setError(s: *SyncState, msg: []const u8) void {
        s.mu.lock();
        defer s.mu.unlock();
        const n = @min(msg.len, s.last_error.len - 1);
        @memcpy(s.last_error[0..n], msg[0..n]);
        s.last_error[n] = 0;
        s.last_error_len = n;
        s.has_error.store(true, .seq_cst);
    }

    pub fn clearError(s: *SyncState) void {
        s.mu.lock();
        defer s.mu.unlock();
        s.last_error[0] = 0;
        s.last_error_len = 0;
        s.has_error.store(false, .seq_cst);
    }

    pub fn getError(s: *SyncState, buf: []u8) usize {
        s.mu.lock();
        defer s.mu.unlock();
        const n = @min(s.last_error_len, buf.len);
        @memcpy(buf[0..n], s.last_error[0..n]);
        return n;
    }
};

pub const WorkerControl = struct {
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    immediate_sync_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cond_mu: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn requestStop(self: *WorkerControl) void {
        self.stop_requested.store(true, .seq_cst);
        self.cond_mu.lock();
        defer self.cond_mu.unlock();
        self.cond.broadcast();
    }

    pub fn requestImmediateSync(self: *WorkerControl) void {
        self.immediate_sync_requested.store(true, .seq_cst);
        self.cond_mu.lock();
        defer self.cond_mu.unlock();
        self.cond.broadcast();
    }

    pub fn waitTimeout(self: *WorkerControl, timeout_ns: u64) void {
        self.cond_mu.lock();
        defer self.cond_mu.unlock();
        if (self.stop_requested.load(.seq_cst) or self.immediate_sync_requested.load(.seq_cst)) return;
        self.cond.timedWait(&self.cond_mu, timeout_ns) catch {};
    }
};

pub const SyncConfig = struct {
    workbook_id: []const u8,
    workbook_slug: []const u8,
    profile: internal.profile_mod.ProfileId,
    active: internal.ActiveConnection,
    control: *WorkerControl,
    alloc: internal.Allocator,
    db: *internal.GraphDb,
    state: *SyncState,
};
