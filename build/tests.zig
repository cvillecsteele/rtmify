const std = @import("std");

const llama = @import("llama.zig");
const support = @import("support.zig");
const types = @import("types.zig");

pub fn registerUnitTestSteps(ctx: types.BuildCtx, native: *const types.NativeArtifacts) void {
    const b = ctx.b;

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const trace_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/src/main.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native.rtmify_mod },
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });
    const run_trace_tests = b.addRunArtifact(trace_tests);

    const windows_trace_state_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/windows/src/state.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const run_windows_trace_state_tests = b.addRunArtifact(windows_trace_state_tests);

    const live_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/src/lib_live.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native.rtmify_mod },
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });
    support.addSqlite(live_tests, b);
    support.addLiveSecurityDeps(live_tests, b);
    const run_live_tests = b.addRunArtifact(live_tests);

    const cadcruncher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libcadcruncher/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const run_cadcruncher_tests = b.addRunArtifact(cadcruncher_tests);

    const reqif_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libreqif/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const run_reqif_tests = b.addRunArtifact(reqif_tests);

    const llm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libllm/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    llama.addLlamaCpp(llm_tests, b);
    const run_llm_tests = b.addRunArtifact(llm_tests);

    const traveler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libtraveler/src/lib.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .imports = &.{
                .{ .name = "llm", .module = native.llm_mod },
            },
        }),
    });
    llama.addLlamaCpp(traveler_tests, b);
    const run_traveler_tests = b.addRunArtifact(traveler_tests);

    const windows_lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/lifecycle.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const run_windows_lifecycle_tests = b.addRunArtifact(windows_lifecycle_tests);

    const windows_process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/process.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const run_windows_process_tests = b.addRunArtifact(windows_process_tests);

    const windows_status_probe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/status_probe.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const run_windows_status_probe_tests = b.addRunArtifact(windows_status_probe_tests);

    const windows_license_gate_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/license_gate.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const run_windows_license_gate_tests = b.addRunArtifact(windows_license_gate_tests);

    const test_lib_step = b.step("test-lib", "Run librtmify unit tests");
    test_lib_step.dependOn(&run_lib_tests.step);

    const test_trace_step = b.step("test-trace", "Run trace CLI unit tests");
    test_trace_step.dependOn(&run_trace_tests.step);
    test_trace_step.dependOn(&run_windows_trace_state_tests.step);

    const test_live_step = b.step("test-live", "Run live module unit tests");
    test_live_step.dependOn(&run_live_tests.step);
    test_live_step.dependOn(&run_windows_lifecycle_tests.step);
    test_live_step.dependOn(&run_windows_process_tests.step);
    test_live_step.dependOn(&run_windows_status_probe_tests.step);
    test_live_step.dependOn(&run_windows_license_gate_tests.step);

    const test_cadcruncher_step = b.step("test-cadcruncher", "Run libcadcruncher unit tests");
    test_cadcruncher_step.dependOn(&run_cadcruncher_tests.step);

    const test_reqif_step = b.step("test-reqif", "Run libreqif unit tests");
    test_reqif_step.dependOn(&run_reqif_tests.step);

    const test_traveler_step = b.step("test-traveler", "Run traveler and llm unit tests");
    test_traveler_step.dependOn(&run_llm_tests.step);
    test_traveler_step.dependOn(&run_traveler_tests.step);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_trace_tests.step);
    test_step.dependOn(&run_windows_trace_state_tests.step);
    test_step.dependOn(&run_live_tests.step);
    test_step.dependOn(&run_windows_lifecycle_tests.step);
    test_step.dependOn(&run_windows_process_tests.step);
    test_step.dependOn(&run_windows_status_probe_tests.step);
    test_step.dependOn(&run_windows_license_gate_tests.step);
    test_step.dependOn(&run_cadcruncher_tests.step);
    test_step.dependOn(&run_reqif_tests.step);
    test_step.dependOn(&run_llm_tests.step);
    test_step.dependOn(&run_traveler_tests.step);
}

