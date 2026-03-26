const std = @import("std");
const Allocator = std.mem.Allocator;

const design_history = @import("design_history.zig");
const graph_live = @import("graph_live.zig");
const chain_mod = @import("chain.zig");
const dh_routes = @import("routes/design_history.zig");

pub fn renderReport(report: *const design_history.DhrReport, writer: anytype, alloc: Allocator) !void {
    try writer.writeAll("# Full Traceability Report\n\n");
    try writer.print("Profile: {s}\n\n", .{@tagName(report.profile)});

    for (report.user_need_sections) |section| {
        try renderUserNeedSection(section, writer, alloc);
    }

    if (report.unlinked_requirements.len > 0) {
        try writer.writeAll("## Requirements Without User Needs\n\n");
        for (report.unlinked_requirements) |history| {
            try renderRequirementSection(history, writer, alloc);
        }
    }
}

fn renderUserNeedSection(section: design_history.UserNeedHistory, writer: anytype, alloc: Allocator) !void {
    try writer.print("## {s}\n\n", .{section.user_need.id});

    if (try propValue(section.user_need, "statement", alloc)) |statement| {
        defer alloc.free(statement);
        if (statement.len > 0) try writer.print("- Statement: {s}\n", .{statement});
    }
    if (try propValue(section.user_need, "source", alloc)) |source| {
        defer alloc.free(source);
        if (source.len > 0) try writer.print("- Source: {s}\n", .{source});
    }
    if (try propValue(section.user_need, "priority", alloc)) |priority| {
        defer alloc.free(priority);
        if (priority.len > 0) try writer.print("- Priority: {s}\n", .{priority});
    }
    try writer.writeByte('\n');

    if (section.requirements.len == 0) {
        try writer.writeAll("_No requirements linked._\n\n");
        return;
    }

    for (section.requirements) |history| {
        try renderRequirementSection(history, writer, alloc);
    }
}

fn renderRequirementSection(history: design_history.RequirementHistory, writer: anytype, alloc: Allocator) !void {
    const req = history.requirement orelse return;
    try writer.print("### Requirement {s}\n\n", .{req.id});

    if (try propValue(req, "statement", alloc)) |statement| {
        defer alloc.free(statement);
        if (statement.len > 0) try writer.print("- Statement: {s}\n", .{statement});
    }
    if (try propValue(req, "status", alloc)) |status| {
        defer alloc.free(status);
        if (status.len > 0) try writer.print("- Status: {s}\n", .{status});
    }
    try writer.writeByte('\n');

    try renderNodeSection("Risks", history.risks, writer, alloc);
    try renderNodeSection("Design Inputs", history.design_inputs, writer, alloc);
    try renderNodeSection("Design Outputs", history.design_outputs, writer, alloc);
    try renderNodeSection("Configuration Items", history.configuration_items, writer, alloc);
    try renderNodeSection("Source Files", history.source_files, writer, alloc);
    try renderNodeSection("Test Files", history.test_files, writer, alloc);
    try renderNodeSection("Annotations", history.annotations, writer, alloc);
    try renderNodeSection("Commits", history.commits, writer, alloc);
    try renderGapSection("Open Chain Gaps", history.chain_gaps, writer);
}

fn renderNodeSection(title: []const u8, nodes: []const graph_live.Node, writer: anytype, alloc: Allocator) !void {
    try writer.print("#### {s}\n", .{title});
    if (nodes.len == 0) {
        try writer.writeAll("- None\n\n");
        return;
    }
    for (nodes) |node| {
        const summary = try nodeSummary(node, alloc);
        defer alloc.free(summary);
        try writer.print("- {s}\n", .{summary});
    }
    try writer.writeByte('\n');
}

fn renderGapSection(title: []const u8, gaps: []const chain_mod.Gap, writer: anytype) !void {
    try writer.print("#### {s}\n", .{title});
    if (gaps.len == 0) {
        try writer.writeAll("- None\n\n");
        return;
    }
    for (gaps) |gap| {
        try writer.print("- {s}{d} {s} [{s}] {s}: {s}\n", .{
            if (gap.severity == .err) "ERR " else if (gap.severity == .warn) "WARN " else "",
            gap.code,
            gap.title,
            gap.node_id,
            gap.gap_type,
            gap.message,
        });
    }
    try writer.writeByte('\n');
}

