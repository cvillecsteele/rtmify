const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const secure_store = @import("../secure_store.zig");
const test_results_auth = @import("../test_results_auth.zig");
const workbook_config = @import("config.zig");
const workbook_runtime = @import("runtime.zig");

pub const WorkbookRegistry = struct {
    live_config: workbook_config.LiveConfig,
    active_workbook_id: ?[]const u8,
    workbooks: std.StringHashMap(*workbook_runtime.WorkbookRuntime),

    pub fn init(alloc: Allocator, store: *secure_store.Store, options: workbook_config.BootstrapOptions) !WorkbookRegistry {
        var cfg = try workbook_config.loadOrInit(alloc, options);
        errdefer cfg.deinit(alloc);
        return initForConfig(alloc, cfg, store);
    }

    pub fn initForConfig(alloc: Allocator, cfg: workbook_config.LiveConfig, store: *secure_store.Store) !WorkbookRegistry {
        _ = store;
        var workbooks = std.StringHashMap(*workbook_runtime.WorkbookRuntime).init(alloc);
        errdefer workbooks.deinit();

        for (cfg.workbooks) |entry| {
            const db_path_z = try alloc.dupeZ(u8, entry.db_path);
            defer alloc.free(db_path_z);
            const runtime = try alloc.create(workbook_runtime.WorkbookRuntime);
            errdefer alloc.destroy(runtime);
            runtime.* = .{
                .config = try entry.clone(alloc),
                .db = try graph_live.GraphDb.init(db_path_z),
                .ingest_auth = try test_results_auth.AuthState.initForWorkbookSlug(entry.slug, alloc),
            };
            try workbooks.put(try alloc.dupe(u8, entry.id), runtime);
        }

        return .{
            .live_config = cfg,
            .active_workbook_id = if (cfg.active_workbook_id) |id| try alloc.dupe(u8, id) else null,
            .workbooks = workbooks,
        };
    }

    pub fn deinit(self: *WorkbookRegistry, alloc: Allocator) void {
        var it = self.workbooks.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(alloc);
            alloc.destroy(entry.value_ptr.*);
        }
        self.workbooks.deinit();
        if (self.active_workbook_id) |id| alloc.free(id);
        self.live_config.deinit(alloc);
    }

    pub fn active(self: *WorkbookRegistry) !*workbook_runtime.WorkbookRuntime {
        const id = self.active_workbook_id orelse return error.NoActiveWorkbook;
        return self.workbooks.get(id) orelse return error.NoActiveWorkbook;
    }

    pub fn activeConfig(self: *WorkbookRegistry) !*workbook_config.WorkbookConfig {
        return workbook_config.activeWorkbook(&self.live_config) orelse error.NoActiveWorkbook;
    }

    pub fn save(self: *WorkbookRegistry, alloc: Allocator) !void {
        if (self.active_workbook_id) |id| {
            if (self.workbooks.get(id)) |runtime| {
                const cfg = workbook_config.activeWorkbook(&self.live_config) orelse return error.NoActiveWorkbook;
                cfg.deinit(alloc);
                cfg.* = try runtime.config.clone(alloc);
            }
        }
        try workbook_config.save(&self.live_config, alloc);
    }
};
