const std = @import("std");
const internal = @import("internal.zig");
const protocol = @import("protocol.zig");

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

pub fn userNeedMarkdown(user_need_id: []const u8, db: *internal.graph_live.GraphDb, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleNode(db, user_need_id, arena);
    const gaps_json = try internal.routes.handleChainGaps(db, profile_name, arena);

    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_json, .{});
    defer gaps_parsed.deinit();

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    const edges_in = internal.json_util.getObjectField(parsed.value, "edges_in");
    const edges_out = internal.json_util.getObjectField(parsed.value, "edges_out");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try std.fmt.format(buf.writer(alloc), "# User Need {s}\n\n", .{user_need_id});
    try appendNodeCoreMarkdown(&buf, node, alloc);
    try appendFilteredEdgeNodeSection(&buf, "Derived Requirements", edges_in, "DERIVES_FROM", "Requirement", alloc);
    try appendFilteredGapSection(&buf, "Chain Gaps", if (gaps_parsed.value == .array) gaps_parsed.value else null, user_need_id, alloc);
    try appendEdgeSection(&buf, "Other Outgoing Links", edges_out, alloc);
    try appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "DERIVES_FROM", "Requirement", alloc);
    return alloc.dupe(u8, buf.items);
}

pub fn userNeedsIndexMarkdown(db: *internal.graph_live.GraphDb, profile_name: []const u8, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const needs_json = try internal.routes.handleUserNeeds(db, arena);
    const gaps_json = try internal.routes.handleChainGaps(db, profile_name, arena);

    var needs_parsed = try std.json.parseFromSlice(std.json.Value, arena, needs_json, .{});
    defer needs_parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_json, .{});
    defer gaps_parsed.deinit();

    if (needs_parsed.value != .array) return error.InvalidArgument;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    var covered: usize = 0;
    var uncovered: usize = 0;

    try buf.appendSlice(alloc, "# User Needs\n\n");
    for (needs_parsed.value.array.items) |need| {
        const need_id = internal.json_util.getString(need, "id") orelse continue;
        const detail_json = try internal.routes.handleNode(db, need_id, arena);
        var detail_parsed = try std.json.parseFromSlice(std.json.Value, arena, detail_json, .{});
        defer detail_parsed.deinit();
        const edges_in = internal.json_util.getObjectField(detail_parsed.value, "edges_in");
        const derived_count = countFilteredEdges(edges_in, "DERIVES_FROM", "Requirement");
        if (derived_count > 0) covered += 1 else uncovered += 1;
    }

    try std.fmt.format(buf.writer(alloc), "- Total user needs: {d}\n- User needs with linked requirements: {d}\n- User needs without linked requirements: {d}\n\n", .{
        needs_parsed.value.array.items.len,
        covered,
        uncovered,
    });

    try buf.appendSlice(alloc, "## Coverage\n");
    if (needs_parsed.value.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (needs_parsed.value.array.items) |need| {
            const need_id = internal.json_util.getString(need, "id") orelse continue;
            const detail_json = try internal.routes.handleNode(db, need_id, arena);
            var detail_parsed = try std.json.parseFromSlice(std.json.Value, arena, detail_json, .{});
            defer detail_parsed.deinit();
            const edges_in = internal.json_util.getObjectField(detail_parsed.value, "edges_in");
            const derived_count = countFilteredEdges(edges_in, "DERIVES_FROM", "Requirement");
            const summary = nodeSummary(need) orelse "";
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} (derived requirements: {d})\n", .{ need_id, summary, derived_count });
        }
        try buf.append(alloc, '\n');
    }

    try appendUserNeedGapSummary(&buf, if (gaps_parsed.value == .array) gaps_parsed.value else null, alloc);
    return alloc.dupe(u8, buf.items);
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
    const user_needs_data = try internal.routes.handleUserNeeds(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var user_needs_parsed = try std.json.parseFromSlice(std.json.Value, arena, user_needs_data, .{});
    defer user_needs_parsed.deinit();
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
    try std.fmt.format(buf.writer(alloc), "- User needs represented: {d}\n- Requirements represented: {d}\n- Rows with linked tests: {d}\n", .{
        if (user_needs_parsed.value == .array) user_needs_parsed.value.array.items.len else 0,
        unique.count(),
        linked_tests,
    });
    return alloc.dupe(u8, buf.items);
}

