/// provision.zig — provider-neutral workbook tab provisioning for industry profiles.
///
/// Creates missing tabs and writes header rows for a given profile.
/// Idempotent: never deletes or overwrites existing tabs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const profile_mod = @import("profile.zig");
const online_provider = @import("online_provider.zig");
const Profile = profile_mod.Profile;
const TabRef = online_provider.TabRef;
const ProviderRuntime = online_provider.ProviderRuntime;
const ValueUpdate = online_provider.ValueUpdate;

// ---------------------------------------------------------------------------
// Header rows per tab
// ---------------------------------------------------------------------------

const TabHeaders = struct { name: []const u8, headers: []const []const u8 };

const tab_header_map = &[_]TabHeaders{
    .{ .name = "Requirements", .headers = &.{
        "ID", "Statement", "Priority", "User Need ID", "Test Group IDs", "Lifecycle Status", "Notes", "RTMify Verification",
    }},
    .{ .name = "User Needs", .headers = &.{
        "ID", "Statement", "Source of Need Statement", "Priority",
    }},
    .{ .name = "Tests", .headers = &.{
        "Test Group ID", "Test ID", "Test Type", "Test Method",
    }},
    .{ .name = "Risks", .headers = &.{
        "Risk ID", "Description", "Initial Severity", "Initial Likelihood",
        "Mitigation", "Linked REQ", "Residual Severity", "Residual Likelihood",
    }},
    .{ .name = "Design Inputs", .headers = &.{
        "ID", "Description", "Source Requirement", "Status",
    }},
    .{ .name = "Design Outputs", .headers = &.{
        "ID", "Description", "Type", "Design Input ID", "Version", "Status",
    }},
    .{ .name = "Configuration Items", .headers = &.{
        "ID", "Description", "Type", "Version", "Design Output ID", "Status",
    }},
    .{ .name = "Product", .headers = &.{
        "assembly", "revision", "full_identifier", "description", "Product Status", "RTMify Status",
    }},
    .{ .name = "Decomposition", .headers = &.{
        "parent_id", "child_id",
    }},
};

