const std = @import("std");
const Allocator = std.mem.Allocator;

const artifact_discriminator = @import("../artifact_discriminator.zig");
const ctx_mod = @import("context.zig");
const diagnostics = @import("diagnostics.zig");
const design_artifacts_handler = @import("handlers/design_artifacts.zig");
const bom_handler = @import("handlers/bom.zig");
const soup_handler = @import("handlers/soup.zig");
const test_results_handler = @import("handlers/test_results.zig");
const graph_live = @import("../graph_live.zig");

pub fn processOneFile(db: *graph_live.GraphDb, inbox_dir: []const u8, name: []const u8, alloc: Allocator) !void {
    const path = try std.fs.path.join(alloc, &.{ inbox_dir, name });
    defer alloc.free(path);

    var discrimination = artifact_discriminator.discriminateInboxPath(path, name, alloc) catch |err| {
        try diagnostics.rejectFile(db, inbox_dir, name, alloc, @errorName(err));
        return;
    };
    defer discrimination.deinit(alloc);
    if (!discrimination.accepted) {
        try diagnostics.rejectDiscriminatedFile(db, inbox_dir, name, alloc, discrimination);
        return;
    }

    const ctx: ctx_mod.DispatchCtx = .{
        .db = db,
        .inbox_dir = inbox_dir,
        .alloc = alloc,
    };
    switch (discrimination.kind.?) {
        .test_results => try test_results_handler.handle(ctx, name, path),
        .bom => try bom_handler.handle(ctx, name, path),
        .soup => try soup_handler.handle(ctx, name, path),
        .rtm_workbook, .urs_docx, .srs_docx, .swrs_docx, .hrs_docx, .sysrd_docx => {
            try design_artifacts_handler.handle(ctx, name, discrimination);
        },
    }
}