pub fn requirementsIndexMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rtm_data = try internal.routes.handleRtm(db, arena);
    const unimplemented_data = try internal.routes.handleUnimplementedRequirements(db, arena);
    const gaps_data = try internal.routes.handleGaps(db, arena);

    var rtm_parsed = try std.json.parseFromSlice(std.json.Value, arena, rtm_data, .{});
    defer rtm_parsed.deinit();
    var unimplemented_parsed = try std.json.parseFromSlice(std.json.Value, arena, unimplemented_data, .{});
    defer unimplemented_parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_data, .{});
    defer gaps_parsed.deinit();

    var statements: std.StringHashMap([]const u8) = .init(arena);
    defer statements.deinit();
    var ordered_ids: std.ArrayList([]const u8) = .empty;
    defer ordered_ids.deinit(arena);
    var unimplemented_ids: std.StringHashMap(void) = .init(arena);
    defer unimplemented_ids.deinit();
    var untested_ids: std.StringHashMap(void) = .init(arena);
    defer untested_ids.deinit();

    if (rtm_parsed.value == .array) {
        for (rtm_parsed.value.array.items) |item| {
            const req_id = internal.json_util.getString(item, "req_id") orelse continue;
            if (!statements.contains(req_id)) {
                try ordered_ids.append(arena, req_id);
                try statements.put(req_id, internal.json_util.getString(item, "statement") orelse "");
            }
        }
    }
    if (unimplemented_parsed.value == .array) {
        for (unimplemented_parsed.value.array.items) |item| {
            const req_id = internal.json_util.getString(item, "id") orelse continue;
            try unimplemented_ids.put(req_id, {});
            if (!statements.contains(req_id)) {
                try ordered_ids.append(arena, req_id);
                const props = internal.json_util.getObjectField(item, "properties");
                try statements.put(req_id, if (props) |p| internal.json_util.getString(p, "statement") orelse "" else "");
            }
        }
    }
    if (gaps_parsed.value == .array) {
        for (gaps_parsed.value.array.items) |item| {
            const req_id = internal.json_util.getString(item, "id") orelse continue;
            try untested_ids.put(req_id, {});
            if (!statements.contains(req_id)) {
                try ordered_ids.append(arena, req_id);
                const props = internal.json_util.getObjectField(item, "properties");
                try statements.put(req_id, if (props) |p| internal.json_util.getString(p, "statement") orelse "" else "");
            }
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Requirements\n\n");
    try std.fmt.format(buf.writer(alloc), "- Total requirements: {d}\n- Requirements without implementation evidence: {d}\n- Requirements without linked tests: {d}\n\n", .{
        ordered_ids.items.len,
        unimplemented_ids.count(),
        untested_ids.count(),
    });

    try buf.appendSlice(alloc, "## Requirements Without Implementation Evidence\n");
    if (unimplemented_ids.count() == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (ordered_ids.items) |req_id| {
            if (!unimplemented_ids.contains(req_id)) continue;
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s}\n", .{ req_id, statements.get(req_id) orelse "" });
        }
        try buf.append(alloc, '\n');
    }

    try buf.appendSlice(alloc, "## Requirements Without Linked Tests\n");
    if (untested_ids.count() == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (ordered_ids.items) |req_id| {
            if (!untested_ids.contains(req_id)) continue;
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s}\n", .{ req_id, statements.get(req_id) orelse "" });
        }
        try buf.append(alloc, '\n');
    }

    try buf.appendSlice(alloc, "## Requirement Inventory\n");
    for (ordered_ids.items) |req_id| {
        try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [implemented={s}, tested={s}]\n", .{
            req_id,
            statements.get(req_id) orelse "",
            if (unimplemented_ids.contains(req_id)) "no" else "yes",
            if (untested_ids.contains(req_id)) "no" else "yes",
        });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn testsIndexMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tests_data = try internal.routes.handleTests(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, tests_data, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Tests\n\n");
    if (parsed.value != .array) {
        try buf.appendSlice(alloc, "- None\n");
        return alloc.dupe(u8, buf.items);
    }

    var linked_requirement_rows: usize = 0;
    for (parsed.value.array.items) |item| {
        const req_ids = internal.json_util.getObjectField(item, "req_ids") orelse continue;
        if (req_ids == .array and req_ids.array.items.len > 0) linked_requirement_rows += 1;
    }
    try std.fmt.format(buf.writer(alloc), "- Test rows: {d}\n- Test rows with linked requirements: {d}\n\n", .{
        parsed.value.array.items.len,
        linked_requirement_rows,
    });
    try buf.appendSlice(alloc, "## Test Inventory\n");
    for (parsed.value.array.items) |item| {
        const test_id = internal.json_util.getString(item, "test_id");
        const group_id = internal.json_util.getString(item, "test_group_id") orelse "?";
        const req_ids = internal.json_util.getObjectField(item, "req_ids");
        const req_count = if (req_ids) |value| if (value == .array) value.array.items.len else 0 else 0;
        const suspect = if (internal.json_util.getObjectField(item, "suspect")) |value| switch (value) {
            .bool => value.bool,
            else => false,
        } else false;
        if (test_id) |id| {
            try std.fmt.format(buf.writer(alloc), "- `test://{s}` — group `{s}`, linked requirements: {d}, suspect={s}\n", .{
                id,
                group_id,
                req_count,
                if (suspect) "yes" else "no",
            });
        } else {
            try std.fmt.format(buf.writer(alloc), "- `test-group://{s}` — linked requirements: {d}, suspect={s}\n", .{
                group_id,
                req_count,
                if (suspect) "yes" else "no",
            });
        }
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn risksIndexMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const risks_data = try internal.routes.handleRisks(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, risks_data, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Risks\n\n");
    if (parsed.value != .array) {
        try buf.appendSlice(alloc, "- None\n");
        return alloc.dupe(u8, buf.items);
    }

    var open_count: usize = 0;
    for (parsed.value.array.items) |item| {
        const status = internal.json_util.getString(item, "status") orelse "";
        if (std.ascii.eqlIgnoreCase(status, "open")) open_count += 1;
    }
    try std.fmt.format(buf.writer(alloc), "- Risk rows: {d}\n- Open risks: {d}\n\n", .{
        parsed.value.array.items.len,
        open_count,
    });
    try buf.appendSlice(alloc, "## Risk Inventory\n");
    for (parsed.value.array.items) |item| {
        const risk_id = internal.json_util.getString(item, "risk_id") orelse "?";
        const desc = internal.json_util.getString(item, "description") orelse "";
        const status = internal.json_util.getString(item, "status") orelse "";
        const residual_severity = internal.json_util.getString(item, "residual_severity") orelse "?";
        const residual_likelihood = internal.json_util.getString(item, "residual_likelihood") orelse "?";
        try std.fmt.format(buf.writer(alloc), "- `risk://{s}` — {s} [status={s}, residual_severity={s}, residual_likelihood={s}]\n", .{
            risk_id,
            desc,
            status,
            residual_severity,
            residual_likelihood,
        });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn suspectsIndexMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suspects_data = try internal.routes.handleSuspects(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, suspects_data, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Suspects\n\n");
    if (parsed.value != .array) {
        try buf.appendSlice(alloc, "- None\n");
        return alloc.dupe(u8, buf.items);
    }
    try std.fmt.format(buf.writer(alloc), "- Suspect nodes: {d}\n\n", .{parsed.value.array.items.len});
    try buf.appendSlice(alloc, "## Suspect Inventory\n");
    if (parsed.value.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return alloc.dupe(u8, buf.items);
    }
    for (parsed.value.array.items) |item| {
        const node_id = internal.json_util.getString(item, "id") orelse "?";
        const node_type = internal.json_util.getString(item, "type") orelse "Node";
        const reason = internal.json_util.getString(item, "suspect_reason") orelse "";
        try std.fmt.format(buf.writer(alloc), "- `suspect://{s}` ({s}) — {s}\n", .{ node_id, node_type, reason });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn codeTraceabilitySummaryMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleCodeTraceability(db, arena);
    const unimplemented_data = try internal.routes.handleUnimplementedRequirements(db, arena);
    const untested_data = try internal.routes.handleUntestedSourceFiles(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();
    var unimplemented_parsed = try std.json.parseFromSlice(std.json.Value, arena, unimplemented_data, .{});
    defer unimplemented_parsed.deinit();
    var untested_parsed = try std.json.parseFromSlice(std.json.Value, arena, untested_data, .{});
    defer untested_parsed.deinit();
    const src_count = if (internal.json_util.getObjectField(parsed.value, "source_files")) |v| if (v == .array) v.array.items.len else 0 else 0;
    const test_count = if (internal.json_util.getObjectField(parsed.value, "test_files")) |v| if (v == .array) v.array.items.len else 0 else 0;
    const unimplemented_count = if (unimplemented_parsed.value == .array) unimplemented_parsed.value.array.items.len else 0;
    const untested_source_count = if (untested_parsed.value == .array) untested_parsed.value.array.items.len else 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Code Traceability Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Source files: {d}\n- Test files: {d}\n- Requirements without implementation evidence: {d}\n- Source files without test linkage: {d}\n", .{
        src_count,
        test_count,
        unimplemented_count,
        untested_source_count,
    });
    return alloc.dupe(u8, buf.items);
}

const CodeFileSummary = struct {
    id: []const u8,
    annotation_count: i64,
    design_control_links: usize,
    requirement_links: usize,
    design_output_links: usize,
    linked_test_files: usize,
};

fn codeFileSummaryLessThan(_: void, lhs: CodeFileSummary, rhs: CodeFileSummary) bool {
    if (lhs.design_control_links != rhs.design_control_links) return lhs.design_control_links > rhs.design_control_links;
    if (lhs.annotation_count != rhs.annotation_count) return lhs.annotation_count > rhs.annotation_count;
    if (lhs.linked_test_files != rhs.linked_test_files) return lhs.linked_test_files > rhs.linked_test_files;
    return std.mem.lessThan(u8, lhs.id, rhs.id);
}

pub fn codeFilesIndexMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try internal.routes.handleCodeTraceability(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();

    const source_files = internal.json_util.getObjectField(parsed.value, "source_files");
    const test_files = internal.json_util.getObjectField(parsed.value, "test_files");

    var source_summaries: std.ArrayList(CodeFileSummary) = .empty;
    defer source_summaries.deinit(alloc);

    if (source_files) |files| {
        if (files == .array) {
            for (files.array.items) |item| {
                const file_id = internal.json_util.getString(item, "id") orelse continue;
                const detail_json = try internal.routes.handleNode(db, file_id, arena);
                var detail_parsed = try std.json.parseFromSlice(std.json.Value, arena, detail_json, .{});
                defer detail_parsed.deinit();

                const node = internal.json_util.getObjectField(detail_parsed.value, "node") orelse continue;
                const edges_in = internal.json_util.getObjectField(detail_parsed.value, "edges_in");
                const edges_out = internal.json_util.getObjectField(detail_parsed.value, "edges_out");
                const props = internal.json_util.getObjectField(node, "properties");
                const annotation_count = if (props) |p| getIntField(p, "annotation_count") orelse 0 else 0;
                const requirement_links = countFilteredEdges(edges_in, "IMPLEMENTED_IN", "Requirement");
                const design_output_links = countFilteredEdges(edges_in, "IMPLEMENTED_IN", "DesignOutput");
                const linked_test_files = countFilteredEdges(edges_out, "VERIFIED_BY_CODE", "TestFile");

                try source_summaries.append(alloc, .{
                    .id = try alloc.dupe(u8, file_id),
                    .annotation_count = annotation_count,
                    .design_control_links = requirement_links + design_output_links,
                    .requirement_links = requirement_links,
                    .design_output_links = design_output_links,
                    .linked_test_files = linked_test_files,
                });
            }
        }
    }
    defer {
        for (source_summaries.items) |item| alloc.free(item.id);
    }

    std.mem.sort(CodeFileSummary, source_summaries.items, {}, codeFileSummaryLessThan);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Code Files\n\n");
    try std.fmt.format(buf.writer(alloc), "- Source files: {d}\n- Test files: {d}\n\n", .{
        if (source_files != null and source_files.? == .array) source_files.?.array.items.len else 0,
        if (test_files != null and test_files.? == .array) test_files.?.array.items.len else 0,
    });

    try buf.appendSlice(alloc, "## Top Source Files by Design-Control Linkage\n");
    if (source_summaries.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (source_summaries.items) |item| {
            try std.fmt.format(buf.writer(alloc), "- `source-file://{s}` — design_controls: {d}, requirements: {d}, design_outputs: {d}, annotations: {d}, linked_tests: {d}\n", .{
                item.id,
                item.design_control_links,
                item.requirement_links,
                item.design_output_links,
                item.annotation_count,
                item.linked_test_files,
            });
        }
        try buf.append(alloc, '\n');
    }

    try buf.appendSlice(alloc, "## Test File Inventory\n");
    if (test_files == null or test_files.? != .array or test_files.?.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (test_files.?.array.items) |item| {
            const file_id = internal.json_util.getString(item, "id") orelse continue;
            const props = internal.json_util.getObjectField(item, "properties");
            const annotation_count = if (props) |p| getIntField(p, "annotation_count") orelse 0 else 0;
            try std.fmt.format(buf.writer(alloc), "- `test-file://{s}` — annotations: {d}\n", .{
                file_id,
                annotation_count,
            });
        }
        try buf.append(alloc, '\n');
    }

    return alloc.dupe(u8, buf.items);
}

pub fn codeFileMarkdown(node_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const data = try internal.routes.handleNode(db, node_id, alloc);
    defer alloc.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.NotFound;
    const node_type = internal.json_util.getString(node, "type") orelse return error.NotFound;
    const edges_out = internal.json_util.getObjectField(parsed.value, "edges_out");
    const edges_in = internal.json_util.getObjectField(parsed.value, "edges_in");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    if (std.mem.eql(u8, node_type, "SourceFile")) {
        try std.fmt.format(buf.writer(alloc), "# Source File {s}\n\n", .{node_id});
        try appendNodeCoreMarkdown(&buf, node, alloc);
        try appendFilteredEdgeNodeSection(&buf, "Linked Requirements", edges_in, "IMPLEMENTED_IN", "Requirement", alloc);
        try appendFilteredEdgeNodeSection(&buf, "Linked Design Outputs", edges_in, "IMPLEMENTED_IN", "DesignOutput", alloc);
        try appendFilteredEdgeNodeSection(&buf, "Verified By Test Files", edges_out, "VERIFIED_BY_CODE", "TestFile", alloc);
        try appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "IMPLEMENTED_IN", "Requirement", alloc);
        try appendNonMatchingEdgeSection(&buf, "Other Outgoing Links", edges_out, "VERIFIED_BY_CODE", "TestFile", alloc);
    } else if (std.mem.eql(u8, node_type, "TestFile")) {
        try std.fmt.format(buf.writer(alloc), "# Test File {s}\n\n", .{node_id});
        try appendNodeCoreMarkdown(&buf, node, alloc);
        try appendFilteredEdgeNodeSection(&buf, "Verifies Source Files", edges_in, "VERIFIED_BY_CODE", "SourceFile", alloc);
        try appendFilteredEdgeNodeSection(&buf, "Verifies Requirements", edges_in, "VERIFIED_BY_CODE", "Requirement", alloc);
        try appendEdgeSection(&buf, "Outgoing Links", edges_out, alloc);
        try appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "VERIFIED_BY_CODE", "SourceFile", alloc);
    } else {
        return error.NotFound;
    }

    return alloc.dupe(u8, buf.items);
}

pub fn mcpToolsIndexMarkdown(alloc: internal.Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, protocol.tools_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidArgument;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# MCP Tools\n\n");
    try std.fmt.format(buf.writer(alloc), "- Callable tools exposed by this server: {d}\n\n", .{parsed.value.array.items.len});
    try buf.appendSlice(alloc, "## Tool Catalog\n");
    for (parsed.value.array.items) |item| {
        const name = internal.json_util.getString(item, "name") orelse continue;
        const description = internal.json_util.getString(item, "description") orelse "";
        const input_schema = internal.json_util.getObjectField(item, "inputSchema");
        const required_count: usize = if (input_schema) |schema|
            if (internal.json_util.getObjectField(schema, "required")) |required|
                if (required == .array) required.array.items.len else 0
            else 0
        else 0;
        try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [required_args={d}]\n", .{
            name,
            description,
            required_count,
        });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn mcpPromptsIndexMarkdown(alloc: internal.Allocator) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, protocol.prompts_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidArgument;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# MCP Prompts\n\n");
    try std.fmt.format(buf.writer(alloc), "- Prompts exposed by this server: {d}\n\n", .{parsed.value.array.items.len});
    try buf.appendSlice(alloc, "## Prompt Catalog\n");
    for (parsed.value.array.items) |item| {
        const name = internal.json_util.getString(item, "name") orelse continue;
        const description = internal.json_util.getString(item, "description") orelse "";
        const arguments = internal.json_util.getObjectField(item, "arguments");
        const arg_count: usize = if (arguments) |args| if (args == .array) args.array.items.len else 0 else 0;
        try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [arguments={d}]\n", .{
            name,
            description,
            arg_count,
        });
    }
    try buf.append(alloc, '\n');
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
    try appendNodeCoreMarkdown(&buf, node, alloc);

    if (std.mem.eql(u8, node_type, "Test")) {
        try appendStringListSection(&buf, "Parent Test Groups", trace.parent_groups.items, "test-group://", alloc);
        try appendStringListSection(&buf, "Direct Linked Requirements", trace.direct_requirements.items, "requirement://", alloc);
        try appendStringListSection(&buf, "Inherited Group Requirements", trace.inherited_requirements.items, "requirement://", alloc);
        try appendStringListSection(&buf, "Effective Linked Requirements", trace.effective_requirements.items, "requirement://", alloc);
        try appendStringListSection(&buf, "Linked Risks", trace.linked_risks.items, "risk://", alloc);
        try appendEdgeSection(&buf, "Other Outgoing Links", edges_out, alloc);
        try appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "HAS_TEST", "TestGroup", alloc);
    } else if (std.mem.eql(u8, node_type, "TestGroup")) {
        try appendStringListSection(&buf, "Child Tests", trace.child_tests.items, "test://", alloc);
        try appendStringListSection(&buf, "Linked Requirements", trace.direct_requirements.items, "requirement://", alloc);
        try appendStringListSection(&buf, "Linked Risks", trace.linked_risks.items, "risk://", alloc);
        try appendNonMatchingEdgeSection(&buf, "Other Outgoing Links", edges_out, "HAS_TEST", "Test", alloc);
        try appendNonMatchingEdgeSection(&buf, "Other Incoming Links", edges_in, "TESTED_BY", "Requirement", alloc);
    } else {
        return markdownFromNodeDetail(node, edges_out, edges_in, alloc);
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
        try appendInlineStringList(&buf, "Parent Test Groups", trace.parent_groups.items, "test-group://", alloc);
        try appendInlineStringList(&buf, "Linked Requirements", trace.effective_requirements.items, "requirement://", alloc);
        try appendInlineStringList(&buf, "Linked Risks", trace.linked_risks.items, "risk://", alloc);
        try buf.append(alloc, '\n');
    }

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

