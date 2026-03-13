/// Renders an in-memory Graph as a PDF Requirements Traceability Matrix.
///
/// Output: PDF 1.4, US Letter, 1-inch margins, Helvetica (no font embedding),
/// uncompressed content streams.  Gap rows are highlighted in yellow.
/// Page numbers appear in the footer.
///
/// Algorithm:
///   1. Lay out all sections into a PageBuilder (tracks y-cursor, auto-breaks).
///   2. Each page's content stream is buffered as []u8.
///   3. writePdf() assembles the final file with a precise xref table.

const std = @import("std");
const graph = @import("graph.zig");
const Graph = graph.Graph;
const RtmRow = graph.RtmRow;
const RiskRow = graph.RiskRow;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Page geometry (PDF user-space = points = 1/72 inch)
// ---------------------------------------------------------------------------

const PAGE_W: f32 = 612.0; // US Letter
const PAGE_H: f32 = 792.0;
const MARGIN: f32 = 72.0; // 1-inch margins
const CONTENT_W: f32 = PAGE_W - 2.0 * MARGIN; // 468 pt
const BODY_TOP: f32 = PAGE_H - MARGIN; // 720 pt
const BODY_BOT: f32 = MARGIN + 24.0; // 96 pt — stays above footer
const FOOTER_Y: f32 = 54.0;

const ROW_H: f32 = 14.0;
const FONT_BODY: f32 = 8.5;
const FONT_HDR_CELL: f32 = 8.5;
const FONT_SECTION: f32 = 11.0;
const FONT_TITLE: f32 = 14.0;
const FONT_FOOTER: f32 = 8.0;

const SECTION_GAP: f32 = 10.0;
const SECTION_HDR_H: f32 = 18.0;
const META_LINE_H: f32 = 13.0;

// Gap highlight (yellow)
const GAP_R: f32 = 1.0;
const GAP_G: f32 = 1.0;
const GAP_B: f32 = 0.0;

// Header row background (light gray)
const HDR_R: f32 = 0.851;
const HDR_G: f32 = 0.851;
const HDR_B: f32 = 0.851;

// ---------------------------------------------------------------------------
// Column widths (points, sum = CONTENT_W = 468 pt)
// Proportional to DXA widths in render_docx.zig, scaled by 0.05.
// ---------------------------------------------------------------------------

const COL_UN = [4]f32{ 42, 240, 108, 78 };
const COL_RTM = [11]f32{ 40, 36, 84, 46, 46, 34, 34, 40, 34, 34, 40 };
const COL_TST = [5]f32{ 42, 42, 90, 90, 204 };
const COL_RISK = [10]f32{ 36, 180, 24, 24, 24, 72, 36, 24, 24, 24 };

// ---------------------------------------------------------------------------
// Helvetica AFM character widths (1000 units per em, chars 0–255).
// Source: Adobe Helvetica AFM (public domain).  Unknown/non-ASCII → 556.
// ---------------------------------------------------------------------------

const HELV_WIDTHS: [256]u16 = blk: {
    var w = [_]u16{556} ** 256;
    // chars 32–126 (printable ASCII)
    const pw = [95]u16{
        278, 278, 355, 556, 556, 889, 667, 222, // 32–39
        333, 333, 389, 584, 278, 333, 278, 278, // 40–47
        556, 556, 556, 556, 556, 556, 556, 556, // 48–55
        556, 556, 278, 278, 584, 584, 584, 556, // 56–63
        1015, 667, 667, 722, 722, 667, 611, 778, // 64–71
        722, 278, 500, 667, 556, 833, 722, 778, // 72–79
        667, 778, 722, 667, 611, 722, 667, 944, // 80–87
        667, 667, 611, 278, 278, 278, 469, 556, // 88–95
        222, 556, 556, 500, 556, 556, 278, 556, // 96–103
        556, 222, 222, 500, 222, 833, 556, 556, // 104–111
        556, 556, 333, 500, 278, 556, 500, 722, // 112–119
        500, 500, 500, 334, 260, 334, 584, // 120–126
    };
    for (pw, 0..) |v, i| w[32 + i] = v;
    break :blk w;
};

/// Width of `text` in points at the given font size (ASCII only).
fn textWidth(text: []const u8, font_size: f32) f32 {
    var total: f32 = 0;
    for (text) |c| total += @as(f32, @floatFromInt(HELV_WIDTHS[c]));
    return total * font_size / 1000.0;
}

/// Return the longest prefix of `text` that fits within `max_w` points.
fn clipText(text: []const u8, max_w: f32, font_size: f32) []const u8 {
    if (textWidth(text, font_size) <= max_w) return text;
    var end: usize = text.len;
    while (end > 0) {
        end -= 1;
        if (textWidth(text[0..end], font_size) <= max_w) break;
    }
    return text[0..end];
}

