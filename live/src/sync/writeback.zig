const std = @import("std");
const internal = @import("internal.zig");

const WritebackPlan = struct {
    value_updates: std.ArrayList(internal.ValueUpdate),
    row_formats: std.ArrayList(internal.RowFormat),

    fn deinit(self: *WritebackPlan, alloc: internal.Allocator) void {
        for (self.value_updates.items) |upd| {
            alloc.free(upd.a1_range);
            for (upd.values) |value| alloc.free(value);
            alloc.free(upd.values);
        }
        self.value_updates.deinit(alloc);
        self.row_formats.deinit(alloc);
    }
};

pub fn requirementStatus(db: *internal.GraphDb, req_id: []const u8, alloc: internal.Allocator) []const u8 {
    const node = db.getNode(req_id, alloc) catch return "ERROR";
    if (node == null) return "MISSING";
    defer if (node) |n| {
        alloc.free(n.id);
        alloc.free(n.type);
        alloc.free(n.properties);
        if (n.suspect_reason) |r| alloc.free(r);
    };
    var tests: std.ArrayList(internal.graph_live.Edge) = .empty;
    db.edgesFrom(req_id, alloc, &tests) catch return "ERROR";
    defer {
        for (tests.items) |e| {
            alloc.free(e.id);
            alloc.free(e.from_id);
            alloc.free(e.to_id);
            alloc.free(e.label);
        }
        tests.deinit(alloc);
    }
    var has_test = false;
    for (tests.items) |e| {
        if (std.mem.eql(u8, e.label, "TESTED_BY") or std.mem.eql(u8, e.label, "HAS_TEST")) {
            has_test = true;
            break;
        }
    }
    if (!has_test) return "NO_TEST_LINKED";
    return "OK";
}

pub fn statusColorHex(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "OK")) return "#B6E1CD";
    if (std.mem.eql(u8, status, "NO_TEST_LINKED") or
        std.mem.eql(u8, status, "MISSING_FULL_IDENTIFIER") or
        std.mem.eql(u8, status, "NO_REQ_LINKED") or
        std.mem.eql(u8, status, "MISSING") or
        std.mem.eql(u8, status, "PRODUCT_UNKNOWN_STATUS")) return "#FCE8B2";
    return "#F4C7C3";
}

fn isRecognizedProductStatus(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \r\n\t");
    if (value.len == 0) return true;
    return std.ascii.eqlIgnoreCase(value, "Active") or
        std.ascii.eqlIgnoreCase(value, "In Development") or
        std.ascii.eqlIgnoreCase(value, "Development") or
        std.ascii.eqlIgnoreCase(value, "Superseded") or
        std.ascii.eqlIgnoreCase(value, "EOL") or
        std.ascii.eqlIgnoreCase(value, "End of Life") or
        std.ascii.eqlIgnoreCase(value, "Obsolete");
}

pub fn writeBackStatus(
    db: *internal.GraphDb,
    runtime: *internal.ProviderRuntime,
    req_rows: []const []const []const u8,
    risk_rows: []const []const []const u8,
    un_rows: []const []const []const u8,
    product_rows: []const []const []const u8,
    alloc: internal.Allocator,
) !void {
    var plan = try buildWritebackPlan(db, req_rows, risk_rows, un_rows, product_rows, alloc);
    defer plan.deinit(alloc);

    if (plan.value_updates.items.len > 0) {
        runtime.batchWriteValues(plan.value_updates.items, alloc) catch |e| {
            std.log.warn("sync: status writeback failed: {s}", .{@errorName(e)});
        };
    }
    if (plan.row_formats.items.len > 0) {
        runtime.applyRowFormats(plan.row_formats.items, alloc) catch |e| {
            std.log.warn("sync: color writeback failed: {s}", .{@errorName(e)});
        };
    }
}

