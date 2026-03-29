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

fn addLlamaCppModuleIncludes(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("libllm/vendor_shims"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/include"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/ggml/include"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/ggml/src"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/ggml/src/ggml-metal"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/src"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/tools/mtmd"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/tools/mtmd/models"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/src/models"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/vendor"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/vendor/stb"));
    module.addIncludePath(b.path("libllm/vendor/llama.cpp/vendor/miniaudio"));
}

fn addLlamaCpp(compile: *std.Build.Step.Compile, b: *std.Build) void {
    const target = compile.rootModuleTarget();
    const use_metal = target.os.tag == .macos;
    const c_flags: []const []const u8 = if (use_metal) &.{
        "-std=c11",
        "-DGGML_USE_CPU=1",
        "-DGGML_USE_METAL=1",
        "-DGGML_SCHED_MAX_COPIES=4",
        "-DGGML_VERSION=\"unknown\"",
        "-DGGML_COMMIT=\"unknown\"",
        "-D_XOPEN_SOURCE=600",
        "-D_DARWIN_C_SOURCE",
    } else &.{
        "-std=c11",
        "-DGGML_USE_CPU=1",
        "-DGGML_SCHED_MAX_COPIES=4",
        "-DGGML_VERSION=\"unknown\"",
        "-DGGML_COMMIT=\"unknown\"",
        "-D_XOPEN_SOURCE=600",
        "-D_DARWIN_C_SOURCE",
    };
    const cpp_flags: []const []const u8 = if (use_metal) &.{
        "-std=c++17",
        "-DGGML_USE_CPU=1",
        "-DGGML_USE_METAL=1",
        "-DGGML_SCHED_MAX_COPIES=4",
        "-DGGML_VERSION=\"unknown\"",
        "-DGGML_COMMIT=\"unknown\"",
        "-D_XOPEN_SOURCE=600",
        "-D_DARWIN_C_SOURCE",
        "-Wno-cast-qual",
    } else &.{
        "-std=c++17",
        "-DGGML_USE_CPU=1",
        "-DGGML_SCHED_MAX_COPIES=4",
        "-DGGML_VERSION=\"unknown\"",
        "-DGGML_COMMIT=\"unknown\"",
        "-D_XOPEN_SOURCE=600",
        "-D_DARWIN_C_SOURCE",
        "-Wno-cast-qual",
    };

    addLlamaCppModuleIncludes(compile.root_module, b);
    compile.linkLibC();
    compile.linkLibCpp();
    if (target.os.tag == .linux) {
        compile.linkSystemLibrary("m");
        compile.linkSystemLibrary("dl");
    }
    if (use_metal) {
        compile.linkFramework("Foundation");
        compile.linkFramework("Metal");
        compile.linkFramework("MetalKit");
    }

    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/ggml/src"),
        .files = &.{
            "ggml.c",
            "ggml-alloc.c",
            "ggml-quants.c",
        },
        .flags = c_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/ggml/src"),
        .files = &.{
            "ggml.cpp",
            "ggml-backend.cpp",
            "ggml-backend-dl.cpp",
            "ggml-backend-reg.cpp",
            "ggml-opt.cpp",
            "ggml-threading.cpp",
            "gguf.cpp",
        },
        .flags = cpp_flags,
    });
    if (use_metal) {
        compile.addCSourceFiles(.{
            .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-metal"),
            .files = &.{
                "ggml-metal.cpp",
                "ggml-metal-device.cpp",
                "ggml-metal-common.cpp",
                "ggml-metal-ops.cpp",
            },
            .flags = cpp_flags,
        });
        compile.addCSourceFiles(.{
            .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-metal"),
            .files = &.{
                "ggml-metal-device.m",
                "ggml-metal-context.m",
            },
            .flags = c_flags,
        });
    }
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu"),
        .files = &.{
            "ggml-cpu.c",
            "quants.c",
        },
        .flags = c_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu"),
        .files = &.{
            "ggml-cpu.cpp",
            "repack.cpp",
            "hbm.cpp",
            "traits.cpp",
            "binary-ops.cpp",
            "unary-ops.cpp",
            "vec.cpp",
            "ops.cpp",
            "amx/amx.cpp",
            "amx/mmq.cpp",
        },
        .flags = cpp_flags,
    });

    switch (target.cpu.arch) {
        .aarch64 => {
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/arm"),
                .files = &.{
                    "quants.c",
                },
                .flags = c_flags,
            });
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/arm"),
                .files = &.{
                    "repack.cpp",
                },
                .flags = cpp_flags,
            });
        },
        .x86_64 => {
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/x86"),
                .files = &.{
                    "quants.c",
                },
                .flags = c_flags,
            });
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/x86"),
                .files = &.{
                    "repack.cpp",
                },
                .flags = cpp_flags,
            });
        },
        else => {},
    }

    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/src"),
        .files = &.{
            "llama.cpp",
            "llama-adapter.cpp",
            "llama-arch.cpp",
            "llama-batch.cpp",
            "llama-chat.cpp",
            "llama-context.cpp",
            "llama-cparams.cpp",
            "llama-grammar.cpp",
            "llama-graph.cpp",
            "llama-hparams.cpp",
            "llama-impl.cpp",
            "llama-io.cpp",
            "llama-kv-cache.cpp",
            "llama-kv-cache-iswa.cpp",
            "llama-memory.cpp",
            "llama-memory-hybrid.cpp",
            "llama-memory-hybrid-iswa.cpp",
            "llama-memory-recurrent.cpp",
            "llama-mmap.cpp",
            "llama-model-loader.cpp",
            "llama-model-saver.cpp",
            "llama-model.cpp",
            "llama-quant.cpp",
            "llama-sampler.cpp",
            "llama-vocab.cpp",
            "unicode-data.cpp",
            "unicode.cpp",
        },
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/src/models"),
        .files = &.{
            "afmoe.cpp",
            "apertus.cpp",
            "arcee.cpp",
            "arctic.cpp",
            "arwkv7.cpp",
            "baichuan.cpp",
            "bailingmoe.cpp",
            "bailingmoe2.cpp",
            "bert.cpp",
            "bitnet.cpp",
            "bloom.cpp",
            "chameleon.cpp",
            "chatglm.cpp",
            "codeshell.cpp",
            "cogvlm.cpp",
            "cohere2-iswa.cpp",
            "command-r.cpp",
            "dbrx.cpp",
            "deci.cpp",
            "deepseek.cpp",
            "deepseek2.cpp",
            "delta-net-base.cpp",
            "dots1.cpp",
            "dream.cpp",
            "ernie4-5-moe.cpp",
            "ernie4-5.cpp",
            "eurobert.cpp",
            "exaone-moe.cpp",
            "exaone.cpp",
            "exaone4.cpp",
            "falcon-h1.cpp",
            "falcon.cpp",
            "gemma-embedding.cpp",
            "gemma.cpp",
            "gemma2-iswa.cpp",
            "gemma3.cpp",
            "gemma3n-iswa.cpp",
            "glm4-moe.cpp",
            "glm4.cpp",
            "gpt2.cpp",
            "gptneox.cpp",
            "granite-hybrid.cpp",
            "granite.cpp",
            "grok.cpp",
            "grovemoe.cpp",
            "hunyuan-dense.cpp",
            "hunyuan-moe.cpp",
            "internlm2.cpp",
            "jais.cpp",
            "jais2.cpp",
            "jamba.cpp",
            "kimi-linear.cpp",
            "lfm2.cpp",
            "llada-moe.cpp",
            "llada.cpp",
            "llama-iswa.cpp",
            "llama.cpp",
            "maincoder.cpp",
            "mamba-base.cpp",
            "mamba.cpp",
            "mimo2-iswa.cpp",
            "minicpm3.cpp",
            "minimax-m2.cpp",
            "mistral3.cpp",
            "modern-bert.cpp",
            "mpt.cpp",
            "nemotron-h.cpp",
            "nemotron.cpp",
            "neo-bert.cpp",
            "olmo.cpp",
            "olmo2.cpp",
            "olmoe.cpp",
            "openai-moe-iswa.cpp",
            "openelm.cpp",
            "orion.cpp",
            "paddleocr.cpp",
            "pangu-embedded.cpp",
            "phi2.cpp",
            "phi3.cpp",
            "plamo.cpp",
            "plamo2.cpp",
            "plamo3.cpp",
            "plm.cpp",
            "qwen.cpp",
            "qwen2.cpp",
            "qwen2moe.cpp",
            "qwen2vl.cpp",
            "qwen3.cpp",
            "qwen35.cpp",
            "qwen35moe.cpp",
            "qwen3moe.cpp",
            "qwen3next.cpp",
            "qwen3vl-moe.cpp",
            "qwen3vl.cpp",
            "refact.cpp",
            "rnd1.cpp",
            "rwkv6-base.cpp",
            "rwkv6.cpp",
            "rwkv6qwen2.cpp",
            "rwkv7-base.cpp",
            "rwkv7.cpp",
            "seed-oss.cpp",
            "smallthinker.cpp",
            "smollm3.cpp",
            "stablelm.cpp",
            "starcoder.cpp",
            "starcoder2.cpp",
            "step35-iswa.cpp",
            "t5-dec.cpp",
            "t5-enc.cpp",
            "wavtokenizer-dec.cpp",
            "xverse.cpp",
        },
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/tools/mtmd"),
        .files = &.{
            "mtmd.cpp",
            "mtmd-audio.cpp",
            "mtmd-image.cpp",
            "clip.cpp",
            "mtmd-helper.cpp",
        },
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/tools/mtmd/models"),
        .files = &.{
            "cogvlm.cpp",
            "conformer.cpp",
            "deepseekocr.cpp",
            "glm4v.cpp",
            "internvl.cpp",
            "kimik25.cpp",
            "kimivl.cpp",
            "llama4.cpp",
            "llava.cpp",
            "minicpmv.cpp",
            "mobilenetv5.cpp",
            "nemotron-v2-vl.cpp",
            "paddleocr.cpp",
            "pixtral.cpp",
            "qwen2vl.cpp",
            "qwen3vl.cpp",
            "siglip.cpp",
            "whisper-enc.cpp",
            "youtuvl.cpp",
        },
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor_shims"),
        .files = &.{
            "llama_mtmd_bridge.cpp",
        },
        .flags = cpp_flags,
    });
}

