const std = @import("std");
const structured_id = @import("../id.zig");
const diagnostic = @import("../diagnostic.zig");
const internal = @import("internal.zig");

const Diagnostics = internal.Diagnostics;
const Row = internal.Row;

pub const un_id_syns = &[_][]const u8{ "User Need ID", "UN ID", "Need ID", "Stakeholder Need ID", "Item #", "Item ID", "Number", "#" };
pub const un_stmt_syns = &[_][]const u8{ "Description", "Need Statement", "User Need", "Need Description", "Requirement Statement" };
pub const un_source_syns = &[_][]const u8{ "Source", "Origin", "Stakeholder", "Customer", "Requestor", "Originator" };
pub const un_pri_syns = &[_][]const u8{ "Importance", "Criticality", "Rank", "Level" };

pub const req_id_syns = &[_][]const u8{ "Requirement ID", "Req ID", "REQ #", "Item ID", "Requirement Number", "Req Number", "Number", "#" };
pub const req_un_syns = &[_][]const u8{ "User Need ID", "User Need iD", "User Need", "Traces To", "Parent Need", "Source Need", "UN ID", "Derived From", "Source", "Stakeholder Need" };
pub const req_stmt_syns = &[_][]const u8{ "Requirement Statement", "Description", "Requirement Text", "Requirement Description", "Req Statement" };
pub const req_pri_syns = &[_][]const u8{ "Importance", "Criticality", "Rank", "Level" };
pub const req_tg_syns = &[_][]const u8{ "Test Group ID", "Test Group", "Verification Method", "Verification ID", "TG ID", "Verified By", "Test Ref", "Verification", "Test ID" };
pub const req_status_syns = &[_][]const u8{ "Status", "State", "Requirement Status", "Lifecycle" };
pub const req_notes_syns = &[_][]const u8{ "Comments", "Remarks", "Additional Notes", "Comment" };

pub const tst_tgid_syns = &[_][]const u8{ "TG ID", "Group ID", "Test Suite ID", "Test Group", "Group", "Suite ID" };
pub const tst_id_syns = &[_][]const u8{ "ID", "Test Number", "Test Case ID", "TC ID", "Test Case", "Case ID" };
pub const tst_type_syns = &[_][]const u8{ "Type", "Verification Type", "Method Type", "Test Category" };
pub const tst_method_syns = &[_][]const u8{ "Method", "Verification Method", "Test Approach", "Approach", "Technique" };

pub const risk_id_syns = &[_][]const u8{ "ID", "Risk Number", "Risk #", "Hazard ID", "FMEA ID", "Risk Item", "Number" };
pub const risk_desc_syns = &[_][]const u8{ "Description", "Risk Description", "Hazard Description", "Risk Statement", "Failure Mode", "Hazard" };
pub const risk_isev_syns = &[_][]const u8{ "Severity", "Initial Sev", "Pre-mitigation Severity", "Sev", "S", "Initial S" };
pub const risk_ilik_syns = &[_][]const u8{ "Likelihood", "Initial Lik", "Probability", "Pre-mitigation Likelihood", "Prob", "Occurrence", "P", "Initial P" };
pub const risk_mit_syns = &[_][]const u8{ "Mitigation", "Control", "Risk Control", "Mitigation Action", "Risk Treatment", "Control Measure", "Action" };
pub const risk_req_syns = &[_][]const u8{ "Linked Requirement", "Mitigating Requirement", "Control Requirement", "REQ ID", "Requirement ID", "Mitigated By", "Linked REQ ID", "Linked REQ" };
pub const risk_rsev_syns = &[_][]const u8{ "Residual Severity", "Residual Sev", "Post-mitigation Severity", "RS", "Res Sev" };
pub const risk_rlik_syns = &[_][]const u8{ "Residual Likelihood", "Residual Lik", "Post-mitigation Likelihood", "RP", "Residual Occurrence", "Res Lik" };

pub const di_id_syns = &[_][]const u8{ "DI ID", "Design Input ID", "Input ID", "Item ID", "Number", "#" };
pub const di_desc_syns = &[_][]const u8{ "Description", "Design Input", "Input Description", "Requirement Statement", "Statement" };
pub const di_src_req_syns = &[_][]const u8{ "Source Requirement", "Source REQ", "REQ ID", "Requirement ID", "Linked Requirement", "Traces To" };
pub const di_status_syns = &[_][]const u8{ "Status", "State", "Lifecycle", "Design Input Status" };

pub const do_id_syns = &[_][]const u8{ "DO ID", "Design Output ID", "Output ID", "Item ID", "Number", "#" };
pub const do_desc_syns = &[_][]const u8{ "Description", "Design Output", "Output Description", "Artifact Description", "Statement" };
pub const do_type_syns = &[_][]const u8{ "Type", "Artifact Type", "Output Type", "Category" };
pub const do_di_syns = &[_][]const u8{ "Design Input ID", "DI ID", "Source Design Input", "Input ID", "Linked DI" };
pub const do_ver_syns = &[_][]const u8{ "Version", "Rev", "Revision", "Document Version", "Ver" };
pub const do_status_syns = &[_][]const u8{ "Status", "State", "Lifecycle", "Design Output Status" };

