const std = @import("std");

const internal = @import("../internal.zig");
const common = @import("common.zig");

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
                const annotation_count = if (props) |p| common.getIntField(p, "annotation_count") orelse 0 else 0;
                const requirement_links = common.countFilteredEdges(edges_in, "IMPLEMENTED_IN", "Requirement");
                const design_output_links = common.countFilteredEdges(edges_in, "IMPLEMENTED_IN", "DesignOutput");
                const linked_test_files = common.countFilteredEdges(edges_out, "VERIFIED_BY_CODE", "TestFile");

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
            const annotation_count = if (props) |p| common.getIntField(p, "annotation_count") orelse 0 else 0;
            try std.fmt.format(buf.writer(alloc), "- `test-file://{s}` — annotations: {d}\n", .{
                file_id,
                annotation_count,
            });
        }
        try buf.append(alloc, '\n');
    }

    return alloc.dupe(u8, buf.items);
}
