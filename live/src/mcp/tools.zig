const std = @import("std");
const internal = @import("internal.zig");
const workbooks = @import("workbooks.zig");
const markdown = @import("markdown.zig");

const FilterOpts = struct { suspect_field: bool = false };

pub fn invalidArgumentsDispatch(message: []const u8, alloc: internal.Allocator) !internal.ToolDispatch {
    return .{ .invalid_arguments = try alloc.dupe(u8, message) };
}

pub fn jsonPayloadOwned(json: []const u8) internal.ToolPayload {
    return .{
        .text = json,
        .structured_json = json,
        .structured_aliases_text = true,
    };
}

pub fn jsonPayloadOwnedWithNote(json: []const u8, note: ?[]const u8) internal.ToolPayload {
    return .{
        .text = json,
        .note = note,
        .structured_json = json,
        .structured_aliases_text = true,
    };
}

pub fn textPayloadOwned(text: []const u8) internal.ToolPayload {
    return .{ .text = text };
}

pub fn buildToolPayload(
    name: []const u8,
    args: ?std.json.Value,
    req_ctx: *const internal.RequestContext,
    runtime_ctx: *const internal.RuntimeContext,
) !internal.ToolDispatch {
    const alloc = req_ctx.alloc;
    const registry = req_ctx.registry;
    const db = runtime_ctx.db;
    const secure_store_ref = req_ctx.secure_store_ref;
    const state = req_ctx.state;
    const profile_name = runtime_ctx.profile_name;
    const license_service = req_ctx.license_service;
    const refresh_active_runtime_fn = req_ctx.refresh_active_runtime_fn;

    if (std.mem.eql(u8, name, "list_workbooks")) {
        return .{ .payload = jsonPayloadOwned(try workbooks.listWorkbooksJson(registry, alloc)) };
    } else if (std.mem.eql(u8, name, "get_active_workbook")) {
        return .{ .payload = jsonPayloadOwned(try workbooks.activeWorkbookJson(registry, alloc)) };
    } else if (std.mem.eql(u8, name, "switch_workbook")) {
        const workbook_id = if (args) |a| internal.json_util.getString(a, "id") else null;
        const display_name = if (args) |a| internal.json_util.getString(a, "display_name") else null;
        const target_id = if (workbook_id) |id|
            id
        else if (display_name) |name_value|
            blk: {
                const cfg = internal.workbook.config.findByDisplayName(&registry.live_config, name_value) orelse return invalidArgumentsDispatch("switch_workbook requires an existing 'id' or 'display_name'", alloc);
                break :blk cfg.id;
            }
        else
            return invalidArgumentsDispatch("switch_workbook requires 'id' or 'display_name'", alloc);
        _ = try registry.activateWorkbook(target_id, alloc);
        if (refresh_active_runtime_fn) |f| f(registry, secure_store_ref, license_service, alloc);
        return .{ .payload = jsonPayloadOwned(try workbooks.activeWorkbookJson(registry, alloc)) };
    } else if (toolRequiresActiveWorkbook(name) and registry.active_runtime == null) {
        return invalidArgumentsDispatch("No active workbook", alloc);
    } else if (std.mem.eql(u8, name, "get_rtm")) {
        const data = try internal.routes.handleRtm(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{ .suspect_field = true }, alloc) };
    } else if (std.mem.eql(u8, name, "get_gaps")) {
        const data = try internal.routes.handleGaps(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_suspects")) {
        const data = try internal.routes.handleSuspects(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_nodes")) {
        const type_filter = if (args) |a| internal.json_util.getString(a, "type") else null;
        const data = try internal.routes.handleNodes(db, type_filter, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_node")) {
        const node_id = if (args) |a| internal.json_util.getString(a, "id") else null;
        if (node_id == null) return invalidArgumentsDispatch("get_node requires 'id'", alloc);
        const include_edges = getBoolArg(args, "include_edges") orelse true;
        const include_properties = getBoolArg(args, "include_properties") orelse true;
        const data = try internal.routes.handleNode(db, node_id.?, alloc);
        return .{ .payload = try filterNodePayload(data, include_edges, include_properties, alloc) };
    } else if (std.mem.eql(u8, name, "search")) {
        const q = try requireStringArg(args, "q");
        const data = try internal.routes.handleSearch(db, q, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_user_needs")) {
        const data = try internal.routes.handleUserNeeds(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_tests")) {
        const data = try internal.routes.handleTests(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_risks")) {
        const data = try internal.routes.handleRisks(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "get_impact")) {
        const node_id = try requireStringArg(args, "id");
        const data = try internal.routes.handleImpact(db, node_id, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "get_schema")) {
        const data = try internal.routes.handleSchema(db, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "get_status")) {
        const data = try internal.routes.handleStatus(registry, secure_store_ref, state, license_service, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "clear_suspect")) {
        const node_id = try requireStringArg(args, "id");
        const data = try internal.routes.handleClearSuspect(db, node_id, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "code_traceability")) {
        const data = try internal.routes.handleCodeTraceability(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filterCodeTraceabilityPayload(data, args, alloc) };
    } else if (std.mem.eql(u8, name, "unimplemented_requirements")) {
        const data = try internal.routes.handleUnimplementedRequirements(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "untested_source_files")) {
        const data = try internal.routes.handleUntestedSourceFiles(db, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "file_annotations")) {
        const file_path = try requireStringArg(args, "file_path");
        const data = try internal.routes.handleFileAnnotations(db, file_path, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "blame_for_requirement")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try internal.routes.handleBlameForRequirement(db, req_id, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "commit_history")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try internal.routes.handleCommitHistory(db, req_id, alloc);
        defer alloc.free(data);
        return .{ .payload = try filteredArrayPayload(data, args, .{}, alloc) };
    } else if (std.mem.eql(u8, name, "design_history")) {
        const req_id = try requireStringArg(args, "req_id");
        const data = try internal.routes.handleDesignHistory(db, profile_name, req_id, alloc);
        return .{ .payload = jsonPayloadOwned(data) };
    } else if (std.mem.eql(u8, name, "get_test_results")) {
        const test_case_ref = try requireStringArg(args, "test_case_ref");
        return .{ .payload = jsonPayloadOwned(try internal.test_results.getTestResultsJson(db, test_case_ref, alloc)) };
    } else if (std.mem.eql(u8, name, "get_execution")) {
        const execution_id = try requireStringArg(args, "execution_id");
        const data = try internal.test_results.getExecutionJson(db, execution_id, alloc);
        return .{ .payload = jsonPayloadOwned(if (data) |value| value else try alloc.dupe(u8, "{\"error\":\"not_found\"}")) };
    } else if (std.mem.eql(u8, name, "get_verification_status")) {
        const requirement_ref = try requireStringArg(args, "requirement_ref");
        return .{ .payload = jsonPayloadOwned(try internal.test_results.verificationJson(db, requirement_ref, alloc)) };
    } else if (std.mem.eql(u8, name, "get_dangling_results")) {
        return .{ .payload = jsonPayloadOwned(try internal.test_results.danglingResultsJson(db, alloc)) };
    } else if (std.mem.eql(u8, name, "get_unit_history")) {
        const serial_number = try requireStringArg(args, "serial_number");
        return .{ .payload = jsonPayloadOwned(try internal.test_results.unitHistoryJson(db, serial_number, alloc)) };
    } else if (std.mem.eql(u8, name, "get_bom")) {
        const full_product_identifier = try requireStringArg(args, "full_product_identifier");
        const bom_type = if (args) |a| internal.json_util.getString(a, "bom_type") else null;
        const bom_name = if (args) |a| internal.json_util.getString(a, "bom_name") else null;
        const include_obsolete = getBoolArg(args, "include_obsolete") orelse false;
        return .{ .payload = jsonPayloadOwned(try internal.bom.getBomJson(db, full_product_identifier, bom_type, bom_name, include_obsolete, alloc)) };
    } else if (std.mem.eql(u8, name, "get_bom_item")) {
        const item_id = if (args) |a| blk: {
            if (internal.json_util.getString(a, "id")) |value| break :blk try alloc.dupe(u8, value);
            const full_product_identifier = internal.json_util.getString(a, "full_product_identifier") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const bom_type = internal.json_util.getString(a, "bom_type") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const bom_name = internal.json_util.getString(a, "bom_name") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const part = internal.json_util.getString(a, "part") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            const revision = internal.json_util.getString(a, "revision") orelse return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
            break :blk try std.fmt.allocPrint(alloc, "bom-item://{s}/{s}/{s}/{s}@{s}", .{
                full_product_identifier,
                bom_type,
                bom_name,
                part,
                revision,
            });
        } else return invalidArgumentsDispatch("get_bom_item requires either 'id' or the full selector: full_product_identifier, bom_type, bom_name, part, revision", alloc);
        defer alloc.free(item_id);
        return .{ .payload = jsonPayloadOwned(try internal.bom.getBomItemJson(db, item_id, alloc)) };
    } else if (std.mem.eql(u8, name, "list_design_boms")) {
        const full_product_identifier = if (args) |a| internal.json_util.getString(a, "full_product_identifier") else null;
        const bom_name = if (args) |a| internal.json_util.getString(a, "bom_name") else null;
        const include_obsolete = getBoolArg(args, "include_obsolete") orelse false;
        return .{ .payload = jsonPayloadOwned(try internal.bom.listDesignBomsJson(db, full_product_identifier, bom_name, include_obsolete, alloc)) };
    } else if (std.mem.eql(u8, name, "find_part_usage")) {
        const part = try requireStringArg(args, "part");
        const include_obsolete = getBoolArg(args, "include_obsolete") orelse false;
        return .{ .payload = jsonPayloadOwned(try internal.bom.findPartUsageJson(db, part, include_obsolete, alloc)) };
    } else if (std.mem.eql(u8, name, "bom_gaps")) {
        const full_product_identifier = if (args) |a| internal.json_util.getString(a, "full_product_identifier") else null;
        const bom_name = if (args) |a| internal.json_util.getString(a, "bom_name") else null;
        const include_inactive = getBoolArg(args, "include_inactive") orelse false;
        return .{ .payload = jsonPayloadOwned(try internal.bom.bomGapsJson(db, full_product_identifier, bom_name, include_inactive, alloc)) };
    } else if (std.mem.eql(u8, name, "bom_impact_analysis")) {
        const full_product_identifier = try requireStringArg(args, "full_product_identifier");
        const bom_name = try requireStringArg(args, "bom_name");
        const include_obsolete = getBoolArg(args, "include_obsolete") orelse false;
        return .{ .payload = jsonPayloadOwned(try internal.bom.bomImpactAnalysisJson(db, full_product_identifier, bom_name, include_obsolete, alloc)) };
    } else if (std.mem.eql(u8, name, "get_product_serials")) {
        const full_product_identifier = try requireStringArg(args, "full_product_identifier");
        return .{ .payload = jsonPayloadOwned(try internal.bom.getProductSerialsJson(db, full_product_identifier, alloc)) };
    } else if (std.mem.eql(u8, name, "get_components_by_supplier")) {
        const supplier = try requireStringArg(args, "supplier");
        return .{ .payload = jsonPayloadOwned(try internal.bom.getComponentsBySupplierJson(db, supplier, alloc)) };
    } else if (std.mem.eql(u8, name, "get_software_components")) {
        const purl_prefix = if (args) |a| internal.json_util.getString(a, "purl_prefix") else null;
        const license_filter = if (args) |a| internal.json_util.getString(a, "license") else null;
        return .{ .payload = jsonPayloadOwned(try internal.bom.getSoftwareComponentsJson(db, purl_prefix, license_filter, alloc)) };
    } else if (std.mem.eql(u8, name, "chain_gaps")) {
        return .{ .payload = try chainGapsToolPayload(db, args, alloc) };
    } else if (std.mem.eql(u8, name, "implementation_changes_since")) {
        const since = if (args) |a| internal.json_util.getString(a, "since") else null;
        const node_type = if (args) |a| internal.json_util.getString(a, "node_type") else null;
        if (since == null or node_type == null) return invalidArgumentsDispatch("implementation_changes_since requires 'since' and 'node_type'", alloc);
        const repo = if (args) |a| internal.json_util.getString(a, "repo") else null;
        const limit_arg = getIntArg(args, "limit");
        const offset_arg = getIntArg(args, "offset");
        const limit = if (limit_arg) |v| try std.fmt.allocPrint(alloc, "{d}", .{v}) else null;
        defer if (limit) |v| alloc.free(v);
        const offset = if (offset_arg) |v| try std.fmt.allocPrint(alloc, "{d}", .{v}) else null;
        defer if (offset) |v| alloc.free(v);
        const data = try internal.routes.handleImplementationChangesResponse(db, since.?, node_type.?, repo, limit, offset, alloc);
        if (!data.ok) return invalidArgumentsDispatch("implementation_changes_since requires 'since' and 'node_type'", alloc);
        defer alloc.free(data.body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data.body, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return .{ .payload = jsonPayloadOwned(try alloc.dupe(u8, data.body)) };
        const note = if (limit_arg != null and parsed.value.array.items.len > 0)
            try std.fmt.allocPrint(alloc, "Returned {d} implementation-change rows using file/commit evidence.", .{parsed.value.array.items.len})
        else
            null;
        return .{ .payload = jsonPayloadOwnedWithNote(try alloc.dupe(u8, data.body), note) };
    } else if (std.mem.eql(u8, name, "requirement_trace")) {
        const id = try requireStringArg(args, "id");
        return .{ .payload = textPayloadOwned(try markdown.requirementTraceMarkdown(id, db, profile_name, alloc)) };
    } else if (std.mem.eql(u8, name, "gap_explanation")) {
        const code = try requireIntArg(args, "code");
        const node_id = try requireStringArg(args, "node_id");
        return .{ .payload = textPayloadOwned(try markdown.gapExplanationMarkdown(@intCast(code), node_id, db, profile_name, alloc)) };
    } else if (std.mem.eql(u8, name, "impact_summary")) {
        const id = try requireStringArg(args, "id");
        return .{ .payload = textPayloadOwned(try markdown.impactMarkdown(id, db, alloc)) };
    } else if (std.mem.eql(u8, name, "status_summary")) {
        return .{ .payload = textPayloadOwned(try markdown.statusMarkdown(registry, secure_store_ref, state, alloc)) };
    } else if (std.mem.eql(u8, name, "review_summary")) {
        return .{ .payload = textPayloadOwned(try markdown.reviewSummaryMarkdown(db, profile_name, state, alloc)) };
    }
    return .{ .not_found = {} };
}

pub fn filteredArrayPayload(data_json: []const u8, args: ?std.json.Value, opts: FilterOpts, alloc: internal.Allocator) !internal.ToolPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return jsonPayloadOwned(try alloc.dupe(u8, data_json));

    const offset = @max(getIntArg(args, "offset") orelse 0, 0);
    const limit = getIntArg(args, "limit");
    const suspect_only = opts.suspect_field and (getBoolArg(args, "suspect_only") orelse false);

    var filtered: std.ArrayList(std.json.Value) = .empty;
    defer filtered.deinit(alloc);
    for (parsed.value.array.items) |item| {
        if (suspect_only) {
            const suspect = if (internal.json_util.getObjectField(item, "suspect")) |v| switch (v) {
                .bool => v.bool,
                else => false,
            } else false;
            if (!suspect) continue;
        }
        try filtered.append(alloc, item);
    }

    var out: std.ArrayList(std.json.Value) = .empty;
    defer out.deinit(alloc);
    const start: usize = @intCast(@min(offset, @as(i64, @intCast(filtered.items.len))));
    const max_count: usize = if (limit) |l| @intCast(@max(l, 0)) else filtered.items.len;
    var i = start;
    while (i < filtered.items.len and out.items.len < max_count) : (i += 1) {
        try out.append(alloc, filtered.items[i]);
    }

    const out_json = try jsonArrayFromValues(out.items, alloc);
    const truncated = limit != null and (start + out.items.len < filtered.items.len);
    if (truncated) {
        const note = try std.fmt.allocPrint(alloc, "Truncated results to {d} of {d} items.", .{ out.items.len, filtered.items.len });
        return jsonPayloadOwnedWithNote(out_json, note);
    }
    return jsonPayloadOwned(out_json);
}

pub fn filterNodePayload(data_json: []const u8, include_edges: bool, include_properties: bool, alloc: internal.Allocator) !internal.ToolPayload {
    if (include_edges and include_properties) return jsonPayloadOwned(data_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return jsonPayloadOwned(data_json);

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return jsonPayloadOwned(data_json);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"node\":{\"id\":");
    try internal.json_util.appendJsonQuoted(&buf, internal.json_util.getString(node, "id") orelse "unknown", alloc);
    try buf.appendSlice(alloc, ",\"type\":");
    try internal.json_util.appendJsonQuoted(&buf, internal.json_util.getString(node, "type") orelse "Node", alloc);
    if (include_properties) {
        const properties = internal.json_util.getObjectField(node, "properties") orelse std.json.Value{ .null = {} };
        try buf.appendSlice(alloc, ",\"properties\":");
        try appendJsonValue(&buf, properties, alloc);
    }
    const suspect = if (internal.json_util.getObjectField(node, "suspect")) |v| switch (v) {
        .bool => v.bool,
        else => false,
    } else false;
    try buf.appendSlice(alloc, ",\"suspect\":");
    try buf.appendSlice(alloc, if (suspect) "true" else "false");
    const suspect_reason = internal.json_util.getObjectField(node, "suspect_reason") orelse std.json.Value{ .null = {} };
    try buf.appendSlice(alloc, ",\"suspect_reason\":");
    try appendJsonValue(&buf, suspect_reason, alloc);
    try buf.append(alloc, '}');
    if (include_edges) {
        const empty_values = [_]std.json.Value{};
        const empty_array = std.json.Value{ .array = .{ .items = &empty_values, .capacity = 0, .allocator = alloc } };
        try buf.appendSlice(alloc, ",\"edges_out\":");
        try appendJsonValue(&buf, internal.json_util.getObjectField(parsed.value, "edges_out") orelse empty_array, alloc);
        try buf.appendSlice(alloc, ",\"edges_in\":");
        try appendJsonValue(&buf, internal.json_util.getObjectField(parsed.value, "edges_in") orelse empty_array, alloc);
    }
    try buf.append(alloc, '}');
    alloc.free(data_json);
    return jsonPayloadOwned(try alloc.dupe(u8, buf.items));
}

pub fn filterCodeTraceabilityPayload(data_json: []const u8, args: ?std.json.Value, alloc: internal.Allocator) !internal.ToolPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return jsonPayloadOwned(try alloc.dupe(u8, data_json));
    const repo_filter = if (args) |a| internal.json_util.getString(a, "repo") else null;
    const limit = getIntArg(args, "limit");

    const empty_values = [_]std.json.Value{};
    const src_val = parsed.value.object.get("source_files") orelse std.json.Value{ .array = .{ .items = &empty_values, .capacity = 0, .allocator = alloc } };
    const test_val = parsed.value.object.get("test_files") orelse std.json.Value{ .array = .{ .items = &empty_values, .capacity = 0, .allocator = alloc } };
    var src_out: std.ArrayList(std.json.Value) = .empty;
    defer src_out.deinit(alloc);
    var test_out: std.ArrayList(std.json.Value) = .empty;
    defer test_out.deinit(alloc);

    if (src_val == .array) {
        for (src_val.array.items) |item| {
            if (repo_filter) |repo| if (!nodeMatchesRepo(item, repo)) continue;
            if (limit != null and src_out.items.len >= @as(usize, @intCast(@max(limit.?, 0)))) break;
            try src_out.append(alloc, item);
        }
    }
    if (test_val == .array) {
        for (test_val.array.items) |item| {
            if (repo_filter) |repo| if (!nodeMatchesRepo(item, repo)) continue;
            if (limit != null and test_out.items.len >= @as(usize, @intCast(@max(limit.?, 0)))) break;
            try test_out.append(alloc, item);
        }
    }

    const src_json = try jsonArrayFromValues(src_out.items, alloc);
    defer alloc.free(src_json);
    const test_json = try jsonArrayFromValues(test_out.items, alloc);
    defer alloc.free(test_json);
    const out_json = try std.fmt.allocPrint(alloc, "{{\"source_files\":{s},\"test_files\":{s}}}", .{ src_json, test_json });

    var truncated = false;
    if (limit) |l| {
        if (src_val == .array and src_val.array.items.len > @as(usize, @intCast(@max(l, 0)))) truncated = true;
        if (test_val == .array and test_val.array.items.len > @as(usize, @intCast(@max(l, 0)))) truncated = true;
    }
    if (truncated) {
        const note = try std.fmt.allocPrint(alloc, "Truncated code traceability results to {d} source files and {d} test files.", .{ src_out.items.len, test_out.items.len });
        return jsonPayloadOwnedWithNote(out_json, note);
    }
    return jsonPayloadOwned(out_json);
}

pub fn chainGapsToolPayload(db: *internal.graph_live.GraphDb, args: ?std.json.Value, alloc: internal.Allocator) !internal.ToolPayload {
    const prof_name = if (args) |a| internal.json_util.getString(a, "profile") else null;
    const pid = if (prof_name) |n| internal.profile_mod.fromString(n) orelse return error.InvalidArgument else null;
    const data = if (pid) |profile_id| blk: {
        const prof = internal.profile_mod.get(profile_id);
        const edge_gaps = try internal.chain_mod.walkChain(db, prof, alloc);
        defer alloc.free(edge_gaps);
        const special_gaps = try internal.chain_mod.walkSpecialGaps(db, prof, alloc);
        defer alloc.free(special_gaps);
        var all: std.ArrayList(internal.chain_mod.Gap) = .empty;
        defer all.deinit(alloc);
        try all.appendSlice(alloc, edge_gaps);
        try all.appendSlice(alloc, special_gaps);
        break :blk try internal.chain_mod.gapsToJson(all.items, alloc);
    } else try internal.routes.handleChainGaps(db, prof_name orelse "generic", alloc);
    defer alloc.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return jsonPayloadOwned(try alloc.dupe(u8, data));
    const severity_filter = if (args) |a| internal.json_util.getString(a, "severity") else null;
    const offset = @max(getIntArg(args, "offset") orelse 0, 0);
    const limit = getIntArg(args, "limit");
    var filtered: std.ArrayList(std.json.Value) = .empty;
    defer filtered.deinit(alloc);
    for (parsed.value.array.items) |item| {
        if (severity_filter) |sev| {
            const item_sev = internal.json_util.getString(item, "severity") orelse continue;
            if (!std.mem.eql(u8, item_sev, sev)) continue;
        }
        try filtered.append(alloc, item);
    }
    var out: std.ArrayList(std.json.Value) = .empty;
    defer out.deinit(alloc);
    const start: usize = @intCast(@min(offset, @as(i64, @intCast(filtered.items.len))));
    const max_count: usize = if (limit) |l| @intCast(@max(l, 0)) else filtered.items.len;
    var i: usize = start;
    while (i < filtered.items.len and out.items.len < max_count) : (i += 1) try out.append(alloc, filtered.items[i]);
    const out_json = try jsonArrayFromValues(out.items, alloc);
    const truncated = limit != null and (start + out.items.len < filtered.items.len);
    if (truncated) {
        const note = try std.fmt.allocPrint(alloc, "Truncated chain gaps to {d} of {d} items.", .{ out.items.len, filtered.items.len });
        return jsonPayloadOwnedWithNote(out_json, note);
    }
    return jsonPayloadOwned(out_json);
}

pub fn requireStringArg(args: ?std.json.Value, key: []const u8) ![]const u8 {
    return if (args) |a| internal.json_util.getString(a, key) orelse error.InvalidArgument else error.InvalidArgument;
}

pub fn requireIntArg(args: ?std.json.Value, key: []const u8) !i64 {
    return getIntArg(args, key) orelse error.InvalidArgument;
}

pub fn getIntArg(args: ?std.json.Value, key: []const u8) ?i64 {
    const field = if (args) |a| internal.json_util.getObjectField(a, key) else null;
    return if (field) |v| switch (v) {
        .integer => v.integer,
        else => null,
    } else null;
}

pub fn getBoolArg(args: ?std.json.Value, key: []const u8) ?bool {
    const field = if (args) |a| internal.json_util.getObjectField(a, key) else null;
    return if (field) |v| switch (v) {
        .bool => v.bool,
        else => null,
    } else null;
}

pub fn toolRequiresActiveWorkbook(name: []const u8) bool {
    return !(std.mem.eql(u8, name, "list_workbooks") or
        std.mem.eql(u8, name, "get_active_workbook") or
        std.mem.eql(u8, name, "switch_workbook") or
        std.mem.eql(u8, name, "get_status") or
        std.mem.eql(u8, name, "status_summary"));
}

pub fn toolIsNarrative(name: []const u8) bool {
    return std.mem.eql(u8, name, "requirement_trace") or
        std.mem.eql(u8, name, "gap_explanation") or
        std.mem.eql(u8, name, "impact_summary") or
        std.mem.eql(u8, name, "status_summary") or
        std.mem.eql(u8, name, "review_summary");
}

fn nodeMatchesRepo(item: std.json.Value, repo: []const u8) bool {
    const props = internal.json_util.getObjectField(item, "properties") orelse return false;
    const prop_repo = internal.json_util.getString(props, "repo") orelse return false;
    return std.mem.eql(u8, prop_repo, repo);
}

pub fn appendJsonValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: internal.Allocator) !void {
    const piece = try std.json.Stringify.valueAlloc(alloc, value, .{});
    defer alloc.free(piece);
    try buf.appendSlice(alloc, piece);
}

pub fn jsonArrayFromValues(items: []const std.json.Value, alloc: internal.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '[');
    for (items, 0..) |item, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        const piece = try std.json.Stringify.valueAlloc(alloc, item, .{});
        defer alloc.free(piece);
        try buf.appendSlice(alloc, piece);
    }
    try buf.append(alloc, ']');
    return alloc.dupe(u8, buf.items);
}
