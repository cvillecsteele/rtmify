const std = @import("std");

pub const EntryType = enum {
    root,
    storage,
    stream,
    unknown,
};

pub const DirectoryEntry = struct {
    id: u32,
    name: []const u8,
    full_name: []const u8,
    entry_type: EntryType,
    left_sibling: ?u32,
    right_sibling: ?u32,
    child: ?u32,
    start_sector: u32,
    size_bytes: u64,
};

pub const StreamRef = struct {
    entry_id: u32,
    name: []const u8,
    size_bytes: u64,
};

const Header = struct {
    sector_shift: u16,
    mini_sector_shift: u16,
    num_fat_sectors: u32,
    first_dir_sector: u32,
    mini_stream_cutoff_size: u32,
    first_mini_fat_sector: u32,
    num_mini_fat_sectors: u32,
    first_difat_sector: u32,
    num_difat_sectors: u32,
    difat: [109]u32,
};

pub const CompoundFile = struct {
    bytes: []u8,
    header: Header,
    sector_size: usize,
    mini_sector_size: usize,
    fat: []u32,
    mini_fat: []u32,
    entries: []DirectoryEntry,
    root_stream: []u8,

    pub fn deinit(self: *CompoundFile, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.full_name);
        }
        allocator.free(self.entries);
        allocator.free(self.root_stream);
        allocator.free(self.mini_fat);
        allocator.free(self.fat);
        allocator.free(self.bytes);
    }

    pub fn directoryEntries(self: *const CompoundFile) []const DirectoryEntry {
        return self.entries;
    }

    pub fn listStreams(self: *const CompoundFile, allocator: std.mem.Allocator) ![]StreamRef {
        var out: std.ArrayList(StreamRef) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries) |entry| {
            if (entry.entry_type != .stream) continue;
            try out.append(allocator, .{
                .entry_id = entry.id,
                .name = try allocator.dupe(u8, entry.full_name),
                .size_bytes = entry.size_bytes,
            });
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn readStreamById(self: *const CompoundFile, entry_id: u32, allocator: std.mem.Allocator) ![]u8 {
        if (entry_id >= self.entries.len) return error.StreamNotFound;
        const entry = self.entries[entry_id];
        if (entry.entry_type != .stream and entry.entry_type != .root) return error.StreamNotFound;

        if (entry.entry_type != .root and entry.size_bytes < self.header.mini_stream_cutoff_size and self.root_stream.len > 0) {
            return try self.readMiniStream(entry.start_sector, entry.size_bytes, allocator);
        }
        return try self.readRegularStream(entry.start_sector, entry.size_bytes, allocator);
    }

    pub fn readStreamByName(self: *const CompoundFile, name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, entry.full_name, name)) continue;
            return try self.readStreamById(entry.id, allocator);
        }
        return null;
    }

    fn readRegularStream(self: *const CompoundFile, start_sector: u32, size_bytes: u64, allocator: std.mem.Allocator) ![]u8 {
        if (size_bytes == 0) return try allocator.dupe(u8, "");
        const wanted: usize = @intCast(size_bytes);
        var out = try allocator.alloc(u8, wanted);
        errdefer allocator.free(out);

        var cursor: usize = 0;
        var sector = start_sector;
        var seen: std.AutoHashMap(u32, void) = .init(allocator);
        defer seen.deinit();
        while (cursor < wanted) {
            if (sector == end_of_chain) break;
            if (sector >= self.fat.len) return error.FatOutOfRange;
            if (try seen.fetchPut(sector, {})) |_| return error.ChainCycle;
            const slice = try self.readSector(sector);
            const copy_len = @min(slice.len, wanted - cursor);
            @memcpy(out[cursor .. cursor + copy_len], slice[0..copy_len]);
            cursor += copy_len;
            sector = self.fat[sector];
        }
        if (cursor < wanted) return error.UnexpectedEOF;
        return out;
    }

    fn readMiniStream(self: *const CompoundFile, start_mini_sector: u32, size_bytes: u64, allocator: std.mem.Allocator) ![]u8 {
        if (size_bytes == 0) return try allocator.dupe(u8, "");
        const wanted: usize = @intCast(size_bytes);
        var out = try allocator.alloc(u8, wanted);
        errdefer allocator.free(out);

        var cursor: usize = 0;
        var mini_sector = start_mini_sector;
        var seen: std.AutoHashMap(u32, void) = .init(allocator);
        defer seen.deinit();
        while (cursor < wanted) {
            if (mini_sector == end_of_chain) break;
            if (mini_sector >= self.mini_fat.len) return error.MiniFatOutOfRange;
            if (try seen.fetchPut(mini_sector, {})) |_| return error.ChainCycle;

            const start = @as(usize, @intCast(mini_sector)) * self.mini_sector_size;
            const end = start + self.mini_sector_size;
            if (end > self.root_stream.len) return error.UnexpectedEOF;

            const copy_len = @min(self.mini_sector_size, wanted - cursor);
            @memcpy(out[cursor .. cursor + copy_len], self.root_stream[start .. start + copy_len]);
            cursor += copy_len;
            mini_sector = self.mini_fat[mini_sector];
        }
        if (cursor < wanted) return error.UnexpectedEOF;
        return out;
    }

    fn readSector(self: *const CompoundFile, sector_id: u32) ![]const u8 {
        const start = 512 + (@as(usize, @intCast(sector_id)) * self.sector_size);
        const end = start + self.sector_size;
        if (end > self.bytes.len) return error.UnexpectedEOF;
        return self.bytes[start..end];
    }
};