fn buildWritebackPlan(
    db: *internal.GraphDb,
    req_rows: []const []const []const u8,
    risk_rows: []const []const []const u8,
    un_rows: []const []const []const u8,
    product_rows: []const []const []const u8,
    alloc: internal.Allocator,
) !WritebackPlan {
    var plan: WritebackPlan = .{
        .value_updates = .empty,
        .row_formats = .empty,
    };
    errdefer plan.deinit(alloc);

    if (req_rows.len > 1) {
        const header = req_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        const verification_col = findCol(header, "RTMify Verification") orelse header.len;
        if (id_col != null and status_col != null) {
            const scol = status_col.?;
            if (verification_col == header.len) {
                const header_col_letter = colLetterBuf(verification_col);
                const header_range = try std.fmt.allocPrint(alloc, "Requirements!{s}1", .{colLetterRef(header_col_letter, verification_col)});
                const header_values = try alloc.alloc([]const u8, 1);
                header_values[0] = try alloc.dupe(u8, "RTMify Verification");
                try plan.value_updates.append(alloc, .{ .a1_range = header_range, .values = header_values });
            }
            for (req_rows[1..], 0..) |row, i| {
                const row_num = i + 2;
                const req_id = if (id_col.? < row.len) row[id_col.?] else "";
                if (req_id.len == 0) continue;
                const status = requirementStatus(db, req_id, alloc);
                const col_letter = colLetterBuf(scol);
                const range = try std.fmt.allocPrint(alloc, "Requirements!{s}{d}", .{ colLetterRef(col_letter, scol), row_num });
                const values = try alloc.alloc([]const u8, 1);
                values[0] = try alloc.dupe(u8, status);
                try plan.value_updates.append(alloc, .{ .a1_range = range, .values = values });

                var verification = try internal.test_results.verificationForRequirement(db, req_id, alloc);
                defer verification.deinit(alloc);
                const verification_value: []const u8 = if (verification.linked_test_groups.len == 0 and verification.linked_tests.len == 0)
                    ""
                else
                    @tagName(verification.state);
                const verification_col_letter = colLetterBuf(verification_col);
                const verification_range = try std.fmt.allocPrint(alloc, "Requirements!{s}{d}", .{ colLetterRef(verification_col_letter, verification_col), row_num });
                const verification_values = try alloc.alloc([]const u8, 1);
                verification_values[0] = try alloc.dupe(u8, verification_value);
                try plan.value_updates.append(alloc, .{ .a1_range = verification_range, .values = verification_values });

                try plan.row_formats.append(alloc, .{
                    .tab_title = "Requirements",
                    .row_1based = row_num,
                    .col_start_1based = 1,
                    .col_end_1based = if (verification_col == header.len) header.len + 1 else header.len,
                    .fill_hex = statusColorHex(status),
                });
            }
        }
    }

    if (risk_rows.len > 1) {
        const header = risk_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        if (id_col != null and status_col != null) {
            for (risk_rows[1..], 0..) |row, i| {
                const row_num = i + 2;
                const risk_id = if (id_col.? < row.len) row[id_col.?] else "";
                if (risk_id.len == 0) continue;
                const node = db.getNode(risk_id, alloc) catch null;
                const status: []const u8 = if (node != null) "OK" else "MISSING";
                if (node) |n| {
                    alloc.free(n.id);
                    alloc.free(n.type);
                    alloc.free(n.properties);
                    if (n.suspect_reason) |r| alloc.free(r);
                }
                const col_letter = colLetterBuf(status_col.?);
                const range = try std.fmt.allocPrint(alloc, "Risks!{s}{d}", .{ colLetterRef(col_letter, status_col.?), row_num });
                const values = try alloc.alloc([]const u8, 1);
                values[0] = try alloc.dupe(u8, status);
                try plan.value_updates.append(alloc, .{ .a1_range = range, .values = values });
                try plan.row_formats.append(alloc, .{
                    .tab_title = "Risks",
                    .row_1based = row_num,
                    .col_start_1based = 1,
                    .col_end_1based = header.len,
                    .fill_hex = statusColorHex(status),
                });
            }
        }
    }

    if (un_rows.len > 1) {
        const header = un_rows[0];
        const id_col = findCol(header, "ID");
        const status_col = findCol(header, "Status");
        if (id_col != null and status_col != null) {
            for (un_rows[1..], 0..) |row, i| {
                const row_num = i + 2;
                const un_id = if (id_col.? < row.len) row[id_col.?] else "";
                if (un_id.len == 0) continue;
                var edges: std.ArrayList(internal.graph_live.Edge) = .empty;
                db.edgesTo(un_id, alloc, &edges) catch {
                    edges.deinit(alloc);
                    continue;
                };
                var linked = false;
                for (edges.items) |e| {
                    if (std.mem.eql(u8, e.label, "DERIVES_FROM")) {
                        linked = true;
                        break;
                    }
                }
                for (edges.items) |e| {
                    alloc.free(e.id);
                    alloc.free(e.from_id);
                    alloc.free(e.to_id);
                    alloc.free(e.label);
                }
                edges.deinit(alloc);
                const status: []const u8 = if (linked) "OK" else "NO_REQ_LINKED";
                const col_letter = colLetterBuf(status_col.?);
                const range = try std.fmt.allocPrint(alloc, "User Needs!{s}{d}", .{ colLetterRef(col_letter, status_col.?), row_num });
                const values = try alloc.alloc([]const u8, 1);
                values[0] = try alloc.dupe(u8, status);
                try plan.value_updates.append(alloc, .{ .a1_range = range, .values = values });
                try plan.row_formats.append(alloc, .{
                    .tab_title = "User Needs",
                    .row_1based = row_num,
                    .col_start_1based = 1,
                    .col_end_1based = header.len,
                    .fill_hex = statusColorHex(status),
                });
            }
        }
    }

    try appendProductWriteback(&plan.value_updates, &plan.row_formats, product_rows, alloc);
    return plan;
}

