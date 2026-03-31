const std = @import("std");

const archive = @import("../archive.zig");
const bom = @import("../../bom.zig");
const ctx_mod = @import("../context.zig");
const diagnostics = @import("../diagnostics.zig");

pub fn handle(ctx: ctx_mod.DispatchCtx, name: []const u8, path: []const u8) !void {
    const bytes = std.fs.cwd().readFileAlloc(ctx.alloc, path, 25 * 1024 * 1024) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer ctx.alloc.free(bytes);

    if (std.mem.endsWith(u8, name, ".xlsx")) {
        var grouped = bom.ingestXlsxBody(ctx.db, bytes, ctx.alloc) catch |err| {
            try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
            return;
        };
        defer grouped.deinit(ctx.alloc);

        const archived_path = try archive.archiveFile(ctx.inbox_dir, "processed", name, ctx.alloc);
        defer ctx.alloc.free(archived_path);
        try diagnostics.recordGroupedBomWarnings(ctx.db, archived_path, grouped, ctx.alloc);
        return;
    }

    var response = bom.ingestInboxFile(ctx.db, name, bytes, ctx.alloc) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer response.deinit(ctx.alloc);

    const archived_path = try archive.archiveFile(ctx.inbox_dir, "processed", name, ctx.alloc);
    defer ctx.alloc.free(archived_path);
    try diagnostics.recordBomWarnings(ctx.db, archived_path, response, ctx.alloc);
}
