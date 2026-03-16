const std = @import("std");
const internal = @import("internal.zig");

pub fn nodeMarkdown(node_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const data = try internal.routes.handleNode(db, node_id, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    return markdownFromNodeDetail(node, internal.json_util.getObjectField(parsed.value, "edges_out"), internal.json_util.getObjectField(parsed.value, "edges_in"), alloc);
}

pub fn requirementTraceMarkdown(req_id: []const u8, db: *internal.graph_live.GraphDb, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleDesignHistory(db, profile_name, req_id, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    const requirement = internal.json_util.getObjectField(parsed.value, "requirement") orelse return error.NotFound;
    if (requirement == .null) return error.NotFound;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const rid = internal.json_util.getString(requirement, "id") orelse req_id;
    try std.fmt.format(buf.writer(alloc), "# Requirement {s}\n\n", .{rid});
    try appendNodeCoreMarkdown(&buf, requirement, alloc);
    try appendNodeArraySection(&buf, "User Needs", internal.json_util.getObjectField(parsed.value, "user_needs"), alloc);
    try appendNodeArraySection(&buf, "Risks", internal.json_util.getObjectField(parsed.value, "risks"), alloc);
    try appendNodeArraySection(&buf, "Design Inputs", internal.json_util.getObjectField(parsed.value, "design_inputs"), alloc);
    try appendNodeArraySection(&buf, "Design Outputs", internal.json_util.getObjectField(parsed.value, "design_outputs"), alloc);
    try appendNodeArraySection(&buf, "Configuration Items", internal.json_util.getObjectField(parsed.value, "configuration_items"), alloc);
    try appendNodeArraySection(&buf, "Source Files", internal.json_util.getObjectField(parsed.value, "source_files"), alloc);
    try appendNodeArraySection(&buf, "Test Files", internal.json_util.getObjectField(parsed.value, "test_files"), alloc);
    try appendNodeArraySection(&buf, "Commits", internal.json_util.getObjectField(parsed.value, "commits"), alloc);
    try appendGapArraySection(&buf, "Chain Gaps", internal.json_util.getObjectField(parsed.value, "chain_gaps"), alloc);
    return alloc.dupe(u8, buf.items);
}

pub fn designHistoryMarkdown(req_id: []const u8, db: *internal.graph_live.GraphDb, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    return requirementTraceMarkdown(req_id, db, profile_name, alloc);
}

pub fn impactMarkdown(node_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleImpact(db, node_id, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidArgument;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# Impact Analysis for {s}\n\n", .{node_id});
    try std.fmt.format(buf.writer(alloc), "- Impacted nodes: {d}\n\n", .{parsed.value.array.items.len});
    try buf.appendSlice(alloc, "## Impacted Nodes\n");
    if (parsed.value.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n");
    } else {
        for (parsed.value.array.items) |item| {
            const id = internal.json_util.getString(item, "id") orelse "?";
            const ty = internal.json_util.getString(item, "type") orelse "?";
            const via = internal.json_util.getString(item, "via") orelse "?";
            const dir = internal.json_util.getString(item, "dir") orelse "?";
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) via `{s}` {s}\n", .{ id, ty, via, dir });
        }
    }
    return alloc.dupe(u8, buf.items);
}

pub fn statusMarkdown(registry: *internal.workbook.registry.WorkbookRegistry, secure_store_ref: *internal.secure_store.Store, state: *internal.sync_live.SyncState, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var license_service = try internal.license.initDefaultHmacFile(arena, .{
        .product = .live,
        .trial_policy = .requires_license,
    });
    const data = try internal.routes.handleStatus(registry, secure_store_ref, state, &license_service, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Live Status\n\n");
    try std.fmt.format(buf.writer(alloc), "- Configured: {s}\n", .{boolStr(internal.json_util.getObjectField(parsed.value, "configured"))});
    try std.fmt.format(buf.writer(alloc), "- Platform: {s}\n", .{internal.json_util.getString(parsed.value, "platform") orelse "none"});
    try std.fmt.format(buf.writer(alloc), "- Workbook: {s}\n", .{internal.json_util.getString(parsed.value, "workbook_label") orelse "none"});
    try std.fmt.format(buf.writer(alloc), "- Sync Count: {d}\n", .{getIntField(parsed.value, "sync_count") orelse 0});
    try std.fmt.format(buf.writer(alloc), "- Last Sync At: {d}\n", .{getIntField(parsed.value, "last_sync_at") orelse 0});
    try std.fmt.format(buf.writer(alloc), "- Last Scan At: {s}\n", .{internal.json_util.getString(parsed.value, "last_scan_at") orelse "never"});
    try std.fmt.format(buf.writer(alloc), "- Has Error: {s}\n", .{boolStr(internal.json_util.getObjectField(parsed.value, "has_error"))});
    const err = internal.json_util.getString(parsed.value, "error") orelse "";
    if (err.len > 0) try std.fmt.format(buf.writer(alloc), "- Error: {s}\n", .{err});
    return alloc.dupe(u8, buf.items);
}

pub fn chainGapSummaryMarkdown(db: *internal.graph_live.GraphDb, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleChainGaps(db, profile_name, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var err_count: usize = 0;
    var warn_count: usize = 0;
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            const sev = internal.json_util.getString(item, "severity") orelse "info";
            if (std.mem.eql(u8, sev, "err")) err_count += 1 else if (std.mem.eql(u8, sev, "warn")) warn_count += 1;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Chain Gap Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Total gaps: {d}\n- Errors: {d}\n- Warnings: {d}\n\n", .{ if (parsed.value == .array) parsed.value.array.items.len else 0, err_count, warn_count });
    try appendGapArraySection(&buf, "Top Gaps", if (parsed.value == .array) parsed.value else null, alloc);
    return alloc.dupe(u8, buf.items);
}

pub fn rtmSummaryMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleRtm(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var unique: std.StringHashMap(void) = .init(arena);
    defer unique.deinit();
    var linked_tests: usize = 0;
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            const req_id = internal.json_util.getString(item, "req_id") orelse continue;
            try unique.put(req_id, {});
            if (internal.json_util.getString(item, "test_group_id") != null) linked_tests += 1;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# RTM Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Requirements represented: {d}\n- Rows with linked tests: {d}\n", .{ unique.count(), linked_tests });
    return alloc.dupe(u8, buf.items);
}

pub fn codeTraceabilitySummaryMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleCodeTraceability(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    const src_count = if (internal.json_util.getObjectField(parsed.value, "source_files")) |v| if (v == .array) v.array.items.len else 0 else 0;
    const test_count = if (internal.json_util.getObjectField(parsed.value, "test_files")) |v| if (v == .array) v.array.items.len else 0 else 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Code Traceability Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Source files: {d}\n- Test files: {d}\n", .{ src_count, test_count });
    return alloc.dupe(u8, buf.items);
}

pub fn reviewSummaryMarkdown(db: *internal.graph_live.GraphDb, profile_name: []const u8, state: *internal.sync_live.SyncState, alloc: internal.Allocator) ![]u8 {
    _ = state;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suspects_json = try internal.routes.handleSuspects(db, arena);
    const gaps_json = try internal.routes.handleChainGaps(db, profile_name, arena);
    var suspects_parsed = try std.json.parseFromSlice(std.json.Value, arena, suspects_json, .{});
    defer suspects_parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_json, .{});
    defer gaps_parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Review Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Suspect nodes: {d}\n- Chain gaps: {d}\n", .{
        if (suspects_parsed.value == .array) suspects_parsed.value.array.items.len else 0,
        if (gaps_parsed.value == .array) gaps_parsed.value.array.items.len else 0,
    });
    return alloc.dupe(u8, buf.items);
}

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

pub fn markdownFromNodeDetail(node: std.json.Value, edges_out: ?std.json.Value, edges_in: ?std.json.Value, alloc: internal.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const id = internal.json_util.getString(node, "id") orelse "unknown";
    const ty = internal.json_util.getString(node, "type") orelse "Node";
    try std.fmt.format(buf.writer(alloc), "# {s} {s}\n\n", .{ ty, id });
    try appendNodeCoreMarkdown(&buf, node, alloc);
    try appendEdgeSection(&buf, "Outgoing Links", edges_out, alloc);
    try appendEdgeSection(&buf, "Incoming Links", edges_in, alloc);
    return alloc.dupe(u8, buf.items);
}

fn appendNodeCoreMarkdown(buf: *std.ArrayList(u8), node: std.json.Value, alloc: internal.Allocator) !void {
    const id = internal.json_util.getString(node, "id") orelse "unknown";
    const ty = internal.json_util.getString(node, "type") orelse "Node";
    try std.fmt.format(buf.writer(alloc), "- ID: `{s}`\n- Type: {s}\n", .{ id, ty });
    const suspect = if (internal.json_util.getObjectField(node, "suspect")) |v| switch (v) {
        .bool => v.bool,
        else => false,
    } else false;
    try std.fmt.format(buf.writer(alloc), "- Suspect: {s}\n", .{if (suspect) "yes" else "no"});
    const props = internal.json_util.getObjectField(node, "properties");
    if (props) |p| if (p == .object) {
        const statement = internal.json_util.getString(p, "statement");
        const status = internal.json_util.getString(p, "status");
        const description = internal.json_util.getString(p, "description");
        const path = internal.json_util.getString(p, "path");
        const message = internal.json_util.getString(p, "message");
        if (statement) |s| try std.fmt.format(buf.writer(alloc), "- Statement: {s}\n", .{s});
        if (description) |s| try std.fmt.format(buf.writer(alloc), "- Description: {s}\n", .{s});
        if (status) |s| try std.fmt.format(buf.writer(alloc), "- Status: {s}\n", .{s});
        if (path) |s| try std.fmt.format(buf.writer(alloc), "- Path: `{s}`\n", .{s});
        if (message) |s| try std.fmt.format(buf.writer(alloc), "- Message: {s}\n", .{s});
    };
    try buf.append(alloc, '\n');
}

fn appendNodeArraySection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const id = internal.json_util.getString(item, "id") orelse "?";
        const ty = internal.json_util.getString(item, "type") orelse "Node";
        const summary = nodeSummary(item);
        if (summary) |s| {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) — {s}\n", .{ id, ty, s });
        } else {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s})\n", .{ id, ty });
        }
    }
    try buf.append(alloc, '\n');
}

