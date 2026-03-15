/// Renders an in-memory Graph as a Markdown Requirements Traceability Matrix.
///
/// All sections (User Needs, Requirements Traceability, Tests, Risk Register,
/// Gap Summary) are sorted deterministically by ID so output is stable across
/// hash-map iteration orders.

const std = @import("std");
const graph = @import("graph.zig");
const Graph = graph.Graph;
const RtmRow = graph.RtmRow;
const RiskRow = graph.RiskRow;
const profile_mod = @import("profile.zig");
const report_mod = @import("report.zig");

const DASH = "—"; // U+2014 em dash

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Write a full Markdown RTM report for `g` to `writer`.
/// `input_filename` and `timestamp` are embedded verbatim in the title block.
pub fn renderMd(
    g: *const Graph,
    input_filename: []const u8,
    timestamp: []const u8,
    writer: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // -----------------------------------------------------------------------
    // Title block
    // -----------------------------------------------------------------------
    try writer.print("# Requirements Traceability Matrix\n\n", .{});
    try writer.print("Input: {s}\n", .{input_filename});
    try writer.print("Generated: {s}\n", .{timestamp});

    // -----------------------------------------------------------------------
    // User Needs
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## User Needs\n\n");
    try writer.writeAll("| ID | Statement | Source | Priority |\n");
    try writer.writeAll("| --- | --- | --- | --- |\n");

    var uns: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.user_need, alloc, &uns);
    std.mem.sort(*const graph.Node, uns.items, {}, nodeIdLt);
    for (uns.items) |n| {
        try writer.print("| {s} | {s} | {s} | {s} |\n", .{
            n.id,
            n.get("statement") orelse "",
            n.get("source") orelse "",
            n.get("priority") orelse "",
        });
    }

    // -----------------------------------------------------------------------
    // Requirements Traceability
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## Requirements Traceability\n\n");
    try writer.writeAll("| Req ID | User Need | Statement | Test Group | Test ID | Type | Method | Status | Source File | Test File | Last Commit |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");

    var rtm_rows: std.ArrayList(RtmRow) = .empty;
    try g.rtm(alloc, &rtm_rows);
    std.mem.sort(RtmRow, rtm_rows.items, {}, rtmRowLt);

    var gap_findings: std.ArrayList(graph.GapFinding) = .empty;
    try g.collectGapFindings(alloc, &gap_findings);

    for (rtm_rows.items) |row| {
        const has_gap = requirementHasGap(gap_findings.items, row.req_id);
        const req_prefix: []const u8 = if (has_gap) "**⚠** " else "";
        const un = row.user_need_id orelse DASH;
        const tg = row.test_group_id orelse DASH;
        const tid = row.test_id orelse DASH;
        const typ = row.test_type orelse DASH;
        const meth = row.test_method orelse DASH;
        try writer.print("| {s}{s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n", .{
            req_prefix, row.req_id, un, row.statement,
            tg, tid, typ, meth, row.status,
            row.source_file orelse "",
            row.test_file orelse "",
            row.last_commit orelse "",
        });
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## Tests\n\n");
    try writer.writeAll("| Test Group | Test ID | Type | Method | Linked Reqs |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- |\n");

    const TestRow = struct {
        tg_id: []const u8,
        test_id: []const u8,
        test_type: []const u8,
        test_method: []const u8,
        req_ids: []const u8,
    };

    var tg_nodes: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.test_group, alloc, &tg_nodes);

    var test_rows: std.ArrayList(TestRow) = .empty;
    for (tg_nodes.items) |tg| {
        // Find requirement linked to this test group (TESTED_BY tg)
        var edges_in: std.ArrayList(graph.Edge) = .empty;
        try g.edgesTo(tg.id, alloc, &edges_in);
        var req_ids_buf: std.ArrayList(u8) = .empty;
        for (edges_in.items) |e| {
            if (e.label == .tested_by) {
                if (req_ids_buf.items.len > 0) try req_ids_buf.appendSlice(alloc, ", ");
                try req_ids_buf.appendSlice(alloc, e.from_id);
            }
        }
        const req_ids = if (req_ids_buf.items.len > 0) try alloc.dupe(u8, req_ids_buf.items) else DASH;

        // Find test cases in this group (tg HAS_TEST test)
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
                .req_ids = req_ids,
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

    for (test_rows.items) |row| {
        try writer.print("| {s} | {s} | {s} | {s} | {s} |\n", .{
            row.tg_id, row.test_id, row.test_type, row.test_method, row.req_ids,
        });
    }

    // -----------------------------------------------------------------------
    // Risk Register
    // -----------------------------------------------------------------------
    try writer.writeAll("\n## Risk Register\n\n");
    try writer.writeAll("| Risk ID | Description | Init. Sev | Init. Like | Init. Score | Mitigation | Linked Req | Res. Sev | Res. Like | Res. Score |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");

    var risk_rows: std.ArrayList(RiskRow) = .empty;
    try g.risks(alloc, &risk_rows);
    std.mem.sort(RiskRow, risk_rows.items, {}, struct {
        fn lt(_: void, a: RiskRow, b: RiskRow) bool {
            return std.mem.order(u8, a.risk_id, b.risk_id) == .lt;
        }
    }.lt);

    for (risk_rows.items) |row| {
        const has_gap = riskHasGap(gap_findings.items, row.risk_id);
        const req_prefix: []const u8 = if (has_gap) "**⚠** " else "";
        const req_str = row.req_id orelse DASH;
        const init_sev = row.initial_severity orelse DASH;
        const init_lik = row.initial_likelihood orelse DASH;
        const res_sev = row.residual_severity orelse DASH;
        const res_lik = row.residual_likelihood orelse DASH;
        const mit = row.mitigation orelse DASH;

        var init_score_buf: [32]u8 = undefined;
        var res_score_buf: [32]u8 = undefined;
        const init_score = scoreStr(&init_score_buf, row.initial_severity, row.initial_likelihood);
        const res_score = scoreStr(&res_score_buf, row.residual_severity, row.residual_likelihood);

        try writer.print("| {s} | {s} | {s} | {s} | {s} | {s} | {s}{s} | {s} | {s} | {s} |\n", .{
            row.risk_id, row.description,
            init_sev, init_lik, init_score,
            mit,
            req_prefix, req_str,
            res_sev, res_lik, res_score,
        });
    }

    // -----------------------------------------------------------------------
    // Gap Summary
    // -----------------------------------------------------------------------
    const total = hardGapCount(gap_findings.items);
    try writer.print("\n## Gap Summary\n\n**{d} gap(s) found.**\n", .{total});
    if (gap_findings.items.len == 0) {
        try writer.writeAll("\nNo gaps detected.\n");
    } else {
        try renderGapGroup(writer, "Hard Gaps", gap_findings.items, .hard);
        try renderGapGroup(writer, "Advisory Gaps", gap_findings.items, .advisory);
    }
}

