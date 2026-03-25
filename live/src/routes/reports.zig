const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const render_md = rtmify.render_md;
const render_docx = rtmify.render_docx;
const render_pdf = rtmify.render_pdf;

const graph_live = @import("../graph_live.zig");
const adapter = @import("../adapter.zig");
const bom = @import("../bom.zig");
const soup = @import("../soup.zig");
const json_util = @import("../json_util.zig");
const design_history_core = @import("../design_history.zig");
const design_history_md = @import("../design_history_md.zig");
const design_history_pdf = @import("../design_history_pdf.zig");
const dh_routes = @import("design_history.zig");

pub fn handleReportDhrMd(db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) ![]const u8 {
    var report = try design_history_core.buildDhrReport(db, profile_name, alloc);
    defer design_history_core.deinitDhrReport(&report, alloc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try design_history_md.renderReport(&report, buf.writer(alloc), alloc);
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportDhrPdf(db: *graph_live.GraphDb, profile_name: []const u8, alloc: Allocator) ![]const u8 {
    var report = try design_history_core.buildDhrReport(db, profile_name, alloc);
    defer design_history_core.deinitDhrReport(&report, alloc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try design_history_pdf.renderReport(&report, buf.writer(alloc), alloc);
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportRtmPdf(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_pdf.renderPdf(&g, "live.db", "live", buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportRtmMd(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_md.renderMd(&g, "live.db", "live", buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportRtmDocx(db: *graph_live.GraphDb, alloc: Allocator) ![]const u8 {
    var g = try adapter.buildGraphFromSqlite(db, alloc);
    defer g.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_docx.renderDocx(&g, "live.db", "live", buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportDesignBomMd(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    return buildDesignBomMarkdown(db, full_product_identifier, bom_name, include_obsolete, alloc);
}

pub fn handleReportDesignBomPdf(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const markdown = try buildDesignBomMarkdown(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(markdown);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_pdf.renderPdfFromMarkdown(markdown, buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportDesignBomDocx(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const markdown = try buildDesignBomMarkdown(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(markdown);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_docx.renderDocxFromMarkdown(markdown, buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportSoupMd(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    return soup.soupRegisterMarkdown(db, full_product_identifier, bom_name, include_obsolete, alloc);
}

pub fn handleReportSoupPdf(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const markdown = try soup.soupRegisterMarkdown(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(markdown);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_pdf.renderPdfFromMarkdown(markdown, buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

pub fn handleReportSoupDocx(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const markdown = try soup.soupRegisterMarkdown(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(markdown);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try render_docx.renderDocxFromMarkdown(markdown, buf.writer(alloc));
    return alloc.dupe(u8, buf.items);
}

fn buildDesignBomMarkdown(
    db: *graph_live.GraphDb,
    full_product_identifier: []const u8,
    bom_name: []const u8,
    include_obsolete: bool,
    alloc: Allocator,
) ![]const u8 {
    const tree_json = try bom.getDesignBomTreeJson(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(tree_json);
    const items_json = try bom.getDesignBomItemsJson(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(items_json);
    const coverage_json = try bom.getDesignBomCoverageJson(db, full_product_identifier, bom_name, include_obsolete, alloc);
    defer alloc.free(coverage_json);

    var tree_parsed = try std.json.parseFromSlice(std.json.Value, alloc, tree_json, .{});
    defer tree_parsed.deinit();
    var items_parsed = try std.json.parseFromSlice(std.json.Value, alloc, items_json, .{});
    defer items_parsed.deinit();
    var coverage_parsed = try std.json.parseFromSlice(std.json.Value, alloc, coverage_json, .{});
    defer coverage_parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# Design BOM Report\n\n- Product: `{s}`\n- BOM: `{s}`\n\n", .{ full_product_identifier, bom_name });

    if (json_util.getObjectField(coverage_parsed.value, "summary")) |summary| {
        try buf.appendSlice(alloc, "## Summary\n\n");
        try std.fmt.format(
            buf.writer(alloc),
            "- Items: {d}\n- Requirement-covered items: {d}\n- Test-covered items: {d}\n- Fully covered items: {d}\n- Items with no trace links: {d}\n- Unresolved trace refs: {d}\n\n",
            .{
                json_util.getInt(summary, "item_count") orelse 0,
                json_util.getInt(summary, "requirement_covered_count") orelse 0,
                json_util.getInt(summary, "test_covered_count") orelse 0,
                json_util.getInt(summary, "fully_covered_count") orelse 0,
                json_util.getInt(summary, "no_trace_count") orelse 0,
                json_util.getInt(summary, "warning_count") orelse 0,
            },
        );
    }

    try buf.appendSlice(alloc, "## Hierarchy\n\n");
    if (json_util.getObjectField(tree_parsed.value, "design_boms")) |design_boms| {
        if (design_boms == .array and design_boms.array.items.len > 0) {
            for (design_boms.array.items) |design_bom| {
                try std.fmt.format(
                    buf.writer(alloc),
                    "### {s} ({s})\n\n",
                    .{
                        json_util.getString(design_bom, "bom_type") orelse "unknown",
                        json_util.getString(design_bom, "source_format") orelse "unknown",
                    },
                );
                if (json_util.getObjectField(design_bom, "tree")) |tree| {
                    if (json_util.getObjectField(tree, "roots")) |roots| {
                        try appendBomTreeMarkdown(&buf, roots, 0, alloc);
                    }
                }
                try buf.append(alloc, '\n');
            }
        } else {
            try buf.appendSlice(alloc, "_No Design BOM tree available._\n\n");
        }
    } else {
        try buf.appendSlice(alloc, "_No Design BOM tree available._\n\n");
    }

    try buf.appendSlice(alloc, "## Item Traceability\n\n| Part | Rev | Requirements | Tests | Unresolved |\n|---|---|---|---|---|\n");
    if (json_util.getObjectField(items_parsed.value, "items")) |items| {
        if (items == .array and items.array.items.len > 0) {
            for (items.array.items) |item| {
                const node = json_util.getObjectField(item, "node") orelse continue;
                const props = json_util.getObjectField(node, "properties") orelse continue;
                const reqs = try markdownJoinStringArray(json_util.getObjectField(props, "requirement_ids"), alloc);
                defer alloc.free(reqs);
                const tests = try markdownJoinStringArray(json_util.getObjectField(props, "test_ids"), alloc);
                defer alloc.free(tests);
                const unresolved = try markdownJoinCombinedStringArrays(
                    json_util.getObjectField(item, "unresolved_requirement_ids"),
                    json_util.getObjectField(item, "unresolved_test_ids"),
                    alloc,
                );
                defer alloc.free(unresolved);
                try std.fmt.format(
                    buf.writer(alloc),
                    "| {s} | {s} | {s} | {s} | {s} |\n",
                    .{
                        json_util.getString(props, "part") orelse "—",
                        json_util.getString(props, "revision") orelse "—",
                        reqs,
                        tests,
                        unresolved,
                    },
                );
            }
        } else {
            try buf.appendSlice(alloc, "| — | — | — | — | — |\n");
        }
    }

    return alloc.dupe(u8, buf.items);
}

fn appendBomTreeMarkdown(buf: *std.ArrayList(u8), nodes: std.json.Value, depth: usize, alloc: Allocator) !void {
    if (nodes != .array) return;
    for (nodes.array.items) |node| {
        const props = json_util.getObjectField(node, "properties") orelse continue;
        const edge_props = json_util.getObjectField(node, "edge_properties");
        try buf.appendNTimes(alloc, ' ', depth * 2);
        try buf.appendSlice(alloc, "- ");
        try buf.appendSlice(alloc, json_util.getString(props, "part") orelse json_util.getString(node, "id") orelse "item");
        try std.fmt.format(buf.writer(alloc), " @ {s}", .{json_util.getString(props, "revision") orelse "-"});
        if (edge_props) |edge| {
            if (json_util.getString(edge, "quantity")) |qty| {
                try std.fmt.format(buf.writer(alloc), " (qty {s})", .{qty});
            }
        }
        try buf.append(alloc, '\n');
        if (json_util.getObjectField(node, "children")) |children| {
            try appendBomTreeMarkdown(buf, children, depth + 1, alloc);
        }
    }
}

fn markdownJoinStringArray(value: ?std.json.Value, alloc: Allocator) ![]const u8 {
    const field = value orelse return alloc.dupe(u8, "—");
    if (field != .array or field.array.items.len == 0) return alloc.dupe(u8, "—");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (field.array.items, 0..) |entry, idx| {
        if (entry != .string) continue;
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, entry.string);
    }
    if (buf.items.len == 0) return alloc.dupe(u8, "—");
    return alloc.dupe(u8, buf.items);
}

fn markdownJoinCombinedStringArrays(a: ?std.json.Value, b: ?std.json.Value, alloc: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try appendMarkdownStringArray(&buf, a, alloc);
    try appendMarkdownStringArray(&buf, b, alloc);
    if (buf.items.len == 0) return alloc.dupe(u8, "—");
    return alloc.dupe(u8, buf.items);
}

fn appendMarkdownStringArray(buf: *std.ArrayList(u8), value: ?std.json.Value, alloc: Allocator) !void {
    const field = value orelse return;
    if (field != .array) return;
    for (field.array.items) |entry| {
        if (entry != .string) continue;
        if (buf.items.len > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, entry.string);
    }
}

const testing = std.testing;

fn seedRtmReportFixture(db: *graph_live.GraphDb) !void {
    try db.addNode("artifact://rtm/demo", "Artifact", "{\"kind\":\"rtm_workbook\",\"display_name\":\"Demo RTM\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"status\":\"Approved\",\"text_status\":\"single_source\",\"authoritative_source\":\"artifact://rtm/demo\",\"source_count\":1}", null);
    try db.addNode("REQ-002", "Requirement", "{\"status\":\"Approved\",\"text_status\":\"single_source\",\"authoritative_source\":\"artifact://rtm/demo\",\"source_count\":1}", null);
    try db.addNode("artifact://rtm/demo:REQ-001", "RequirementText", "{\"artifact_id\":\"artifact://rtm/demo\",\"source_kind\":\"rtm_workbook\",\"req_id\":\"REQ-001\",\"section\":\"Requirements\",\"text\":\"Resolved requirement one\",\"normalized_text\":\"resolved requirement one\",\"hash\":\"abc\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try db.addNode("artifact://rtm/demo:REQ-002", "RequirementText", "{\"artifact_id\":\"artifact://rtm/demo\",\"source_kind\":\"rtm_workbook\",\"req_id\":\"REQ-002\",\"section\":\"Requirements\",\"text\":\"Resolved requirement two\",\"normalized_text\":\"resolved requirement two\",\"hash\":\"def\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try db.addNode("TG-001", "TestGroup", "{\"protocol\":\"ATP\"}", null);
    try db.addNode("TG-002", "TestGroup", "{\"protocol\":\"ATP\"}", null);
    try db.addNode("T-001", "Test", "{\"test_type\":\"Verification\",\"test_method\":\"Bench\"}", null);
    try db.addNode("T-002", "Test", "{\"test_type\":\"Verification\",\"test_method\":\"Bench\"}", null);

    try db.addEdge("artifact://rtm/demo", "artifact://rtm/demo:REQ-001", "CONTAINS");
    try db.addEdge("artifact://rtm/demo", "artifact://rtm/demo:REQ-002", "CONTAINS");
    try db.addEdge("artifact://rtm/demo:REQ-001", "REQ-001", "ASSERTS");
    try db.addEdge("artifact://rtm/demo:REQ-002", "REQ-002", "ASSERTS");
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addEdge("REQ-001", "TG-002", "TESTED_BY");
    try db.addEdge("REQ-002", "TG-001", "TESTED_BY");
    try db.addEdge("TG-001", "T-001", "HAS_TEST");
    try db.addEdge("TG-002", "T-002", "HAS_TEST");
}

test "handleReportDhrMd includes downstream design history artifacts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try dh_routes.seedDhrFixture(&db);

    const resp = try handleReportDhrMd(&db, "medical", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "# Design History Record") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Profile: medical") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "## UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "### Requirement REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Detect GPS loss") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Risks") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Clock drift") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Design Inputs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Timing spec") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Design Outputs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "GPS firmware") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Configuration Items") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Main ECU") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Source Files") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "src/gps.c") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Test Files") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "test/gps_test.c") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Annotations") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "src/gps.c:10") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Commits") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Implement GPS trace") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "#### Open Chain Gaps") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "design_output_without_config_control") != null);
}

test "handleReportDhrMd includes unlinked requirements appendix when needed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try dh_routes.seedDhrFixture(&db);

    const resp = try handleReportDhrMd(&db, "medical", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "## Requirements Without User Needs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "### Requirement REQ-999") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Standalone maintenance mode") != null);
}

test "handleReportDhrPdf includes downstream design history artifacts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try dh_routes.seedDhrFixture(&db);

    const resp = try handleReportDhrPdf(&db, "medical", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "Design History Record") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "UN-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Requirement REQ-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Detect GPS loss") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Design Inputs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Timing spec") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Requirements Without User Needs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-999") != null);
}

test "handleReportRtmMd resolves requirement statements from RTM assertions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedRtmReportFixture(&db);

    const resp = try handleReportRtmMd(&db, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "Resolved requirement one") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "TG-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "TG-002") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001, REQ-002") != null);
}

test "handleReportRtmPdf resolves requirement statements from RTM assertions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedRtmReportFixture(&db);

    const resp = try handleReportRtmPdf(&db, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "Resolved requirement one") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "TG-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "TG-002") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001, REQ-002") != null);
}

test "handleReportRtmDocx resolves requirement statements from RTM assertions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedRtmReportFixture(&db);

    const resp = try handleReportRtmDocx(&db, alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "Resolved requirement one") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "TG-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "TG-002") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-001, REQ-002") != null);
}
