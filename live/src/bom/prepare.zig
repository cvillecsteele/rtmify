const std = @import("std");
const json_util = @import("../json_util.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const prepare_csv = @import("prepare_csv.zig");
const prepare_json = @import("prepare_json.zig");
const prepare_cyclonedx = @import("prepare_cyclonedx.zig");
const prepare_spdx = @import("prepare_spdx.zig");

pub const Allocator = std.mem.Allocator;

pub fn prepareHttpBody(content_type: ?[]const u8, body: []const u8, alloc: Allocator) (types.BomError || error{OutOfMemory})!types.PreparedBom {
    if (content_type) |value| {
        if (std.mem.startsWith(u8, value, "text/csv")) return prepare_csv.prepareHardwareCsv(body, alloc);
        if (std.mem.startsWith(u8, value, "application/json")) return prepareJsonBody(body, alloc);
    }
    return if (util.looksLikeJson(body)) prepareJsonBody(body, alloc) else if (util.looksLikeCsv(body)) prepare_csv.prepareHardwareCsv(body, alloc) else error.UnsupportedContentType;
}

pub fn prepareInboxFile(name: []const u8, body: []const u8, alloc: Allocator) (types.BomError || error{OutOfMemory})!types.PreparedBom {
    if (std.mem.endsWith(u8, name, ".csv")) return prepare_csv.prepareHardwareCsv(body, alloc);
    if (std.mem.endsWith(u8, name, ".json")) return prepareJsonBody(body, alloc);
    if (std.mem.endsWith(u8, name, ".xlsx")) return error.UnsupportedFormat;
    return error.UnsupportedFormat;
}

pub fn prepareJsonBody(body: []const u8, alloc: Allocator) (types.BomError || error{OutOfMemory})!types.PreparedBom {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    if (json_util.getObjectField(root, "bom_items") != null) return prepare_json.prepareHardwareJson(root, alloc);
    if (json_util.getString(root, "bomFormat")) |value| {
        if (std.mem.eql(u8, value, "CycloneDX")) return prepare_cyclonedx.prepareCycloneDx(root, alloc);
    }
    if (json_util.getString(root, "spdxVersion") != null) return prepare_spdx.prepareSpdx(root, alloc);
    return error.UnsupportedFormat;
}
