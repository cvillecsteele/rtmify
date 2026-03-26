const std = @import("std");
const Allocator = std.mem.Allocator;

const design_history = @import("design_history.zig");
const graph_live = @import("graph_live.zig");
const chain_mod = @import("chain.zig");
const dh_routes = @import("routes/design_history.zig");

const PAGE_W: f32 = 612.0;
const PAGE_H: f32 = 792.0;
const MARGIN: f32 = 72.0;
const BODY_TOP: f32 = PAGE_H - MARGIN;
const BODY_BOT: f32 = MARGIN + 24.0;
const FOOTER_Y: f32 = 54.0;

const FONT_BODY: f32 = 8.5;
const FONT_SECTION: f32 = 11.0;
const FONT_TITLE: f32 = 14.0;
const FONT_FOOTER: f32 = 8.0;

const SECTION_GAP: f32 = 10.0;
const SECTION_HDR_H: f32 = 18.0;

const HELV_WIDTHS: [256]u16 = blk: {
    var w = [_]u16{556} ** 256;
    const pw = [95]u16{
        278, 278, 355, 556, 556, 889, 667, 222,
        333, 333, 389, 584, 278, 333, 278, 278,
        556, 556, 556, 556, 556, 556, 556, 556,
        556, 556, 278, 278, 584, 584, 584, 556,
        1015, 667, 667, 722, 722, 667, 611, 778,
        722, 278, 500, 667, 556, 833, 722, 778,
        667, 778, 722, 667, 611, 722, 667, 944,
        667, 667, 611, 278, 278, 278, 469, 556,
        222, 556, 556, 500, 556, 556, 278, 556,
        556, 222, 222, 500, 222, 833, 556, 556,
        556, 556, 333, 500, 278, 556, 500, 722,
        500, 500, 500, 334, 260, 334, 584,
    };
    for (pw, 0..) |v, i| w[32 + i] = v;
    break :blk w;
};

fn textWidth(text: []const u8, font_size: f32) f32 {
    var total: f32 = 0;
    for (text) |c| total += @as(f32, @floatFromInt(HELV_WIDTHS[c]));
    return total * font_size / 1000.0;
}

fn clipText(text: []const u8, max_w: f32, font_size: f32) []const u8 {
    if (textWidth(text, font_size) <= max_w) return text;
    var end: usize = text.len;
    while (end > 0) {
        end -= 1;
        if (textWidth(text[0..end], font_size) <= max_w) break;
    }
    return text[0..end];
}

fn appendPdfStr(buf: *std.ArrayList(u8), gpa: Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '(' or c == ')' or c == '\\') {
            try buf.appendSlice(gpa, &[_]u8{ '\\', c });
            i += 1;
        } else if (c >= 32 and c < 127) {
            try buf.append(gpa, c);
            i += 1;
        } else if (c < 32 or c == 127) {
            i += 1;
        } else {
            const seq_len: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else if (c >= 0xC0) 2 else 1;
            const end = @min(i + seq_len, text.len);
            const seq = text[i..end];
            if (seq_len == 3 and seq.len == 3) {
                if (seq[0] == 0xE2 and seq[1] == 0x80 and seq[2] == 0x94) {
                    try buf.append(gpa, '-');
                } else if (seq[0] == 0xE2 and seq[1] == 0x86 and seq[2] == 0x92) {
                    try buf.appendSlice(gpa, "->");
                } else {
                    try buf.append(gpa, '?');
                }
            } else {
                try buf.append(gpa, '?');
            }
            i += seq_len;
        }
    }
}

