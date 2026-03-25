pub const assets = @import("assets.zig");
pub const listen = @import("listen.zig");
pub const policy = @import("policy.zig");
pub const request_utils = @import("request_utils.zig");
pub const response = @import("response.zig");
pub const security = @import("security.zig");

test "server facade still exposes public API" {
    const facade = @import("../server.zig");
    _ = facade.ServerCtx;
    _ = facade.InstanceInfo;
    _ = facade.listen;
}

test {
    _ = assets;
    _ = listen;
    _ = policy;
    _ = request_utils;
    _ = response;
    _ = security;
}
