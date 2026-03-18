const std = @import("std");
const internal = @import("internal.zig");

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
    req_rows: [][][]const u8,
    risk_rows: [][][]const u8,
    un_rows: [][][]const u8,
    product_rows: []const []const []const u8,
    alloc: internal.Allocator,
) !void {
    var value_updates: std.ArrayList(internal.ValueUpdate) = .empty;
    defer {
        for (value_updates.items) |upd| {
            alloc.free(upd.a1_range);
            for (upd.values) |v| alloc.free(v);
            alloc.free(upd.values);
        }
        value_updates.deinit(alloc);
    }
    var row_formats: std.ArrayList(internal.RowFormat) = .empty;
    defer row_formats.deinit(alloc);

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
                try value_updates.append(alloc, .{ .a1_range = header_range, .values = header_values });
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
                try value_updates.append(alloc, .{ .a1_range = range, .values = values });

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
                try value_updates.append(alloc, .{ .a1_range = verification_range, .values = verification_values });

                try row_formats.append(alloc, .{
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
                try value_updates.append(alloc, .{ .a1_range = range, .values = values });
                try row_formats.append(alloc, .{
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
                try value_updates.append(alloc, .{ .a1_range = range, .values = values });
                try row_formats.append(alloc, .{
                    .tab_title = "User Needs",
                    .row_1based = row_num,
                    .col_start_1based = 1,
                    .col_end_1based = header.len,
                    .fill_hex = statusColorHex(status),
                });
            }
        }
    }

    try appendProductWriteback(&value_updates, &row_formats, product_rows, alloc);

    if (value_updates.items.len > 0) {
        runtime.batchWriteValues(value_updates.items, alloc) catch |e| {
            std.log.warn("sync: status writeback failed: {s}", .{@errorName(e)});
        };
    }
    if (row_formats.items.len > 0) {
        runtime.applyRowFormats(row_formats.items, alloc) catch |e| {
            std.log.warn("sync: color writeback failed: {s}", .{@errorName(e)});
        };
    }
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
    defer seen_identifiers.deinit();

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

        const normalized_identifier = try normalizeProductCell(identifier_raw, alloc);
        const status: []const u8 = blk: {
            if (normalized_identifier.len == 0 or internal.schema.isBlankEquivalent(normalized_identifier)) {
                break :blk "MISSING_FULL_IDENTIFIER";
            }
            if (seen_identifiers.contains(normalized_identifier)) {
                break :blk "DUPLICATE_FULL_IDENTIFIER";
            }
            try seen_identifiers.put(normalized_identifier, {});
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
