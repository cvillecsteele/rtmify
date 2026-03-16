const std = @import("std");
const graph = @import("../graph.zig");
const xlsx = @import("../xlsx.zig");
const diagnostic = @import("../diagnostic.zig");

pub const Allocator = std.mem.Allocator;
pub const Graph = graph.Graph;
pub const Property = graph.Property;
pub const SheetData = xlsx.SheetData;
pub const Row = xlsx.Row;
pub const Diagnostics = diagnostic.Diagnostics;

pub const IngestStats = struct {
    product_count: u32 = 0,
    decomposition_count: u32 = 0,
    requirement_count: u32 = 0,
    user_need_count: u32 = 0,
    test_group_count: u32 = 0,
    test_count: u32 = 0,
    risk_count: u32 = 0,
    design_input_count: u32 = 0,
    design_output_count: u32 = 0,
    config_item_count: u32 = 0,
};

pub const IngestOptions = struct {
    enable_product_tab: bool = false,
    enable_decomposition_tab: bool = false,
    enable_design_inputs_tab: bool = false,
    enable_design_outputs_tab: bool = false,
    enable_config_items_tab: bool = false,
};

pub const IngestContext = struct {
    g: *Graph,
    diag: *Diagnostics,
    opts: IngestOptions,
};

pub fn cell(row: Row, col: ?usize) []const u8 {
    const c = col orelse return "";
    if (c >= row.len) return "";
    return row[c];
}

pub fn diagnosticsContainCode(diag: *const Diagnostics, code: diagnostic.Code) bool {
    for (diag.entries.items) |entry| {
        if (entry.code == code) return true;
    }
    return false;
}
