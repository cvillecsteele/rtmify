/// profile.zig — Industry profile definitions for RTMify Live.
///
/// Each profile defines the required traceability chain, specialized gap checks,
/// and which tabs to provision in the spreadsheet.

const std = @import("std");
const graph = @import("rtmify").graph;
const NodeType = graph.NodeType;
const EdgeLabel = graph.EdgeLabel;

pub const GapSeverity = enum { err, warn };

pub const ProfileId = enum {
    medical,
    aerospace,
    automotive,
    generic,
};

pub const ChainStep = struct {
    from_type: NodeType,
    edge_label: EdgeLabel,
    to_type: NodeType,
    required: bool,
    severity: GapSeverity,
    code: u16,
    title: []const u8,
    gap_type: []const u8,
};

pub const SpecialGapKind = enum {
    unimplemented_requirement,
    untested_source_file,
    uncommitted_requirement,
    unattributed_annotation,
    req_without_design_input,
    design_input_without_design_output,
    design_output_without_source,
    design_output_without_config_control,
    hlr_without_llr,
    llr_without_source,
    source_without_structural_coverage,
    missing_asil,
    asil_inheritance,
};

pub const SpecialGapCheck = struct {
    kind: SpecialGapKind,
    severity: GapSeverity,
    code: u16,
    title: []const u8,
};

pub const Profile = struct {
    id: ProfileId,
    name: []const u8,
    chain_steps: []const ChainStep,
    special_checks: []const SpecialGapCheck,
    tabs: []const []const u8,
};

const medical_chain = &[_]ChainStep{
    .{ .from_type = .user_need, .edge_label = .derives_from, .to_type = .requirement, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "orphan_requirement" },
    .{ .from_type = .requirement, .edge_label = .tested_by, .to_type = .test_group, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "untested_requirement" },
    .{ .from_type = .risk, .edge_label = .mitigated_by, .to_type = .requirement, .required = true, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "unmitigated_risk" },
};

const aerospace_chain = &[_]ChainStep{
    .{ .from_type = .user_need, .edge_label = .derives_from, .to_type = .requirement, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "orphan_requirement" },
    .{ .from_type = .requirement, .edge_label = .tested_by, .to_type = .test_group, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "untested_requirement" },
};

const automotive_chain = &[_]ChainStep{
    .{ .from_type = .user_need, .edge_label = .derives_from, .to_type = .requirement, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "orphan_requirement" },
    .{ .from_type = .requirement, .edge_label = .tested_by, .to_type = .test_group, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "untested_requirement" },
    .{ .from_type = .risk, .edge_label = .mitigated_by, .to_type = .requirement, .required = true, .severity = .err, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "unmitigated_risk" },
};

const generic_chain = &[_]ChainStep{};

const medical_special_checks = &[_]SpecialGapCheck{
    .{ .kind = .req_without_design_input, .severity = .err, .code = 1201, .title = "Requirement without design input" },
    .{ .kind = .design_input_without_design_output, .severity = .err, .code = 1202, .title = "Design input without design output" },
    .{ .kind = .design_output_without_source, .severity = .err, .code = 1206, .title = "Traceability chain incomplete" },
    .{ .kind = .design_output_without_config_control, .severity = .err, .code = 1206, .title = "Traceability chain incomplete" },
    .{ .kind = .unimplemented_requirement, .severity = .warn, .code = 1201, .title = "Requirement missing in required chain" },
};

