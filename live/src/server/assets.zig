const std = @import("std");

const routes = @import("../routes.zig");

pub fn staticAssetForPath(path: []const u8) ?routes.StaticAsset {
    for (routes.static_assets) |asset| {
        if (std.mem.eql(u8, asset.path, path)) return asset;
    }
    return null;
}

const testing = std.testing;

test "static asset lookup returns embedded module asset" {
    const asset = staticAssetForPath("/modules/helpers.js");
    try testing.expect(asset != null);
    try testing.expectEqualStrings("/modules/helpers.js", asset.?.path);
    try testing.expectEqualStrings("application/javascript; charset=utf-8", asset.?.content_type);

    const init = staticAssetForPath("/modules/init.js");
    try testing.expect(init != null);
    try testing.expectEqualStrings("/modules/init.js", init.?.path);
}

test "static asset lookup rejects unknown module path" {
    try testing.expect(staticAssetForPath("/modules/does-not-exist.js") == null);
}
