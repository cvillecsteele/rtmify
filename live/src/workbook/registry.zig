const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const provider_common = @import("../provider_common.zig");
const secure_store = @import("../secure_store.zig");
const sync_live = @import("../sync_live.zig");
const test_results_auth = @import("../test_results_auth.zig");
const workbook_config = @import("config.zig");
const workbook_runtime = @import("runtime.zig");

pub const WorkbookSummary = struct {
    id: []const u8,
    slug: []const u8,
    display_name: []const u8,
    profile: []const u8,
    provider: ?[]const u8,
    workbook_label: ?[]const u8,
    is_active: bool,
    removed_at: ?i64,
    last_sync_at: i64,
    sync_in_progress: bool,
    has_error: bool,
    last_error: ?[]const u8,
    inbox_dir: []const u8,
    db_path: []const u8,

    pub fn deinit(self: *WorkbookSummary, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.slug);
        alloc.free(self.display_name);
        alloc.free(self.profile);
        if (self.provider) |value| alloc.free(value);
        if (self.workbook_label) |value| alloc.free(value);
        if (self.last_error) |value| alloc.free(value);
        alloc.free(self.inbox_dir);
        alloc.free(self.db_path);
    }
};

pub fn deinitSummarySlice(items: []WorkbookSummary, alloc: Allocator) void {
    for (items) |*item| item.deinit(alloc);
    alloc.free(items);
}

pub const ActiveWorkers = struct {
    sync_thread: ?std.Thread = null,
    repo_thread: ?std.Thread = null,
    inbox_thread: ?std.Thread = null,
    control: *sync_live.WorkerControl,
};

