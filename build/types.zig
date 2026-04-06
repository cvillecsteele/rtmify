const std = @import("std");

pub const BuildCtx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts_mod: *std.Build.Module,
};

pub const NativeArtifacts = struct {
    rtmify_mod: *std.Build.Module,
    cadcruncher_mod: *std.Build.Module,
    llm_mod: *std.Build.Module,
    traveler_mod: *std.Build.Module,
    trace_exe: *std.Build.Step.Compile,
    live_exe: *std.Build.Step.Compile,
    cadinspect_exe: *std.Build.Step.Compile,
    cadcruncher_lib: *std.Build.Step.Compile,
    llm_lib: *std.Build.Step.Compile,
    traveler_lib: *std.Build.Step.Compile,
    traveler_exe: *std.Build.Step.Compile,
    shared_lib: *std.Build.Step.Compile,
    static_lib: *std.Build.Step.Compile,
    license_gen_exe: *std.Build.Step.Compile,
};