pub fn renderMdWithContext(
    g: *const Graph,
    ctx: report_mod.ReportContext,
    input_filename: []const u8,
    timestamp: []const u8,
    writer: anytype,
) !void {
    if (ctx.profile == .generic) return renderMd(g, input_filename, timestamp, writer);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const profile = profile_mod.get(ctx.profile);

    try writer.print("# Requirements Traceability Matrix\n\n", .{});
    try writer.print("Input: {s}\n", .{input_filename});
    try writer.print("Generated: {s}\n", .{timestamp});
    try writer.print("Profile: {s}\n", .{profile.short_name});
    try writer.print("Standards: {s}\n", .{profile.standards});

    try writer.writeAll("\n## Summary\n\n");
    try writer.print("- Profile: {s}\n", .{profile.name});
    try writer.print("- Standards: {s}\n", .{profile.standards});
    try writer.print("- Hard gaps: {d}\n", .{report_mod.hardGapCount(ctx.merged_gaps)});
    try writer.print("- Total findings: {d}\n", .{ctx.merged_gaps.len});

    try writer.writeAll("\n## User Needs\n\n");
    try writer.writeAll("| ID | Statement | Source | Priority |\n");
    try writer.writeAll("| --- | --- | --- | --- |\n");
    var uns: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.user_need, alloc, &uns);
    std.mem.sort(*const graph.Node, uns.items, {}, nodeIdLt);
    for (uns.items) |n| {
        try writer.print("| {s} | {s} | {s} | {s} |\n", .{
            n.id,
            n.get("statement") orelse "",
            n.get("source") orelse "",
            n.get("priority") orelse "",
        });
    }

    try renderDesignInputsSection(g, writer, alloc);
    try renderDesignOutputsSection(g, writer, alloc);
    try renderRequirementsTraceabilityWithProfile(g, ctx, writer, alloc);
    try renderTestsSection(g, writer, alloc);
    try renderRiskSection(g, ctx, writer, alloc);
    try renderConfigItemsSection(g, writer, alloc);
    try renderTraceGapSummary(writer, ctx.merged_gaps);
    try renderProfileComplianceSummary(g, ctx, writer, alloc);
}

