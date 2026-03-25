const std = @import("std");

const internal = @import("../internal.zig");

pub fn markdownFromNodeDetail(node: std.json.Value, edges_out: ?std.json.Value, edges_in: ?std.json.Value, alloc: internal.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const id = internal.json_util.getString(node, "id") orelse "unknown";
    const ty = internal.json_util.getString(node, "type") orelse "Node";
    try std.fmt.format(buf.writer(alloc), "# {s} {s}\n\n", .{ ty, id });
    try appendNodeCoreMarkdown(&buf, node, alloc);
    try appendEdgeSection(&buf, "Outgoing Links", edges_out, alloc);
    try appendEdgeSection(&buf, "Incoming Links", edges_in, alloc);
    return alloc.dupe(u8, buf.items);
}

pub fn appendNodeCoreMarkdown(buf: *std.ArrayList(u8), node: std.json.Value, alloc: internal.Allocator) !void {
    const id = internal.json_util.getString(node, "id") orelse "unknown";
    const ty = internal.json_util.getString(node, "type") orelse "Node";
    try std.fmt.format(buf.writer(alloc), "- ID: `{s}`\n- Type: {s}\n", .{ id, ty });
    const suspect = if (internal.json_util.getObjectField(node, "suspect")) |v| switch (v) {
        .bool => v.bool,
        else => false,
    } else false;
    try std.fmt.format(buf.writer(alloc), "- Suspect: {s}\n", .{if (suspect) "yes" else "no"});
    const props = internal.json_util.getObjectField(node, "properties");
    if (props) |p| if (p == .object) {
        const statement = internal.json_util.getString(p, "statement");
        const effective_statement = internal.json_util.getString(p, "effective_statement");
        const effective_statement_source = internal.json_util.getString(p, "effective_statement_source");
        const text_status = internal.json_util.getString(p, "text_status");
        const authoritative_source = internal.json_util.getString(p, "authoritative_source");
        const status = internal.json_util.getString(p, "status");
        const description = internal.json_util.getString(p, "description");
        const path = internal.json_util.getString(p, "path");
        const message = internal.json_util.getString(p, "message");
        if (statement) |s| try std.fmt.format(buf.writer(alloc), "- Statement: {s}\n", .{s});
        if (effective_statement) |s| if (statement == null or !std.mem.eql(u8, statement.?, s))
            try std.fmt.format(buf.writer(alloc), "- Effective Text: {s}\n", .{s});
        if (text_status) |s| try std.fmt.format(buf.writer(alloc), "- Text Status: {s}\n", .{s});
        if (authoritative_source) |s| if (s.len > 0)
            try std.fmt.format(buf.writer(alloc), "- Authoritative Source: `{s}`\n", .{s});
        if (effective_statement_source) |s| if (s.len > 0 and (authoritative_source == null or !std.mem.eql(u8, authoritative_source.?, s)))
            try std.fmt.format(buf.writer(alloc), "- Effective Text Source: `{s}`\n", .{s});
        if (description) |s| try std.fmt.format(buf.writer(alloc), "- Description: {s}\n", .{s});
        if (status) |s| try std.fmt.format(buf.writer(alloc), "- Status: {s}\n", .{s});
        if (path) |s| try std.fmt.format(buf.writer(alloc), "- Path: `{s}`\n", .{s});
        if (message) |s| try std.fmt.format(buf.writer(alloc), "- Message: {s}\n", .{s});
        const source_count = internal.json_util.getInt(p, "source_count") orelse 0;
        if (source_count > 0) {
            try std.fmt.format(buf.writer(alloc), "- Source Assertions: {d}\n", .{source_count});
            const source_assertions = internal.json_util.getObjectField(p, "source_assertions");
            try appendSourceAssertionSection(buf, source_assertions, alloc);
        }
    };
    try buf.append(alloc, '\n');
}