fn appendGapArraySection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const code = getIntField(item, "code") orelse 0;
        const title_val = internal.json_util.getString(item, "title") orelse "Gap";
        const message = internal.json_util.getString(item, "message") orelse "";
        try std.fmt.format(buf.writer(alloc), "- [{d}] {s}: {s}\n", .{ code, title_val, message });
    }
    try buf.append(alloc, '\n');
}

fn appendEdgeSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array or arr.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse "";
        const node = internal.json_util.getObjectField(item, "node");
        if (node) |n| {
            const id = internal.json_util.getString(n, "id") orelse "?";
            const ty = internal.json_util.getString(n, "type") orelse "Node";
            try std.fmt.format(buf.writer(alloc), "- `{s}` -> `{s}` ({s})", .{ label, id, ty });
            try appendEdgePropertySuffix(buf, internal.json_util.getObjectField(item, "properties"), alloc);
            try buf.append(alloc, '\n');
        }
    }
    try buf.append(alloc, '\n');
}

fn edgePropertyPriority(key: []const u8) usize {
    if (std.mem.eql(u8, key, "quantity")) return 0;
    if (std.mem.eql(u8, key, "ref_designator")) return 1;
    if (std.mem.eql(u8, key, "supplier")) return 2;
    if (std.mem.eql(u8, key, "relation_source")) return 3;
    return 4;
}

