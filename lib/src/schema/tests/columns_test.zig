const s = @import("support.zig");

test "resolveCol exact match" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const headers: s.Row = &.{ "ID", "Statement", "Priority" };
    const col = s.columns.resolveCol(headers, &.{}, "ID", s.columns.req_id_syns, "Reqs", &d, false);
    try s.testing.expectEqual(@as(?usize, 0), col);
}

test "resolveCol synonym match emits info" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const headers: s.Row = &.{ "Req ID", "Statement" };
    const col = s.columns.resolveCol(headers, &.{}, "ID", s.columns.req_id_syns, "Reqs", &d, false);
    try s.testing.expectEqual(@as(?usize, 0), col);
    var found_info = false;
    for (d.entries.items) |e| {
        if (e.level == .info and s.std.mem.indexOf(u8, e.message, "synonym") != null) found_info = true;
    }
    try s.testing.expect(found_info);
}

test "resolveCol leftmost wins on ambiguity" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const headers: s.Row = &.{ "Other", "ID", "Statement", "ID" };
    const col = s.columns.resolveCol(headers, &.{}, "ID", s.columns.req_id_syns, "Reqs", &d, false);
    try s.testing.expectEqual(@as(?usize, 1), col);
    try s.testing.expect(d.warning_count >= 1);
}

test "resolveCol heuristic ID detection" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const headers: s.Row = &.{ "Whatever", "Random Col" };
    const data_rows: []const s.Row = &.{
        &.{ "REQ-001", "foo" },
        &.{ "REQ-002", "bar" },
        &.{ "REQ-003", "baz" },
    };
    const col = s.columns.resolveCol(headers, data_rows, "ID", s.columns.req_id_syns, "Reqs", &d, true);
    try s.testing.expectEqual(@as(?usize, 0), col);
    var found_warn = false;
    for (d.entries.items) |e| {
        if (e.level == .warn and s.std.mem.indexOf(u8, e.message, "guessing") != null) found_warn = true;
    }
    try s.testing.expect(found_warn);
}

test "structured ID validator accepts multi-segment mixed-case IDs" {
    try s.testing.expect(s.structured_id.isStructuredId("REQ-001"));
    try s.testing.expect(s.structured_id.isStructuredId("REQ-OQ-001"));
    try s.testing.expect(s.structured_id.isStructuredId("Foo-1AF5-Bar-Q5"));
    try s.testing.expect(s.structured_id.isStructuredId("ABC_DEF-01_A"));
    try s.testing.expect(!s.structured_id.isStructuredId("hello"));
    try s.testing.expect(!s.structured_id.isStructuredId("REQ001"));
    try s.testing.expect(!s.structured_id.isStructuredId("REQ/001"));
    try s.testing.expect(!s.structured_id.isStructuredId(""));
}

test "resolveCol heuristic detects complex structured IDs" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const headers: s.Row = &.{ "Whatever", "Random Col" };
    const data_rows: []const s.Row = &.{
        &.{ "REQ-OQ-001", "foo" },
        &.{ "Foo-1AF5-Bar-Q5", "bar" },
        &.{ "ABC_DEF-01_A", "baz" },
    };
    const col = s.columns.resolveCol(headers, data_rows, "ID", s.columns.req_id_syns, "Reqs", &d, true);
    try s.testing.expectEqual(@as(?usize, 0), col);
}
