const std = @import("std");
const internal = @import("internal.zig");
const port_db = @import("port_db.zig");
const writeback = @import("writeback.zig");
const state_mod = @import("state.zig");

pub fn runSyncCycle(
    db: *internal.GraphDb,
    profile_id: internal.profile_mod.ProfileId,
    workbook_slug: []const u8,
    workbook_display_name: []const u8,
    workbook_path: []const u8,
    runtime: *internal.ProviderRuntime,
    state: *state_mod.SyncState,
    alloc: internal.Allocator,
) anyerror!void {
    _ = state;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const tests_rows = try runtime.readRows("Tests", a);
    const un_rows = try runtime.readRows("User Needs", a);
    const req_rows = try runtime.readRows("Requirements", a);
    const risk_rows = try runtime.readRows("Risks", a);
    const existing_tabs = try runtime.listTabs(a);
    defer internal.online_provider.freeTabRefs(existing_tabs, a);
    const enable_decomposition_tab = profile_id == .aerospace;
    const di_rows = try readOptionalTab(runtime, existing_tabs, "Design Inputs", a);
    const do_rows = try readOptionalTab(runtime, existing_tabs, "Design Outputs", a);
    const ci_rows = try readOptionalTab(runtime, existing_tabs, "Configuration Items", a);
    const product_rows = try readOptionalTab(runtime, existing_tabs, "Product", a);
    const decomposition_rows = if (enable_decomposition_tab)
        try readOptionalTab(runtime, existing_tabs, "Decomposition", a)
    else
        &.{};

    const sheet_data = [_]internal.xlsx.SheetData{
        .{ .name = "Tests", .rows = @ptrCast(tests_rows) },
        .{ .name = "User Needs", .rows = @ptrCast(un_rows) },
        .{ .name = "Requirements", .rows = @ptrCast(req_rows) },
        .{ .name = "Risks", .rows = @ptrCast(risk_rows) },
        .{ .name = "Design Inputs", .rows = @ptrCast(di_rows) },
        .{ .name = "Design Outputs", .rows = @ptrCast(do_rows) },
        .{ .name = "Configuration Items", .rows = @ptrCast(ci_rows) },
        .{ .name = "Product", .rows = @ptrCast(product_rows) },
        .{ .name = "Decomposition", .rows = @ptrCast(decomposition_rows) },
    };

    var g = internal.graph_mod.Graph.init(a);
    defer g.deinit();

    var diag = internal.diagnostic_mod.Diagnostics.init(a);
    defer diag.deinit();

    _ = internal.schema.ingestValidatedWithOptions(&g, &sheet_data, &diag, .{
        .enable_product_tab = true,
        .enable_decomposition_tab = enable_decomposition_tab,
        .enable_design_inputs_tab = profile_id == .medical,
        .enable_design_outputs_tab = profile_id == .medical,
        .enable_config_items_tab = profile_id != .generic,
        .rtm_artifact_id = try std.fmt.allocPrint(a, "artifact://rtm/{s}", .{workbook_slug}),
        .rtm_artifact_display_name = workbook_display_name,
        .rtm_artifact_path = workbook_path,
    }) catch |e| {
        std.log.warn("sync: ingest errors (continuing): {s}", .{@errorName(e)});
    };

    try port_db.portGraphToDb(db, &g, alloc);
    try writeback.writeBackStatus(db, runtime, req_rows, risk_rows, un_rows, product_rows, a);

    std.log.info("sync: cycle complete — {d} nodes", .{g.nodes.count()});
}

pub fn readOptionalTab(runtime: *internal.ProviderRuntime, existing_tabs: []const internal.online_provider.TabRef, tab_name: []const u8, alloc: internal.Allocator) ![][][]const u8 {
    if (!tabExists(existing_tabs, tab_name)) return &.{};
    return runtime.readRows(tab_name, alloc) catch &.{};
}

pub fn tabExists(existing_tabs: []const internal.online_provider.TabRef, want: []const u8) bool {
    for (existing_tabs) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, want)) return true;
        if (containsIgnoreCase(tab.title, want) or containsIgnoreCase(want, tab.title)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    var hay_buf: [128]u8 = undefined;
    var needle_buf: [128]u8 = undefined;
    const hay_len = @min(haystack.len, hay_buf.len);
    const needle_len = @min(needle.len, needle_buf.len);
    for (haystack[0..hay_len], 0..) |c, i| hay_buf[i] = std.ascii.toLower(c);
    for (needle[0..needle_len], 0..) |c, i| needle_buf[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, hay_buf[0..hay_len], needle_buf[0..needle_len]) != null;
}
