const std = @import("std");
const Allocator = std.mem.Allocator;
const Stmt = @import("../db.zig").Stmt;
const types = @import("types.zig");
const require_text = @import("require_text.zig");

pub fn appendJsonEscaped(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

pub fn appendJsonQuoted(buf: *std.ArrayList(u8), s: []const u8, alloc: Allocator) !void {
    try buf.append(alloc, '"');
    try appendJsonEscaped(buf, s, alloc);
    try buf.append(alloc, '"');
}

pub fn appendJsonValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: Allocator) !void {
    switch (value) {
        .null => try buf.appendSlice(alloc, "null"),
        .bool => |v| try buf.appendSlice(alloc, if (v) "true" else "false"),
        .integer => |v| try std.fmt.format(buf.writer(alloc), "{d}", .{v}),
        .float => |v| try std.fmt.format(buf.writer(alloc), "{d}", .{v}),
        .number_string => |v| try buf.appendSlice(alloc, v),
        .string => |v| try appendJsonQuoted(buf, v, alloc),
        else => try appendJsonQuoted(buf, "", alloc),
    }
}

pub fn sanitizeNodePropertiesJson(node_type: []const u8, properties_json: []const u8, alloc: Allocator) ![]u8 {
    if (!std.mem.eql(u8, node_type, "Requirement")) return alloc.dupe(u8, properties_json);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, properties_json, .{}) catch {
        return alloc.dupe(u8, properties_json);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return alloc.dupe(u8, properties_json);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, '{');
    var first = true;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "statement") or
            std.mem.eql(u8, key, "effective_statement") or
            std.mem.eql(u8, key, "effective_statement_source") or
            std.mem.eql(u8, key, "source_assertions"))
        {
            continue;
        }
        if (!first) try buf.append(alloc, ',');
        first = false;
        try appendJsonQuoted(&buf, key, alloc);
        try buf.append(alloc, ':');
        try appendJsonValue(&buf, entry.value_ptr.*, alloc);
    }
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn augmentRequirementPropertiesJson(g: anytype, req_id: []const u8, base_json: []const u8, alloc: Allocator) ![]const u8 {
    var resolution = try require_text.resolveRequirementText(g, req_id, alloc);
    defer resolution.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, base_json, .{});
    defer parsed.deinit();
    const legacy_statement = if (parsed.value == .object)
        switch (parsed.value.object.get("statement") orelse .null) {
            .string => |value| value,
            else => null,
        }
    else
        null;
    const effective_statement = resolution.effective_statement orelse legacy_statement;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, '{');
    var first = true;
    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "statement") or
                std.mem.eql(u8, key, "effective_statement") or
                std.mem.eql(u8, key, "effective_statement_source") or
                std.mem.eql(u8, key, "text_status") or
                std.mem.eql(u8, key, "authoritative_source") or
                std.mem.eql(u8, key, "source_count") or
                std.mem.eql(u8, key, "source_assertions"))
            {
                continue;
            }
            if (!first) try buf.append(alloc, ',');
            first = false;
            try appendJsonQuoted(&buf, key, alloc);
            try buf.append(alloc, ':');
            try appendJsonValue(&buf, entry.value_ptr.*, alloc);
        }
    }
    if (!first) try buf.append(alloc, ',');
    try buf.appendSlice(alloc, "\"statement\":");
    if (effective_statement) |statement|
        try appendJsonQuoted(&buf, statement, alloc)
    else
        try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"effective_statement\":");
    if (effective_statement) |statement|
        try appendJsonQuoted(&buf, statement, alloc)
    else
        try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"effective_statement_source\":");
    if (resolution.authoritative_source) |source|
        try appendJsonQuoted(&buf, source, alloc)
    else
        try buf.appendSlice(alloc, "null");
    try buf.appendSlice(alloc, ",\"text_status\":");
    try appendJsonQuoted(&buf, resolution.text_status, alloc);
    try buf.appendSlice(alloc, ",\"authoritative_source\":");
    if (resolution.authoritative_source) |source|
        try appendJsonQuoted(&buf, source, alloc)
    else
        try buf.appendSlice(alloc, "null");
    try std.fmt.format(buf.writer(alloc), ",\"source_count\":{d}", .{resolution.source_count});
    try buf.appendSlice(alloc, ",\"source_assertions\":[");
    for (resolution.assertions, 0..) |assertion, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, "{\"id\":");
        try appendJsonQuoted(&buf, assertion.text_id, alloc);
        try buf.appendSlice(alloc, ",\"artifact_id\":");
        if (assertion.artifact_id) |value| try appendJsonQuoted(&buf, value, alloc) else try buf.appendSlice(alloc, "null");
        try buf.appendSlice(alloc, ",\"source_kind\":");
        if (assertion.source_kind) |value| try appendJsonQuoted(&buf, value, alloc) else try buf.appendSlice(alloc, "null");
        try buf.appendSlice(alloc, ",\"section\":");
        if (assertion.section) |value| try appendJsonQuoted(&buf, value, alloc) else try buf.appendSlice(alloc, "null");
        try buf.appendSlice(alloc, ",\"text\":");
        if (assertion.text) |value| try appendJsonQuoted(&buf, value, alloc) else try buf.appendSlice(alloc, "null");
        try buf.appendSlice(alloc, ",\"normalized_text\":");
        if (assertion.normalized_text) |value| try appendJsonQuoted(&buf, value, alloc) else try buf.appendSlice(alloc, "null");
        try buf.appendSlice(alloc, ",\"hash\":");
        if (assertion.hash) |value| try appendJsonQuoted(&buf, value, alloc) else try buf.appendSlice(alloc, "null");
        try buf.appendSlice(alloc, ",\"parse_status\":");
        if (assertion.parse_status) |value| try appendJsonQuoted(&buf, value, alloc) else try buf.appendSlice(alloc, "null");
        try std.fmt.format(buf.writer(alloc), ",\"occurrence_count\":{d}", .{assertion.occurrence_count});
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "]}");
    return alloc.dupe(u8, buf.items);
}

