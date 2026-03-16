const s = @import("support.zig");

test "semanticValidate warns on missing shall" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system will work correctly" },
    });

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    try s.testing.expect(d.warning_count >= 1);
}

test "semanticValidate warns on vague terms" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system shall provide adequate performance" },
    });

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (s.std.mem.indexOf(u8, e.message, "adequate") != null) found = true;
    }
    try s.testing.expect(found);
}

test "semanticValidate warns on high risk without mitigation" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "initial_severity", .value = "4" },
        .{ .key = "initial_likelihood", .value = "4" },
        .{ .key = "mitigation", .value = "" },
    });

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (s.std.mem.indexOf(u8, e.message, "score") != null) found = true;
    }
    try s.testing.expect(found);
}

test "semanticValidate warns on compound shall" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system shall work and shall also report errors" },
    });

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "compound") != null) found = true;
    }
    try s.testing.expect(found);
}

test "semanticValidate warns on obsolete with traces" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system shall work" },
        .{ .key = "status", .value = "obsolete" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "obsolete") != null) found = true;
    }
    try s.testing.expect(found);
}

test "semanticValidate warns when residual exceeds initial" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "initial_severity", .value = "2" },
        .{ .key = "initial_likelihood", .value = "2" },
        .{ .key = "residual_severity", .value = "3" },
        .{ .key = "residual_likelihood", .value = "3" },
        .{ .key = "mitigation", .value = "Some action" },
    });

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "residual score") != null) found = true;
    }
    try s.testing.expect(found);
}

test "semanticValidate warns when residual present but initial absent" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "residual_severity", .value = "2" },
        .{ .key = "residual_likelihood", .value = "2" },
    });

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "initial scores absent") != null) found = true;
    }
    try s.testing.expect(found);
}

test "semanticValidate warns on test group with no tests" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("TG-001", .test_group, &.{});

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "no test cases") != null) found = true;
    }
    try s.testing.expect(found);
}

test "semanticValidate no warning for test group with tests" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("T-001", .test_case, &.{});
    try g.addEdge("TG-001", "T-001", .has_test);

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.semantic.semanticValidate(&g, &d);
    for (d.entries.items) |e| {
        if (s.std.mem.indexOf(u8, e.message, "no test cases") != null) {
            try s.testing.expect(false);
        }
    }
}
