const std = @import("std");
const graph = @import("graph.zig");

const NodeType = graph.NodeType;
const EdgeLabel = graph.EdgeLabel;

pub const GapSeverity = enum { err, warn };

pub const ProfileId = enum {
    medical,
    aerospace,
    automotive,
    generic,
};

pub const Direction = enum {
    outgoing,
    incoming,
};

pub const ChainStep = struct {
    from_type: NodeType,
    edge_label: EdgeLabel,
    to_type: NodeType,
    direction: Direction = .outgoing,
    required: bool,
    severity: GapSeverity,
    code: u16,
    title: []const u8,
    gap_type: []const u8,
    profile_rule: []const u8 = "",
    clause: ?[]const u8 = null,
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
    gap_type: []const u8,
    profile_rule: []const u8 = "",
    clause: ?[]const u8 = null,
};

pub const Profile = struct {
    id: ProfileId,
    short_name: []const u8 = "",
    name: []const u8,
    standards: []const u8 = "",
    chain_steps: []const ChainStep,
    special_checks: []const SpecialGapCheck,
    tabs: []const []const u8,
};

const medical_chain = &[_]ChainStep{
    .{ .from_type = .user_need, .edge_label = .derives_from, .to_type = .requirement, .direction = .incoming, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "orphan_requirement", .profile_rule = "medical_user_need_requirement_chain", .clause = "ISO 13485 §7.3.2" },
    .{ .from_type = .requirement, .edge_label = .tested_by, .to_type = .test_group, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "untested_requirement", .profile_rule = "medical_requirement_verification_chain", .clause = "IEC 62304 §5.7" },
    .{ .from_type = .risk, .edge_label = .mitigated_by, .to_type = .requirement, .required = true, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "unmitigated_risk", .profile_rule = "medical_risk_requirement_chain", .clause = "ISO 14971 §7" },
};

const aerospace_chain = &[_]ChainStep{
    .{ .from_type = .user_need, .edge_label = .derives_from, .to_type = .requirement, .direction = .incoming, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "orphan_requirement", .profile_rule = "aerospace_user_need_requirement_chain", .clause = "AS9100 §8.3.3" },
    .{ .from_type = .requirement, .edge_label = .tested_by, .to_type = .test_group, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "untested_requirement", .profile_rule = "aerospace_requirement_test_chain", .clause = "DO-178C Table A-7" },
};

const automotive_chain = &[_]ChainStep{
    .{ .from_type = .user_need, .edge_label = .derives_from, .to_type = .requirement, .direction = .incoming, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "orphan_requirement", .profile_rule = "automotive_hara_requirement_chain", .clause = "ISO 26262 Part 4 §6" },
    .{ .from_type = .requirement, .edge_label = .tested_by, .to_type = .test_group, .required = true, .severity = .err, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "untested_requirement", .profile_rule = "automotive_requirement_test_chain", .clause = "ISO 26262 Part 6 §9-11" },
    .{ .from_type = .risk, .edge_label = .mitigated_by, .to_type = .requirement, .required = true, .severity = .err, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "unmitigated_risk", .profile_rule = "automotive_hazard_safety_goal_requirement_chain", .clause = "ISO 26262 Part 3 §7" },
};

const generic_chain = &[_]ChainStep{};

const medical_special_checks = &[_]SpecialGapCheck{
    .{ .kind = .req_without_design_input, .severity = .err, .code = 1201, .title = "Requirement without design input", .gap_type = "req_without_design_input", .profile_rule = "iso13485_requirement_design_input_chain", .clause = "ISO 13485 §7.3.3" },
    .{ .kind = .design_input_without_design_output, .severity = .err, .code = 1202, .title = "Design input without design output", .gap_type = "design_input_without_design_output", .profile_rule = "iso13485_di_do_chain", .clause = "ISO 13485 §7.3.4" },
    .{ .kind = .design_output_without_source, .severity = .err, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "design_output_without_source", .profile_rule = "iec62304_design_output_implementation_chain", .clause = "IEC 62304 §5.5" },
    .{ .kind = .design_output_without_config_control, .severity = .err, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "design_output_without_config_control", .profile_rule = "iso13485_design_output_config_control", .clause = "ISO 13485 §7.3.4" },
    .{ .kind = .unimplemented_requirement, .severity = .warn, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "unimplemented_requirement", .profile_rule = "iec62304_requirement_implementation_evidence", .clause = "IEC 62304 §5.5" },
};

