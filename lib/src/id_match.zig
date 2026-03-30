const std = @import("std");
const Allocator = std.mem.Allocator;
const structured_id = @import("id.zig");

pub const Match = union(enum) {
    none,
    exact: []const u8,
    related_unknown,
};

pub const Token = struct {
    value: []const u8,
    start: usize,
    end: usize,
};

pub const TokenIterator = struct {
    text: []const u8,
    cursor: usize = 0,

    pub fn init(text: []const u8) TokenIterator {
        return .{ .text = text };
    }

    pub fn next(self: *TokenIterator) ?Token {
        while (self.cursor < self.text.len and !isTokenChar(self.text[self.cursor])) : (self.cursor += 1) {}
        if (self.cursor >= self.text.len) return null;

        const start = self.cursor;
        while (self.cursor < self.text.len and isTokenChar(self.text[self.cursor])) : (self.cursor += 1) {}

        return .{
            .value = self.text[start..self.cursor],
            .start = start,
            .end = self.cursor,
        };
    }
};

pub const ScanResult = struct {
    pub const OccurrenceKind = enum {
        exact,
        related_unknown,
    };

    pub const Occurrence = struct {
        kind: OccurrenceKind,
        token: []const u8,
        canonical_id: ?[]const u8,
        start: usize,
        end: usize,
    };

    exact_ids: [][]const u8,
    related_unknown_ids: [][]const u8,
    occurrences: []Occurrence,

    pub fn deinit(self: *ScanResult, alloc: Allocator) void {
        for (self.exact_ids) |value| alloc.free(value);
        if (self.exact_ids.len > 0) alloc.free(self.exact_ids);

        for (self.related_unknown_ids) |value| alloc.free(value);
        if (self.related_unknown_ids.len > 0) alloc.free(self.related_unknown_ids);

        for (self.occurrences) |occurrence| {
            alloc.free(occurrence.token);
            if (occurrence.canonical_id) |canonical_id| alloc.free(canonical_id);
        }
        if (self.occurrences.len > 0) alloc.free(self.occurrences);

        self.* = .{ .exact_ids = &.{}, .related_unknown_ids = &.{}, .occurrences = &.{} };
    }
};

