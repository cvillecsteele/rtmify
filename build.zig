const std = @import("std");

const ReleaseTarget = struct {
    triple: []const u8,
    trace_name: []const u8,
    live_name: []const u8,
    lib_suffix: []const u8,
};

const release_targets = [_]ReleaseTarget{
    .{
        .triple = "aarch64-macos",
        .trace_name = "rtmify-trace-macos-arm64",
        .live_name = "rtmify-live-macos-arm64",
        .lib_suffix = "macos-arm64",
    },
    .{
        .triple = "x86_64-macos",
        .trace_name = "rtmify-trace-macos-x64",
        .live_name = "rtmify-live-macos-x64",
        .lib_suffix = "macos-x64",
    },
    .{
        .triple = "x86_64-windows",
        .trace_name = "rtmify-trace-windows-x64",
        .live_name = "rtmify-live-windows-x64",
        .lib_suffix = "windows-x64",
    },
    .{
        .triple = "aarch64-windows",
        .trace_name = "rtmify-trace-windows-arm64",
        .live_name = "rtmify-live-windows-arm64",
        .lib_suffix = "windows-arm64",
    },
    .{
        .triple = "x86_64-linux-musl",
        .trace_name = "rtmify-trace-linux-x64",
        .live_name = "rtmify-live-linux-x64",
        .lib_suffix = "linux-x64",
    },
    .{
        .triple = "aarch64-linux-musl",
        .trace_name = "rtmify-trace-linux-arm64",
        .live_name = "rtmify-live-linux-arm64",
        .lib_suffix = "linux-arm64",
    },
};

fn addSqlite(compile: *std.Build.Step.Compile, b: *std.Build) void {
    const sqlite_flags = &.{
        "-DSQLITE_THREADSAFE=2",
        "-DSQLITE_OMIT_LOAD_EXTENSION=1",
    };

    compile.addCSourceFile(.{ .file = b.path("lib/vendor/sqlite3.c"), .flags = sqlite_flags });
    compile.addIncludePath(b.path("lib/vendor"));
    compile.linkLibC();
}

fn findExistingPath(paths: []const []const u8) ?[]const u8 {
    for (paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return path;
    }
    return null;
}

fn macSdkRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.env_map.get("SDKROOT")) |sdkroot| return sdkroot;
    return findExistingPath(&.{
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    });
}

fn addLiveSecurityDeps(compile: *std.Build.Step.Compile, b: *std.Build) void {
    if (compile.rootModuleTarget().os.tag != .macos) return;

    if (macSdkRoot(b)) |sdkroot| {
        const framework_dir = b.pathJoin(&.{ sdkroot, "System/Library/Frameworks" });
        const include_dir = b.pathJoin(&.{ sdkroot, "usr/include" });
        const lib_dir = b.pathJoin(&.{ sdkroot, "usr/lib" });
        compile.addSystemFrameworkPath(.{ .cwd_relative = framework_dir });
        compile.addSystemIncludePath(.{ .cwd_relative = include_dir });
        compile.addLibraryPath(.{ .cwd_relative = lib_dir });
    }

    compile.linkFramework("Security");
    compile.linkFramework("CoreFoundation");
}