fn addLlamaCppRuntimeResources(step: *std.Build.Step, b: *std.Build) void {
    const install_ggml_common = b.addInstallBinFile(
        b.path("libllm/vendor/llama.cpp/ggml/src/ggml-common.h"),
        "ggml-common.h",
    );
    const install_ggml_metal = b.addInstallBinFile(
        b.path("libllm/vendor/llama.cpp/ggml/src/ggml-metal/ggml-metal.metal"),
        "ggml-metal.metal",
    );
    const install_ggml_metal_impl = b.addInstallBinFile(
        b.path("libllm/vendor/llama.cpp/ggml/src/ggml-metal/ggml-metal-impl.h"),
        "ggml-metal-impl.h",
    );

    step.dependOn(&install_ggml_common.step);
    step.dependOn(&install_ggml_metal.step);
    step.dependOn(&install_ggml_metal_impl.step);
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

fn defaultLicenseHmacKeyPath(b: *std.Build) ?[]const u8 {
    const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
    const home = b.graph.env_map.get(home_var) orelse return null;
    return b.pathJoin(&.{ home, ".rtmify", "secrets", "license-hmac-key.txt" });
}

fn fingerprintHex(b: *std.Build, key_bytes: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key_bytes, &digest, .{});
    return b.dupe(std.fmt.bytesToHex(&digest, .lower)[0..]);
}

