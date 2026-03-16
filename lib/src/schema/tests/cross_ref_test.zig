const s = @import("support.zig");

test "checkCrossRef unresolved ref emits warning with available IDs" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("UN-001", .user_need, &.{});

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.cross_ref.checkCrossRef(&g, "UN-999", .user_need, &d, "Requirements", 3);

    try s.testing.expect(d.warning_count >= 1);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and
            s.std.mem.indexOf(u8, e.message, "UN-999") != null and
            s.std.mem.indexOf(u8, e.message, "UN-001") != null) found = true;
    }
    try s.testing.expect(found);
}

test "checkCrossRef wrong type emits warning" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.cross_ref.checkCrossRef(&g, "REQ-001", .user_need, &d, "Requirements", 2);

    try s.testing.expect(d.warning_count >= 1);
    var found = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "Requirement") != null and
            s.std.mem.indexOf(u8, e.message, "UserNeed") != null) found = true;
    }
    try s.testing.expect(found);
}

test "checkCrossRef no warning for correct type" {
    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();
    try g.addNode("UN-001", .user_need, &.{});

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    try s.cross_ref.checkCrossRef(&g, "UN-001", .user_need, &d, "Requirements", 2);
    try s.testing.expectEqual(@as(u32, 0), d.warning_count);
}
