const std = @import("std");

pub const Allocator = std.mem.Allocator;

fn freeStringSlice(items: []const []const u8, alloc: Allocator) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

pub const BomType = enum { hardware, software };
pub const BomFormat = enum { hardware_csv, hardware_json, cyclonedx, spdx, xlsx, sheets, soup_json, soup_xlsx };

pub const ProductStatus = enum {
    active,
    in_development,
    superseded,
    eol,
    obsolete,
    unknown,
};

pub const BomOccurrenceInput = struct {
    parent_key: ?[]const u8,
    child_part: []const u8,
    child_revision: []const u8,
    description: ?[]const u8,
    category: ?[]const u8,
    requirement_ids: ?[]const []const u8,
    test_ids: ?[]const []const u8,
    quantity: ?[]const u8,
    ref_designator: ?[]const u8,
    supplier: ?[]const u8,
    purl: ?[]const u8,
    license: ?[]const u8,
    hashes_json: ?[]const u8,
    safety_class: ?[]const u8,
    known_anomalies: ?[]const u8,
    anomaly_evaluation: ?[]const u8,

    pub fn deinit(self: *BomOccurrenceInput, alloc: Allocator) void {
        if (self.parent_key) |value| alloc.free(value);
        alloc.free(self.child_part);
        alloc.free(self.child_revision);
        if (self.description) |value| alloc.free(value);
        if (self.category) |value| alloc.free(value);
        if (self.requirement_ids) |values| freeStringSlice(values, alloc);
        if (self.test_ids) |values| freeStringSlice(values, alloc);
        if (self.quantity) |value| alloc.free(value);
        if (self.ref_designator) |value| alloc.free(value);
        if (self.supplier) |value| alloc.free(value);
        if (self.purl) |value| alloc.free(value);
        if (self.license) |value| alloc.free(value);
        if (self.hashes_json) |value| alloc.free(value);
        if (self.safety_class) |value| alloc.free(value);
        if (self.known_anomalies) |value| alloc.free(value);
        if (self.anomaly_evaluation) |value| alloc.free(value);
    }
};

pub const BomSubmission = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    bom_type: BomType,
    source_format: BomFormat,
    root_key: ?[]const u8,
    occurrences: []BomOccurrenceInput,

    pub fn deinit(self: *BomSubmission, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        if (self.root_key) |value| alloc.free(value);
        for (self.occurrences) |*occurrence| occurrence.deinit(alloc);
        alloc.free(self.occurrences);
    }
};

pub const BomWarning = struct {
    code: []const u8,
    message: []const u8,
    subject: ?[]const u8,

    pub fn deinit(self: *BomWarning, alloc: Allocator) void {
        alloc.free(self.code);
        alloc.free(self.message);
        if (self.subject) |value| alloc.free(value);
    }
};

pub const BomIngestResponse = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    bom_type: BomType,
    source_format: BomFormat,
    inserted_nodes: usize,
    inserted_edges: usize,
    warnings: []BomWarning,

    pub fn deinit(self: *BomIngestResponse, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        for (self.warnings) |*warning| warning.deinit(alloc);
        alloc.free(self.warnings);
    }
};

pub const GroupIngestStatus = enum { ok, failed };

pub const GroupedBomResult = struct {
    full_product_identifier: []const u8,
    bom_name: []const u8,
    rows_ingested: usize,
    inserted_nodes: usize,
    inserted_edges: usize,
    status: GroupIngestStatus,
    error_code: ?[]const u8 = null,
    error_detail: ?[]const u8 = null,
    warnings: []BomWarning,

    pub fn deinit(self: *GroupedBomResult, alloc: Allocator) void {
        alloc.free(self.full_product_identifier);
        alloc.free(self.bom_name);
        if (self.error_code) |value| alloc.free(value);
        if (self.error_detail) |value| alloc.free(value);
        for (self.warnings) |*warning| warning.deinit(alloc);
        alloc.free(self.warnings);
    }
};

pub const GroupedBomIngestResponse = struct {
    groups: []GroupedBomResult,

    pub fn deinit(self: *GroupedBomIngestResponse, alloc: Allocator) void {
        for (self.groups) |*group| group.deinit(alloc);
        alloc.free(self.groups);
    }
};

pub const BomError = error{
    UnsupportedContentType,
    UnsupportedFormat,
    InvalidJson,
    InvalidCsv,
    MissingBomName,
    MissingFullProductIdentifier,
    EmptyBomItems,
    MissingRequiredField,
    NoProductMatch,
    MissingDesignBomTab,
    SbomUnresolvableRoot,
    CircularReference,
};

pub const PreparedBom = struct {
    submission: BomSubmission,
    warnings: std.ArrayList(BomWarning),

    pub fn deinit(self: *PreparedBom, alloc: Allocator) void {
        self.submission.deinit(alloc);
        for (self.warnings.items) |*warning| warning.deinit(alloc);
        self.warnings.deinit(alloc);
    }
};

pub const IngestOptions = struct {
    allow_missing_product: bool = false,
    unresolved_requirement_warning_code: []const u8 = "BOM_UNRESOLVED_REQUIREMENT_REF",
    unresolved_test_warning_code: []const u8 = "BOM_UNRESOLVED_TEST_REF",
    warning_subject_label: []const u8 = "BOM item",
};

pub const ItemSpec = struct {
    part: []const u8,
    revision: []const u8,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    supplier: ?[]const u8 = null,
    requirement_ids: ?[]const []const u8 = null,
    test_ids: ?[]const []const u8 = null,
    purl: ?[]const u8 = null,
    license: ?[]const u8 = null,
    hashes_json: ?[]const u8 = null,
    safety_class: ?[]const u8 = null,
    known_anomalies: ?[]const u8 = null,
    anomaly_evaluation: ?[]const u8 = null,
};

pub const RelationSpec = struct {
    parent_key: ?[]const u8,
    child_key: []const u8,
    quantity: ?[]const u8 = null,
    ref_designator: ?[]const u8 = null,
    supplier: ?[]const u8 = null,
};

pub const TraceLinkCounts = struct {
    declared_requirement_count: usize = 0,
    declared_test_count: usize = 0,
    linked_requirement_count: usize = 0,
    linked_test_count: usize = 0,
    unresolved_requirement_count: usize = 0,
    unresolved_test_count: usize = 0,
};

pub const PartRevision = struct {
    part: []const u8,
    revision: []const u8,

    pub fn deinit(self: PartRevision, alloc: Allocator) void {
        alloc.free(self.part);
        alloc.free(self.revision);
    }
};
