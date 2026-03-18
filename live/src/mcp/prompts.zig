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
        break :blk try std.fmt.allocPrint(alloc, "Trace requirement {s} using RTMify. Read requirement://{s} and design-history://{s}. If needed, call commit_history with req_id={s} and code_traceability. Produce sections: Overview, Upstream Need, Verification, Risks, Code & Commits, Chain Gaps, and Open Questions. Keep the output concise and call out any missing links explicitly.", .{ id, id, id, id });
    } else if (std.mem.eql(u8, name, "impact_of_change")) blk: {
        const id = try tools.requireStringArg(args, "id");
        break :blk try std.fmt.allocPrint(alloc, "Analyze the downstream impact of changing node {s}. Read impact://{s}. If the node is a requirement, also read requirement://{s}. Return: Summary, Directly Impacted Items, Likely Verification Fallout, and Suggested Next Checks. Distinguish real traceability impact from missing-data uncertainty.", .{ id, id, id });
    } else if (std.mem.eql(u8, name, "explain_gap")) blk: {
        const code = try tools.requireIntArg(args, "code");
        const node_id = try tools.requireStringArg(args, "node_id");
        break :blk try std.fmt.allocPrint(alloc, "Explain RTMify gap {d} for node {s}. Read gap://{d}/{s} and node://{s}. Return sections: What RTMify Checked, Why This Gap Exists, What To Inspect Next, and Likely Resolution. State whether this looks like a real model gap or a data-entry / ingestion issue.", .{ code, node_id, code, node_id, node_id });
    } else if (std.mem.eql(u8, name, "audit_readiness_summary")) blk: {
        const profile = try tools.requireStringArg(args, "profile");
        break :blk try std.fmt.allocPrint(alloc, "Summarize RTMify audit readiness for the {s} profile. Read report://status and report://chain-gaps. Call chain_gaps with profile={s} if you need detail. Return: Current State, Critical Gaps, Medium Gaps, Evidence Strength, and Top 3 Next Actions.", .{ profile, profile });
    } else if (std.mem.eql(u8, name, "repo_coverage_summary")) blk: {
        const repo_note = if (args) |a| internal.json_util.getString(a, "repo") else null;
        if (repo_note) |repo| {
            break :blk try std.fmt.allocPrint(alloc, "Summarize repository-backed traceability coverage for repo {s}. Call code_traceability with repo={s}. Also call unimplemented_requirements and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.", .{ repo, repo });
        }
        break :blk try alloc.dupe(u8, "Summarize repository-backed traceability coverage across all configured repos. Call code_traceability, unimplemented_requirements, and untested_source_files. Return: Coverage Summary, Gaps, Notable Files, and Recommended Next Steps.");
    } else if (std.mem.eql(u8, name, "design_history_summary")) blk: {
        const req_id = try tools.requireStringArg(args, "req_id");
        break :blk try std.fmt.allocPrint(alloc, "Summarize design history for requirement {s}. Read design-history://{s}. Return: Requirement, Upstream Need, Design Inputs/Outputs, Configuration Control, Verification, Commits, and Open Traceability Gaps.", .{ req_id, req_id });
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
