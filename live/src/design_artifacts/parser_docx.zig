const std = @import("std");

const Allocator = std.mem.Allocator;

const rtmify = @import("rtmify");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn parseDocxAssertions(path: []const u8, alloc: Allocator) !std.ArrayList(types.ParsedRequirementAssertion) {
    const xml = try extractDocxDocumentXml(path, alloc);
    defer alloc.free(xml);

    var map: std.StringHashMap(types.ParsedRequirementAssertion) = .init(alloc);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.section);
            if (entry.value_ptr.text) |value| alloc.free(value);
            if (entry.value_ptr.normalized_text) |value| alloc.free(value);
            alloc.free(entry.value_ptr.parse_status);
        }
        map.deinit();
    }

    try collectTableAssertions(xml, alloc, &map);
    try collectParagraphAssertions(xml, alloc, &map);

    var out: std.ArrayList(types.ParsedRequirementAssertion) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        try out.append(alloc, .{
            .req_id = try alloc.dupe(u8, entry.key_ptr.*),
            .section = try alloc.dupe(u8, entry.value_ptr.section),
            .text = if (entry.value_ptr.text) |value| try alloc.dupe(u8, value) else null,
            .normalized_text = if (entry.value_ptr.normalized_text) |value| try alloc.dupe(u8, value) else null,
            .parse_status = try alloc.dupe(u8, entry.value_ptr.parse_status),
            .occurrence_count = entry.value_ptr.occurrence_count,
        });
    }
    return out;
}

pub fn extractDocxAllText(path: []const u8, alloc: Allocator) ![]u8 {
    const xml = try extractDocxDocumentXml(path, alloc);
    defer alloc.free(xml);
    return extractTextRuns(xml, alloc);
}

pub fn collectParagraphAssertions(
    xml: []const u8,
    alloc: Allocator,
    map: *std.StringHashMap(types.ParsedRequirementAssertion),
) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<w:p")) |start| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, xml, open_end, "</w:p>") orelse break;
        const text = try extractTextRuns(xml[open_end + 1 .. close], alloc);
        defer alloc.free(text);
        pos = close + "</w:p>".len;
        if (text.len == 0) continue;
        if (try inferAssertionFromText(text, "paragraph", alloc)) |assertion| {
            defer {
                alloc.free(assertion.req_id);
                alloc.free(assertion.section);
                if (assertion.text) |value| alloc.free(value);
                if (assertion.normalized_text) |value| alloc.free(value);
                alloc.free(assertion.parse_status);
            }
            try mergeAssertion(map, assertion, alloc);
        }
    }
}

