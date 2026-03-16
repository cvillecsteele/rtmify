const s = @import("support.zig");

test "ingest fixture into graph" {
    var tmp_arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer tmp_arena.deinit();
    const sheets = try s.xlsx.parse(tmp_arena.allocator(), "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();

    try s.schema.ingest(&g, sheets);

    const node = g.getNode("UN-001");
    try s.testing.expect(node != null);
    try s.testing.expectEqual(s.graph.NodeType.user_need, node.?.node_type);
    try s.testing.expectEqualStrings("This better work", node.?.get("statement").?);

    const req1 = g.getNode("REQ-001");
    try s.testing.expect(req1 != null);
    try s.testing.expectEqualStrings("The system SHALL work", req1.?.get("statement").?);

    const risk = g.getNode("RSK-101");
    try s.testing.expect(risk != null);
    try s.testing.expectEqualStrings("Clock drift at high temp", risk.?.get("description").?);
}

test "ingestValidated returns stats" {
    var tmp_arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer tmp_arena.deinit();
    const sheets = try s.xlsx.parse(tmp_arena.allocator(), "test/fixtures/RTMify_Requirements_Tracking_Template.xlsx");

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_inputs_tab = true,
    });
    try s.testing.expect(stats.requirement_count >= 2);
    try s.testing.expect(stats.user_need_count >= 1);
    try s.testing.expect(stats.risk_count >= 1);
}

test "ingest persists declared reference counts for requirements and risks" {
    const sheets = [_]s.SheetData{
        .{ .name = "User Needs", .rows = &.{ &.{ "ID", "Statement", "Source", "Priority" }, &.{ "UN-001", "Need", "Customer", "high" } } },
        .{ .name = "Tests", .rows = &.{ &.{ "Test Group ID", "Test ID", "Test Type", "Test Method" }, &.{ "TG-001", "T-001", "Verification", "Test" } } },
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement", "User Need ID", "Test Group IDs" }, &.{ "REQ-001", "One", "UN-001", "" }, &.{ "REQ-002", "Two", "UN-001", "TG-001, TG-404" } } },
        .{ .name = "Risks", .rows = &.{ &.{ "Risk ID", "Description", "Linked REQ" }, &.{ "RSK-001", "No mitigation", "" }, &.{ "RSK-002", "Broken mitigation", "REQ-404" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try s.schema.ingest(&g, &sheets);

    try s.testing.expectEqualStrings("0", g.getNode("REQ-001").?.get("declared_test_group_ref_count").?);
    try s.testing.expectEqualStrings("2", g.getNode("REQ-002").?.get("declared_test_group_ref_count").?);
    try s.testing.expectEqualStrings("0", g.getNode("RSK-001").?.get("declared_mitigation_req_ref_count").?);
    try s.testing.expectEqualStrings("1", g.getNode("RSK-002").?.get("declared_mitigation_req_ref_count").?);
}

test "multi-ID DERIVES_FROM creates multiple edges" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "User Needs", .rows = &.{ &.{ "ID", "Statement" }, &.{ "UN-001", "Need one" }, &.{ "UN-002", "Need two" } } },
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement", "User Need iD" }, &.{ "REQ-001", "The system shall work", "UN-001, UN-002" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    _ = try s.schema.ingestValidated(&g, sheets, &d);

    var edges: s.std.ArrayList(s.graph.Edge) = .empty;
    defer edges.deinit(s.testing.allocator);
    try g.edgesFrom("REQ-001", s.testing.allocator, &edges);

    var derives_count: usize = 0;
    for (edges.items) |e| {
        if (e.label == .derives_from) derives_count += 1;
    }
    try s.testing.expectEqual(@as(usize, 2), derives_count);
    try s.testing.expectEqual(@as(u32, 0), d.warning_count);
}

test "invalid requirement ID row is skipped during ingest" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement" }, &.{ "foo/bar/baz?blow=up", "The system shall work" }, &.{ "REQ-002", "The system shall also work" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_inputs_tab = true,
        .enable_design_outputs_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 1), stats.requirement_count);
    try s.testing.expect(g.getNode("REQ-002") != null);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.id_invalid));
}

test "requirement row with qualification-style ID ingests successfully" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement" }, &.{ "REQ-OQ-001", "The system shall work" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_outputs_tab = true,
        .enable_config_items_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 1), stats.requirement_count);
    try s.testing.expect(g.getNode("REQ-OQ-001") != null);
}

test "requirement row with exact-case complex ID is preserved" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement" }, &.{ "Foo-1AF5-Bar-Q5", "The system shall work" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_design_inputs_tab = true });
    try s.testing.expectEqual(@as(u32, 1), stats.requirement_count);
    try s.testing.expect(g.getNode("Foo-1AF5-Bar-Q5") != null);
    try s.testing.expect(g.getNode("FOO-1AF5-BAR-Q5") == null);
}