pub fn stmtToNodeResolved(g: anytype, st: *Stmt, alloc: Allocator) !types.Node {
    const node_id = st.columnText(0);
    const node_type = st.columnText(1);
    const raw_properties = st.columnText(2);
    const properties = if (std.mem.eql(u8, node_type, "Requirement"))
        augmentRequirementPropertiesJson(g, node_id, raw_properties, alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try alloc.dupe(u8, raw_properties),
        }
    else
        try alloc.dupe(u8, raw_properties);
    return .{
        .id = try alloc.dupe(u8, node_id),
        .type = try alloc.dupe(u8, node_type),
        .properties = properties,
        .suspect = st.columnInt(3) != 0,
        .suspect_reason = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
    };
}

pub fn stmtToEdge(st: *Stmt, alloc: Allocator) !types.Edge {
    return .{
        .id = try alloc.dupe(u8, st.columnText(0)),
        .from_id = try alloc.dupe(u8, st.columnText(1)),
        .to_id = try alloc.dupe(u8, st.columnText(2)),
        .label = try alloc.dupe(u8, st.columnText(3)),
        .properties = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
    };
}

pub fn stmtToRuntimeDiagnostic(st: *Stmt, alloc: Allocator) !types.RuntimeDiagnostic {
    return .{
        .dedupe_key = try alloc.dupe(u8, st.columnText(0)),
        .code = @intCast(st.columnInt(1)),
        .severity = try alloc.dupe(u8, st.columnText(2)),
        .title = try alloc.dupe(u8, st.columnText(3)),
        .message = try alloc.dupe(u8, st.columnText(4)),
        .source = try alloc.dupe(u8, st.columnText(5)),
        .subject = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
        .details_json = try alloc.dupe(u8, st.columnText(7)),
        .updated_at = st.columnInt(8),
    };
}
