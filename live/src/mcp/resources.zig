const std = @import("std");
const internal = @import("internal.zig");
const protocol = @import("protocol.zig");
const workbooks = @import("workbooks.zig");
const markdown = @import("markdown.zig");

pub fn resourcesListResult(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"resources\":");
    try buf.appendSlice(alloc, protocol.resources_json);

    var added_any = false;
    const gaps_json = internal.routes.handleChainGaps(db, "generic", arena) catch null;
    if (gaps_json) |gjson| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, gjson, .{});
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            var extras: std.ArrayList(u8) = .empty;
            defer extras.deinit(alloc);
            for (parsed.value.array.items, 0..) |item, idx| {
                if (idx >= 5) break;
                const code = if (internal.json_util.getObjectField(item, "code")) |v| switch (v) {
                    .integer => v.integer,
                    else => 0,
                } else 0;
                const node_id = internal.json_util.getString(item, "node_id") orelse continue;
                if (idx == 0) try extras.appendSlice(alloc, ",");
                try std.fmt.format(extras.writer(alloc), "{{\"uri\":", .{});
                const gap_uri = try std.fmt.allocPrint(arena, "gap://{d}/{s}", .{ code, node_id });
                try internal.json_util.appendJsonQuoted(&extras, gap_uri, alloc);
                try extras.appendSlice(alloc, ",\"name\":");
                try internal.json_util.appendJsonQuoted(&extras, "Gap Explanation", alloc);
                try extras.appendSlice(alloc, ",\"description\":");
                try internal.json_util.appendJsonQuoted(&extras, internal.json_util.getString(item, "title") orelse "Gap detail", alloc);
                try extras.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
                added_any = true;
            }
            if (added_any) {
                _ = buf.pop();
                try buf.appendSlice(alloc, extras.items);
                try buf.append(alloc, ']');
            }
        }
    }

    const rtm_json = internal.routes.handleRtm(db, arena) catch null;
    if (rtm_json) |rjson| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, rjson, .{});
        defer parsed.deinit();
        if (parsed.value == .array and parsed.value.array.items.len > 0) {
            _ = buf.pop();
            for (parsed.value.array.items, 0..) |item, idx| {
                if (idx >= 5) break;
                const req_id = internal.json_util.getString(item, "req_id") orelse continue;
                try buf.append(alloc, ',');
                try buf.appendSlice(alloc, "{\"uri\":");
                const req_uri = try std.fmt.allocPrint(arena, "requirement://{s}", .{req_id});
                try internal.json_util.appendJsonQuoted(&buf, req_uri, alloc);
                try buf.appendSlice(alloc, ",\"name\":");
                try internal.json_util.appendJsonQuoted(&buf, req_id, alloc);
                try buf.appendSlice(alloc, ",\"description\":");
                try internal.json_util.appendJsonQuoted(&buf, internal.json_util.getString(item, "statement") orelse "Requirement trace record", alloc);
                try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
            }
            try buf.append(alloc, ']');
        }
    }

    var bom_items: std.ArrayList(internal.graph_live.Node) = .empty;
    defer internal.shared.freeNodeList(&bom_items, alloc);
    try db.nodesByType("BOMItem", alloc, &bom_items);

    var design_boms: std.ArrayList(internal.graph_live.Node) = .empty;
    defer internal.shared.freeNodeList(&design_boms, alloc);
    try db.nodesByType("DesignBOM", alloc, &design_boms);
    if (design_boms.items.len > 0) {
        _ = buf.pop();
        for (design_boms.items, 0..) |bom_node, idx| {
            if (idx >= 5) break;
            const full_product_identifier = internal.json_util.extractJsonFieldStatic(bom_node.properties, "full_product_identifier") orelse continue;
            const bom_name = internal.json_util.extractJsonFieldStatic(bom_node.properties, "bom_name") orelse continue;
            const uri = try std.fmt.allocPrint(alloc, "design-bom://{s}/{s}", .{ full_product_identifier, bom_name });
            defer alloc.free(uri);
            const display_name = try std.fmt.allocPrint(alloc, "Design BOM {s} / {s}", .{ full_product_identifier, bom_name });
            defer alloc.free(display_name);
            try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"uri\":");
            try internal.json_util.appendJsonQuoted(&buf, uri, alloc);
            try buf.appendSlice(alloc, ",\"name\":");
            try internal.json_util.appendJsonQuoted(&buf, display_name, alloc);
            try buf.appendSlice(alloc, ",\"description\":");
            try internal.json_util.appendJsonQuoted(&buf, "Design BOM tree and trace-coverage summary for one product BOM.", alloc);
            try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
        }
        try buf.append(alloc, ']');
    }

    if (design_boms.items.len > 0) {
        _ = buf.pop();
        var added_software_index = false;
        var count: usize = 0;
        for (design_boms.items) |bom_node| {
            const bom_type = internal.json_util.extractJsonFieldStatic(bom_node.properties, "bom_type") orelse continue;
            if (!std.mem.eql(u8, bom_type, "software")) continue;
            if (!added_software_index) {
                try buf.append(alloc, ',');
                try buf.appendSlice(alloc, "{\"uri\":\"software-boms://\",\"name\":\"Software BOMs\",\"description\":\"Software Design BOM and SOUP register inventory for the active workbook.\",\"mimeType\":\"text/markdown\"}");
                added_software_index = true;
            }
            const full_product_identifier = internal.json_util.extractJsonFieldStatic(bom_node.properties, "full_product_identifier") orelse continue;
            const bom_name = internal.json_util.extractJsonFieldStatic(bom_node.properties, "bom_name") orelse continue;
            const uri = try std.fmt.allocPrint(alloc, "soup-components://{s}/{s}", .{ full_product_identifier, bom_name });
            defer alloc.free(uri);
            const display_name = try std.fmt.allocPrint(alloc, "SOUP {s} / {s}", .{ full_product_identifier, bom_name });
            defer alloc.free(display_name);
            try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"uri\":");
            try internal.json_util.appendJsonQuoted(&buf, uri, alloc);
            try buf.appendSlice(alloc, ",\"name\":");
            try internal.json_util.appendJsonQuoted(&buf, display_name, alloc);
            try buf.appendSlice(alloc, ",\"description\":");
            try internal.json_util.appendJsonQuoted(&buf, "Flattened SOUP/software component register with statuses and unresolved refs.", alloc);
            try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
            count += 1;
            if (count >= 5) break;
        }
        try buf.append(alloc, ']');
    }

    if (bom_items.items.len > 0) {
        _ = buf.pop();
        for (bom_items.items, 0..) |item, idx| {
            if (idx >= 5) break;
            try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"uri\":");
            try internal.json_util.appendJsonQuoted(&buf, item.id, alloc);
            try buf.appendSlice(alloc, ",\"name\":");
            const part = internal.json_util.extractJsonFieldStatic(item.properties, "part") orelse item.id;
            const revision = internal.json_util.extractJsonFieldStatic(item.properties, "revision") orelse "?";
            const name = try std.fmt.allocPrint(alloc, "BOM Item {s}@{s}", .{ part, revision });
            defer alloc.free(name);
            try internal.json_util.appendJsonQuoted(&buf, name, alloc);
            try buf.appendSlice(alloc, ",\"description\":");
            try internal.json_util.appendJsonQuoted(&buf, "Parent chains plus resolved and unresolved requirement/test links for this BOM item.", alloc);
            try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
        }
        var soup_count: usize = 0;
        for (bom_items.items) |item| {
            if (soup_count >= 5) break;
            if (!std.mem.containsAtLeast(u8, item.id, 1, "/software/")) continue;
            const part = internal.json_util.extractJsonFieldStatic(item.properties, "part") orelse continue;
            const revision = internal.json_util.extractJsonFieldStatic(item.properties, "revision") orelse continue;
            const bom_prefix = "bom-item://";
            if (!std.mem.startsWith(u8, item.id, bom_prefix)) continue;
            const rest = item.id[bom_prefix.len..];
            const slash1 = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            const slash2_rel = std.mem.indexOfScalar(u8, rest[slash1 + 1 ..], '/') orelse continue;
            const bom_name = rest[slash1 + 1 + slash2_rel + 1 ..];
            const at = std.mem.lastIndexOfScalar(u8, bom_name, '@') orelse continue;
            const soup_uri = try std.fmt.allocPrint(alloc, "soup-component://{s}/{s}/{s}@{s}", .{
                rest[0..slash1],
                bom_name[0..at],
                part,
                revision,
            });
            defer alloc.free(soup_uri);
            const display_name = try std.fmt.allocPrint(alloc, "SOUP Component {s}@{s}", .{ part, revision });
            defer alloc.free(display_name);
            try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"uri\":");
            try internal.json_util.appendJsonQuoted(&buf, soup_uri, alloc);
            try buf.appendSlice(alloc, ",\"name\":");
            try internal.json_util.appendJsonQuoted(&buf, display_name, alloc);
            try buf.appendSlice(alloc, ",\"description\":");
            try internal.json_util.appendJsonQuoted(&buf, "SOUP component drill-down with trace links, anomaly fields, and unresolved refs.", alloc);
            try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\"}");
            soup_count += 1;
        }
        try buf.append(alloc, ']');
    }

    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn resourceReadResult(uri: []const u8, req_ctx: *const internal.RequestContext, runtime_ctx: *const internal.RuntimeContext) ![]u8 {
    const alloc = req_ctx.alloc;
    const text = if (std.mem.startsWith(u8, uri, "design-bom://"))
        try designBomMarkdown(uri["design-bom://".len..], runtime_ctx.db, alloc)
    else if (std.mem.eql(u8, uri, "software-boms://"))
        try softwareBomsMarkdown(runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "soup-components://"))
        try soupComponentsMarkdown(uri["soup-components://".len..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "soup-component://"))
        try soupComponentMarkdown(uri["soup-component://".len..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "bom-item://"))
        try bomItemTraceMarkdown(uri, runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "requirement://"))
        try markdown.requirementTraceMarkdown(uri[14..], runtime_ctx.db, runtime_ctx.profile_name, alloc)
    else if (std.mem.startsWith(u8, uri, "user-need://"))
        try markdown.nodeMarkdown(uri[12..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "risk://"))
        try markdown.nodeMarkdown(uri[7..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "test://"))
        try markdown.nodeMarkdown(uri[7..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "test-group://"))
        try markdown.nodeMarkdown(uri[13..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "node://"))
        try markdown.nodeMarkdown(uri[7..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "impact://"))
        try markdown.impactMarkdown(uri[9..], runtime_ctx.db, alloc)
    else if (std.mem.startsWith(u8, uri, "design-history://"))
        try markdown.designHistoryMarkdown(uri[17..], runtime_ctx.db, runtime_ctx.profile_name, alloc)
    else if (std.mem.startsWith(u8, uri, "gap://")) blk: {
        const rest = uri[6..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidArgument;
        const code = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.InvalidArgument;
        break :blk try markdown.gapExplanationMarkdown(code, rest[slash + 1 ..], runtime_ctx.db, runtime_ctx.profile_name, alloc);
    } else if (std.mem.eql(u8, uri, "report://status"))
        try markdown.statusMarkdown(req_ctx.registry, req_ctx.secure_store_ref, req_ctx.state, alloc)
    else if (std.mem.eql(u8, uri, "report://chain-gaps"))
        try markdown.chainGapSummaryMarkdown(runtime_ctx.db, runtime_ctx.profile_name, alloc)
    else if (std.mem.eql(u8, uri, "report://rtm"))
        try markdown.rtmSummaryMarkdown(runtime_ctx.db, alloc)
    else if (std.mem.eql(u8, uri, "report://code-traceability"))
        try markdown.codeTraceabilitySummaryMarkdown(runtime_ctx.db, alloc)
    else if (std.mem.eql(u8, uri, "report://review"))
        try markdown.reviewSummaryMarkdown(runtime_ctx.db, runtime_ctx.profile_name, req_ctx.state, alloc)
    else
        return error.NotFound;
    defer alloc.free(text);
    const heading = try workbooks.workbookHeading(req_ctx.registry, alloc);
    defer alloc.free(heading);
    const contextual = try std.fmt.allocPrint(alloc, "{s}{s}", .{ heading, text });
    defer alloc.free(contextual);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"contents\":[{\"uri\":");
    try internal.json_util.appendJsonQuoted(&buf, uri, alloc);
    try buf.appendSlice(alloc, ",\"mimeType\":\"text/markdown\",\"text\":");
    try internal.json_util.appendJsonQuoted(&buf, contextual, alloc);
    try buf.appendSlice(alloc, "}]}");
    return alloc.dupe(u8, buf.items);
}

