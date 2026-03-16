const s = @import("support.zig");

test "resolveTab exact match" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const sheets = &[_]s.SheetData{
        .{ .name = "Requirements", .rows = &.{} },
        .{ .name = "Risks", .rows = &.{} },
    };
    const found = s.tabs.resolveTab(sheets, "Requirements", &d);
    try s.testing.expect(found != null);
    try s.testing.expectEqualStrings("Requirements", found.?.name);
}

test "resolveTab case-insensitive" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const sheets = &[_]s.SheetData{
        .{ .name = "REQUIREMENTS", .rows = &.{} },
    };
    const found = s.tabs.resolveTab(sheets, "Requirements", &d);
    try s.testing.expect(found != null);
}

test "resolveTab synonym match" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const sheets = &[_]s.SheetData{
        .{ .name = "Reqs", .rows = &.{} },
    };
    const found = s.tabs.resolveTab(sheets, "Requirements", &d);
    try s.testing.expect(found != null);
    try s.testing.expectEqualStrings("Reqs", found.?.name);
}

test "resolveTab fuzzy match" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const sheets = &[_]s.SheetData{
        .{ .name = "Risk", .rows = &.{} },
    };
    const found = s.tabs.resolveTab(sheets, "Risks", &d);
    try s.testing.expect(found != null);
}

test "resolveTab returns null for no match" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const sheets = &[_]s.SheetData{
        .{ .name = "Sheet1", .rows = &.{} },
    };
    const found = s.tabs.resolveTab(sheets, "Requirements", &d);
    try s.testing.expect(found == null);
}

test "levenshtein distances" {
    try s.testing.expectEqual(@as(usize, 0), s.tabs.levenshtein("abc", "abc"));
    try s.testing.expectEqual(@as(usize, 1), s.tabs.levenshtein("Risks", "Risk"));
    try s.testing.expectEqual(@as(usize, 1), s.tabs.levenshtein("Reqts", "Reqs"));
    try s.testing.expectEqual(@as(usize, 3), s.tabs.levenshtein("abc", "xyz"));
}

test "resolveTab emits INFO for missing optional tabs" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Requirements", .rows = &.{
            &.{ "ID", "Statement" },
            &.{ "REQ-001", "The system shall work" },
        } },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    _ = try s.schema.ingestValidated(&g, sheets, &d);

    var un_info = false;
    var tst_info = false;
    var risk_info = false;
    for (d.entries.items) |e| {
        if (e.level == .info) {
            if (s.std.mem.indexOf(u8, e.message, "User Needs") != null) un_info = true;
            if (s.std.mem.indexOf(u8, e.message, "Tests") != null) tst_info = true;
            if (s.std.mem.indexOf(u8, e.message, "Risks") != null) risk_info = true;
        }
    }
    try s.testing.expect(un_info);
    try s.testing.expect(tst_info);
    try s.testing.expect(risk_info);
}

test "resolveTab full tab list in RequirementsTabNotFound error" {
    const sheets: []const s.SheetData = &.{
        .{ .name = "Sheet1", .rows = &.{} },
        .{ .name = "Sheet2", .rows = &.{} },
    };

    var g = s.Graph.init(s.testing.allocator);
    defer g.deinit();

    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();

    const result = s.schema.ingestValidated(&g, sheets, &d);
    try s.testing.expectError(s.diagnostic.ValidationError.RequirementsTabNotFound, result);

    var found_tabs = false;
    for (d.entries.items) |e| {
        if (e.level == .err and s.std.mem.indexOf(u8, e.message, "Sheet1") != null) found_tabs = true;
    }
    try s.testing.expect(found_tabs);
}
