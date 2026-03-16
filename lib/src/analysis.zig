const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const profile_mod = @import("profile.zig");
const schema = @import("schema.zig");
const xlsx = @import("xlsx.zig");

pub fn ingestOptionsForProfile(profile_id: profile_mod.ProfileId) schema.IngestOptions {
    return switch (profile_id) {
        .generic => .{},
        .medical => .{
            .enable_product_tab = true,
            .enable_design_inputs_tab = true,
            .enable_design_outputs_tab = true,
            .enable_config_items_tab = true,
        },
        .aerospace => .{
            .enable_product_tab = true,
            .enable_decomposition_tab = true,
            .enable_config_items_tab = true,
        },
        .automotive => .{
            .enable_product_tab = true,
            .enable_config_items_tab = true,
        },
    };
}

pub fn warnMissingProfileTabs(
    sheets: []const xlsx.SheetData,
    profile_id: profile_mod.ProfileId,
    diag: *diagnostic.Diagnostics,
) !void {
    if (profile_id == .generic) return;

    const prof = profile_mod.get(profile_id);
    for (prof.tabs) |tab| {
        if (std.mem.eql(u8, tab, "User Needs") or
            std.mem.eql(u8, tab, "Requirements") or
            std.mem.eql(u8, tab, "Tests") or
            std.mem.eql(u8, tab, "Risks")) continue;
        if (schema.hasTab(sheets, tab)) continue;
        try diag.warn(
            diagnostic.E.profile_expected_tab_missing,
            .profile,
            null,
            null,
            "Profile '{s}' expects tab '{s}', but it is not present in this workbook",
            .{ prof.short_name, tab },
        );
    }
}

const testing = std.testing;

test "warnMissingProfileTabs ignores generic" {
    var diag = diagnostic.Diagnostics.init(testing.allocator);
    defer diag.deinit();

    try warnMissingProfileTabs(&.{}, .generic, &diag);
    try testing.expectEqual(@as(usize, 0), diag.entries.items.len);
}

test "warnMissingProfileTabs flags missing profile tabs" {
    var diag = diagnostic.Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const user_need_rows = [_]xlsx.Row{&.{ "ID", "Need" }};
    const requirement_rows = [_]xlsx.Row{&.{ "ID", "Statement" }};
    const test_rows = [_]xlsx.Row{&.{ "ID", "Procedure" }};
    const risk_rows = [_]xlsx.Row{&.{ "ID", "Hazard" }};
    const sheets = [_]xlsx.SheetData{
        .{ .name = "User Needs", .rows = user_need_rows[0..] },
        .{ .name = "Requirements", .rows = requirement_rows[0..] },
        .{ .name = "Tests", .rows = test_rows[0..] },
        .{ .name = "Risks", .rows = risk_rows[0..] },
    };

    try warnMissingProfileTabs(sheets[0..], .medical, &diag);
    try testing.expect(diag.warning_count > 0);
}
