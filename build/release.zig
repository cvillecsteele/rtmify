const std = @import("std");

const support = @import("support.zig");

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

pub fn register(b: *std.Build, opts_mod: *std.Build.Module) void {
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
        support.addSqlite(live_release_exe, b);
        support.addLiveSecurityDeps(live_release_exe, b);

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
