const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    name: []const u8,
    data: []const u8,
};

pub const Sheet = struct {
    name: []const u8,
    rows: []const []const []const u8,
};

fn writeU16(writer: anytype, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn writeU32(writer: anytype, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn xmlEscape(text: []const u8, alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            '\'' => try out.appendSlice(alloc, "&apos;"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

fn excelColName(index: usize, alloc: Allocator) ![]u8 {
    var value = index + 1;
    var scratch: [16]u8 = undefined;
    var len: usize = 0;
    while (value > 0) {
        const rem = (value - 1) % 26;
        scratch[len] = @as(u8, @intCast('A' + rem));
        len += 1;
        value = (value - 1) / 26;
    }
    const out = try alloc.alloc(u8, len);
    for (out, 0..) |*dest, i| dest.* = scratch[len - 1 - i];
    return out;
}

fn writeStoredZip(path: []const u8, entries: []const Entry) !void {
    const dir_name = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir_name);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var writer = file.writerStreaming(&.{});
    const w = &writer.interface;

    const CentralRecord = struct {
        name: []const u8,
        crc32: u32,
        size: u32,
        local_offset: u32,
    };

    var records: std.ArrayList(CentralRecord) = .empty;
    defer records.deinit(std.heap.page_allocator);

    for (entries) |entry| {
        const local_offset: u32 = @intCast(try file.getPos());
        const crc32 = std.hash.Crc32.hash(entry.data);
        const size: u32 = @intCast(entry.data.len);

        try writeU32(w, 0x04034b50);
        try writeU16(w, 20);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU32(w, crc32);
        try writeU32(w, size);
        try writeU32(w, size);
        try writeU16(w, @intCast(entry.name.len));
        try writeU16(w, 0);
        try w.writeAll(entry.name);
        try w.writeAll(entry.data);

        try records.append(std.heap.page_allocator, .{
            .name = entry.name,
            .crc32 = crc32,
            .size = size,
            .local_offset = local_offset,
        });
    }

    const central_offset: u32 = @intCast(try file.getPos());
    for (records.items) |record| {
        try writeU32(w, 0x02014b50);
        try writeU16(w, 20);
        try writeU16(w, 20);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU32(w, record.crc32);
        try writeU32(w, record.size);
        try writeU32(w, record.size);
        try writeU16(w, @intCast(record.name.len));
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU16(w, 0);
        try writeU32(w, 0);
        try writeU32(w, record.local_offset);
        try w.writeAll(record.name);
    }

    const central_end: u32 = @intCast(try file.getPos());
    const central_size = central_end - central_offset;
    const entry_count: u16 = @intCast(records.items.len);

    try writeU32(w, 0x06054b50);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU16(w, entry_count);
    try writeU16(w, entry_count);
    try writeU32(w, central_size);
    try writeU32(w, central_offset);
    try writeU16(w, 0);
}

pub fn writeMinimalDocx(path: []const u8, paragraphs: []const []const u8, alloc: Allocator) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    for (paragraphs) |paragraph| {
        const escaped = try xmlEscape(paragraph, alloc);
        defer alloc.free(escaped);
        try std.fmt.format(body.writer(alloc), "<w:p><w:r><w:t>{s}</w:t></w:r></w:p>", .{escaped});
    }

    const document_xml = try std.fmt.allocPrint(
        alloc,
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            ++ "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            ++ "<w:body>{s}</w:body></w:document>",
        .{body.items},
    );
    defer alloc.free(document_xml);

    const content_types =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        ++ "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        ++ "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        ++ "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        ++ "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        ++ "</Types>";
    const root_rels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        ++ "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        ++ "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
        ++ "</Relationships>";
    const doc_rels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        ++ "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>";

    const entries = [_]Entry{
        .{ .name = "[Content_Types].xml", .data = content_types },
        .{ .name = "_rels/.rels", .data = root_rels },
        .{ .name = "word/document.xml", .data = document_xml },
        .{ .name = "word/_rels/document.xml.rels", .data = doc_rels },
    };
    try writeStoredZip(path, &entries);
}

pub fn writeMinimalXlsx(path: []const u8, sheets: []const Sheet, alloc: Allocator) !void {
    var content_overrides: std.ArrayList(u8) = .empty;
    defer content_overrides.deinit(alloc);
    var workbook_sheets: std.ArrayList(u8) = .empty;
    defer workbook_sheets.deinit(alloc);
    var workbook_rels: std.ArrayList(u8) = .empty;
    defer workbook_rels.deinit(alloc);
    var dynamic_entries: std.ArrayList(Entry) = .empty;
    defer {
        for (dynamic_entries.items) |entry| {
            alloc.free(entry.name);
            alloc.free(entry.data);
        }
        dynamic_entries.deinit(alloc);
    }

    for (sheets, 0..) |sheet, idx| {
        const sheet_no = idx + 1;
        try std.fmt.format(
            workbook_sheets.writer(alloc),
            "<sheet name=\"{s}\" sheetId=\"{d}\" r:id=\"rId{d}\"/>",
            .{ sheet.name, sheet_no, sheet_no },
        );
        try std.fmt.format(
            workbook_rels.writer(alloc),
            "<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{d}.xml\"/>",
            .{ sheet_no, sheet_no },
        );
        try std.fmt.format(
            content_overrides.writer(alloc),
            "<Override PartName=\"/xl/worksheets/sheet{d}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>",
            .{sheet_no},
        );

        var row_xml: std.ArrayList(u8) = .empty;
        defer row_xml.deinit(alloc);
        for (sheet.rows, 0..) |row, row_idx| {
            try std.fmt.format(row_xml.writer(alloc), "<row r=\"{d}\">", .{row_idx + 1});
            for (row, 0..) |cell, col_idx| {
                const col_name = try excelColName(col_idx, alloc);
                defer alloc.free(col_name);
                const cell_ref = try std.fmt.allocPrint(alloc, "{s}{d}", .{ col_name, row_idx + 1 });
                defer alloc.free(cell_ref);
                const escaped = try xmlEscape(cell, alloc);
                defer alloc.free(escaped);
                try std.fmt.format(
                    row_xml.writer(alloc),
                    "<c r=\"{s}\" t=\"inlineStr\"><is><t>{s}</t></is></c>",
                    .{ cell_ref, escaped },
                );
            }
            try row_xml.appendSlice(alloc, "</row>");
        }

        const sheet_xml = try std.fmt.allocPrint(
            alloc,
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                ++ "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
                ++ "<sheetData>{s}</sheetData></worksheet>",
            .{row_xml.items},
        );
        const sheet_name = try std.fmt.allocPrint(alloc, "xl/worksheets/sheet{d}.xml", .{sheet_no});
        try dynamic_entries.append(alloc, .{
            .name = sheet_name,
            .data = sheet_xml,
        });
    }

    const content_types = try std.fmt.allocPrint(
        alloc,
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            ++ "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            ++ "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            ++ "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            ++ "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            ++ "{s}</Types>",
        .{content_overrides.items},
    );
    defer alloc.free(content_types);

    const root_rels =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        ++ "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        ++ "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        ++ "</Relationships>";
    const workbook_xml = try std.fmt.allocPrint(
        alloc,
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            ++ "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            ++ "<sheets>{s}</sheets></workbook>",
        .{workbook_sheets.items},
    );
    defer alloc.free(workbook_xml);
    const workbook_xml_rels = try std.fmt.allocPrint(
        alloc,
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            ++ "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">{s}</Relationships>",
        .{workbook_rels.items},
    );
    defer alloc.free(workbook_xml_rels);

    var all_entries: std.ArrayList(Entry) = .empty;
    defer all_entries.deinit(alloc);
    try all_entries.appendSlice(alloc, &.{
        .{ .name = "[Content_Types].xml", .data = content_types },
        .{ .name = "_rels/.rels", .data = root_rels },
        .{ .name = "xl/workbook.xml", .data = workbook_xml },
        .{ .name = "xl/_rels/workbook.xml.rels", .data = workbook_xml_rels },
    });
    try all_entries.appendSlice(alloc, dynamic_entries.items);
    try writeStoredZip(path, all_entries.items);
}
