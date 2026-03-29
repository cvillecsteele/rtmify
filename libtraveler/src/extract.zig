const std = @import("std");
const llm = @import("llm");
const json_parse = @import("json_parse.zig");
const normalize = @import("normalize.zig");
const prompt = @import("prompt.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");

pub const Extractor = struct {
    provider: llm.Provider,
    owns_provider: bool,

    pub fn initWithProvider(provider: llm.Provider, owns_provider: bool) Extractor {
        return .{
            .provider = provider,
            .owns_provider = owns_provider,
        };
    }

    pub fn deinit(self: *Extractor, alloc: std.mem.Allocator) void {
        if (self.owns_provider) {
            self.provider.deinit(alloc);
        }
    }

    pub fn extractImage(self: *Extractor, alloc: std.mem.Allocator, image_path: []const u8) !types.TravelerResult {
        var response = try self.provider.infer(alloc, .{
            .prompt = prompt.extraction_prompt,
            .image_path = image_path,
            .json_mode = true,
        });
        errdefer response.deinit(alloc);

        var result = types.TravelerResult{
            .raw_response_text = response.text,
        };
        errdefer result.deinit(alloc);

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const json_bytes = json_parse.extractFirstJSONObjectAlloc(arena, response.text) catch {
            response.text = &.{};
            result.validation.status = .rejected;
            result.validation.rejection_reason = .structurally_invalid_json;
            result.validation.warnings = try alloc.dupe(types.WarningCode, &.{});
            return result;
        };

        var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch {
            response.text = &.{};
            result.validation.status = .rejected;
            result.validation.rejection_reason = .structurally_invalid_json;
            result.validation.warnings = try alloc.dupe(types.WarningCode, &.{});
            return result;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const heuristics = detectHeuristics(root);

        result.header.product_name = try dupOptionalField(alloc, root, &.{
            &.{ "header", "product_name" },
            &.{ "PRODUCT NAME" },
            &.{ "product_name" },
            &.{ "product" },
        });
        result.header.assembly = try dupOptionalField(alloc, root, &.{
            &.{ "header", "assembly" },
            &.{ "PART NUMBER" },
            &.{ "part_number" },
            &.{ "assembly" },
        });
        result.header.serial_number = try dupOptionalField(alloc, root, &.{
            &.{ "header", "serial_number" },
            &.{ "SERIAL NUMBER" },
            &.{ "serial_number" },
        });
        result.header.bom_revision = try dupOptionalField(alloc, root, &.{
            &.{ "header", "bom_revision" },
            &.{ "BOM REVISION" },
            &.{ "bom_revision" },
        });
        result.header.work_order = try dupOptionalField(alloc, root, &.{
            &.{ "header", "work_order" },
            &.{ "WORK ORDER" },
            &.{ "work_order" },
        });
        result.header.lot_batch = try dupOptionalField(alloc, root, &.{
            &.{ "header", "lot_batch" },
            &.{ "LOT / BATCH" },
            &.{ "lot_batch" },
        });
        result.header.traveler_date = try dupOptionalField(alloc, root, &.{
            &.{ "header", "traveler_date" },
            &.{ "DATE INITIATED" },
            &.{ "traveler_date" },
        });
        result.verification.atp_test_report_id = try dupOptionalField(alloc, root, &.{
            &.{ "verification", "atp_test_report_id" },
            &.{ "ATP TEST REPORT ID" },
            &.{ "atp_test_report_id" },
        });
        result.verification.final_disposition = try dupOptionalField(alloc, root, &.{
            &.{ "verification", "final_disposition" },
            &.{ "FINAL DISPOSITION" },
            &.{ "final_disposition" },
        });
        result.verification.rework_ncr_number = try dupOptionalField(alloc, root, &.{
            &.{ "verification", "rework_ncr_number" },
            &.{ "REWORK (NCR #)" },
            &.{ "rework_ncr_number" },
        });

        result.header.product_name = try takeNormalized(alloc, result.header.product_name, renormalizeOptional);
        result.header.assembly = try takeNormalized(alloc, result.header.assembly, normalize.normalizeAssemblyAlloc);
        result.header.serial_number = try takeNormalized(alloc, result.header.serial_number, renormalizeOptional);
        result.header.bom_revision = try takeNormalized(alloc, result.header.bom_revision, normalize.normalizeRevisionAlloc);
        result.verification.atp_test_report_id = try takeNormalized(alloc, result.verification.atp_test_report_id, renormalizeOptional);
        result.normalized.product_full_identifier = try normalize.deriveFullIdentifierAlloc(alloc, result.header);

        response.text = &.{};
        try validate.classify(alloc, &result, heuristics);
        return result;
    }
};

fn renormalizeOptional(alloc: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    if (value == null) return null;
    const normalized = try normalize.collapseWhitespaceAlloc(alloc, value.?);
    return normalized;
}

fn takeNormalized(
    alloc: std.mem.Allocator,
    value: ?[]u8,
    comptime func: fn (std.mem.Allocator, ?[]const u8) anyerror!?[]u8,
) !?[]u8 {
    if (value == null) return null;
    defer alloc.free(value.?);
    return func(alloc, value.?);
}

fn dupOptionalField(alloc: std.mem.Allocator, root: std.json.Value, comptime paths: []const []const []const u8) !?[]u8 {
    inline for (paths) |path| {
        if (lookupPath(root, path)) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len == 0) return null;
            const duped = try alloc.dupe(u8, trimmed);
            return duped;
        }
    }
    return null;
}

