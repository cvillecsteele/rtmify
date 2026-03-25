const std = @import("std");

const Allocator = std.mem.Allocator;

const json_util = @import("../json_util.zig");
const shared = @import("../routes/shared.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn appendJsonValue(buf: *std.ArrayList(u8), value: std.json.Value, alloc: Allocator) !void {
    switch (value) {
        .null => try buf.appendSlice(alloc, "null"),
        .bool => |v| try buf.appendSlice(alloc, if (v) "true" else "false"),
        .integer => |v| try std.fmt.format(buf.writer(alloc), "{d}", .{v}),
        .float => |v| try std.fmt.format(buf.writer(alloc), "{d}", .{v}),
        .number_string => |v| try buf.appendSlice(alloc, v),
        .string => |v| try json_util.appendJsonQuoted(buf, v, alloc),
        else => try json_util.appendJsonQuoted(buf, "", alloc),
    }
}

pub fn buildRequirementTextProperties(
    artifact_id: []const u8,
    kind: types.ArtifactKind,
    assertion: types.ParsedRequirementAssertion,
    imported_at: []const u8,
    alloc: Allocator,
) ![]const u8 {
    const hash_hex = util.hashNormalizedText(assertion.normalized_text);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"req_id\":");
    try shared.appendJsonStr(&buf, assertion.req_id, alloc);
    try buf.appendSlice(alloc, ",\"artifact_id\":");
    try shared.appendJsonStr(&buf, artifact_id, alloc);
    try buf.appendSlice(alloc, ",\"source_kind\":");
    try shared.appendJsonStr(&buf, kind.toString(), alloc);
    try buf.appendSlice(alloc, ",\"section\":");
    try shared.appendJsonStr(&buf, assertion.section, alloc);
    try buf.appendSlice(alloc, ",\"text\":");
    try shared.appendJsonStrOpt(&buf, assertion.text, alloc);
    try buf.appendSlice(alloc, ",\"normalized_text\":");
    try shared.appendJsonStrOpt(&buf, assertion.normalized_text, alloc);
    try buf.appendSlice(alloc, ",\"hash\":");
    try shared.appendJsonStr(&buf, &hash_hex, alloc);
    try buf.appendSlice(alloc, ",\"imported_at\":");
    try shared.appendJsonStr(&buf, imported_at, alloc);
    try buf.appendSlice(alloc, ",\"parse_status\":");
    try shared.appendJsonStr(&buf, assertion.parse_status, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"occurrence_count\":{d}}}", .{assertion.occurrence_count});
    return alloc.dupe(u8, buf.items);
}

pub fn stripAndExtendRequirementProperties(
    raw_props: []const u8,
    authoritative_source: ?[]const u8,
    text_status: []const u8,
    source_count: usize,
    alloc: Allocator,
) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw_props, .{});
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '{');
    var first = true;
    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "statement") or
                std.mem.eql(u8, key, "effective_statement") or
                std.mem.eql(u8, key, "effective_statement_source") or
                std.mem.eql(u8, key, "text_status") or
                std.mem.eql(u8, key, "authoritative_source") or
                std.mem.eql(u8, key, "source_count") or
                std.mem.eql(u8, key, "source_assertions"))
            {
                continue;
            }
            if (!first) try buf.append(alloc, ',');
            first = false;
            try json_util.appendJsonQuoted(&buf, key, alloc);
            try buf.append(alloc, ':');
            try appendJsonValue(&buf, entry.value_ptr.*, alloc);
        }
    }
    if (!first) try buf.append(alloc, ',');
    try buf.appendSlice(alloc, "\"text_status\":");
    try shared.appendJsonStr(&buf, text_status, alloc);
    try buf.appendSlice(alloc, ",\"authoritative_source\":");
    try shared.appendJsonStrOpt(&buf, authoritative_source, alloc);
    try std.fmt.format(buf.writer(alloc), ",\"source_count\":{d}}}", .{source_count});
    return alloc.dupe(u8, buf.items);
}