pub fn normalizeProductCell(raw: []const u8, alloc: internal.Allocator) ![]const u8 {
    const normalized = try internal.xlsx.normalizeCell(raw, alloc);
    return std.mem.trim(u8, normalized, " ");
}

pub fn appendProductWriteback(
    value_updates: *std.ArrayList(internal.ValueUpdate),
    row_formats: *std.ArrayList(internal.RowFormat),
    product_rows: []const []const []const u8,
    alloc: internal.Allocator,
) !void {
    if (product_rows.len == 0) return;

    const header = product_rows[0];
    const assembly_col = findCol(header, "assembly");
    const revision_col = findCol(header, "revision");
    const identifier_col = findCol(header, "full_identifier");
    const description_col = findCol(header, "description");
    const product_status_col = findCol(header, "Product Status");
    const rtmify_status_col = findCol(header, "RTMify Status") orelse 5;

    if (findCol(header, "RTMify Status") == null) {
        try appendSingleValueUpdate(value_updates, "Product", rtmify_status_col, 1, "RTMify Status", alloc);
    }

    if (product_rows.len == 1) {
        try appendSingleValueUpdate(value_updates, "Product", rtmify_status_col, 2, "NO_PRODUCT_DECLARED", alloc);
        return;
    }

    var seen_identifiers = std.StringHashMap(void).init(alloc);
    defer {
        var it = seen_identifiers.iterator();
        while (it.next()) |entry| alloc.free(entry.key_ptr.*);
        seen_identifiers.deinit();
    }

    for (product_rows[1..], 0..) |row, i| {
        const row_num = i + 2;
        const assembly_raw = if (assembly_col) |col| if (col < row.len) row[col] else "" else "";
        const revision_raw = if (revision_col) |col| if (col < row.len) row[col] else "" else "";
        const identifier_raw = if (identifier_col) |col| if (col < row.len) row[col] else "" else "";
        const description_raw = if (description_col) |col| if (col < row.len) row[col] else "" else "";
        const product_status_raw = if (product_status_col) |col| if (col < row.len) row[col] else "" else "";

        if (internal.schema.isBlankEquivalent(assembly_raw) and
            internal.schema.isBlankEquivalent(revision_raw) and
            internal.schema.isBlankEquivalent(identifier_raw) and
            internal.schema.isBlankEquivalent(description_raw) and
            internal.schema.isBlankEquivalent(product_status_raw))
        {
            continue;
        }

        var keep_identifier = false;
        const normalized_identifier = try normalizeProductCell(identifier_raw, alloc);
        defer if (!keep_identifier) alloc.free(normalized_identifier);
        const status: []const u8 = blk: {
            if (normalized_identifier.len == 0 or internal.schema.isBlankEquivalent(normalized_identifier)) {
                break :blk "MISSING_FULL_IDENTIFIER";
            }
            if (seen_identifiers.contains(normalized_identifier)) {
                break :blk "DUPLICATE_FULL_IDENTIFIER";
            }
            try seen_identifiers.put(normalized_identifier, {});
            keep_identifier = true;
            if (!isRecognizedProductStatus(product_status_raw)) {
                break :blk "PRODUCT_UNKNOWN_STATUS";
            }
            break :blk "OK";
        };

        try appendSingleValueUpdate(value_updates, "Product", rtmify_status_col, row_num, status, alloc);
        try row_formats.append(alloc, .{
            .tab_title = "Product",
            .row_1based = row_num,
            .col_start_1based = 1,
            .col_end_1based = 6,
            .fill_hex = statusColorHex(status),
        });
    }
}

