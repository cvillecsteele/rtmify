const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const provider_mod = @import("provider.zig");
const types = @import("types.zig");

const c = @cImport({
    @cInclude("llama_mtmd_bridge.h");
});

pub const ProviderContext = struct {
    session: *c.rtm_llm_session,
};

pub fn init(alloc: std.mem.Allocator, config: types.ModelConfig) !provider_mod.Provider {
    try validateConfig(config);

    const threads = effectiveThreadCount(config.threads);
    const model_path_z = try alloc.dupeZ(u8, config.model_path);
    defer alloc.free(model_path_z);
    const mmproj_path_z = try alloc.dupeZ(u8, config.mmproj_path);
    defer alloc.free(mmproj_path_z);
    const cfg = c.rtm_llm_model_config{
        .model_path = model_path_z.ptr,
        .mmproj_path = mmproj_path_z.ptr,
        .ctx_size = config.ctx_size,
        .threads = threads,
        .gpu_layers = config.gpu_layers,
        .seed = config.seed orelse 0,
        .has_seed = config.seed != null,
    };

    const session = c.rtm_llm_session_create(&cfg);
    if (session == null) {
        const kind = c.rtm_llm_global_error_kind();
        const message = bridgeMessage(c.rtm_llm_global_last_error());
        if (message.len != 0) std.debug.print("libllm init failed: {s}\n", .{message});
        return mapBridgeError(kind, c.rtm_llm_global_last_error());
    }
    errdefer c.rtm_llm_session_destroy(session);

    const ctx = try alloc.create(ProviderContext);
    ctx.* = .{ .session = session.? };
    return .{
        .ctx = ctx,
        .vtable = &.{
            .infer = infer,
            .deinit = deinit,
        },
    };
}

pub fn validateConfig(config: types.ModelConfig) !void {
    try ensureFileExists(config.model_path, errors.Error.ModelNotFound);
    try ensureFileExists(config.mmproj_path, errors.Error.MmprojNotFound);
}

fn infer(ctx_ptr: *anyopaque, alloc: std.mem.Allocator, req: types.Request) !types.Response {
    const ctx: *ProviderContext = @ptrCast(@alignCast(ctx_ptr));
    try ensureFileExists(req.image_path, errors.Error.ImageNotFound);

    const prompt_z = try alloc.dupeZ(u8, req.prompt);
    defer alloc.free(prompt_z);
    const image_path_z = try alloc.dupeZ(u8, req.image_path);
    defer alloc.free(image_path_z);
    const bridge_req = c.rtm_llm_request{
        .prompt = prompt_z.ptr,
        .image_path = image_path_z.ptr,
        .max_tokens = req.max_tokens orelse 0,
        .has_max_tokens = req.max_tokens != null,
        .temperature = req.temperature,
        .top_p = req.top_p,
        .seed = req.seed orelse 0,
        .has_seed = req.seed != null,
        .json_mode = req.json_mode,
    };

    var bridge_resp: c.rtm_llm_response = std.mem.zeroes(c.rtm_llm_response);
    const ok = c.rtm_llm_infer_image(ctx.session, &bridge_req, &bridge_resp);
    if (!ok) {
        const kind = c.rtm_llm_session_error_kind(ctx.session);
        const message = bridgeMessage(c.rtm_llm_last_error(ctx.session));
        if (message.len != 0) std.debug.print("libllm inference failed: {s}\n", .{message});
        return mapBridgeError(kind, c.rtm_llm_last_error(ctx.session));
    }
    defer c.rtm_llm_response_free(&bridge_resp);

    if (bridge_resp.text == null) return errors.Error.BackendInferenceFailed;
    const c_text: [*:0]const u8 = @ptrCast(bridge_resp.text);
    const text = std.mem.span(c_text);
    const duped = try alloc.dupe(u8, text);
    errdefer alloc.free(duped);

    return .{
        .text = duped,
        .prompt_tokens = if (bridge_resp.has_prompt_tokens) bridge_resp.prompt_tokens else null,
        .completion_tokens = if (bridge_resp.has_completion_tokens) bridge_resp.completion_tokens else null,
        .backend_name = "llama-mtmd",
        .finish_reason = mapFinishReason(bridge_resp.finish_reason),
    };
}

fn deinit(ctx_ptr: *anyopaque, alloc: std.mem.Allocator) void {
    const ctx: *ProviderContext = @ptrCast(@alignCast(ctx_ptr));
    c.rtm_llm_session_destroy(ctx.session);
    alloc.destroy(ctx);
}

fn effectiveThreadCount(threads: u16) u16 {
    if (threads != 0) return threads;
    return std.math.cast(u16, std.Thread.getCpuCount() catch 4) orelse 4;
}

fn ensureFileExists(path: []const u8, err: anyerror) !void {
    std.fs.cwd().access(path, .{}) catch |access_err| switch (access_err) {
        error.FileNotFound => return err,
        else => return access_err,
    };
}

fn mapBridgeError(kind: c.rtm_llm_error_kind, message_c: ?[*:0]const u8) errors.Error {
    _ = message_c;
    return switch (kind) {
        c.RTM_LLM_ERROR_MODEL_NOT_FOUND => errors.Error.ModelNotFound,
        c.RTM_LLM_ERROR_MMPROJ_NOT_FOUND => errors.Error.MmprojNotFound,
        c.RTM_LLM_ERROR_IMAGE_NOT_FOUND => errors.Error.ImageNotFound,
        c.RTM_LLM_ERROR_OUT_OF_MEMORY => errors.Error.OutOfMemory,
        c.RTM_LLM_ERROR_UNSUPPORTED_REQUEST => errors.Error.UnsupportedRequest,
        c.RTM_LLM_ERROR_BACKEND_INIT_FAILED => errors.Error.BackendInitFailed,
        c.RTM_LLM_ERROR_UTF8_DECODE_FAILED => errors.Error.Utf8DecodeFailed,
        c.RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, c.RTM_LLM_ERROR_UNKNOWN => errors.Error.BackendInferenceFailed,
        else => errors.Error.BackendInferenceFailed,
    };
}

fn mapFinishReason(reason: c.rtm_llm_finish_reason) types.FinishReason {
    return switch (reason) {
        c.RTM_LLM_FINISH_STOP => .stop,
        c.RTM_LLM_FINISH_LENGTH => .length,
        c.RTM_LLM_FINISH_ERROR => .@"error",
        else => .unknown,
    };
}

fn bridgeMessage(message_c: ?[*:0]const u8) []const u8 {
    if (message_c) |message| return std.mem.span(message);
    return "";
}

test "validateConfig rejects missing files" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "model.gguf", .data = "x" });
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &tmp_path_buf);
    const model_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "model.gguf" });
    defer testing.allocator.free(model_path);
    const missing_mmproj_path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "missing.gguf" });
    defer testing.allocator.free(missing_mmproj_path);

    try testing.expectError(errors.Error.MmprojNotFound, validateConfig(.{
        .model_path = model_path,
        .mmproj_path = missing_mmproj_path,
    }));
}

test "bridge error mapping is stable" {
    try std.testing.expectEqual(errors.Error.ModelNotFound, mapBridgeError(c.RTM_LLM_ERROR_MODEL_NOT_FOUND, null));
    try std.testing.expectEqual(errors.Error.MmprojNotFound, mapBridgeError(c.RTM_LLM_ERROR_MMPROJ_NOT_FOUND, null));
    try std.testing.expectEqual(errors.Error.ImageNotFound, mapBridgeError(c.RTM_LLM_ERROR_IMAGE_NOT_FOUND, null));
}
