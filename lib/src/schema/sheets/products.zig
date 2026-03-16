const std = @import("std");
const columns = @import("../columns.zig");
const normalize = @import("../normalize.zig");
const internal = @import("../internal.zig");
const diagnostic = @import("../../diagnostic.zig");

pub fn ingest(ctx: *const internal.IngestContext, sheet: internal.SheetData, stats: *internal.IngestStats) !void {
    const g = ctx.g;
    const diag = ctx.diag;
    if (sheet.rows.len < 2) {
        try diag.info(diagnostic.E.product_none_declared, .profile, sheet.name, null,
            "Product tab has no declared products", .{});
        return;
    }

    const headers = sheet.rows[0];
    const data = sheet.rows[1..];
    const a = diag.arena.allocator();

    const c_assembly = columns.resolveCol(headers, &.{}, "assembly", columns.product_assembly_syns, sheet.name, diag, false);
    const c_revision = columns.resolveCol(headers, &.{}, "revision", columns.product_revision_syns, sheet.name, diag, false);
    const c_identifier = columns.resolveCol(headers, &.{}, "full_identifier", columns.product_identifier_syns, sheet.name, diag, false);
    const c_description = columns.resolveCol(headers, &.{}, "description", columns.product_description_syns, sheet.name, diag, false);
    const c_status = columns.resolveCol(headers, &.{}, "Product Status", columns.product_status_syns, sheet.name, diag, false);

    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var declared_count: usize = 0;

    for (data, 0..) |row, ri| {
        const assembly_raw = internal.cell(row, c_assembly);
        const revision_raw = internal.cell(row, c_revision);
        const identifier_raw = internal.cell(row, c_identifier);
        const description_raw = internal.cell(row, c_description);
        const status_raw = internal.cell(row, c_status);

        if (normalize.isBlankEquivalent(assembly_raw) and
            normalize.isBlankEquivalent(revision_raw) and
            normalize.isBlankEquivalent(identifier_raw) and
            normalize.isBlankEquivalent(description_raw) and
            normalize.isBlankEquivalent(status_raw))
        {
            continue;
        }

        const assembly = try normalize.normalizeProductField(assembly_raw, a);
        const revision = try normalize.normalizeProductField(revision_raw, a);
        const full_identifier = try normalize.normalizeProductField(identifier_raw, a);
        const description = try normalize.normalizeProductField(description_raw, a);
        const product_status = try normalize.normalizeProductField(status_raw, a);
        const row_num: u32 = @intCast(ri + 2);

        if (full_identifier.len == 0 or normalize.isBlankEquivalent(full_identifier)) {
            try diag.warn(diagnostic.E.product_full_identifier_missing, .row_parsing, sheet.name, row_num,
                "Product row missing full_identifier — skipping", .{});
            continue;
        }

        if (seen.contains(full_identifier)) {
            try diag.add(.err, diagnostic.E.product_duplicate_full_identifier, .row_parsing, sheet.name, row_num,
                "duplicate Product full_identifier '{s}' — skipping", .{full_identifier});
            continue;
        }
        try seen.put(full_identifier, {});
        declared_count += 1;

        const node_id = try std.fmt.allocPrint(a, "product://{s}", .{full_identifier});
        try g.addNode(node_id, .product, &.{
            .{ .key = "assembly", .value = assembly },
            .{ .key = "revision", .value = revision },
            .{ .key = "full_identifier", .value = full_identifier },
            .{ .key = "description", .value = description },
            .{ .key = "product_status", .value = product_status },
        });
        stats.product_count += 1;
    }

    if (declared_count == 0) {
        try diag.info(diagnostic.E.product_none_declared, .profile, sheet.name, null,
            "Product tab has no declared products", .{});
    }
}