pub fn collectTableAssertions(
    xml: []const u8,
    alloc: Allocator,
    map: *std.StringHashMap(types.ParsedRequirementAssertion),
) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<w:tr")) |row_start| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, row_start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, xml, open_end, "</w:tr>") orelse break;
        const row_xml = xml[open_end + 1 .. close];
        pos = close + "</w:tr>".len;

        var cells: std.ArrayList([]const u8) = .empty;
        defer {
            for (cells.items) |cell| alloc.free(cell);
            cells.deinit(alloc);
        }

        var cell_pos: usize = 0;
        while (std.mem.indexOfPos(u8, row_xml, cell_pos, "<w:tc")) |cell_start| {
            const cell_open_end = std.mem.indexOfScalarPos(u8, row_xml, cell_start, '>') orelse break;
            const cell_close = std.mem.indexOfPos(u8, row_xml, cell_open_end, "</w:tc>") orelse break;
            try cells.append(alloc, try extractTextRuns(row_xml[cell_open_end + 1 .. cell_close], alloc));
            cell_pos = cell_close + "</w:tc>".len;
        }

        for (cells.items, 0..) |cell_text, idx| {
            const id_candidate = std.mem.trim(u8, cell_text, " \t\r\n:");
            if (!rtmify.id.looksLikeStructuredIdForInference(id_candidate)) continue;
            const value_text = blk: {
                var next_idx = idx + 1;
                while (next_idx < cells.items.len) : (next_idx += 1) {
                    const candidate = std.mem.trim(u8, cells.items[next_idx], " \t\r\n:");
                    if (candidate.len > 0 and !rtmify.id.looksLikeStructuredIdForInference(candidate)) break :blk candidate;
                }
                break :blk "";
            };
            const normalized = if (value_text.len > 0) try util.normalizeText(value_text, alloc) else null;
            defer if (normalized) |value| alloc.free(value);
            const parse_status = util.classifyExtractedText(if (value_text.len > 0) value_text else null, normalized);
            const assertion: types.ParsedRequirementAssertion = .{
                .req_id = try alloc.dupe(u8, id_candidate),
                .section = try alloc.dupe(u8, "table"),
                .text = if (value_text.len > 0) try alloc.dupe(u8, value_text) else null,
                .normalized_text = if (normalized) |value| try alloc.dupe(u8, value) else null,
                .parse_status = try alloc.dupe(u8, parse_status),
                .occurrence_count = 1,
            };
            defer {
                alloc.free(assertion.req_id);
                alloc.free(assertion.section);
                if (assertion.text) |value| alloc.free(value);
                if (assertion.normalized_text) |value| alloc.free(value);
                alloc.free(assertion.parse_status);
            }
            try mergeAssertion(map, assertion, alloc);
        }
    }
}

pub fn inferAssertionFromText(text: []const u8, section: []const u8, alloc: Allocator) !?types.ParsedRequirementAssertion {
    var token_start: ?usize = null;
    var idx: usize = 0;
    while (idx <= text.len) : (idx += 1) {
        const is_boundary = idx == text.len or std.ascii.isWhitespace(text[idx]) or std.mem.indexOfScalar(u8, ":;,()[]{}", text[idx]) != null;
        if (token_start == null) {
            if (idx < text.len and !std.ascii.isWhitespace(text[idx])) token_start = idx;
            continue;
        }
        if (!is_boundary) continue;
        const token = std.mem.trim(u8, text[token_start.?..idx], " \t\r\n:;,.()[]{}");
        token_start = null;
        if (token.len == 0 or !rtmify.id.looksLikeStructuredIdForInference(token)) continue;
        const remainder = std.mem.trim(u8, text[idx..], " \t\r\n:-\u{2014}");
        const normalized = if (remainder.len > 0) try util.normalizeText(remainder, alloc) else null;
        defer if (normalized) |value| alloc.free(value);
        const parse_status = util.classifyExtractedText(if (remainder.len > 0) remainder else null, normalized);
        return types.ParsedRequirementAssertion{
            .req_id = try alloc.dupe(u8, token),
            .section = try alloc.dupe(u8, section),
            .text = if (remainder.len > 0) try alloc.dupe(u8, remainder) else null,
            .normalized_text = if (normalized) |value| try alloc.dupe(u8, value) else null,
            .parse_status = try alloc.dupe(u8, parse_status),
            .occurrence_count = 1,
        };
    }
    return null;
}

pub fn mergeAssertion(
    map: *std.StringHashMap(types.ParsedRequirementAssertion),
    assertion: types.ParsedRequirementAssertion,
    alloc: Allocator,
) !void {
    if (map.getPtr(assertion.req_id)) |existing| {
        existing.occurrence_count += 1;
        const left = existing.normalized_text orelse existing.text orelse "";
        const right = assertion.normalized_text orelse assertion.text orelse "";
        if (!std.mem.eql(u8, left, right)) {
            alloc.free(existing.parse_status);
            existing.parse_status = try alloc.dupe(u8, "ambiguous_within_artifact");
        } else if (!std.mem.eql(u8, existing.parse_status, "ambiguous_within_artifact") and util.isLowConfidenceStatus(assertion.parse_status)) {
            alloc.free(existing.parse_status);
            existing.parse_status = try alloc.dupe(u8, assertion.parse_status);
        }
        return;
    }
    try map.put(try alloc.dupe(u8, assertion.req_id), .{
        .req_id = undefined,
        .section = try alloc.dupe(u8, assertion.section),
        .text = if (assertion.text) |value| try alloc.dupe(u8, value) else null,
        .normalized_text = if (assertion.normalized_text) |value| try alloc.dupe(u8, value) else null,
        .parse_status = try alloc.dupe(u8, assertion.parse_status),
        .occurrence_count = assertion.occurrence_count,
    });
}

