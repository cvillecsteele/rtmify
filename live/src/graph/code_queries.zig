const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const encode = @import("encode.zig");

pub fn nodesByRepo(g: anytype, repo_path: []const u8, alloc: Allocator, result: *std.ArrayList(types.Node)) !void {
    var st = try g.db.prepare(
        \\SELECT id, type, properties, suspect, suspect_reason FROM nodes
        \\WHERE type IN ('SourceFile','TestFile')
        \\AND json_extract(properties,'$.repo') = ?
        \\AND COALESCE(json_extract(properties,'$.present'), 1) != 0
        \\ORDER BY id
    );
    defer st.finalize();
    try st.bindText(1, repo_path);
    while (try st.step()) {
        try result.append(alloc, try encode.stmtToNodeResolved(g, &st, alloc));
    }
}

pub fn requirementsWithImplementationChangesSince(
    g: anytype,
    since: []const u8,
    repo_path: ?[]const u8,
    alloc: Allocator,
    result: *std.ArrayList(types.ImplementationChangeEvidence),
) !void {
    var st = try g.db.prepare(
        \\SELECT DISTINCT
        \\  req.id,
        \\  req.type,
        \\  req.id,
        \\  file.id,
        \\  cmt.id,
        \\  json_extract(cmt.properties,'$.short_hash'),
        \\  json_extract(cmt.properties,'$.date'),
        \\  json_extract(cmt.properties,'$.message')
        \\FROM nodes req
        \\JOIN edges impl ON impl.from_id = req.id AND impl.label = 'IMPLEMENTED_IN'
        \\JOIN nodes file ON file.id = impl.to_id AND file.type = 'SourceFile'
        \\JOIN edges chg ON chg.from_id = file.id AND chg.label = 'CHANGED_IN'
        \\JOIN nodes cmt ON cmt.id = chg.to_id AND cmt.type = 'Commit'
        \\WHERE req.type = 'Requirement'
        \\  AND json_extract(cmt.properties,'$.date') > ?
        \\  AND (? IS NULL OR json_extract(file.properties,'$.repo') = ?)
        \\ORDER BY json_extract(cmt.properties,'$.date') DESC, req.id, file.id
    );
    defer st.finalize();
    try st.bindText(1, since);
    if (repo_path) |rp| {
        try st.bindText(2, rp);
        try st.bindText(3, rp);
    } else {
        try st.bindNull(2);
        try st.bindNull(3);
    }
    while (try st.step()) {
        try result.append(alloc, .{
            .node_id = try alloc.dupe(u8, st.columnText(0)),
            .node_type = try alloc.dupe(u8, st.columnText(1)),
            .requirement_id = try alloc.dupe(u8, st.columnText(2)),
            .file_id = try alloc.dupe(u8, st.columnText(3)),
            .commit_id = try alloc.dupe(u8, st.columnText(4)),
            .commit_short_hash = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
            .commit_date = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
            .commit_message = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
        });
    }
}

pub fn userNeedsWithImplementationChangesSince(
    g: anytype,
    since: []const u8,
    repo_path: ?[]const u8,
    alloc: Allocator,
    result: *std.ArrayList(types.ImplementationChangeEvidence),
) !void {
    var st = try g.db.prepare(
        \\SELECT DISTINCT
        \\  un.id,
        \\  un.type,
        \\  req.id,
        \\  file.id,
        \\  cmt.id,
        \\  json_extract(cmt.properties,'$.short_hash'),
        \\  json_extract(cmt.properties,'$.date'),
        \\  json_extract(cmt.properties,'$.message')
        \\FROM nodes un
        \\JOIN edges drv ON drv.to_id = un.id AND drv.label = 'DERIVES_FROM'
        \\JOIN nodes req ON req.id = drv.from_id AND req.type = 'Requirement'
        \\JOIN edges impl ON impl.from_id = req.id AND impl.label = 'IMPLEMENTED_IN'
        \\JOIN nodes file ON file.id = impl.to_id AND file.type = 'SourceFile'
        \\JOIN edges chg ON chg.from_id = file.id AND chg.label = 'CHANGED_IN'
        \\JOIN nodes cmt ON cmt.id = chg.to_id AND cmt.type = 'Commit'
        \\WHERE un.type = 'UserNeed'
        \\  AND json_extract(cmt.properties,'$.date') > ?
        \\  AND (? IS NULL OR json_extract(file.properties,'$.repo') = ?)
        \\ORDER BY json_extract(cmt.properties,'$.date') DESC, un.id, req.id, file.id
    );
    defer st.finalize();
    try st.bindText(1, since);
    if (repo_path) |rp| {
        try st.bindText(2, rp);
        try st.bindText(3, rp);
    } else {
        try st.bindNull(2);
        try st.bindNull(3);
    }
    while (try st.step()) {
        try result.append(alloc, .{
            .node_id = try alloc.dupe(u8, st.columnText(0)),
            .node_type = try alloc.dupe(u8, st.columnText(1)),
            .requirement_id = try alloc.dupe(u8, st.columnText(2)),
            .file_id = try alloc.dupe(u8, st.columnText(3)),
            .commit_id = try alloc.dupe(u8, st.columnText(4)),
            .commit_short_hash = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
            .commit_date = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
            .commit_message = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
        });
    }
}