fn nodeSummary(node: graph_live.Node, alloc: Allocator) ![]u8 {
    if (std.mem.eql(u8, node.type, "Risk")) {
        const description = try propValue(node, "description", alloc) orelse try alloc.dupe(u8, "");
        defer alloc.free(description);
        return std.fmt.allocPrint(alloc, "**{s}**: {s}", .{ node.id, description });
    }
    if (std.mem.eql(u8, node.type, "DesignInput") or std.mem.eql(u8, node.type, "DesignOutput") or std.mem.eql(u8, node.type, "ConfigurationItem")) {
        const description = (try propValue(node, "description", alloc)) orelse (try propValue(node, "path", alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(description);
        return std.fmt.allocPrint(alloc, "**{s}**: {s}", .{ node.id, description });
    }
    if (std.mem.eql(u8, node.type, "SourceFile") or std.mem.eql(u8, node.type, "TestFile")) {
        const path = (try propValue(node, "path", alloc)) orelse try alloc.dupe(u8, node.id);
        defer alloc.free(path);
        const repo = try propValue(node, "repo", alloc);
        defer if (repo) |value| alloc.free(value);
        if (repo) |value| {
            return std.fmt.allocPrint(alloc, "**{s}** ({s})", .{ path, value });
        }
        return std.fmt.allocPrint(alloc, "**{s}**", .{path});
    }
    if (std.mem.eql(u8, node.type, "CodeAnnotation")) {
        const req_id = (try propValue(node, "req_id", alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(req_id);
        const file_path = (try propValue(node, "file_path", alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(file_path);
        const line_number = (try propValue(node, "line_number", alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(line_number);
        const blame_author = try propValue(node, "blame_author", alloc);
        defer if (blame_author) |value| alloc.free(value);
        const short_hash = try propValue(node, "short_hash", alloc);
        defer if (short_hash) |value| alloc.free(value);
        if (blame_author != null or short_hash != null) {
            return std.fmt.allocPrint(alloc, "**{s}**: req={s} file={s} line={s} {s} {s}", .{
                node.id,
                req_id,
                file_path,
                line_number,
                blame_author orelse "",
                short_hash orelse "",
            });
        }
        return std.fmt.allocPrint(alloc, "**{s}**: req={s} file={s} line={s}", .{
            node.id,
            req_id,
            file_path,
            line_number,
        });
    }
    if (std.mem.eql(u8, node.type, "Commit")) {
        const short_hash = (try propValue(node, "short_hash", alloc)) orelse try alloc.dupe(u8, node.id);
        defer alloc.free(short_hash);
        const date = (try propValue(node, "date", alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(date);
        const message = (try propValue(node, "message", alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(message);
        return std.fmt.allocPrint(alloc, "**{s}** {s} {s}", .{ short_hash, date, message });
    }
    const statement = (try propValue(node, "statement", alloc)) orelse (try propValue(node, "description", alloc)) orelse try alloc.dupe(u8, "");
    defer alloc.free(statement);
    return std.fmt.allocPrint(alloc, "**{s}**: {s}", .{ node.id, statement });
}

fn propValue(node: graph_live.Node, key: []const u8, alloc: Allocator) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, node.properties, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(key) orelse return null;
    return switch (value) {
        .string => try alloc.dupe(u8, value.string),
        .integer => try std.fmt.allocPrint(alloc, "{d}", .{value.integer}),
        .float => try std.fmt.allocPrint(alloc, "{d}", .{@as(f64, value.float)}),
        .bool => try alloc.dupe(u8, if (value.bool) "true" else "false"),
        else => null,
    };
}

const testing = std.testing;

test "renderReport includes downstream sections and unlinked appendix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try dh_routes.seedDhrFixture(&db);

    var report = try design_history.buildFullTraceabilityReport(&db, "medical", alloc);
    defer design_history.deinitDhrReport(&report, alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try renderReport(&report, buf.writer(alloc), alloc);

    try testing.expect(std.mem.indexOf(u8, buf.items, "Profile: medical") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "### Requirement REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Detect GPS loss") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "#### Design Inputs") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "DI-001") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## Requirements Without User Needs") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "REQ-999") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Standalone maintenance mode") != null);
}
