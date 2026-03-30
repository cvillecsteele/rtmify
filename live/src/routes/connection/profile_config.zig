const std = @import("std");
const Allocator = std.mem.Allocator;

const profile_mod = @import("rtmify").profile;
const secure_store_mod = @import("../../secure_store.zig");
const workbook = @import("../../workbook/mod.zig");
const json_util = @import("../../json_util.zig");
const shared = @import("../shared.zig");

pub fn handleGetProfile(registry: *workbook.registry.WorkbookRegistry, alloc: Allocator) ![]const u8 {
    const prof_name = (try registry.activeConfig()).profile;
    const pid = profile_mod.fromString(prof_name) orelse .generic;
    const prof = profile_mod.get(pid);
    return std.fmt.allocPrint(alloc, "{{\"profile\":\"{s}\",\"name\":\"{s}\"}}", .{ prof_name, prof.name });
}

pub fn handlePostProfile(registry: *workbook.registry.WorkbookRegistry, body: []const u8, alloc: Allocator) ![]const u8 {
    const resp = try handlePostProfileResponse(registry, body, alloc, alloc);
    return resp.body;
}

pub fn handlePostProfileResponse(
    registry: *workbook.registry.WorkbookRegistry,
    body: []const u8,
    alloc: Allocator,
    persistent_alloc: Allocator,
) !shared.JsonRouteResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"invalid JSON\"}"), false);
    defer parsed.deinit();

    const name = json_util.getString(parsed.value, "profile") orelse
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"missing profile field\"}"), false);
    if (profile_mod.fromString(name) == null) {
        return shared.jsonRouteResponse(.bad_request, try alloc.dupe(u8, "{\"ok\":false,\"error\":\"unknown profile\"}"), false);
    }
    try workbook.config.setActiveProfile(&registry.live_config, name, persistent_alloc);
    {
        const runtime = try registry.active();
        runtime.config.deinit(persistent_alloc);
        runtime.config = try (try registry.activeConfig()).clone(persistent_alloc);
        runtime.db.deleteConfig("rtmify_provisioned") catch {};
    }
    try registry.save(persistent_alloc);
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, "{\"ok\":true}"), true);
}

fn makeTestRegistry(alloc: Allocator, store: *secure_store_mod.Store) !workbook.registry.WorkbookRegistry {
    var cfg = try workbook.config.bootstrapConfig(alloc, .{});
    errdefer cfg.deinit(alloc);
    alloc.free(cfg.workbooks[0].db_path);
    cfg.workbooks[0].db_path = try alloc.dupe(u8, ":memory:");
    alloc.free(cfg.workbooks[0].inbox_dir);
    cfg.workbooks[0].inbox_dir = try alloc.dupe(u8, "/tmp/inbox");
    return workbook.registry.WorkbookRegistry.initForConfig(alloc, cfg, store);
}

const testing = std.testing;

test "handlePostProfile accepts legal JSON with whitespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var store = try secure_store_mod.initTestMemory(alloc);
    defer store.deinit(alloc);
    var registry = try makeTestRegistry(alloc, &store);
    defer registry.deinit(alloc);

    const resp = try handlePostProfile(&registry, "{ \"profile\" : \"aerospace\" }", alloc);
    try testing.expectEqualStrings("{\"ok\":true}", resp);
}
