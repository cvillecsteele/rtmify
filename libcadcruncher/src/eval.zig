const std = @import("std");
const altium = @import("altium.zig");
const detect = @import("detect.zig");
const evidence = @import("evidence.zig");
const sample_probe = @import("sample_probe.zig");

pub const UsefulnessClass = enum {
    reportable,
    inspect_only,
    noise,
};

pub const ScopeCount = struct {
    scope_kind: evidence.ScopeKind,
    count: usize,
};

pub const UsefulnessCount = struct {
    class: UsefulnessClass,
    count: usize,
};

pub const EvaluationSummary = struct {
    fixture_path: []const u8,
    artifact_kind: detect.ArtifactKind,

    total_records: usize,
    useful_records: usize,
    unknown_records: usize,

    by_scope: []const ScopeCount,
    by_usefulness: []const UsefulnessCount,

    missing_expected: []const []const u8,
    unexpected_reportable: []const []const u8,
};

const ExpectedReportableRecord = struct {
    scope_kind: []const u8,
    scope_identifier: ?[]const u8 = null,
};

const FixtureExpectation = struct {
    expected_reportable_records: []ExpectedReportableRecord = &.{},
    expected_document_fields: [][]const u8 = &.{},
    minimum_reportable_count: usize = 0,
};

pub fn classifyRecord(record: evidence.EvidenceRecord) UsefulnessClass {
    return switch (record.artifact_kind) {
        .altium_pcbdoc => classifyPcbDoc(record),
        .altium_schdoc => classifySchDoc(record),
        else => .noise,
    };
}

pub fn evaluateExtracted(
    fixture_path: []const u8,
    artifact_kind: detect.ArtifactKind,
    records: []const evidence.EvidenceRecord,
    allocator: std.mem.Allocator,
) !EvaluationSummary {
    const expectation = try loadExpectationForFixture(fixture_path, allocator);
    defer if (expectation) |exp| freeFixtureExpectation(exp, allocator);

    var scope_counts: [@typeInfo(evidence.ScopeKind).@"enum".fields.len]usize = [_]usize{0} ** @typeInfo(evidence.ScopeKind).@"enum".fields.len;
    var usefulness_counts: [@typeInfo(UsefulnessClass).@"enum".fields.len]usize = [_]usize{0} ** @typeInfo(UsefulnessClass).@"enum".fields.len;

    var useful_records: usize = 0;
    var unknown_records: usize = 0;

    var actual_reportable: std.ArrayList([]const u8) = .empty;
    defer {
        for (actual_reportable.items) |item| allocator.free(item);
        actual_reportable.deinit(allocator);
    }

    var actual_document_fields: std.ArrayList([]const u8) = .empty;
    defer {
        for (actual_document_fields.items) |item| allocator.free(item);
        actual_document_fields.deinit(allocator);
    }

    for (records) |record| {
        scope_counts[@intFromEnum(record.scope_kind)] += 1;
        if (record.scope_kind == .unknown) unknown_records += 1;

        const usefulness = classifyRecord(record);
        usefulness_counts[@intFromEnum(usefulness)] += 1;

        if (usefulness == .reportable) {
            useful_records += 1;
            try actual_reportable.append(allocator, try reportableDescriptor(record, allocator));
        }

        if (record.scope_kind == .document) {
            try collectActualDocumentFields(record, &actual_document_fields, allocator);
        }
    }

    var by_scope: std.ArrayList(ScopeCount) = .empty;
    defer by_scope.deinit(allocator);
    inline for (@typeInfo(evidence.ScopeKind).@"enum".fields, 0..) |field, i| {
        if (scope_counts[i] != 0) {
            try by_scope.append(allocator, .{
                .scope_kind = @enumFromInt(field.value),
                .count = scope_counts[i],
            });
        }
    }

    var by_usefulness: std.ArrayList(UsefulnessCount) = .empty;
    defer by_usefulness.deinit(allocator);
    inline for (@typeInfo(UsefulnessClass).@"enum".fields, 0..) |field, i| {
        if (usefulness_counts[i] != 0) {
            try by_usefulness.append(allocator, .{
                .class = @enumFromInt(field.value),
                .count = usefulness_counts[i],
            });
        }
    }

    var missing_expected: std.ArrayList([]const u8) = .empty;
    defer {
        for (missing_expected.items) |item| allocator.free(item);
        missing_expected.deinit(allocator);
    }

    var unexpected_reportable: std.ArrayList([]const u8) = .empty;
    defer {
        for (unexpected_reportable.items) |item| allocator.free(item);
        unexpected_reportable.deinit(allocator);
    }

    if (expectation) |exp| {
        for (exp.expected_reportable_records) |wanted| {
            const descriptor = try expectedDescriptor(wanted, allocator);
            defer allocator.free(descriptor);
            if (!containsString(actual_reportable.items, descriptor)) {
                try missing_expected.append(allocator, try allocator.dupe(u8, descriptor));
            }
        }
        for (exp.expected_document_fields) |field| {
            const descriptor = try std.fmt.allocPrint(allocator, "document-field:{s}", .{field});
            defer allocator.free(descriptor);
            if (!containsString(actual_document_fields.items, descriptor)) {
                try missing_expected.append(allocator, try allocator.dupe(u8, descriptor));
            }
        }
        for (actual_reportable.items) |actual| {
            if (!isExpectedActual(actual, exp.expected_reportable_records)) {
                try unexpected_reportable.append(allocator, try allocator.dupe(u8, actual));
            }
        }
        if (useful_records < exp.minimum_reportable_count) {
            try missing_expected.append(allocator, try std.fmt.allocPrint(
                allocator,
                "minimum-reportable:{d}<{d}",
                .{ useful_records, exp.minimum_reportable_count },
            ));
        }
    }

    return .{
        .fixture_path = try allocator.dupe(u8, fixture_path),
        .artifact_kind = artifact_kind,
        .total_records = records.len,
        .useful_records = useful_records,
        .unknown_records = unknown_records,
        .by_scope = try by_scope.toOwnedSlice(allocator),
        .by_usefulness = try by_usefulness.toOwnedSlice(allocator),
        .missing_expected = try missing_expected.toOwnedSlice(allocator),
        .unexpected_reportable = try unexpected_reportable.toOwnedSlice(allocator),
    };
}