const PageBuilder = struct {
    gpa: Allocator,
    pages: std.ArrayList([]u8),
    cur: std.ArrayList(u8),
    y: f32,

    fn init(gpa: Allocator) PageBuilder {
        return .{ .gpa = gpa, .pages = .empty, .cur = .empty, .y = BODY_TOP };
    }

    fn deinit(pb: *PageBuilder) void {
        for (pb.pages.items) |p| pb.gpa.free(p);
        pb.pages.deinit(pb.gpa);
        pb.cur.deinit(pb.gpa);
    }

    fn pageNum(pb: *const PageBuilder) usize {
        return pb.pages.items.len + 1;
    }

    fn finalizePage(pb: *PageBuilder) !void {
        const footer = try std.fmt.allocPrint(pb.gpa, "Page {d}", .{pb.pageNum()});
        defer pb.gpa.free(footer);

        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(pb.gpa);
        try appendPdfStr(&escaped, pb.gpa, footer);

        const fw = textWidth(footer, FONT_FOOTER);
        const fx = (PAGE_W - fw) / 2.0;

        try pb.cur.print(pb.gpa, "BT\n/F1 {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{
            FONT_FOOTER,
            fx,
            FOOTER_Y,
        });
        try pb.cur.appendSlice(pb.gpa, escaped.items);
        try pb.cur.appendSlice(pb.gpa, ") Tj\nET\n");

        try pb.pages.append(pb.gpa, try pb.cur.toOwnedSlice(pb.gpa));
        pb.cur = .empty;
        pb.y = BODY_TOP;
    }

    fn ensureSpace(pb: *PageBuilder, needed: f32) !void {
        if (pb.y - needed < BODY_BOT) try pb.finalizePage();
    }

    fn drawHeading(pb: *PageBuilder, text: []const u8, font_size: f32) !void {
        try pb.ensureSpace(SECTION_HDR_H);
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(pb.gpa);
        try appendPdfStr(&escaped, pb.gpa, text);
        try pb.cur.print(pb.gpa, "BT\n/F2 {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{
            font_size,
            MARGIN,
            pb.y - SECTION_HDR_H + 4.0,
        });
        try pb.cur.appendSlice(pb.gpa, escaped.items);
        try pb.cur.appendSlice(pb.gpa, ") Tj\nET\n");
        pb.y -= SECTION_HDR_H;
    }

    fn drawSection(pb: *PageBuilder, text: []const u8) !void {
        pb.y -= SECTION_GAP;
        try pb.drawHeading(text, FONT_SECTION);
    }

    fn drawText(pb: *PageBuilder, text: []const u8, bold: bool) !void {
        const line_h = FONT_BODY * 1.5;
        try pb.ensureSpace(line_h);
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(pb.gpa);
        const max_w = PAGE_W - 2.0 * MARGIN;
        const clipped = clipText(text, max_w, FONT_BODY);
        try appendPdfStr(&escaped, pb.gpa, clipped);
        const font: []const u8 = if (bold) "/F2" else "/F1";
        try pb.cur.print(pb.gpa, "BT\n{s} {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{
            font,
            FONT_BODY,
            MARGIN,
            pb.y - line_h + 3.0,
        });
        try pb.cur.appendSlice(pb.gpa, escaped.items);
        try pb.cur.appendSlice(pb.gpa, ") Tj\nET\n");
        pb.y -= line_h;
    }

    fn drawBlankLine(pb: *PageBuilder) !void {
        try pb.ensureSpace(FONT_BODY);
        pb.y -= FONT_BODY;
    }
};

pub fn renderReport(report: *const design_history.DhrReport, writer: anytype, alloc: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const page_alloc = arena.allocator();

    var pb = PageBuilder.init(page_alloc);
    defer pb.deinit();

    try pb.drawHeading("Full Traceability Report", FONT_TITLE);
    const profile_line = try std.fmt.allocPrint(alloc, "Profile: {s}", .{@tagName(report.profile)});
    defer alloc.free(profile_line);
    try pb.drawText(profile_line, false);
    try pb.drawBlankLine();

    for (report.user_need_sections) |section| {
        try renderUserNeedSection(&pb, section, alloc);
    }

    if (report.unlinked_requirements.len > 0) {
        try pb.drawSection("Requirements Without User Needs");
        for (report.unlinked_requirements) |history| {
            try renderRequirementSection(&pb, history, alloc);
        }
    }

    if (pb.cur.items.len > 0) try pb.finalizePage();
    try writePdf(page_alloc, pb.pages.items, writer);
}

fn renderUserNeedSection(pb: *PageBuilder, section: design_history.UserNeedHistory, alloc: Allocator) !void {
    try pb.drawSection(section.user_need.id);

    if (try propValue(section.user_need, "statement", alloc)) |statement| {
        defer alloc.free(statement);
        if (statement.len > 0) {
            const line = try std.fmt.allocPrint(alloc, "Statement: {s}", .{statement});
            defer alloc.free(line);
            try pb.drawText(line, false);
        }
    }
    if (try propValue(section.user_need, "source", alloc)) |source| {
        defer alloc.free(source);
        if (source.len > 0) {
            const line = try std.fmt.allocPrint(alloc, "Source: {s}", .{source});
            defer alloc.free(line);
            try pb.drawText(line, false);
        }
    }
    if (try propValue(section.user_need, "priority", alloc)) |priority| {
        defer alloc.free(priority);
        if (priority.len > 0) {
            const line = try std.fmt.allocPrint(alloc, "Priority: {s}", .{priority});
            defer alloc.free(line);
            try pb.drawText(line, false);
        }
    }

    if (section.requirements.len == 0) {
        try pb.drawText("No requirements linked.", false);
        try pb.drawBlankLine();
        return;
    }

    try pb.drawBlankLine();
    for (section.requirements) |history| {
        try renderRequirementSection(pb, history, alloc);
    }
}