fn headersForTab(tab_name: []const u8) ?[]const []const u8 {
    for (tab_header_map) |th| {
        if (std.mem.eql(u8, th.name, tab_name)) return th.headers;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Fuzzy tab match (reuse similar logic as schema.resolveTab but simpler)
// ---------------------------------------------------------------------------

fn tabExists(existing: []const TabRef, want: []const u8) bool {
    for (existing) |tab| {
        if (std.ascii.eqlIgnoreCase(tab.title, want)) return true;
        // Substring match
        const t_lower_buf = toLowerBuf(tab.title);
        const w_lower_buf = toLowerBuf(want);
        const t_lower = t_lower_buf[0..tab.title.len];
        const w_lower = w_lower_buf[0..want.len];
        if (std.mem.indexOf(u8, t_lower, w_lower) != null or
            std.mem.indexOf(u8, w_lower, t_lower) != null) return true;
    }
    return false;
}

fn toLowerBuf(s: []const u8) [128]u8 {
    var buf: [128]u8 = undefined;
    const len = @min(s.len, buf.len);
    for (s[0..len], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

fn collectMissingTabs(existing: []const TabRef, profile: Profile, alloc: Allocator) ![][]const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    for (profile.tabs) |tab_name| {
        if (tabExists(existing, tab_name)) continue;
        try missing.append(alloc, try alloc.dupe(u8, tab_name));
    }
    return missing.toOwnedSlice(alloc);
}

fn columnLetters(idx_1based: usize, alloc: Allocator) ![]u8 {
    var n = idx_1based;
    var reversed: std.ArrayList(u8) = .empty;
    defer reversed.deinit(alloc);
    while (n > 0) {
        const rem = (n - 1) % 26;
        try reversed.append(alloc, @as(u8, @intCast('A' + rem)));
        n = (n - 1) / 26;
    }
    const out = try alloc.alloc(u8, reversed.items.len);
    for (reversed.items, 0..) |_, i| {
        out[i] = reversed.items[reversed.items.len - 1 - i];
    }
    return out;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Provision missing tabs for the given profile.
/// Creates any tabs in profile.tabs that don't exist in the provider runtime,
/// then writes their header rows.
/// Returns a list of tab names that were created (caller owns the slice and strings).
pub fn provisionWorkbook(runtime: *ProviderRuntime, profile: Profile, alloc: Allocator) ![][]const u8 {
    const existing_tabs = try runtime.listTabs(alloc);
    defer online_provider.freeTabRefs(existing_tabs, alloc);

    var created: std.ArrayList([]const u8) = .empty;
    const missing_tabs = try collectMissingTabs(existing_tabs, profile, alloc);
    defer {
        for (missing_tabs) |tab_name| alloc.free(tab_name);
        alloc.free(missing_tabs);
    }

    for (missing_tabs) |tab_name| {
        try runtime.createTab(tab_name, alloc);

        // Write header row
        const headers = headersForTab(tab_name) orelse continue;
        var updates: std.ArrayList(ValueUpdate) = .empty;
        defer {
            for (updates.items) |u| {
                alloc.free(u.a1_range);
                alloc.free(u.values);
            }
            updates.deinit(alloc);
        }
        for (headers, 0..) |header, i| {
            const col = try columnLetters(i + 1, alloc);
            defer alloc.free(col);
            const range = try std.fmt.allocPrint(alloc, "{s}!{s}1", .{ tab_name, col });
            const values = try alloc.alloc([]const u8, 1);
            values[0] = header;
            try updates.append(alloc, .{
                .a1_range = range,
                .values = values,
            });
        }
        try runtime.batchWriteValues(updates.items, alloc);

        try created.append(alloc, try alloc.dupe(u8, tab_name));
    }

    return created.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tabExists exact match" {
    const existing = &[_]TabRef{
        .{ .title = @constCast("Requirements"), .native_id = @constCast("0") },
        .{ .title = @constCast("Tests"), .native_id = @constCast("1") },
    };
    try testing.expect(tabExists(existing, "Requirements"));
    try testing.expect(tabExists(existing, "Tests"));
    try testing.expect(!tabExists(existing, "Design Inputs"));
}

test "tabExists case-insensitive" {
    const existing = &[_]TabRef{
        .{ .title = @constCast("requirements"), .native_id = @constCast("0") },
    };
    try testing.expect(tabExists(existing, "Requirements"));
}

test "tabExists substring match" {
    const existing = &[_]TabRef{
        .{ .title = @constCast("My Requirements List"), .native_id = @constCast("0") },
    };
    try testing.expect(tabExists(existing, "Requirements"));
}

test "headersForTab returns correct headers" {
    const hdrs = headersForTab("Design Inputs");
    try testing.expect(hdrs != null);
    try testing.expect(hdrs.?.len >= 3);
    try testing.expectEqualStrings("ID", hdrs.?[0]);
}

test "headersForTab returns Product headers" {
    const hdrs = headersForTab("Product");
    try testing.expect(hdrs != null);
    try testing.expectEqual(@as(usize, 6), hdrs.?.len);
    try testing.expectEqualStrings("assembly", hdrs.?[0]);
    try testing.expectEqualStrings("RTMify Status", hdrs.?[5]);
}

test "headersForTab returns Decomposition headers" {
    const hdrs = headersForTab("Decomposition");
    try testing.expect(hdrs != null);
    try testing.expectEqual(@as(usize, 2), hdrs.?.len);
    try testing.expectEqualStrings("parent_id", hdrs.?[0]);
    try testing.expectEqualStrings("child_id", hdrs.?[1]);
}

test "headersForTab returns null for unknown tab" {
    try testing.expect(headersForTab("Unknown Tab XYZ") == null);
}

test "collectMissingTabs excludes genuinely existing tabs with spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const existing = &[_]TabRef{
        .{ .title = @constCast("User Needs"), .native_id = @constCast("0") },
        .{ .title = @constCast("Requirements"), .native_id = @constCast("1") },
    };
    const missing = try collectMissingTabs(existing, profile_mod.get(.aerospace), alloc);
    defer {
        for (missing) |tab| alloc.free(tab);
        alloc.free(missing);
    }
    try testing.expectEqual(@as(usize, 5), missing.len);
    try testing.expectEqualStrings("Tests", missing[0]);
    try testing.expectEqualStrings("Decomposition", missing[4]);
}

test "columnLetters maps spreadsheet columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const a = try columnLetters(1, alloc);
    defer alloc.free(a);
    const z = try columnLetters(26, alloc);
    defer alloc.free(z);
    const aa = try columnLetters(27, alloc);
    defer alloc.free(aa);
    const af = try columnLetters(32, alloc);
    defer alloc.free(af);
    try testing.expectEqualStrings("A", a);
    try testing.expectEqualStrings("Z", z);
    try testing.expectEqualStrings("AA", aa);
    try testing.expectEqualStrings("AF", af);
}
