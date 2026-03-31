const std = @import("std");

const archive = @import("../archive.zig");
const ctx_mod = @import("../context.zig");
const diagnostics = @import("../diagnostics.zig");
const test_results = @import("../../test_results.zig");

pub fn handle(ctx: ctx_mod.DispatchCtx, name: []const u8, path: []const u8) !void {
    const bytes = std.fs.cwd().readFileAlloc(ctx.alloc, path, 25 * 1024 * 1024) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer ctx.alloc.free(bytes);
    if (bytes.len > 10 * 1024 * 1024) {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, "TestResultsTooLarge");
        return;
    }
    var payload = test_results.parsePayload(bytes, ctx.alloc) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer payload.deinit(ctx.alloc);

    var response = test_results.ingest(ctx.db, payload, ctx.alloc) catch |err| {
        try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
        return;
    };
    defer response.deinit(ctx.alloc);

    const archived_path = try archive.archiveFile(ctx.inbox_dir, "processed", name, ctx.alloc);
    ctx.alloc.free(archived_path);
}