const cfb_magic = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
const free_sect: u32 = 0xFFFFFFFF;
const end_of_chain: u32 = 0xFFFFFFFE;
const fat_sect: u32 = 0xFFFFFFFD;
const difat_sect: u32 = 0xFFFFFFFC;
const no_stream: u32 = 0xFFFFFFFF;

fn le16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset .. offset + 2][0..2], .little);
}

fn le32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset .. offset + 4][0..4], .little);
}

fn le64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset .. offset + 8][0..8], .little);
}

fn writeLe16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, @ptrCast(bytes[offset .. offset + 2]), value, .little);
}

fn writeLe32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, @ptrCast(bytes[offset .. offset + 4]), value, .little);
}

fn writeLe64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, @ptrCast(bytes[offset .. offset + 8]), value, .little);
}

pub fn open(path: []const u8, allocator: std.mem.Allocator) !CompoundFile {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    errdefer allocator.free(bytes);
    if (bytes.len < 8) return error.NotCompoundFile;
    if (!std.mem.eql(u8, bytes[0..8], &cfb_magic)) return error.NotCompoundFile;
    if (bytes.len < 512) return error.InvalidHeader;

    const header = try parseHeader(bytes);
    const sector_size: usize = @as(usize, 1) << @intCast(header.sector_shift);
    const mini_sector_size: usize = @as(usize, 1) << @intCast(header.mini_sector_shift);
    if (sector_size < 128 or mini_sector_size < 8) return error.InvalidSectorSize;

    const fat_sector_ids = try buildFatSectorList(bytes, header, sector_size, allocator);
    defer allocator.free(fat_sector_ids);

    const fat = try readFat(bytes, fat_sector_ids, sector_size, allocator);
    errdefer allocator.free(fat);

    const mini_fat = try readMiniFat(bytes, header, fat, sector_size, allocator);
    errdefer allocator.free(mini_fat);

    const entries = try readDirectory(bytes, header, fat, sector_size, allocator);
    errdefer {
        for (entries) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.full_name);
        }
        allocator.free(entries);
    }

    const root_stream = if (entries.len == 0) try allocator.dupe(u8, "") else blk: {
        const root = entries[0];
        if (root.entry_type != .root or root.size_bytes == 0) break :blk try allocator.dupe(u8, "");
        break :blk try readRegularStreamFromContext(bytes, fat, sector_size, root.start_sector, root.size_bytes, allocator);
    };
    errdefer allocator.free(root_stream);

    return .{
        .bytes = bytes,
        .header = header,
        .sector_size = sector_size,
        .mini_sector_size = mini_sector_size,
        .fat = fat,
        .mini_fat = mini_fat,
        .entries = entries,
        .root_stream = root_stream,
    };
}

