const std = @import("std");
const base_diagnostics = @import("diagnostics.zig");
const parse = @import("parse.zig");
const reqif_types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const ProjectionProfileId = enum {
    doors,
    polarion,
};

pub const ProjectionStatus = enum {
    projected,
    rejected,
};

pub const ProjectionDiagnostic = struct {
    severity: base_diagnostics.DiagnosticSeverity,
    code: []const u8,
    context_identifier: ?[]const u8 = null,
    message: []const u8,
};

pub const AssertionProvenance = struct {
    profile: ProjectionProfileId,
    spec_object_identifier: []const u8,
    spec_object_type_name: ?[]const u8 = null,
    req_id_attribute_name: []const u8,
    text_attribute_name: []const u8,
    section_attribute_name: ?[]const u8 = null,
};

pub const ProjectedAssertion = struct {
    req_id: []const u8,
    section: ?[]const u8 = null,
    text: []const u8,
    normalized_text: []const u8,
    parse_status: []const u8,
    occurrence_count: usize,
    provenance: AssertionProvenance,
};

pub const ProjectedBundle = struct {
    source_name: ?[]const u8 = null,
    specification_identifier: []const u8,
    specification_name: ?[]const u8 = null,
    assertions: []const ProjectedAssertion,
};

pub const ProjectionResult = struct {
    profile: ProjectionProfileId,
    status: ProjectionStatus,
    bundles: []const ProjectedBundle,
    diagnostics: []const ProjectionDiagnostic,
};

const ProjectionCollector = struct {
    allocator: Allocator,
    items: std.ArrayList(ProjectionDiagnostic) = .empty,

    fn init(allocator: Allocator) ProjectionCollector {
        return .{ .allocator = allocator };
    }

    fn add(
        self: *ProjectionCollector,
        severity: base_diagnostics.DiagnosticSeverity,
        code: []const u8,
        context_identifier: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.items.append(self.allocator, .{
            .severity = severity,
            .code = try self.allocator.dupe(u8, code),
            .context_identifier = try dupOptional(self.allocator, context_identifier),
            .message = try std.fmt.allocPrint(self.allocator, fmt, args),
        });
    }

    fn fromParse(self: *ProjectionCollector, diagnostics: []const base_diagnostics.Diagnostic) !void {
        for (diagnostics) |item| {
            try self.items.append(self.allocator, .{
                .severity = item.severity,
                .code = try self.allocator.dupe(u8, switch (item.severity) {
                    .warning => "parse_warning",
                    .@"error" => "parse_error",
                }),
                .context_identifier = try dupOptional(self.allocator, item.context_identifier),
                .message = try self.allocator.dupe(u8, item.message),
            });
        }
    }

    fn toOwnedSlice(self: *ProjectionCollector) ![]const ProjectionDiagnostic {
        return self.items.toOwnedSlice(self.allocator);
    }
};

const NamedSlot = struct {
    count: usize = 0,
    value: ?[]const u8 = null,
};

const DoorsNames = struct {
    const req_id = "ReqIF.ForeignID";
    const text = "ReqIF.Text";
    const section = "ReqIF.ChapterName";
    const tag = "Tag:Requirement";
};

const PolarionNames = struct {
    const requirement_type = "Software Requirement";
    const req_id = "ReqIF.ForeignID";
    const text = "ReqIF.Text";
    const section = "ReqIF.ChapterName";
    const known_non_requirement_types = [_][]const u8{
        "Heading",
        "Document",
        "Flex QMS document",
        "Applicable Standard",
    };
};

pub fn projectReqifBytes(
    allocator: Allocator,
    xml_bytes: []const u8,
    profile: ProjectionProfileId,
) !ProjectionResult {
    const parsed = try parse.parseReqifBytes(allocator, xml_bytes);
    return projectFromParseResult(allocator, parsed, profile);
}

pub fn projectReqifzBytes(
    allocator: Allocator,
    zip_bytes: []const u8,
    profile: ProjectionProfileId,
) !ProjectionResult {
    const parsed = try parse.parseReqifzBytes(allocator, zip_bytes);
    return projectFromParseResult(allocator, parsed, profile);
}

