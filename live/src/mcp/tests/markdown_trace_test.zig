const markdown = @import("../markdown.zig");

test "markdown facade exports trace entrypoints" {
    _ = markdown.requirementTraceMarkdown;
    _ = markdown.designHistoryMarkdown;
    _ = markdown.impactMarkdown;
    _ = markdown.unitHistoryMarkdown;
    _ = markdown.testTraceMarkdown;
    _ = markdown.executionMarkdown;
}
