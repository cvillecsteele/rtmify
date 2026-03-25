const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const markdown = @import("../markdown.zig");

test "markdown facade exports detail entrypoints" {
    _ = markdown.nodeMarkdown;
    _ = markdown.userNeedMarkdown;
    _ = markdown.artifactMarkdown;
    _ = markdown.codeFileMarkdown;
    _ = markdown.markdownFromNodeDetail;
}

test "artifact markdown renders extraction summary headings" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("artifact://srs_docx/demo", "Artifact", "{\"kind\":\"srs_docx\",\"display_name\":\"Demo SRS\",\"path\":\"/tmp/demo.docx\",\"ingest_source\":\"dashboard_upload\",\"last_ingested_at\":\"123\",\"latest_new_requirement_ids\":[\"REQ-001\"]}", null);
    try db.addNode("artifact://srs_docx/demo:REQ-001", "RequirementText", "{\"artifact_id\":\"artifact://srs_docx/demo\",\"source_kind\":\"srs_docx\",\"req_id\":\"REQ-001\",\"text\":\"Requirement text\",\"normalized_text\":\"requirement text\",\"hash\":\"abc\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try db.addEdge("artifact://srs_docx/demo", "artifact://srs_docx/demo:REQ-001", "CONTAINS");

    const md = try markdown.artifactMarkdown("artifact://srs_docx/demo", &db, testing.allocator);
    defer testing.allocator.free(md);

    try testing.expect(std.mem.indexOf(u8, md, "# Design Artifact artifact://srs_docx/demo") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## Assertions") != null);
    try testing.expect(std.mem.indexOf(u8, md, "## New Since Last Ingest") != null);
}