fn designBomMarkdown(path: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidArgument;
    const full_product_identifier = path[0..slash];
    const bom_name = path[slash + 1 ..];
    const tree_json = try internal.bom.getDesignBomTreeJson(db, full_product_identifier, bom_name, false, alloc);
    defer alloc.free(tree_json);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, tree_json, .{});
    defer parsed.deinit();

    const design_boms = internal.json_util.getObjectField(parsed.value, "design_boms") orelse return error.InvalidJson;
    if (design_boms != .array or design_boms.array.items.len == 0) return error.NotFound;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# Design BOM {s} / {s}\n\n", .{ full_product_identifier, bom_name });
    for (design_boms.array.items) |design_bom| {
        const bom_type = internal.json_util.getString(design_bom, "bom_type") orelse "unknown";
        const source_format = internal.json_util.getString(design_bom, "source_format") orelse "unknown";
        try std.fmt.format(buf.writer(alloc), "## {s}\n- Source Format: {s}\n", .{ bom_type, source_format });
        const properties = internal.json_util.getObjectField(design_bom, "properties");
        if (properties) |props| {
            if (internal.json_util.getString(props, "ingested_at")) |value| {
                try std.fmt.format(buf.writer(alloc), "- Ingested At: {s}\n", .{value});
            }
        }
        const tree = internal.json_util.getObjectField(design_bom, "tree") orelse {
            try buf.append(alloc, '\n');
            continue;
        };
        const roots = internal.json_util.getObjectField(tree, "roots") orelse {
            try buf.append(alloc, '\n');
            continue;
        };
        try buf.appendSlice(alloc, "- Roots:\n");
        try appendTreeChildrenMarkdown(&buf, roots, 0, alloc);
        try buf.append(alloc, '\n');
    }
    return alloc.dupe(u8, buf.items);
}

