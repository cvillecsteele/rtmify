const std = @import("std");

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const StartTag = struct {
    name: []const u8,
    attrs: []const Attribute,
    self_closing: bool,
};

pub const Token = union(enum) {
    start: StartTag,
    end: []const u8,
    text: []const u8,
};

pub const Tokenizer = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,
    scratch_attrs: std.ArrayList(Attribute) = .empty,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Tokenizer {
        return .{
            .allocator = allocator,
            .input = input,
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.scratch_attrs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *Tokenizer) !?Token {
        while (self.pos < self.input.len) {
            if (self.input[self.pos] != '<') {
                const start = self.pos;
                const end = std.mem.indexOfScalarPos(u8, self.input, self.pos, '<') orelse self.input.len;
                self.pos = end;
                return .{ .text = self.input[start..end] };
            }

            if (std.mem.startsWith(u8, self.input[self.pos..], "<!--")) {
                const end = std.mem.indexOfPos(u8, self.input, self.pos + 4, "-->") orelse return error.InvalidXml;
                self.pos = end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<?")) {
                const end = std.mem.indexOfPos(u8, self.input, self.pos + 2, "?>") orelse return error.InvalidXml;
                self.pos = end + 2;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, self.input, self.pos + 9, "]]>") orelse return error.InvalidXml;
                const text = self.input[self.pos + 9 .. end];
                self.pos = end + 3;
                return .{ .text = text };
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<!DOCTYPE")) {
                const end = std.mem.indexOfScalarPos(u8, self.input, self.pos, '>') orelse return error.InvalidXml;
                self.pos = end + 1;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "</")) {
                return try self.parseEndTag();
            }
            return try self.parseStartTag();
        }
        return null;
    }

    pub fn captureRawUntilEnd(self: *Tokenizer, expected_end_local_name: []const u8) ![]const u8 {
        const content_start = self.pos;
        var depth: usize = 0;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] != '<') {
                self.pos += 1;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<!--")) {
                const end = std.mem.indexOfPos(u8, self.input, self.pos + 4, "-->") orelse return error.InvalidXml;
                self.pos = end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<?")) {
                const end = std.mem.indexOfPos(u8, self.input, self.pos + 2, "?>") orelse return error.InvalidXml;
                self.pos = end + 2;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, self.input, self.pos + 9, "]]>") orelse return error.InvalidXml;
                self.pos = end + 3;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "</")) {
                const name_start = self.pos + 2;
                const name_end = scanNameEnd(self.input, name_start);
                const local = localName(self.input[name_start..name_end]);
                const tag_end = std.mem.indexOfScalarPos(u8, self.input, name_end, '>') orelse return error.InvalidXml;
                if (depth == 0 and std.mem.eql(u8, local, expected_end_local_name)) {
                    const raw = self.input[content_start..self.pos];
                    self.pos = tag_end + 1;
                    return raw;
                }
                if (std.mem.eql(u8, local, expected_end_local_name) and depth > 0) depth -= 1;
                self.pos = tag_end + 1;
                continue;
            }
            const name_start = self.pos + 1;
            const name_end = scanNameEnd(self.input, name_start);
            const local = localName(self.input[name_start..name_end]);
            const tag_end = std.mem.indexOfScalarPos(u8, self.input, name_end, '>') orelse return error.InvalidXml;
            const self_closing = tag_end > name_end and self.input[tag_end - 1] == '/';
            if (!self_closing and std.mem.eql(u8, local, expected_end_local_name)) depth += 1;
            self.pos = tag_end + 1;
        }
        return error.InvalidXml;
    }

    fn parseEndTag(self: *Tokenizer) !Token {
        const name_start = self.pos + 2;
        const name_end = scanNameEnd(self.input, name_start);
        const tag_end = std.mem.indexOfScalarPos(u8, self.input, name_end, '>') orelse return error.InvalidXml;
        const name = self.input[name_start..name_end];
        self.pos = tag_end + 1;
        return .{ .end = name };
    }

    fn parseStartTag(self: *Tokenizer) !Token {
        try self.scratch_attrs.resize(self.allocator, 0);

        const name_start = self.pos + 1;
        var cursor = scanNameEnd(self.input, name_start);
        const name = self.input[name_start..cursor];

        while (true) {
            cursor = skipWhitespace(self.input, cursor);
            if (cursor >= self.input.len) return error.InvalidXml;
            if (self.input[cursor] == '>') {
                self.pos = cursor + 1;
                return .{ .start = .{
                    .name = name,
                    .attrs = self.scratch_attrs.items,
                    .self_closing = false,
                } };
            }
            if (self.input[cursor] == '/' and cursor + 1 < self.input.len and self.input[cursor + 1] == '>') {
                self.pos = cursor + 2;
                return .{ .start = .{
                    .name = name,
                    .attrs = self.scratch_attrs.items,
                    .self_closing = true,
                } };
            }

            const attr_name_start = cursor;
            const attr_name_end = scanNameEnd(self.input, attr_name_start);
            const attr_name = self.input[attr_name_start..attr_name_end];
            cursor = skipWhitespace(self.input, attr_name_end);
            if (cursor >= self.input.len or self.input[cursor] != '=') return error.InvalidXml;
            cursor += 1;
            cursor = skipWhitespace(self.input, cursor);
            if (cursor >= self.input.len) return error.InvalidXml;
            const quote = self.input[cursor];
            if (quote != '"' and quote != '\'') return error.InvalidXml;
            cursor += 1;
            const value_start = cursor;
            const value_end = std.mem.indexOfScalarPos(u8, self.input, value_start, quote) orelse return error.InvalidXml;
            try self.scratch_attrs.append(self.allocator, .{
                .name = attr_name,
                .value = self.input[value_start..value_end],
            });
            cursor = value_end + 1;
        }
    }
};

pub fn localName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| name[colon + 1 ..] else name;
}

pub fn attr(start: StartTag, needle: []const u8) ?[]const u8 {
    for (start.attrs) |item| {
        if (std.mem.eql(u8, item.name, needle) or std.mem.eql(u8, localName(item.name), needle)) {
            return item.value;
        }
    }
    return null;
}

fn skipWhitespace(input: []const u8, pos: usize) usize {
    var cursor = pos;
    while (cursor < input.len and (input[cursor] == ' ' or input[cursor] == '\n' or input[cursor] == '\r' or input[cursor] == '\t')) : (cursor += 1) {}
    return cursor;
}

fn scanNameEnd(input: []const u8, pos: usize) usize {
    var cursor = pos;
    while (cursor < input.len) : (cursor += 1) {
        const c = input[cursor];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '/' or c == '>' or c == '=') break;
    }
    return cursor;
}

const testing = std.testing;

test "Tokenizer parses start, text, and end tags" {
    var tok = Tokenizer.init(testing.allocator, "<a x=\"1\">hi</a>");
    defer tok.deinit();

    const start = (try tok.next()).?.start;
    try testing.expectEqualStrings("a", localName(start.name));
    try testing.expectEqualStrings("1", attr(start, "x").?);

    const text = (try tok.next()).?.text;
    try testing.expectEqualStrings("hi", text);

    const end = (try tok.next()).?.end;
    try testing.expectEqualStrings("a", localName(end));
    try testing.expect((try tok.next()) == null);
}