// ---------------------------------------------------------------------------
// DHR report
// ---------------------------------------------------------------------------

/// Write a Design History Record (DHR) markdown report for `g` to `writer`.
/// Sections are organized per UserNeed, showing the full UN → REQ chain.
pub fn renderDhr(
    g: *const Graph,
    writer: anytype,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try writer.writeAll("# Design History Record\n\n");

    var uns: std.ArrayList(*const graph.Node) = .empty;
    try g.nodesByType(.user_need, alloc, &uns);
    std.mem.sort(*const graph.Node, uns.items, {}, nodeIdLt);

    for (uns.items) |un| {
        try writer.print("## {s}\n\n", .{un.id});
        const statement = un.get("statement") orelse "";
        if (statement.len > 0) {
            try writer.print("**Statement**: {s}\n\n", .{statement});
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

        if (reqs.items.len == 0) {
            try writer.writeAll("_No requirements linked._\n\n");
            continue;
        }

        try writer.writeAll("### Requirements\n\n");
        for (reqs.items) |req| {
            const req_stmt = req.get("statement") orelse "";
            const req_status = req.get("status") orelse "";
            try writer.print("- **{s}**: {s}", .{ req.id, req_stmt });
            if (req_status.len > 0) {
                try writer.print(" _(status: {s})_", .{req_status});
            }
            try writer.writeByte('\n');
        }
        try writer.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Helpers
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

fn nodeHasId(nodes: []const *const graph.Node, id: []const u8) bool {
    for (nodes) |n| if (std.mem.eql(u8, n.id, id)) return true;
    return false;
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

fn renderGapGroup(writer: anytype, group_title: []const u8, findings: []const graph.GapFinding, severity: graph.GapSeverity) !void {
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
            try writer.print("\n### {s}\n", .{group_title});
            wrote_group = true;
        }
        try writer.print("\n#### {s} ({d})\n\n", .{ section.heading, count });
        for (findings) |finding| {
            if (finding.severity != severity or finding.kind != section.kind) continue;
            if (finding.related_id) |related| {
                try writer.print("- {s} \u{2192} {s}\n", .{ finding.primary_id, related });
            } else {
                try writer.print("- {s}\n", .{finding.primary_id});
            }
        }
    }
}

fn scoreStr(buf: []u8, sev: ?[]const u8, lik: ?[]const u8) []const u8 {
    const s = sev orelse return DASH;
    const l = lik orelse return DASH;
    const si = std.fmt.parseInt(u64, s, 10) catch return DASH;
    const li = std.fmt.parseInt(u64, l, 10) catch return DASH;
    return std.fmt.bufPrint(buf, "{d}", .{si * li}) catch DASH;
}

fn renderDesignInputsSection(g: *const Graph, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Design Inputs\n\n");
    try writer.writeAll("| ID | Description | Type | Linked Requirements |\n");
    try writer.writeAll("| --- | --- | --- | --- |\n");

    var nodes: std.ArrayList(*const graph.Node) = .empty;
    defer nodes.deinit(alloc);
    try g.nodesByType(.design_input, alloc, &nodes);
    std.mem.sort(*const graph.Node, nodes.items, {}, nodeIdLt);

    for (nodes.items) |n| {
        const reqs = try linkedNodeIds(g, n.id, .allocated_to, .requirement, .incoming, alloc);
        defer if (reqs.len > 0 and !std.mem.eql(u8, reqs, DASH)) alloc.free(reqs);
        try writer.print("| {s} | {s} | {s} | {s} |\n", .{
            n.id,
            n.get("description") orelse n.get("statement") orelse "",
            n.get("type") orelse "",
            reqs,
        });
    }
}

fn renderDesignOutputsSection(g: *const Graph, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Design Outputs\n\n");
    try writer.writeAll("| ID | Description | Type | Design Input | Version | Source File |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- |\n");

    var nodes: std.ArrayList(*const graph.Node) = .empty;
    defer nodes.deinit(alloc);
    try g.nodesByType(.design_output, alloc, &nodes);
    std.mem.sort(*const graph.Node, nodes.items, {}, nodeIdLt);

    for (nodes.items) |n| {
        const dis = try linkedNodeIds(g, n.id, .satisfied_by, .design_input, .incoming, alloc);
        defer if (dis.len > 0 and !std.mem.eql(u8, dis, DASH)) alloc.free(dis);
        const src = try linkedNodeIds(g, n.id, .implemented_in, .source_file, .outgoing, alloc);
        defer if (src.len > 0 and !std.mem.eql(u8, src, DASH)) alloc.free(src);
        try writer.print("| {s} | {s} | {s} | {s} | {s} | {s} |\n", .{
            n.id,
            n.get("description") orelse n.get("statement") orelse "",
            n.get("type") orelse "",
            dis,
            n.get("version") orelse "",
            src,
        });
    }
}

fn renderRequirementsTraceabilityWithProfile(g: *const Graph, ctx: report_mod.ReportContext, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Requirements Traceability\n\n");
    try writer.writeAll("| Req ID | User Need | Design Input | Design Output | Statement | Test Group | Test ID | Status | Source File |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");

    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(alloc);
    try g.rtm(alloc, &rows);
    std.mem.sort(RtmRow, rows.items, {}, rtmRowLt);

    for (rows.items) |row| {
        const req_node = g.getNode(row.req_id);
        const dis = if (req_node != null) try linkedNodeIds(g, row.req_id, .allocated_to, .design_input, .outgoing, alloc) else DASH;
        defer if (dis.len > 0 and !std.mem.eql(u8, dis, DASH)) alloc.free(dis);
        const dos = if (req_node != null) try collectRequirementDesignOutputs(g, row.req_id, alloc) else DASH;
        defer if (dos.len > 0 and !std.mem.eql(u8, dos, DASH)) alloc.free(dos);
        const req_prefix: []const u8 = if (report_mod.traceGapForNode(ctx.merged_gaps, row.req_id)) "**⚠** " else "";
        try writer.print("| {s}{s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} | {s} |\n", .{
            req_prefix,
            row.req_id,
            row.user_need_id orelse DASH,
            dis,
            dos,
            row.statement,
            row.test_group_id orelse DASH,
            row.test_id orelse DASH,
            row.status,
            row.source_file orelse DASH,
        });
    }
}

fn renderTestsSection(g: *const Graph, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Tests\n\n");
    try writer.writeAll("| Test Group | Test ID | Type | Method | Linked Reqs |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- |\n");

    const TestRow = struct {
        tg_id: []const u8,
        test_id: []const u8,
        test_type: []const u8,
        test_method: []const u8,
        req_ids: []const u8,
    };

    var tg_nodes: std.ArrayList(*const graph.Node) = .empty;
    defer tg_nodes.deinit(alloc);
    try g.nodesByType(.test_group, alloc, &tg_nodes);
    var test_rows: std.ArrayList(TestRow) = .empty;
    defer test_rows.deinit(alloc);

    for (tg_nodes.items) |tg| {
        const reqs = try linkedNodeIds(g, tg.id, .tested_by, .requirement, .incoming, alloc);
        defer if (reqs.len > 0 and !std.mem.eql(u8, reqs, DASH)) alloc.free(reqs);
        var edges_out: std.ArrayList(graph.Edge) = .empty;
        defer edges_out.deinit(alloc);
        try g.edgesFrom(tg.id, alloc, &edges_out);
        for (edges_out.items) |e| {
            if (e.label != .has_test) continue;
            const t = g.getNode(e.to_id);
            try test_rows.append(alloc, .{
                .tg_id = tg.id,
                .test_id = e.to_id,
                .test_type = if (t) |n| n.get("test_type") orelse "" else "",
                .test_method = if (t) |n| n.get("test_method") orelse "" else "",
                .req_ids = try alloc.dupe(u8, reqs),
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

    for (test_rows.items) |row| {
        try writer.print("| {s} | {s} | {s} | {s} | {s} |\n", .{
            row.tg_id, row.test_id, row.test_type, row.test_method, row.req_ids,
        });
    }
}

fn renderRiskSection(g: *const Graph, ctx: report_mod.ReportContext, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Risk Register\n\n");
    try writer.writeAll("| Risk ID | Description | Init. Sev | Init. Like | Init. Score | Mitigation | Linked Req | Res. Sev | Res. Like | Res. Score |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n");

    var risk_rows: std.ArrayList(RiskRow) = .empty;
    defer risk_rows.deinit(alloc);
    try g.risks(alloc, &risk_rows);
    std.mem.sort(RiskRow, risk_rows.items, {}, struct {
        fn lt(_: void, a: RiskRow, b: RiskRow) bool {
            return std.mem.order(u8, a.risk_id, b.risk_id) == .lt;
        }
    }.lt);

    for (risk_rows.items) |row| {
        const has_gap = report_mod.traceGapForNode(ctx.merged_gaps, row.risk_id);
        const req_prefix: []const u8 = if (has_gap) "**⚠** " else "";
        const req_str = row.req_id orelse DASH;
        var init_score_buf: [32]u8 = undefined;
        var res_score_buf: [32]u8 = undefined;
        try writer.print("| {s} | {s} | {s} | {s} | {s} | {s} | {s}{s} | {s} | {s} | {s} |\n", .{
            row.risk_id,
            row.description,
            row.initial_severity orelse DASH,
            row.initial_likelihood orelse DASH,
            scoreStr(&init_score_buf, row.initial_severity, row.initial_likelihood),
            row.mitigation orelse DASH,
            req_prefix,
            req_str,
            row.residual_severity orelse DASH,
            row.residual_likelihood orelse DASH,
            scoreStr(&res_score_buf, row.residual_severity, row.residual_likelihood),
        });
    }
}

fn renderConfigItemsSection(g: *const Graph, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Configuration Items\n\n");
    try writer.writeAll("| ID | Description | Type | Version | Design Output |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- |\n");

    var nodes: std.ArrayList(*const graph.Node) = .empty;
    defer nodes.deinit(alloc);
    try g.nodesByType(.config_item, alloc, &nodes);
    std.mem.sort(*const graph.Node, nodes.items, {}, nodeIdLt);

    for (nodes.items) |n| {
        const dos = try linkedNodeIds(g, n.id, .controlled_by, .design_output, .incoming, alloc);
        defer if (dos.len > 0 and !std.mem.eql(u8, dos, DASH)) alloc.free(dos);
        try writer.print("| {s} | {s} | {s} | {s} | {s} |\n", .{
            n.id,
            n.get("description") orelse n.get("statement") orelse "",
            n.get("type") orelse "",
            n.get("version") orelse "",
            dos,
        });
    }
}

fn renderTraceGapSummary(writer: anytype, gaps: []const report_mod.TraceGap) !void {
    try writer.print("\n## Gap Summary\n\n**{d} gap(s) found.**\n", .{report_mod.hardGapCount(gaps)});
    if (gaps.len == 0) {
        try writer.writeAll("\nNo gaps detected.\n");
        return;
    }

    for (gaps) |gap| {
        if (gap.clause) |clause| {
            try writer.print("- `{s}` {s} ({s}) — {s}\n", .{
                gap.primary_id,
                gap.kind,
                clause,
                gap.message,
            });
        } else {
            try writer.print("- `{s}` {s} — {s}\n", .{
                gap.primary_id,
                gap.kind,
                gap.message,
            });
        }
    }
}

fn renderProfileComplianceSummary(g: *const Graph, ctx: report_mod.ReportContext, writer: anytype, alloc: std.mem.Allocator) !void {
    try writer.writeAll("\n## Profile Compliance Summary\n\n");
    const di_count = try countNodesByType(g, .design_input, alloc);
    const do_count = try countNodesByType(g, .design_output, alloc);
    const ci_count = try countNodesByType(g, .config_item, alloc);
    const req_count = try countNodesByType(g, .requirement, alloc);
    try writer.print("- Profile: {s}\n", .{ctx.profile_name});
    try writer.print("- Standards: {s}\n", .{ctx.profile_standards});
    try writer.print("- Requirements: {d}\n", .{req_count});
    try writer.print("- Design Inputs: {d}\n", .{di_count});
    try writer.print("- Design Outputs: {d}\n", .{do_count});
    try writer.print("- Configuration Items: {d}\n", .{ci_count});
    try writer.print("- Generic findings: {d}\n", .{ctx.generic_gaps.len});
    try writer.print("- Profile findings: {d}\n", .{ctx.profile_gaps.len});
    try writer.print("- Hard gaps: {d}\n", .{report_mod.hardGapCount(ctx.merged_gaps)});
}

const LinkDirection = enum { outgoing, incoming };

fn linkedNodeIds(
    g: *const Graph,
    node_id: []const u8,
    label: graph.EdgeLabel,
    other_type: graph.NodeType,
    direction: LinkDirection,
    alloc: std.mem.Allocator,
) ![]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(alloc);
    for (g.edges.items) |e| {
        const match = switch (direction) {
            .outgoing => std.mem.eql(u8, e.from_id, node_id) and e.label == label,
            .incoming => std.mem.eql(u8, e.to_id, node_id) and e.label == label,
        };
        if (!match) continue;
        const other_id = switch (direction) {
            .outgoing => e.to_id,
            .incoming => e.from_id,
        };
        const other = g.getNode(other_id) orelse continue;
        if (other.node_type != other_type) continue;
        try ids.append(alloc, other.id);
    }
    if (ids.items.len == 0) return DASH;
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (ids.items, 0..) |id, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, id);
    }
    return out.toOwnedSlice(alloc);
}

fn collectRequirementDesignOutputs(g: *const Graph, req_id: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    var outputs: std.ArrayList([]const u8) = .empty;
    defer outputs.deinit(alloc);
    for (g.edges.items) |e| {
        if (e.label != .allocated_to or !std.mem.eql(u8, e.from_id, req_id)) continue;
        const di = g.getNode(e.to_id) orelse continue;
        if (di.node_type != .design_input) continue;
        for (g.edges.items) |sub| {
            if (sub.label != .satisfied_by or !std.mem.eql(u8, sub.from_id, di.id)) continue;
            const do_node = g.getNode(sub.to_id) orelse continue;
            if (do_node.node_type != .design_output) continue;
            try outputs.append(alloc, do_node.id);
        }
    }
    if (outputs.items.len == 0) return DASH;
    std.mem.sort([]const u8, outputs.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    for (outputs.items, 0..) |id, i| {
        if (i > 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, id);
    }
    return out.toOwnedSlice(alloc);
}

fn countNodesByType(g: *const Graph, node_type: graph.NodeType, alloc: std.mem.Allocator) !usize {
    var nodes: std.ArrayList(*const graph.Node) = .empty;
    defer nodes.deinit(alloc);
    try g.nodesByType(node_type, alloc, &nodes);
    return nodes.items.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const xlsx = @import("xlsx.zig");
const schema = @import("schema.zig");
const diagnostic = @import("diagnostic.zig");

test "render_md golden file" {
    var tmp_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tmp_arena.deinit();
    const tmp = tmp_arena.allocator();

    const sheets = try xlsx.parse(tmp, "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");

    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try schema.ingest(&g, sheets);

    // Render to buffer
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderMd(&g, "RTMify_Requirements_Tracking_Template.xlsx", "2024-01-01T00:00:00Z",
        buf.writer(testing.allocator));

    // Load golden file
    const golden = try std.fs.cwd().readFileAlloc(
        testing.allocator,
        "test/fixtures/golden_rtm.md",
        1024 * 1024,
    );
    defer testing.allocator.free(golden);

    try testing.expectEqualStrings(golden, buf.items);
}

test "render_md no gaps" {
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
    try renderMd(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    // No gaps — no warning markers, gap summary shows 0, no sub-sections
    try testing.expect(std.mem.indexOf(u8, buf.items, "**⚠**") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "**0 gap(s) found.**") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "### Hard Gaps") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "### Advisory Gaps") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "No gaps detected.") != null);
}

test "render_md score calculation" {
    var init_buf: [32]u8 = undefined;
    var res_buf: [32]u8 = undefined;
    try testing.expectEqualStrings("12", scoreStr(&init_buf, "4", "3"));
    try testing.expectEqualStrings("4", scoreStr(&res_buf, "4", "1"));

    var dash_buf: [32]u8 = undefined;
    try testing.expectEqualStrings(DASH, scoreStr(&dash_buf, null, "3"));
    try testing.expectEqualStrings(DASH, scoreStr(&dash_buf, "4", null));
    try testing.expectEqualStrings(DASH, scoreStr(&dash_buf, "x", "3"));
}

test "render_md includes multiple test groups and plural linked requirements" {
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
    try renderMd(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    try testing.expect(std.mem.indexOf(u8, buf.items, "| REQ-001 |") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "| TG-001 | T-001 |") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "| TG-002 | T-002 |") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "REQ-001, REQ-002") != null);
}