pub fn appendSingleValueUpdate(
    value_updates: *std.ArrayList(internal.ValueUpdate),
    tab_title: []const u8,
    col_index: usize,
    row_num: usize,
    value: []const u8,
    alloc: internal.Allocator,
) !void {
    const col_letter = colLetterBuf(col_index);
    const range = try std.fmt.allocPrint(alloc, "{s}!{s}{d}", .{ tab_title, colLetterRef(col_letter, col_index), row_num });
    const values = try alloc.alloc([]const u8, 1);
    values[0] = try alloc.dupe(u8, value);
    try value_updates.append(alloc, .{ .a1_range = range, .values = values });
}

pub fn findCol(header: []const []const u8, name: []const u8) ?usize {
    for (header, 0..) |h, i| {
        if (std.ascii.eqlIgnoreCase(h, name)) return i;
    }
    return null;
}

pub fn colLetterBuf(idx: usize) [3]u8 {
    var result: [3]u8 = .{ 'A', 0, 0 };
    if (idx < 26) {
        result[0] = 'A' + @as(u8, @intCast(idx));
        return result;
    }
    const a = idx / 26 - 1;
    const b = idx % 26;
    result[0] = 'A' + @as(u8, @intCast(a));
    result[1] = 'A' + @as(u8, @intCast(b));
    result[2] = 0;
    return result;
}

pub fn colLetterRef(buf: [3]u8, idx: usize) []const u8 {
    return buf[0..if (idx < 26) 1 else 2];
}

pub fn colLetter(idx: usize) [3]u8 {
    return colLetterBuf(idx);
}

const testing = std.testing;

fn findSingleValueUpdate(updates: []const internal.ValueUpdate, range: []const u8) ?[]const u8 {
    for (updates) |upd| {
        if (std.mem.eql(u8, upd.a1_range, range)) return upd.values[0];
    }
    return null;
}

test "requirementStatus returns MISSING when requirement node absent" {
    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();

    try testing.expectEqualStrings("MISSING", requirementStatus(&db, "REQ-404", testing.allocator));
}

test "requirementStatus returns NO_TEST_LINKED when requirement has no test edges" {
    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);

    try testing.expectEqualStrings("NO_TEST_LINKED", requirementStatus(&db, "REQ-001", testing.allocator));
}

test "requirementStatus returns OK when requirement has linked test group" {
    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");

    try testing.expectEqualStrings("OK", requirementStatus(&db, "REQ-001", testing.allocator));
}

test "statusColorHex maps ok warning and error buckets correctly" {
    try testing.expectEqualStrings("#B6E1CD", statusColorHex("OK"));
    try testing.expectEqualStrings("#FCE8B2", statusColorHex("MISSING"));
    try testing.expectEqualStrings("#F4C7C3", statusColorHex("DUPLICATE_FULL_IDENTIFIER"));
}

test "buildWritebackPlan adds RTMify Verification header and writes verification state" {
    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("TG-001", "TestGroup", "{}", null);
    try db.addNode("TEST-001", "Test", "{}", null);
    try db.addEdge("REQ-001", "TG-001", "TESTED_BY");
    try db.addEdge("TG-001", "TEST-001", "HAS_TEST");

    var payload = internal.test_results.ExecutionInput{
        .execution_id = try testing.allocator.dupe(u8, "exec-1"),
        .executed_at = try testing.allocator.dupe(u8, "2026-03-31T12:00:00Z"),
        .serial_number = null,
        .full_product_identifier = null,
        .executor_json = null,
        .source_json = null,
        .test_cases = try testing.allocator.alloc(internal.test_results.TestCaseInput, 1),
    };
    defer payload.deinit(testing.allocator);
    payload.test_cases[0] = .{
        .result_id = try testing.allocator.dupe(u8, "res-1"),
        .test_case_ref = try testing.allocator.dupe(u8, "TEST-001"),
        .status = try testing.allocator.dupe(u8, "passed"),
        .duration_ms = null,
        .notes = null,
        .measurements_json = try testing.allocator.dupe(u8, "[]"),
        .attachments_json = try testing.allocator.dupe(u8, "[]"),
    };
    var ingest_response = try internal.test_results.ingest(&db, payload, testing.allocator);
    defer ingest_response.deinit(testing.allocator);

    const req_header = [_][]const u8{ "ID", "Status" };
    const req_row = [_][]const u8{ "REQ-001", "" };
    const req_rows = [_][]const []const u8{
        &req_header,
        &req_row,
    };
    var plan = try buildWritebackPlan(&db, &req_rows, &.{}, &.{}, &.{}, testing.allocator);
    defer plan.deinit(testing.allocator);

    try testing.expectEqualStrings("RTMify Verification", findSingleValueUpdate(plan.value_updates.items, "Requirements!C1").?);
    try testing.expectEqualStrings("OK", findSingleValueUpdate(plan.value_updates.items, "Requirements!B2").?);
    try testing.expectEqualStrings("VERIFIED", findSingleValueUpdate(plan.value_updates.items, "Requirements!C2").?);
}