// ---------------------------------------------------------------------------
// PDF string escaping
// ---------------------------------------------------------------------------

/// Append a PDF-escaped version of `text` to `buf`.
/// Handles: (, ), \ → backslash-escape; non-ASCII UTF-8 → ASCII substitutes.
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
            i += 1; // skip control characters
        } else {
            // Non-ASCII UTF-8 sequence
            const seq_len: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else if (c >= 0xC0) 2 else 1;
            const end = @min(i + seq_len, text.len);
            const seq = text[i..end];
            if (seq_len == 3 and seq.len == 3) {
                if (seq[0] == 0xE2 and seq[1] == 0x80 and seq[2] == 0x94) {
                    try buf.append(gpa, '-'); // U+2014 em dash → -
                } else if (seq[0] == 0xE2 and seq[1] == 0x86 and seq[2] == 0x92) {
                    try buf.appendSlice(gpa, "->"); // U+2192 → → ->
                } else if (seq[0] == 0xE2 and seq[1] == 0x9A and seq[2] == 0xA0) {
                    try buf.append(gpa, '!'); // U+26A0 ⚠ → !
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

// ---------------------------------------------------------------------------
// Page builder
// ---------------------------------------------------------------------------

const PageBuilder = struct {
    gpa: Allocator,
    pages: std.ArrayList([]u8), // completed content streams (owned slices)
    cur: std.ArrayList(u8), // current page content stream being built
    y: f32, // y-cursor (descends from BODY_TOP)

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

    /// Write footer and save the current content stream as a completed page.
    fn finalizePage(pb: *PageBuilder) !void {
        const gpa = pb.gpa;
        const footer = try std.fmt.allocPrint(gpa, "Page {d}", .{pb.pageNum()});
        defer gpa.free(footer);
        const fw = textWidth(footer, FONT_FOOTER);
        const fx = (PAGE_W - fw) / 2.0;

        var ftxt: std.ArrayList(u8) = .empty;
        defer ftxt.deinit(gpa);
        try appendPdfStr(&ftxt, gpa, footer);

        try pb.cur.print(gpa, "BT\n/F1 {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{ FONT_FOOTER, fx, FOOTER_Y });
        try pb.cur.appendSlice(gpa, ftxt.items);
        try pb.cur.appendSlice(gpa, ") Tj\nET\n");

        const owned = try pb.cur.toOwnedSlice(gpa);
        try pb.pages.append(gpa, owned);
        pb.cur = .empty;
        pb.y = BODY_TOP;
    }

    /// Start a new page if `needed` points would overflow the current one.
    fn ensureSpace(pb: *PageBuilder, needed: f32) !void {
        if (pb.y - needed < BODY_BOT) try pb.finalizePage();
    }

    // -----------------------------------------------------------------------
    // Drawing primitives
    // -----------------------------------------------------------------------

    fn drawTitleBlock(pb: *PageBuilder, input_filename: []const u8, timestamp: []const u8) !void {
        const gpa = pb.gpa;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(gpa);

        // "Requirements Traceability Matrix" (bold, large)
        try pb.ensureSpace(SECTION_HDR_H + META_LINE_H * 2);
        try pb.cur.print(gpa, "BT\n/F2 {d:.1} Tf\n{d:.1} {d:.1} Td\n(Requirements Traceability Matrix) Tj\nET\n", .{
            FONT_TITLE, MARGIN, pb.y - SECTION_HDR_H,
        });
        pb.y -= SECTION_HDR_H;

        // "Input: <filename>"
        tmp.clearRetainingCapacity();
        try appendPdfStr(&tmp, gpa, input_filename);
        try pb.cur.print(gpa, "BT\n/F1 {d:.1} Tf\n{d:.1} {d:.1} Td\n(Input: ", .{ FONT_BODY, MARGIN, pb.y - META_LINE_H });
        try pb.cur.appendSlice(gpa, tmp.items);
        try pb.cur.appendSlice(gpa, ") Tj\nET\n");
        pb.y -= META_LINE_H;

        // "Generated: <timestamp>"
        tmp.clearRetainingCapacity();
        try appendPdfStr(&tmp, gpa, timestamp);
        try pb.cur.print(gpa, "BT\n/F1 {d:.1} Tf\n{d:.1} {d:.1} Td\n(Generated: ", .{ FONT_BODY, MARGIN, pb.y - META_LINE_H });
        try pb.cur.appendSlice(gpa, tmp.items);
        try pb.cur.appendSlice(gpa, ") Tj\nET\n");
        pb.y -= META_LINE_H + SECTION_GAP;
    }

    fn drawSection(pb: *PageBuilder, heading: []const u8) !void {
        // Keep at least heading + one data row together
        try pb.ensureSpace(SECTION_GAP + SECTION_HDR_H + ROW_H);
        const gpa = pb.gpa;
        pb.y -= SECTION_GAP;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(gpa);
        try appendPdfStr(&tmp, gpa, heading);
        try pb.cur.print(gpa, "BT\n/F2 {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{
            FONT_SECTION, MARGIN, pb.y - SECTION_HDR_H + 4.0,
        });
        try pb.cur.appendSlice(gpa, tmp.items);
        try pb.cur.appendSlice(gpa, ") Tj\nET\n");
        pb.y -= SECTION_HDR_H;
    }

    fn drawTableHeader(pb: *PageBuilder, headers: []const []const u8, widths: []const f32) !void {
        try pb.ensureSpace(ROW_H);
        const gpa = pb.gpa;

        // Gray background
        try pb.cur.print(gpa, "{d:.3} {d:.3} {d:.3} rg\n", .{ HDR_R, HDR_G, HDR_B });
        var x: f32 = MARGIN;
        for (widths) |cw| {
            try pb.cur.print(gpa, "{d:.1} {d:.1} {d:.1} {d:.1} re\n", .{ x, pb.y - ROW_H, cw, ROW_H });
            x += cw;
        }
        try pb.cur.appendSlice(gpa, "f\n");

        // Cell borders
        try pb.cur.appendSlice(gpa, "0 0 0 RG\n");
        x = MARGIN;
        for (widths) |cw| {
            try pb.cur.print(gpa, "{d:.1} {d:.1} {d:.1} {d:.1} re\n", .{ x, pb.y - ROW_H, cw, ROW_H });
            x += cw;
        }
        try pb.cur.appendSlice(gpa, "S\n");

        // Bold header text
        try pb.cur.appendSlice(gpa, "0 0 0 rg\n");
        x = MARGIN;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(gpa);
        for (headers, widths) |hdr, cw| {
            const clip = clipText(hdr, cw - 4.0, FONT_HDR_CELL);
            tmp.clearRetainingCapacity();
            try appendPdfStr(&tmp, gpa, clip);
            try pb.cur.print(gpa, "BT\n/F2 {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{
                FONT_HDR_CELL, x + 2.0, pb.y - ROW_H + 3.5,
            });
            try pb.cur.appendSlice(gpa, tmp.items);
            try pb.cur.appendSlice(gpa, ") Tj\nET\n");
            x += cw;
        }
        pb.y -= ROW_H;
    }

    fn drawDataRow(pb: *PageBuilder, cells: []const []const u8, widths: []const f32, is_gap: bool) !void {
        try pb.ensureSpace(ROW_H);
        const gpa = pb.gpa;

        if (is_gap) {
            try pb.cur.print(gpa, "{d:.1} {d:.1} {d:.1} rg\n", .{ GAP_R, GAP_G, GAP_B });
            var x: f32 = MARGIN;
            for (widths) |cw| {
                try pb.cur.print(gpa, "{d:.1} {d:.1} {d:.1} {d:.1} re\n", .{ x, pb.y - ROW_H, cw, ROW_H });
                x += cw;
            }
            try pb.cur.appendSlice(gpa, "f\n");
        }

        // Borders
        try pb.cur.appendSlice(gpa, "0 0 0 RG\n");
        var x: f32 = MARGIN;
        for (widths) |cw| {
            try pb.cur.print(gpa, "{d:.1} {d:.1} {d:.1} {d:.1} re\n", .{ x, pb.y - ROW_H, cw, ROW_H });
            x += cw;
        }
        try pb.cur.appendSlice(gpa, "S\n");

        // Body text
        try pb.cur.appendSlice(gpa, "0 0 0 rg\n");
        x = MARGIN;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(gpa);
        for (cells, widths) |cell, cw| {
            const clip = clipText(cell, cw - 4.0, FONT_BODY);
            tmp.clearRetainingCapacity();
            try appendPdfStr(&tmp, gpa, clip);
            try pb.cur.print(gpa, "BT\n/F1 {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{
                FONT_BODY, x + 2.0, pb.y - ROW_H + 3.5,
            });
            try pb.cur.appendSlice(gpa, tmp.items);
            try pb.cur.appendSlice(gpa, ") Tj\nET\n");
            x += cw;
        }
        pb.y -= ROW_H;
    }

    fn drawText(pb: *PageBuilder, text: []const u8, font_size: f32, bold: bool) !void {
        const line_h = font_size * 1.5;
        try pb.ensureSpace(line_h);
        const gpa = pb.gpa;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(gpa);
        try appendPdfStr(&tmp, gpa, text);
        const font: []const u8 = if (bold) "/F2" else "/F1";
        try pb.cur.print(gpa, "BT\n{s} {d:.1} Tf\n{d:.1} {d:.1} Td\n(", .{
            font, font_size, MARGIN, pb.y - line_h + 3.0,
        });
        try pb.cur.appendSlice(gpa, tmp.items);
        try pb.cur.appendSlice(gpa, ") Tj\nET\n");
        pb.y -= line_h;
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Write a full PDF RTM report for `g` to `writer`.
pub fn renderPdf(
    g: *const Graph,
    input_filename: []const u8,
    timestamp: []const u8,
    writer: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pb = PageBuilder.init(alloc);
    defer pb.deinit();

    // -----------------------------------------------------------------------
    // Collect and sort data (mirrors render_md.zig)
    // -----------------------------------------------------------------------

    var uns: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.user_need, alloc, &uns);
    std.mem.sort(*const graph.Node, uns.items, {}, nodeIdLt);

    var rtm_rows: std.ArrayList(RtmRow) = .empty;
    try g.rtm(alloc, &rtm_rows);
    std.mem.sort(RtmRow, rtm_rows.items, {}, rtmRowLt);

    var gap_findings: std.ArrayList(graph.GapFinding) = .empty;
    try g.collectGapFindings(alloc, &gap_findings);

    // Test rows (same traversal as render_md.zig)
    const TestRow = struct {
        tg_id: []const u8,
        test_id: []const u8,
        test_type: []const u8,
        test_method: []const u8,
        req_id: ?[]const u8,
    };
    var tg_nodes: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.test_group, alloc, &tg_nodes);
    var test_rows: std.ArrayList(TestRow) = .empty;
    for (tg_nodes.items) |tg| {
        var edges_in: std.ArrayList(graph.Edge) = .empty;
        try g.edgesTo(tg.id, alloc, &edges_in);
        var req_id: ?[]const u8 = null;
        for (edges_in.items) |e| {
            if (e.label == .tested_by) { req_id = e.from_id; break; }
        }
        var edges_out: std.ArrayList(graph.Edge) = .empty;
        try g.edgesFrom(tg.id, alloc, &edges_out);
        for (edges_out.items) |e| {
            if (e.label != .has_test) continue;
            const t = g.getNode(e.to_id);
            try test_rows.append(alloc, .{
                .tg_id = tg.id,
                .test_id = e.to_id,
                .test_type = if (t) |n| n.get("test_type") orelse "" else "",
                .test_method = if (t) |n| n.get("test_method") orelse "" else "",
                .req_id = req_id,
            });
        }
    }
    std.mem.sort(TestRow, test_rows.items, {}, struct {
        fn lt(_: void, a: TestRow, b: TestRow) bool {
            const c = std.mem.order(u8, a.tg_id, b.tg_id);
            if (c != .eq) return c == .lt;
            return std.mem.order(u8, a.test_id, b.test_id) == .lt;
        }
    }.lt);

    var risk_rows: std.ArrayList(RiskRow) = .empty;
    try g.risks(alloc, &risk_rows);
    std.mem.sort(RiskRow, risk_rows.items, {}, struct {
        fn lt(_: void, a: RiskRow, b: RiskRow) bool {
            return std.mem.order(u8, a.risk_id, b.risk_id) == .lt;
        }
    }.lt);

    // -----------------------------------------------------------------------
    // Lay out content into pages
    // -----------------------------------------------------------------------

    try pb.drawTitleBlock(input_filename, timestamp);

    // User Needs
    try pb.drawSection("User Needs");
    try pb.drawTableHeader(&.{ "ID", "Statement", "Source", "Priority" }, &COL_UN);
    for (uns.items) |n| {
        const cells = [4][]const u8{
            n.id,
            n.get("statement") orelse "",
            n.get("source") orelse "",
            n.get("priority") orelse "",
        };
        try pb.drawDataRow(&cells, &COL_UN, false);
    }

    // Requirements Traceability
    try pb.drawSection("Requirements Traceability");
    try pb.drawTableHeader(
        &.{ "Req ID", "User Need", "Statement", "Test Group", "Test ID", "Type", "Method", "Status", "Src File", "Test File", "Commit" },
        &COL_RTM,
    );
    for (rtm_rows.items) |row| {
        const has_gap = requirementHasGap(gap_findings.items, row.req_id);
        const cells = [11][]const u8{
            row.req_id,
            row.user_need_id orelse "-",
            row.statement,
            row.test_group_id orelse "-",
            row.test_id orelse "-",
            row.test_type orelse "-",
            row.test_method orelse "-",
            row.status,
            row.source_file orelse "",
            row.test_file orelse "",
            row.last_commit orelse "",
        };
        try pb.drawDataRow(&cells, &COL_RTM, has_gap);
    }

    // Tests
    try pb.drawSection("Tests");
    try pb.drawTableHeader(&.{ "Test Group", "Test ID", "Type", "Method", "Linked Reqs" }, &COL_TST);
    for (test_rows.items) |row| {
        var linked_reqs = std.ArrayList(u8).empty;
        defer linked_reqs.deinit(alloc);
        var edges_in: std.ArrayList(graph.Edge) = .empty;
        defer edges_in.deinit(alloc);
        try g.edgesTo(row.tg_id, alloc, &edges_in);
        for (edges_in.items) |e| {
            if (e.label != .tested_by) continue;
            if (linked_reqs.items.len > 0) try linked_reqs.appendSlice(alloc, ", ");
            try linked_reqs.appendSlice(alloc, e.from_id);
        }
        const cells = [5][]const u8{
            row.tg_id,
            row.test_id,
            row.test_type,
            row.test_method,
            if (linked_reqs.items.len > 0) linked_reqs.items else "-",
        };
        try pb.drawDataRow(&cells, &COL_TST, false);
    }

    // Risk Register
    try pb.drawSection("Risk Register");
    try pb.drawTableHeader(
        &.{ "Risk ID", "Description", "IS", "IL", "ISc", "Mitigation", "Req", "RS", "RL", "RSc" },
        &COL_RISK,
    );
    for (risk_rows.items) |row| {
        const has_gap = riskHasGap(gap_findings.items, row.risk_id);
        var ib: [32]u8 = undefined;
        var rb: [32]u8 = undefined;
        const cells = [10][]const u8{
            row.risk_id,
            row.description,
            row.initial_severity orelse "-",
            row.initial_likelihood orelse "-",
            scoreStr(&ib, row.initial_severity, row.initial_likelihood),
            row.mitigation orelse "-",
            row.req_id orelse "-",
            row.residual_severity orelse "-",
            row.residual_likelihood orelse "-",
            scoreStr(&rb, row.residual_severity, row.residual_likelihood),
        };
        try pb.drawDataRow(&cells, &COL_RISK, has_gap);
    }

    // Gap Summary
    const total = hardGapCount(gap_findings.items);

    try pb.drawSection("Gap Summary");
    const gap_line = try std.fmt.allocPrint(alloc, "{d} gap(s) found.", .{total});
    try pb.drawText(gap_line, FONT_BODY, true);
    if (gap_findings.items.len == 0) {
        try pb.drawText("No gaps detected.", FONT_BODY, false);
    } else {
        try drawGapGroupPdf(&pb, alloc, "Hard Gaps", gap_findings.items, .hard);
        try drawGapGroupPdf(&pb, alloc, "Advisory Gaps", gap_findings.items, .advisory);
    }

    // Flush the last page
    if (pb.cur.items.len > 0) try pb.finalizePage();

    try writePdf(alloc, pb.pages.items, writer);
}

// ---------------------------------------------------------------------------
// DHR report (PDF)
// ---------------------------------------------------------------------------

/// Write a Design History Record (DHR) PDF report for `g` to `writer`.
pub fn renderDhrPdf(
    g: *const Graph,
    writer: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pb = PageBuilder.init(alloc);
    defer pb.deinit();

    try pb.cur.print(alloc, "BT\n/F2 {d:.1} Tf\n{d:.1} {d:.1} Td\n(Design History Record) Tj\nET\n", .{
        FONT_TITLE, MARGIN, pb.y - SECTION_HDR_H,
    });
    pb.y -= SECTION_HDR_H + SECTION_GAP;

    var uns: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.user_need, alloc, &uns);
    std.mem.sort(*const graph.Node, uns.items, {}, nodeIdLt);

    for (uns.items) |un| {
        const section_title = try std.fmt.allocPrint(alloc, "{s}", .{un.id});
        try pb.drawSection(section_title);

        const statement = un.get("statement") orelse "";
        if (statement.len > 0) {
            const line = try std.fmt.allocPrint(alloc, "Statement: {s}", .{statement});
            try pb.drawText(line, FONT_BODY, false);
        }

        // Find requirements derived from this user need
        var reqs: std.ArrayList(*const graph.Node) = .empty;
        for (g.edges.items) |e| {
            if (e.label == .derives_from and std.mem.eql(u8, e.to_id, un.id)) {
                if (g.getNode(e.from_id)) |req| {
                    try reqs.append(alloc, req);
                }
            }
        }
        std.mem.sort(*const graph.Node, reqs.items, {}, nodeIdLt);

        for (reqs.items) |req| {
            const req_stmt = req.get("statement") orelse "";
            const line = try std.fmt.allocPrint(alloc, "  - {s}: {s}", .{ req.id, req_stmt });
            try pb.drawText(line, FONT_BODY, false);
        }
    }

    if (pb.cur.items.len > 0) try pb.finalizePage();
    try writePdf(alloc, pb.pages.items, writer);
}

