const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const json_util = @import("../json_util.zig");
const query = @import("query.zig");

pub fn soupRegisterMarkdown(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const components_json = try query.getSoupComponentsJson(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(components_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, components_json, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# SOUP Register Report\n\n- Product: `{s}`\n- BOM: `{s}`\n\n", .{ full_product_identifier, bom_name });
    try buf.appendSlice(alloc, "## Components\n\n| Component | Version | Supplier | Category | License | Safety Class | Requirement IDs | Test IDs | Statuses |\n|---|---|---|---|---|---|---|---|---|\n");
    const components = json_util.getObjectField(parsed.value, "components") orelse return alloc.dupe(u8, buf.items);
    if (components != .array or components.array.items.len == 0) {
        try buf.appendSlice(alloc, "| — | — | — | — | — | — | — | — | — |\n");
        return alloc.dupe(u8, buf.items);
    }
    for (components.array.items) |component| {
        const props = json_util.getObjectField(component, "properties") orelse continue;
        const reqs = try markdownJoinStringArray(json_util.getObjectField(props, "requirement_ids"), alloc);
        defer alloc.free(reqs);
        const tests = try markdownJoinStringArray(json_util.getObjectField(props, "test_ids"), alloc);
        defer alloc.free(tests);
        const statuses = try markdownJoinStringArray(json_util.getObjectField(component, "statuses"), alloc);
        defer alloc.free(statuses);
        try std.fmt.format(
            buf.writer(alloc),
            "| {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n",
            .{
                json_util.getString(props, "part") orelse "—",
                json_util.getString(props, "revision") orelse "—",
                json_util.getString(props, "supplier") orelse "—",
                json_util.getString(props, "category") orelse "—",
                json_util.getString(props, "license") orelse "—",
                json_util.getString(props, "safety_class") orelse "—",
                reqs,
                tests,
                statuses,
            },
        );
    }
    return alloc.dupe(u8, buf.items);
}

fn markdownJoinStringArray(value: ?std.json.Value, alloc: Allocator) ![]const u8 {
    const field = value orelse return alloc.dupe(u8, "—");
    if (field != .array or field.array.items.len == 0) return alloc.dupe(u8, "—");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (field.array.items, 0..) |entry, idx| {
        if (entry != .string) continue;
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, entry.string);
    }
    if (buf.items.len == 0) return alloc.dupe(u8, "—");
    return alloc.dupe(u8, buf.items);
}