pub fn extractDocxDocumentXml(path: []const u8, alloc: Allocator) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var read_buf: [4096]u8 = undefined;
    var fr = file.reader(&read_buf);

    const Entry = struct {
        name: []u8,
        file_offset: u64,
        compressed_size: u64,
        uncompressed_size: u64,
        method: std.zip.CompressionMethod,
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |item| alloc.free(item.name);
        entries.deinit(alloc);
    }

    var iter = try std.zip.Iterator.init(&fr);
    var name_buf: [512]u8 = undefined;
    while (try iter.next()) |ce| {
        if (ce.filename_len > name_buf.len) continue;
        try fr.seekTo(ce.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name_buf[0..ce.filename_len]);
        const name_slice = name_buf[0..ce.filename_len];
        try entries.append(alloc, .{
            .name = try alloc.dupe(u8, name_slice),
            .file_offset = ce.file_offset,
            .compressed_size = ce.compressed_size,
            .uncompressed_size = ce.uncompressed_size,
            .method = ce.compression_method,
        });
    }

    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, "word/document.xml")) {
            return extractZipEntry(&fr, entry.file_offset, entry.compressed_size, entry.uncompressed_size, entry.method, alloc);
        }
    }
    return error.InvalidXlsx;
}

pub fn extractZipEntry(
    fr: *std.fs.File.Reader,
    file_offset: u64,
    compressed_size: u64,
    uncompressed_size: u64,
    method: std.zip.CompressionMethod,
    alloc: Allocator,
) ![]u8 {
    try fr.seekTo(file_offset);
    const lh = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
    if (!std.mem.eql(u8, &lh.signature, &std.zip.local_file_header_sig)) return error.InvalidXlsx;

    const data_off = file_offset +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        @as(u64, lh.filename_len) +
        @as(u64, lh.extra_len);
    try fr.seekTo(data_off);

    _ = compressed_size;
    const buf = try alloc.alloc(u8, @intCast(uncompressed_size));
    errdefer alloc.free(buf);
    var fw = std.Io.Writer.fixed(buf);
    switch (method) {
        .store => try fr.interface.streamExact64(&fw, uncompressed_size),
        .deflate => {
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var dec = std.compress.flate.Decompress.init(&fr.interface, .raw, &flate_buf);
            try dec.reader.streamExact64(&fw, uncompressed_size);
        },
        else => return error.UnsupportedContentType,
    }
    return buf;
}

pub fn extractTextRuns(xml: []const u8, alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<w:t")) |start| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, xml, open_end, "</w:t>") orelse break;
        const text = try xmlUnescape(xml[open_end + 1 .. close], alloc);
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
        pos = close + "</w:t>".len;
    }
    return alloc.dupe(u8, std.mem.trim(u8, out.items, " \t\r\n"));
}

pub fn xmlUnescape(src: []const u8, alloc: Allocator) ![]u8 {
    if (std.mem.indexOfScalar(u8, src, '&') == null) return alloc.dupe(u8, src);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "&amp;")) {
            try out.append(alloc, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, src[i..], "&lt;")) {
            try out.append(alloc, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, src[i..], "&gt;")) {
            try out.append(alloc, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, src[i..], "&quot;")) {
            try out.append(alloc, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, src[i..], "&apos;")) {
            try out.append(alloc, '\'');
            i += 6;
        } else {
            try out.append(alloc, src[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}
