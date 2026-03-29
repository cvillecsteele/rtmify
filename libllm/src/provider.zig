const std = @import("std");
const types = @import("types.zig");

pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        infer: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, req: types.Request) anyerror!types.Response,
        deinit: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator) void,
    };

    pub fn infer(self: Provider, alloc: std.mem.Allocator, req: types.Request) !types.Response {
        return self.vtable.infer(self.ctx, alloc, req);
    }

    pub fn deinit(self: Provider, alloc: std.mem.Allocator) void {
        self.vtable.deinit(self.ctx, alloc);
    }
};

test "provider delegates infer and deinit" {
    const testing = std.testing;

    const Fake = struct {
        saw_infer: bool = false,
        saw_deinit: bool = false,

        fn infer(ctx: *anyopaque, alloc: std.mem.Allocator, req: types.Request) !types.Response {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.saw_infer = true;
            try testing.expectEqualStrings("prompt", req.prompt);
            return .{
                .text = try alloc.dupe(u8, "{\"ok\":true}"),
                .backend_name = "fake",
                .finish_reason = .stop,
            };
        }

        fn deinit(ctx: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.saw_deinit = true;
        }
    };

    var fake = Fake{};
    const provider = Provider{
        .ctx = &fake,
        .vtable = &.{
            .infer = Fake.infer,
            .deinit = Fake.deinit,
        },
    };

    var response = try provider.infer(testing.allocator, .{
        .prompt = "prompt",
        .image_path = "image.jpg",
    });
    defer response.deinit(testing.allocator);

    try testing.expect(fake.saw_infer);
    provider.deinit(testing.allocator);
    try testing.expect(fake.saw_deinit);
}