const aerospace_special_checks = &[_]SpecialGapCheck{
    .{ .kind = .hlr_without_llr, .severity = .err, .code = 1203, .title = "High-level requirement without low-level decomposition", .gap_type = "hlr_without_llr", .profile_rule = "do178c_hlr_llr_decomposition", .clause = "DO-178C Table A-4" },
    .{ .kind = .llr_without_source, .severity = .err, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "llr_without_source", .profile_rule = "do178c_llr_source_chain", .clause = "DO-178C Table A-5" },
    .{ .kind = .source_without_structural_coverage, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "source_without_structural_coverage", .profile_rule = "do178c_structural_coverage", .clause = "DO-178C §6.4.4" },
    .{ .kind = .unimplemented_requirement, .severity = .warn, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "unimplemented_requirement", .profile_rule = "aerospace_requirement_implementation_evidence", .clause = "DO-178C Table A-5" },
    .{ .kind = .uncommitted_requirement, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "uncommitted_requirement", .profile_rule = "aerospace_commit_traceability", .clause = "AS9100 §8.5.2" },
    .{ .kind = .unattributed_annotation, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "unattributed_annotation", .profile_rule = "aerospace_annotation_attribution", .clause = "AS9100 §7.5" },
};

const automotive_special_checks = &[_]SpecialGapCheck{
    .{ .kind = .missing_asil, .severity = .err, .code = 1204, .title = "ASIL not specified for safety requirement", .gap_type = "missing_asil", .profile_rule = "iso26262_missing_asil", .clause = "ISO 26262 Part 3 §6" },
    .{ .kind = .asil_inheritance, .severity = .err, .code = 1205, .title = "ASIL inheritance violation", .gap_type = "asil_inheritance", .profile_rule = "iso26262_asil_inheritance", .clause = "ISO 26262 Part 9 §5" },
    .{ .kind = .unimplemented_requirement, .severity = .warn, .code = 1201, .title = "Requirement missing in required chain", .gap_type = "unimplemented_requirement", .profile_rule = "automotive_requirement_implementation_evidence", .clause = "ASPICE SWE.3" },
    .{ .kind = .uncommitted_requirement, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "uncommitted_requirement", .profile_rule = "automotive_commit_traceability", .clause = "ASPICE SUP.8" },
    .{ .kind = .unattributed_annotation, .severity = .warn, .code = 1206, .title = "Traceability chain incomplete", .gap_type = "unattributed_annotation", .profile_rule = "automotive_annotation_attribution", .clause = "ASPICE SUP.1" },
};

const generic_special_checks = &[_]SpecialGapCheck{};

const medical_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks",
    "Design Inputs", "Design Outputs", "Configuration Items", "Product",
};

const aerospace_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks", "Configuration Items", "Product", "Decomposition",
};

const automotive_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks", "Configuration Items", "Product",
};

const generic_tabs = &[_][]const u8{
    "User Needs", "Requirements", "Tests", "Risks", "Product",
};

pub const profiles = [4]Profile{
    .{
        .id = .medical,
        .short_name = "medical",
        .name = "Medical",
        .standards = "ISO 13485 / IEC 62304 / FDA",
        .chain_steps = medical_chain,
        .special_checks = medical_special_checks,
        .tabs = medical_tabs,
    },
    .{
        .id = .aerospace,
        .short_name = "aerospace",
        .name = "Aerospace",
        .standards = "AS9100 / DO-178C",
        .chain_steps = aerospace_chain,
        .special_checks = aerospace_special_checks,
        .tabs = aerospace_tabs,
    },
    .{
        .id = .automotive,
        .short_name = "automotive",
        .name = "Automotive",
        .standards = "ISO 26262 / ASPICE",
        .chain_steps = automotive_chain,
        .special_checks = automotive_special_checks,
        .tabs = automotive_tabs,
    },
    .{
        .id = .generic,
        .short_name = "generic",
        .name = "Generic",
        .standards = "Generic",
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

test "medical profile exposes standards and clauses" {
    const p = get(.medical);
    try testing.expectEqualStrings("ISO 13485 / IEC 62304 / FDA", p.standards);
    try testing.expect(p.special_checks[0].clause != null);
}