pub fn projectReqifFile(
    allocator: Allocator,
    path: []const u8,
    profile: ProjectionProfileId,
) !ProjectionResult {
    const parsed = try parse.parseReqifFile(allocator, path);
    return projectFromParseResult(allocator, parsed, profile);
}

pub fn projectReqifzFile(
    allocator: Allocator,
    path: []const u8,
    profile: ProjectionProfileId,
) !ProjectionResult {
    const parsed = try parse.parseReqifzFile(allocator, path);
    return projectFromParseResult(allocator, parsed, profile);
}

pub fn projectFromParseResult(
    allocator: Allocator,
    parsed: reqif_types.ParseResult,
    profile: ProjectionProfileId,
) !ProjectionResult {
    var collector = ProjectionCollector.init(allocator);
    try collector.fromParse(parsed.diagnostics);

    var bundle_list: std.ArrayList(ProjectedBundle) = .empty;
    var seen_req_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen_req_ids.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen_req_ids.deinit();
    }
    var rejected = false;
    var projected_assertions: usize = 0;

    for (parsed.bundles) |bundle| {
        const projected_bundle = switch (profile) {
            .doors => try projectDoorsBundle(allocator, bundle, &collector, &seen_req_ids, &rejected),
            .polarion => try projectPolarionBundle(allocator, bundle, &collector, &seen_req_ids, &rejected),
        };
        if (projected_bundle) |value| {
            projected_assertions += value.assertions.len;
            try bundle_list.append(allocator, value);
        }
    }

    if (parsed.bundles.len == 0 or projected_assertions == 0) {
        rejected = true;
        try collector.add(
            .@"error",
            "profile_not_applicable",
            null,
            "profile '{s}' found no projectable requirement assertions",
            .{@tagName(profile)},
        );
    }

    return .{
        .profile = profile,
        .status = if (rejected) .rejected else .projected,
        .bundles = if (rejected) &.{} else try bundle_list.toOwnedSlice(allocator),
        .diagnostics = try collector.toOwnedSlice(),
    };
}

