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

    const c_id = columns.resolveCol(headers, data, "ID", columns.ci_id_syns, sheet.name, diag, true);
    const c_desc = columns.resolveCol(headers, &.{}, "Description", columns.ci_desc_syns, sheet.name, diag, false);
    const c_type = columns.resolveCol(headers, &.{}, "Type", columns.ci_type_syns, sheet.name, diag, false);
    const c_ver = columns.resolveCol(headers, &.{}, "Version", columns.ci_ver_syns, sheet.name, diag, false);
    const c_do = columns.resolveCol(headers, &.{}, "Design Output ID", columns.ci_do_syns, sheet.name, diag, false);
    const c_status = columns.resolveCol(headers, &.{}, "Status", columns.ci_status_syns, sheet.name, diag, false);

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

        try g.addNode(id, .config_item, &.{
            .{ .key = "description", .value = internal.cell(row, c_desc) },
            .{ .key = "type", .value = internal.cell(row, c_type) },
            .{ .key = "version", .value = internal.cell(row, c_ver) },
            .{ .key = "status", .value = internal.cell(row, c_status) },
        });
        stats.config_item_count += 1;

        const do_raw = internal.cell(row, c_do);
        if (!normalize.isBlankEquivalent(do_raw)) {
            for (try normalize.splitIds(do_raw, a)) |part| {
                const do_id = try normalize.normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (do_id.len == 0) continue;
                try g.addEdge(do_id, id, .controlled_by);
            }
        }
    }
}
