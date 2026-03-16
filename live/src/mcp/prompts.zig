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