test "render_md gap summary includes hard and advisory categories" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("UN-001", .user_need, &.{});
    try g.addNode("UN-002", .user_need, &.{});
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "declared_test_group_ref_count", .value = "0" },
    });
    try g.addNode("REQ-002", .requirement, &.{
        .{ .key = "declared_test_group_ref_count", .value = "1" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "declared_mitigation_req_ref_count", .value = "0" },
    });

    try g.addEdge("REQ-002", "UN-001", .derives_from);
    try g.addEdge("REQ-002", "TG-001", .tested_by);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderMd(&g, "test.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    try testing.expect(std.mem.indexOf(u8, buf.items, "### Hard Gaps") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "#### Requirements with No User Need (1)") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "#### Requirements with No Test Group Link (1)") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "#### Risks with No Mitigation Requirement (1)") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "### Advisory Gaps") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "#### User Needs with No Requirements (1)") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "- UN-002") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "#### Requirements Linked to Empty Test Groups (1)") != null);
}

test "render_md_with_context includes profile sections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sheets = try xlsx.parse(alloc, "test/fixtures/RTMify_Profile_Tabs_Golden.xlsx");
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    var d = diagnostic.Diagnostics.init(testing.allocator);
    defer d.deinit();
    _ = try schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_inputs_tab = true,
        .enable_design_outputs_tab = true,
        .enable_config_items_tab = true,
    });

    const ctx = try report_mod.buildReportContext(&g, .medical, alloc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try renderMdWithContext(&g, ctx, "profile.xlsx", "2024-01-01T00:00:00Z", buf.writer(testing.allocator));

    try testing.expect(std.mem.indexOf(u8, buf.items, "## Design Inputs") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## Design Outputs") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## Configuration Items") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "## Profile Compliance Summary") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Profile: medical") != null);
}
