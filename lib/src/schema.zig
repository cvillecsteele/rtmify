/// Maps parsed XLSX sheet data onto a Graph.
///
/// Column lookup is by header name (case-insensitive) so column reordering
/// in the template does not break ingestion.

const diagnostic = @import("diagnostic.zig");
const schema_mod = @import("schema/mod.zig");

const Graph = schema_mod.internal.Graph;
const SheetData = schema_mod.internal.SheetData;
const Diagnostics = schema_mod.internal.Diagnostics;

pub const IngestStats = schema_mod.internal.IngestStats;
pub const IngestOptions = schema_mod.internal.IngestOptions;

/// Ingest workbook sheets into g.
/// Call order: Product? -> User Needs -> Tests -> Requirements -> Decomposition? -> Risks
/// (so that edge targets exist before edges are created).
pub fn ingest(g: *Graph, sheets: []const SheetData) !void {
    return ingestWithOptions(g, sheets, .{});
}

pub fn ingestWithOptions(g: *Graph, sheets: []const SheetData, options: IngestOptions) !void {
    var d = Diagnostics.init(g.arena.child_allocator);
    defer d.deinit();
    _ = try ingestValidatedWithOptions(g, sheets, &d, options);
}

/// Validated ingest: appends diagnostics, returns counts.
pub fn ingestValidated(g: *Graph, sheets: []const SheetData, diag: *Diagnostics) !IngestStats {
    return ingestValidatedWithOptions(g, sheets, diag, .{});
}

/// Validated ingest with explicit feature flags, returns counts.
pub fn ingestValidatedWithOptions(g: *Graph, sheets: []const SheetData, diag: *Diagnostics, options: IngestOptions) !IngestStats {
    var stats = IngestStats{};
    const ctx: schema_mod.internal.IngestContext = .{
        .g = g,
        .diag = diag,
        .opts = options,
    };

    if (options.enable_product_tab) {
        if (schema_mod.tabs.resolveTab(sheets, "Product", diag)) |s| {
            try schema_mod.sheets.products.ingest(&ctx, s, &stats);
        }
    }
    if (schema_mod.tabs.resolveTab(sheets, "User Needs", diag)) |s| {
        try schema_mod.sheets.user_needs.ingest(&ctx, s, &stats);
    } else {
        try diag.info(diagnostic.E.optional_tab_missing, .tab_discovery, null, null,
            "'User Needs' tab not found — user need traceability will be absent", .{});
    }
    if (schema_mod.tabs.resolveTab(sheets, "Tests", diag)) |s| {
        try schema_mod.sheets.tests.ingest(&ctx, s, &stats);
    } else {
        try diag.info(diagnostic.E.optional_tab_missing, .tab_discovery, null, null,
            "'Tests' tab not found — test coverage will not be tracked", .{});
    }

    const req_sheet = schema_mod.tabs.resolveTab(sheets, "Requirements", diag) orelse {
        try diag.add(.err, diagnostic.E.requirements_tab_missing, .tab_discovery, null, null,
            "No 'Requirements' tab found. Available tabs: {s}", .{schema_mod.tabs.tabList(sheets, diag)});
        return diagnostic.ValidationError.RequirementsTabNotFound;
    };
    try schema_mod.sheets.requirements.ingest(&ctx, req_sheet, &stats);

    if (options.enable_decomposition_tab) {
        if (schema_mod.tabs.resolveTab(sheets, "Decomposition", diag)) |s| {
            try schema_mod.sheets.decomposition.ingest(&ctx, s, &stats);
        }
    }
    if (schema_mod.tabs.resolveTab(sheets, "Risks", diag)) |s| {
        try schema_mod.sheets.risks.ingest(&ctx, s, &stats);
    } else {
        try diag.info(diagnostic.E.optional_tab_missing, .tab_discovery, null, null,
            "'Risks' tab not found — risk register will not be tracked", .{});
    }
    if (options.enable_design_inputs_tab) {
        if (schema_mod.tabs.resolveTab(sheets, "Design Inputs", diag)) |s| {
            try schema_mod.sheets.design_inputs.ingest(&ctx, s, &stats);
        }
    }
    if (options.enable_design_outputs_tab) {
        if (schema_mod.tabs.resolveTab(sheets, "Design Outputs", diag)) |s| {
            try schema_mod.sheets.design_outputs.ingest(&ctx, s, &stats);
        }
    }
    if (options.enable_config_items_tab) {
        if (schema_mod.tabs.resolveTab(sheets, "Configuration Items", diag)) |s| {
            try schema_mod.sheets.config_items.ingest(&ctx, s, &stats);
        }
    }

    try schema_mod.semantic.semanticValidate(g, diag);
    return stats;
}

pub fn hasTab(sheets: []const SheetData, canonical_name: []const u8) bool {
    return schema_mod.tabs.hasTab(sheets, canonical_name);
}

pub fn isBlankEquivalent(s: []const u8) bool {
    return schema_mod.normalize.isBlankEquivalent(s);
}

test {
    _ = @import("schema/tests/mod.zig");
}