fn parseHeader(bytes: []const u8) !Header {
    if (le16(bytes, 24) != 0x003E) return error.InvalidHeader;

    var difat: [109]u32 = undefined;
    for (0..109) |i| difat[i] = le32(bytes, 76 + i * 4);

    return .{
        .sector_shift = le16(bytes, 30),
        .mini_sector_shift = le16(bytes, 32),
        .num_fat_sectors = le32(bytes, 44),
        .first_dir_sector = le32(bytes, 48),
        .mini_stream_cutoff_size = le32(bytes, 56),
        .first_mini_fat_sector = le32(bytes, 60),
        .num_mini_fat_sectors = le32(bytes, 64),
        .first_difat_sector = le32(bytes, 68),
        .num_difat_sectors = le32(bytes, 72),
        .difat = difat,
    };
}

fn buildFatSectorList(bytes: []const u8, header: Header, sector_size: usize, allocator: std.mem.Allocator) ![]u32 {
    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(allocator);

    for (header.difat) |sid| {
        if (sid == free_sect) continue;
        try ids.append(allocator, sid);
    }

    var current = header.first_difat_sector;
    var seen: std.AutoHashMap(u32, void) = .init(allocator);
    defer seen.deinit();
    var remaining = header.num_difat_sectors;
    while (remaining > 0 and current != end_of_chain and current != free_sect) : (remaining -= 1) {
        if (try seen.fetchPut(current, {})) |_| return error.ChainCycle;
        const start = 512 + (@as(usize, @intCast(current)) * sector_size);
        const end = start + sector_size;
        if (end > bytes.len) return error.UnexpectedEOF;
        const sector = bytes[start..end];

        const ids_per_sector = (sector_size / 4) - 1;
        for (0..ids_per_sector) |i| {
            const sid = le32(sector, i * 4);
            if (sid == free_sect) continue;
            try ids.append(allocator, sid);
        }
        current = le32(sector, sector_size - 4);
    }

    return try ids.toOwnedSlice(allocator);
}

fn readFat(bytes: []const u8, fat_sector_ids: []const u32, sector_size: usize, allocator: std.mem.Allocator) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    for (fat_sector_ids) |sid| {
        const start = 512 + (@as(usize, @intCast(sid)) * sector_size);
        const end = start + sector_size;
        if (end > bytes.len) return error.UnexpectedEOF;
        const sector = bytes[start..end];
        for (0..sector_size / 4) |i| {
            try out.append(allocator, le32(sector, i * 4));
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn readMiniFat(bytes: []const u8, header: Header, fat: []const u32, sector_size: usize, allocator: std.mem.Allocator) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    if (header.num_mini_fat_sectors == 0 or header.first_mini_fat_sector == free_sect) {
        return try out.toOwnedSlice(allocator);
    }

    var sector = header.first_mini_fat_sector;
    var seen: std.AutoHashMap(u32, void) = .init(allocator);
    defer seen.deinit();
    var remaining = header.num_mini_fat_sectors;
    while (remaining > 0 and sector != end_of_chain) : (remaining -= 1) {
        if (sector >= fat.len) return error.FatOutOfRange;
        if (try seen.fetchPut(sector, {})) |_| return error.ChainCycle;
        const start = 512 + (@as(usize, @intCast(sector)) * sector_size);
        const end = start + sector_size;
        if (end > bytes.len) return error.UnexpectedEOF;
        const buf = bytes[start..end];
        for (0..sector_size / 4) |i| {
            try out.append(allocator, le32(buf, i * 4));
        }
        sector = fat[sector];
    }
    return try out.toOwnedSlice(allocator);
}

fn readDirectory(bytes: []const u8, header: Header, fat: []const u32, sector_size: usize, allocator: std.mem.Allocator) ![]DirectoryEntry {
    const dir_bytes = try readRegularStreamFromContext(bytes, fat, sector_size, header.first_dir_sector, std.math.maxInt(u64), allocator);
    defer allocator.free(dir_bytes);

    if (dir_bytes.len == 0) return try allocator.dupe(DirectoryEntry, &.{});
    var entries: std.ArrayList(DirectoryEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.full_name);
        }
        entries.deinit(allocator);
    }

    var offset: usize = 0;
    while (offset + 128 <= dir_bytes.len) : (offset += 128) {
        const raw = dir_bytes[offset .. offset + 128];
        const name_len = le16(raw, 64);
        const name = try decodeDirName(raw[0..64], name_len, allocator);
        const object_type = raw[66];
        const entry_type: EntryType = switch (object_type) {
            1 => .storage,
            2 => .stream,
            5 => .root,
            else => .unknown,
        };
        const left = nullableSibling(le32(raw, 68));
        const right = nullableSibling(le32(raw, 72));
        const child = nullableSibling(le32(raw, 76));
        const start_sector = le32(raw, 116);
        const size_bytes = le64(raw, 120);
        try entries.append(allocator, .{
            .id = @intCast(entries.items.len),
            .name = name,
            .full_name = try allocator.dupe(u8, name),
            .entry_type = entry_type,
            .left_sibling = left,
            .right_sibling = right,
            .child = child,
            .start_sector = start_sector,
            .size_bytes = size_bytes,
        });
    }

    if (entries.items.len == 0) return try entries.toOwnedSlice(allocator);
    var visited: std.AutoHashMap(u32, void) = .init(allocator);
    defer visited.deinit();
    try assignFullNames(entries.items, allocator, 0, "", &visited);
    return try entries.toOwnedSlice(allocator);
}