fn trimAsciiWhitespace(bytes: []u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn loadLicenseHmacKeyHex(b: *std.Build, optimize: std.builtin.OptimizeMode) []const u8 {
    const key_file_opt = b.option([]const u8, "license-hmac-key-file", "Path to a 64-hex-char HMAC key file for signed RTMify licenses");
    const key_file_env = b.graph.env_map.get("RTMIFY_LICENSE_HMAC_KEY_FILE");
    const key_file = key_file_opt orelse key_file_env;
    if (key_file) |path| {
        const bytes = std.fs.cwd().readFileAlloc(b.allocator, path, 1024) catch @panic("failed to read license HMAC key file");
        const trimmed = trimAsciiWhitespace(bytes);
        if (trimmed.len != 64) @panic("license HMAC key file must contain exactly 64 lowercase hex chars");
        return b.dupe(trimmed);
    }
    if (optimize != .Debug) {
        @panic("release builds require -Dlicense-hmac-key-file or RTMIFY_LICENSE_HMAC_KEY_FILE");
    }
    return "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
}

pub fn build(b: *std.Build) void {
    const version = "20260308-a";
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    const license_hmac_key_hex = loadLicenseHmacKeyHex(b, optimize);
    opts.addOption([]const u8, "license_hmac_key_hex", license_hmac_key_hex);
    const opts_mod = opts.createModule();

    const native_rtmify_mod = b.createModule(.{
        .root_source_file = b.path("lib/src/lib.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = opts_mod },
        },
    });
    const native_cadcruncher_mod = b.createModule(.{
        .root_source_file = b.path("libcadcruncher/src/lib.zig"),
        .target = target,
    });

    const trace_exe = b.addExecutable(.{
        .name = "rtmify-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });

    const live_exe = b.addExecutable(.{
        .name = "rtmify-live",
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/src/main_live.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    addSqlite(live_exe, b);
    addLiveSecurityDeps(live_exe, b);

    const cadinspect_exe = b.addExecutable(.{
        .name = "rtmify-cadinspect",
        .root_module = b.createModule(.{
            .root_source_file = b.path("libcadcruncher/src/inspector_cli.zig"),
            .target = target,
            .optimize = optimize,
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
            .target = target,
            .optimize = optimize,
        }),
    });

    const shared_lib = b.addLibrary(.{
        .name = "rtmify",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });

    const static_lib = b.addLibrary(.{
        .name = "rtmify",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    static_lib.bundle_compiler_rt = true;

    const license_gen_exe = b.addExecutable(.{
        .name = "rtmify-license-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/license_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });

    const install_trace = b.addInstallArtifact(trace_exe, .{});
    const install_live = b.addInstallArtifact(live_exe, .{});
    const install_cadinspect = b.addInstallArtifact(cadinspect_exe, .{});
    const install_cadcruncher_lib = b.addInstallArtifact(cadcruncher_lib, .{});
    const install_shared_lib = b.addInstallArtifact(shared_lib, .{});
    const install_static_lib = b.addInstallArtifact(static_lib, .{});
    const install_license_gen = b.addInstallArtifact(license_gen_exe, .{});

    b.getInstallStep().dependOn(&install_trace.step);
    b.getInstallStep().dependOn(&install_live.step);
    b.getInstallStep().dependOn(&install_cadinspect.step);
    b.getInstallStep().dependOn(&install_cadcruncher_lib.step);
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

    const run_trace_cmd = b.addRunArtifact(trace_exe);
    if (b.args) |args| run_trace_cmd.addArgs(args);
    const run_trace_step = b.step("run-trace", "Run rtmify-trace");
    run_trace_step.dependOn(&run_trace_cmd.step);

    const run_live_cmd = b.addRunArtifact(live_exe);
    if (b.args) |args| run_live_cmd.addArgs(args);
    const run_live_step = b.step("run-live", "Run rtmify-live");
    run_live_step.dependOn(&run_live_cmd.step);

    const run_cadinspect_cmd = b.addRunArtifact(cadinspect_exe);
    if (b.args) |args| run_cadinspect_cmd.addArgs(args);
    const run_cadinspect_step = b.step("run-cadcruncher", "Run rtmify-cadinspect");
    run_cadinspect_step.dependOn(&run_cadinspect_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const trace_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    const run_trace_tests = b.addRunArtifact(trace_tests);

    const windows_trace_state_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/windows/src/state.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_windows_trace_state_tests = b.addRunArtifact(windows_trace_state_tests);

    const live_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/src/lib_live.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rtmify", .module = native_rtmify_mod },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    addSqlite(live_tests, b);
    addLiveSecurityDeps(live_tests, b);
    const run_live_tests = b.addRunArtifact(live_tests);

    const cadcruncher_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libcadcruncher/src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cadcruncher_tests = b.addRunArtifact(cadcruncher_tests);

    const windows_lifecycle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/lifecycle.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_windows_lifecycle_tests = b.addRunArtifact(windows_lifecycle_tests);

    const windows_process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/process.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_windows_process_tests = b.addRunArtifact(windows_process_tests);

    const windows_status_probe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/status_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_windows_status_probe_tests = b.addRunArtifact(windows_status_probe_tests);

    const windows_license_gate_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/license_gate.zig"),
            .target = target,
            .optimize = optimize,
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

    const win_gui_exe = b.addExecutable(.{
        .name = "rtmify-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/windows/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    win_gui_exe.linkLibrary(static_lib);
    win_gui_exe.subsystem = .Windows;
    win_gui_exe.linkSystemLibrary("ws2_32");
    win_gui_exe.linkSystemLibrary("crypt32");
    win_gui_exe.linkSystemLibrary("advapi32");
    win_gui_exe.addWin32ResourceFile(.{ .file = b.path("trace/windows/res/rtmify.rc") });

    const install_win_gui = b.addInstallArtifact(win_gui_exe, .{});
    const win_gui_step = b.step("win-gui", "Build rtmify-trace.exe (use -Dtarget=x86_64-windows)");
    win_gui_step.dependOn(&install_win_gui.step);

    const win_gui_live_exe = b.addExecutable(.{
        .name = "RTMify Live",
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    win_gui_live_exe.linkLibrary(static_lib);
    win_gui_live_exe.subsystem = .Windows;
    win_gui_live_exe.linkSystemLibrary("user32");
    win_gui_live_exe.linkSystemLibrary("shell32");
    win_gui_live_exe.linkSystemLibrary("advapi32");
    win_gui_live_exe.linkSystemLibrary("ws2_32");
    win_gui_live_exe.linkSystemLibrary("crypt32");
    win_gui_live_exe.addWin32ResourceFile(.{ .file = b.path("live/windows/res/rtmify_live.rc") });

    const install_win_gui_live = b.addInstallArtifact(win_gui_live_exe, .{});
    const win_gui_live_step = b.step("win-gui-live", "Build RTMify Live.exe (use -Dtarget=x86_64-windows)");
    win_gui_live_step.dependOn(&install_win_gui_live.step);

    const windows_check_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = "x86_64-windows" }) catch
        @panic("invalid windows check target triple"));
    const check_live_windows_server = b.addExecutable(.{
        .name = "rtmify-live-check-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/src/main_live.zig"),
            .target = windows_check_target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "rtmify", .module = b.createModule(.{
                    .root_source_file = b.path("lib/src/lib.zig"),
                    .target = windows_check_target,
                    .imports = &.{
                        .{ .name = "build_options", .module = opts_mod },
                    },
                }) },
                .{ .name = "build_options", .module = opts_mod },
            },
        }),
    });
    addSqlite(check_live_windows_server, b);

    const check_live_windows_shell = b.addExecutable(.{
        .name = "rtmify-live-shell-check-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/main.zig"),
            .target = windows_check_target,
            .optimize = .ReleaseSafe,
        }),
    });
    check_live_windows_shell.linkLibrary(static_lib);
    check_live_windows_shell.subsystem = .Windows;
    check_live_windows_shell.linkSystemLibrary("user32");
    check_live_windows_shell.linkSystemLibrary("shell32");
    check_live_windows_shell.linkSystemLibrary("advapi32");
    check_live_windows_shell.linkSystemLibrary("ws2_32");
    check_live_windows_shell.linkSystemLibrary("crypt32");
    check_live_windows_shell.addWin32ResourceFile(.{ .file = b.path("live/windows/res/rtmify_live.rc") });

    const check_live_windows_step = b.step("check-live-windows", "Compile Windows live binaries without executing them");
    check_live_windows_step.dependOn(&check_live_windows_server.step);
    check_live_windows_step.dependOn(&check_live_windows_shell.step);

    const release_step = b.step("release", "Build trace, live, and static librtmify for all release targets");

    for (release_targets) |rt| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = rt.triple }) catch
            @panic("invalid release target triple");
        const cross_target = b.resolveTargetQuery(query);

        const cross_rtmify_mod = b.createModule(.{
            .root_source_file = b.path("lib/src/lib.zig"),
            .target = cross_target,
            .imports = &.{
                .{ .name = "build_options", .module = opts_mod },
            },
        });

        const trace_release_exe = b.addExecutable(.{
            .name = rt.trace_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("trace/src/main.zig"),
                .target = cross_target,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "rtmify", .module = cross_rtmify_mod },
                    .{ .name = "build_options", .module = opts_mod },
                },
            }),
        });

        const install_trace_release = b.addInstallArtifact(trace_release_exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        });
        release_step.dependOn(&install_trace_release.step);

        const live_release_exe = b.addExecutable(.{
            .name = rt.live_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("live/src/main_live.zig"),
                .target = cross_target,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "rtmify", .module = cross_rtmify_mod },
                    .{ .name = "build_options", .module = opts_mod },
                },
            }),
        });
        addSqlite(live_release_exe, b);
        addLiveSecurityDeps(live_release_exe, b);

        const install_live_release = b.addInstallArtifact(live_release_exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        });
        release_step.dependOn(&install_live_release.step);

        const static_release_lib = b.addLibrary(.{
            .name = b.fmt("rtmify-{s}", .{rt.lib_suffix}),
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("lib/src/lib.zig"),
                .target = cross_target,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "build_options", .module = opts_mod },
                },
            }),
        });
        static_release_lib.bundle_compiler_rt = true;

        const install_release_lib = b.addInstallArtifact(static_release_lib, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
        });
        release_step.dependOn(&install_release_lib.step);
    }
}
