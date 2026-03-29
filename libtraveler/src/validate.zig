const std = @import("std");
const types = @import("types.zig");

pub const Heuristics = struct {
    repeated_key_flattening: bool = false,
    header_component_confusion: bool = false,
    footer_boilerplate_capture: bool = false,
};

pub fn classify(alloc: std.mem.Allocator, result: *types.TravelerResult, heuristics: Heuristics) !void {
    if (heuristics.header_component_confusion) {
        return setRejected(alloc, result, .header_component_confusion);
    }
    if (heuristics.footer_boilerplate_capture) {
        return setRejected(alloc, result, .footer_boilerplate_capture);
    }
    if (heuristics.repeated_key_flattening) {
        return setRejected(alloc, result, .repeated_key_flattening);
    }

    if (isMissing(result.header.product_name)) return setRejected(alloc, result, .missing_product_name);
    if (isMissing(result.header.assembly)) return setRejected(alloc, result, .missing_assembly);
    if (isMissing(result.header.serial_number)) return setRejected(alloc, result, .missing_serial_number);
    if (isMissing(result.header.bom_revision)) return setRejected(alloc, result, .missing_bom_revision);
    if (isMissing(result.verification.atp_test_report_id)) return setRejected(alloc, result, .missing_atp_test_report_id);

    if (!looksLikeSerial(result.header.serial_number.?)) return setRejected(alloc, result, .invalid_serial_number_format);
    if (!looksLikeRevision(result.header.bom_revision.?)) return setRejected(alloc, result, .invalid_bom_revision_format);
    if (!looksLikeAtpId(result.verification.atp_test_report_id.?)) return setRejected(alloc, result, .invalid_atp_test_report_id_format);
    if (result.normalized.product_full_identifier == null) return setRejected(alloc, result, .product_full_identifier_not_derivable);

    result.validation.status = .accepted;
    result.validation.rejection_reason = .ok;
    if (result.header.work_order == null or result.header.lot_batch == null or result.header.traveler_date == null) {
        result.validation.warnings = try alloc.dupe(types.WarningCode, &.{.secondary_fields_missing});
    } else {
        result.validation.warnings = &.{};
    }
}

fn setRejected(alloc: std.mem.Allocator, result: *types.TravelerResult, reason: types.RejectionReason) !void {
    result.validation.status = .rejected;
    result.validation.rejection_reason = reason;
    result.validation.warnings = try alloc.dupe(types.WarningCode, &.{});
}

fn isMissing(value: ?[]const u8) bool {
    return value == null or std.mem.trim(u8, value.?, " \t\r\n").len == 0;
}

fn looksLikeSerial(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    if (std.mem.indexOfScalar(u8, value, '\n') != null) return false;
    var saw_alnum = false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            saw_alnum = true;
            continue;
        }
        if (ch == '-' or ch == '_' or ch == '/' or ch == '.') continue;
        return false;
    }
    return saw_alnum;
}

fn looksLikeRevision(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "REV-") and value.len > 4;
}

fn looksLikeAtpId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    var saw_digit = false;
    for (value) |ch| {
        if (std.ascii.isDigit(ch)) saw_digit = true;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '/' or ch == ' ' or ch == '#') continue;
        return false;
    }
    return saw_digit;
}