pub fn appendSourceAssertionSection(buf: *std.ArrayList(u8), assertions: ?std.json.Value, alloc: internal.Allocator) !void {
    if (assertions == null or assertions.? != .array or assertions.?.array.items.len == 0) return;
    try buf.appendSlice(alloc, "## Source Assertions\n");
    for (assertions.?.array.items) |item| {
        const artifact_id = internal.json_util.getString(item, "artifact_id") orelse "unknown";
        const source_kind = internal.json_util.getString(item, "source_kind") orelse "unknown";
        const parse_status = internal.json_util.getString(item, "parse_status") orelse "ok";
        const text = internal.json_util.getString(item, "text") orelse "—";
        try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) [{s}] — {s}\n", .{
            artifact_id,
            source_kind,
            parse_status,
            text,
        });
    }
    try buf.append(alloc, '\n');
}

pub fn appendNodeArraySection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const id = internal.json_util.getString(item, "id") orelse "?";
        const ty = internal.json_util.getString(item, "type") orelse "Node";
        const summary = nodeSummary(item);
        if (summary) |s| {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) — {s}\n", .{ id, ty, s });
        } else {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s})\n", .{ id, ty });
        }
    }
    try buf.append(alloc, '\n');
}

pub fn appendGapArraySection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const code = getIntField(item, "code") orelse 0;
        const title_val = internal.json_util.getString(item, "title") orelse "Gap";
        const message = internal.json_util.getString(item, "message") orelse "";
        try std.fmt.format(buf.writer(alloc), "- [{d}] {s}: {s}\n", .{ code, title_val, message });
    }
    try buf.append(alloc, '\n');
}

pub fn appendFilteredGapSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, node_id: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    var matched: usize = 0;
    for (arr.?.array.items) |item| {
        const item_node_id = internal.json_util.getString(item, "node_id") orelse continue;
        if (!std.mem.eql(u8, item_node_id, node_id)) continue;
        const code = getIntField(item, "code") orelse 0;
        const title_val = internal.json_util.getString(item, "title") orelse "Gap";
        const message = internal.json_util.getString(item, "message") orelse "";
        try std.fmt.format(buf.writer(alloc), "- [{d}] {s}: {s}\n", .{ code, title_val, message });
        matched += 1;
    }
    if (matched == 0) try buf.appendSlice(alloc, "- None\n");
    try buf.append(alloc, '\n');
}

pub fn appendEdgeSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse "";
        const node = internal.json_util.getObjectField(item, "node");
        if (node) |n| {
            const id = internal.json_util.getString(n, "id") orelse "?";
            const ty = internal.json_util.getString(n, "type") orelse "Node";
            try std.fmt.format(buf.writer(alloc), "- `{s}` -> `{s}` ({s})", .{ label, id, ty });
            try appendEdgePropertySuffix(buf, internal.json_util.getObjectField(item, "properties"), alloc);
            try buf.append(alloc, '\n');
        }
    }
    try buf.append(alloc, '\n');
}

pub fn appendFilteredEdgeNodeSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, label_filter: []const u8, type_filter: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    var matched: usize = 0;
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse continue;
        if (!std.mem.eql(u8, label, label_filter)) continue;
        const node = internal.json_util.getObjectField(item, "node") orelse continue;
        const ty = internal.json_util.getString(node, "type") orelse continue;
        if (!std.mem.eql(u8, ty, type_filter)) continue;
        const id = internal.json_util.getString(node, "id") orelse "?";
        const summary = nodeSummary(node);
        if (summary) |s| {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) — {s}\n", .{ id, ty, s });
        } else {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s})\n", .{ id, ty });
        }
        matched += 1;
    }
    if (matched == 0) try buf.appendSlice(alloc, "- None\n");
    try buf.append(alloc, '\n');
}

pub fn appendNonMatchingEdgeSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, skip_label: []const u8, skip_type: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    var matched: usize = 0;
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse "";
        const node = internal.json_util.getObjectField(item, "node") orelse continue;
        const ty = internal.json_util.getString(node, "type") orelse "Node";
        if (std.mem.eql(u8, label, skip_label) and std.mem.eql(u8, ty, skip_type)) continue;
        const id = internal.json_util.getString(node, "id") orelse "?";
        try std.fmt.format(buf.writer(alloc), "- `{s}` -> `{s}` ({s})", .{ label, id, ty });
        try appendEdgePropertySuffix(buf, internal.json_util.getObjectField(item, "properties"), alloc);
        try buf.append(alloc, '\n');
        matched += 1;
    }
    if (matched == 0) try buf.appendSlice(alloc, "- None\n");
    try buf.append(alloc, '\n');
}

