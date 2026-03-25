const std = @import("std");
const Allocator = std.mem.Allocator;

const bom = @import("../bom.zig");

pub const default_bom_name = "SOUP Components";

pub const SoupRowError = struct {
    row: usize,
    code: []const u8,
    message: []const u8,

    pub fn deinit(self: *SoupRowError, alloc: Allocator) void {
        alloc.free(self.code);
        alloc.free(self.message);
    }
};

pub const SoupIngestResponse = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    source_format: bom.BomFormat,
    rows_received: usize,
    rows_ingested: usize,
    inserted_nodes: usize,
    inserted_edges: usize,
    row_errors: []SoupRowError,
    warnings: []bom.BomWarning,

    pub fn deinit(self: *SoupIngestResponse, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        for (self.row_errors) |*row_error| row_error.deinit(alloc);
        alloc.free(self.row_errors);
        for (self.warnings) |*warning| warning.deinit(alloc);
        alloc.free(self.warnings);
    }
};

pub const ParseResult = struct {
    submission: bom.BomSubmission,
    warnings: std.ArrayList(bom.BomWarning),
    row_errors: std.ArrayList(SoupRowError),
    rows_received: usize,
    rows_ingested: usize,

    pub fn deinit(self: *ParseResult, alloc: Allocator) void {
        self.submission.deinit(alloc);
        for (self.warnings.items) |*warning| warning.deinit(alloc);
        self.warnings.deinit(alloc);
        for (self.row_errors.items) |*row_error| row_error.deinit(alloc);
        self.row_errors.deinit(alloc);
    }
};