fn appendTreeChildrenMarkdown(buf: *std.ArrayList(u8), value: std.json.Value, depth: usize, alloc: internal.Allocator) !void {
    if (value != .array or value.array.items.len == 0) {
        try buf.appendSlice(alloc, "  - None\n");
        return;
    }
    for (value.array.items) |item| {
        const properties = internal.json_util.getObjectField(item, "properties") orelse continue;
        const part = internal.json_util.getString(properties, "part") orelse internal.json_util.getString(item, "id") orelse "unknown";
        const revision = internal.json_util.getString(properties, "revision") orelse "?";
        try buf.appendNTimes(alloc, ' ', depth * 2);
        try std.fmt.format(buf.writer(alloc), "- {s}@{s}\n", .{ part, revision });
        if (internal.json_util.getObjectField(item, "children")) |children| {
            try appendTreeChildrenMarkdown(buf, children, depth + 1, alloc);
        }
    }
}

fn bomItemTraceMarkdown(item_id: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const item_json = try internal.bom.getBomItemJson(db, item_id, alloc);
    defer alloc.free(item_json);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, item_json, .{});
    defer parsed.deinit();

    const node = internal.json_util.getObjectField(parsed.value, "node") orelse return error.InvalidJson;
    const properties = internal.json_util.getObjectField(node, "properties") orelse return error.InvalidJson;
    const part = internal.json_util.getString(properties, "part") orelse item_id;
    const revision = internal.json_util.getString(properties, "revision") orelse "?";
    const description = internal.json_util.getString(properties, "description");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try std.fmt.format(buf.writer(alloc), "# BOM Item {s}@{s}\n\n", .{ part, revision });
    try std.fmt.format(buf.writer(alloc), "- ID: `{s}`\n", .{item_id});
    if (description) |value| try std.fmt.format(buf.writer(alloc), "- Description: {s}\n", .{value});
    try buf.append(alloc, '\n');

    try appendParentChainsSection(&buf, internal.json_util.getObjectField(parsed.value, "parent_chains"), alloc);
    try appendStringArraySection(&buf, "Declared Requirement IDs", internal.json_util.getObjectField(properties, "requirement_ids"), alloc);
    try appendStringArraySection(&buf, "Declared Test IDs", internal.json_util.getObjectField(properties, "test_ids"), alloc);
    try appendNodeIdArraySection(&buf, "Linked Requirements", internal.json_util.getObjectField(parsed.value, "linked_requirements"), alloc);
    try appendNodeIdArraySection(&buf, "Linked Tests", internal.json_util.getObjectField(parsed.value, "linked_tests"), alloc);
    try appendStringArraySection(&buf, "Unresolved Requirement IDs", internal.json_util.getObjectField(parsed.value, "unresolved_requirement_ids"), alloc);
    try appendStringArraySection(&buf, "Unresolved Test IDs", internal.json_util.getObjectField(parsed.value, "unresolved_test_ids"), alloc);
    return alloc.dupe(u8, buf.items);
}