test "invalid reference token is skipped during ingest" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "User Needs", .rows = &.{ &.{ "ID", "Statement" }, &.{ "UN-001", "Need one" } } },
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement", "User Need ID" }, &.{ "REQ-001", "The system shall work", "foo?bar" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    _ = try s.schema.ingestValidated(&g, sheets, &d);
    var edges: s.std.ArrayList(s.graph.Edge) = .empty;
    defer edges.deinit(s.testing.allocator);
    try g.edgesFrom("REQ-001", s.testing.allocator, &edges);
    try s.testing.expectEqual(@as(usize, 0), edges.items.len);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.id_invalid));
}

test "requirement references complex user need ID exactly" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "User Needs", .rows = &.{ &.{ "ID", "Statement" }, &.{ "UN-OQ-005", "Need one" } } },
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement", "User Need ID" }, &.{ "REQ-OQ-001", "The system shall work", "UN-OQ-005" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    _ = try s.schema.ingestValidated(&g, sheets, &d);
    var edges: s.std.ArrayList(s.graph.Edge) = .empty;
    defer edges.deinit(s.testing.allocator);
    try g.edgesFrom("REQ-OQ-001", s.testing.allocator, &edges);
    var found = false;
    for (edges.items) |e| {
        if (e.label == .derives_from and s.std.mem.eql(u8, e.to_id, "UN-OQ-005")) found = true;
    }
    try s.testing.expect(found);
}

test "risk references complex mitigation requirement exactly" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement" }, &.{ "Foo-1AF5-Bar-Q5", "The system shall work" } } },
        .{ .name = "Risks", .rows = &.{ &.{ "Risk ID", "Description", "Linked REQ" }, &.{ "RSK-PQ-012", "Thing goes wrong", "Foo-1AF5-Bar-Q5" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    _ = try s.schema.ingestValidated(&g, sheets, &d);
    var edges: s.std.ArrayList(s.graph.Edge) = .empty;
    defer edges.deinit(s.testing.allocator);
    try g.edgesFrom("RSK-PQ-012", s.testing.allocator, &edges);
    var found = false;
    for (edges.items) |e| {
        if (e.label == .mitigated_by and s.std.mem.eql(u8, e.to_id, "Foo-1AF5-Bar-Q5")) found = true;
    }
    try s.testing.expect(found);
}

test "duplicate ID detection in ingestValidated" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "The system shall work" }, &.{ "REQ-001", "Duplicate entry" }, &.{ "REQ-002", "The system shall also work" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_inputs_tab = true,
        .enable_design_outputs_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 2), stats.requirement_count);
    var found_dup_warn = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "duplicate") != null) found_dup_warn = true;
    }
    try s.testing.expect(found_dup_warn);
}

test "isSectionDivider skipped silently in ingest" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement" }, &.{ "", "GENERAL REQUIREMENTS" }, &.{ "REQ-001", "The system shall work" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_outputs_tab = true,
        .enable_config_items_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 1), stats.requirement_count);
}

test "isBlankEquivalent prevents dangling edges" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement", "User Need iD", "Test Group ID" }, &.{ "REQ-001", "The system shall work", "N/A", "TBD" } } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    _ = try s.schema.ingestValidated(&g, sheets, &d);
    var edges: s.std.ArrayList(s.graph.Edge) = .empty;
    defer edges.deinit(s.testing.allocator);
    try g.edgesFrom("REQ-001", s.testing.allocator, &edges);
    try s.testing.expectEqual(@as(usize, 0), edges.items.len);
}

test "existing 4-tab behavior unchanged with DI/DO/CI tabs present" {
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "GPS SHALL detect loss" }, &.{ "REQ-002", "System SHALL restart" } };
    const un_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "UN-001", "User needs GPS" } };
    const di_rows: []const []const []const u8 = &.{ &.{ "ID", "Description" }, &.{ "DI-001", "GPS spec" } };
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = req_rows },
        .{ .name = "User Needs", .rows = un_rows },
        .{ .name = "Design Inputs", .rows = di_rows },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidated(&g, sheets, &d);
    try s.testing.expectEqual(@as(u32, 2), stats.requirement_count);
    try s.testing.expectEqual(@as(u32, 1), stats.user_need_count);
    try s.testing.expectEqual(@as(u32, 0), stats.design_input_count);
}

test "ingest golden profile tabs fixture builds full design chain" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    const sheets = try s.xlsx.parse(arena.allocator(), "test/fixtures/RTMify_Profile_Tabs_Golden.xlsx");

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_inputs_tab = true,
        .enable_design_outputs_tab = true,
        .enable_config_items_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 3), stats.design_input_count);
    try s.testing.expectEqual(@as(u32, 3), stats.design_output_count);
    try s.testing.expectEqual(@as(u32, 3), stats.config_item_count);
    try s.testing.expectEqual(@as(u32, 0), d.error_count);
}

test "ingest extended error fixture emits expected diagnostics" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    const sheets = try s.xlsx.parse(arena.allocator(), "test/fixtures/RTMify_Profile_Tabs_Errors.xlsx");

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    _ = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_inputs_tab = true,
        .enable_design_outputs_tab = true,
        .enable_config_items_tab = true,
    });

    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.ref_not_found));
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.duplicate_id));
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.row_no_id));
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.duplicate_test_id));
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.req_no_shall));
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.risk_unmitigated));
}
