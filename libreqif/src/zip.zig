const std = @import("std");

pub const ExtractedFile = struct {
    name: []const u8,
    bytes: []const u8,
};

pub fn extractReqifEntries(allocator: std.mem.Allocator, zip_bytes: []const u8) ![]const ExtractedFile {
    const end_record = findEndRecord(zip_bytes) catch return error.InvalidArchive;
    if (end_record.need_zip64()) return error.InvalidArchive;
    if (end_record.disk_number != 0 or end_record.central_directory_disk_number != 0) return error.InvalidArchive;

    var entries: std.ArrayList(ExtractedFile) = .empty;
    errdefer entries.deinit(allocator);

    var offset: usize = end_record.central_directory_offset;
    var index: usize = 0;
    while (index < end_record.record_count_total) : (index += 1) {
        const header = try readStruct(std.zip.CentralDirectoryFileHeader, zip_bytes, offset);
        if (!std.mem.eql(u8, &header.signature, &std.zip.central_file_header_sig)) return error.InvalidArchive;

        const filename_start = offset + @sizeOf(std.zip.CentralDirectoryFileHeader);
        const filename_end = filename_start + header.filename_len;
        if (filename_end > zip_bytes.len) return error.InvalidArchive;
        const filename = zip_bytes[filename_start..filename_end];

        if (header.flags.encrypted) return error.InvalidArchive;
        if (std.mem.endsWith(u8, filename, "/")) {
            offset = filename_end + header.extra_len + header.comment_len;
            continue;
        }
        if (std.mem.startsWith(u8, filename, "__MACOSX/")) {
            offset = filename_end + header.extra_len + header.comment_len;
            continue;
        }
        if (std.ascii.endsWithIgnoreCase(filename, ".reqif")) {
            const extracted = try extractEntryBytes(allocator, zip_bytes, header, filename);
            try entries.append(allocator, extracted);
        }

        offset = filename_end + header.extra_len + header.comment_len;
    }

    if (entries.items.len == 0) return error.MissingReqifEntry;
    return entries.toOwnedSlice(allocator);
}

fn extractEntryBytes(
    allocator: std.mem.Allocator,
    zip_bytes: []const u8,
    header: std.zip.CentralDirectoryFileHeader,
    filename: []const u8,
) !ExtractedFile {
    const local_header_offset = header.local_file_header_offset;
    const local_header = try readStruct(std.zip.LocalFileHeader, zip_bytes, local_header_offset);
    if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig)) return error.InvalidArchive;

    const data_start = local_header_offset + @sizeOf(std.zip.LocalFileHeader) + local_header.filename_len + local_header.extra_len;
    const data_end = data_start + header.compressed_size;
    if (data_end > zip_bytes.len) return error.InvalidArchive;
    const compressed = zip_bytes[data_start..data_end];

    const name_copy = try allocator.dupe(u8, filename);
    errdefer allocator.free(name_copy);

    const bytes_copy = switch (header.compression_method) {
        .store => try allocator.dupe(u8, compressed),
        .deflate => try decompressDeflate(allocator, compressed, header.uncompressed_size),
        else => return error.InvalidArchive,
    };

    return .{ .name = name_copy, .bytes = bytes_copy };
}

fn decompressDeflate(allocator: std.mem.Allocator, compressed: []const u8, expected_len: usize) ![]const u8 {
    var reader: std.Io.Reader = .fixed(compressed);
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader, .raw, &buffer);
    const bytes = decompress.reader.allocRemaining(allocator, .limited(expected_len + 1)) catch return error.InvalidArchive;
    if (bytes.len != expected_len) return error.InvalidArchive;
    return bytes;
}

fn findEndRecord(bytes: []const u8) !std.zip.EndRecord {
    const pos = std.mem.lastIndexOf(u8, bytes, &std.zip.end_record_sig) orelse return error.InvalidArchive;
    if (pos + @sizeOf(std.zip.EndRecord) > bytes.len) return error.InvalidArchive;
    const ptr: *align(1) const std.zip.EndRecord = @ptrCast(bytes[pos..][0..@sizeOf(std.zip.EndRecord)]);
    return ptr.*;
}

fn readStruct(comptime T: type, bytes: []const u8, offset: usize) !T {
    if (offset + @sizeOf(T) > bytes.len) return error.InvalidArchive;
    const ptr: *align(1) const T = @ptrCast(bytes[offset..][0..@sizeOf(T)]);
    return ptr.*;
}

const testing = std.testing;

test "extractReqifEntries pulls reqif bytes from fixture archive" {
    const path = "libreqif/test/fixtures/strictdoc/reqifz/01_reqifz_with_one_reqif_and_one_attachments/sample.reqifz";
    const zip_bytes = try std.fs.cwd().readFileAlloc(testing.allocator, path, 2 * 1024 * 1024);
    defer testing.allocator.free(zip_bytes);

    const files = try extractReqifEntries(testing.allocator, zip_bytes);
    defer {
        for (files) |file| {
            testing.allocator.free(file.name);
            testing.allocator.free(file.bytes);
        }
        testing.allocator.free(files);
    }

    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("sample.reqif", files[0].name);
    try testing.expect(std.mem.startsWith(u8, files[0].bytes, "<?xml"));
}
