const std = @import("std");
const testing = std.testing;
const markdown = @import("../markdown.zig");

test "markdown facade exports catalog entrypoints" {
    _ = markdown.statusMarkdown;
    _ = markdown.mcpToolsIndexMarkdown;
    _ = markdown.mcpPromptsIndexMarkdown;
}

test "mcp tools and prompts markdown render headings" {
    const tools_md = try markdown.mcpToolsIndexMarkdown(testing.allocator);
    defer testing.allocator.free(tools_md);
    try testing.expect(std.mem.indexOf(u8, tools_md, "# MCP Tools") != null);

    const prompts_md = try markdown.mcpPromptsIndexMarkdown(testing.allocator);
    defer testing.allocator.free(prompts_md);
    try testing.expect(std.mem.indexOf(u8, prompts_md, "# MCP Prompts") != null);
}
