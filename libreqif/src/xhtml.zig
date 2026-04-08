const std = @import("std");

pub fn normalizePlainText(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var prev_space = true;
    while (i < input.len) {
        const c = input[i];
        if (isWhitespaceByte(c)) {
            if (!prev_space) {
                try out.append(allocator, ' ');
                prev_space = true;
            }
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        prev_space = false;
        i += 1;
    }

    return allocator.dupe(u8, std.mem.trim(u8, out.items, " "));
}

pub fn decodeEntities(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, '&') == null) return allocator.dupe(u8, input);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }
        const semi_rel = std.mem.indexOfScalarPos(u8, input, i, ';') orelse {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        };
        const entity = input[i + 1 .. semi_rel];
        if (std.mem.eql(u8, entity, "amp")) {
            try out.append(allocator, '&');
        } else if (std.mem.eql(u8, entity, "lt")) {
            try out.append(allocator, '<');
        } else if (std.mem.eql(u8, entity, "gt")) {
            try out.append(allocator, '>');
        } else if (std.mem.eql(u8, entity, "quot")) {
            try out.append(allocator, '"');
        } else if (std.mem.eql(u8, entity, "apos")) {
            try out.append(allocator, '\'');
        } else if (entity.len > 1 and entity[0] == '#') {
            try appendNumericEntity(allocator, &out, entity[1..]);
        } else {
            try out.appendSlice(allocator, input[i .. semi_rel + 1]);
        }
        i = semi_rel + 1;
    }

    return out.toOwnedSlice(allocator);
}

pub fn stripMarkup(allocator: std.mem.Allocator, markup: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < markup.len) {
        if (std.mem.startsWith(u8, markup[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, markup, i + 4, "-->") orelse return error.InvalidXhtml;
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, markup[i..], "<![CDATA[")) {
            const end = std.mem.indexOfPos(u8, markup, i + 9, "]]>") orelse return error.InvalidXhtml;
            try appendNormalized(allocator, &out, markup[i + 9 .. end]);
            i = end + 3;
            continue;
        }
        if (markup[i] == '<') {
            try appendNormalizedByte(allocator, &out, ' ');
            const end = std.mem.indexOfScalarPos(u8, markup, i, '>') orelse return error.InvalidXhtml;
            i = end + 1;
            continue;
        }
        if (markup[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, markup, i, ';') orelse {
                try appendNormalizedByte(allocator, &out, '&');
                i += 1;
                continue;
            };
            const entity = markup[i + 1 .. semi];
            if (std.mem.eql(u8, entity, "amp")) {
                try appendNormalizedByte(allocator, &out, '&');
            } else if (std.mem.eql(u8, entity, "lt")) {
                try appendNormalizedByte(allocator, &out, '<');
            } else if (std.mem.eql(u8, entity, "gt")) {
                try appendNormalizedByte(allocator, &out, '>');
            } else if (std.mem.eql(u8, entity, "quot")) {
                try appendNormalizedByte(allocator, &out, '"');
            } else if (std.mem.eql(u8, entity, "apos")) {
                try appendNormalizedByte(allocator, &out, '\'');
            } else if (entity.len > 1 and entity[0] == '#') {
                try appendNumericEntityNormalized(allocator, &out, entity[1..]);
            }
            i = semi + 1;
            continue;
        }
        try appendNormalizedByte(allocator, &out, markup[i]);
        i += 1;
    }

    return allocator.dupe(u8, std.mem.trim(u8, out.items, " "));
}

fn appendNumericEntity(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entity: []const u8,
) !void {
    const codepoint = if (entity.len > 1 and (entity[0] == 'x' or entity[0] == 'X'))
        try std.fmt.parseUnsigned(u21, entity[1..], 16)
    else
        try std.fmt.parseUnsigned(u21, entity, 10);
    var buf: [4]u8 = undefined;
    const encoded = try std.unicode.utf8Encode(codepoint, &buf);
    try out.appendSlice(allocator, buf[0..encoded]);
}

fn appendNumericEntityNormalized(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entity: []const u8,
) !void {
    const codepoint = if (entity.len > 1 and (entity[0] == 'x' or entity[0] == 'X'))
        try std.fmt.parseUnsigned(u21, entity[1..], 16)
    else
        try std.fmt.parseUnsigned(u21, entity, 10);
    var buf: [4]u8 = undefined;
    const encoded = try std.unicode.utf8Encode(codepoint, &buf);
    try appendNormalized(allocator, out, buf[0..encoded]);
}

fn appendNormalized(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| try appendNormalizedByte(allocator, out, c);
}

fn appendNormalizedByte(allocator: std.mem.Allocator, out: *std.ArrayList(u8), c: u8) !void {
    if (isWhitespaceByte(c)) {
        if (out.items.len == 0 or out.items[out.items.len - 1] == ' ') return;
        try out.append(allocator, ' ');
        return;
    }
    try out.append(allocator, c);
}

fn isWhitespaceByte(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

const testing = std.testing;

test "decodeEntities decodes basic XML entities" {
    const decoded = try decodeEntities(testing.allocator, "a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("a & b <c> \"d\" 'e'", decoded);
}

test "stripMarkup removes tags and collapses whitespace" {
    const text = try stripMarkup(testing.allocator, "<reqif-xhtml:div>Hello<br/> <b>world</b></reqif-xhtml:div>");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Hello world", text);
}
