const std = @import("std");
const internal = @import("internal.zig");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");
const workbooks = @import("workbooks.zig");

pub fn promptsListResult(alloc: internal.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"prompts\":{s}}}", .{protocol.prompts_json});
}

pub fn promptGetResult(name: []const u8, args: ?std.json.Value, req_ctx: *const internal.RequestContext, runtime_ctx: *const internal.RuntimeContext) ![]u8 {
    _ = runtime_ctx;
    const alloc = req_ctx.alloc;
    const body = if (std.mem.eql(u8, name, "trace_requirement")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Trace requirement {s} using RTMify. Read requirement://{s} and design-history://{s}. Pay attention to Effective Text, Text Status, Authoritative Source, and Source Assertions. If needed, call commit_history with req_id={s} and code_traceability. Produce sections: Overview, Source Provenance, Upstream Need, Verification, Risks, Code & Commits, Chain Gaps, and Open Questions. Keep the output concise and call out any missing links explicitly.", .{ id, id, id, id });
    } else if (std.mem.eql(u8, name, "trace_design_artifact")) blk: {
        const artifact_id = try tools.requireStringArg(args, "artifact_id");
        break :blk try std.fmt.allocPrint(alloc, "Inspect design artifact {s} using RTMify. Read {s} and artifacts://. Return sections: Artifact Overview, Extracted Assertions, Conflicts or Null Text, Impacted Requirements, and Recommended Next Checks. Answer directly whether this artifact has extraction conflicts before adding detail.", .{ artifact_id, artifact_id });
    } else if (std.mem.eql(u8, name, "trace_user_need")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Trace user need {s} using RTMify. Read user-need://{s} and impact://{s}. If needed, call get_user_needs, chain_gaps, and get_rtm to confirm downstream requirement and verification coverage. Produce sections: Overview, Derived Requirements, Verification Coverage, Risks, Chain Gaps, and Open Questions. Answer directly which requirements hang off this user need before adding extra commentary.", .{ id, id, id });
    } else if (std.mem.eql(u8, name, "trace_test")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Trace test artifact {s} using RTMify. Read test://{s}; if that is not found, read test-group://{s}. Call get_tests to confirm linked requirements. If {s} looks like a concrete test case, also call get_test_results with test_case_ref={s}. Return sections: Overview, Linked Requirements, Latest Execution Evidence, Coverage Concerns, and Open Questions. Answer directly what this test verifies before adding detail.", .{ id, id, id, id, id });
    } else if (std.mem.eql(u8, name, "trace_risk")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Trace risk {s} using RTMify. Read risk://{s} and impact://{s}. Call get_risks for structured fields if needed. Return sections: Overview, Linked Requirements, Mitigations and Verification Evidence, Residual Exposure, and Open Questions. Make it explicit whether the graph shows the risk as open, mitigated, or only partially evidenced.", .{ id, id, id });
    } else if (std.mem.eql(u8, name, "trace_unit")) blk: {
        const serial_number = try tools.requireStringArg(args, "serial_number");
        break :blk try std.fmt.allocPrint(alloc, "Trace production unit {s} using RTMify. First call get_unit_history with serial_number={s}. If execution IDs are returned, call get_execution for the most important one. Return sections: Overview, Product, Execution Timeline, Failed or Notable Tests, and Recommended Next Checks. Answer directly whether this unit passed or failed before adding detail.", .{ serial_number, serial_number });
    } else if (std.mem.eql(u8, name, "which_requirements_for_user_need")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Answer which requirements derive from user need {s}. Read user-need://{s} first. If needed, call get_user_needs or get_rtm to confirm exact requirement IDs. Return the derived requirements first as a direct answer, then add a short note on coverage or gaps only if relevant.", .{ id, id });
    } else if (std.mem.eql(u8, name, "which_tests_for_requirement")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Summarize verification evidence for requirement {s}. Read requirement://{s} and call get_verification_status with requirement_ref={s}. If needed, call get_test_results for the most important linked tests. Return sections: Requirement, Linked Tests, Latest Results, Verification Gaps, and Confidence. Answer the current verification status first, then explain missing or stale evidence.", .{ id, id, id });
    } else if (std.mem.eql(u8, name, "product_execution_summary")) blk: {
        const full_product_identifier = try tools.requireStringArg(args, "full_product_identifier");
        break :blk try std.fmt.allocPrint(alloc, "Summarize known serial-bearing execution history for product {s}. Read serials://{s} and call get_product_serials with full_product_identifier={s}. Return sections: Known Serials, Latest Status Pattern, Failed Units, and Suggested Drill-Downs. Answer directly how many serial-bearing executions are known before adding detail.", .{ full_product_identifier, full_product_identifier, full_product_identifier });
    } else if (std.mem.eql(u8, name, "open_risk_summary")) blk: {
        break :blk try alloc.dupe(u8, "Summarize risks that remain open in RTMify. Call get_risks and focus on risks whose status is open or not fully mitigated. If needed, read risk://<id> and impact://<id> for the highest-risk items. Return sections: Open Risks, Residual Severity/Likelihood, Verification Exposure, and Recommended Next Checks. Answer directly how many open risks exist before adding detail.");
    } else if (std.mem.eql(u8, name, "part_blast_radius")) blk: {
        const part = try tools.requireStringArg(args, "part");
        break :blk try std.fmt.allocPrint(alloc, "Assess blast radius for part {s}. First call find_part_usage with part={s}. Then call bom_impact_analysis or get_bom_item for the most important affected BOMs/items, and read design-bom resources when available. Return sections: Where Used, What Breaks or Needs Review, Requirement/Test Exposure, and Recommended Next Checks. Treat this as broader operational impact, not just formal EOL status.", .{ part, part });
    } else if (std.mem.eql(u8, name, "soup_component_review")) blk: {
        const full_product_identifier = try tools.requireStringArg(args, "full_product_identifier");
        const part = try tools.requireStringArg(args, "part");
        const bom_name = if (args) |a| internal.json_util.getString(a, "bom_name") else null;
        const revision = if (args) |a| internal.json_util.getString(a, "revision") else null;
        break :blk try std.fmt.allocPrint(alloc, "Review SOUP component {s} for product {s}. Call get_soup_components with full_product_identifier={s} bom_name={s}. If revision={s} is provided, prefer the matching component version. If you can construct an exact resource, read soup-component://{s}/{s}/{s}@{s}. Return sections: Component Overview, Version and License, Known Anomalies and Evaluation, Requirement/Test Links, and Audit Concerns. Answer directly whether the component looks adequately documented before adding detail.", .{
            part,
            full_product_identifier,
            full_product_identifier,
            bom_name orelse internal.soup.default_bom_name,
            revision orelse "*",
            full_product_identifier,
            bom_name orelse internal.soup.default_bom_name,
            part,
            revision orelse "*",
        });
    } else if (std.mem.eql(u8, name, "requirement_change_review")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Review fallout from a requirement change for {s}. Read requirement://{s}, design-history://{s}, and impact://{s}. Pay attention to source provenance and any source conflicts. Call get_verification_status with requirement_ref={s}; if the node is suspect or has recent test evidence, call chain_gaps and get_test_results as needed. Return sections: Change Summary, Source Provenance, Impacted Items, Potentially Stale Verification, Open Gaps, and Recommended Next Checks. Answer directly what appears stale or newly suspect before adding detail.", .{ id, id, id, id, id });
    } else if (std.mem.eql(u8, name, "impact_of_change")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Analyze the downstream impact of changing node {s}. Read impact://{s}. If the node is a requirement, also read requirement://{s}. Return: Summary, Directly Impacted Items, Likely Verification Fallout, and Suggested Next Checks. Distinguish real traceability impact from missing-data uncertainty.", .{ id, id, id });
    } else if (std.mem.eql(u8, name, "explain_gap")) blk: {
        const code = try tools.requireIntArg(args, "code");
        const node_id = try tools.requireStringArg(args, "node_id");
        break :blk try std.fmt.allocPrint(alloc, "Explain RTMify gap {d} for node {s}. Read gap://{d}/{s} and node://{s}. Return sections: What RTMify Checked, Why This Gap Exists, What To Inspect Next, and Likely Resolution. State whether this looks like a real model gap or a data-entry / ingestion issue.", .{ code, node_id, code, node_id, node_id });
    } else if (std.mem.eql(u8, name, "audit_readiness_summary")) blk: {
        const profile = try tools.requireStringArg(args, "profile");
        break :blk try std.fmt.allocPrint(alloc, "Summarize RTMify audit readiness for the {s} profile. Read report://status, report://chain-gaps, report://rtm, and report://review. If design artifacts exist, read artifacts:// for provenance/conflict context. Call chain_gaps with profile={s} if you need detail. Return: Current State, Critical Gaps, Source-Provenance Risks, Evidence Strength, and Top 3 Next Actions.", .{ profile, profile });
    } else if (std.mem.eql(u8, name, "repo_coverage_summary")) blk: {
        const repo_note = if (args) |a| internal.json_util.getString(a, "repo") else null;
        if (repo_note) |repo| {
            break :blk try std.fmt.allocPrint(alloc, "Summarize repository-backed traceability coverage for repo {s}. Call code_traceability with repo={s}. Also call unimplemented_requirements and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.", .{ repo, repo });
        }
        break :blk try alloc.dupe(u8, "Summarize repository-backed traceability coverage across all configured repos. Call code_traceability, unimplemented_requirements, and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.");
    } else if (std.mem.eql(u8, name, "design_history_summary")) blk: {
        const req_id = try tools.requireStringArg(args, "req_id");
        break :blk try std.fmt.allocPrint(alloc, "Summarize design history for requirement {s}. Read design-history://{s} and requirement://{s}. Return: Requirement, Source Provenance, Upstream Need, Design Inputs/Outputs, Configuration Control, Verification, Commits, and Open Traceability Gaps.", .{ req_id, req_id, req_id });
    } else if (std.mem.eql(u8, name, "inspect_bom_item_traceability")) blk: {
        const item_id = try bomItemSelectorArg(args, alloc);
        defer alloc.free(item_id);
        break :blk try std.fmt.allocPrint(alloc, "Inspect BOM item traceability for {s}. First call get_bom_item with id={s}. Then read bom-item://{s}. Distinguish declared requirement_ids/test_ids from resolved links. Return sections: Item, Parent Chain, Linked Requirements, Linked Tests, Unresolved Declared Refs, and Recommended Fixes. If unresolved IDs exist, say whether the issue is more likely a bad BOM export value or a missing synced Requirement/Test node.", .{ item_id, item_id, item_id });
    } else if (std.mem.eql(u8, name, "eol_impact")) blk: {
        const part = try tools.requireStringArg(args, "part");
        break :blk try std.fmt.allocPrint(alloc, "Assess end-of-life impact for part {s}. First call find_part_usage with part={s}. For each important BOM, read the corresponding design-bom resource if one is returned or call get_bom/get_bom_item as needed. Return sections: Where Used, Product Impact, Requirement/Test Coverage at Risk, and Recommended Next Checks. Separate actual usage evidence from assumptions about substitutes.", .{ part, part });
    } else if (std.mem.eql(u8, name, "bom_coverage")) blk: {
        const full_product_identifier = if (args) |a| internal.json_util.getString(a, "full_product_identifier") else null;
        const bom_name = if (args) |a| internal.json_util.getString(a, "bom_name") else null;
        if (full_product_identifier != null or bom_name != null) {
            break :blk try std.fmt.allocPrint(alloc, "Summarize Design BOM coverage for product={s} bom_name={s}. Call list_design_boms, bom_gaps, and bom_impact_analysis using the same filters. If a matching resource exists, read design-bom://{s}/{s}. Return: BOM Scope, Linked Requirements, Linked Tests, Unresolved Refs, and Highest-Risk Gaps.", .{
                full_product_identifier orelse "*",
                bom_name orelse "*",
                full_product_identifier orelse "*",
                bom_name orelse "*",
            });
        }
        break :blk try alloc.dupe(u8, "Summarize overall Design BOM traceability coverage. Call list_design_boms and bom_gaps. For the most important BOMs, call bom_impact_analysis. Return: BOM Inventory, Coverage Patterns, Unresolved Ref Hotspots, and Recommended Next Fixes.");
    } else if (std.mem.eql(u8, name, "component_substitute")) blk: {
        const part = try tools.requireStringArg(args, "part");
        break :blk try std.fmt.allocPrint(alloc, "Evaluate substitute risk for part {s}. First call find_part_usage with part={s}. Then inspect the most important affected items with get_bom_item. Return sections: Current Usage, Trace Links Potentially Affected, Verification/Requirement Exposure, and Questions Before Approving a Substitute. Do not assume interchangeability unless the graph explicitly supports it.", .{ part, part });
    } else if (std.mem.eql(u8, name, "soup_audit_prep")) blk: {
        const full_product_identifier = if (args) |a| internal.json_util.getString(a, "full_product_identifier") else null;
        const bom_name = if (args) |a| internal.json_util.getString(a, "bom_name") else null;
        break :blk try std.fmt.allocPrint(alloc, "Prepare a SOUP audit summary. Call list_software_boms with full_product_identifier={s} bom_name={s}. Then call get_soup_components and bom_gaps for the most relevant SOUP register. If available, read soup-components://{s}/{s}. Return sections: Inventory, Anomaly Documentation, Requirement/Test Linkage, Unresolved Refs, and Audit Risks. Make the canonical-source rule explicit if the same BOM could also come from CycloneDX/SPDX.", .{
            full_product_identifier orelse "*",
            bom_name orelse "*",
            full_product_identifier orelse "*",
            bom_name orelse internal.soup.default_bom_name,
        });
    } else if (std.mem.eql(u8, name, "soup_coverage")) blk: {
        const full_product_identifier = if (args) |a| internal.json_util.getString(a, "full_product_identifier") else null;
        const bom_name = if (args) |a| internal.json_util.getString(a, "bom_name") else null;
        break :blk try std.fmt.allocPrint(alloc, "Summarize SOUP coverage for product={s} bom_name={s}. Call list_software_boms, get_soup_components, soup_by_license, and bom_gaps. Return sections: Component Inventory, Safety Classes, Licenses, Requirement/Test Coverage, and Highest-Risk Gaps. Call out items with unknown version or missing anomaly evaluation explicitly.", .{
            full_product_identifier orelse "*",
            bom_name orelse "*",
        });
    } else return error.NotFound;
    defer alloc.free(body);
    const heading = try workbooks.workbookHeading(req_ctx.registry, alloc);
    defer alloc.free(heading);
    const contextual_body = try std.fmt.allocPrint(alloc, "{s}{s}", .{ heading, body });
    defer alloc.free(contextual_body);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"description\":");
    try internal.json_util.appendJsonQuoted(&buf, name, alloc);
    try buf.appendSlice(alloc, ",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
    try internal.json_util.appendJsonQuoted(&buf, contextual_body, alloc);
    try buf.appendSlice(alloc, "}}]}");
    return alloc.dupe(u8, buf.items);
}

fn bomItemSelectorArg(args: ?std.json.Value, alloc: internal.Allocator) ![]u8 {
    const a = args orelse return error.InvalidArgument;
    if (internal.json_util.getString(a, "id")) |value| {
        return alloc.dupe(u8, value);
    }
    const full_product_identifier = internal.json_util.getString(a, "full_product_identifier") orelse return error.InvalidArgument;
    const bom_type = internal.json_util.getString(a, "bom_type") orelse return error.InvalidArgument;
    const bom_name = internal.json_util.getString(a, "bom_name") orelse return error.InvalidArgument;
    const part = internal.json_util.getString(a, "part") orelse return error.InvalidArgument;
    const revision = internal.json_util.getString(a, "revision") orelse return error.InvalidArgument;
    return std.fmt.allocPrint(alloc, "bom-item://{s}/{s}/{s}/{s}@{s}", .{
        full_product_identifier,
        bom_type,
        bom_name,
        part,
        revision,
    });
}