pub const Catalog = struct {
    alloc: Allocator,
    canonical_ids: [][]const u8,
    exact_index: std.StringHashMapUnmanaged(usize),
    known_prefixes: std.StringHashMapUnmanaged(void),

    pub fn init(alloc: Allocator, ids: []const []const u8) !Catalog {
        var canonical_ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (canonical_ids.items) |value| alloc.free(value);
            canonical_ids.deinit(alloc);
        }

        var exact_index: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer exact_index.deinit(alloc);

        var known_prefixes: std.StringHashMapUnmanaged(void) = .empty;
        errdefer {
            var it = known_prefixes.keyIterator();
            while (it.next()) |prefix| alloc.free(prefix.*);
            known_prefixes.deinit(alloc);
        }

        for (ids) |raw_id| {
            const trimmed = std.mem.trim(u8, raw_id, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (exact_index.contains(trimmed)) continue;

            const owned_id = try alloc.dupe(u8, trimmed);
            errdefer alloc.free(owned_id);

            const idx = canonical_ids.items.len;
            try canonical_ids.append(alloc, owned_id);
            try exact_index.put(alloc, owned_id, idx);

            if (!structured_id.isStructuredId(owned_id)) continue;

            const prefix = firstSegment(owned_id);
            if (known_prefixes.contains(prefix)) continue;
            try known_prefixes.put(alloc, try alloc.dupe(u8, prefix), {});
        }

        return .{
            .alloc = alloc,
            .canonical_ids = try canonical_ids.toOwnedSlice(alloc),
            .exact_index = exact_index,
            .known_prefixes = known_prefixes,
        };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.canonical_ids) |value| self.alloc.free(value);
        if (self.canonical_ids.len > 0) self.alloc.free(self.canonical_ids);

        var prefix_it = self.known_prefixes.keyIterator();
        while (prefix_it.next()) |prefix| self.alloc.free(prefix.*);

        self.exact_index.deinit(self.alloc);
        self.known_prefixes.deinit(self.alloc);
        self.* = .{
            .alloc = self.alloc,
            .canonical_ids = &.{},
            .exact_index = .empty,
            .known_prefixes = .empty,
        };
    }

    pub fn resolveExact(self: *const Catalog, candidate: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
        const idx = self.exact_index.get(trimmed) orelse return null;
        return self.canonical_ids[idx];
    }

    pub fn contains(self: *const Catalog, candidate: []const u8) bool {
        return self.resolveExact(candidate) != null;
    }

    pub fn classify(self: *const Catalog, candidate: []const u8) Match {
        if (self.resolveExact(candidate)) |canonical| return .{ .exact = canonical };

        const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
        if (!structured_id.isStructuredId(trimmed)) return .none;
        if (!self.known_prefixes.contains(firstSegment(trimmed))) return .none;
        return .related_unknown;
    }

    pub fn scanText(self: *const Catalog, text: []const u8, alloc: Allocator) !ScanResult {
        var exact_ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (exact_ids.items) |value| alloc.free(value);
            exact_ids.deinit(alloc);
        }

        var related_unknown_ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (related_unknown_ids.items) |value| alloc.free(value);
            related_unknown_ids.deinit(alloc);
        }

        var occurrences: std.ArrayList(ScanResult.Occurrence) = .empty;
        errdefer {
            for (occurrences.items) |occurrence| {
                alloc.free(occurrence.token);
                if (occurrence.canonical_id) |canonical_id| alloc.free(canonical_id);
            }
            occurrences.deinit(alloc);
        }

        var it = TokenIterator.init(text);
        while (it.next()) |token| {
            switch (self.classify(token.value)) {
                .none => {},
                .exact => |canonical| {
                    try occurrences.append(alloc, .{
                        .kind = .exact,
                        .token = try alloc.dupe(u8, token.value),
                        .canonical_id = try alloc.dupe(u8, canonical),
                        .start = token.start,
                        .end = token.end,
                    });
                    if (containsString(exact_ids.items, canonical)) continue;
                    try exact_ids.append(alloc, try alloc.dupe(u8, canonical));
                },
                .related_unknown => {
                    try occurrences.append(alloc, .{
                        .kind = .related_unknown,
                        .token = try alloc.dupe(u8, token.value),
                        .canonical_id = null,
                        .start = token.start,
                        .end = token.end,
                    });
                    if (containsString(related_unknown_ids.items, token.value)) continue;
                    try related_unknown_ids.append(alloc, try alloc.dupe(u8, token.value));
                },
            }
        }

        return .{
            .exact_ids = try exact_ids.toOwnedSlice(alloc),
            .related_unknown_ids = try related_unknown_ids.toOwnedSlice(alloc),
            .occurrences = try occurrences.toOwnedSlice(alloc),
        };
    }
};

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

