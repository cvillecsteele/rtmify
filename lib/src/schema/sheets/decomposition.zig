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

    const c_parent = columns.resolveCol(headers, &.{}, "parent_id", columns.decomposition_parent_syns, sheet.name, diag, false);
    const c_child = columns.resolveCol(headers, &.{}, "child_id", columns.decomposition_child_syns, sheet.name, diag, false);

    var seen_pairs = std.StringHashMap(void).init(a);
    defer seen_pairs.deinit();

    for (data, 0..) |row, ri| {
        const row_num: u32 = @intCast(ri + 2);
        const raw_parent = internal.cell(row, c_parent);
        const raw_child = internal.cell(row, c_child);

        if (normalize.isBlankEquivalent(raw_parent) and normalize.isBlankEquivalent(raw_child)) continue;
        if (normalize.isBlankEquivalent(raw_parent)) {
            try diag.warn(diagnostic.E.decomposition_parent_missing, .row_parsing, sheet.name, row_num,
                "Decomposition row missing parent_id — skipping", .{});
            continue;
        }
        if (normalize.isBlankEquivalent(raw_child)) {
            try diag.warn(diagnostic.E.decomposition_child_missing, .row_parsing, sheet.name, row_num,
                "Decomposition row missing child_id — skipping", .{});
            continue;
        }

        const parent_id = try normalize.normalizeId(raw_parent, a, diag, sheet.name, row_num);
        if (parent_id.len == 0) continue;
        const child_id = try normalize.normalizeId(raw_child, a, diag, sheet.name, row_num);
        if (child_id.len == 0) continue;

        if (std.mem.eql(u8, parent_id, child_id)) {
            try diag.warn(diagnostic.E.decomposition_self_reference, .row_parsing, sheet.name, row_num,
                "Decomposition self-reference '{s}' is not allowed — skipping", .{parent_id});
            continue;
        }

        const pair_key = try std.fmt.allocPrint(a, "{s}\x1f{s}", .{ parent_id, child_id });
        if (seen_pairs.contains(pair_key)) {
            try diag.warn(diagnostic.E.decomposition_duplicate, .row_parsing, sheet.name, row_num,
                "duplicate decomposition row '{s}' -> '{s}' — skipping", .{ parent_id, child_id });
            continue;
        }

        const parent = g.getNode(parent_id);
        const child = g.getNode(child_id);
        if (parent == null or child == null or
            parent.?.node_type != .requirement or child.?.node_type != .requirement)
        {
            try diag.warn(diagnostic.E.decomposition_unknown_requirement, .row_parsing, sheet.name, row_num,
                "Decomposition references unknown Requirement ID '{s}' -> '{s}' — skipping", .{ parent_id, child_id });
            continue;
        }

        try seen_pairs.put(pair_key, {});
        try g.addEdge(parent_id, child_id, .refined_by);
        stats.decomposition_count += 1;
    }
}