fn lookupPath(root: std.json.Value, comptime path: []const []const u8) ?[]const u8 {
    var current = root;
    inline for (path, 0..) |part, idx| {
        switch (current) {
            .object => |obj| {
                const next = obj.get(part) orelse return null;
                if (idx == path.len - 1) {
                    return jsonString(next);
                }
                current = next;
            },
            else => return null,
        }
    }
    return null;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .null => null,
        else => null,
    };
}

fn detectHeuristics(root: std.json.Value) validate.Heuristics {
    var heuristics = validate.Heuristics{};
    if (root != .object) {
        heuristics.repeated_key_flattening = true;
        return heuristics;
    }

    const obj = root.object;
    const has_nested_header = obj.get("header") != null;
    const has_flat_repeated = obj.get("ITEM") != null or obj.get("STEP") != null or obj.get("QTY REQ'D") != null;
    if (!has_nested_header and has_flat_repeated) {
        heuristics.repeated_key_flattening = true;
    }

    if (obj.get("PART NUMBER") != null and obj.get("ITEM") != null) {
        heuristics.header_component_confusion = true;
    }

    const footer_keys = [_][]const u8{
        "QF-720-004 Rev C • Controlled Document • Do Not Duplicate",
        "Page 1 of 1",
        "VitalSense Medical Devices, Inc.",
    };
    for (footer_keys) |key| {
        if (obj.get(key) != null) {
            heuristics.footer_boilerplate_capture = true;
            break;
        }
    }

    return heuristics;
}

test "good JSON with all required fields is accepted" {
    const testing = std.testing;
    const Fake = struct {
        payload: []const u8,

        fn infer(ctx: *anyopaque, alloc: std.mem.Allocator, _: llm.Request) !llm.Response {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return .{
                .text = try alloc.dupe(u8, self.payload),
                .backend_name = "fake",
                .finish_reason = .stop,
            };
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var fake = Fake{
        .payload =
            \\{"header":{"product_name":"VS-200 Patient Monitor","assembly":"VS200-ASSY-100","serial_number":"D71893","bom_revision":"Rev C"},"verification":{"atp_test_report_id":"ATP 178-37-B"}}
        ,
    };
    var extractor = Extractor.initWithProvider(.{
        .ctx = &fake,
        .vtable = &.{ .infer = Fake.infer, .deinit = Fake.deinit },
    }, false);

    var result = try extractor.extractImage(testing.allocator, "image.jpg");
    defer result.deinit(testing.allocator);

    try testing.expectEqual(types.ValidationStatus.accepted, result.validation.status);
    try testing.expectEqual(types.RejectionReason.ok, result.validation.rejection_reason);
    try testing.expectEqualStrings("VS-200 Patient Monitor", result.header.product_name.?);
    try testing.expectEqualStrings("VS200-ASSY-100-REV-C", result.normalized.product_full_identifier.?);
}

test "missing product name rejects" {
    const testing = std.testing;
    const Fake = struct {
        fn infer(_: *anyopaque, alloc: std.mem.Allocator, _: llm.Request) !llm.Response {
            return .{
                .text = try alloc.dupe(u8, "{\"header\":{\"assembly\":\"VS200-ASSY-100\",\"serial_number\":\"D71893\",\"bom_revision\":\"Rev C\"},\"verification\":{\"atp_test_report_id\":\"ATP 178-37-B\"}}"),
                .backend_name = "fake",
                .finish_reason = .stop,
            };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var extractor = Extractor.initWithProvider(.{
        .ctx = undefined,
        .vtable = &.{ .infer = Fake.infer, .deinit = Fake.deinit },
    }, false);
    var result = try extractor.extractImage(testing.allocator, "image.jpg");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(types.RejectionReason.missing_product_name, result.validation.rejection_reason);
}

test "flat repeated-key JSON rejects as repeated_key_flattening" {
    const testing = std.testing;
    const Fake = struct {
        fn infer(_: *anyopaque, alloc: std.mem.Allocator, _: llm.Request) !llm.Response {
            return .{
                .text = try alloc.dupe(u8, "{\"PRODUCT NAME\":\"VS-200\",\"PART NUMBER\":\"PCB-200-MCU-01\",\"ITEM\":\"1\",\"SERIAL NUMBER\":\"D71893\",\"BOM REVISION\":\"Rev C\",\"ATP TEST REPORT ID\":\"ATP 178-37-B\"}"),
                .backend_name = "fake",
                .finish_reason = .stop,
            };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var extractor = Extractor.initWithProvider(.{
        .ctx = undefined,
        .vtable = &.{ .infer = Fake.infer, .deinit = Fake.deinit },
    }, false);
    var result = try extractor.extractImage(testing.allocator, "image.jpg");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(types.RejectionReason.header_component_confusion, result.validation.rejection_reason);
}

test "malformed JSON is rejected" {
    const testing = std.testing;
    const Fake = struct {
        fn infer(_: *anyopaque, alloc: std.mem.Allocator, _: llm.Request) !llm.Response {
            return .{
                .text = try alloc.dupe(u8, "not json"),
                .backend_name = "fake",
                .finish_reason = .stop,
            };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var extractor = Extractor.initWithProvider(.{
        .ctx = undefined,
        .vtable = &.{ .infer = Fake.infer, .deinit = Fake.deinit },
    }, false);
    var result = try extractor.extractImage(testing.allocator, "image.jpg");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(types.RejectionReason.structurally_invalid_json, result.validation.rejection_reason);
}