fn decodeDirName(buf: []const u8, raw_len: u16, allocator: std.mem.Allocator) ![]u8 {
    if (raw_len < 2) return try allocator.dupe(u8, "");
    const usable_len = @min(buf.len, @as(usize, raw_len) - 2);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i + 1 < usable_len) : (i += 2) {
        const code = std.mem.readInt(u16, buf[i .. i + 2][0..2], .little);
        if (code == 0) break;
        if (code <= 0x7F) {
            try out.append(allocator, @intCast(code));
        } else {
            try out.append(allocator, '?');
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn nullableSibling(value: u32) ?u32 {
    return if (value == no_stream) null else value;
}

fn assignFullNames(entries: []DirectoryEntry, allocator: std.mem.Allocator, current: u32, parent: []const u8, visited: *std.AutoHashMap(u32, void)) !void {
    if (current >= entries.len) return error.DirectoryCorrupt;
    if (try visited.fetchPut(current, {})) |_| return;
    const entry = &entries[current];

    if (entry.left_sibling) |left| try assignFullNames(entries, allocator, left, parent, visited);

    const full_name = if (entry.entry_type == .root or parent.len == 0)
        try allocator.dupe(u8, entry.name)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, entry.name });
    allocator.free(entry.full_name);
    entry.full_name = full_name;

    if (entry.child) |child| try assignFullNames(entries, allocator, child, if (entry.entry_type == .root) "" else entry.full_name, visited);
    if (entry.right_sibling) |right| try assignFullNames(entries, allocator, right, parent, visited);
}

fn readRegularStreamFromContext(bytes: []const u8, fat: []const u32, sector_size: usize, start_sector: u32, size_bytes: u64, allocator: std.mem.Allocator) ![]u8 {
    if (start_sector == end_of_chain or start_sector == free_sect or size_bytes == 0) return try allocator.dupe(u8, "");
    var sectors: std.ArrayList(u8) = .empty;
    errdefer sectors.deinit(allocator);

    var sector = start_sector;
    var seen: std.AutoHashMap(u32, void) = .init(allocator);
    defer seen.deinit();
    var remaining = size_bytes;
    while (sector != end_of_chain) {
        if (sector >= fat.len) return error.FatOutOfRange;
        if (try seen.fetchPut(sector, {})) |_| return error.ChainCycle;
        const start = 512 + (@as(usize, @intCast(sector)) * sector_size);
        const end = start + sector_size;
        if (end > bytes.len) return error.UnexpectedEOF;

        const copy_len: usize = if (size_bytes == std.math.maxInt(u64))
            sector_size
        else
            @intCast(@min(@as(u64, sector_size), remaining));
        try sectors.appendSlice(allocator, bytes[start .. start + copy_len]);
        if (size_bytes != std.math.maxInt(u64)) {
            remaining -= copy_len;
            if (remaining == 0) break;
        }
        sector = fat[sector];
    }
    return try sectors.toOwnedSlice(allocator);
}