fn loadLicenseHmacKeyHex(b: *std.Build, optimize: std.builtin.OptimizeMode) []const u8 {
    const key_file_opt = b.option([]const u8, "license-hmac-key-file", "Path to a 64-hex-char HMAC key file for signed RTMify licenses");
    const key_file_env = b.graph.env_map.get("RTMIFY_LICENSE_HMAC_KEY_FILE");
    const key_file_default = defaultLicenseHmacKeyPath(b);
    const key_file = key_file_opt orelse key_file_env orelse key_file_default;
    if (key_file) |path| {
        const bytes = std.fs.cwd().readFileAlloc(b.allocator, path, 1024) catch @panic("failed to read license HMAC key file");
        const trimmed = trimAsciiWhitespace(bytes);
        if (trimmed.len != 64) @panic("license HMAC key file must contain exactly 64 lowercase hex chars");
        return b.dupe(trimmed);
    }
    if (optimize != .Debug) {
        @panic("release builds require -Dlicense-hmac-key-file, RTMIFY_LICENSE_HMAC_KEY_FILE, or ~/.rtmify/secrets/license-hmac-key.txt");
    }
    return "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
}

pub fn build(b: *std.Build) void {
    const default_version = "20260325-f";
    const version = b.option([]const u8, "release-version", "Release version string") orelse default_version;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    const license_hmac_key_hex = loadLicenseHmacKeyHex(b, optimize);
    opts.addOption([]const u8, "license_hmac_key_hex", license_hmac_key_hex);
    const license_hmac_key_bytes = b.allocator.alloc(u8, 32) catch @panic("out of memory decoding license_hmac_key_hex");
    _ = std.fmt.hexToBytes(license_hmac_key_bytes, license_hmac_key_hex) catch @panic("invalid license_hmac_key_hex");
    const license_hmac_key_fingerprint_hex = fingerprintHex(b, license_hmac_key_bytes);
    opts.addOption([]const u8, "license_hmac_key_fingerprint_hex", license_hmac_key_fingerprint_hex);
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
    const native_llm_mod = b.createModule(.{
        .root_source_file = b.path("libllm/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    addLlamaCppModuleIncludes(native_llm_mod, b);
    const native_traveler_mod = b.createModule(.{
        .root_source_file = b.path("libtraveler/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "llm", .module = native_llm_mod },
        },
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

    const llm_lib = b.addLibrary(.{
        .name = "llm",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("libllm/src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addLlamaCpp(llm_lib, b);

    const traveler_lib = b.addLibrary(.{
        .name = "traveler",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("libtraveler/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "llm", .module = native_llm_mod },
            },
        }),
    });
    addLlamaCppModuleIncludes(traveler_lib.root_module, b);

    const traveler_exe = b.addExecutable(.{
        .name = "traveler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("traveler/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "traveler", .module = native_traveler_mod },
                .{ .name = "llm", .module = native_llm_mod },
            },
        }),
    });
    addLlamaCpp(traveler_exe, b);

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
    const install_llm_lib = b.addInstallArtifact(llm_lib, .{});
    const install_traveler_lib = b.addInstallArtifact(traveler_lib, .{});
    const install_traveler = b.addInstallArtifact(traveler_exe, .{});
    const install_shared_lib = b.addInstallArtifact(shared_lib, .{});
    const install_static_lib = b.addInstallArtifact(static_lib, .{});
    const install_license_gen = b.addInstallArtifact(license_gen_exe, .{});

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
    if (target.result.os.tag == .macos) {
        addLlamaCppRuntimeResources(&install_traveler.step, b);
        addLlamaCppRuntimeResources(b.getInstallStep(), b);
    }

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

    const llm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libllm/src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addLlamaCpp(llm_tests, b);
    const run_llm_tests = b.addRunArtifact(llm_tests);

    const traveler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libtraveler/src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "llm", .module = native_llm_mod },
            },
        }),
    });
    addLlamaCpp(traveler_tests, b);
    const run_traveler_tests = b.addRunArtifact(traveler_tests);

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
    test_step.dependOn(&run_llm_tests.step);
    test_step.dependOn(&run_traveler_tests.step);

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
