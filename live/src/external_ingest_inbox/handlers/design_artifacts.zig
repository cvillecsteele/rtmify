const std = @import("std");

const artifact_discriminator = @import("../../artifact_discriminator.zig");
const archive = @import("../archive.zig");
const ctx_mod = @import("../context.zig");
const design_artifacts = @import("../../design_artifacts.zig");
const diagnostics = @import("../diagnostics.zig");

pub fn handle(
    ctx: ctx_mod.DispatchCtx,
    name: []const u8,
    discrimination: artifact_discriminator.DiscriminationResult,
) !void {
    const kind_enum = artifact_discriminator.candidateKindToDesignArtifactKind(discrimination.kind.?) orelse unreachable;
    const logical_key = try ctx.alloc.dupe(u8, discrimination.filename_stem_slug);
    defer ctx.alloc.free(logical_key);
    const archived_path = try archive.archiveDesignArtifactFile(ctx.inbox_dir, kind_enum, logical_key, name, ctx.alloc);
    defer ctx.alloc.free(archived_path);

    switch (kind_enum) {
        .rtm_workbook => {
            var ingest_result = design_artifacts.ingestRtmWorkbookPath(
                ctx.db,
                archived_path,
                logical_key,
                std.fs.path.basename(archived_path),
                "external_inbox",
                ctx.alloc,
            ) catch |err| {
                try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
                return;
            };
            defer ingest_result.deinit(ctx.alloc);
        },
        .urs_docx, .srs_docx, .swrs_docx, .hrs_docx, .sysrd_docx => {
            var ingest_result = design_artifacts.ingestDocxPath(
                ctx.db,
                archived_path,
                kind_enum,
                logical_key,
                std.fs.path.basename(archived_path),
                "external_inbox",
                ctx.alloc,
            ) catch |err| {
                try diagnostics.rejectFile(ctx.db, ctx.inbox_dir, name, ctx.alloc, @errorName(err));
                return;
            };
            defer ingest_result.deinit(ctx.alloc);
        },
    }
}
