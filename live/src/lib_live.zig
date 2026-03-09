/// lib_live.zig — test root for live modules.
/// `zig build test-live` runs all tests in db.zig, graph_live.zig, and sheets.zig.
const std = @import("std");

pub const db = @import("db.zig");
pub const graph_live = @import("graph_live.zig");
pub const sheets = @import("sheets.zig");
pub const sync_live = @import("sync_live.zig");
pub const mcp = @import("mcp.zig");

test {
    _ = db;
    _ = graph_live;
    _ = sheets;
    _ = sync_live;
    _ = mcp;
}
