const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const encode = @import("encode.zig");

pub const SUSPECT_FORWARD = [_][]const u8{ "TESTED_BY", "HAS_TEST", "MITIGATED_BY", "IMPLEMENTED_IN", "VERIFIED_BY_CODE" };
pub const SUSPECT_BACKWARD = [_][]const u8{"MITIGATED_BY"};

pub fn isSuspectForward(label: []const u8) bool {
    for (SUSPECT_FORWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

pub fn isSuspectBackward(label: []const u8) bool {
    for (SUSPECT_BACKWARD) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

pub fn propagateSuspectLocked(g: anytype, changed_id: []const u8) !void {
    var fwd = try g.db.prepare("SELECT label, to_id FROM edges WHERE from_id=?");
    defer fwd.finalize();
    try fwd.bindText(1, changed_id);

    var fwd_targets: [64]struct { label: [64]u8, label_len: usize, to_id: [256]u8, to_id_len: usize } = undefined;
    var fwd_count: usize = 0;
    while (try fwd.step()) {
        if (fwd_count >= fwd_targets.len) break;
        const label = fwd.columnText(0);
        const to_id = fwd.columnText(1);
        @memcpy(fwd_targets[fwd_count].label[0..label.len], label);
        fwd_targets[fwd_count].label_len = label.len;
        @memcpy(fwd_targets[fwd_count].to_id[0..to_id.len], to_id);
        fwd_targets[fwd_count].to_id_len = to_id.len;
        fwd_count += 1;
    }

    for (fwd_targets[0..fwd_count]) |t| {
        const label = t.label[0..t.label_len];
        const to_id = t.to_id[0..t.to_id_len];
        if (isSuspectForward(label)) {
            try setSuspectLocked(g, to_id, changed_id);
        }
    }

    var bwd = try g.db.prepare("SELECT label, from_id FROM edges WHERE to_id=?");
    defer bwd.finalize();
    try bwd.bindText(1, changed_id);

    var bwd_targets: [64]struct { label: [64]u8, label_len: usize, from_id: [256]u8, from_id_len: usize } = undefined;
    var bwd_count: usize = 0;
    while (try bwd.step()) {
        if (bwd_count >= bwd_targets.len) break;
        const label = bwd.columnText(0);
        const from_id = bwd.columnText(1);
        @memcpy(bwd_targets[bwd_count].label[0..label.len], label);
        bwd_targets[bwd_count].label_len = label.len;
        @memcpy(bwd_targets[bwd_count].from_id[0..from_id.len], from_id);
        bwd_targets[bwd_count].from_id_len = from_id.len;
        bwd_count += 1;
    }

    for (bwd_targets[0..bwd_count]) |t| {
        const label = t.label[0..t.label_len];
        const from_id = t.from_id[0..t.from_id_len];
        if (isSuspectBackward(label)) {
            try setSuspectLocked(g, from_id, changed_id);
        }
    }
}

pub fn setSuspectLocked(g: anytype, node_id: []const u8, reason_node: []const u8) !void {
    var reason_buf: [300]u8 = undefined;
    const reason = std.fmt.bufPrint(&reason_buf, "{s} changed", .{reason_node}) catch reason_buf[0..];
    var st = try g.db.prepare("UPDATE nodes SET suspect=1, suspect_reason=? WHERE id=?");
    defer st.finalize();
    try st.bindText(1, reason);
    try st.bindText(2, node_id);
    _ = try st.step();
}

pub fn clearSuspect(g: anytype, id: []const u8) !void {
    g.db.write_mu.lock();
    defer g.db.write_mu.unlock();
    var st = try g.db.prepare("UPDATE nodes SET suspect=0, suspect_reason=NULL WHERE id=?");
    defer st.finalize();
    try st.bindText(1, id);
    _ = try st.step();
}

pub fn suspects(g: anytype, alloc: Allocator, result: *std.ArrayList(types.Node)) !void {
    var st = try g.db.prepare(
        "SELECT id, type, properties, suspect, suspect_reason FROM nodes WHERE suspect=1 ORDER BY type, id"
    );
    defer st.finalize();
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToNodeResolved(g, &st, alloc));
    }
}
