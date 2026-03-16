const s = @import("support.zig");

test "splitIds comma and semicolon" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    const parts = try s.normalize.splitIds("UN-001, UN-002; UN-003", arena.allocator());
    try s.testing.expectEqual(@as(usize, 3), parts.len);
    try s.testing.expectEqualStrings("UN-001", parts[0]);
    try s.testing.expectEqualStrings("UN-002", parts[1]);
    try s.testing.expectEqualStrings("UN-003", parts[2]);
}

test "splitIds slash and newline" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    const parts = try s.normalize.splitIds("TG-001/TG-002\nTG-003", arena.allocator());
    try s.testing.expectEqual(@as(usize, 3), parts.len);
}

test "splitIds single token" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    const parts = try s.normalize.splitIds("  REQ-001  ", arena.allocator());
    try s.testing.expectEqual(@as(usize, 1), parts.len);
    try s.testing.expectEqualStrings("REQ-001", parts[0]);
}

test "splitIds empty produces no tokens" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    const parts = try s.normalize.splitIds("", arena.allocator());
    try s.testing.expectEqual(@as(usize, 0), parts.len);
}

test "isBlankEquivalent" {
    try s.testing.expect(s.normalize.isBlankEquivalent(""));
    try s.testing.expect(s.normalize.isBlankEquivalent("n/a"));
    try s.testing.expect(s.normalize.isBlankEquivalent("N/A"));
    try s.testing.expect(s.normalize.isBlankEquivalent("tbd"));
    try s.testing.expect(s.normalize.isBlankEquivalent("TBD"));
    try s.testing.expect(s.normalize.isBlankEquivalent("none"));
    try s.testing.expect(s.normalize.isBlankEquivalent("-"));
    try s.testing.expect(!s.normalize.isBlankEquivalent("REQ-001"));
    try s.testing.expect(!s.normalize.isBlankEquivalent("0"));
}

test "isSectionDivider" {
    try s.testing.expect(s.normalize.isSectionDivider(&.{ "", "" }, 0));
    try s.testing.expect(s.normalize.isSectionDivider(&.{ "", "Intro" }, 0));
    try s.testing.expect(s.normalize.isSectionDivider(&.{ "", "GENERAL REQUIREMENTS" }, 0));
    try s.testing.expect(!s.normalize.isSectionDivider(&.{ "REQ-001", "statement" }, 0));
    try s.testing.expect(!s.normalize.isSectionDivider(&.{ "", "statement", "high" }, 0));
    try s.testing.expect(s.normalize.isSectionDivider(&.{ "", "section 3 - interfaces" }, 0));
}

test "normalizeId basic" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const result = try s.normalize.normalizeId(" req-001 ", arena.allocator(), &d, "Test", 1);
    try s.testing.expectEqualStrings("req-001", result);
    try s.testing.expectEqual(@as(u32, 0), d.warning_count);
}

test "normalizeId rejects parenthetical suffix without repair" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const result = try s.normalize.normalizeId("REQ-001 (old)", arena.allocator(), &d, "Test", 1);
    try s.testing.expectEqual(@as(usize, 0), result.len);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.id_invalid));
}

test "normalizeId rejects leading and trailing hyphens without repair" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const result = try s.normalize.normalizeId("-REQ-001-", arena.allocator(), &d, "Test", 1);
    try s.testing.expectEqual(@as(usize, 0), result.len);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.id_invalid));
}

test "normalizeId rejects URL-like IDs" {
    var arena = s.std.heap.ArenaAllocator.init(s.testing.allocator);
    defer arena.deinit();
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const result = try s.normalize.normalizeId("foo/bar/baz?blow=up", arena.allocator(), &d, "Requirements", 2);
    try s.testing.expectEqual(@as(usize, 0), result.len);
    try s.testing.expect(s.diagnosticsContainCode(&d, s.diagnostic.E.id_invalid));
}

test "parseNumericField text mappings" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    try s.testing.expectEqualStrings("4", (try s.normalize.parseNumericField("high", &d, "T", 1, "Sev")).?);
    try s.testing.expectEqualStrings("3", (try s.normalize.parseNumericField("medium", &d, "T", 1, "Sev")).?);
    try s.testing.expectEqualStrings("1", (try s.normalize.parseNumericField("negligible", &d, "T", 1, "Sev")).?);
    try s.testing.expectEqualStrings("4", (try s.normalize.parseNumericField("4.0", &d, "T", 1, "Sev")).?);
}

test "parseNumericField blank equivalents return null" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    try s.testing.expect(try s.normalize.parseNumericField("", &d, "T", 1, "Sev") == null);
    try s.testing.expect(try s.normalize.parseNumericField("n/a", &d, "T", 1, "Sev") == null);
}

test "parseNumericField fractional warns and returns null" {
    var d = s.Diagnostics.init(s.testing.allocator);
    defer d.deinit();
    const result = try s.normalize.parseNumericField("3.5", &d, "Risks", 2, "Severity");
    try s.testing.expect(result == null);
    try s.testing.expect(d.warning_count >= 1);
}
