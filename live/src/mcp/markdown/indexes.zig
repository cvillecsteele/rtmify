const std = @import("std");

const internal = @import("../internal.zig");
const design_artifacts = @import("../../design_artifacts.zig");
const common = @import("common.zig");

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
        const derived_count = common.countFilteredEdges(edges_in, "DERIVES_FROM", "Requirement");
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
            const derived_count = common.countFilteredEdges(edges_in, "DERIVES_FROM", "Requirement");
            const summary = common.nodeSummary(need) orelse "";
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} (derived requirements: {d})\n", .{ need_id, summary, derived_count });
        }
        try buf.append(alloc, '\n');
    }

    try appendUserNeedGapSummary(&buf, if (gaps_parsed.value == .array) gaps_parsed.value else null, alloc);
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
    try common.appendGapArraySection(&buf, "Top Gaps", if (parsed.value == .array) parsed.value else null, alloc);
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
    const requirements_data = try internal.routes.handleNodes(db, "Requirement", arena);
    var requirements_parsed = try std.json.parseFromSlice(std.json.Value, arena, requirements_data, .{});
    defer requirements_parsed.deinit();
    var unique: std.StringHashMap(void) = .init(arena);
    defer unique.deinit();
    var linked_tests: usize = 0;
    var conflicting_requirements: usize = 0;
    if (parsed.value == .array) {
        for (parsed.value.array.items) |item| {
            const req_id = internal.json_util.getString(item, "req_id") orelse continue;
            try unique.put(req_id, {});
            if (internal.json_util.getString(item, "test_group_id") != null) linked_tests += 1;
        }
    }
    if (requirements_parsed.value == .array) {
        for (requirements_parsed.value.array.items) |item| {
            const props = internal.json_util.getObjectField(item, "properties") orelse continue;
            if (std.mem.eql(u8, internal.json_util.getString(props, "text_status") orelse "", "conflict"))
                conflicting_requirements += 1;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# RTM Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- User needs represented: {d}\n- Requirements represented: {d}\n- Rows with linked tests: {d}\n- Requirements with source conflicts: {d}\n", .{
        if (user_needs_parsed.value == .array) user_needs_parsed.value.array.items.len else 0,
        unique.count(),
        linked_tests,
        conflicting_requirements,
    });
    return alloc.dupe(u8, buf.items);
}

