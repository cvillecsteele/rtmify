const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_live = @import("../graph_live.zig");
const profile_mod = @import("rtmify").profile;
const design_history_core = @import("../design_history.zig");
const chain_mod = @import("../chain.zig");
const shared = @import("shared.zig");

pub fn handleDesignHistory(db: *graph_live.GraphDb, profile_name: []const u8, req_id: []const u8, alloc: Allocator) ![]const u8 {
    const pid = profile_mod.fromString(profile_name) orelse .generic;
    var history = (try design_history_core.buildRequirementHistoryForProfile(db, pid, req_id, alloc)) orelse {
        return std.fmt.allocPrint(alloc, "{{\"profile\":\"{s}\",\"requirement\":null,\"user_needs\":[],\"risks\":[],\"design_inputs\":[],\"design_outputs\":[],\"configuration_items\":[],\"source_files\":[],\"test_files\":[],\"annotations\":[],\"commits\":[],\"chain_gaps\":[]}}", .{@tagName(pid)});
    };
    defer design_history_core.deinitRequirementHistory(&history, alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"profile\":");
    try shared.appendJsonStr(&buf, @tagName(history.profile), alloc);
    try buf.appendSlice(alloc, ",\"requirement\":");
    try shared.appendNodeObjectOpt(&buf, history.requirement, alloc);
    try buf.appendSlice(alloc, ",\"user_needs\":");
    const needs_json = try shared.jsonNodeArray(history.user_needs, alloc);
    defer alloc.free(needs_json);
    try buf.appendSlice(alloc, needs_json);
    try buf.appendSlice(alloc, ",\"risks\":");
    const risks_json = try shared.jsonNodeArray(history.risks, alloc);
    defer alloc.free(risks_json);
    try buf.appendSlice(alloc, risks_json);
    try buf.appendSlice(alloc, ",\"design_inputs\":");
    const inputs_json = try shared.jsonNodeArray(history.design_inputs, alloc);
    defer alloc.free(inputs_json);
    try buf.appendSlice(alloc, inputs_json);
    try buf.appendSlice(alloc, ",\"design_outputs\":");
    const outputs_json = try shared.jsonNodeArray(history.design_outputs, alloc);
    defer alloc.free(outputs_json);
    try buf.appendSlice(alloc, outputs_json);
    try buf.appendSlice(alloc, ",\"configuration_items\":");
    const config_json = try shared.jsonNodeArray(history.configuration_items, alloc);
    defer alloc.free(config_json);
    try buf.appendSlice(alloc, config_json);
    try buf.appendSlice(alloc, ",\"source_files\":");
    const source_json = try shared.jsonNodeArray(history.source_files, alloc);
    defer alloc.free(source_json);
    try buf.appendSlice(alloc, source_json);
    try buf.appendSlice(alloc, ",\"test_files\":");
    const test_json = try shared.jsonNodeArray(history.test_files, alloc);
    defer alloc.free(test_json);
    try buf.appendSlice(alloc, test_json);
    try buf.appendSlice(alloc, ",\"annotations\":");
    const annotations_json = try shared.jsonNodeArray(history.annotations, alloc);
    defer alloc.free(annotations_json);
    try buf.appendSlice(alloc, annotations_json);
    try buf.appendSlice(alloc, ",\"commits\":");
    const commits_json = try shared.jsonNodeArray(history.commits, alloc);
    defer alloc.free(commits_json);
    try buf.appendSlice(alloc, commits_json);
    try buf.appendSlice(alloc, ",\"chain_gaps\":");
    const gaps_json = try chain_mod.gapsToJson(history.chain_gaps, alloc);
    defer alloc.free(gaps_json);
    try buf.appendSlice(alloc, gaps_json);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn seedDhrFixture(db: *graph_live.GraphDb) !void {
    try db.addNode("UN-001", "UserNeed", "{\"statement\":\"Need GPS\",\"source\":\"Customer\",\"priority\":\"High\"}", null);
    try db.addNode("artifact://rtm/demo", "Artifact", "{\"kind\":\"rtm_workbook\",\"display_name\":\"Demo RTM\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"status\":\"Approved\",\"text_status\":\"single_source\",\"authoritative_source\":\"artifact://rtm/demo\",\"source_count\":1}", null);
    try db.addNode("REQ-999", "Requirement", "{\"status\":\"Draft\",\"text_status\":\"single_source\",\"authoritative_source\":\"artifact://rtm/demo\",\"source_count\":1}", null);
    try db.addNode("artifact://rtm/demo:REQ-001", "RequirementText", "{\"artifact_id\":\"artifact://rtm/demo\",\"source_kind\":\"rtm_workbook\",\"req_id\":\"REQ-001\",\"text\":\"Detect GPS loss\",\"normalized_text\":\"detect gps loss\",\"hash\":\"abc\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try db.addNode("artifact://rtm/demo:REQ-999", "RequirementText", "{\"artifact_id\":\"artifact://rtm/demo\",\"source_kind\":\"rtm_workbook\",\"req_id\":\"REQ-999\",\"text\":\"Standalone maintenance mode\",\"normalized_text\":\"standalone maintenance mode\",\"hash\":\"def\",\"parse_status\":\"ok\",\"occurrence_count\":1}", null);
    try db.addNode("RSK-001", "Risk", "{\"description\":\"Clock drift\"}", null);
    try db.addNode("DI-001", "DesignInput", "{\"description\":\"Timing spec\"}", null);
    try db.addNode("DO-001", "DesignOutput", "{\"description\":\"GPS firmware\"}", null);
    try db.addNode("DO-002", "DesignOutput", "{\"description\":\"Fallback logging\"}", null);
    try db.addNode("CI-001", "ConfigurationItem", "{\"description\":\"Main ECU\"}", null);
    try db.addNode("src/gps.c", "SourceFile", "{\"path\":\"src/gps.c\",\"repo\":\"/tmp/repo\"}", null);
    try db.addNode("test/gps_test.c", "TestFile", "{\"path\":\"test/gps_test.c\",\"repo\":\"/tmp/repo\"}", null);
    try db.addNode("src/gps.c:10", "CodeAnnotation", "{\"req_id\":\"REQ-001\",\"file_path\":\"src/gps.c\",\"line_number\":10,\"blame_author\":\"Casey\",\"short_hash\":\"abc123\"}", null);
    try db.addNode("abc123", "Commit", "{\"hash\":\"abc123\",\"short_hash\":\"abc123\",\"date\":\"2026-03-09T00:00:00Z\",\"message\":\"Implement GPS trace\"}", null);

    try db.addEdge("artifact://rtm/demo", "artifact://rtm/demo:REQ-001", "CONTAINS");
    try db.addEdge("artifact://rtm/demo", "artifact://rtm/demo:REQ-999", "CONTAINS");
    try db.addEdge("artifact://rtm/demo:REQ-001", "REQ-001", "ASSERTS");
    try db.addEdge("artifact://rtm/demo:REQ-999", "REQ-999", "ASSERTS");
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");
    try db.addEdge("RSK-001", "REQ-001", "MITIGATED_BY");
    try db.addEdge("REQ-001", "DI-001", "ALLOCATED_TO");
    try db.addEdge("DI-001", "DO-001", "SATISFIED_BY");
    try db.addEdge("DI-001", "DO-002", "SATISFIED_BY");
    try db.addEdge("DO-001", "CI-001", "CONTROLLED_BY");
    try db.addEdge("REQ-001", "src/gps.c", "IMPLEMENTED_IN");
    try db.addEdge("DO-001", "src/gps.c", "IMPLEMENTED_IN");
    try db.addEdge("REQ-001", "test/gps_test.c", "VERIFIED_BY_CODE");
    try db.addEdge("src/gps.c", "test/gps_test.c", "VERIFIED_BY_CODE");
    try db.addEdge("REQ-001", "src/gps.c:10", "ANNOTATED_AT");
    try db.addEdge("REQ-001", "abc123", "COMMITTED_IN");
}

const testing = std.testing;

test "handleDesignHistory returns structured chain with filtered gaps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try seedDhrFixture(&db);

    const resp = try handleDesignHistory(&db, "medical", "REQ-001", alloc);
    try testing.expect(std.mem.indexOf(u8, resp, "\"requirement\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"user_needs\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"risks\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"design_inputs\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"design_outputs\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"configuration_items\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"source_files\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"test_files\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"annotations\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"commits\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"chain_gaps\":") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "DO-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "CI-001") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "design_output_without_config_control") != null);
}