pub fn countFilteredEdges(arr: ?std.json.Value, label_filter: []const u8, type_filter: []const u8) usize {
    if (arr == null or arr.? != .array) return 0;
    var count: usize = 0;
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse continue;
        if (!std.mem.eql(u8, label, label_filter)) continue;
        const node = internal.json_util.getObjectField(item, "node") orelse continue;
        const ty = internal.json_util.getString(node, "type") orelse continue;
        if (!std.mem.eql(u8, ty, type_filter)) continue;
        count += 1;
    }
    return count;
}

pub fn appendStringListSection(buf: *std.ArrayList(u8), title: []const u8, items: []const []const u8, uri_prefix: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (items) |item| {
        try std.fmt.format(buf.writer(alloc), "- `{s}{s}`\n", .{ uri_prefix, item });
    }
    try buf.append(alloc, '\n');
}

pub fn appendInlineStringList(buf: *std.ArrayList(u8), label: []const u8, items: []const []const u8, uri_prefix: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "- {s}: ", .{label});
    if (items.len == 0) {
        try buf.appendSlice(alloc, "none visible\n");
        return;
    }
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try std.fmt.format(buf.writer(alloc), "`{s}{s}`", .{ uri_prefix, item });
    }
    try buf.append(alloc, '\n');
}

pub fn nodeSummary(node: std.json.Value) ?[]const u8 {
    const props = internal.json_util.getObjectField(node, "properties") orelse return null;
    return internal.json_util.getString(props, "statement") orelse
        internal.json_util.getString(props, "description") orelse
        internal.json_util.getString(props, "path") orelse
        internal.json_util.getString(props, "file_path") orelse
        internal.json_util.getString(props, "message") orelse
        internal.json_util.getString(props, "short_hash");
}

pub fn edgePropertyPriority(key: []const u8) usize {
    if (std.mem.eql(u8, key, "quantity")) return 0;
    if (std.mem.eql(u8, key, "ref_designator")) return 1;
    if (std.mem.eql(u8, key, "supplier")) return 2;
    if (std.mem.eql(u8, key, "relation_source")) return 3;
    return 4;
}

pub fn edgePropertyLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const lhs_priority = edgePropertyPriority(lhs);
    const rhs_priority = edgePropertyPriority(rhs);
    if (lhs_priority != rhs_priority) return lhs_priority < rhs_priority;
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn appendEdgePropertyValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: internal.Allocator) !void {
    switch (value) {
        .string => try buf.appendSlice(alloc, value.string),
        .integer => try std.fmt.format(buf.writer(alloc), "{d}", .{value.integer}),
        .float => try std.fmt.format(buf.writer(alloc), "{d}", .{value.float}),
        .bool => try buf.appendSlice(alloc, if (value.bool) "true" else "false"),
        else => {
            const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
            defer alloc.free(json);
            try buf.appendSlice(alloc, json);
        },
    }
}

pub fn appendEdgePropertySuffix(buf: *std.ArrayList(u8), properties: ?std.json.Value, alloc: internal.Allocator) !void {
    if (properties == null or properties.? != .object) return;

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);
    var it = properties.?.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        try keys.append(alloc, entry.key_ptr.*);
    }
    if (keys.items.len == 0) return;
    std.mem.sort([]const u8, keys.items, {}, edgePropertyLessThan);

    try buf.appendSlice(alloc, " [");
    for (keys.items, 0..) |key, idx| {
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, key);
        try buf.append(alloc, '=');
        try appendEdgePropertyValue(buf, properties.?.object.get(key).?, alloc);
    }
    try buf.append(alloc, ']');
}

pub fn getIntField(value: std.json.Value, key: []const u8) ?i64 {
    const field = internal.json_util.getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => field.integer,
        else => null,
    };
}

pub fn boolStr(v: ?std.json.Value) []const u8 {
    if (v) |val| switch (val) {
        .bool => return if (val.bool) "true" else "false",
        else => {},
    };
    return "false";
}
