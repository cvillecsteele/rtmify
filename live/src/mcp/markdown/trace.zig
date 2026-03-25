const std = @import("std");

const internal = @import("../internal.zig");
const common = @import("common.zig");

const TestTraceInfo = struct {
    node_type: []const u8,
    parent_groups: std.ArrayList([]const u8),
    child_tests: std.ArrayList([]const u8),
    direct_requirements: std.ArrayList([]const u8),
    inherited_requirements: std.ArrayList([]const u8),
    effective_requirements: std.ArrayList([]const u8),
    linked_risks: std.ArrayList([]const u8),

    fn init() TestTraceInfo {
        return .{
            .node_type = "",
            .parent_groups = .empty,
            .child_tests = .empty,
            .direct_requirements = .empty,
            .inherited_requirements = .empty,
            .effective_requirements = .empty,
            .linked_risks = .empty,
        };
    }

    fn deinit(self: *TestTraceInfo, alloc: internal.Allocator) void {
        for (self.parent_groups.items) |value| alloc.free(value);
        self.parent_groups.deinit(alloc);
        for (self.child_tests.items) |value| alloc.free(value);
        self.child_tests.deinit(alloc);
        for (self.direct_requirements.items) |value| alloc.free(value);
        self.direct_requirements.deinit(alloc);
        for (self.inherited_requirements.items) |value| alloc.free(value);
        self.inherited_requirements.deinit(alloc);
        for (self.effective_requirements.items) |value| alloc.free(value);
        self.effective_requirements.deinit(alloc);
        for (self.linked_risks.items) |value| alloc.free(value);
        self.linked_risks.deinit(alloc);
    }
};

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
    try common.appendNodeCoreMarkdown(&buf, requirement, alloc);
    try common.appendNodeArraySection(&buf, "User Needs", internal.json_util.getObjectField(parsed.value, "user_needs"), alloc);
    try common.appendNodeArraySection(&buf, "Risks", internal.json_util.getObjectField(parsed.value, "risks"), alloc);
    try common.appendNodeArraySection(&buf, "Design Inputs", internal.json_util.getObjectField(parsed.value, "design_inputs"), alloc);
    try common.appendNodeArraySection(&buf, "Design Outputs", internal.json_util.getObjectField(parsed.value, "design_outputs"), alloc);
    try common.appendNodeArraySection(&buf, "Configuration Items", internal.json_util.getObjectField(parsed.value, "configuration_items"), alloc);
    try common.appendNodeArraySection(&buf, "Source Files", internal.json_util.getObjectField(parsed.value, "source_files"), alloc);
    try common.appendNodeArraySection(&buf, "Test Files", internal.json_util.getObjectField(parsed.value, "test_files"), alloc);
    try common.appendNodeArraySection(&buf, "Commits", internal.json_util.getObjectField(parsed.value, "commits"), alloc);
    try common.appendGapArraySection(&buf, "Chain Gaps", internal.json_util.getObjectField(parsed.value, "chain_gaps"), alloc);
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