pub const ci_id_syns = &[_][]const u8{ "CI ID", "Config Item ID", "Item ID", "Configuration Item ID", "Number", "#" };
pub const ci_desc_syns = &[_][]const u8{ "Description", "Config Item", "Item Description", "Configuration Item", "Component" };
pub const ci_type_syns = &[_][]const u8{ "Type", "Item Type", "Component Type", "Category" };
pub const ci_ver_syns = &[_][]const u8{ "Version", "Rev", "Revision", "Item Version", "Ver" };
pub const ci_do_syns = &[_][]const u8{ "Design Output ID", "DO ID", "Linked DO", "Source DO", "Output ID" };
pub const ci_status_syns = &[_][]const u8{ "Status", "State", "Lifecycle", "CI Status" };

pub const product_assembly_syns = &[_][]const u8{ "Assembly", "Part Number", "Part No", "PN", "Assembly Number" };
pub const product_revision_syns = &[_][]const u8{ "Revision", "Rev", "Version" };
pub const product_identifier_syns = &[_][]const u8{ "Full Identifier", "Full ID", "Canonical Identifier", "Configuration Identifier" };
pub const product_description_syns = &[_][]const u8{ "Description", "Product Description", "Name" };
pub const product_status_syns = &[_][]const u8{ "Status", "Lifecycle Status", "Configuration Status" };

pub const decomposition_parent_syns = &[_][]const u8{ "Parent ID", "Parent Requirement", "Parent Req ID", "HLR ID", "High-Level Requirement" };
pub const decomposition_child_syns = &[_][]const u8{ "Child ID", "Child Requirement", "Child Req ID", "LLR ID", "Low-Level Requirement" };

pub fn resolveCol(
    headers: Row,
    data_rows: []const Row,
    canonical: []const u8,
    synonyms: []const []const u8,
    tab_name: []const u8,
    diag: *Diagnostics,
    is_id_col: bool,
) ?usize {
    var found: ?usize = null;
    var found_label: []const u8 = canonical;
    var ambig_count: usize = 0;

    for (headers, 0..) |h, i| {
        const ht = std.mem.trim(u8, h, " \t");
        if (std.ascii.eqlIgnoreCase(ht, canonical)) {
            if (found == null) {
                found = i;
            } else {
                ambig_count += 1;
                if (i < found.?) found = i;
            }
        }
    }
    if (found != null) {
        if (ambig_count > 0) diag.warn(diagnostic.E.column_ambiguous, .column_mapping, tab_name, null,
            "multiple columns match '{s}'; using leftmost (col {d})", .{ canonical, found.? + 1 }) catch {};
        return found;
    }

    for (synonyms) |syn| {
        for (headers, 0..) |h, i| {
            const ht = std.mem.trim(u8, h, " \t");
            if (std.ascii.eqlIgnoreCase(ht, syn)) {
                if (found == null) {
                    found = i;
                    found_label = syn;
                } else if (i < found.?) {
                    found = i;
                    found_label = syn;
                    ambig_count += 1;
                } else {
                    ambig_count += 1;
                }
            }
        }
    }
    if (found != null) {
        if (ambig_count > 0) {
            diag.warn(diagnostic.E.column_ambiguous, .column_mapping, tab_name, null,
                "multiple columns match '{s}' field; using leftmost", .{ canonical }) catch {};
        } else {
            diag.info(diagnostic.E.column_synonym_match, .column_mapping, tab_name, null,
                "'{s}' column matched by synonym '{s}'", .{ canonical, found_label }) catch {};
        }
        return found;
    }

    if (is_id_col and data_rows.len > 0) {
        const col_count = headers.len;
        var best_col: ?usize = null;
        var best_score: usize = 0;
        for (0..col_count) |ci| {
            var matches: usize = 0;
            for (data_rows) |row| {
                if (ci < row.len and structured_id.looksLikeStructuredIdForInference(row[ci])) matches += 1;
            }
            if (matches > data_rows.len / 2 and matches > best_score) {
                best_score = matches;
                best_col = ci;
            }
        }
        if (best_col) |bc| {
            diag.warn(diagnostic.E.id_column_guessed, .column_mapping, tab_name, null,
                "ID column not found by name; guessing column {d} from data pattern", .{ bc + 1 }) catch {};
            return bc;
        }
        diag.warn(diagnostic.E.id_column_missing, .column_mapping, tab_name, null,
            "ID column not found for '{s}' tab; rows will be skipped", .{ tab_name }) catch {};
    }

    return null;
}
