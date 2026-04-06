const std = @import("std");

const include_paths = [_][]const u8{
    "libllm/vendor_shims",
    "libllm/vendor/llama.cpp/include",
    "libllm/vendor/llama.cpp/ggml/include",
    "libllm/vendor/llama.cpp/ggml/src",
    "libllm/vendor/llama.cpp/ggml/src/ggml-metal",
    "libllm/vendor/llama.cpp/ggml/src/ggml-cpu",
    "libllm/vendor/llama.cpp/src",
    "libllm/vendor/llama.cpp/tools/mtmd",
    "libllm/vendor/llama.cpp/tools/mtmd/models",
    "libllm/vendor/llama.cpp/src/models",
    "libllm/vendor/llama.cpp/vendor",
    "libllm/vendor/llama.cpp/vendor/stb",
    "libllm/vendor/llama.cpp/vendor/miniaudio",
};

const ggml_c_files = [_][]const u8{
    "ggml.c",
    "ggml-alloc.c",
    "ggml-quants.c",
};

const ggml_cpp_files = [_][]const u8{
    "ggml.cpp",
    "ggml-backend.cpp",
    "ggml-backend-dl.cpp",
    "ggml-backend-reg.cpp",
    "ggml-opt.cpp",
    "ggml-threading.cpp",
    "gguf.cpp",
};

const ggml_metal_cpp_files = [_][]const u8{
    "ggml-metal.cpp",
    "ggml-metal-device.cpp",
    "ggml-metal-common.cpp",
    "ggml-metal-ops.cpp",
};

const ggml_metal_objc_files = [_][]const u8{
    "ggml-metal-device.m",
    "ggml-metal-context.m",
};

const ggml_cpu_c_files = [_][]const u8{
    "ggml-cpu.c",
    "quants.c",
};

const ggml_cpu_cpp_files = [_][]const u8{
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
};

const ggml_cpu_arm_c_files = [_][]const u8{
    "quants.c",
};

const ggml_cpu_arm_cpp_files = [_][]const u8{
    "repack.cpp",
};

const ggml_cpu_x86_c_files = [_][]const u8{
    "quants.c",
};

const ggml_cpu_x86_cpp_files = [_][]const u8{
    "repack.cpp",
};

const llama_src_cpp_files = [_][]const u8{
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
};

const llama_model_cpp_files = [_][]const u8{
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
};

const mtmd_cpp_files = [_][]const u8{
    "mtmd.cpp",
    "mtmd-audio.cpp",
    "mtmd-image.cpp",
    "clip.cpp",
    "mtmd-helper.cpp",
};

const mtmd_model_cpp_files = [_][]const u8{
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
};

const vendor_shim_cpp_files = [_][]const u8{
    "llama_mtmd_bridge.cpp",
};

pub fn addLlamaCppModuleIncludes(module: *std.Build.Module, b: *std.Build) void {
    for (include_paths) |include_path| {
        module.addIncludePath(b.path(include_path));
    }
}

pub fn addLlamaCpp(compile: *std.Build.Step.Compile, b: *std.Build) void {
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
        .files = &ggml_c_files,
        .flags = c_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/ggml/src"),
        .files = &ggml_cpp_files,
        .flags = cpp_flags,
    });
    if (use_metal) {
        compile.addCSourceFiles(.{
            .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-metal"),
            .files = &ggml_metal_cpp_files,
            .flags = cpp_flags,
        });
        compile.addCSourceFiles(.{
            .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-metal"),
            .files = &ggml_metal_objc_files,
            .flags = c_flags,
        });
    }
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu"),
        .files = &ggml_cpu_c_files,
        .flags = c_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu"),
        .files = &ggml_cpu_cpp_files,
        .flags = cpp_flags,
    });

    switch (target.cpu.arch) {
        .aarch64 => {
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/arm"),
                .files = &ggml_cpu_arm_c_files,
                .flags = c_flags,
            });
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/arm"),
                .files = &ggml_cpu_arm_cpp_files,
                .flags = cpp_flags,
            });
        },
        .x86_64 => {
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/x86"),
                .files = &ggml_cpu_x86_c_files,
                .flags = c_flags,
            });
            compile.addCSourceFiles(.{
                .root = b.path("libllm/vendor/llama.cpp/ggml/src/ggml-cpu/arch/x86"),
                .files = &ggml_cpu_x86_cpp_files,
                .flags = cpp_flags,
            });
        },
        else => {},
    }

    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/src"),
        .files = &llama_src_cpp_files,
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/src/models"),
        .files = &llama_model_cpp_files,
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/tools/mtmd"),
        .files = &mtmd_cpp_files,
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor/llama.cpp/tools/mtmd/models"),
        .files = &mtmd_model_cpp_files,
        .flags = cpp_flags,
    });
    compile.addCSourceFiles(.{
        .root = b.path("libllm/vendor_shims"),
        .files = &vendor_shim_cpp_files,
        .flags = cpp_flags,
    });
}

pub fn addLlamaCppRuntimeResources(step: *std.Build.Step, b: *std.Build) void {
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
