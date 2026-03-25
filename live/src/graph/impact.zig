const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub const IMPACT_FORWARD = [_][]const u8{
    "TESTED_BY",
    "HAS_TEST",
    "ALLOCATED_TO",
    "SATISFIED_BY",
    "CONTROLLED_BY",
    "IMPLEMENTED_IN",
    "VERIFIED_BY_CODE",
    "REFINED_BY",
};
pub const IMPACT_BACKWARD = [_][]const u8{
    "DERIVES_FROM",
    "MITIGATED_BY",
};

pub fn isImpactForward(label: []const u8) bool {
    for (IMPACT_FORWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

pub fn isImpactBackward(label: []const u8) bool {
    for (IMPACT_BACKWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

pub fn impact(g: anytype, node_id: []const u8, alloc: Allocator, result: *std.ArrayList(types.ImpactNode)) !void {
    var visited: std.StringHashMapUnmanaged(void) = .{};
    defer visited.deinit(alloc);
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(alloc);
    try queue.append(alloc, try alloc.dupe(u8, node_id));

    var qi: usize = 0;
    while (qi < queue.items.len) {
        const current = queue.items[qi];
        qi += 1;

        var fwd_st = try g.db.prepare("SELECT label, to_id FROM edges WHERE from_id=?");
        defer fwd_st.finalize();
        try fwd_st.bindText(1, current);
        while (try fwd_st.step()) {
            const label = try alloc.dupe(u8, fwd_st.columnText(0));
            const to_id = try alloc.dupe(u8, fwd_st.columnText(1));
            if (isImpactForward(label) and !visited.contains(to_id)) {
                try visited.put(alloc, to_id, {});
                if (try g.getNode(to_id, alloc)) |n| {
                    try result.append(alloc, .{
                        .id = n.id,
                        .type = n.type,
                        .properties = n.properties,
                        .via = label,
                        .dir = "→",
                    });
                    try queue.append(alloc, to_id);
                }
            }
        }

        var bwd_st = try g.db.prepare("SELECT label, from_id FROM edges WHERE to_id=?");
        defer bwd_st.finalize();
        try bwd_st.bindText(1, current);
        while (try bwd_st.step()) {
            const label = try alloc.dupe(u8, bwd_st.columnText(0));
            const from_id = try alloc.dupe(u8, bwd_st.columnText(1));
            if (isImpactBackward(label) and !visited.contains(from_id)) {
                try visited.put(alloc, from_id, {});
                if (try g.getNode(from_id, alloc)) |n| {
                    try result.append(alloc, .{
                        .id = n.id,
                        .type = n.type,
                        .properties = n.properties,
                        .via = label,
                        .dir = "←",
                    });
                    try queue.append(alloc, from_id);
                }
            }
        }
    }
}