pub fn unitHistoryMarkdown(serial_number: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const data = try internal.test_results.unitHistoryJson(db, serial_number, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# Unit {s}\n\n", .{serial_number});

    const executions = internal.json_util.getObjectField(parsed.value, "executions") orelse {
        try buf.appendSlice(alloc, "- No execution history\n");
        return alloc.dupe(u8, buf.items);
    };
    if (executions != .array or executions.array.items.len == 0) {
        try buf.appendSlice(alloc, "- No execution history\n");
        return alloc.dupe(u8, buf.items);
    }

    try std.fmt.format(buf.writer(alloc), "- Executions: {d}\n\n", .{executions.array.items.len});
    try buf.appendSlice(alloc, "## Execution History\n");
    for (executions.array.items) |row| {
        const execution_id = internal.json_util.getString(row, "execution_id") orelse continue;
        const status = internal.json_util.getString(row, "computed_status") orelse "unknown";
        const executed_at = internal.json_util.getString(row, "executed_at") orelse "unknown";
        try std.fmt.format(buf.writer(alloc), "- `execution://{s}` — {s} — {s}\n", .{ execution_id, status, executed_at });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn testTraceMarkdown(node_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const data = try internal.routes.handleNode(db, node_id, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    const node_type = internal.json_util.getString(node, "type") orelse return error.NotFound;
    const edges_out = internal.json_util.getObjectField(parsed.value, "edges_out");
    const edges_in = internal.json_util.getObjectField(parsed.value, "edges_in");

    var trace = try collectTestTraceInfo(node_id, db, alloc);
    defer trace.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# {s} {s}\n\n", .{ node_type, node_id });
    try common.appendNodeCoreMarkdown(&buf, node, alloc);

    if (std.mem.eql(u8, node_type, "Test")) {
        try common.appendStringListSection(&buf, "Parent Test Groups", trace.parent_groups.items, "test-group://", alloc);
        try common.appendStringListSection(&buf, "Direct Linked Requirements", trace.direct_requirements.items, "requirement://", alloc);
        try common.appendStringListSection(&buf, "Inherited Group Requirements", trace.inherited_requirements.items, "requirement://", alloc);
        try common.appendStringListSection(&buf, "Effective Linked Requirements", trace.effective_requirements.items, "requirement://", alloc);
        try common.appendStringListSection(&buf, "Linked Risks", trace.linked_risks.items, "risk://", alloc);
        try common.appendEdgeSection(&buf, "Other Outgoing Links", edges_out, alloc);
        try common.appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "HAS_TEST", "TestGroup", alloc);
    } else if (std.mem.eql(u8, node_type, "TestGroup")) {
        try common.appendStringListSection(&buf, "Child Tests", trace.child_tests.items, "test://", alloc);
        try common.appendStringListSection(&buf, "Linked Requirements", trace.direct_requirements.items, "requirement://", alloc);
        try common.appendStringListSection(&buf, "Linked Risks", trace.linked_risks.items, "risk://", alloc);
        try common.appendNonMatchingEdgeSection(&buf, "Other Outgoing Links", edges_out, "HAS_TEST", "Test", alloc);
        try common.appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "TESTED_BY", "Requirement", alloc);
    } else {
        return common.markdownFromNodeDetail(node, edges_out, edges_in, alloc);
    }

    return alloc.dupe(u8, buf.items);
}

pub fn executionMarkdown(execution_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const data = (try internal.test_results.getExecutionJson(db, execution_id, alloc)) orelse return error.NotFound;
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# Execution {s}\n\n", .{execution_id});
    try std.fmt.format(buf.writer(alloc), "- Executed At: {s}\n", .{internal.json_util.getString(parsed.value, "executed_at") orelse "unknown"});
    try std.fmt.format(buf.writer(alloc), "- Status: {s}\n", .{internal.json_util.getString(parsed.value, "computed_status") orelse "unknown"});
    if (internal.json_util.getString(parsed.value, "serial_number")) |serial_number|
        try std.fmt.format(buf.writer(alloc), "- Unit: `unit://{s}`\n", .{serial_number});
    if (internal.json_util.getString(parsed.value, "full_product_identifier")) |full_product_identifier|
        try std.fmt.format(buf.writer(alloc), "- Product: `{s}`\n", .{full_product_identifier});
    try buf.append(alloc, '\n');

    try buf.appendSlice(alloc, "## Test Cases\n");
    const test_cases = internal.json_util.getObjectField(parsed.value, "test_cases") orelse {
        try buf.appendSlice(alloc, "- None\n\n");
        return alloc.dupe(u8, buf.items);
    };
    if (test_cases != .array or test_cases.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return alloc.dupe(u8, buf.items);
    }

    for (test_cases.array.items) |row| {
        const test_case_ref = internal.json_util.getString(row, "test_case_ref") orelse continue;
        const status = internal.json_util.getString(row, "status") orelse "unknown";
        try std.fmt.format(buf.writer(alloc), "### `{s}` — {s}\n", .{ test_case_ref, status });
        if (internal.json_util.getString(row, "result_id")) |result_id|
            try std.fmt.format(buf.writer(alloc), "- Result ID: `{s}`\n", .{result_id});
        if (internal.json_util.getString(row, "resolution_state")) |resolution_state|
            try std.fmt.format(buf.writer(alloc), "- Resolution State: {s}\n", .{resolution_state});
        var trace = collectTestTraceInfo(test_case_ref, db, alloc) catch {
            try buf.appendSlice(alloc, "- Parent Test Groups: none visible\n- Linked Requirements: none visible\n- Linked Risks: none visible\n\n");
            continue;
        };
        defer trace.deinit(alloc);
        try common.appendInlineStringList(&buf, "Parent Test Groups", trace.parent_groups.items, "test-group://", alloc);
        try common.appendInlineStringList(&buf, "Linked Requirements", trace.effective_requirements.items, "requirement://", alloc);
        try common.appendInlineStringList(&buf, "Linked Risks", trace.linked_risks.items, "risk://", alloc);
        try buf.append(alloc, '\n');
    }

    return alloc.dupe(u8, buf.items);
}

fn appendUniqueString(list: *std.ArrayList([]const u8), value: []const u8, alloc: internal.Allocator) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(alloc, try alloc.dupe(u8, value));
}

fn collectRequirementAndRiskLinks(trace: *TestTraceInfo, requirement_ids: []const []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) !void {
    for (requirement_ids) |req_id| {
        try appendUniqueString(&trace.effective_requirements, req_id, alloc);
        const req_data = internal.routes.handleNode(db, req_id, alloc) catch continue;
        defer alloc.free(req_data);
        var req_parsed = try std.json.parseFromSlice(std.json.Value, alloc, req_data, .{});
        defer req_parsed.deinit();
        const req_edges_in = internal.json_util.getObjectField(req_parsed.value, "edges_in");
        if (req_edges_in == null or req_edges_in.? != .array) continue;
        for (req_edges_in.?.array.items) |req_edge| {
            const req_label = internal.json_util.getString(req_edge, "label") orelse continue;
            if (!std.mem.eql(u8, req_label, "MITIGATED_BY")) continue;
            const risk_node = internal.json_util.getObjectField(req_edge, "node") orelse continue;
            const risk_ty = internal.json_util.getString(risk_node, "type") orelse continue;
            if (!std.mem.eql(u8, risk_ty, "Risk")) continue;
            const risk_id = internal.json_util.getString(risk_node, "id") orelse continue;
            try appendUniqueString(&trace.linked_risks, risk_id, alloc);
        }
    }
}

fn collectGroupRequirements(group_id: []const u8, trace: *TestTraceInfo, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) !void {
    const group_data = internal.routes.handleNode(db, group_id, alloc) catch return;
    defer alloc.free(group_data);
    var group_parsed = try std.json.parseFromSlice(std.json.Value, alloc, group_data, .{});
    defer group_parsed.deinit();
    const group_edges_in = internal.json_util.getObjectField(group_parsed.value, "edges_in");
    if (group_edges_in == null or group_edges_in.? != .array) return;

    var req_ids: std.ArrayList([]const u8) = .empty;
    defer req_ids.deinit(alloc);
    for (group_edges_in.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse continue;
        if (!std.mem.eql(u8, label, "TESTED_BY")) continue;
        const node = internal.json_util.getObjectField(item, "node") orelse continue;
        const ty = internal.json_util.getString(node, "type") orelse continue;
        if (!std.mem.eql(u8, ty, "Requirement")) continue;
        const req_id = internal.json_util.getString(node, "id") orelse continue;
        try appendUniqueString(&trace.inherited_requirements, req_id, alloc);
        try req_ids.append(alloc, req_id);
    }
    try collectRequirementAndRiskLinks(trace, req_ids.items, db, alloc);
}

fn collectTestTraceInfo(node_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) !TestTraceInfo {
    const data = try internal.routes.handleNode(db, node_id, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    const node_type = internal.json_util.getString(node, "type") orelse return error.NotFound;
    const edges_in = internal.json_util.getObjectField(parsed.value, "edges_in");
    const edges_out = internal.json_util.getObjectField(parsed.value, "edges_out");

    var trace = TestTraceInfo.init();
    trace.node_type = node_type;

    if (std.mem.eql(u8, node_type, "Test")) {
        var direct_req_ids: std.ArrayList([]const u8) = .empty;
        defer direct_req_ids.deinit(alloc);
        if (edges_in != null and edges_in.? == .array) {
            for (edges_in.?.array.items) |item| {
                const label = internal.json_util.getString(item, "label") orelse continue;
                const edge_node = internal.json_util.getObjectField(item, "node") orelse continue;
                const edge_type = internal.json_util.getString(edge_node, "type") orelse continue;
                const edge_id = internal.json_util.getString(edge_node, "id") orelse continue;
                if (std.mem.eql(u8, label, "TESTED_BY") and std.mem.eql(u8, edge_type, "Requirement")) {
                    try appendUniqueString(&trace.direct_requirements, edge_id, alloc);
                    try direct_req_ids.append(alloc, edge_id);
                } else if (std.mem.eql(u8, label, "HAS_TEST") and std.mem.eql(u8, edge_type, "TestGroup")) {
                    try appendUniqueString(&trace.parent_groups, edge_id, alloc);
                }
            }
        }
        try collectRequirementAndRiskLinks(&trace, direct_req_ids.items, db, alloc);
        for (trace.parent_groups.items) |group_id| try collectGroupRequirements(group_id, &trace, db, alloc);
    } else if (std.mem.eql(u8, node_type, "TestGroup")) {
        var direct_req_ids: std.ArrayList([]const u8) = .empty;
        defer direct_req_ids.deinit(alloc);
        if (edges_in != null and edges_in.? == .array) {
            for (edges_in.?.array.items) |item| {
                const label = internal.json_util.getString(item, "label") orelse continue;
                if (!std.mem.eql(u8, label, "TESTED_BY")) continue;
                const edge_node = internal.json_util.getObjectField(item, "node") orelse continue;
                const edge_type = internal.json_util.getString(edge_node, "type") orelse continue;
                if (!std.mem.eql(u8, edge_type, "Requirement")) continue;
                const edge_id = internal.json_util.getString(edge_node, "id") orelse continue;
                try appendUniqueString(&trace.direct_requirements, edge_id, alloc);
                try direct_req_ids.append(alloc, edge_id);
            }
        }
        if (edges_out != null and edges_out.? == .array) {
            for (edges_out.?.array.items) |item| {
                const label = internal.json_util.getString(item, "label") orelse continue;
                if (!std.mem.eql(u8, label, "HAS_TEST")) continue;
                const edge_node = internal.json_util.getObjectField(item, "node") orelse continue;
                const edge_type = internal.json_util.getString(edge_node, "type") orelse continue;
                if (!std.mem.eql(u8, edge_type, "Test")) continue;
                const edge_id = internal.json_util.getString(edge_node, "id") orelse continue;
                try appendUniqueString(&trace.child_tests, edge_id, alloc);
            }
        }
        try collectRequirementAndRiskLinks(&trace, direct_req_ids.items, db, alloc);
    } else {
        return error.NotFound;
    }

    return trace;
}