fn projectDoorsBundle(
    allocator: Allocator,
    bundle: reqif_types.Bundle,
    collector: *ProjectionCollector,
    seen_req_ids: *std.StringHashMap(void),
    rejected: *bool,
) !?ProjectedBundle {
    const referenced_ids = try collectHierarchyRefs(allocator, bundle.specification.children);
    defer allocator.free(referenced_ids);
    if (referenced_ids.len == 0) return null;

    var assertions: std.ArrayList(ProjectedAssertion) = .empty;
    var eligible_type_seen = false;

    for (referenced_ids) |object_ref| {
        const spec_object = findSpecObject(bundle.spec_objects, object_ref) orelse {
            rejected.* = true;
            try collector.add(
                .@"error",
                "missing_spec_object_reference",
                bundle.specification.identifier,
                "specification references missing SPEC-OBJECT '{s}'",
                .{object_ref},
            );
            continue;
        };
        const object_type = findSpecObjectType(bundle.type_system.spec_object_types, spec_object.type_identifier);
        const type_is_eligible = if (object_type) |value|
            typeHasAttributes(value, &.{ DoorsNames.req_id, DoorsNames.text, DoorsNames.tag })
        else
            false;
        if (!type_is_eligible) continue;

        eligible_type_seen = true;

        const req_id_slot = findNamedSlot(spec_object.attribute_values, DoorsNames.req_id);
        const text_slot = findNamedSlot(spec_object.attribute_values, DoorsNames.text);
        const section_slot = findNamedSlot(spec_object.attribute_values, DoorsNames.section);
        const tag_slot = findNamedSlot(spec_object.attribute_values, DoorsNames.tag);

        if (req_id_slot.count > 1 or text_slot.count > 1 or tag_slot.count > 1 or section_slot.count > 1) {
            rejected.* = true;
            try collector.add(
                .@"error",
                "multiple_candidate_values",
                spec_object.identifier,
                "SPEC-OBJECT '{s}' has multiple candidate values for projected fields",
                .{spec_object.identifier},
            );
            continue;
        }

        const req_id = requiredField(req_id_slot.value, spec_object.identifier, DoorsNames.req_id, collector, rejected) orelse continue;
        const text = requiredField(text_slot.value, spec_object.identifier, DoorsNames.text, collector, rejected) orelse continue;
        const tag = requiredField(tag_slot.value, spec_object.identifier, DoorsNames.tag, collector, rejected) orelse continue;

        if (!isAllowedDoorsRequirementTag(tag)) {
            rejected.* = true;
            try collector.add(
                .@"error",
                "unsupported_requirement_tag",
                spec_object.identifier,
                "SPEC-OBJECT '{s}' uses unsupported Tag:Requirement value '{s}'",
                .{ spec_object.identifier, tag },
            );
            continue;
        }

        if (seenReqId(seen_req_ids, req_id)) {
            rejected.* = true;
            try collector.add(
                .@"error",
                "duplicate_projected_req_id",
                spec_object.identifier,
                "duplicate projected requirement id '{s}'",
                .{req_id},
            );
            continue;
        }
        try seen_req_ids.put(try allocator.dupe(u8, req_id), {});

        try assertions.append(allocator, .{
            .req_id = try allocator.dupe(u8, req_id),
            .section = if (section_slot.value) |value| try allocator.dupe(u8, value) else null,
            .text = try allocator.dupe(u8, text),
            .normalized_text = try normalizeText(text, allocator),
            .parse_status = try allocator.dupe(u8, "ok"),
            .occurrence_count = 1,
            .provenance = .{
                .profile = .doors,
                .spec_object_identifier = try allocator.dupe(u8, spec_object.identifier),
                .spec_object_type_name = try dupOptional(allocator, spec_object.type_name),
                .req_id_attribute_name = try allocator.dupe(u8, DoorsNames.req_id),
                .text_attribute_name = try allocator.dupe(u8, DoorsNames.text),
                .section_attribute_name = try allocator.dupe(u8, DoorsNames.section),
            },
        });
    }

    if (!eligible_type_seen) return null;

    return .{
        .source_name = try dupOptional(allocator, bundle.source_name),
        .specification_identifier = try allocator.dupe(u8, bundle.specification.identifier),
        .specification_name = try dupOptional(allocator, bundle.specification.long_name),
        .assertions = try assertions.toOwnedSlice(allocator),
    };
}

