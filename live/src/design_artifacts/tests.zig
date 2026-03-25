const std = @import("std");

const design_artifacts = @import("../design_artifacts.zig");
const ids = @import("ids.zig");
const snapshot = @import("snapshot.zig");
const xlsx = @import("rtmify").xlsx;

test "artifact id uses kind namespace" {
    const value = try design_artifacts.artifactIdFor(.srs_docx, "core", std.testing.allocator);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("artifact://srs_docx/core", value);
}

test "rtm workbook artifact id uses rtm namespace" {
    const value = try design_artifacts.artifactIdFor(.rtm_workbook, "demo", std.testing.allocator);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("artifact://rtm/demo", value);
}

test "requirement text id omits redundant index" {
    const value = try ids.buildRequirementTextId("artifact://srs_docx/core", "REQ-001", std.testing.allocator);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("artifact://srs_docx/core:REQ-001", value);
}

test "validateUniqueAssertionIds rejects duplicate requirement ids" {
    const assertions = [_]design_artifacts.ParsedRequirementAssertion{
        .{
            .req_id = "REQ-001",
            .section = "paragraph",
            .text = "One",
            .normalized_text = "one",
            .parse_status = "ok",
            .occurrence_count = 2,
        },
        .{
            .req_id = "REQ-001",
            .section = "table",
            .text = "One",
            .normalized_text = "one",
            .parse_status = "ambiguous_within_artifact",
            .occurrence_count = 1,
        },
    };

    try std.testing.expectError(error.DuplicateRequirementAssertion, snapshot.validateUniqueAssertionIds(&assertions, std.testing.allocator));
}

test "validateRtmWorkbookShape rejects BOM workbook shape" {
    const sheets = [_]xlsx.SheetData{
        .{ .name = "Design BOM", .rows = &.{} },
        .{ .name = "Requirements", .rows = &.{} },
        .{ .name = "User Needs", .rows = &.{} },
        .{ .name = "Tests", .rows = &.{} },
        .{ .name = "Risks", .rows = &.{} },
    };
    try std.testing.expectError(error.UnsupportedFormat, design_artifacts.validateRtmWorkbookShape(&sheets));
}

test "validateRtmWorkbookShape requires required sheets" {
    const sheets = [_]xlsx.SheetData{
        .{ .name = "Requirements", .rows = &.{} },
        .{ .name = "User Needs", .rows = &.{} },
        .{ .name = "Tests", .rows = &.{} },
    };
    try std.testing.expectError(error.InvalidXlsx, design_artifacts.validateRtmWorkbookShape(&sheets));
}

test "facade exports key public functions" {
    _ = design_artifacts.artifactIdFor;
    _ = design_artifacts.migrateLegacyRequirementStatements;
    _ = design_artifacts.ingestDocxPath;
    _ = design_artifacts.ingestRtmWorkbookPath;
    _ = design_artifacts.reingestArtifact;
    _ = design_artifacts.listArtifactsJson;
    _ = design_artifacts.getArtifactJson;
    _ = design_artifacts.listArtifacts;
    _ = design_artifacts.applyArtifactSnapshot;
    _ = design_artifacts.parseDocxAssertions;
    _ = design_artifacts.extractDocxAllText;
    _ = design_artifacts.validateRtmWorkbookShape;
}