pub fn freeEvaluationSummary(summary: EvaluationSummary, allocator: std.mem.Allocator) void {
    allocator.free(summary.fixture_path);
    allocator.free(summary.by_scope);
    allocator.free(summary.by_usefulness);
    for (summary.missing_expected) |item| allocator.free(item);
    allocator.free(summary.missing_expected);
    for (summary.unexpected_reportable) |item| allocator.free(item);
    allocator.free(summary.unexpected_reportable);
}

fn classifyPcbDoc(record: evidence.EvidenceRecord) UsefulnessClass {
    return switch (record.scope_kind) {
        .component => if (record.scope_identifier != null and
            (record.display_name != null or hasAnyProperty(record.properties, &.{ "Pattern", "PATTERN", "Comment", "SOURCEDESCRIPTION" })))
            .reportable
        else
            .inspect_only,
        .document => if (record.display_name != null and hasAnyProperty(record.properties, &.{ "Format", "HEADER", "TITLE", "FILENAME", "Guid" }))
            .reportable
        else
            .inspect_only,
        .net, .rule, .layer_stack_region, .model => .inspect_only,
        .unknown => if (record.scope_identifier != null or record.display_name != null) .inspect_only else .noise,
    };
}

fn classifySchDoc(record: evidence.EvidenceRecord) UsefulnessClass {
    return switch (record.scope_kind) {
        .component => if (record.scope_identifier != null and
            (record.display_name != null or hasAnyProperty(record.properties, &.{ "LIBREFERENCE", "DESIGNITEMID", "Comment", "COMMENT" })))
            .reportable
        else
            .inspect_only,
        .document => if (hasAnyProperty(record.properties, &.{ "Author", "Title", "DocumentName", "ProjectName", "Revision" }))
            .reportable
        else if (record.display_name != null or record.scope_identifier != null)
            .inspect_only
        else
            .noise,
        .unknown => if (hasAnyProperty(record.properties, &.{ "NAME", "TEXT", "%UTF8%TEXT" }) or record.display_name != null or record.scope_identifier != null)
            .inspect_only
        else
            .noise,
        else => .inspect_only,
    };
}

fn hasAnyProperty(properties: []const evidence.Property, names: []const []const u8) bool {
    for (names) |name| {
        if (propertyValue(properties, name) != null) return true;
    }
    return false;
}