test "buildWritebackPlan writes risk statuses using node presence" {
    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("RSK-001", "Risk", "{}", null);

    const risk_header = [_][]const u8{ "ID", "Status" };
    const risk_row_1 = [_][]const u8{ "RSK-001", "" };
    const risk_row_2 = [_][]const u8{ "RSK-404", "" };
    const risk_rows = [_][]const []const u8{
        &risk_header,
        &risk_row_1,
        &risk_row_2,
    };
    var plan = try buildWritebackPlan(&db, &.{}, &risk_rows, &.{}, &.{}, testing.allocator);
    defer plan.deinit(testing.allocator);

    try testing.expectEqualStrings("OK", findSingleValueUpdate(plan.value_updates.items, "Risks!B2").?);
    try testing.expectEqualStrings("MISSING", findSingleValueUpdate(plan.value_updates.items, "Risks!B3").?);
}

test "buildWritebackPlan writes user need statuses using DERIVES_FROM edges" {
    var db = try internal.GraphDb.init(":memory:");
    defer db.deinit();
    try db.addNode("REQ-001", "Requirement", "{}", null);
    try db.addNode("UN-001", "UserNeed", "{}", null);
    try db.addEdge("REQ-001", "UN-001", "DERIVES_FROM");

    const un_header = [_][]const u8{ "ID", "Status" };
    const un_row_1 = [_][]const u8{ "UN-001", "" };
    const un_row_2 = [_][]const u8{ "UN-404", "" };
    const un_rows = [_][]const []const u8{
        &un_header,
        &un_row_1,
        &un_row_2,
    };
    var plan = try buildWritebackPlan(&db, &.{}, &.{}, &un_rows, &.{}, testing.allocator);
    defer plan.deinit(testing.allocator);

    try testing.expectEqualStrings("OK", findSingleValueUpdate(plan.value_updates.items, "User Needs!B2").?);
    try testing.expectEqualStrings("NO_REQ_LINKED", findSingleValueUpdate(plan.value_updates.items, "User Needs!B3").?);
}

test "normalizeProductCell trims normalized xlsx cell output" {
    const normalized = try normalizeProductCell("  ASM-1000 Rev C  ", testing.allocator);
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings("ASM-1000 Rev C", normalized);
}

test "appendProductWriteback accepts recognized product status synonyms" {
    var value_updates: std.ArrayList(internal.ValueUpdate) = .empty;
    var row_formats: std.ArrayList(internal.RowFormat) = .empty;
    defer {
        var plan: WritebackPlan = .{ .value_updates = value_updates, .row_formats = row_formats };
        plan.deinit(testing.allocator);
    }

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
        &.{ "ASM-1000", "Rev C", "ASM-1000 Rev C", "Desc", "End of Life", "" },
    };
    try appendProductWriteback(&value_updates, &row_formats, product_rows, testing.allocator);

    try testing.expectEqualStrings("OK", findSingleValueUpdate(value_updates.items, "Product!F2").?);
}

test "appendProductWriteback skips fully blank rows" {
    var value_updates: std.ArrayList(internal.ValueUpdate) = .empty;
    var row_formats: std.ArrayList(internal.RowFormat) = .empty;
    defer {
        var plan: WritebackPlan = .{ .value_updates = value_updates, .row_formats = row_formats };
        plan.deinit(testing.allocator);
    }

    const product_rows: []const []const []const u8 = &.{
        &.{ "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status" },
        &.{ "", "", "", "", "", "" },
    };
    try appendProductWriteback(&value_updates, &row_formats, product_rows, testing.allocator);

    try testing.expect(findSingleValueUpdate(value_updates.items, "Product!F2") == null);
    try testing.expectEqual(@as(usize, 0), row_formats.items.len);
}
