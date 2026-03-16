const std = @import("std");
const testing = std.testing;
const internal = @import("../internal.zig");
const markdown = @import("../markdown.zig");

test "node markdown includes edge properties in stable order" {
    var db = try internal.graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("BOM-ROOT", "BOM", "{\"description\":\"Root\"}", null);
    try db.addNode("BOM-ITEM", "BOMItem", "{\"description\":\"Child\"}", null);
    try db.addEdgeWithProperties("BOM-ROOT", "BOM-ITEM", "CONTAINS", "{\"supplier\":\"Murata\",\"quantity\":\"4\",\"relation_source\":\"hardware_csv\",\"ref_designator\":\"C47,C48\"}");

    const md = try markdown.nodeMarkdown("BOM-ROOT", &db, testing.allocator);
    defer testing.allocator.free(md);
    try testing.expect(std.mem.indexOf(u8, md, "[quantity=4, ref_designator=C47,C48, supplier=Murata, relation_source=hardware_csv]") != null);
}