fn appendFilteredGapSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, node_id: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    var matched: usize = 0;
    for (arr.?.array.items) |item| {
        const item_node_id = internal.json_util.getString(item, "node_id") orelse continue;
        if (!std.mem.eql(u8, item_node_id, node_id)) continue;
        const code = getIntField(item, "code") orelse 0;
        const title_val = internal.json_util.getString(item, "title") orelse "Gap";
        const message = internal.json_util.getString(item, "message") orelse "";
        try std.fmt.format(buf.writer(alloc), "- [{d}] {s}: {s}\n", .{ code, title_val, message });
        matched += 1;
    }
    if (matched == 0) try buf.appendSlice(alloc, "- None\n");
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

fn appendFilteredEdgeNodeSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, label_filter: []const u8, type_filter: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    var matched: usize = 0;
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse continue;
        if (!std.mem.eql(u8, label, label_filter)) continue;
        const node = internal.json_util.getObjectField(item, "node") orelse continue;
        const ty = internal.json_util.getString(node, "type") orelse continue;
        if (!std.mem.eql(u8, ty, type_filter)) continue;
        const id = internal.json_util.getString(node, "id") orelse "?";
        const summary = nodeSummary(node);
        if (summary) |s| {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s}) — {s}\n", .{ id, ty, s });
        } else {
            try std.fmt.format(buf.writer(alloc), "- `{s}` ({s})\n", .{ id, ty });
        }
        matched += 1;
    }
    if (matched == 0) try buf.appendSlice(alloc, "- None\n");
    try buf.append(alloc, '\n');
}

