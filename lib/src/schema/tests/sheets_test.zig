const s = @import("support.zig");

test "requirements accepts plural Test Group IDs header" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement", "Test Group IDs" }, &.{ "REQ-001", "The system shall work", "TG-001, TG-002" } } },
        .{ .name = "Tests", .rows = &.{ &.{ "Test Group ID", "Test ID" }, &.{ "TG-001", "T-001" }, &.{ "TG-002", "T-002" } } },
    };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    _ = try s.schema.ingestValidated(&g, sheets, &d);

    var edges: s.std.ArrayList(s.graph.Edge) = .empty;
    defer edges.deinit(s.testing.allocator);
    try g.edgesFrom("REQ-001", s.testing.allocator, &edges);
    var tested_by_count: usize = 0;
    for (edges.items) |e| {
        if (e.label == .tested_by) tested_by_count += 1;
    }
    try s.testing.expectEqual(@as(usize, 2), tested_by_count);
}

test "requirements keeps legacy Test Group ID header compatibility" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{ &.{ "ID", "Statement", "Test Group ID" }, &.{ "REQ-001", "The system shall work", "TG-001, TG-002" } } },
        .{ .name = "Tests", .rows = &.{ &.{ "Test Group ID", "Test ID" }, &.{ "TG-001", "T-001" }, &.{ "TG-002", "T-002" } } },
    };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    _ = try s.schema.ingestValidated(&g, sheets, &d);
    var edges: s.std.ArrayList(s.graph.Edge) = .empty;
    defer edges.deinit(s.testing.allocator);
    try g.edgesFrom("REQ-001", s.testing.allocator, &edges);
    var tested_by_count: usize = 0;
    for (edges.items) |e| {
        if (e.label == .tested_by) tested_by_count += 1;
    }
    try s.testing.expectEqual(@as(usize, 2), tested_by_count);
}

test "ingestDesignInputs creates DesignInput node and ALLOCATED_TO edge" {
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement", "Lifecycle Status" }, &.{ "REQ-001", "The system SHALL detect GPS loss", "approved" } };
    const di_rows: []const []const []const u8 = &.{ &.{ "ID", "Description", "Source Requirement", "Status" }, &.{ "DI-001", "GPS loss timing specification", "REQ-001", "draft" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Design Inputs", .rows = di_rows } };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_design_inputs_tab = true });
    try s.testing.expectEqual(@as(u32, 1), stats.design_input_count);
    try s.testing.expect(g.getNode("DI-001") != null);
}

test "ingestDesignOutputs creates DesignOutput node and SATISFIED_BY edge" {
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "System SHALL detect GPS loss" } };
    const di_rows: []const []const []const u8 = &.{ &.{ "ID", "Description" }, &.{ "DI-001", "GPS timing spec" } };
    const do_rows: []const []const []const u8 = &.{ &.{ "ID", "Description", "Type", "Design Input ID", "Version", "Status" }, &.{ "DO-001", "GPS timeout module", "Software", "DI-001", "1.0", "released" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Design Inputs", .rows = di_rows }, .{ .name = "Design Outputs", .rows = do_rows } };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_inputs_tab = true,
        .enable_design_outputs_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 1), stats.design_output_count);
}

test "ingestConfigItems creates ConfigurationItem node and CONTROLLED_BY edge" {
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "System SHALL detect GPS loss" } };
    const do_rows: []const []const []const u8 = &.{ &.{ "ID", "Description" }, &.{ "DO-001", "GPS timeout module" } };
    const ci_rows: []const []const []const u8 = &.{ &.{ "ID", "Description", "Type", "Version", "Design Output ID", "Status" }, &.{ "CI-001", "gps_timeout.c", "Source File", "1.0", "DO-001", "controlled" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Design Outputs", .rows = do_rows }, .{ .name = "Configuration Items", .rows = ci_rows } };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_design_outputs_tab = true,
        .enable_config_items_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 1), stats.config_item_count);
}

test "product tab is ignored by default ingest options" {
    const product_rows: []const []const []const u8 = &.{ &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" }, &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Active", "" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "System SHALL work" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Product", .rows = product_rows } };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidated(&g, sheets, &d);
    try s.testing.expectEqual(@as(u32, 0), stats.product_count);
}

test "product tab ingests Product nodes when enabled" {
    const product_rows: []const []const []const u8 = &.{ &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" }, &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Active", "" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "System SHALL work" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Product", .rows = product_rows } };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_product_tab = true,
        .enable_design_inputs_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 1), stats.product_count);
}

