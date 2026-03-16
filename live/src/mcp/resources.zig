const std = @import("std");
const internal = @import("internal.zig");
const protocol = @import("protocol.zig");
const workbooks = @import("workbooks.zig");
const markdown = @import("markdown.zig");

pub fn resourcesListResult(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"resources\":");
    try buf.appendSlice(alloc, protocol.resources_json);

    var added_any = false;
    const gaps_json = internal.routes.handleChainGaps(db, "generic", arena) catch null;
    if (gaps_json) |gjson| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, gjson, .{});
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            var extras: std.ArrayList(u8) = .empty;
            defer extras.deinit(alloc);
            for (parsed.value.array.items, 0..) |item, idx| {
                if (idx >= 5) break;
                const code = if (internal.json_util.getObjectField(item, "code")) |v| switch (v) {
                    .integer => v.integer,
                    else => 0,
                } else 0;
                const node_id = internal.json_util.getString(item, "node_id") orelse continue;
                if (idx == 0) try extras.appendSlice(alloc, ",");
                try std.fmt.format(extras.writer(alloc), "{{\"uri\":", .{});
                const gap_uri = try std.fmt.allocPrint(arena, "gap://{d}/{s}", .{ code, node_id });
                try internal.json_util.appendJsonQuoted(&extras, gap_uri, alloc);
                try extras.appendSlice(alloc, ",\"name\":");
                try internal.json_util.appendJsonQuoted(&extras, "Gap Explanation", alloc);
                try extras.appendSlice(alloc, ",\"description\":");
                try internal.json_util.appendJsonQuoted(&extras, internal.json_util.getString(item, "title") orelse "Gap detail", alloc);
                try extras.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
                added_any = true;
            }
            if (added_any) {
                _ = buf.pop();
                try buf.appendSlice(alloc, extras.items);
                try buf.append(alloc, ']');
            }
        }
    }

    const rtm_json = internal.routes.handleRtm(db, arena) catch null;
    if (rtm_json) |rjson| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, rjson, .{});
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            _ = buf.pop();
            for (parsed.value.array.items, 0..) |item, idx| {
                if (idx >= 5) break;
                const req_id = internal.json_util.getString(item, "req_id") orelse continue;
                try buf.append(alloc, ',');
                try buf.appendSlice(alloc, "{\"uri\":");
                const req_uri = try std.fmt.allocPrint(arena, "requirement://{s}", .{req_id});
                try internal.json_util.appendJsonQuoted(&buf, req_uri, alloc);
                try buf.appendSlice(alloc, ",\"name\":");
                try internal.json_util.appendJsonQuoted(&buf, req_id, alloc);
                try buf.appendSlice(alloc, ",\"description\":");
                try internal.json_util.appendJsonQuoted(&buf, internal.json_util.getString(item, "statement") orelse "Requirement trace record", alloc);
                try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
            }
            try buf.append(alloc, ']');
        }
    }

    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn resourceReadResult(uri: []const u8, req_ctx: *const internal.RequestContext, runtime_ctx: *const internal.RuntimeContext) ![]u8 {
    const alloc = req_ctx.alloc;
    const text = if (std.mem.startsWith(u8, uri, "requirement://"))
        try markdown.requirementTraceMarkdown(uri[14..], runtime_ctx.db, runtime_ctx.profile_name, alloc)
    else if (std.mem.startsWith(u8, uri, "user-need://"))
        try markdown.nodeMarkdown(uri[12..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "risk://"))
        try markdown.nodeMarkdown(uri[7..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "test://"))
        try markdown.nodeMarkdown(uri[7..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "test-group://"))
        try markdown.nodeMarkdown(uri[13..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "node://"))
        try markdown.nodeMarkdown(uri[7..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "impact://"))
        try markdown.impactMarkdown(uri[9..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "design-history://"))
        try markdown.designHistoryMarkdown(uri[17..], runtime_ctx.db, runtime_ctx.profile_name, alloc)
    else if (std.mem.startsWith(u8, uri, "gap://")) blk: {
        const rest = uri[6..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidArgument;
        const code = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.InvalidArgument;
        break :blk try markdown.gapExplanationMarkdown(code, rest[slash + 1 ..], runtime_ctx.db, runtime_ctx.profile_name, alloc);
    } else if (std.mem.eql(u8, uri, "report://status"))
        try markdown.statusMarkdown(req_ctx.registry, req_ctx.secure_store_ref, req_ctx.state, alloc)
    else if (std.mem.eql(u8, uri, "report://chain-gaps"))
        try markdown.chainGapSummaryMarkdown(runtime_ctx.db, runtime_ctx.profile_name, alloc)
    else if (std.mem.eql(u8, uri, "report://rtm"))
        try markdown.rtmSummaryMarkdown(runtime_ctx.db, alloc)
    else if (std.mem.eql(u8, uri, "report://code-traceability"))
        try markdown.codeTraceabilitySummaryMarkdown(runtime_ctx.db, alloc)
    else if (std.mem.eql(u8, uri, "report://review"))
        try markdown.reviewSummaryMarkdown(runtime_ctx.db, runtime_ctx.profile_name, req_ctx.state, alloc)
    else
        return error.NotFound;
    defer alloc.free(text);
    const heading = try workbooks.workbookHeading(req_ctx.registry, alloc);
    defer alloc.free(heading);
    const contextual = try std.fmt.allocPrint(alloc, "{s}{s}", .{ heading, text });
    defer alloc.free(contextual);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"contents\":[{\"uri\":");
    try internal.json_util.appendJsonQuoted(&buf, uri, alloc);
    try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\",\"text\":");
    try internal.json_util.appendJsonQuoted(&buf, contextual, alloc);
    try buf.appendSlice(alloc, "}]}");
    return alloc.dupe(u8, buf.items);
}