fn firstSegment(value: []const u8) []const u8 {
    const dash_idx = std.mem.indexOfScalar(u8, value, '-') orelse return value;
    return value[0..dash_idx];
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "Catalog resolves exact IDs and preserves canonical values" {
    var catalog = try Catalog.init(std.testing.allocator, &.{ "REQ-001", "REQ-002", "REQ-001" });
    defer catalog.deinit();

    try std.testing.expect(catalog.contains("REQ-001"));
    try std.testing.expectEqualStrings("REQ-001", catalog.resolveExact("REQ-001").?);
    try std.testing.expect(catalog.resolveExact("REQ-404") == null);
}

test "Catalog exact resolution trims known IDs and keeps non-structured exact IDs exact-only" {
    var catalog = try Catalog.init(std.testing.allocator, &.{ "  REQ-001  ", "AlphaBeta" });
    defer catalog.deinit();

    try std.testing.expectEqualStrings("REQ-001", catalog.resolveExact("REQ-001").?);
    try std.testing.expectEqualStrings("AlphaBeta", catalog.resolveExact("AlphaBeta").?);
    try std.testing.expectEqual(Match.none, catalog.classify("AlphaBeta-2"));
}

test "Catalog classify reports related unknown structured IDs by family" {
    var catalog = try Catalog.init(std.testing.allocator, &.{ "REQ-001", "UN-001" });
    defer catalog.deinit();

    try std.testing.expectEqual(Match{ .exact = "REQ-001" }, catalog.classify("REQ-001"));
    try std.testing.expectEqual(Match.related_unknown, catalog.classify("REQ-999"));
    try std.testing.expectEqual(Match.none, catalog.classify("plain prose"));
    try std.testing.expectEqual(Match.none, catalog.classify("TEST-001"));
}

test "Catalog scanText extracts exact and related unknown IDs without substring false positives" {
    var catalog = try Catalog.init(std.testing.allocator, &.{ "REQ-001", "Foo-1AF5-Bar-Q5" });
    defer catalog.deinit();

    var scan = try catalog.scanText(
        "REQ-001 implemented here; REQ-0012 is not the same; REQ-999 is stale; Foo-1AF5-Bar-Q9 moved",
        std.testing.allocator,
    );
    defer scan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), scan.exact_ids.len);
    try std.testing.expectEqualStrings("REQ-001", scan.exact_ids[0]);
    try std.testing.expectEqual(@as(usize, 2), scan.related_unknown_ids.len);
    try std.testing.expectEqualStrings("REQ-999", scan.related_unknown_ids[0]);
    try std.testing.expectEqualStrings("Foo-1AF5-Bar-Q9", scan.related_unknown_ids[1]);
}

test "Catalog scanText reports punctuation-bounded occurrences with stable ordering and offsets" {
    var catalog = try Catalog.init(std.testing.allocator, &.{ "REQ-001", "REQ-002" });
    defer catalog.deinit();

    const text = "(REQ-002), REQ-001; REQ-002 and REQ-404.";
    var scan = try catalog.scanText(text, std.testing.allocator);
    defer scan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), scan.exact_ids.len);
    try std.testing.expectEqualStrings("REQ-002", scan.exact_ids[0]);
    try std.testing.expectEqualStrings("REQ-001", scan.exact_ids[1]);
    try std.testing.expectEqual(@as(usize, 1), scan.related_unknown_ids.len);
    try std.testing.expectEqualStrings("REQ-404", scan.related_unknown_ids[0]);

    try std.testing.expectEqual(@as(usize, 4), scan.occurrences.len);
    try std.testing.expectEqual(ScanResult.OccurrenceKind.exact, scan.occurrences[0].kind);
    try std.testing.expectEqualStrings("REQ-002", scan.occurrences[0].token);
    try std.testing.expectEqualStrings("REQ-002", scan.occurrences[0].canonical_id.?);
    try std.testing.expectEqual(@as(usize, 1), scan.occurrences[0].start);
    try std.testing.expectEqual(@as(usize, 8), scan.occurrences[0].end);
    try std.testing.expectEqual(ScanResult.OccurrenceKind.exact, scan.occurrences[1].kind);
    try std.testing.expectEqualStrings("REQ-001", scan.occurrences[1].token);
    try std.testing.expectEqual(@as(usize, 11), scan.occurrences[1].start);
    try std.testing.expectEqual(ScanResult.OccurrenceKind.exact, scan.occurrences[2].kind);
    try std.testing.expectEqualStrings("REQ-002", scan.occurrences[2].token);
    try std.testing.expectEqual(@as(usize, 20), scan.occurrences[2].start);
    try std.testing.expectEqual(ScanResult.OccurrenceKind.related_unknown, scan.occurrences[3].kind);
    try std.testing.expectEqualStrings("REQ-404", scan.occurrences[3].token);
    try std.testing.expect(scan.occurrences[3].canonical_id == null);
}
