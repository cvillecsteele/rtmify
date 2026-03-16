const std = @import("std");
const internal = @import("../internal.zig");

pub fn freeValueUpdates(updates: *std.ArrayList(internal.ValueUpdate), alloc: internal.Allocator) void {
    for (updates.items) |upd| {
        alloc.free(upd.a1_range);
        for (upd.values) |value| alloc.free(value);
        alloc.free(upd.values);
    }
    updates.deinit(alloc);
}

pub fn findSingleValueUpdate(updates: []const internal.ValueUpdate, range: []const u8) ?[]const u8 {
    for (updates) |upd| {
        if (std.mem.eql(u8, upd.a1_range, range)) return upd.values[0];
    }
    return null;
}

pub fn freeEdges(edges: *std.ArrayList(internal.graph_live.Edge), alloc: internal.Allocator) void {
    for (edges.items) |e| {
        alloc.free(e.id);
        alloc.free(e.from_id);
        alloc.free(e.to_id);
        alloc.free(e.label);
    }
    edges.deinit(alloc);
}

pub fn freeRuntimeDiagnostics(diags: *std.ArrayList(internal.graph_live.RuntimeDiagnostic), alloc: internal.Allocator) void {
    for (diags.items) |d| {
        alloc.free(d.dedupe_key);
        alloc.free(d.severity);
        alloc.free(d.title);
        alloc.free(d.message);
        alloc.free(d.source);
        if (d.subject) |s| alloc.free(s);
        alloc.free(d.details_json);
    }
    diags.deinit(alloc);
}