fn appendNonMatchingEdgeSection(buf: *std.ArrayList(u8), title: []const u8, arr: ?std.json.Value, skip_label: []const u8, skip_type: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (arr == null or arr.? != .array) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    var matched: usize = 0;
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse "";
        const node = internal.json_util.getObjectField(item, "node") orelse continue;
        const ty = internal.json_util.getString(node, "type") orelse "Node";
        if (std.mem.eql(u8, label, skip_label) and std.mem.eql(u8, ty, skip_type)) continue;
        const id = internal.json_util.getString(node, "id") orelse "?";
        try std.fmt.format(buf.writer(alloc), "- `{s}` -> `{s}` ({s})", .{ label, id, ty });
        try appendEdgePropertySuffix(buf, internal.json_util.getObjectField(item, "properties"), alloc);
        try buf.append(alloc, '\n');
        matched += 1;
    }
    if (matched == 0) try buf.appendSlice(alloc, "- None\n");
    try buf.append(alloc, '\n');
}

fn countFilteredEdges(arr: ?std.json.Value, label_filter: []const u8, type_filter: []const u8) usize {
    if (arr == null or arr.? != .array) return 0;
    var count: usize = 0;
    for (arr.?.array.items) |item| {
        const label = internal.json_util.getString(item, "label") orelse continue;
        if (!std.mem.eql(u8, label, label_filter)) continue;
        const node = internal.json_util.getObjectField(item, "node") orelse continue;
        const ty = internal.json_util.getString(node, "type") orelse continue;
        if (!std.mem.eql(u8, ty, type_filter)) continue;
        count += 1;
    }
    return count;
}

