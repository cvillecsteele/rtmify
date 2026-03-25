pub const ingest = @import("ingest.zig");
pub const item_specs = @import("item_specs.zig");
pub const trace_refs = @import("trace_refs.zig");
pub const util = @import("util.zig");

test "soup facade still exposes public API" {
    const facade = @import("../soup.zig");
    _ = facade.default_bom_name;
    _ = facade.SoupRowError;
    _ = facade.SoupIngestResponse;
    _ = facade.ingestJsonBody;
    _ = facade.ingestXlsxPath;
    _ = facade.listSoftwareBomsJson;
    _ = facade.getSoupComponentsJson;
    _ = facade.soupRegisterMarkdown;
}

test {
    _ = ingest;
    _ = item_specs;
    _ = trace_refs;
    _ = util;
}
