const std = @import("std");
const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const render_md = rtmify.render_md;
const render_docx = rtmify.render_docx;
const render_pdf = rtmify.render_pdf;

const graph_live = @import("../graph_live.zig");
const adapter = @import("../adapter.zig");
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

const testing = std.testing;

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
    try testing.expect(std.mem.indexOf(u8, resp, "Design Inputs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Timing spec") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Requirements Without User Needs") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "REQ-999") != null);
}
