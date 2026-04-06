const std = @import("std");

const llama = @import("llama.zig");
const support = @import("support.zig");
const types = @import("types.zig");

pub fn createNativeArtifacts(ctx: types.BuildCtx) types.NativeArtifacts {
    const b = ctx.b;

    const native_rtmify_mod = b.createModule(.{
        .root_source_file = b.path("lib/src/lib.zig"),
        .target = ctx.target,
        .imports = &.{
            .{ .name = "build_options", .module = ctx.opts_mod },
        },
    });
    const native_cadcruncher_mod = b.createModule(.{
        .root_source_file = b.path("libcadcruncher/src/lib.zig"),
        .target = ctx.target,
    });
    const native_llm_mod = b.createModule(.{
        .root_source_file = b.path("libllm/src/lib.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    llama.addLlamaCppModuleIncludes(native_llm_mod, b);
    const native_traveler_mod = b.createModule(.{
        .root_source_file = b.path("libtraveler/src/lib.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{
            .{ .name = "llm", .module = native_llm_mod },
        },
    });

    const trace_exe = b.addExecutable(.{
        .name = "rtmify-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/src/main.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });

    const live_exe = b.addExecutable(.{
        .name = "rtmify-live",
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/src/main_live.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });
    support.addSqlite(live_exe, b);
    support.addLiveSecurityDeps(live_exe, b);

    const cadinspect_exe = b.addExecutable(.{
        .name = "rtmify-cadinspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("libcadcruncher/src/inspector_cli.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "cadcruncher", .module = native_cadcruncher_mod },
            },
        }),
    });

    const cadcruncher_lib = b.addLibrary(.{
        .name = "cadcruncher",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("libcadcruncher/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });

    const llm_lib = b.addLibrary(.{
        .name = "llm",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("libllm/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    llama.addLlamaCpp(llm_lib, b);

    const traveler_lib = b.addLibrary(.{
        .name = "traveler",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("libtraveler/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "llm", .module = native_llm_mod },
            },
        }),
    });
    llama.addLlamaCppModuleIncludes(traveler_lib.root_module, b);

    const traveler_exe = b.addExecutable(.{
        .name = "traveler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("traveler/src/main.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "traveler", .module = native_traveler_mod },
                .{ .name = "llm", .module = native_llm_mod },
            },
        }),
    });
    llama.addLlamaCpp(traveler_exe, b);

    const shared_lib = b.addLibrary(.{
        .name = "rtmify",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });

    const static_lib = b.addLibrary(.{
        .name = "rtmify",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });
    static_lib.bundle_compiler_rt = true;

    const license_gen_exe = b.addExecutable(.{
        .name = "rtmify-license-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/license_gen.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });

    return .{
        .rtmify_mod = native_rtmify_mod,
        .cadcruncher_mod = native_cadcruncher_mod,
        .llm_mod = native_llm_mod,
        .traveler_mod = native_traveler_mod,
        .trace_exe = trace_exe,
        .live_exe = live_exe,
        .cadinspect_exe = cadinspect_exe,
        .cadcruncher_lib = cadcruncher_lib,
        .llm_lib = llm_lib,
        .traveler_lib = traveler_lib,
        .traveler_exe = traveler_exe,
        .shared_lib = shared_lib,
        .static_lib = static_lib,
        .license_gen_exe = license_gen_exe,
    };
}

pub fn registerArtifactSteps(ctx: types.BuildCtx, native: *const types.NativeArtifacts) void {
    const b = ctx.b;

    const install_trace = b.addInstallArtifact(native.trace_exe, .{});
    const install_live = b.addInstallArtifact(native.live_exe, .{});
    const install_cadinspect = b.addInstallArtifact(native.cadinspect_exe, .{});
    const install_cadcruncher_lib = b.addInstallArtifact(native.cadcruncher_lib, .{});
    const install_llm_lib = b.addInstallArtifact(native.llm_lib, .{});
    const install_traveler_lib = b.addInstallArtifact(native.traveler_lib, .{});
    const install_traveler = b.addInstallArtifact(native.traveler_exe, .{});
    const install_shared_lib = b.addInstallArtifact(native.shared_lib, .{});
    const install_static_lib = b.addInstallArtifact(native.static_lib, .{});
    const install_license_gen = b.addInstallArtifact(native.license_gen_exe, .{});

    b.getInstallStep().dependOn(&install_trace.step);
    b.getInstallStep().dependOn(&install_live.step);
    b.getInstallStep().dependOn(&install_cadinspect.step);
    b.getInstallStep().dependOn(&install_cadcruncher_lib.step);
    b.getInstallStep().dependOn(&install_llm_lib.step);
    b.getInstallStep().dependOn(&install_traveler_lib.step);
    b.getInstallStep().dependOn(&install_traveler.step);
    b.getInstallStep().dependOn(&install_shared_lib.step);
    b.getInstallStep().dependOn(&install_static_lib.step);
    b.getInstallStep().dependOn(&install_license_gen.step);

    const trace_step = b.step("trace", "Build rtmify-trace");
    trace_step.dependOn(&install_trace.step);

    const live_step = b.step("live", "Build rtmify-live");
    live_step.dependOn(&install_live.step);

    const cadcruncher_step = b.step("cadcruncher", "Build rtmify-cadinspect and libcadcruncher module");
    cadcruncher_step.dependOn(&install_cadinspect.step);
    cadcruncher_step.dependOn(&install_cadcruncher_lib.step);

    const lib_step = b.step("lib", "Build librtmify static and shared libraries");
    lib_step.dependOn(&install_shared_lib.step);
    lib_step.dependOn(&install_static_lib.step);

    const license_gen_step = b.step("license-gen", "Build rtmify-license-gen");
    license_gen_step.dependOn(&install_license_gen.step);

    const llm_step = b.step("llm", "Build libllm static library");
    llm_step.dependOn(&install_llm_lib.step);

    const traveler_lib_step = b.step("traveler-lib", "Build libtraveler static library");
    traveler_lib_step.dependOn(&install_traveler_lib.step);

    const traveler_step = b.step("traveler", "Build traveler CLI");
    traveler_step.dependOn(&install_traveler.step);
    if (ctx.target.result.os.tag == .macos) {
        llama.addLlamaCppRuntimeResources(&install_traveler.step, b);
        llama.addLlamaCppRuntimeResources(b.getInstallStep(), b);
    }

    const run_trace_cmd = b.addRunArtifact(native.trace_exe);
    if (b.args) |args| run_trace_cmd.addArgs(args);
    const run_trace_step = b.step("run-trace", "Run rtmify-trace");
    run_trace_step.dependOn(&run_trace_cmd.step);

    const run_live_cmd = b.addRunArtifact(native.live_exe);
    if (b.args) |args| run_live_cmd.addArgs(args);
    const run_live_step = b.step("run-live", "Run rtmify-live");
    run_live_step.dependOn(&run_live_cmd.step);

    const run_cadinspect_cmd = b.addRunArtifact(native.cadinspect_exe);
    if (b.args) |args| run_cadinspect_cmd.addArgs(args);
    const run_cadinspect_step = b.step("run-cadcruncher", "Run rtmify-cadinspect");
    run_cadinspect_step.dependOn(&run_cadinspect_cmd.step);
}
