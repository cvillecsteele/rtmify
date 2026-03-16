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

    const c_id = columns.resolveCol(headers, data, "ID", columns.do_id_syns, sheet.name, diag, true);
    const c_desc = columns.resolveCol(headers, &.{}, "Description", columns.do_desc_syns, sheet.name, diag, false);
    const c_type = columns.resolveCol(headers, &.{}, "Type", columns.do_type_syns, sheet.name, diag, false);
    const c_di = columns.resolveCol(headers, &.{}, "Design Input ID", columns.do_di_syns, sheet.name, diag, false);
    const c_ver = columns.resolveCol(headers, &.{}, "Version", columns.do_ver_syns, sheet.name, diag, false);
    const c_status = columns.resolveCol(headers, &.{}, "Status", columns.do_status_syns, sheet.name, diag, false);

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

        try g.addNode(id, .design_output, &.{
            .{ .key = "description", .value = internal.cell(row, c_desc) },
            .{ .key = "type", .value = internal.cell(row, c_type) },
            .{ .key = "version", .value = internal.cell(row, c_ver) },
            .{ .key = "status", .value = internal.cell(row, c_status) },
        });
        stats.design_output_count += 1;

        const di_raw = internal.cell(row, c_di);
        if (!normalize.isBlankEquivalent(di_raw)) {
            for (try normalize.splitIds(di_raw, a)) |part| {
                const di_id = try normalize.normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (di_id.len == 0) continue;
                try g.addEdge(di_id, id, .satisfied_by);
            }
        }
    }
}