const aerospace_special_checks = &[_]SpecialGapCheck{
    .{ .kind = .hlr_without_llr, .severity = .err, .code = 1203, .title = "High-level requirement without low-level decomposition" },
    .{ .kind = .llr_without_source, .severity = .err, .code = 1206, .title = "Traceability chain incomplete" },
    .{ .kind = .source_without_structural_coverage, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete" },
    .{ .kind = .unimplemented_requirement, .severity = .warn, .code = 1201, .title = "Requirement missing in required chain" },
    .{ .kind = .uncommitted_requirement, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete" },
    .{ .kind = .unattributed_annotation, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete" },
};

const automotive_special_checks = &[_]SpecialGapCheck{
    .{ .kind = .missing_asil, .severity = .err, .code = 1204, .title = "ASIL not specified for safety requirement" },
    .{ .kind = .asil_inheritance, .severity = .err, .code = 1205, .title = "ASIL inheritance violation" },
    .{ .kind = .unimplemented_requirement, .severity = .warn, .code = 1201, .title = "Requirement missing in required chain" },
    .{ .kind = .uncommitted_requirement, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete" },
    .{ .kind = .unattributed_annotation, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete" },
};

const generic_special_checks = &[_]SpecialGapCheck{};

const medical_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks",
    "Design Inputs", "Design Outputs", "Configuration Items",
};

const aerospace_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks", "Configuration Items",
};

const automotive_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks", "Configuration Items",
};

const generic_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks",
};

pub const profiles = [4]Profile{
    .{
        .id = .medical,
        .name = "Medical (ISO 13485 / IEC 62304 / FDA)",
        .chain_steps = medical_chain,
        .special_checks = medical_special_checks,
        .tabs = medical_tabs,
    },
    .{
        .id = .aerospace,
        .name = "Aerospace (AS9100 + DO-178C)",
        .chain_steps = aerospace_chain,
        .special_checks = aerospace_special_checks,
        .tabs = aerospace_tabs,
    },
    .{
        .id = .automotive,
        .name = "Automotive (ISO 26262 + ASPICE)",
        .chain_steps = automotive_chain,
        .special_checks = automotive_special_checks,
        .tabs = automotive_tabs,
    },
    .{
        .id = .generic,
        .name = "Generic",
        .chain_steps = generic_chain,
        .special_checks = generic_special_checks,
        .tabs = generic_tabs,
    },
};

pub fn fromString(s: []const u8) ?ProfileId {
    if (std.ascii.eqlIgnoreCase(s, "medical")) return .medical;
    if (std.ascii.eqlIgnoreCase(s, "aerospace")) return .aerospace;
    if (std.ascii.eqlIgnoreCase(s, "automotive")) return .automotive;
    if (std.ascii.eqlIgnoreCase(s, "generic")) return .generic;
    return null;
}

pub fn get(id: ProfileId) Profile {
    return profiles[@intFromEnum(id)];
}

const testing = std.testing;

test "fromString roundtrip" {
    try testing.expectEqual(ProfileId.medical, fromString("medical").?);
    try testing.expectEqual(ProfileId.aerospace, fromString("aerospace").?);
    try testing.expectEqual(ProfileId.automotive, fromString("automotive").?);
    try testing.expectEqual(ProfileId.generic, fromString("generic").?);
    try testing.expect(fromString("unknown") == null);
}

test "get returns correct profile" {
    const p = get(.medical);
    try testing.expectEqual(ProfileId.medical, p.id);
    try testing.expectEqualStrings("Medical (ISO 13485 / IEC 62304 / FDA)", p.name);
    try testing.expect(p.chain_steps.len > 0);
    try testing.expect(p.tabs.len >= 4);
}

test "automotive profile has no design inputs tab" {
    const p = get(.automotive);
    for (p.tabs) |tab| {
        try testing.expect(!std.mem.eql(u8, tab, "Design Inputs"));
    }
}

test "automotive profile has asil special checks" {
    const p = get(.automotive);
    var found_missing = false;
    var found_inheritance = false;
    for (p.special_checks) |check| {
        if (check.kind == .missing_asil) found_missing = true;
        if (check.kind == .asil_inheritance) found_inheritance = true;
    }
    try testing.expect(found_missing);
    try testing.expect(found_inheritance);
}

test "aerospace profile has refined_by special chain logic" {
    const p = get(.aerospace);
    var found = false;
    for (p.special_checks) |check| {
        if (check.kind == .hlr_without_llr) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "medical profile includes design-chain checks" {
    const p = get(.medical);
    var found_di = false;
    var found_do = false;
    for (p.special_checks) |check| {
        if (check.kind == .req_without_design_input) found_di = true;
        if (check.kind == .design_input_without_design_output) found_do = true;
    }
    try testing.expect(found_di);
    try testing.expect(found_do);
}

test "generic profile has no required chain steps" {
    const p = get(.generic);
    try testing.expectEqual(@as(usize, 0), p.chain_steps.len);
}