pub fn requirementsIndexMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes_data = try internal.routes.handleNodes(db, "Requirement", arena);
    const unimplemented_data = try internal.routes.handleUnimplementedRequirements(db, arena);
    const gaps_data = try internal.routes.handleGaps(db, arena);

    var nodes_parsed = try std.json.parseFromSlice(std.json.Value, arena, nodes_data, .{});
    defer nodes_parsed.deinit();
    var unimplemented_parsed = try std.json.parseFromSlice(std.json.Value, arena, unimplemented_data, .{});
    defer unimplemented_parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_data, .{});
    defer gaps_parsed.deinit();

    var statements: std.StringHashMap([]const u8) = .init(arena);
    defer statements.deinit();
    var text_statuses: std.StringHashMap([]const u8) = .init(arena);
    defer text_statuses.deinit();
    var authoritative_sources: std.StringHashMap([]const u8) = .init(arena);
    defer authoritative_sources.deinit();
    var source_counts: std.StringHashMap(usize) = .init(arena);
    defer source_counts.deinit();
    var ordered_ids: std.ArrayList([]const u8) = .empty;
    defer ordered_ids.deinit(arena);
    var unimplemented_ids: std.StringHashMap(void) = .init(arena);
    defer unimplemented_ids.deinit();
    var untested_ids: std.StringHashMap(void) = .init(arena);
    defer untested_ids.deinit();
    var conflicting_ids: std.StringHashMap(void) = .init(arena);
    defer conflicting_ids.deinit();
    var single_source_ids: std.StringHashMap(void) = .init(arena);
    defer single_source_ids.deinit();
    var missing_rtm_ids: std.StringHashMap(void) = .init(arena);
    defer missing_rtm_ids.deinit();
    var missing_requirement_doc_ids: std.StringHashMap(void) = .init(arena);
    defer missing_requirement_doc_ids.deinit();

    if (nodes_parsed.value == .array) {
        for (nodes_parsed.value.array.items) |item| {
            const req_id = internal.json_util.getString(item, "id") orelse continue;
            const props = internal.json_util.getObjectField(item, "properties");
            if (!statements.contains(req_id)) {
                try ordered_ids.append(arena, req_id);
                try statements.put(req_id, if (props) |p| internal.json_util.getString(p, "statement") orelse "" else "");
            }
            const text_status = if (props) |p| internal.json_util.getString(p, "text_status") orelse "no_source" else "no_source";
            const authoritative_source = if (props) |p| internal.json_util.getString(p, "authoritative_source") orelse "" else "";
            const source_count = if (props) |p| internal.json_util.getInt(p, "source_count") orelse 0 else 0;
            try text_statuses.put(req_id, text_status);
            try authoritative_sources.put(req_id, authoritative_source);
            try source_counts.put(req_id, @intCast(source_count));
            if (std.mem.eql(u8, text_status, "conflict")) try conflicting_ids.put(req_id, {});
            if (std.mem.eql(u8, text_status, "single_source")) try single_source_ids.put(req_id, {});
            if (props) |p| {
                const source_assertions = internal.json_util.getObjectField(p, "source_assertions");
                if (source_assertions) |arr| {
                    if (arr == .array) {
                        var has_rtm = false;
                        var has_requirement_doc = false;
                        for (arr.array.items) |assertion| {
                            const source_kind = internal.json_util.getString(assertion, "source_kind") orelse continue;
                            const parsed_kind = design_artifacts.ArtifactKind.fromString(source_kind) orelse continue;
                            if (parsed_kind == .rtm_workbook) has_rtm = true;
                            if (parsed_kind.isRequirementDocKind()) has_requirement_doc = true;
                        }
                        if (has_requirement_doc and !has_rtm) try missing_rtm_ids.put(req_id, {});
                        if (has_rtm and !has_requirement_doc) try missing_requirement_doc_ids.put(req_id, {});
                    }
                }
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
    try std.fmt.format(buf.writer(alloc), "- Total requirements: {d}\n- Requirements without implementation evidence: {d}\n- Requirements without linked tests: {d}\n- Requirements with source conflicts: {d}\n- Single-source requirements: {d}\n- Requirements present in requirement documents but absent from RTM: {d}\n- Requirements present in RTM but absent from requirement documents: {d}\n\n", .{
        ordered_ids.items.len,
        unimplemented_ids.count(),
        untested_ids.count(),
        conflicting_ids.count(),
        single_source_ids.count(),
        missing_rtm_ids.count(),
        missing_requirement_doc_ids.count(),
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

    try buf.appendSlice(alloc, "## Requirements With Source Conflicts\n");
    if (conflicting_ids.count() == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (ordered_ids.items) |req_id| {
            if (!conflicting_ids.contains(req_id)) continue;
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s}\n", .{ req_id, statements.get(req_id) orelse "" });
        }
        try buf.append(alloc, '\n');
    }

    try buf.appendSlice(alloc, "## Requirements Present In Requirement Documents But Absent From RTM\n");
    if (missing_rtm_ids.count() == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (ordered_ids.items) |req_id| {
            if (!missing_rtm_ids.contains(req_id)) continue;
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s}\n", .{ req_id, statements.get(req_id) orelse "" });
        }
        try buf.append(alloc, '\n');
    }

    try buf.appendSlice(alloc, "## Requirements Present In RTM But Absent From Requirement Documents\n");
    if (missing_requirement_doc_ids.count() == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
    } else {
        for (ordered_ids.items) |req_id| {
            if (!missing_requirement_doc_ids.contains(req_id)) continue;
            try std.fmt.format(buf.writer(alloc), "- `{s}` — {s}\n", .{ req_id, statements.get(req_id) orelse "" });
        }
        try buf.append(alloc, '\n');
    }

    try buf.appendSlice(alloc, "## Requirement Inventory\n");
    for (ordered_ids.items) |req_id| {
        try std.fmt.format(buf.writer(alloc), "- `{s}` — {s} [implemented={s}, tested={s}, text_status={s}, source_count={d}, authoritative_source={s}]\n", .{
            req_id,
            statements.get(req_id) orelse "",
            if (unimplemented_ids.contains(req_id)) "no" else "yes",
            if (untested_ids.contains(req_id)) "no" else "yes",
            text_statuses.get(req_id) orelse "no_source",
            source_counts.get(req_id) orelse 0,
            if ((authoritative_sources.get(req_id) orelse "").len > 0) authoritative_sources.get(req_id).? else "none",
        });
    }
    try buf.append(alloc, '\n');
    return alloc.dupe(u8, buf.items);
}

pub fn artifactsIndexMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try design_artifacts.listArtifactsJson(db, arena);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, data, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Design Artifacts\n\n");
    if (parsed.value != .array or parsed.value.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n");
        return alloc.dupe(u8, buf.items);
    }
    try std.fmt.format(buf.writer(alloc), "- Total artifacts: {d}\n\n", .{parsed.value.array.items.len});
    for (parsed.value.array.items) |item| {
        const artifact_id = internal.json_util.getString(item, "artifact_id") orelse continue;
        const display_name = internal.json_util.getString(item, "display_name") orelse artifact_id;
        const kind = internal.json_util.getString(item, "kind") orelse "unknown";
        const conflict_count = internal.json_util.getInt(item, "conflict_count") orelse 0;
        const null_text_count = internal.json_util.getInt(item, "null_text_count") orelse 0;
        const low_confidence_count = internal.json_util.getInt(item, "low_confidence_count") orelse 0;
        try std.fmt.format(buf.writer(alloc), "- [`{s}`](artifact://{s}) — {s} [{s}; conflicts={d}; null_text={d}; low_confidence={d}]\n", .{
            display_name,
            artifact_id,
            artifact_id,
            kind,
            conflict_count,
            null_text_count,
            low_confidence_count,
        });
    }
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

pub fn reviewSummaryMarkdown(db: *internal.graph_live.GraphDb, profile_name: []const u8, state: *internal.sync_live.SyncState, alloc: internal.Allocator) ![]u8 {
    _ = state;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const suspects_json = try internal.routes.handleSuspects(db, arena);
    const gaps_json = try internal.routes.handleChainGaps(db, profile_name, arena);
    const requirements_json = try internal.routes.handleNodes(db, "Requirement", arena);
    var suspects_parsed = try std.json.parseFromSlice(std.json.Value, arena, suspects_json, .{});
    defer suspects_parsed.deinit();
    var gaps_parsed = try std.json.parseFromSlice(std.json.Value, arena, gaps_json, .{});
    defer gaps_parsed.deinit();
    var requirements_parsed = try std.json.parseFromSlice(std.json.Value, arena, requirements_json, .{});
    defer requirements_parsed.deinit();
    var conflicting_requirements: usize = 0;
    if (requirements_parsed.value == .array) {
        for (requirements_parsed.value.array.items) |item| {
            const props = internal.json_util.getObjectField(item, "properties") orelse continue;
            if (std.mem.eql(u8, internal.json_util.getString(props, "text_status") orelse "", "conflict"))
                conflicting_requirements += 1;
        }
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Review Summary\n\n");
    try std.fmt.format(buf.writer(alloc), "- Suspect nodes: {d}\n- Chain gaps: {d}\n- Requirements with source conflicts: {d}\n", .{
        if (suspects_parsed.value == .array) suspects_parsed.value.array.items.len else 0,
        if (gaps_parsed.value == .array) gaps_parsed.value.array.items.len else 0,
        conflicting_requirements,
    });
    return alloc.dupe(u8, buf.items);
}

pub fn appendUserNeedGapSummary(buf: *std.ArrayList(u8), arr: ?std.json.Value, alloc: internal.Allocator) !void {
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