fn projectPolarionBundle(
    allocator: Allocator,
    bundle: reqif_types.Bundle,
    collector: *ProjectionCollector,
    seen_req_ids: *std.StringHashMap(void),
    rejected: *bool,
) !?ProjectedBundle {
    const referenced_ids = try collectHierarchyRefs(allocator, bundle.specification.children);
    defer allocator.free(referenced_ids);
    if (referenced_ids.len == 0) return null;

    var assertions: std.ArrayList(ProjectedAssertion) = .empty;
    var requirement_seen = false;

    for (referenced_ids) |object_ref| {
        const spec_object = findSpecObject(bundle.spec_objects, object_ref) orelse {
            rejected.* = true;
            try collector.add(
                .@"error",
                "missing_spec_object_reference",
                bundle.specification.identifier,
                "specification references missing SPEC-OBJECT '{s}'",
                .{object_ref},
            );
            continue;
        };
        const type_name = spec_object.type_name orelse "";
        const object_type = findSpecObjectType(bundle.type_system.spec_object_types, spec_object.type_identifier);
        const exposes_req_id_and_text = if (object_type) |value|
            typeHasAttributes(value, &.{ PolarionNames.req_id, PolarionNames.text })
        else
            false;

        if (std.mem.eql(u8, type_name, PolarionNames.requirement_type)) {
            requirement_seen = true;

            const req_id_slot = findNamedSlot(spec_object.attribute_values, PolarionNames.req_id);
            const text_slot = findNamedSlot(spec_object.attribute_values, PolarionNames.text);
            const section_slot = findNamedSlot(spec_object.attribute_values, PolarionNames.section);

            if (req_id_slot.count > 1 or text_slot.count > 1 or section_slot.count > 1) {
                rejected.* = true;
                try collector.add(
                    .@"error",
                    "multiple_candidate_values",
                    spec_object.identifier,
                    "SPEC-OBJECT '{s}' has multiple candidate values for projected fields",
                    .{spec_object.identifier},
                );
                continue;
            }

            const req_id = requiredField(req_id_slot.value, spec_object.identifier, PolarionNames.req_id, collector, rejected) orelse continue;
            const text = requiredField(text_slot.value, spec_object.identifier, PolarionNames.text, collector, rejected) orelse continue;

            if (seenReqId(seen_req_ids, req_id)) {
                rejected.* = true;
                try collector.add(
                    .@"error",
                    "duplicate_projected_req_id",
                    spec_object.identifier,
                    "duplicate projected requirement id '{s}'",
                    .{req_id},
                );
                continue;
            }
            try seen_req_ids.put(try allocator.dupe(u8, req_id), {});

            try assertions.append(allocator, .{
                .req_id = try allocator.dupe(u8, req_id),
                .section = if (section_slot.value) |value| try allocator.dupe(u8, value) else null,
                .text = try allocator.dupe(u8, text),
                .normalized_text = try normalizeText(text, allocator),
                .parse_status = try allocator.dupe(u8, "ok"),
                .occurrence_count = 1,
                .provenance = .{
                    .profile = .polarion,
                    .spec_object_identifier = try allocator.dupe(u8, spec_object.identifier),
                    .spec_object_type_name = try dupOptional(allocator, spec_object.type_name),
                    .req_id_attribute_name = try allocator.dupe(u8, PolarionNames.req_id),
                    .text_attribute_name = try allocator.dupe(u8, PolarionNames.text),
                    .section_attribute_name = try allocator.dupe(u8, PolarionNames.section),
                },
            });
            continue;
        }

        if (isKnownPolarionNonRequirementType(type_name)) continue;

        if (exposes_req_id_and_text) {
            rejected.* = true;
            try collector.add(
                .@"error",
                "ambiguous_requirement_object_type",
                spec_object.identifier,
                "SPEC-OBJECT '{s}' uses unsupported requirement-like type '{s}'",
                .{ spec_object.identifier, type_name },
            );
        }
    }

    if (!requirement_seen and assertions.items.len == 0) return null;

    return .{
        .source_name = try dupOptional(allocator, bundle.source_name),
        .specification_identifier = try allocator.dupe(u8, bundle.specification.identifier),
        .specification_name = try dupOptional(allocator, bundle.specification.long_name),
        .assertions = try assertions.toOwnedSlice(allocator),
    };
}

fn requiredField(
    value: ?[]const u8,
    object_id: []const u8,
    field_name: []const u8,
    collector: *ProjectionCollector,
    rejected: *bool,
) ?[]const u8 {
    const trimmed = trimNonEmpty(value) orelse {
        rejected.* = true;
        collector.add(
            .@"error",
            "missing_required_field",
            object_id,
            "SPEC-OBJECT '{s}' is missing required field '{s}'",
            .{ object_id, field_name },
        ) catch {};
        return null;
    };
    return trimmed;
}

fn collectHierarchyRefs(
    allocator: Allocator,
    hierarchies: []const reqif_types.SpecHierarchy,
) ![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    for (hierarchies) |hierarchy| {
        try appendHierarchyRefs(&refs, allocator, hierarchy);
    }
    return refs.toOwnedSlice(allocator);
}

fn appendHierarchyRefs(
    refs: *std.ArrayList([]const u8),
    allocator: Allocator,
    hierarchy: reqif_types.SpecHierarchy,
) !void {
    if (hierarchy.object_ref) |object_ref| {
        try refs.append(allocator, object_ref);
    }
    for (hierarchy.children) |child| {
        try appendHierarchyRefs(refs, allocator, child);
    }
}

fn findSpecObject(
    spec_objects: []const reqif_types.SpecObject,
    identifier: []const u8,
) ?reqif_types.SpecObject {
    for (spec_objects) |spec_object| {
        if (std.mem.eql(u8, spec_object.identifier, identifier)) return spec_object;
    }
    return null;
}

