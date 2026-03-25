const std = @import("std");
const testing = std.testing;
const graph = @import("../mod.zig");

test "requirement resolution prefers RTM and augments node properties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();

    try g.addNode("REQ-001", "Requirement", "{\"status\":\"approved\"}", null);
    try g.addNode("artifact://rtm/demo", "Artifact", "{\"kind\":\"rtm_workbook\"}", null);
    try g.addNode("artifact://srs/core", "Artifact", "{\"kind\":\"srs_docx\"}", null);
    try g.addNode("artifact://rtm/demo:REQ-001", "RequirementText", "{\"artifact_id\":\"artifact://rtm/demo\",\"source_kind\":\"rtm_workbook\",\"req_id\":\"REQ-001\",\"text\":\"RTM text\",\"normalized_text\":\"rtm text\",\"hash\":\"abc\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try g.addNode("artifact://srs/core:REQ-001", "RequirementText", "{\"artifact_id\":\"artifact://srs/core\",\"source_kind\":\"srs_docx\",\"req_id\":\"REQ-001\",\"text\":\"SRS text\",\"normalized_text\":\"srs text\",\"hash\":\"def\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try g.addEdge("artifact://rtm/demo", "artifact://rtm/demo:REQ-001", "CONTAINS");
    try g.addEdge("artifact://srs/core", "artifact://srs/core:REQ-001", "CONTAINS");
    try g.addEdge("artifact://rtm/demo:REQ-001", "REQ-001", "ASSERTS");
    try g.addEdge("artifact://srs/core:REQ-001", "REQ-001", "ASSERTS");

    var resolution = try g.resolveRequirementText("REQ-001", alloc);
    defer resolution.deinit(alloc);
    try testing.expectEqualStrings("RTM text", resolution.effective_statement.?);
    try testing.expectEqualStrings("artifact://rtm/demo", resolution.authoritative_source.?);
    try testing.expectEqualStrings("conflict", resolution.text_status);
    try testing.expectEqual(@as(usize, 2), resolution.source_count);

    const node = (try g.getNode("REQ-001", alloc)).?;
    try testing.expect(std.mem.indexOf(u8, node.properties, "\"statement\":\"RTM text\"") != null);
    try testing.expect(std.mem.indexOf(u8, node.properties, "\"source_count\":2") != null);
}

test "search finds requirement text via requirement text nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g = try graph.GraphDb.init(":memory:");
    defer g.deinit();
    try g.addNode("artifact://rtm/demo", "Artifact", "{\"kind\":\"rtm_workbook\"}", null);
    try g.addNode("REQ-001", "Requirement", "{}", null);
    try g.addNode("REQ-002", "Requirement", "{}", null);
    try g.addNode("artifact://rtm/demo:REQ-001", "RequirementText", "{\"artifact_id\":\"artifact://rtm/demo\",\"source_kind\":\"rtm_workbook\",\"req_id\":\"REQ-001\",\"text\":\"sterile packaging required\",\"normalized_text\":\"sterile packaging required\",\"hash\":\"abc\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try g.addNode("artifact://rtm/demo:REQ-002", "RequirementText", "{\"artifact_id\":\"artifact://rtm/demo\",\"source_kind\":\"rtm_workbook\",\"req_id\":\"REQ-002\",\"text\":\"unrelated\",\"normalized_text\":\"unrelated\",\"hash\":\"def\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try g.addEdge("artifact://rtm/demo", "artifact://rtm/demo:REQ-001", "CONTAINS");
    try g.addEdge("artifact://rtm/demo", "artifact://rtm/demo:REQ-002", "CONTAINS");
    try g.addEdge("artifact://rtm/demo:REQ-001", "REQ-001", "ASSERTS");
    try g.addEdge("artifact://rtm/demo:REQ-002", "REQ-002", "ASSERTS");

    var results: std.ArrayList(graph.Node) = .empty;
    defer results.deinit(alloc);
    try g.search("sterile", alloc, &results);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("REQ-001", results.items[0].id);
}
