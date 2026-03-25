const std = @import("std");
const testing = std.testing;

const bom = @import("../bom.zig");
const graph_live = @import("../graph_live.zig");
const shared = @import("../routes/shared.zig");
const prepare_csv = @import("prepare_csv.zig");

test "facade exposes ingest and coverage query" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var ingest = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {"parent_part":"ASM-1000","child_part":"R1","quantity":"1"}
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);

    const coverage = try bom.getDesignBomCoverageJson(&db, "ASM-1000-REV-C", "pcba", true, testing.allocator);
    defer testing.allocator.free(coverage);
    try testing.expect(std.mem.indexOf(u8, coverage, "\"item_count\":2") != null);
}

test "prepare hardware csv parses valid body with named bom" {
    const body =
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,ref_designator,description,supplier,category
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4,"C47,C48",10uF capacitor,Murata,component
    ;
    var prepared = try prepare_csv.prepareHardwareCsv(body, testing.allocator);
    defer prepared.deinit(testing.allocator);
    try testing.expectEqualStrings("pcba", prepared.submission.bom_name);
    try testing.expectEqualStrings("ASM-1000-REV-C", prepared.submission.full_product_identifier);
    try testing.expect(prepared.submission.occurrences.len >= 2);
}

test "prepare hardware csv rejects mismatched bom name across rows" {
    const body =
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4
        \\firmware,ASM-1000-REV-C,ASM-1000,REV-C,R0402-1K,A,2
    ;
    try testing.expectError(error.InvalidCsv, prepare_csv.prepareHardwareCsv(body, testing.allocator));
}

test "hardware csv trace refs create BOM item properties and typed edges" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Req 2\"}", null);
    try db.addNode("TEST-001", "Test", "{\"name\":\"Test 1\"}", null);

    var ingest = try bom.ingestHttpBody(
        &db,
        "text/csv",
        \\bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,requirement_ids,test_id
        \\pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4,"REQ-001;REQ-002",TEST-001
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ingest.warnings.len);

    const item_id = "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A";
    const item_json = try bom.getBomItemJson(&db, item_id, testing.allocator);
    defer testing.allocator.free(item_json);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"requirement_ids\":[\"REQ-001\",\"REQ-002\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"test_ids\":[\"TEST-001\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"linked_requirements\":[") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-002\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"linked_tests\":[") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"TEST-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_requirement_ids\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_test_ids\":[]") != null);
}

test "hardware json unresolved trace refs warn and preserve declared ids" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req\"}", null);

    var ingest = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4",
        \\      "requirement_ids": "REQ-001|REQ-404",
        \\      "test_ids": ["TEST-404"]
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer ingest.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), ingest.warnings.len);
    try testing.expectEqualStrings("BOM_UNRESOLVED_REQUIREMENT_REF", ingest.warnings[0].code);
    try testing.expectEqualStrings("BOM_UNRESOLVED_TEST_REF", ingest.warnings[1].code);

    const item_id = "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A";
    const item_json = try bom.getBomItemJson(&db, item_id, testing.allocator);
    defer testing.allocator.free(item_json);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"requirement_ids\":[\"REQ-001\",\"REQ-404\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"test_ids\":[\"TEST-404\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-001\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_requirement_ids\":[\"REQ-404\"]") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"unresolved_test_ids\":[\"TEST-404\"]") != null);
}

test "edge properties round trip through graph and node detail JSON" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();

    try db.addNode("a", "BOM", "{}", null);
    try db.addNode("b", "BOMItem", "{\"part\":\"X\"}", null);
    try db.addEdgeWithProperties("a", "b", "CONTAINS", "{\"quantity\":\"4\"}");

    var edges: std.ArrayList(graph_live.Edge) = .empty;
    defer {
        for (edges.items) |edge| shared.freeEdge(edge, testing.allocator);
        edges.deinit(testing.allocator);
    }
    try db.edgesFrom("a", testing.allocator, &edges);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqualStrings("{\"quantity\":\"4\"}", edges.items[0].properties.?);

    const resp = try @import("../routes/query.zig").handleNode(&db, "a", testing.allocator);
    defer testing.allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"properties\":{\"quantity\":\"4\"}") != null);
}

test "re-ingesting same bom key replaces only that bom subtree" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var hardware = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer hardware.deinit(testing.allocator);

    var software = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bomFormat": "CycloneDX",
        \\  "bom_name": "firmware",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "metadata": { "component": { "name": "fw", "version": "1.0.0", "bom-ref": "fw@1.0.0" } },
        \\  "components": [
        \\    { "name": "zlib", "version": "1.2.13", "bom-ref": "pkg:generic/zlib@1.2.13", "purl": "pkg:generic/zlib@1.2.13" }
        \\  ],
        \\  "dependencies": [
        \\    { "ref": "fw@1.0.0", "dependsOn": ["pkg:generic/zlib@1.2.13"] }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer software.deinit(testing.allocator);

    var replacement = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "R0402-1K",
        \\      "child_revision": "B",
        \\      "quantity": "2"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer replacement.deinit(testing.allocator);

    const bom_json = try bom.getBomJson(&db, "ASM-1000-REV-C", null, null, false, testing.allocator);
    defer testing.allocator.free(bom_json);
    try testing.expect(std.mem.indexOf(u8, bom_json, "R0402-1K") != null);
    try testing.expect(std.mem.indexOf(u8, bom_json, "C0805-10UF") == null);
    try testing.expect(std.mem.indexOf(u8, bom_json, "\"bom_name\":\"firmware\"") != null);
}