fn findSpecObjectType(
    object_types: []const reqif_types.SpecObjectType,
    identifier: ?[]const u8,
) ?reqif_types.SpecObjectType {
    const id = identifier orelse return null;
    for (object_types) |object_type| {
        if (std.mem.eql(u8, object_type.identifier, id)) return object_type;
    }
    return null;
}

fn findNamedSlot(
    values: []const reqif_types.AttributeValue,
    definition_name: []const u8,
) NamedSlot {
    var slot: NamedSlot = .{};
    for (values) |value| {
        const candidate = value.definition_name orelse continue;
        if (!std.mem.eql(u8, candidate, definition_name)) continue;
        slot.count += 1;
        slot.value = trimNonEmpty(value.text);
    }
    return slot;
}

fn trimNonEmpty(value: ?[]const u8) ?[]const u8 {
    const slice = value orelse return null;
    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn typeHasAttributes(object_type: reqif_types.SpecObjectType, names: []const []const u8) bool {
    for (names) |name| {
        var found = false;
        for (object_type.attribute_definitions) |attr| {
            const long_name = attr.long_name orelse continue;
            if (std.mem.eql(u8, long_name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn isAllowedDoorsRequirementTag(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "requirement");
}

fn isKnownPolarionNonRequirementType(type_name: []const u8) bool {
    for (PolarionNames.known_non_requirement_types) |name| {
        if (std.mem.eql(u8, type_name, name)) return true;
    }
    return false;
}

fn seenReqId(map: *std.StringHashMap(void), req_id: []const u8) bool {
    return map.contains(req_id);
}

fn dupOptional(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

fn normalizeText(text: []const u8, allocator: Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var last_space = false;
    for (text) |c| {
        const lowered = std.ascii.toLower(c);
        if (std.ascii.isWhitespace(lowered)) {
            if (!last_space and buf.items.len > 0) {
                try buf.append(allocator, ' ');
                last_space = true;
            }
            continue;
        }
        last_space = false;
        try buf.append(allocator, lowered);
    }
    return allocator.dupe(u8, std.mem.trimRight(u8, buf.items, " "));
}

const testing = std.testing;

fn loadFixture(allocator: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
}

fn expectRejectedWithCode(result: ProjectionResult, code: []const u8) !void {
    try testing.expectEqual(ProjectionStatus.rejected, result.status);
    var found = false;
    for (result.diagnostics) |diag| {
        if (std.mem.eql(u8, diag.code, code)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "projection API exposes explicit profile result and rejection behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif/01_minimal_reqif/sample.reqif");
    const parsed = try parse.parseReqifBytes(alloc, bytes);
    const result = try projectFromParseResult(alloc, parsed, .polarion);

    try testing.expectEqual(ProjectionProfileId.polarion, result.profile);
    try testing.expectEqual(ProjectionStatus.rejected, result.status);
    try testing.expectEqual(@as(usize, 0), result.bundles.len);
    try testing.expect(result.diagnostics.len > 0);
}

test "synthetic polarion fixture projects software requirements only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_polarion_accept.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try testing.expectEqual(ProjectionStatus.projected, result.status);
    try testing.expect(result.bundles.len >= 1);
    try testing.expect(result.bundles[0].assertions.len > 0);
    try testing.expectEqualStrings("ReqIF.ForeignID", result.bundles[0].assertions[0].provenance.req_id_attribute_name);
    try testing.expectEqualStrings("ReqIF.Text", result.bundles[0].assertions[0].provenance.text_attribute_name);

    var found_requirement = false;
    for (result.bundles[0].assertions) |assertion| {
        try testing.expect(assertion.section == null or assertion.section.?.len > 0);
        try testing.expect(assertion.text.len > 0);
        try testing.expect(assertion.req_id.len > 0);
        try testing.expectEqualStrings("ok", assertion.parse_status);
        if (std.mem.eql(u8, assertion.text, "The system shall encrypt data at rest.")) found_requirement = true;
        try testing.expect(assertion.provenance.spec_object_type_name != null);
        try testing.expectEqualStrings("Software Requirement", assertion.provenance.spec_object_type_name.?);
    }
    try testing.expect(found_requirement);
}

test "real polarion fixture rejects duplicate projected requirement ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/Polarion_01_anonimized_example/sample.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try expectRejectedWithCode(result, "duplicate_projected_req_id");
}

test "real doors fixture rejects when profile requirements are not satisfied" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/02_example_from_a_user/sample.reqif");
    const result = try projectReqifBytes(alloc, bytes, .doors);

    try expectRejectedWithCode(result, "profile_not_applicable");
}

test "synthetic doors fixture projects stable ids texts sections and provenance" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/doors_projection.reqif");
    const result = try projectReqifBytes(alloc, bytes, .doors);

    try testing.expectEqual(ProjectionStatus.projected, result.status);
    try testing.expectEqual(@as(usize, 1), result.bundles.len);
    try testing.expectEqual(@as(usize, 2), result.bundles[0].assertions.len);
    try testing.expectEqualStrings("REQ-001", result.bundles[0].assertions[0].req_id);
    try testing.expectEqualStrings("System Behavior", result.bundles[0].assertions[0].section.?);
    try testing.expectEqualStrings("The device shall start.", result.bundles[0].assertions[0].text);
    try testing.expectEqualStrings("the device shall start.", result.bundles[0].assertions[0].normalized_text);
    try testing.expectEqualStrings("ReqIF.ChapterName", result.bundles[0].assertions[0].provenance.section_attribute_name.?);
}

test "rmf fixture rejects projection with profile not applicable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/org.eclipse.rmf_01_specRelationTest/sample.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try expectRejectedWithCode(result, "profile_not_applicable");
}

test "sparx fixture rejects projection with profile not applicable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/SparxSystems_Enterprise_Architect_8.0_01_example/sample.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try expectRejectedWithCode(result, "profile_not_applicable");
}

test "duplicate projected requirement ids reject whole document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_duplicate_req_id.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try expectRejectedWithCode(result, "duplicate_projected_req_id");
}