pub fn registerCoverageStep(ctx: types.BuildCtx, native: *const types.NativeArtifacts) void {
    const b = ctx.b;
    const coverage_step = b.step("coverage", "Run native unit tests under kcov and emit coverage reports");

    if (!ctx.target.query.isNative()) {
        const fail = b.addFail("coverage is only supported for native targets");
        coverage_step.dependOn(&fail.step);
        return;
    }

    const kcov_path = b.findProgram(&.{"kcov"}, &.{}) catch null;
    if (kcov_path) |kcov| {
        const coverage_optimize: std.builtin.OptimizeMode = .Debug;

        const lib_coverage_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("lib/src/lib.zig"),
                .target = ctx.target,
                .optimize = coverage_optimize,
                .imports = &.{
                    .{ .name = "build_options", .module = ctx.opts_mod },
                },
            }),
        });

        const trace_coverage_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("trace/src/main.zig"),
                .target = ctx.target,
                .optimize = coverage_optimize,
                .imports = &.{
                    .{ .name = "rtmify", .module = native.rtmify_mod },
                    .{ .name = "build_options", .module = ctx.opts_mod },
                },
            }),
        });

        const live_coverage_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("live/src/lib_live.zig"),
                .target = ctx.target,
                .optimize = coverage_optimize,
                .imports = &.{
                    .{ .name = "rtmify", .module = native.rtmify_mod },
                    .{ .name = "build_options", .module = ctx.opts_mod },
                },
            }),
        });
        support.addSqlite(live_coverage_tests, b);
        support.addLiveSecurityDeps(live_coverage_tests, b);

        const cadcruncher_coverage_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("libcadcruncher/src/lib.zig"),
                .target = ctx.target,
                .optimize = coverage_optimize,
            }),
        });

        const reqif_coverage_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("libreqif/src/lib.zig"),
                .target = ctx.target,
                .optimize = coverage_optimize,
            }),
        });

        const llm_coverage_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("libllm/src/lib.zig"),
                .target = ctx.target,
                .optimize = coverage_optimize,
            }),
        });
        llama.addLlamaCpp(llm_coverage_tests, b);

        const traveler_coverage_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("libtraveler/src/lib.zig"),
                .target = ctx.target,
                .optimize = coverage_optimize,
                .imports = &.{
                    .{ .name = "llm", .module = native.llm_mod },
                },
            }),
        });
        llama.addLlamaCpp(traveler_coverage_tests, b);

        const lib_kcov = support.addKcovRun(
            b,
            kcov,
            b.pathJoin(&.{ "zig-out", "coverage", "lib" }),
            "lib/src",
            lib_coverage_tests,
        );
        coverage_step.dependOn(&lib_kcov.step);

        const trace_kcov = support.addKcovRun(
            b,
            kcov,
            b.pathJoin(&.{ "zig-out", "coverage", "trace" }),
            "trace/src,lib/src",
            trace_coverage_tests,
        );
        coverage_step.dependOn(&trace_kcov.step);

        const live_kcov = support.addKcovRun(
            b,
            kcov,
            b.pathJoin(&.{ "zig-out", "coverage", "live" }),
            "live/src,lib/src",
            live_coverage_tests,
        );
        coverage_step.dependOn(&live_kcov.step);

        const cadcruncher_kcov = support.addKcovRun(
            b,
            kcov,
            b.pathJoin(&.{ "zig-out", "coverage", "cadcruncher" }),
            "libcadcruncher/src",
            cadcruncher_coverage_tests,
        );
        coverage_step.dependOn(&cadcruncher_kcov.step);

        const reqif_kcov = support.addKcovRun(
            b,
            kcov,
            b.pathJoin(&.{ "zig-out", "coverage", "reqif" }),
            "libreqif/src",
            reqif_coverage_tests,
        );
        coverage_step.dependOn(&reqif_kcov.step);

        const llm_kcov = support.addKcovRun(
            b,
            kcov,
            b.pathJoin(&.{ "zig-out", "coverage", "llm" }),
            "libllm/src",
            llm_coverage_tests,
        );
        coverage_step.dependOn(&llm_kcov.step);

        const traveler_kcov = support.addKcovRun(
            b,
            kcov,
            b.pathJoin(&.{ "zig-out", "coverage", "traveler" }),
            "libtraveler/src,libllm/src",
            traveler_coverage_tests,
        );
        coverage_step.dependOn(&traveler_kcov.step);
    } else {
        const fail = b.addFail("kcov not found in PATH; install kcov to run `zig build coverage`");
        coverage_step.dependOn(&fail.step);
    }
}
