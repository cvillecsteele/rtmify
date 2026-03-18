const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const protocol = @import("../protocol.zig");
const support = @import("support.zig");

test "tools list exposes truthful schemas for structured and narrative tools" {
    var parsed = try support.parseToolsJsonForTest(testing.allocator);
    defer parsed.deinit();

    const get_rtm = support.findToolForTest(parsed.value, "get_rtm") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(get_rtm, "outputSchema") != null);
    try testing.expectEqualStrings("array", internal.json_util.getString(internal.json_util.getObjectField(get_rtm, "outputSchema").?, "type").?);

    const get_node = support.findToolForTest(parsed.value, "get_node") orelse return error.TestUnexpectedResult;
    const get_node_schema = internal.json_util.getObjectField(get_node, "inputSchema") orelse return error.TestUnexpectedResult;
    const get_node_props = internal.json_util.getObjectField(get_node_schema, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(get_node_props, "include_edges") != null);
    try testing.expect(internal.json_util.getObjectField(get_node_props, "include_properties") != null);
    try testing.expectEqualStrings("object", internal.json_util.getString(internal.json_util.getObjectField(get_node, "outputSchema").?, "type").?);

    const get_bom_item = support.findToolForTest(parsed.value, "get_bom_item") orelse return error.TestUnexpectedResult;
    const get_bom_item_schema = internal.json_util.getObjectField(get_bom_item, "inputSchema") orelse return error.TestUnexpectedResult;
    const one_of = internal.json_util.getObjectField(get_bom_item_schema, "oneOf") orelse return error.TestUnexpectedResult;
    try testing.expect(one_of == .array);
    try testing.expectEqual(@as(usize, 2), one_of.array.items.len);
    const get_bom_item_output = internal.json_util.getObjectField(get_bom_item, "outputSchema") orelse return error.TestUnexpectedResult;
    const get_bom_item_props = internal.json_util.getObjectField(get_bom_item_output, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(get_bom_item_props, "linked_requirements") != null);
    try testing.expect(internal.json_util.getObjectField(get_bom_item_props, "linked_tests") != null);
    try testing.expect(internal.json_util.getObjectField(get_bom_item_props, "unresolved_requirement_ids") != null);
    try testing.expect(internal.json_util.getObjectField(get_bom_item_props, "unresolved_test_ids") != null);

    const get_bom = support.findToolForTest(parsed.value, "get_bom") orelse return error.TestUnexpectedResult;
    const get_bom_schema = internal.json_util.getObjectField(get_bom, "inputSchema") orelse return error.TestUnexpectedResult;
    const get_bom_props = internal.json_util.getObjectField(get_bom_schema, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(get_bom_props, "include_obsolete") != null);

    const list_design_boms = support.findToolForTest(parsed.value, "list_design_boms") orelse return error.TestUnexpectedResult;
    const list_design_boms_schema = internal.json_util.getObjectField(list_design_boms, "inputSchema") orelse return error.TestUnexpectedResult;
    const list_design_boms_props = internal.json_util.getObjectField(list_design_boms_schema, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(list_design_boms_props, "include_obsolete") != null);

    const find_part_usage = support.findToolForTest(parsed.value, "find_part_usage") orelse return error.TestUnexpectedResult;
    const find_part_usage_schema = internal.json_util.getObjectField(find_part_usage, "inputSchema") orelse return error.TestUnexpectedResult;
    const find_part_usage_props = internal.json_util.getObjectField(find_part_usage_schema, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(find_part_usage_props, "include_obsolete") != null);

    const bom_gaps = support.findToolForTest(parsed.value, "bom_gaps") orelse return error.TestUnexpectedResult;
    const bom_gaps_schema = internal.json_util.getObjectField(bom_gaps, "inputSchema") orelse return error.TestUnexpectedResult;
    const bom_gaps_props = internal.json_util.getObjectField(bom_gaps_schema, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(bom_gaps_props, "include_inactive") != null);

    const bom_impact_analysis = support.findToolForTest(parsed.value, "bom_impact_analysis") orelse return error.TestUnexpectedResult;
    const bom_impact_analysis_schema = internal.json_util.getObjectField(bom_impact_analysis, "inputSchema") orelse return error.TestUnexpectedResult;
    const bom_impact_analysis_props = internal.json_util.getObjectField(bom_impact_analysis_schema, "properties") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(bom_impact_analysis_props, "include_obsolete") != null);

    const requirement_trace = support.findToolForTest(parsed.value, "requirement_trace") orelse return error.TestUnexpectedResult;
    try testing.expect(internal.json_util.getObjectField(requirement_trace, "outputSchema") == null);
}

test "mcp headers do not advertise wildcard cors" {
    for (protocol.json_rpc_headers) |header| {
        try testing.expect(!std.ascii.eqlIgnoreCase(header.name, "Access-Control-Allow-Origin"));
    }
}
