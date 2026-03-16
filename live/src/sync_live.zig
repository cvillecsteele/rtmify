const sync_mod = @import("sync/mod.zig");

pub const SyncState = sync_mod.state.SyncState;
pub const WorkerControl = sync_mod.state.WorkerControl;
pub const SyncConfig = sync_mod.state.SyncConfig;
pub const RepoScanCtx = sync_mod.repo_scan.RepoScanCtx;

pub fn syncThread(cfg: SyncConfig) void {
    sync_mod.worker.syncThread(cfg);
}

pub fn destroyRepoScanCtx(ctx: *RepoScanCtx) void {
    sync_mod.repo_scan.destroyRepoScanCtx(ctx);
}

pub fn repoScanThread(ctx: *RepoScanCtx) void {
    sync_mod.repo_scan.repoScanThread(ctx);
}

pub fn triggerRepoScanNow(
    db: *sync_mod.internal.GraphDb,
    state: *SyncState,
    repo_paths: []const []const u8,
    alloc: sync_mod.internal.Allocator,
) !void {
    try sync_mod.repo_scan.triggerRepoScanNow(db, state, repo_paths, alloc);
}

test {
    _ = @import("sync/tests/mod.zig");
}
