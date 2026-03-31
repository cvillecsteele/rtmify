const std = @import("std");

const archive = @import("../archive.zig");
const ctx_mod = @import("../context.zig");
const diagnostics = @import("../diagnostics.zig");
const soup = @import("../../soup.zig");

pub fn handle(ctx: ctx_mod.DispatchCtx, name: []const u8, path: []const u8) !void {
    const full_product_identifier = extractSoupInboxProductIdentifier(name) orelse {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, "SOUP_NO_PRODUCT_IDENTIFIER");
        return;
    };
    var response = soup.ingestXlsxInboxPath(ctx.db, path, full_product_identifier, ctx.alloc) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer response.deinit(ctx.alloc);

    const archived_path = try archive.archiveFile(ctx.inbox_dir, "processed", name, ctx.alloc);
    defer ctx.alloc.free(archived_path);
    try diagnostics.recordSoupWarnings(ctx.db, archived_path, response, ctx.alloc);
}

pub fn extractSoupInboxProductIdentifier(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "SOUP__")) return null;
    if (!std.mem.endsWith(u8, name, ".xlsx")) return null;
    return name["SOUP__".len .. name.len - ".xlsx".len];
}

const testing = std.testing;

test "extractSoupInboxProductIdentifier matches current SOUP naming" {
    try testing.expectEqualStrings("ASM-1000-REV-C", extractSoupInboxProductIdentifier("SOUP__ASM-1000-REV-C.xlsx").?);
    try testing.expect(extractSoupInboxProductIdentifier("SOUP__ASM-1000-REV-C.csv") == null);
    try testing.expect(extractSoupInboxProductIdentifier("firmware.xlsx") == null);
}
