const std = @import("std");

const support = @import("support.zig");
const types = @import("types.zig");

pub fn register(ctx: types.BuildCtx, native: *const types.NativeArtifacts) void {
    const b = ctx.b;

    const win_gui_exe = b.addExecutable(.{
        .name = "rtmify-trace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("trace/windows/src/main.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    win_gui_exe.linkLibrary(native.static_lib);
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
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    win_gui_live_exe.linkLibrary(native.static_lib);
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
                        .{ .name = "build_options", .module = ctx.opts_mod },
                    },
                }) },
                .{ .name = "build_options", .module = ctx.opts_mod },
            },
        }),
    });
    support.addSqlite(check_live_windows_server, b);

    const check_live_windows_shell = b.addExecutable(.{
        .name = "rtmify-live-shell-check-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("live/windows/src/main.zig"),
            .target = windows_check_target,
            .optimize = .ReleaseSafe,
        }),
    });
    check_live_windows_shell.linkLibrary(native.static_lib);
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
}