test "product tab missing full_identifier emits warning and skips node" {
    const product_rows: []const []const []const u8 = &.{ &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" }, &.{ "ASM-1000", "Rev C", "", "Sensor Controller Unit", "Active", "" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "System SHALL work" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Product", .rows = product_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_product_tab = true });
    try s.testing.expectEqual(@as(u32, 0), stats.product_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.product_full_identifier_missing));
}

test "product tab duplicate full_identifier emits error and keeps first node" {
    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
        &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Sensor Controller Unit", "Active", "" },
        &.{ "ASM-1000", "Rev D", "ASM-1000 Rev C", "Sensor Controller Unit Rev D", "Development", "" },
    };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "System SHALL work" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Product", .rows = product_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{
        .enable_product_tab = true,
        .enable_config_items_tab = true,
    });
    try s.testing.expectEqual(@as(u32, 1), stats.product_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.product_duplicate_full_identifier));
}

test "product tab with header only emits no product declared info" {
    const product_rows: []const []const []const u8 = &.{ &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-001", "System SHALL work" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Product", .rows = product_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_product_tab = true });
    try s.testing.expectEqual(@as(u32, 0), stats.product_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.product_none_declared));
}

test "decomposition tab is ignored by default ingest options" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "REQ-HLR-001", "REQ-LLR-001" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" }, &.{ "REQ-LLR-001", "Low-level requirement SHALL implement mode transition logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidated(&g, sheets, &d);
    try s.testing.expectEqual(@as(u32, 0), stats.decomposition_count);
}

test "decomposition tab ingests REFINED_BY edges when enabled" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "REQ-HLR-001", "REQ-LLR-001" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" }, &.{ "REQ-LLR-001", "Low-level requirement SHALL implement mode transition logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_decomposition_tab = true });
    try s.testing.expectEqual(@as(u32, 1), stats.decomposition_count);
}

test "decomposition tab missing parent_id emits warning and skips edge" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "", "REQ-LLR-001" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" }, &.{ "REQ-LLR-001", "Low-level requirement SHALL implement mode transition logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_decomposition_tab = true });
    try s.testing.expectEqual(@as(u32, 0), stats.decomposition_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.decomposition_parent_missing));
}

test "decomposition tab missing child_id emits warning and skips edge" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "REQ-HLR-001", "" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" }, &.{ "REQ-LLR-001", "Low-level requirement SHALL implement mode transition logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_decomposition_tab = true });
    try s.testing.expectEqual(@as(u32, 0), stats.decomposition_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.decomposition_child_missing));
}

test "decomposition tab duplicate pair emits warning and keeps first edge" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "REQ-HLR-001", "REQ-LLR-001" }, &.{ "REQ-HLR-001", "REQ-LLR-001" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" }, &.{ "REQ-LLR-001", "Low-level requirement SHALL implement mode transition logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_decomposition_tab = true });
    try s.testing.expectEqual(@as(u32, 1), stats.decomposition_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.decomposition_duplicate));
}

test "decomposition tab unknown requirement emits warning and skips edge" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "REQ-HLR-999", "REQ-LLR-001" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" }, &.{ "REQ-LLR-001", "Low-level requirement SHALL implement mode transition logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_decomposition_tab = true });
    try s.testing.expectEqual(@as(u32, 0), stats.decomposition_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.decomposition_unknown_requirement));
}

test "decomposition tab self-reference emits warning and skips edge" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "REQ-HLR-001", "REQ-HLR-001" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_decomposition_tab = true });
    try s.testing.expectEqual(@as(u32, 0), stats.decomposition_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.decomposition_self_reference));
}

test "decomposition tab invalid structured ID uses existing invalid-id diagnostic" {
    const decomp_rows: []const []const []const u8 = &.{ &.{ "parent_id", "child_id" }, &.{ "not/an/id", "REQ-LLR-001" } };
    const req_rows: []const []const []const u8 = &.{ &.{ "ID", "Statement" }, &.{ "REQ-HLR-001", "High-level requirement SHALL govern mode logic" }, &.{ "REQ-LLR-001", "Low-level requirement SHALL implement mode transition logic" } };
    const sheets: []const s.SheetData = &.{ .{ .name = "Requirements", .rows = req_rows }, .{ .name = "Decomposition", .rows = decomp_rows } };
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const stats = try s.schema.ingestValidatedWithOptions(&g, sheets, &d, .{ .enable_decomposition_tab = true });
    try s.testing.expectEqual(@as(u32, 0), stats.decomposition_count);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.id_invalid));
}
