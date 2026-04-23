const testing = @import("std").testing;
const cycle = @import("../cycle.zig");
const internal = @import("../internal.zig");

test "tabExists matches exact case-insensitive and fuzzy optional tab titles" {
    const tabs = [_]internal.online_provider.TabRef{
        .{ .title = "User Needs", .native_id = "1" },
        .{ .title = "Requirements", .native_id = "2" },
        .{ .title = "Configuration Items (optional)", .native_id = "3" },
    };

    try testing.expect(cycle.tabExists(&tabs, "User Needs"));
    try testing.expect(cycle.tabExists(&tabs, "user needs"));
    try testing.expect(cycle.tabExists(&tabs, "Configuration Items"));
    try testing.expect(!cycle.tabExists(&tabs, "Design Inputs"));
}

test "buildIngestOptions carries workbook display name into RTM artifact options" {
    var arena = @import("std").heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const opts = try cycle.buildIngestOptions(.generic, "demo-slug", "Demo Workbook", "/tmp/demo.xlsx", alloc);
    try testing.expectEqualStrings("artifact://rtm/demo-slug", opts.rtm_artifact_id.?);
    try testing.expectEqualStrings("Demo Workbook", opts.rtm_artifact_display_name.?);
    try testing.expectEqualStrings("/tmp/demo.xlsx", opts.rtm_artifact_path.?);
}