fn renderRequirementSection(pb: *PageBuilder, history: design_history.RequirementHistory, alloc: Allocator) !void {
    const req = history.requirement orelse return;
    const heading = try std.fmt.allocPrint(alloc, "Requirement {s}", .{req.id});
    defer alloc.free(heading);
    try pb.drawSection(heading);

    if (try propValue(req, "statement", alloc)) |statement| {
        defer alloc.free(statement);
        if (statement.len > 0) {
            const line = try std.fmt.allocPrint(alloc, "Statement: {s}", .{statement});
            defer alloc.free(line);
            try pb.drawText(line, false);
        }
    }
    if (try propValue(req, "status", alloc)) |status| {
        defer alloc.free(status);
        if (status.len > 0) {
            const line = try std.fmt.allocPrint(alloc, "Status: {s}", .{status});
            defer alloc.free(line);
            try pb.drawText(line, false);
        }
    }
    try pb.drawBlankLine();

    try renderNodeSection(pb, "Risks", history.risks, alloc);
    try renderNodeSection(pb, "Design Inputs", history.design_inputs, alloc);
    try renderNodeSection(pb, "Design Outputs", history.design_outputs, alloc);
    try renderNodeSection(pb, "Configuration Items", history.configuration_items, alloc);
    try renderNodeSection(pb, "Source Files", history.source_files, alloc);
    try renderNodeSection(pb, "Test Files", history.test_files, alloc);
    try renderNodeSection(pb, "Annotations", history.annotations, alloc);
    try renderNodeSection(pb, "Commits", history.commits, alloc);
    try renderGapSection(pb, "Open Chain Gaps", history.chain_gaps, alloc);
}

fn renderNodeSection(pb: *PageBuilder, title: []const u8, nodes: []const graph_live.Node, alloc: Allocator) !void {
    try pb.drawText(title, true);
    if (nodes.len == 0) {
        try pb.drawText("- None", false);
        try pb.drawBlankLine();
        return;
    }
    for (nodes) |node| {
        const summary = try nodeSummary(node, alloc);
        defer alloc.free(summary);
        const line = try std.fmt.allocPrint(alloc, "- {s}", .{summary});
        defer alloc.free(line);
        try pb.drawText(line, false);
    }
    try pb.drawBlankLine();
}

fn renderGapSection(pb: *PageBuilder, title: []const u8, gaps: []const chain_mod.Gap, alloc: Allocator) !void {
    try pb.drawText(title, true);
    if (gaps.len == 0) {
        try pb.drawText("- None", false);
        try pb.drawBlankLine();
        return;
    }
    for (gaps) |gap| {
        const line = try std.fmt.allocPrint(alloc, "- {s}{d} {s} [{s}] {s}: {s}", .{
            if (gap.severity == .err) "ERR " else "WARN ",
            gap.code,
            gap.title,
            gap.node_id,
            gap.gap_type,
            gap.message,
        });
        defer alloc.free(line);
        try pb.drawText(line, false);
    }
    try pb.drawBlankLine();
}

