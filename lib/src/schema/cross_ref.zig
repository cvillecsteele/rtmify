const std = @import("std");
const graph = @import("../graph.zig");
const diagnostic = @import("../diagnostic.zig");
const internal = @import("internal.zig");

const Diagnostics = internal.Diagnostics;
const Graph = internal.Graph;

pub fn checkCrossRef(
    g: *const Graph,
    ref_id: []const u8,
    expected_type: graph.NodeType,
    diag: *Diagnostics,
    tab: []const u8,
    row_num: u32,
) !void {
    if (g.getNode(ref_id)) |target| {
        if (target.node_type != expected_type) {
            try diag.warn(diagnostic.E.ref_wrong_type, .cross_ref, tab, row_num,
                "reference '{s}' resolves to a {s} node but a {s} was expected here — check the ID",
                .{ ref_id, target.node_type.toString(), expected_type.toString() });
        }
    } else {
        var samples: [5][]const u8 = undefined;
        var sample_count: usize = 0;
        var total: usize = 0;
        var it = g.nodes.valueIterator();
        while (it.next()) |ptr| {
            if (ptr.*.node_type == expected_type) {
                total += 1;
                if (sample_count < 5) {
                    samples[sample_count] = ptr.*.id;
                    sample_count += 1;
                }
            }
        }
        if (total == 0) {
            try diag.warn(diagnostic.E.ref_not_found, .cross_ref, tab, row_num,
                "reference '{s}' not found (no {s} nodes exist in the graph)",
                .{ ref_id, expected_type.toString() });
        } else {
            const a = diag.arena.allocator();
            var buf: std.ArrayList(u8) = .empty;
            for (samples[0..sample_count], 0..) |s, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try buf.appendSlice(a, s);
            }
            try diag.warn(diagnostic.E.ref_not_found, .cross_ref, tab, row_num,
                "reference '{s}' not found; available {s} IDs: {s} ({d} total)",
                .{ ref_id, expected_type.toString(), buf.items, total });
        }
    }
}
