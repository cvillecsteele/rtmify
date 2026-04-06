const std = @import("std");

const artifacts = @import("build/artifacts.zig");
const options = @import("build/options.zig");
const release = @import("build/release.zig");
const tests = @import("build/tests.zig");
const types = @import("build/types.zig");
const windows = @import("build/windows.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const opts_mod = options.createBuildOptionsModule(b, optimize);

    const ctx: types.BuildCtx = .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .opts_mod = opts_mod,
    };
    const native = artifacts.createNativeArtifacts(ctx);

    artifacts.registerArtifactSteps(ctx, &native);
    tests.registerUnitTestSteps(ctx, &native);
    tests.registerCoverageStep(ctx, &native);
    windows.register(ctx, &native);
    release.register(b, opts_mod);
}
