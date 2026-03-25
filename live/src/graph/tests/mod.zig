pub const nodes = @import("nodes_test.zig");
pub const edges = @import("edges_test.zig");
pub const require_text = @import("require_text_test.zig");
pub const projections = @import("projections_test.zig");
pub const suspect = @import("suspect_test.zig");
pub const impact = @import("impact_test.zig");
pub const config_diag = @import("config_diag_test.zig");

test {
    _ = nodes;
    _ = edges;
    _ = require_text;
    _ = projections;
    _ = suspect;
    _ = impact;
    _ = config_diag;
}