fn appendUserNeedGapSummary(buf: *std.ArrayList(u8), arr: ?std.json.Value, alloc: internal.Allocator) !void {
    try buf.appendSlice(alloc, "## User Needs Without Linked Requirements\n");
    if (arr == null or arr.? != .array) {
        try buf.appendSlice(alloc, "- None\n");
        return;
    }
    var matched: usize = 0;
    for (arr.?.array.items) |item| {
        const gap_type = internal.json_util.getString(item, "gap_type") orelse continue;
        const node_id = internal.json_util.getString(item, "node_id") orelse continue;
        if (!std.mem.eql(u8, gap_type, "orphan_requirement")) continue;
        if (!std.mem.startsWith(u8, node_id, "UN-")) continue;
        const message = internal.json_util.getString(item, "message") orelse "No downstream requirements";
        try std.fmt.format(buf.writer(alloc), "- `{s}` — {s}\n", .{ node_id, message });
        matched += 1;
    }
    if (matched == 0) try buf.appendSlice(alloc, "- None\n");
    try buf.append(alloc, '\n');
}

fn appendStringListSection(buf: *std.ArrayList(u8), title: []const u8, items: []const []const u8, uri_prefix: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    if (items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (items) |item| {
        try std.fmt.format(buf.writer(alloc), "- `{s}{s}`\n", .{ uri_prefix, item });
    }
    try buf.append(alloc, '\n');
}

fn appendInlineStringList(buf: *std.ArrayList(u8), label: []const u8, items: []const []const u8, uri_prefix: []const u8, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "- {s}: ", .{label});
    if (items.len == 0) {
        try buf.appendSlice(alloc, "none visible\n");
        return;
    }
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try std.fmt.format(buf.writer(alloc), "`{s}{s}`", .{ uri_prefix, item });
    }
    try buf.append(alloc, '\n');
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