fn edgePropertyLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const lhs_priority = edgePropertyPriority(lhs);
    const rhs_priority = edgePropertyPriority(rhs);
    if (lhs_priority != rhs_priority) return lhs_priority < rhs_priority;
    return std.mem.lessThan(u8, lhs, rhs);
}

fn appendEdgePropertyValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: internal.Allocator) !void {
    switch (value) {
        .string => try buf.appendSlice(alloc, value.string),
        .integer => try std.fmt.format(buf.writer(alloc), "{d}", .{value.integer}),
        .float => try std.fmt.format(buf.writer(alloc), "{d}", .{value.float}),
        .bool => try buf.appendSlice(alloc, if (value.bool) "true" else "false"),
        else => {
            const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
            defer alloc.free(json);
            try buf.appendSlice(alloc, json);
        },
    }
}

fn appendEdgePropertySuffix(buf: *std.ArrayList(u8), properties: ?std.json.Value, alloc: internal.Allocator) !void {
    if (properties == null or properties.? != .object) return;

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);
    var it = properties.?.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        try keys.append(alloc, entry.key_ptr.*);
    }
    if (keys.items.len == 0) return;
    std.mem.sort([]const u8, keys.items, {}, edgePropertyLessThan);

    try buf.appendSlice(alloc, " [");
    for (keys.items, 0..) |key, idx| {
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, key);
        try buf.append(alloc, '=');
        try appendEdgePropertyValue(buf, properties.?.object.get(key).?, alloc);
    }
    try buf.append(alloc, ']');
}

fn nodeSummary(node: std.json.Value) ?[]const u8 {
    const props = internal.json_util.getObjectField(node, "properties") orelse return null;
    return internal.json_util.getString(props, "statement") orelse
        internal.json_util.getString(props, "description") orelse
        internal.json_util.getString(props, "path") orelse
        internal.json_util.getString(props, "file_path") orelse
        internal.json_util.getString(props, "message") orelse
        internal.json_util.getString(props, "short_hash");
}

fn markdownFromGap(gap: std.json.Value, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    const code = getIntField(gap, "code") orelse 0;
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

const GapExplanation = struct { check: []const u8, why: []const u8, inspect: []const u8 };

fn explainGap(gap_type: []const u8, node_id: []const u8, profile_name: []const u8) GapExplanation {
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

fn getIntField(value: std.json.Value, key: []const u8) ?i64 {
    const field = internal.json_util.getObjectField(value, key) orelse return null;
    return switch (field) {
        .integer => field.integer,
        else => null,
    };
}

fn boolStr(v: ?std.json.Value) []const u8 {
    if (v) |val| switch (val) {
        .bool => return if (val.bool) "true" else "false",
        else => {},
    };
    return "false";
}