fn makeDirEntry(name: []const u8, entry_type: u8, left: u32, right: u32, child: u32, start_sector: u32, size_bytes: u64) [128]u8 {
    var out: [128]u8 = .{0} ** 128;
    var utf16_bytes: [64]u8 = .{0} ** 64;
    var pos: usize = 0;
    for (name) |ch| {
        if (pos + 2 > utf16_bytes.len) break;
        writeLe16(&utf16_bytes, pos, ch);
        pos += 2;
    }
    @memcpy(out[0..64], utf16_bytes[0..64]);
    writeLe16(&out, 64, @intCast(pos + 2));
    out[66] = entry_type;
    writeLe32(&out, 68, left);
    writeLe32(&out, 72, right);
    writeLe32(&out, 76, child);
    writeLe32(&out, 116, start_sector);
    writeLe64(&out, 120, size_bytes);
    return out;
}

fn buildSyntheticMiniCfb(allocator: std.mem.Allocator) ![]u8 {
    const sector_size = 512;
    const mini_sector_size = 64;
    const total_sectors = 4;
    var bytes = try allocator.alloc(u8, 512 + total_sectors * sector_size);
    @memset(bytes, 0);

    @memcpy(bytes[0..8], &cfb_magic);
    writeLe16(bytes, 24, 0x003E);
    writeLe16(bytes, 26, 0x0003);
    writeLe16(bytes, 28, 0xFFFE);
    writeLe16(bytes, 30, 9);
    writeLe16(bytes, 32, 6);
    writeLe32(bytes, 44, 1);
    writeLe32(bytes, 48, 1);
    writeLe32(bytes, 56, 4096);
    writeLe32(bytes, 60, 3);
    writeLe32(bytes, 64, 1);
    writeLe32(bytes, 68, end_of_chain);
    writeLe32(bytes, 72, 0);
    writeLe32(bytes, 76, 0); // FAT sector 0
    for (0..108) |i| writeLe32(bytes, 80 + i * 4, free_sect);

    const fat_offset = 512;
    writeLe32(bytes, fat_offset + 0, fat_sect);
    writeLe32(bytes, fat_offset + 4, end_of_chain);
    writeLe32(bytes, fat_offset + 8, end_of_chain);
    writeLe32(bytes, fat_offset + 12, end_of_chain);
    for (4..sector_size / 4) |i| {
        writeLe32(bytes, fat_offset + i * 4, free_sect);
    }

    const dir_offset = 512 + sector_size;
    const root_entry = makeDirEntry("Root Entry", 5, no_stream, no_stream, 1, 2, mini_sector_size);
    const child_entry = makeDirEntry("MiniThing", 2, no_stream, no_stream, no_stream, 0, 5);
    @memcpy(bytes[dir_offset .. dir_offset + 128], &root_entry);
    @memcpy(bytes[dir_offset + 128 .. dir_offset + 256], &child_entry);

    const root_stream_offset = 512 + 2 * sector_size;
    @memcpy(bytes[root_stream_offset .. root_stream_offset + 5], "HELLO");

    const mini_fat_offset = 512 + 3 * sector_size;
    writeLe32(bytes, mini_fat_offset, end_of_chain);
    for (1..sector_size / 4) |i| {
        writeLe32(bytes, mini_fat_offset + i * 4, free_sect);
    }

    return bytes;
}

