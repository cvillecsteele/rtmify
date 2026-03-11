const std = @import("std");
const evidence = @import("evidence.zig");

pub fn trimBomAndWhitespace(value: []const u8) []const u8 {
    var out = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.startsWith(u8, out, "\xEF\xBB\xBF")) out = out[3..];
    return std.mem.trim(u8, out, " \t\r\n");
}

pub fn normalizeKey(value: []const u8) []const u8 {
    return trimBomAndWhitespace(value);
}

pub fn normalizeValue(value: []const u8) []const u8 {
    return trimBomAndWhitespace(value);
}

fn isBoundaryChar(ch: u8) bool {
    return !(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-');
}

pub fn collectExactMatches(
    properties: []const evidence.Property,
    known_ids: ?[]const []const u8,
    allocator: std.mem.Allocator,
) ![]evidence.MatchedId {
    var out: std.ArrayList(evidence.MatchedId) = .empty;
    errdefer out.deinit(allocator);

    const ids = known_ids orelse return try out.toOwnedSlice(allocator);
    for (properties) |prop| {
        const prop_value = normalizeValue(prop.value);
        for (ids) |id| {
            const idx_opt = std.mem.indexOf(u8, prop_value, id);
            if (idx_opt == null) continue;
            const idx = idx_opt.?;
            const before_ok = idx == 0 or isBoundaryChar(prop_value[idx - 1]);
            const after_idx = idx + id.len;
            const after_ok = after_idx >= prop_value.len or isBoundaryChar(prop_value[after_idx]);
            if (!before_ok or !after_ok) continue;

            try out.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .source_property = try allocator.dupe(u8, prop.key),
                .matched_from_value = try allocator.dupe(u8, prop_value),
            });
        }
    }

    return try out.toOwnedSlice(allocator);
}

test "collectExactMatches matches full token values only" {
    const alloc = std.testing.allocator;
    const props = [_]evidence.Property{
        .{ .key = "Requirement", .value = "REQ-001" },
        .{ .key = "Comment", .value = "prefix REQ-002 suffix" },
        .{ .key = "Noise", .value = "REQ-0023A" },
    };
    const ids = [_][]const u8{ "REQ-001", "REQ-002", "REQ-0023" };
    const matches = try collectExactMatches(&props, &ids, alloc);
    defer {
        for (matches) |m| {
            alloc.free(m.id);
            alloc.free(m.source_property);
            alloc.free(m.matched_from_value);
        }
        alloc.free(matches);
    }

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("REQ-001", matches[0].id);
    try std.testing.expectEqualStrings("REQ-002", matches[1].id);
}
