const std = @import("std");

pub const ValidationStatus = enum {
    accepted,
    rejected,
    normalization_gap,
};

pub const RejectionReason = enum {
    ok,
    missing_product_name,
    missing_serial_number,
    missing_assembly,
    missing_bom_revision,
    missing_join_fields,
    missing_atp_test_report_id,
    invalid_serial_number_format,
    invalid_bom_revision_format,
    invalid_atp_test_report_id_format,
    product_full_identifier_not_derivable,
    product_full_identifier_mismatch,
    header_component_confusion,
    section_misclassification,
    footer_boilerplate_capture,
    repeated_key_flattening,
    handwriting_unreadable,
    conflicting_field_values,
    hallucinated_value,
    structurally_invalid_json,
    unsupported_layout,
    low_confidence_reject,
    normalization_rule_gap,
    unknown_error,
};

pub const WarningCode = enum {
    secondary_fields_missing,
    footer_noise_ignored,
};

pub const Header = struct {
    product_name: ?[]u8 = null,
    serial_number: ?[]u8 = null,
    assembly: ?[]u8 = null,
    bom_revision: ?[]u8 = null,
    work_order: ?[]u8 = null,
    lot_batch: ?[]u8 = null,
    traveler_date: ?[]u8 = null,

    pub fn deinit(self: *Header, alloc: std.mem.Allocator) void {
        inline for (.{ &self.product_name, &self.serial_number, &self.assembly, &self.bom_revision, &self.work_order, &self.lot_batch, &self.traveler_date }) |field| {
            if (field.*) |value| alloc.free(value);
        }
        self.* = undefined;
    }
};

pub const Verification = struct {
    atp_test_report_id: ?[]u8 = null,
    final_disposition: ?[]u8 = null,
    rework_ncr_number: ?[]u8 = null,

    pub fn deinit(self: *Verification, alloc: std.mem.Allocator) void {
        inline for (.{ &self.atp_test_report_id, &self.final_disposition, &self.rework_ncr_number }) |field| {
            if (field.*) |value| alloc.free(value);
        }
        self.* = undefined;
    }
};

pub const Normalized = struct {
    product_full_identifier: ?[]u8 = null,

    pub fn deinit(self: *Normalized, alloc: std.mem.Allocator) void {
        if (self.product_full_identifier) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const ValidationSummary = struct {
    status: ValidationStatus = .rejected,
    rejection_reason: RejectionReason = .unknown_error,
    warnings: []WarningCode = &.{},

    pub fn deinit(self: *ValidationSummary, alloc: std.mem.Allocator) void {
        if (self.warnings.len > 0) {
            alloc.free(self.warnings);
        }
        self.* = undefined;
    }
};

pub const TravelerResult = struct {
    header: Header = .{},
    normalized: Normalized = .{},
    verification: Verification = .{},
    validation: ValidationSummary = .{},
    raw_response_text: []u8,

    pub fn deinit(self: *TravelerResult, alloc: std.mem.Allocator) void {
        self.header.deinit(alloc);
        self.normalized.deinit(alloc);
        self.verification.deinit(alloc);
        self.validation.deinit(alloc);
        alloc.free(self.raw_response_text);
        self.* = undefined;
    }
};
