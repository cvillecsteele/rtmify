const std = @import("std");

pub const FinishReason = enum {
    stop,
    length,
    @"error",
    unknown,
};

pub const Request = struct {
    prompt: []const u8,
    image_path: []const u8,
    max_tokens: ?u32 = null,
    temperature: f32 = 0.0,
    top_p: f32 = 1.0,
    seed: ?u32 = null,
    json_mode: bool = false,
};

pub const Response = struct {
    text: []u8,
    prompt_tokens: ?u32 = null,
    completion_tokens: ?u32 = null,
    backend_name: []const u8,
    finish_reason: FinishReason = .unknown,

    pub fn deinit(self: *Response, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const ModelConfig = struct {
    model_path: []const u8,
    mmproj_path: []const u8,
    ctx_size: u32 = 8192,
    threads: u16 = 0,
    gpu_layers: u16 = 0,
    seed: ?u32 = 0,
};

test "request defaults are deterministic" {
    const req = Request{
        .prompt = "hello",
        .image_path = "image.jpg",
    };

    try std.testing.expectEqual(@as(?u32, null), req.max_tokens);
    try std.testing.expectEqual(@as(f32, 0.0), req.temperature);
    try std.testing.expectEqual(@as(f32, 1.0), req.top_p);
    try std.testing.expectEqual(@as(?u32, null), req.seed);
    try std.testing.expectEqual(false, req.json_mode);
}
