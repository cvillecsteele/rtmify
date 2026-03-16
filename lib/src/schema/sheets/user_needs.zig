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

    const c_id = columns.resolveCol(headers, data, "ID", columns.un_id_syns, sheet.name, diag, true);
    const c_stmt = columns.resolveCol(headers, &.{}, "Statement", columns.un_stmt_syns, sheet.name, diag, false);
    const c_src = columns.resolveCol(headers, &.{}, "Source of Need Statement", columns.un_source_syns, sheet.name, diag, false);
    const c_pri = columns.resolveCol(headers, &.{}, "Priority", columns.un_pri_syns, sheet.name, diag, false);

    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();

    for (data, 0..) |row, ri| {
        if (normalize.isSectionDivider(row, c_id)) continue;
        const raw_id = internal.cell(row, c_id);
        if (raw_id.len == 0) {
            try diag.warn(diagnostic.E.row_no_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "row has content but ID column is empty — skipping", .{});
            continue;
        }
        const id = try normalize.normalizeId(raw_id, a, diag, sheet.name, @intCast(ri + 2));
        if (id.len == 0) continue;
        if (seen.contains(id)) {
            try diag.warn(diagnostic.E.duplicate_id, .row_parsing, sheet.name, @intCast(ri + 2),
                "duplicate ID '{s}' — skipping", .{id});
            continue;
        }
        try seen.put(id, {});

        try g.addNode(id, .user_need, &.{
            .{ .key = "statement", .value = internal.cell(row, c_stmt) },
            .{ .key = "source", .value = internal.cell(row, c_src) },
            .{ .key = "priority", .value = internal.cell(row, c_pri) },
        });
        stats.user_need_count += 1;
    }
}