fn buildSyntheticFatCfb(allocator: std.mem.Allocator) ![]u8 {
    const sector_size = 512;
    const total_sectors = 3;
    var bytes = try allocator.alloc(u8, 512 + total_sectors * sector_size);
    @memset(bytes, 0);

    @memcpy(bytes[0..8], &cfb_magic);
    writeLe16(bytes, 24, 0x003E);
    writeLe16(bytes, 26, 0x0003);
    writeLe16(bytes, 28, 0xFFFE);
    writeLe16(bytes, 30, 9);
    writeLe16(bytes, 32, 6);
    writeLe32(bytes, 44, 1);
    writeLe32(bytes, 48, 1);
    writeLe32(bytes, 56, 0); // force FAT reads for all streams
    writeLe32(bytes, 60, free_sect);
    writeLe32(bytes, 64, 0);
    writeLe32(bytes, 68, end_of_chain);
    writeLe32(bytes, 72, 0);
    writeLe32(bytes, 76, 0);
    for (0..108) |i| writeLe32(bytes, 80 + i * 4, free_sect);

    const fat_offset = 512;
    writeLe32(bytes, fat_offset + 0, fat_sect);
    writeLe32(bytes, fat_offset + 4, end_of_chain);
    writeLe32(bytes, fat_offset + 8, end_of_chain);
    for (3..sector_size / 4) |i| {
        writeLe32(bytes, fat_offset + i * 4, free_sect);
    }

    const dir_offset = 512 + sector_size;
    const root_entry = makeDirEntry("Root Entry", 5, no_stream, no_stream, 1, end_of_chain, 0);
    const child_entry = makeDirEntry("BigStream", 2, no_stream, no_stream, no_stream, 2, 6);
    @memcpy(bytes[dir_offset .. dir_offset + 128], &root_entry);
    @memcpy(bytes[dir_offset + 128 .. dir_offset + 256], &child_entry);

    const stream_offset = 512 + 2 * sector_size;
    @memcpy(bytes[stream_offset .. stream_offset + 6], "ABCDEF");

    return bytes;
}

fn writeTempTestFile(
    tmp: *std.testing.TmpDir,
    filename: []const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    try tmp.dir.writeFile(.{ .sub_path = filename, .data = data });
    return tmp.dir.realpathAlloc(allocator, filename);
}

test "open rejects non compound file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempTestFile(&tmp, "not-cfb.bin", "nope", alloc);
    defer alloc.free(path);
    try std.testing.expectError(error.NotCompoundFile, open(path, alloc));
}

test "readStreamByName reads a synthetic mini stream" {
    const alloc = std.testing.allocator;
    const bytes = try buildSyntheticMiniCfb(alloc);
    defer alloc.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempTestFile(&tmp, "synth-mini.cfb", bytes, alloc);
    defer alloc.free(path);

    var c = try open(path, alloc);
    defer c.deinit(alloc);
    const data = (try c.readStreamByName("MiniThing", alloc)).?;
    defer alloc.free(data);
    try std.testing.expectEqualStrings("HELLO", data);
}

test "readStreamByName reads a synthetic FAT stream" {
    const alloc = std.testing.allocator;
    const bytes = try buildSyntheticFatCfb(alloc);
    defer alloc.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempTestFile(&tmp, "synth-fat.cfb", bytes, alloc);
    defer alloc.free(path);

    var c = try open(path, alloc);
    defer c.deinit(alloc);
    const data = (try c.readStreamByName("BigStream", alloc)).?;
    defer alloc.free(data);
    try std.testing.expectEqualStrings("ABCDEF", data);
}

test "readStreamByName returns null when absent" {
    const alloc = std.testing.allocator;
    const bytes = try buildSyntheticMiniCfb(alloc);
    defer alloc.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempTestFile(&tmp, "synth-mini-absent.cfb", bytes, alloc);
    defer alloc.free(path);

    var c = try open(path, alloc);
    defer c.deinit(alloc);
    try std.testing.expect((try c.readStreamByName("missing", alloc)) == null);
}