fn propertyValue(properties: []const evidence.Property, key: []const u8) ?[]const u8 {
    for (properties) |prop| {
        if (std.ascii.eqlIgnoreCase(prop.key, key)) return prop.value;
    }
    return null;
}

fn reportableDescriptor(record: evidence.EvidenceRecord, allocator: std.mem.Allocator) ![]u8 {
    if (record.scope_identifier) |id| {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ @tagName(record.scope_kind), id });
    }
    if (record.display_name) |name| {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ @tagName(record.scope_kind), name });
    }
    return std.fmt.allocPrint(allocator, "{s}:<unnamed>", .{ @tagName(record.scope_kind) });
}

fn expectedDescriptor(expected: ExpectedReportableRecord, allocator: std.mem.Allocator) ![]u8 {
    if (expected.scope_identifier) |id| {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ expected.scope_kind, id });
    }
    return std.fmt.allocPrint(allocator, "{s}:<unnamed>", .{ expected.scope_kind });
}

fn collectActualDocumentFields(
    record: evidence.EvidenceRecord,
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const fields = [_][]const u8{ "Author", "Title", "DocumentName", "ProjectName", "Revision" };
    for (fields) |field| {
        if (propertyValue(record.properties, field) != null) {
            const descriptor = try std.fmt.allocPrint(allocator, "document-field:{s}", .{field});
            if (!containsString(list.items, descriptor)) {
                try list.append(allocator, descriptor);
            } else {
                allocator.free(descriptor);
            }
        }
    }
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn isExpectedActual(
    descriptor: []const u8,
    expected_records: []const ExpectedReportableRecord,
) bool {
    for (expected_records) |wanted| {
        if (!std.mem.startsWith(u8, descriptor, wanted.scope_kind)) continue;
        if (wanted.scope_identifier) |id| {
            const actual_id = std.mem.trimLeft(u8, descriptor[wanted.scope_kind.len..], ":");
            if (std.mem.eql(u8, actual_id, id)) return true;
        } else {
            var buf: [128]u8 = undefined;
            const wanted_unnamed = std.fmt.bufPrint(&buf, "{s}:<unnamed>", .{wanted.scope_kind}) catch continue;
            if (std.mem.eql(u8, descriptor, wanted_unnamed)) return true;
        }
    }
    return false;
}

fn expectationPathForFixture(fixture_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const basename = std.fs.path.basename(fixture_path);
    const stem = std.fs.path.stem(basename);
    const filename = try std.fmt.allocPrint(allocator, "{s}.expected.json", .{stem});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ "libcadcruncher", "test", "golden", "altium", filename });
}

fn loadExpectationForFixture(fixture_path: []const u8, allocator: std.mem.Allocator) !?FixtureExpectation {
    const path = try expectationPathForFixture(fixture_path, allocator);
    defer allocator.free(path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidExpectationFile;

    var expectation = FixtureExpectation{};

    if (root.object.get("minimum_reportable_count")) |value| {
        expectation.minimum_reportable_count = switch (value) {
            .integer => |i| @intCast(i),
            else => return error.InvalidExpectationFile,
        };
    }

    if (root.object.get("expected_document_fields")) |value| {
        if (value != .array) return error.InvalidExpectationFile;
        var fields: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (fields.items) |field| allocator.free(field);
            fields.deinit(allocator);
        }
        for (value.array.items) |item| {
            if (item != .string) return error.InvalidExpectationFile;
            try fields.append(allocator, try allocator.dupe(u8, item.string));
        }
        expectation.expected_document_fields = try fields.toOwnedSlice(allocator);
    }

    if (root.object.get("expected_reportable_records")) |value| {
        if (value != .array) return error.InvalidExpectationFile;
        var records: std.ArrayList(ExpectedReportableRecord) = .empty;
        errdefer {
            for (records.items) |record| {
                allocator.free(record.scope_kind);
                if (record.scope_identifier) |id| allocator.free(id);
            }
            records.deinit(allocator);
        }
        for (value.array.items) |item| {
            if (item != .object) return error.InvalidExpectationFile;
            const scope_kind_val = item.object.get("scope_kind") orelse return error.InvalidExpectationFile;
            if (scope_kind_val != .string) return error.InvalidExpectationFile;
            const scope_identifier_val = item.object.get("scope_identifier");
            try records.append(allocator, .{
                .scope_kind = try allocator.dupe(u8, scope_kind_val.string),
                .scope_identifier = if (scope_identifier_val) |sid| switch (sid) {
                    .string => try allocator.dupe(u8, sid.string),
                    .null => null,
                    else => return error.InvalidExpectationFile,
                } else null,
            });
        }
        expectation.expected_reportable_records = try records.toOwnedSlice(allocator);
    }

    return expectation;
}