test "re-ingesting same bom key replaces stale BOM trace edges" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);
    try db.addNode("REQ-001", "Requirement", "{\"statement\":\"Req 1\"}", null);
    try db.addNode("REQ-002", "Requirement", "{\"statement\":\"Req 2\"}", null);

    var first = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4",
        \\      "requirement_id": "REQ-001"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer first.deinit(testing.allocator);

    var second = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {
        \\      "parent_part": "ASM-1000",
        \\      "parent_revision": "REV-C",
        \\      "child_part": "C0805-10UF",
        \\      "child_revision": "A",
        \\      "quantity": "4",
        \\      "requirement_id": "REQ-002"
        \\    }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer second.deinit(testing.allocator);

    const item_json = try bom.getBomItemJson(&db, "bom-item://ASM-1000-REV-C/hardware/pcba/C0805-10UF@A", testing.allocator);
    defer testing.allocator.free(item_json);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-002\"") != null);
    try testing.expect(std.mem.indexOf(u8, item_json, "\"id\":\"REQ-001\"") == null);
}

test "software component query filters by purl prefix" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\"}", null);

    var software = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bomFormat": "CycloneDX",
        \\  "bom_name": "firmware",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "metadata": { "component": { "name": "fw", "version": "1.0.0", "bom-ref": "fw@1.0.0" } },
        \\  "components": [
        \\    {
        \\      "name": "zlib",
        \\      "version": "1.2.13",
        \\      "bom-ref": "pkg:generic/zlib@1.2.13",
        \\      "purl": "pkg:generic/zlib@1.2.13",
        \\      "licenses": [{ "license": { "id": "Zlib" } }]
        \\    }
        \\  ],
        \\  "dependencies": [
        \\    { "ref": "fw@1.0.0", "dependsOn": ["pkg:generic/zlib@1.2.13"] }
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer software.deinit(testing.allocator);

    const components = try bom.getSoftwareComponentsJson(&db, "pkg:generic/zlib", "Zlib", testing.allocator);
    defer testing.allocator.free(components);
    try testing.expect(std.mem.indexOf(u8, components, "pkg:generic/zlib@1.2.13") != null);
}

test "listDesignBomsJson excludes obsolete products by default" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\",\"product_status\":\"Active\"}", null);
    try db.addNode("product://ASM-2000-REV-A", "Product", "{\"full_identifier\":\"ASM-2000-REV-A\",\"product_status\":\"Obsolete\"}", null);

    var active_ingest = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-1000-REV-C",
        \\  "bom_items": [
        \\    {"parent_part":"ASM-1000","child_part":"R1","quantity":"1"}
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer active_ingest.deinit(testing.allocator);
    var obsolete_ingest = try bom.ingestHttpBody(
        &db,
        "application/json",
        \\{
        \\  "bom_name": "pcba",
        \\  "full_product_identifier": "ASM-2000-REV-A",
        \\  "bom_items": [
        \\    {"parent_part":"ASM-2000","child_part":"R2","quantity":"1"}
        \\  ]
        \\}
    ,
        testing.allocator,
    );
    defer obsolete_ingest.deinit(testing.allocator);

    const filtered = try bom.listDesignBomsJson(&db, null, null, false, testing.allocator);
    defer testing.allocator.free(filtered);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-1000-REV-C\"") != null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-2000-REV-A\"") == null);

    const all = try bom.listDesignBomsJson(&db, null, null, true, testing.allocator);
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "\"ASM-2000-REV-A\"") != null);
    try testing.expect(std.mem.indexOf(u8, all, "\"product_status\":\"Obsolete\"") != null);
}

test "bomGapsJson excludes superseded and obsolete products by default" {
    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("product://ASM-1000-REV-C", "Product", "{\"full_identifier\":\"ASM-1000-REV-C\",\"product_status\":\"Active\"}", null);
    try db.addNode("product://ASM-2000-REV-A", "Product", "{\"full_identifier\":\"ASM-2000-REV-A\",\"product_status\":\"Superseded\"}", null);
    try db.addNode("product://ASM-3000-REV-A", "Product", "{\"full_identifier\":\"ASM-3000-REV-A\",\"product_status\":\"Obsolete\"}", null);

    inline for ([_][]const u8{ "ASM-1000-REV-C", "ASM-2000-REV-A", "ASM-3000-REV-A" }) |product_id| {
        const body = try std.fmt.allocPrint(
            testing.allocator,
            \\{{
            \\  "bom_name": "pcba",
            \\  "full_product_identifier": "{s}",
            \\  "bom_items": [
            \\    {{"parent_part":"ASSY","child_part":"FBRFET-3300","quantity":"1","requirement_id":"REQ-404"}}
            \\  ]
            \\}}
        ,
            .{product_id},
        );
        defer testing.allocator.free(body);
        var ingest = try bom.ingestHttpBody(&db, "application/json", body, testing.allocator);
        defer ingest.deinit(testing.allocator);
    }

    const filtered = try bom.bomGapsJson(&db, null, null, false, testing.allocator);
    defer testing.allocator.free(filtered);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-1000-REV-C\"") != null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-2000-REV-A\"") == null);
    try testing.expect(std.mem.indexOf(u8, filtered, "\"ASM-3000-REV-A\"") == null);

    const all = try bom.bomGapsJson(&db, null, null, true, testing.allocator);
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "\"ASM-2000-REV-A\"") != null);
    try testing.expect(std.mem.indexOf(u8, all, "\"ASM-3000-REV-A\"") != null);
}
