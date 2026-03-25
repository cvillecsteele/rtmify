const std = @import("std");
const testing = std.testing;
const gaps = @import("../markdown/gaps.zig");

test "explainGap returns fallback text for unknown gap type" {
    const explanation = gaps.explainGap("unknown_gap", "REQ-001", "medical");
    try testing.expect(std.mem.indexOf(u8, explanation.check, "profile-specific traceability rule") != null);
    try testing.expect(std.mem.indexOf(u8, explanation.why, "missing or inconsistent") != null);
}

test "markdownFromGap renders heading and metadata" {
    const raw =
        \\{
        \\  "code": 1203,
        \\  "title": "Missing implementation",
        \\  "gap_type": "unimplemented_requirement",
        \\  "node_id": "REQ-001",
        \\  "severity": "warn",
        \\  "message": "Requirement lacks implementation evidence."
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();

    const md = try gaps.markdownFromGap(parsed.value, "medical", testing.allocator);
    defer testing.allocator.free(md);

    try testing.expect(std.mem.indexOf(u8, md, "# [1203] Missing implementation") != null);
    try testing.expect(std.mem.indexOf(u8, md, "- Node: `REQ-001`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## What RTMify Checked") != null);
}