test "missing projected text rejects whole document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_missing_text.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try expectRejectedWithCode(result, "missing_required_field");
}

test "missing projected requirement id rejects whole document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_missing_req_id.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try expectRejectedWithCode(result, "missing_required_field");
}

test "unsupported doors requirement tag rejects whole document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_doors_bad_tag.reqif");
    const result = try projectReqifBytes(alloc, bytes, .doors);

    try expectRejectedWithCode(result, "unsupported_requirement_tag");
}

test "unknown polarion requirement like type rejects whole document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_polarion_unknown_type.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try expectRejectedWithCode(result, "ambiguous_requirement_object_type");
}

test "multi specification ambiguity rejects whole document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_multi_spec_ambiguous.reqif");
    const result = try projectReqifBytes(alloc, bytes, .polarion);

    try testing.expectEqual(ProjectionStatus.rejected, result.status);
    try testing.expectEqual(@as(usize, 0), result.bundles.len);
}

test "project from parse result matches direct byte projection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/projection_polarion_accept.reqif");
    const parsed = try parse.parseReqifBytes(alloc, bytes);
    const from_parse = try projectFromParseResult(alloc, parsed, .polarion);
    const from_bytes = try projectReqifBytes(alloc, bytes, .polarion);

    try testing.expectEqual(from_parse.status, from_bytes.status);
    try testing.expectEqual(from_parse.bundles.len, from_bytes.bundles.len);
    try testing.expectEqual(from_parse.bundles[0].assertions.len, from_bytes.bundles[0].assertions.len);
    try testing.expectEqualStrings(from_parse.bundles[0].assertions[0].req_id, from_bytes.bundles[0].assertions[0].req_id);
}

test "project reqifz wrapper matches parse then project" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqifz/01_reqifz_with_one_reqif_and_one_attachments/sample.reqifz");
    const parsed = try parse.parseReqifzBytes(alloc, bytes);
    const from_parse = try projectFromParseResult(alloc, parsed, .polarion);
    const from_bytes = try projectReqifzBytes(alloc, bytes, .polarion);

    try testing.expectEqual(from_parse.status, from_bytes.status);
    try testing.expectEqual(from_parse.bundles.len, from_bytes.bundles.len);
}
