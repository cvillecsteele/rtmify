const std = @import("std");

pub fn addSqlite(compile: *std.Build.Step.Compile, b: *std.Build) void {
    const sqlite_flags = &.{
        "-DSQLITE_THREADSAFE=2",
        "-DSQLITE_OMIT_LOAD_EXTENSION=1",
    };

    compile.addCSourceFile(.{ .file = b.path("lib/vendor/sqlite3.c"), .flags = sqlite_flags });
    compile.addIncludePath(b.path("lib/vendor"));
    compile.linkLibC();
}

pub fn findExistingPath(paths: []const []const u8) ?[]const u8 {
    for (paths) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return path;
    }
    return null;
}

pub fn macSdkRoot(b: *std.Build) ?[]const u8 {
    if (b.graph.env_map.get("SDKROOT")) |sdkroot| return sdkroot;
    return findExistingPath(&.{
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    });
}

pub fn addLiveSecurityDeps(compile: *std.Build.Step.Compile, b: *std.Build) void {
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

pub fn addKcovRun(
    b: *std.Build,
    kcov_path: []const u8,
    report_dir: []const u8,
    include_path: []const u8,
    artifact: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", report_dir });
    const cmd = b.addSystemCommand(&.{
        kcov_path,
        "--clean",
        b.fmt("--include-path={s}", .{include_path}),
        report_dir,
    });
    cmd.step.dependOn(&mkdir.step);
    cmd.addArtifactArg(artifact);
    return cmd;
}