fn nodeSummary(node: graph_live.Node, alloc: Allocator) ![]u8 {
    if (std.mem.eql(u8, node.type, "Risk")) {
        const description = try propValue(node, "description", alloc) orelse try alloc.dupe(u8, "");
        defer alloc.free(description);
        return std.fmt.allocPrint(alloc, "{s}: {s}", .{ node.id, description });
    }
    if (std.mem.eql(u8, node.type, "DesignInput") or std.mem.eql(u8, node.type, "DesignOutput") or std.mem.eql(u8, node.type, "ConfigurationItem")) {
        const description = (try propValue(node, "description", alloc)) orelse (try propValue(node, "path", alloc)) orelse try alloc.dupe(u8, "");
        defer alloc.free(description);
        return std.fmt.allocPrint(alloc, "{s}: {s}", .{ node.id, description });
    }
    if (std.mem.eql(u8, node.type, "SourceFile") or std.mem.eql(u8, node.type, "TestFile")) {
        const path = (try propValue(node, "path", alloc)) orelse try alloc.dupe(u8, node.id);
        defer alloc.free(path);
        const repo = try propValue(node, "repo", alloc);
        defer if (repo) |value| alloc.free(value);
        if (repo) |value| return std.fmt.allocPrint(alloc, "{s} ({s})", .{ path, value });
        return std.fmt.allocPrint(alloc, "{s}", .{path});
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
            return std.fmt.allocPrint(alloc, "{s}: req={s} file={s} line={s} {s} {s}", .{
                node.id,
                req_id,
                file_path,
                line_number,
                blame_author orelse "",
                short_hash orelse "",
            });
        }
        return std.fmt.allocPrint(alloc, "{s}: req={s} file={s} line={s}", .{
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
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ short_hash, date, message });
    }
    const statement = (try propValue(node, "statement", alloc)) orelse (try propValue(node, "description", alloc)) orelse try alloc.dupe(u8, "");
    defer alloc.free(statement);
    return std.fmt.allocPrint(alloc, "{s}: {s}", .{ node.id, statement });
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

fn writePdf(alloc: Allocator, streams: [][]u8, writer: anytype) !void {
    const page_count = streams.len;
    if (page_count == 0) return;

    const total_objs = 5 + 2 * page_count;
    const offsets = try alloc.alloc(u64, total_objs);
    defer alloc.free(offsets);
    @memset(offsets, 0);
    var pos: u64 = 0;

    const W = struct {
        fn all(w: anytype, data: []const u8, p: *u64) !void {
            try w.writeAll(data);
            p.* += data.len;
        }
        fn fmt(a: Allocator, w: anytype, p: *u64, comptime f: []const u8, args: anytype) !void {
            const s = try std.fmt.allocPrint(a, f, args);
            defer a.free(s);
            try w.writeAll(s);
            p.* += s.len;
        }
    };

    try W.all(writer, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n", &pos);

    offsets[0] = pos;
    try W.all(writer, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n", &pos);

    offsets[1] = pos;
    {
        var kids: std.ArrayList(u8) = .empty;
        defer kids.deinit(alloc);
        for (0..page_count) |i| {
            if (i > 0) try kids.appendSlice(alloc, " ");
            const s = try std.fmt.allocPrint(alloc, "{d} 0 R", .{5 + i});
            defer alloc.free(s);
            try kids.appendSlice(alloc, s);
        }
        try W.fmt(alloc, writer, &pos, "2 0 obj\n<< /Type /Pages /Kids [{s}] /Count {d} >>\nendobj\n", .{
            kids.items,
            page_count,
        });
    }

    offsets[2] = pos;
    try W.all(writer, "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n", &pos);

    offsets[3] = pos;
    try W.all(writer, "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>\nendobj\n", &pos);

    for (0..page_count) |i| {
        const page_id = 5 + i;
        const stream_id = 5 + page_count + i;

        offsets[page_id - 1] = pos;
        try W.fmt(alloc, writer, &pos, "{d} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\n   /Contents {d} 0 R\n   /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >>\n>>\nendobj\n", .{
            page_id,
            stream_id,
        });

        offsets[stream_id - 1] = pos;
        try W.fmt(alloc, writer, &pos, "{d} 0 obj\n<< /Length {d} >>\nstream\n", .{
            stream_id,
            streams[i].len,
        });
        try W.all(writer, streams[i], &pos);
        try W.all(writer, "\nendstream\nendobj\n", &pos);
    }

    const xref_pos = pos;
    try W.fmt(alloc, writer, &pos, "xref\n0 {d}\n", .{total_objs});
    try W.all(writer, "0000000000 65535 f \n", &pos);
    for (offsets) |off| {
        try W.fmt(alloc, writer, &pos, "{d:0>10} 00000 n \n", .{off});
    }

    try W.fmt(alloc, writer, &pos, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%%%EOF\n", .{
        total_objs,
        xref_pos,
    });
}

const testing = std.testing;

test "renderReport includes downstream design history content" {
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

    try testing.expect(std.mem.indexOf(u8, buf.items, "Full Traceability Report") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Detect GPS loss") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Design Inputs") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Timing spec") != null);
}
