const std = @import("std");
const columns = @import("../columns.zig");
const normalize = @import("../normalize.zig");
const cross_ref = @import("../cross_ref.zig");
const internal = @import("../internal.zig");
const diagnostic = @import("../../diagnostic.zig");

pub fn ingest(ctx: *const internal.IngestContext, sheet: internal.SheetData, stats: *internal.IngestStats) !void {
    const g = ctx.g;
    const diag = ctx.diag;
    if (sheet.rows.len < 2) return;
    const headers = sheet.rows[0];
    const data = sheet.rows[1..];
    const a = diag.arena.allocator();

    const c_id = columns.resolveCol(headers, data, "ID", columns.req_id_syns, sheet.name, diag, true);
    const c_un = columns.resolveCol(headers, &.{}, "User Need iD", columns.req_un_syns, sheet.name, diag, false);
    const c_stmt = columns.resolveCol(headers, &.{}, "Statement", columns.req_stmt_syns, sheet.name, diag, false);
    const c_pri = columns.resolveCol(headers, &.{}, "Priority", columns.req_pri_syns, sheet.name, diag, false);
    const c_tgid = columns.resolveCol(headers, &.{}, "Test Group IDs", columns.req_tg_syns, sheet.name, diag, false);
    const c_status = columns.resolveCol(headers, &.{}, "Lifecycle Status", columns.req_status_syns, sheet.name, diag, false);
    const c_notes = columns.resolveCol(headers, &.{}, "Notes", columns.req_notes_syns, sheet.name, diag, false);

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

        const tg_raw = internal.cell(row, c_tgid);
        var declared_test_group_ref_count: usize = 0;
        if (!normalize.isBlankEquivalent(tg_raw)) {
            for (try normalize.splitIds(tg_raw, a)) |part| {
                const tg_id = try normalize.normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (tg_id.len == 0) continue;
                declared_test_group_ref_count += 1;
            }
        }
        const declared_test_group_ref_count_str = try std.fmt.allocPrint(a, "{d}", .{declared_test_group_ref_count});

        try g.addNode(id, .requirement, &.{
            .{ .key = "statement", .value = internal.cell(row, c_stmt) },
            .{ .key = "priority", .value = internal.cell(row, c_pri) },
            .{ .key = "status", .value = internal.cell(row, c_status) },
            .{ .key = "notes", .value = internal.cell(row, c_notes) },
            .{ .key = "declared_test_group_ref_count", .value = declared_test_group_ref_count_str },
        });
        stats.requirement_count += 1;

        const un_raw = internal.cell(row, c_un);
        if (!normalize.isBlankEquivalent(un_raw)) {
            for (try normalize.splitIds(un_raw, a)) |part| {
                const un_id = try normalize.normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (un_id.len == 0) continue;
                try cross_ref.checkCrossRef(g, un_id, .user_need, diag, sheet.name, @intCast(ri + 2));
                try g.addEdge(id, un_id, .derives_from);
            }
        }

        if (!normalize.isBlankEquivalent(tg_raw)) {
            for (try normalize.splitIds(tg_raw, a)) |part| {
                const tg_id = try normalize.normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (tg_id.len == 0) continue;
                try cross_ref.checkCrossRef(g, tg_id, .test_group, diag, sheet.name, @intCast(ri + 2));
                try g.addEdge(id, tg_id, .tested_by);
            }
        }
    }
}