// ---------------------------------------------------------------------------
// PDF assembly
// ---------------------------------------------------------------------------

/// Write a complete PDF file from pre-rendered content streams.
///
/// Object numbering (1-indexed):
///   1  Catalog
///   2  Pages
///   3  Font /F1  (Helvetica)
///   4  Font /F2  (Helvetica-Bold)
///   5 .. 4+N    Page objects
///   5+N .. 4+2N Content streams
///
/// Total objects including free head (obj 0) = 5 + 2*N.
fn writePdf(alloc: Allocator, streams: [][]u8, writer: anytype) !void {
    const N = streams.len;
    if (N == 0) return;

    const total_objs = 5 + 2 * N;
    const offsets = try alloc.alloc(u64, total_objs); // offsets[i] = byte offset of object i+1
    @memset(offsets, 0);
    var pos: u64 = 0;

    // write bytes and track position
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

    // Header — 4 high bytes mark this as a binary file
    try W.all(writer, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n", &pos);

    // Object 1: Catalog
    offsets[0] = pos;
    try W.all(writer, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n", &pos);

    // Object 2: Pages (lists all page objects)
    offsets[1] = pos;
    {
        var kids: std.ArrayList(u8) = .empty;
        defer kids.deinit(alloc);
        for (0..N) |i| {
            if (i > 0) try kids.appendSlice(alloc, " ");
            const s = try std.fmt.allocPrint(alloc, "{d} 0 R", .{5 + i});
            defer alloc.free(s);
            try kids.appendSlice(alloc, s);
        }
        try W.fmt(alloc, writer, &pos,
            "2 0 obj\n<< /Type /Pages /Kids [{s}] /Count {d} >>\nendobj\n",
            .{ kids.items, N },
        );
    }

    // Object 3: Font /F1 Helvetica
    offsets[2] = pos;
    try W.all(writer,
        "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " ++
            "/Encoding /WinAnsiEncoding >>\nendobj\n",
        &pos,
    );

    // Object 4: Font /F2 Helvetica-Bold
    offsets[3] = pos;
    try W.all(writer,
        "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold " ++
            "/Encoding /WinAnsiEncoding >>\nendobj\n",
        &pos,
    );

    // Page objects + content streams (interleaved for locality)
    for (0..N) |i| {
        const page_id = 5 + i;
        const cs_id = 5 + N + i;

        // Page object
        offsets[page_id - 1] = pos;
        try W.fmt(alloc, writer, &pos,
            "{d} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\n" ++
                "   /Contents {d} 0 R\n" ++
                "   /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >>\n>>\nendobj\n",
            .{ page_id, cs_id },
        );

        // Content stream
        offsets[cs_id - 1] = pos;
        try W.fmt(alloc, writer, &pos,
            "{d} 0 obj\n<< /Length {d} >>\nstream\n",
            .{ cs_id, streams[i].len },
        );
        try W.all(writer, streams[i], &pos);
        try W.all(writer, "\nendstream\nendobj\n", &pos);
    }

    // Cross-reference table
    const xref_pos = pos;
    try W.fmt(alloc, writer, &pos, "xref\n0 {d}\n", .{total_objs});
    // Object 0: free list head
    try W.all(writer, "0000000000 65535 f \n", &pos);
    // Objects 1..total_objs-1
    for (offsets) |off| {
        try W.fmt(alloc, writer, &pos, "{d:0>10} 00000 n \n", .{off});
    }

    // Trailer
    try W.fmt(alloc, writer, &pos,
        "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%%%EOF\n",
        .{ total_objs, xref_pos },
    );
}

// ---------------------------------------------------------------------------
// Helpers (mirrors render_md.zig)
// ---------------------------------------------------------------------------

fn nodeIdLt(_: void, a: *const graph.Node, b: *const graph.Node) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn rtmRowLt(_: void, a: RtmRow, b: RtmRow) bool {
    const c = std.mem.order(u8, a.req_id, b.req_id);
    if (c != .eq) return c == .lt;
    const tg = std.mem.order(u8, a.test_group_id orelse "", b.test_group_id orelse "");
    if (tg != .eq) return tg == .lt;
    return std.mem.order(u8, a.test_id orelse "", b.test_id orelse "") == .lt;
}

fn scoreStr(buf: []u8, sev: ?[]const u8, lik: ?[]const u8) []const u8 {
    const s = sev orelse return "-";
    const l = lik orelse return "-";
    const si = std.fmt.parseInt(u64, s, 10) catch return "-";
    const li = std.fmt.parseInt(u64, l, 10) catch return "-";
    return std.fmt.bufPrint(buf, "{d}", .{si * li}) catch "-";
}

fn hardGapCount(findings: []const graph.GapFinding) usize {
    var count: usize = 0;
    for (findings) |finding| {
        if (finding.severity == .hard) count += 1;
    }
    return count;
}

fn requirementHasGap(findings: []const graph.GapFinding, req_id: []const u8) bool {
    for (findings) |finding| {
        if (std.mem.eql(u8, finding.primary_id, req_id)) {
            switch (finding.kind) {
                .requirement_no_user_need_link,
                .requirement_no_test_group_link,
                .requirement_only_unresolved_test_group_refs,
                .requirement_linked_to_empty_test_group,
                => return true,
                else => {},
            }
        }
    }
    return false;
}

fn riskHasGap(findings: []const graph.GapFinding, risk_id: []const u8) bool {
    for (findings) |finding| {
        if (std.mem.eql(u8, finding.primary_id, risk_id)) {
            switch (finding.kind) {
                .risk_without_mitigation_requirement,
                .risk_unresolved_mitigation_requirement,
                => return true,
                else => {},
            }
        }
    }
    return false;
}

fn drawGapGroupPdf(pb: *PageBuilder, alloc: Allocator, group_title: []const u8, findings: []const graph.GapFinding, severity: graph.GapSeverity) !void {
    var wrote_group = false;
    const sections = [_]struct { kind: graph.GapKind, heading: []const u8 }{
        .{ .kind = .requirement_no_user_need_link, .heading = "Requirements with No User Need" },
        .{ .kind = .requirement_no_test_group_link, .heading = "Requirements with No Test Group Link" },
        .{ .kind = .requirement_only_unresolved_test_group_refs, .heading = "Requirements with Only Unresolved Test Group References" },
        .{ .kind = .risk_without_mitigation_requirement, .heading = "Risks with No Mitigation Requirement" },
        .{ .kind = .risk_unresolved_mitigation_requirement, .heading = "Risks with Unresolved Mitigation Requirement" },
        .{ .kind = .user_need_without_requirements, .heading = "User Needs with No Requirements" },
        .{ .kind = .requirement_linked_to_empty_test_group, .heading = "Requirements Linked to Empty Test Groups" },
        .{ .kind = .test_group_without_requirements, .heading = "Test Groups with No Requirements" },
    };
    for (sections) |section| {
        var count: usize = 0;
        for (findings) |finding| {
            if (finding.severity == severity and finding.kind == section.kind) count += 1;
        }
        if (count == 0) continue;
        if (!wrote_group) {
            try pb.drawText(group_title, FONT_BODY, true);
            wrote_group = true;
        }
        const hdr = try std.fmt.allocPrint(alloc, "{s} ({d})", .{ section.heading, count });
        try pb.drawText(hdr, FONT_BODY, true);
        for (findings) |finding| {
            if (finding.severity != severity or finding.kind != section.kind) continue;
            const line = if (finding.related_id) |related|
                try std.fmt.allocPrint(alloc, "  - {s} -> {s}", .{ finding.primary_id, related })
            else
                try std.fmt.allocPrint(alloc, "  - {s}", .{finding.primary_id});
            try pb.drawText(line, FONT_BODY, false);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const xlsx = @import("xlsx.zig");
const schema = @import("schema.zig");

test "render_pdf fixture" {
    var tmp_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sheets = try xlsx.parse(tmp, "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try schema.ingest(&g, sheets);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderPdf(&g, "RTMify_Requirements_Tracking_Template.xlsx", "2024-01-01T00:00:00Z",
        buf.writer(testing.allocator));

    const out = buf.items;

    // PDF structure
    try testing.expect(std.mem.startsWith(u8, out, "%PDF-1.4"));
    try testing.expect(std.mem.indexOf(u8, out, "/Helvetica") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/Helvetica-Bold") != null);
    try testing.expect(std.mem.indexOf(u8, out, "xref") != null);
    try testing.expect(std.mem.indexOf(u8, out, "%%EOF") != null);
    try testing.expect(std.mem.indexOf(u8, out, "startxref") != null);

    // Content
    try testing.expect(std.mem.indexOf(u8, out, "BT") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/F1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/F2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Page 1") != null);

    // Gap row yellow highlight (fixture has gaps)
    try testing.expect(std.mem.indexOf(u8, out, "1.0 1.0 0.0 rg") != null);

    // Gap summary section (parens are PDF-escaped to \( \))
    try testing.expect(std.mem.indexOf(u8, out, "gap\\(s\\) found.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Hard Gaps") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Advisory Gaps") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Unresolved Mitigation Requirement") != null);
}

test "render_pdf no gaps no yellow" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("UN-001", .user_need, &.{
        .{ .key = "statement", .value = "Need" },
        .{ .key = "source", .value = "Customer" },
        .{ .key = "priority", .value = "high" },
    });
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "SHALL do" },
        .{ .key = "status", .value = "Approved" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("T-001", .test_case, &.{
        .{ .key = "test_type", .value = "Verification" },
        .{ .key = "test_method", .value = "Test" },
    });
    try g.addEdge("REQ-001", "UN-001", .derives_from);
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("TG-001", "T-001", .has_test);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderPdf(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    const out = buf.items;
    try testing.expect(std.mem.startsWith(u8, out, "%PDF-1.4"));
    try testing.expect(std.mem.indexOf(u8, out, "%%EOF") != null);

    // No yellow fill for gap rows
    try testing.expect(std.mem.indexOf(u8, out, "1.0 1.0 0.0 rg") == null);

    // Gap summary shows 0 (parens are PDF-escaped)
    try testing.expect(std.mem.indexOf(u8, out, "0 gap\\(s\\) found.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "No gaps detected.") != null);
}

test "render_pdf pdf string escaping" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("UN-001", .user_need, &.{
        .{ .key = "statement", .value = "Needs (parens) and \\backslash" },
        .{ .key = "source", .value = "A & B" },
        .{ .key = "priority", .value = "high" },
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderPdf(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    const out = buf.items;
    // Parens and backslash must be escaped in the PDF output
    try testing.expect(std.mem.indexOf(u8, out, "\\(parens\\)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\\\backslash") != null);
    // Raw unescaped ( or ) inside a string context should not appear unescaped
    // (we can't easily verify the absence without a full PDF parser, so just
    //  verify the escape sequences are present)
}

test "render_pdf includes multiple test groups and plural linked requirements" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "One" }});
    try g.addNode("REQ-002", .requirement, &.{.{ .key = "statement", .value = "Two" }});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("TG-002", .test_group, &.{});
    try g.addNode("T-001", .test_case, &.{});
    try g.addNode("T-002", .test_case, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("REQ-001", "TG-002", .tested_by);
    try g.addEdge("REQ-002", "TG-001", .tested_by);
    try g.addEdge("TG-001", "T-001", .has_test);
    try g.addEdge("TG-002", "T-002", .has_test);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderPdf(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    const out = buf.items;
    try testing.expect(std.mem.indexOf(u8, out, "TG-001") != null);
    try testing.expect(std.mem.indexOf(u8, out, "TG-002") != null);
    try testing.expect(std.mem.indexOf(u8, out, "REQ-001, REQ-002") != null);
}

test "render_pdf sorts RTM rows by requirement and preserves test group and test id text" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("REQ-B", .requirement, &.{.{ .key = "statement", .value = "Second" }});
    try g.addNode("REQ-A", .requirement, &.{.{ .key = "statement", .value = "First" }});
    try g.addNode("TG-002", .test_group, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("T-002-01", .test_case, &.{});
    try g.addNode("T-001-01", .test_case, &.{});
    try g.addEdge("REQ-B", "TG-002", .tested_by);
    try g.addEdge("REQ-A", "TG-001", .tested_by);
    try g.addEdge("TG-002", "T-002-01", .has_test);
    try g.addEdge("TG-001", "T-001-01", .has_test);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderPdf(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    const out = buf.items;
    const reqAIndex = std.mem.indexOf(u8, out, "REQ-A") orelse unreachable;
    const reqBIndex = std.mem.indexOf(u8, out, "REQ-B") orelse unreachable;
    try testing.expect(reqAIndex < reqBIndex);
    try testing.expect(std.mem.indexOf(u8, out, "TG-001") != null);
    try testing.expect(std.mem.indexOf(u8, out, "TG-002") != null);
    try testing.expect(std.mem.indexOf(u8, out, "T-001-01") != null);
    try testing.expect(std.mem.indexOf(u8, out, "T-002-01") != null);
}

test "appendPdfStr em dash and arrow" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // em dash: U+2014 = 0xE2 0x80 0x94
    try appendPdfStr(&buf, testing.allocator, "\xe2\x80\x94");
    try testing.expectEqualStrings("-", buf.items);

    buf.clearRetainingCapacity();
    // → U+2192 = 0xE2 0x86 0x92
    try appendPdfStr(&buf, testing.allocator, "\xe2\x86\x92");
    try testing.expectEqualStrings("->", buf.items);
}

test "textWidth and clipText" {
    // "REQ-001" at 8.5pt: (278+556+556+278+556+556+278) * 8.5/1000
    const w = textWidth("REQ-001", 8.5);
    try testing.expect(w > 20.0 and w < 50.0);

    // Clip should return empty or partial string for tiny max width
    const clipped = clipText("Hello World", 1.0, 8.5);
    try testing.expect(clipped.len < "Hello World".len);
}
