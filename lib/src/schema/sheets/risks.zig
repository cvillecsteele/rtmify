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

    const c_id = columns.resolveCol(headers, data, "Risk ID", columns.risk_id_syns, sheet.name, diag, true);
    const c_desc = columns.resolveCol(headers, &.{}, "Description", columns.risk_desc_syns, sheet.name, diag, false);
    const c_isev = columns.resolveCol(headers, &.{}, "Initial Severity", columns.risk_isev_syns, sheet.name, diag, false);
    const c_ilik = columns.resolveCol(headers, &.{}, "Initial Likelihood", columns.risk_ilik_syns, sheet.name, diag, false);
    const c_mit = columns.resolveCol(headers, &.{}, "Mitigation", columns.risk_mit_syns, sheet.name, diag, false);
    const c_req = columns.resolveCol(headers, &.{}, "Linked REQ", columns.risk_req_syns, sheet.name, diag, false);
    const c_rsev = columns.resolveCol(headers, &.{}, "Residual Severity", columns.risk_rsev_syns, sheet.name, diag, false);
    const c_rlik = columns.resolveCol(headers, &.{}, "Residual Likelihood", columns.risk_rlik_syns, sheet.name, diag, false);

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

        const isev = try normalize.parseNumericField(internal.cell(row, c_isev), diag, sheet.name, @intCast(ri + 2), "Initial Severity") orelse "";
        const ilik = try normalize.parseNumericField(internal.cell(row, c_ilik), diag, sheet.name, @intCast(ri + 2), "Initial Likelihood") orelse "";
        const rsev = try normalize.parseNumericField(internal.cell(row, c_rsev), diag, sheet.name, @intCast(ri + 2), "Residual Severity") orelse "";
        const rlik = try normalize.parseNumericField(internal.cell(row, c_rlik), diag, sheet.name, @intCast(ri + 2), "Residual Likelihood") orelse "";

        const req_raw = internal.cell(row, c_req);
        var declared_mitigation_req_ref_count: usize = 0;
        if (!normalize.isBlankEquivalent(req_raw)) {
            for (try normalize.splitIds(req_raw, a)) |part| {
                const req_id = try normalize.normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (req_id.len == 0) continue;
                declared_mitigation_req_ref_count += 1;
            }
        }
        const declared_mitigation_req_ref_count_str = try std.fmt.allocPrint(a, "{d}", .{declared_mitigation_req_ref_count});

        try g.addNode(id, .risk, &.{
            .{ .key = "description", .value = internal.cell(row, c_desc) },
            .{ .key = "initial_severity", .value = isev },
            .{ .key = "initial_likelihood", .value = ilik },
            .{ .key = "mitigation", .value = internal.cell(row, c_mit) },
            .{ .key = "residual_severity", .value = rsev },
            .{ .key = "residual_likelihood", .value = rlik },
            .{ .key = "declared_mitigation_req_ref_count", .value = declared_mitigation_req_ref_count_str },
        });
        stats.risk_count += 1;

        if (!normalize.isBlankEquivalent(req_raw)) {
            for (try normalize.splitIds(req_raw, a)) |part| {
                const req_id = try normalize.normalizeId(part, a, diag, sheet.name, @intCast(ri + 2));
                if (req_id.len == 0) continue;
                try cross_ref.checkCrossRef(g, req_id, .requirement, diag, sheet.name, @intCast(ri + 2));
                try g.addEdge(id, req_id, .mitigated_by);
            }
        }
    }
}