fn freeFixtureExpectation(expectation: FixtureExpectation, allocator: std.mem.Allocator) void {
    for (expectation.expected_reportable_records) |record| {
        allocator.free(record.scope_kind);
        if (record.scope_identifier) |id| allocator.free(id);
    }
    allocator.free(expectation.expected_reportable_records);
    for (expectation.expected_document_fields) |field| allocator.free(field);
    allocator.free(expectation.expected_document_fields);
}

test "classifyRecord promotes useful pcbdoc component evidence" {
    const props = [_]evidence.Property{
        .{ .key = "SOURCEDESIGNATOR", .value = "U2" },
        .{ .key = "PATTERN", .value = "LQFP64" },
        .{ .key = "SOURCEDESCRIPTION", .value = "STM32" },
    };
    const rec = evidence.EvidenceRecord{
        .artifact_kind = .altium_pcbdoc,
        .source_path = "",
        .scope_kind = .component,
        .scope_identifier = "U2",
        .display_name = "STM32",
        .properties = &props,
        .matched_requirement_ids = &.{},
        .provenance = .{
            .storage_name = "Components6",
            .stream_name = "Data",
            .record_index = 0,
            .extraction_method = .altium_pipe_record,
        },
    };
    try std.testing.expectEqual(UsefulnessClass.reportable, classifyRecord(rec));
}

test "classifyRecord promotes useful schdoc document evidence" {
    const props = [_]evidence.Property{
        .{ .key = "Author", .value = "Vinicius" },
        .{ .key = "NAME", .value = "Author" },
        .{ .key = "TEXT", .value = "Vinicius" },
    };
    const rec = evidence.EvidenceRecord{
        .artifact_kind = .altium_schdoc,
        .source_path = "",
        .scope_kind = .document,
        .scope_identifier = "ABC",
        .display_name = "Author",
        .properties = &props,
        .matched_requirement_ids = &.{},
        .provenance = .{
            .storage_name = "",
            .stream_name = "FileHeader",
            .record_index = 0,
            .extraction_method = .altium_schdoc_file_header_record,
        },
    };
    try std.testing.expectEqual(UsefulnessClass.reportable, classifyRecord(rec));
}

test "fixture evaluations satisfy golden expectations" {
    const allocator = std.testing.allocator;
    const fixture_paths = [_][]const []const u8{
        &.{ "altium", "STM32_PCB_Design.PcbDoc" },
        &.{ "altium", "SpiralTest.PcbDoc" },
        &.{ "altium", "sch.SchDoc" },
        &.{ "altium", "TopLevel_2Layer.SchDoc" },
    };

    for (fixture_paths) |parts| {
        const path = try sample_probe.fixturePath(allocator, parts);
        defer allocator.free(path);

        const records = try altium.extractAuto(path, .{}, allocator);
        defer altium.freeRecords(records, allocator);

        const det = try detect.detectFile(path, allocator);
        const summary = try evaluateExtracted(path, det.kind, records, allocator);
        defer freeEvaluationSummary(summary, allocator);

        try std.testing.expect(summary.useful_records > 0);
        try std.testing.expectEqual(@as(usize, 0), summary.missing_expected.len);
    }
}

test "extractReportable returns subset of extractAuto" {
    const allocator = std.testing.allocator;
    const path = try sample_probe.fixturePath(allocator, &.{ "altium", "STM32_PCB_Design.PcbDoc" });
    defer allocator.free(path);

    const all_records = try altium.extractAuto(path, .{}, allocator);
    defer altium.freeRecords(all_records, allocator);

    const reportable = try altium.extractReportable(path, .{}, allocator);
    defer altium.freeRecords(reportable, allocator);

    try std.testing.expect(reportable.len > 0);
    try std.testing.expect(reportable.len <= all_records.len);
    for (reportable) |record| {
        try std.testing.expectEqual(UsefulnessClass.reportable, classifyRecord(record));
    }
}
