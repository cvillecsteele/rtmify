/// provision.zig — Google Sheets tab provisioning for industry profiles.
///
/// Creates missing tabs and writes header rows for a given profile.
/// Idempotent: never deletes or overwrites existing tabs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sheets = @import("sheets.zig");
const SheetTabId = sheets.SheetTabId;
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;

// ---------------------------------------------------------------------------
// Header rows per tab
// ---------------------------------------------------------------------------

const TabHeaders = struct { name: []const u8, headers: []const []const u8 };

const tab_header_map = &[_]TabHeaders{
    .{ .name = "Requirements", .headers = &.{
        "ID", "Statement", "Priority", "User Need ID", "Test Group ID", "Lifecycle Status", "Notes",
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

fn tabExists(existing: []const SheetTabId, want: []const u8) bool {
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

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Provision missing tabs for the given profile.
/// Creates any tabs in profile.tabs that don't exist in existing_tabs,
/// then writes their header rows.
/// Returns a list of tab names that were created (caller owns the slice and strings).
pub fn provisionSheet(
    client: *std.http.Client,
    token: []const u8,
    sheet_id: []const u8,
    profile: Profile,
    existing_tabs: []const SheetTabId,
    alloc: Allocator,
) ![][]const u8 {
    var created: std.ArrayList([]const u8) = .empty;

    for (profile.tabs) |tab_name| {
        if (tabExists(existing_tabs, tab_name)) continue;

        // Build addSheet request
        const add_req = try std.fmt.allocPrint(alloc,
            \\[{{"addSheet":{{"properties":{{"title":"{s}"}}}}}}]
        , .{tab_name});
        defer alloc.free(add_req);

        try sheets.batchUpdateFormat(client, token, sheet_id, add_req, alloc);

        // Write header row
        const headers = headersForTab(tab_name) orelse continue;
        const range = try std.fmt.allocPrint(alloc, "{s}!A1", .{tab_name});
        defer alloc.free(range);

        try sheets.batchUpdateValues(client, token, sheet_id, &.{
            .{ .range = range, .values = headers },
        }, alloc);

        try created.append(alloc, try alloc.dupe(u8, tab_name));
    }

    return created.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "tabExists exact match" {
    const existing = &[_]SheetTabId{
        .{ .title = @constCast("Requirements"), .id = 0 },
        .{ .title = @constCast("Tests"), .id = 1 },
    };
    try testing.expect(tabExists(existing, "Requirements"));
    try testing.expect(tabExists(existing, "Tests"));
    try testing.expect(!tabExists(existing, "Design Inputs"));
}

test "tabExists case-insensitive" {
    const existing = &[_]SheetTabId{
        .{ .title = @constCast("requirements"), .id = 0 },
    };
    try testing.expect(tabExists(existing, "Requirements"));
}

test "tabExists substring match" {
    const existing = &[_]SheetTabId{
        .{ .title = @constCast("My Requirements List"), .id = 0 },
    };
    try testing.expect(tabExists(existing, "Requirements"));
}

test "headersForTab returns correct headers" {
    const hdrs = headersForTab("Design Inputs");
    try testing.expect(hdrs != null);
    try testing.expect(hdrs.?.len >= 3);
    try testing.expectEqualStrings("ID", hdrs.?[0]);
}

test "headersForTab returns null for unknown tab" {
    try testing.expect(headersForTab("Unknown Tab XYZ") == null);
}