pub const WorkbookRegistry = struct {
    live_config: workbook_config.LiveConfig,
    active_runtime: ?*workbook_runtime.WorkbookRuntime = null,
    active_workers: ?ActiveWorkers = null,

    pub fn init(alloc: Allocator, store: *secure_store.Store, options: workbook_config.BootstrapOptions) !WorkbookRegistry {
        var cfg = try workbook_config.loadOrInit(alloc, options);
        errdefer cfg.deinit(alloc);
        return initForConfig(alloc, cfg, store);
    }

    pub fn initForConfig(alloc: Allocator, cfg: workbook_config.LiveConfig, store: *secure_store.Store) !WorkbookRegistry {
        var registry = WorkbookRegistry{ .live_config = cfg };
        errdefer registry.deinit(alloc);
        try registry.reloadActiveRuntime(alloc, store);
        return registry;
    }

    pub fn deinit(self: *WorkbookRegistry, alloc: Allocator) void {
        if (self.active_workers) |workers| {
            alloc.destroy(workers.control);
            self.active_workers = null;
        }
        self.unloadActiveRuntime(alloc);
        self.live_config.deinit(alloc);
    }

    pub fn active(self: *WorkbookRegistry) !*workbook_runtime.WorkbookRuntime {
        return self.active_runtime orelse error.NoActiveWorkbook;
    }

    pub fn activeConfig(self: *WorkbookRegistry) !*workbook_config.WorkbookConfig {
        return workbook_config.activeWorkbook(&self.live_config) orelse error.NoActiveWorkbook;
    }

    pub fn configuredActiveId(self: *const WorkbookRegistry) ?[]const u8 {
        return self.live_config.active_workbook_id;
    }

    pub fn installActiveWorkers(self: *WorkbookRegistry, workers: ActiveWorkers) void {
        self.active_workers = workers;
    }

    pub fn takeActiveWorkers(self: *WorkbookRegistry) ?ActiveWorkers {
        const workers = self.active_workers;
        self.active_workers = null;
        return workers;
    }

    pub fn clearActiveWorkers(self: *WorkbookRegistry) void {
        self.active_workers = null;
    }

    pub fn save(self: *WorkbookRegistry, alloc: Allocator) !void {
        if (self.active_runtime) |runtime| {
            if (workbook_config.findById(&self.live_config, runtime.config.id)) |cfg| {
                cfg.deinit(alloc);
                cfg.* = try runtime.config.clone(alloc);
            }
        }
        try workbook_config.save(&self.live_config, alloc);
    }

    pub fn reloadActiveRuntime(self: *WorkbookRegistry, alloc: Allocator, store: *secure_store.Store) !void {
        self.unloadActiveRuntime(alloc);

        const active_id = self.live_config.active_workbook_id orelse return;
        const cfg = workbook_config.findById(&self.live_config, active_id) orelse return error.NoActiveWorkbook;
        if (cfg.removed_at != null) return error.WorkbookRemoved;

        const db_path_z = try alloc.dupeZ(u8, cfg.db_path);
        defer alloc.free(db_path_z);
        const runtime = try alloc.create(workbook_runtime.WorkbookRuntime);
        errdefer alloc.destroy(runtime);
        runtime.* = .{
            .config = try cfg.clone(alloc),
            .db = try graph_live.GraphDb.init(db_path_z),
            .ingest_auth = try test_results_auth.AuthState.initForWorkbookSlug(cfg.slug, alloc),
        };
        _ = store;
        self.active_runtime = runtime;
    }

    pub fn unloadActiveRuntime(self: *WorkbookRegistry, alloc: Allocator) void {
        if (self.active_runtime) |runtime| {
            runtime.deinit(alloc);
            alloc.destroy(runtime);
            self.active_runtime = null;
        }
    }

    pub fn syncRuntimeConfigFromActive(self: *WorkbookRegistry, alloc: Allocator) !void {
        const runtime = self.active_runtime orelse return;
        const cfg = try self.activeConfig();
        runtime.config.deinit(alloc);
        runtime.config = try cfg.clone(alloc);
    }

    pub fn createWorkbook(
        self: *WorkbookRegistry,
        store: *secure_store.Store,
        validated: provider_common.ValidatedDraft,
        display_name: []const u8,
        repo_paths: []const []const u8,
        alloc: Allocator,
    ) !WorkbookSummary {
        if (!secure_store.backendSupported(store.*)) return error.SecureStorageUnsupported;

        const credential_ref = try secure_store.generateCredentialRef(alloc);
        defer alloc.free(credential_ref);
        try store.put(alloc, credential_ref, validated.credential_json);
        errdefer store.delete(alloc, credential_ref) catch {};

        const entry = try workbook_config.createWorkbookEntry(&self.live_config, display_name, validated, credential_ref, repo_paths, alloc);
        try workbook_config.appendWorkbook(&self.live_config, entry, true, alloc);
        try self.save(alloc);
        return self.summaryForWorkbookId(entry.id, alloc);
    }

    pub fn renameWorkbook(self: *WorkbookRegistry, id: []const u8, display_name: []const u8, alloc: Allocator) !void {
        try workbook_config.renameWorkbook(&self.live_config, id, display_name, alloc);
        if (self.active_runtime) |runtime| {
            if (std.mem.eql(u8, runtime.config.id, id)) {
                try self.syncRuntimeConfigFromActive(alloc);
            }
        }
        try self.save(alloc);
    }

    pub fn activateWorkbook(self: *WorkbookRegistry, id: []const u8, alloc: Allocator) !WorkbookSummary {
        try workbook_config.activateWorkbookId(&self.live_config, id, alloc);
        try self.save(alloc);
        return self.summaryForWorkbookId(id, alloc);
    }

    pub fn removeWorkbook(self: *WorkbookRegistry, id: []const u8, alloc: Allocator) !WorkbookSummary {
        try workbook_config.removeWorkbook(&self.live_config, id, alloc);
        try self.save(alloc);
        return if (self.live_config.active_workbook_id) |active_id|
            self.summaryForWorkbookId(active_id, alloc)
        else
            error.NoActiveWorkbook;
    }

    pub fn purgeWorkbook(self: *WorkbookRegistry, id: []const u8, alloc: Allocator) !void {
        const cfg = workbook_config.findById(&self.live_config, id) orelse return error.WorkbookNotFound;
        if (cfg.removed_at == null) return error.WorkbookNotRemoved;
        const db_path = try alloc.dupe(u8, cfg.db_path);
        defer alloc.free(db_path);
        const inbox_dir = try alloc.dupe(u8, cfg.inbox_dir);
        defer alloc.free(inbox_dir);
        const slug = try alloc.dupe(u8, cfg.slug);
        defer alloc.free(slug);

        const idx = findWorkbookIndex(&self.live_config, id) orelse return error.WorkbookNotFound;
        try workbook_config.purgeWorkbookAt(&self.live_config, idx, alloc);
        try self.deleteWorkbookArtifacts(db_path, inbox_dir, slug);
        try self.save(alloc);
    }

    pub fn listVisible(self: *WorkbookRegistry, alloc: Allocator) ![]WorkbookSummary {
        return self.listByRemovalState(false, alloc);
    }

    pub fn listRemoved(self: *WorkbookRegistry, alloc: Allocator) ![]WorkbookSummary {
        return self.listByRemovalState(true, alloc);
    }

    pub fn summaryForWorkbookId(self: *WorkbookRegistry, id: []const u8, alloc: Allocator) !WorkbookSummary {
        const cfg = workbook_config.findByIdConst(&self.live_config, id) orelse return error.WorkbookNotFound;
        return self.summaryForWorkbook(cfg.*, alloc);
    }

    fn listByRemovalState(self: *WorkbookRegistry, removed: bool, alloc: Allocator) ![]WorkbookSummary {
        var count: usize = 0;
        for (self.live_config.workbooks) |cfg| {
            if ((cfg.removed_at != null) == removed) count += 1;
        }
        const items = try alloc.alloc(WorkbookSummary, count);
        errdefer alloc.free(items);
        var out_idx: usize = 0;
        for (self.live_config.workbooks) |cfg| {
            if ((cfg.removed_at != null) != removed) continue;
            items[out_idx] = try self.summaryForWorkbook(cfg, alloc);
            out_idx += 1;
        }
        return items;
    }

    fn summaryForWorkbook(self: *WorkbookRegistry, cfg: workbook_config.WorkbookConfig, alloc: Allocator) !WorkbookSummary {
        if (self.active_runtime) |runtime| {
            if (std.mem.eql(u8, runtime.config.id, cfg.id)) {
                var err_buf: [256]u8 = undefined;
                const err_len = runtime.sync_state.getError(&err_buf);
                return .{
                    .id = try alloc.dupe(u8, runtime.config.id),
                    .slug = try alloc.dupe(u8, runtime.config.slug),
                    .display_name = try alloc.dupe(u8, runtime.config.display_name),
                    .profile = try alloc.dupe(u8, runtime.config.profile),
                    .provider = if (runtime.config.platform) |p| try alloc.dupe(u8, provider_common.providerIdString(p)) else null,
                    .workbook_label = if (runtime.config.workbook_label) |v| try alloc.dupe(u8, v) else null,
                    .is_active = true,
                    .removed_at = runtime.config.removed_at,
                    .last_sync_at = runtime.sync_state.last_sync_at.load(.seq_cst),
                    .sync_in_progress = runtime.sync_state.sync_in_progress.load(.seq_cst),
                    .has_error = runtime.sync_state.has_error.load(.seq_cst),
                    .last_error = if (err_len > 0) try alloc.dupe(u8, err_buf[0..err_len]) else null,
                    .inbox_dir = try alloc.dupe(u8, runtime.config.inbox_dir),
                    .db_path = try alloc.dupe(u8, runtime.config.db_path),
                };
            }
        }

        return inactiveSummary(cfg, alloc);
    }

    fn inactiveSummary(cfg: workbook_config.WorkbookConfig, alloc: Allocator) !WorkbookSummary {
        const sync = try readPersistedSync(cfg.db_path, alloc);
        return .{
            .id = try alloc.dupe(u8, cfg.id),
            .slug = try alloc.dupe(u8, cfg.slug),
            .display_name = try alloc.dupe(u8, cfg.display_name),
            .profile = try alloc.dupe(u8, cfg.profile),
            .provider = if (cfg.platform) |p| try alloc.dupe(u8, provider_common.providerIdString(p)) else null,
            .workbook_label = if (cfg.workbook_label) |v| try alloc.dupe(u8, v) else null,
            .is_active = false,
            .removed_at = cfg.removed_at,
            .last_sync_at = sync.last_sync_at,
            .sync_in_progress = false,
            .has_error = !sync.last_sync_ok,
            .last_error = sync.last_sync_error,
            .inbox_dir = try alloc.dupe(u8, cfg.inbox_dir),
            .db_path = try alloc.dupe(u8, cfg.db_path),
        };
    }

    fn deleteWorkbookArtifacts(self: *WorkbookRegistry, db_path: []const u8, inbox_dir: []const u8, slug: []const u8) !void {
        _ = self;
        deleteFilePath(db_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        deleteTreePath(inbox_dir) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const token_path = try test_results_auth.tokenPathForWorkbookSlug(slug, std.heap.page_allocator);
        defer std.heap.page_allocator.free(token_path);
        deleteFilePath(token_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

const PersistedSync = struct {
    last_sync_at: i64 = 0,
    last_sync_ok: bool = false,
    last_sync_error: ?[]u8 = null,

    fn deinit(self: *PersistedSync, alloc: Allocator) void {
        if (self.last_sync_error) |value| alloc.free(value);
    }
};

fn readPersistedSync(db_path: []const u8, alloc: Allocator) !PersistedSync {
    const zpath = try alloc.dupeZ(u8, db_path);
    defer alloc.free(zpath);
    var db = graph_live.GraphDb.init(zpath) catch {
        return .{};
    };
    defer db.deinit();

    const last_sync_raw = (db.getConfig("last_sync_at", alloc) catch null) orelse return .{};
    defer alloc.free(last_sync_raw);
    const ok_raw = (db.getConfig("last_sync_ok", alloc) catch null) orelse try alloc.dupe(u8, "0");
    defer alloc.free(ok_raw);
    const err_raw = db.getConfig("last_sync_error", alloc) catch null;

    const last_sync_at = std.fmt.parseInt(i64, last_sync_raw, 10) catch 0;
    const last_sync_ok = std.mem.eql(u8, ok_raw, "1");
    return .{
        .last_sync_at = last_sync_at,
        .last_sync_ok = last_sync_ok,
        .last_sync_error = if (err_raw) |value| try alloc.dupe(u8, value) else null,
    };
}

fn deleteFilePath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.deleteFileAbsolute(path);
    }
    return std.fs.cwd().deleteFile(path);
}

fn deleteTreePath(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.deleteTreeAbsolute(path);
    }
    return std.fs.cwd().deleteTree(path);
}

fn findWorkbookIndex(cfg: *const workbook_config.LiveConfig, id: []const u8) ?usize {
    for (cfg.workbooks, 0..) |workbook, idx| {
        if (std.mem.eql(u8, workbook.id, id)) return idx;
    }
    return null;
}