fn soupComponentsMarkdown(path: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidArgument;
    const full_product_identifier = path[0..slash];
    const bom_name = path[slash + 1 ..];
    return @constCast(try internal.soup.soupRegisterMarkdown(db, full_product_identifier, bom_name, false, alloc));
}

fn softwareBomsMarkdown(db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const json = try internal.soup.listSoftwareBomsJson(db, null, null, false, alloc);
    defer alloc.free(json);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "# Software BOMs\n\n");
    const rows = internal.json_util.getObjectField(parsed.value, "software_boms") orelse return alloc.dupe(u8, buf.items);
    if (rows != .array or rows.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n");
        return alloc.dupe(u8, buf.items);
    }
    for (rows.array.items) |row| {
        const product = internal.json_util.getString(row, "full_product_identifier") orelse "unknown";
        const bom_name = internal.json_util.getString(row, "bom_name") orelse "SOUP Components";
        const source_format = internal.json_util.getString(row, "source_format") orelse "unknown";
        const item_count: i64 = if (internal.json_util.getObjectField(row, "item_count")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;
        const warning_count: i64 = if (internal.json_util.getObjectField(row, "warning_count")) |v| switch (v) {
            .integer => v.integer,
            else => 0,
        } else 0;
        try std.fmt.format(buf.writer(alloc), "- `{s}` / `{s}` — source `{s}` — items {d} — warnings {d}\n", .{
            product,
            bom_name,
            source_format,
            item_count,
            warning_count,
        });
    }
    return alloc.dupe(u8, buf.items);
}

