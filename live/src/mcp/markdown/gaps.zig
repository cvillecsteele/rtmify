const std = @import("std");

const internal = @import("../internal.zig");
const common = @import("common.zig");

pub const GapExplanation = struct {
    check: []const u8,
    why: []const u8,
    inspect: []const u8,
};

pub fn gapExplanationMarkdown(code: u16, node_id: []const u8, db: *internal.graph_live.GraphDb, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleChainGaps(db, profile_name, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.NotFound;
    var found: ?std.json.Value = null;
    for (parsed.value.array.items) |item| {
        const item_code = if (internal.json_util.getObjectField(item, "code")) |v| switch (v) {
            .integer => v.integer,
            else => -1,
        } else -1;
        const item_node = internal.json_util.getString(item, "node_id") orelse continue;
        if (item_code == code and std.mem.eql(u8, item_node, node_id)) {
            found = item;
            break;
        }
    }
    const gap = found orelse return error.NotFound;
    return markdownFromGap(gap, profile_name, alloc);
}

pub fn markdownFromGap(gap: std.json.Value, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    const code = common.getIntField(gap, "code") orelse 0;
    const title = internal.json_util.getString(gap, "title") orelse "Gap";
    const gap_type = internal.json_util.getString(gap, "gap_type") orelse "gap";
    const node_id = internal.json_util.getString(gap, "node_id") orelse "unknown";
    const severity = internal.json_util.getString(gap, "severity") orelse "info";
    const message = internal.json_util.getString(gap, "message") orelse "";
    const expl = explainGap(gap_type, node_id, profile_name);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# [{d}] {s}\n\n", .{ code, title });
    try std.fmt.format(buf.writer(alloc), "- Node: `{s}`\n- Severity: {s}\n- Profile: {s}\n- Type: `{s}`\n\n", .{ node_id, severity, profile_name, gap_type });
    try std.fmt.format(buf.writer(alloc), "{s}\n\n", .{message});
    try std.fmt.format(buf.writer(alloc), "## What RTMify Checked\n{s}\n\n", .{expl.check});
    try std.fmt.format(buf.writer(alloc), "## Why You’re Seeing It\n{s}\n\n", .{expl.why});
    try std.fmt.format(buf.writer(alloc), "## What To Inspect\n{s}\n", .{expl.inspect});
    return alloc.dupe(u8, buf.items);
}

pub fn explainGap(gap_type: []const u8, node_id: []const u8, profile_name: []const u8) GapExplanation {
    _ = profile_name;
    if (std.mem.eql(u8, gap_type, "orphan_requirement")) {
        if (std.mem.startsWith(u8, node_id, "UN-")) return .{
            .check = "RTMify looked for downstream Requirements linked to this User Need.",
            .why = "No requirement currently derives from this user need in the graph.",
            .inspect = "Check the Requirements tab for a row whose User Need ID cell contains this exact user-need ID.",
        };
        return .{
            .check = "RTMify checked for the next required edge in the active profile chain.",
            .why = "That expected traceability step is absent in the graph.",
            .inspect = "Open the source tab for this artifact and verify the expected upstream or downstream link is present.",
        };
    }
    if (std.mem.eql(u8, gap_type, "hlr_without_llr")) return .{
        .check = "RTMify identified this requirement as deriving from a User Need, then looked for downstream lower-level Requirements.",
        .why = "It has no downstream lower-level requirements.",
        .inspect = "Add lower-level requirements and REFINED_BY links, or use a less strict profile if you intentionally model one requirement level.",
    };
    if (std.mem.eql(u8, gap_type, "llr_without_source")) return .{
        .check = "RTMify found a decomposed requirement and then looked for current source implementation evidence.",
        .why = "The decomposition exists, but RTMify cannot see code that currently implements this lower-level requirement.",
        .inspect = "Verify repo scanning and code annotations are linking this requirement to the right source files.",
    };
    if (std.mem.eql(u8, gap_type, "unimplemented_requirement")) return .{
        .check = "RTMify looked for current source implementation evidence linked to the requirement.",
        .why = "RTMify cannot see code that currently appears to implement this requirement.",
        .inspect = "Confirm implementation exists and code annotations are linking the requirement to source files.",
    };
    if (std.mem.eql(u8, gap_type, "uncommitted_requirement")) return .{
        .check = "RTMify found current implementation evidence and then looked for commits whose messages explicitly referenced the requirement.",
        .why = "Implementation evidence exists, but no commit message explicitly names this requirement.",
        .inspect = "Check git scan results and whether commit messages were linked to this requirement.",
    };
    if (std.mem.eql(u8, gap_type, "unattributed_annotation")) return .{
        .check = "RTMify found a requirement tag in code and then asked git who last changed that line.",
        .why = "The requirement tag exists, but git did not provide usable blame data for that line.",
        .inspect = "Check git blame availability and whether the file is tracked and readable.",
    };
    if (std.mem.eql(u8, gap_type, "req_without_design_input")) return .{
        .check = "RTMify looked for ALLOCATED_TO from the requirement to a design input.",
        .why = "The requirement is not allocated to any design input.",
        .inspect = "Check the Design Inputs tab and linked requirement IDs.",
    };
    if (std.mem.eql(u8, gap_type, "design_input_without_design_output")) return .{
        .check = "RTMify looked for SATISFIED_BY from the design input to a design output.",
        .why = "The design input is not satisfied by any design output.",
        .inspect = "Check the Design Outputs tab and whether it references this design input.",
    };
    if (std.mem.eql(u8, gap_type, "design_output_without_source")) return .{
        .check = "RTMify looked for current source implementation evidence linked to the design output.",
        .why = "The design output has no source implementation evidence in the current graph.",
        .inspect = "Check repo scanning, code annotations, and design output IDs.",
    };
    if (std.mem.eql(u8, gap_type, "design_output_without_config_control")) return .{
        .check = "RTMify looked for CONTROLLED_BY from the design output to a configuration item.",
        .why = "The design output is not under configuration control in the current graph.",
        .inspect = "Check the Configuration Items tab and linked design output IDs.",
    };
    if (std.mem.eql(u8, gap_type, "source_without_structural_coverage")) return .{
        .check = "RTMify found this source file as current implementation evidence and then looked for current test evidence tied to it.",
        .why = "RTMify can see code that appears to implement the requirement, but it cannot see tests that currently verify that code.",
        .inspect = "Check whether a test file should be linked and whether repo annotations captured it.",
    };
    if (std.mem.eql(u8, gap_type, "missing_asil")) return .{
        .check = "RTMify checked whether the automotive requirement has an asil property.",
        .why = "ASIL is required by the current profile for this requirement.",
        .inspect = "Add or correct the asil property in the requirement row.",
    };
    if (std.mem.eql(u8, gap_type, "asil_inheritance")) return .{
        .check = "RTMify compared parent and child ASIL values across REFINED_BY edges.",
        .why = "A child requirement appears to have a lower ASIL than its parent.",
        .inspect = "Verify the intended safety allocation and the asil values on both requirements.",
    };
    return .{
        .check = "RTMify evaluated a profile-specific traceability rule.",
        .why = "The required relationship or property is missing or inconsistent.",
        .inspect = "Inspect the related node and its upstream/downstream links in the relevant sheet tabs.",
    };
}
