const std = @import("std");
const columns = @import("../columns.zig");
const normalize = @import("../normalize.zig");
const internal = @import("../internal.zig");
const diagnostic = @import("../../diagnostic.zig");

pub fn ingest(ctx: *const internal.IngestContext, sheet: internal.SheetData, stats: *internal.IngestStats) !void {
    const g = ctx.g;
    const diag = ctx.diag;
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];
    const data = sheet.rows[1..];
    const a = diag.arena.allocator();

    const c_tgid = columns.resolveCol(headers, data, "Test Group ID", columns.tst_tgid_syns, sheet.name, diag, true);
    const c_tid = columns.resolveCol(headers, data, "Test ID", columns.tst_id_syns, sheet.name, diag, false);
    const c_type = columns.resolveCol(headers, &.{}, "Test Type", columns.tst_type_syns, sheet.name, diag, false);
    const c_method = columns.resolveCol(headers, &.{}, "Test Method", columns.tst_method_syns, sheet.name, diag, false);

    var seen_tests = std.StringHashMap(void).init(a);
    defer seen_tests.deinit();

    for (data, 0..) |row, ri| {
        if (normalize.isSectionDivider(row, c_tgid)) continue;
        const raw_tg = internal.cell(row, c_tgid);
        const raw_t = internal.cell(row, c_tid);
        if (raw_tg.len == 0 and raw_t.len == 0) continue;

        const tg_id = if (raw_tg.len > 0)
            try normalize.normalizeId(raw_tg, a, diag, sheet.name, @intCast(ri + 2))
        else
            "";
        const t_id = if (raw_t.len > 0)
            try normalize.normalizeId(raw_t, a, diag, sheet.name, @intCast(ri + 2))
        else
            "";

        if (tg_id.len > 0) {
            const was_new = !g.nodes.contains(tg_id);
            try g.addNode(tg_id, .test_group, &.{});
            if (was_new) stats.test_group_count += 1;
        }

        if (t_id.len > 0 and tg_id.len > 0) {
            if (seen_tests.contains(t_id)) {
                try diag.warn(diagnostic.E.duplicate_test_id, .row_parsing, sheet.name, @intCast(ri + 2),
                    "duplicate Test ID '{s}' — skipping", .{t_id});
                continue;
            }
            try seen_tests.put(t_id, {});
            try g.addNode(t_id, .test_case, &.{
                .{ .key = "test_type", .value = internal.cell(row, c_type) },
                .{ .key = "test_method", .value = internal.cell(row, c_method) },
            });
            try g.addEdge(tg_id, t_id, .has_test);
            stats.test_count += 1;
        }
    }
}