fn soupComponentMarkdown(path: []const u8, db: *internal.graph_live.GraphDb, alloc: internal.Allocator) ![]u8 {
    const slash1 = std.mem.indexOfScalar(u8, path, '/') orelse return error.InvalidArgument;
    const full_product_identifier = path[0..slash1];
    const rest = path[slash1 + 1 ..];
    const slash2 = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidArgument;
    const bom_name = rest[0..slash2];
    const part_and_rev = rest[slash2 + 1 ..];
    const at = std.mem.lastIndexOfScalar(u8, part_and_rev, '@') orelse return error.InvalidArgument;
    const part = part_and_rev[0..at];
    const revision = part_and_rev[at + 1 ..];
    const item_id = try std.fmt.allocPrint(alloc, "bom-item://{s}/software/{s}/{s}@{s}", .{
        full_product_identifier,
        bom_name,
        part,
        revision,
    });
    defer alloc.free(item_id);
    return bomItemTraceMarkdown(item_id, db, alloc);
}

fn appendParentChainsSection(buf: *std.ArrayList(u8), value: ?std.json.Value, alloc: internal.Allocator) !void {
    try buf.appendSlice(alloc, "## Parent Chains\n");
    const chains = value orelse {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    };
    if (chains != .array or chains.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (chains.array.items) |chain| {
        if (chain != .array or chain.array.items.len == 0) continue;
        try buf.appendSlice(alloc, "- ");
        for (chain.array.items, 0..) |item, idx| {
            if (idx > 0) try buf.appendSlice(alloc, " -> ");
            const id = internal.json_util.getString(item, "id") orelse "unknown";
            try buf.appendSlice(alloc, id);
        }
        try buf.append(alloc, '\n');
    }
    try buf.append(alloc, '\n');
}

fn appendStringArraySection(buf: *std.ArrayList(u8), title: []const u8, value: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    const array_value = value orelse {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    };
    if (array_value != .array or array_value.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (array_value.array.items) |item| {
        if (item != .string) continue;
        try buf.appendSlice(alloc, "- ");
        try buf.appendSlice(alloc, item.string);
        try buf.append(alloc, '\n');
    }
    try buf.append(alloc, '\n');
}

fn appendNodeIdArraySection(buf: *std.ArrayList(u8), title: []const u8, value: ?std.json.Value, alloc: internal.Allocator) !void {
    try std.fmt.format(buf.writer(alloc), "## {s}\n", .{title});
    const array_value = value orelse {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    };
    if (array_value != .array or array_value.array.items.len == 0) {
        try buf.appendSlice(alloc, "- None\n\n");
        return;
    }
    for (array_value.array.items) |item| {
        const id = internal.json_util.getString(item, "id") orelse continue;
        try buf.appendSlice(alloc, "- ");
        try buf.appendSlice(alloc, id);
        try buf.append(alloc, '\n');
    }
    try buf.append(alloc, '\n');
}
