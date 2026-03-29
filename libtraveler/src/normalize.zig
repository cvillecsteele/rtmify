const std = @import("std");
const types = @import("types.zig");

pub fn collapseWhitespaceAlloc(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var saw_space = false;
    for (std.mem.trim(u8, input, " \t\r\n")) |ch| {
        const is_space = std.ascii.isWhitespace(ch);
        if (is_space) {
            saw_space = true;
            continue;
        }
        if (saw_space and out.items.len > 0) {
            try out.append(alloc, ' ');
        }
        saw_space = false;
        try out.append(alloc, ch);
    }
    return out.toOwnedSlice(alloc);
}

pub fn normalizeAssemblyAlloc(alloc: std.mem.Allocator, raw: ?[]const u8) !?[]u8 {
    if (raw == null) return null;
    const collapsed = try collapseWhitespaceAlloc(alloc, raw.?);
    return collapsed;
}

pub fn normalizeRevisionAlloc(alloc: std.mem.Allocator, raw: ?[]const u8) !?[]u8 {
    if (raw == null) return null;
    const trimmed = std.mem.trim(u8, raw.?, " \t\r\n");
    if (trimmed.len == 0) return null;

    var upper = try alloc.alloc(u8, trimmed.len);
    defer alloc.free(upper);
    for (trimmed, 0..) |ch, idx| upper[idx] = std.ascii.toUpper(ch);

    var stripped = std.mem.trim(u8, upper, " \t\r\n");
    if (std.mem.startsWith(u8, stripped, "REV")) {
        stripped = std.mem.trim(u8, stripped[3..], " \t\r\n-_:.");
    }
    if (stripped.len == 0) return null;

    var clean: std.ArrayList(u8) = .empty;
    errdefer clean.deinit(alloc);
    try clean.appendSlice(alloc, "REV-");

    var wrote_sep = false;
    for (stripped) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try clean.append(alloc, ch);
            wrote_sep = false;
            continue;
        }
        if (ch == '-' or ch == '_' or std.ascii.isWhitespace(ch)) {
            if (!wrote_sep) {
                try clean.append(alloc, '-');
                wrote_sep = true;
            }
            continue;
        }
        return null;
    }
    if (clean.items.len == 4 and std.mem.eql(u8, clean.items, "REV-")) return null;
    if (clean.items[clean.items.len - 1] == '-') _ = clean.pop();
    const owned = try clean.toOwnedSlice(alloc);
    return owned;
}

pub fn deriveFullIdentifierAlloc(alloc: std.mem.Allocator, header: types.Header) !?[]u8 {
    const assembly = try normalizeAssemblyAlloc(alloc, header.assembly);
    defer if (assembly) |value| alloc.free(value);
    const revision = try normalizeRevisionAlloc(alloc, header.bom_revision);
    defer if (revision) |value| alloc.free(value);

    if (assembly == null or revision == null) return null;
    const full_identifier = try std.fmt.allocPrint(alloc, "{s}-{s}", .{ assembly.?, revision.? });
    return full_identifier;
}

test "revision normalization matches prd examples" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { raw: []const u8, expected: []const u8 }{
        .{ .raw = "Rev C", .expected = "REV-C" },
        .{ .raw = "REV C", .expected = "REV-C" },
        .{ .raw = "C", .expected = "REV-C" },
        .{ .raw = "rev-c", .expected = "REV-C" },
    };
    for (cases) |case| {
        const actual = try normalizeRevisionAlloc(alloc, case.raw);
        defer if (actual) |value| alloc.free(value);
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(case.expected, actual.?);
    }
}

test "assembly normalization preserves punctuation" {
    const actual = try normalizeAssemblyAlloc(std.testing.allocator, " VS200-ASSY-100 / A ");
    defer if (actual) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("VS200-ASSY-100 / A", actual.?);
}

test "derived full identifier composes assembly and revision" {
    var header = types.Header{
        .assembly = try std.testing.allocator.dupe(u8, "VS200-ASSY-100"),
        .bom_revision = try std.testing.allocator.dupe(u8, "Rev C"),
    };
    defer header.deinit(std.testing.allocator);

    const actual = try deriveFullIdentifierAlloc(std.testing.allocator, header);
    defer if (actual) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("VS200-ASSY-100-REV-C", actual.?);
}
