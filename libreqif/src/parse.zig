const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const types = @import("types.zig");
const xhtml = @import("xhtml.zig");
const xml = @import("xml.zig");
const zip = @import("zip.zig");

const Allocator = std.mem.Allocator;

pub fn parseReqifBytes(allocator: Allocator, xml_bytes: []const u8) !types.ParseResult {
    var collector = diagnostics.Collector.init(allocator);
    const bundles = try parseReqifDocument(allocator, xml_bytes, null, &collector);
    return .{
        .bundles = bundles,
        .diagnostics = try collector.toOwnedSlice(),
    };
}

pub fn parseReqifzBytes(allocator: Allocator, zip_bytes: []const u8) !types.ParseResult {
    var collector = diagnostics.Collector.init(allocator);
    var bundle_list: std.ArrayList(types.Bundle) = .empty;

    const entries = try zip.extractReqifEntries(allocator, zip_bytes);
    for (entries) |entry| {
        const bundles = try parseReqifDocument(allocator, entry.bytes, entry.name, &collector);
        try bundle_list.appendSlice(allocator, bundles);
    }

    return .{
        .bundles = try bundle_list.toOwnedSlice(allocator),
        .diagnostics = try collector.toOwnedSlice(),
    };
}

pub fn parseReqifFile(allocator: Allocator, path: []const u8) !types.ParseResult {
    const xml_bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes);
    defer allocator.free(xml_bytes);
    return parseReqifBytes(allocator, xml_bytes);
}

pub fn parseReqifzFile(allocator: Allocator, path: []const u8) !types.ParseResult {
    const zip_bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes);
    defer allocator.free(zip_bytes);
    return parseReqifzBytes(allocator, zip_bytes);
}

const max_file_bytes = 64 * 1024 * 1024;

const RawHeader = struct {
    identifier: ?[]const u8 = null,
    creation_time: ?[]const u8 = null,
    repository_id: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    title: ?[]const u8 = null,
    reqif_tool_id: ?[]const u8 = null,
    source_tool_id: ?[]const u8 = null,
    reqif_version: ?[]const u8 = null,
};

const RawEnumValue = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    embedded_values: std.ArrayList(types.EmbeddedValue) = .empty,
};

const RawDatatype = struct {
    kind: types.ValueKind,
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    enum_values: std.ArrayList(*RawEnumValue) = .empty,
};

const RawAttributeDefinition = struct {
    kind: types.ValueKind,
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    datatype_ref: ?[]const u8 = null,
    multi_valued: bool = false,
};

const RawSpecObjectType = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    attribute_definitions: std.ArrayList(*RawAttributeDefinition) = .empty,
};

const RawSpecRelationType = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    attribute_definitions: std.ArrayList(*RawAttributeDefinition) = .empty,
};

const RawSpecificationType = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    attribute_definitions: std.ArrayList(*RawAttributeDefinition) = .empty,
};

const RawAttributeValue = struct {
    kind: types.ValueKind,
    definition_ref: ?[]const u8 = null,
    raw_text: ?[]const u8 = null,
    enum_value_refs: std.ArrayList([]const u8) = .empty,
};

const RawSpecObject = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    last_change: ?[]const u8 = null,
    type_ref: ?[]const u8 = null,
    values: std.ArrayList(*RawAttributeValue) = .empty,
};

const RawSpecRelation = struct {
    identifier: []const u8,
    source_ref: ?[]const u8 = null,
    target_ref: ?[]const u8 = null,
    type_ref: ?[]const u8 = null,
    values: std.ArrayList(*RawAttributeValue) = .empty,
};

const RawHierarchy = struct {
    identifier: ?[]const u8 = null,
    long_name: ?[]const u8 = null,
    last_change: ?[]const u8 = null,
    object_ref: ?[]const u8 = null,
    children: std.ArrayList(*RawHierarchy) = .empty,
};

const RawSpecification = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    last_change: ?[]const u8 = null,
    type_ref: ?[]const u8 = null,
    values: std.ArrayList(*RawAttributeValue) = .empty,
    hierarchies: std.ArrayList(*RawHierarchy) = .empty,
};

const Parser = struct {
    allocator: Allocator,
    source_name: ?[]const u8,
    diags: *diagnostics.Collector,

    header: RawHeader = .{},

    datatypes: std.ArrayList(*RawDatatype) = .empty,
    datatype_by_id: std.StringHashMap(*RawDatatype),
    enum_value_by_id: std.StringHashMap(*RawEnumValue),
    attr_def_by_id: std.StringHashMap(*RawAttributeDefinition),
    spec_object_types: std.ArrayList(*RawSpecObjectType) = .empty,
    spec_object_type_by_id: std.StringHashMap(*RawSpecObjectType),
    spec_relation_types: std.ArrayList(*RawSpecRelationType) = .empty,
    spec_relation_type_by_id: std.StringHashMap(*RawSpecRelationType),
    specification_types: std.ArrayList(*RawSpecificationType) = .empty,
    specification_type_by_id: std.StringHashMap(*RawSpecificationType),
    spec_objects: std.ArrayList(*RawSpecObject) = .empty,
    spec_object_by_id: std.StringHashMap(*RawSpecObject),
    spec_relations: std.ArrayList(*RawSpecRelation) = .empty,
    specifications: std.ArrayList(*RawSpecification) = .empty,

    path: std.ArrayList([]const u8) = .empty,
    hierarchy_stack: std.ArrayList(*RawHierarchy) = .empty,

    current_datatype: ?*RawDatatype = null,
    current_enum_value: ?*RawEnumValue = null,
    current_attr_def: ?*RawAttributeDefinition = null,
    current_spec_object_type: ?*RawSpecObjectType = null,
    current_spec_relation_type: ?*RawSpecRelationType = null,
    current_specification_type: ?*RawSpecificationType = null,
    current_spec_object: ?*RawSpecObject = null,
    current_spec_relation: ?*RawSpecRelation = null,
    current_specification: ?*RawSpecification = null,
    current_value: ?*RawAttributeValue = null,

    skip_default_value_depth: usize = 0,
    root_seen: bool = false,

    fn init(allocator: Allocator, source_name: ?[]const u8, diags: *diagnostics.Collector) Parser {
        return .{
            .allocator = allocator,
            .source_name = source_name,
            .diags = diags,
            .datatype_by_id = std.StringHashMap(*RawDatatype).init(allocator),
            .enum_value_by_id = std.StringHashMap(*RawEnumValue).init(allocator),
            .attr_def_by_id = std.StringHashMap(*RawAttributeDefinition).init(allocator),
            .spec_object_type_by_id = std.StringHashMap(*RawSpecObjectType).init(allocator),
            .spec_relation_type_by_id = std.StringHashMap(*RawSpecRelationType).init(allocator),
            .specification_type_by_id = std.StringHashMap(*RawSpecificationType).init(allocator),
            .spec_object_by_id = std.StringHashMap(*RawSpecObject).init(allocator),
        };
    }

    fn parse(self: *Parser, xml_bytes: []const u8) ![]const types.Bundle {
        var tokenizer = xml.Tokenizer.init(self.allocator, xml_bytes);
        defer tokenizer.deinit();

        while (try tokenizer.next()) |token| {
            switch (token) {
                .start => |start| {
                    try self.handleStart(&tokenizer, start);
                    if (start.self_closing) self.handleEnd(xml.localName(start.name));
                },
                .end => |name| self.handleEnd(xml.localName(name)),
                .text => |text| try self.handleText(text),
            }
        }

        if (!self.root_seen) return error.UnsupportedRoot;
        if (self.path.items.len != 0) return error.InvalidXml;

        return self.resolveBundles();
    }

    fn handleStart(self: *Parser, tokenizer: *xml.Tokenizer, start: xml.StartTag) !void {
        const local = xml.localName(start.name);
        try self.path.append(self.allocator, local);

        if (std.mem.eql(u8, local, "REQ-IF")) {
            const namespace = xml.attr(start, "xmlns") orelse return error.UnsupportedRoot;
            if (!std.mem.eql(u8, namespace, "http://www.omg.org/spec/ReqIF/20110401/reqif.xsd") and
                !std.mem.eql(u8, namespace, "http://www.omg.org/spec/ReqIF/20101201"))
            {
                return error.UnsupportedRoot;
            }
            self.root_seen = true;
        }

        if (std.mem.eql(u8, local, "DEFAULT-VALUE")) {
            self.skip_default_value_depth += 1;
            return;
        }
        if (self.skip_default_value_depth > 0) return;

        if (std.mem.eql(u8, local, "REQ-IF-HEADER")) {
            self.header.identifier = try self.dupOptionalRaw(xml.attr(start, "IDENTIFIER"));
            return;
        }

        if (kindFromDatatypeTag(local)) |kind| {
            const datatype = try self.allocator.create(RawDatatype);
            datatype.* = .{
                .kind = kind,
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
            };
            try self.datatypes.append(self.allocator, datatype);
            try self.datatype_by_id.put(datatype.identifier, datatype);
            self.current_datatype = datatype;
            return;
        }

        if (std.mem.eql(u8, local, "ENUM-VALUE")) {
            const enum_value = try self.allocator.create(RawEnumValue);
            enum_value.* = .{
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
            };
            if (self.current_datatype) |datatype| {
                try datatype.enum_values.append(self.allocator, enum_value);
                try self.enum_value_by_id.put(enum_value.identifier, enum_value);
            }
            self.current_enum_value = enum_value;
            return;
        }

        if (std.mem.eql(u8, local, "EMBEDDED-VALUE")) {
            if (self.current_enum_value) |enum_value| {
                try enum_value.embedded_values.append(self.allocator, .{
                    .key = try self.dupRaw(xml.attr(start, "KEY") orelse ""),
                    .other_content = try self.dupOptionalText(xml.attr(start, "OTHER-CONTENT")),
                });
            }
            return;
        }

        if (std.mem.eql(u8, local, "SPEC-OBJECT-TYPE")) {
            const raw = try self.allocator.create(RawSpecObjectType);
            raw.* = .{
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
            };
            try self.spec_object_types.append(self.allocator, raw);
            try self.spec_object_type_by_id.put(raw.identifier, raw);
            self.current_spec_object_type = raw;
            return;
        }
        if (std.mem.eql(u8, local, "SPEC-RELATION-TYPE")) {
            const raw = try self.allocator.create(RawSpecRelationType);
            raw.* = .{
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
            };
            try self.spec_relation_types.append(self.allocator, raw);
            try self.spec_relation_type_by_id.put(raw.identifier, raw);
            self.current_spec_relation_type = raw;
            return;
        }
        if (std.mem.eql(u8, local, "SPECIFICATION-TYPE")) {
            const raw = try self.allocator.create(RawSpecificationType);
            raw.* = .{
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
            };
            try self.specification_types.append(self.allocator, raw);
            try self.specification_type_by_id.put(raw.identifier, raw);
            self.current_specification_type = raw;
            return;
        }

        if (kindFromAttributeDefinitionTag(local)) |kind| {
            const raw = try self.allocator.create(RawAttributeDefinition);
            raw.* = .{
                .kind = kind,
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
                .multi_valued = parseBoolAttr(xml.attr(start, "MULTI-VALUED")),
            };
            try self.attr_def_by_id.put(raw.identifier, raw);
            if (self.current_spec_object_type) |owner| {
                try owner.attribute_definitions.append(self.allocator, raw);
            } else if (self.current_spec_relation_type) |owner| {
                try owner.attribute_definitions.append(self.allocator, raw);
            } else if (self.current_specification_type) |owner| {
                try owner.attribute_definitions.append(self.allocator, raw);
            }
            self.current_attr_def = raw;
            return;
        }

        if (std.mem.eql(u8, local, "SPEC-OBJECT")) {
            const raw = try self.allocator.create(RawSpecObject);
            raw.* = .{
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
                .description = try self.dupOptionalText(xml.attr(start, "DESC")),
                .last_change = try self.dupOptionalRaw(xml.attr(start, "LAST-CHANGE")),
            };
            try self.spec_objects.append(self.allocator, raw);
            try self.spec_object_by_id.put(raw.identifier, raw);
            self.current_spec_object = raw;
            return;
        }

        if (std.mem.eql(u8, local, "SPEC-RELATION")) {
            const raw = try self.allocator.create(RawSpecRelation);
            raw.* = .{
                .identifier = try self.requireIdentifier(start),
            };
            try self.spec_relations.append(self.allocator, raw);
            self.current_spec_relation = raw;
            return;
        }

        if (std.mem.eql(u8, local, "SPECIFICATION")) {
            const raw = try self.allocator.create(RawSpecification);
            raw.* = .{
                .identifier = try self.requireIdentifier(start),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
                .last_change = try self.dupOptionalRaw(xml.attr(start, "LAST-CHANGE")),
            };
            try self.specifications.append(self.allocator, raw);
            self.current_specification = raw;
            return;
        }

        if (std.mem.eql(u8, local, "SPEC-HIERARCHY")) {
            const hierarchy = try self.allocator.create(RawHierarchy);
            hierarchy.* = .{
                .identifier = try self.dupOptionalRaw(xml.attr(start, "IDENTIFIER")),
                .long_name = try self.dupOptionalText(xml.attr(start, "LONG-NAME")),
                .last_change = try self.dupOptionalRaw(xml.attr(start, "LAST-CHANGE")),
            };
            if (self.hierarchy_stack.items.len > 0) {
                try self.hierarchy_stack.items[self.hierarchy_stack.items.len - 1].children.append(self.allocator, hierarchy);
            } else if (self.current_specification) |specification| {
                try specification.hierarchies.append(self.allocator, hierarchy);
            }
            try self.hierarchy_stack.append(self.allocator, hierarchy);
            return;
        }

        if (kindFromAttributeValueTag(local)) |kind| {
            const value = try self.allocator.create(RawAttributeValue);
            value.* = .{
                .kind = kind,
                .raw_text = try self.dupOptionalRaw(xml.attr(start, "THE-VALUE")),
            };
            if (self.current_spec_object) |owner| {
                try owner.values.append(self.allocator, value);
            } else if (self.current_spec_relation) |owner| {
                try owner.values.append(self.allocator, value);
            } else if (self.current_specification) |owner| {
                try owner.values.append(self.allocator, value);
            }
            self.current_value = value;

            if (kind == .xhtml) {
                if (xml.attr(start, "THE-VALUE")) |_| return;
            }
            return;
        }

        if (std.mem.eql(u8, local, "THE-VALUE") and self.current_value != null and self.current_value.?.kind == .xhtml) {
            const raw_inner = try tokenizer.captureRawUntilEnd("THE-VALUE");
            self.current_value.?.raw_text = try self.dupRaw(raw_inner);
            _ = self.path.pop();
            return;
        }
    }

    fn handleText(self: *Parser, raw_text: []const u8) !void {
        if (self.skip_default_value_depth > 0) return;
        if (self.path.items.len == 0) return;
        const trimmed = std.mem.trim(u8, raw_text, " \n\r\t");
        if (trimmed.len == 0) return;

        const current = self.path.items[self.path.items.len - 1];
        const parent = if (self.path.items.len >= 2) self.path.items[self.path.items.len - 2] else "";
        const grandparent = if (self.path.items.len >= 3) self.path.items[self.path.items.len - 3] else "";

        if (std.mem.eql(u8, parent, "REQ-IF-HEADER")) {
            const text = try self.dupText(trimmed);
            if (std.mem.eql(u8, current, "COMMENT")) self.setIfEmpty(&self.header.comment, text)
            else if (std.mem.eql(u8, current, "CREATION-TIME")) self.setIfEmpty(&self.header.creation_time, text)
            else if (std.mem.eql(u8, current, "REPOSITORY-ID")) self.setIfEmpty(&self.header.repository_id, text)
            else if (std.mem.eql(u8, current, "REQ-IF-TOOL-ID")) self.setIfEmpty(&self.header.reqif_tool_id, text)
            else if (std.mem.eql(u8, current, "SOURCE-TOOL-ID")) self.setIfEmpty(&self.header.source_tool_id, text)
            else if (std.mem.eql(u8, current, "TITLE")) self.setIfEmpty(&self.header.title, text)
            else if (std.mem.eql(u8, current, "REQ-IF-VERSION")) self.setIfEmpty(&self.header.reqif_version, text);
            return;
        }

        if (self.current_attr_def != null and std.mem.eql(u8, parent, "TYPE") and std.mem.startsWith(u8, current, "DATATYPE-DEFINITION-")) {
            self.current_attr_def.?.datatype_ref = try self.dupRaw(trimmed);
            return;
        }

        if (self.current_value != null and std.mem.eql(u8, parent, "DEFINITION") and std.mem.startsWith(u8, current, "ATTRIBUTE-DEFINITION-")) {
            self.current_value.?.definition_ref = try self.dupRaw(trimmed);
            return;
        }

        if (self.current_value != null and self.current_value.?.kind == .enumeration and std.mem.eql(u8, parent, "VALUES") and std.mem.eql(u8, current, "ENUM-VALUE-REF")) {
            try self.current_value.?.enum_value_refs.append(self.allocator, try self.dupRaw(trimmed));
            return;
        }

        if (self.current_spec_object != null and std.mem.eql(u8, parent, "TYPE") and std.mem.eql(u8, current, "SPEC-OBJECT-TYPE-REF")) {
            self.current_spec_object.?.type_ref = try self.dupRaw(trimmed);
            return;
        }

        if (self.current_spec_relation != null and std.mem.eql(u8, parent, "TYPE") and std.mem.eql(u8, current, "SPEC-RELATION-TYPE-REF")) {
            self.current_spec_relation.?.type_ref = try self.dupRaw(trimmed);
            return;
        }

        if (self.current_spec_relation != null and std.mem.eql(u8, parent, "SOURCE") and std.mem.eql(u8, current, "SPEC-OBJECT-REF")) {
            self.current_spec_relation.?.source_ref = try self.dupRaw(trimmed);
            return;
        }

        if (self.current_spec_relation != null and std.mem.eql(u8, parent, "TARGET") and std.mem.eql(u8, current, "SPEC-OBJECT-REF")) {
            self.current_spec_relation.?.target_ref = try self.dupRaw(trimmed);
            return;
        }

        if (self.current_specification != null and std.mem.eql(u8, parent, "TYPE") and std.mem.eql(u8, current, "SPECIFICATION-TYPE-REF")) {
            self.current_specification.?.type_ref = try self.dupRaw(trimmed);
            return;
        }

        if (self.hierarchy_stack.items.len > 0 and std.mem.eql(u8, parent, "OBJECT") and std.mem.eql(u8, current, "SPEC-OBJECT-REF")) {
            self.hierarchy_stack.items[self.hierarchy_stack.items.len - 1].object_ref = try self.dupRaw(trimmed);
            return;
        }

        _ = grandparent;
    }

    fn handleEnd(self: *Parser, local: []const u8) void {
        if (std.mem.eql(u8, local, "DEFAULT-VALUE")) {
            self.skip_default_value_depth -= 1;
        } else if (self.skip_default_value_depth == 0) {
            if (kindFromDatatypeTag(local) != null) self.current_datatype = null
            else if (std.mem.eql(u8, local, "ENUM-VALUE")) self.current_enum_value = null
            else if (kindFromAttributeDefinitionTag(local) != null) self.current_attr_def = null
            else if (std.mem.eql(u8, local, "SPEC-OBJECT-TYPE")) self.current_spec_object_type = null
            else if (std.mem.eql(u8, local, "SPEC-RELATION-TYPE")) self.current_spec_relation_type = null
            else if (std.mem.eql(u8, local, "SPECIFICATION-TYPE")) self.current_specification_type = null
            else if (std.mem.eql(u8, local, "SPEC-OBJECT")) self.current_spec_object = null
            else if (std.mem.eql(u8, local, "SPEC-RELATION")) self.current_spec_relation = null
            else if (std.mem.eql(u8, local, "SPECIFICATION")) self.current_specification = null
            else if (kindFromAttributeValueTag(local) != null) self.current_value = null
            else if (std.mem.eql(u8, local, "SPEC-HIERARCHY") and self.hierarchy_stack.items.len > 0) _ = self.hierarchy_stack.pop();
        }

        if (self.path.items.len > 0) _ = self.path.pop();
    }

    fn resolveBundles(self: *Parser) ![]const types.Bundle {
        const header = types.Header{
            .identifier = self.header.identifier,
            .creation_time = self.header.creation_time,
            .repository_id = self.header.repository_id,
            .comment = self.header.comment,
            .title = self.header.title,
            .reqif_tool_id = self.header.reqif_tool_id,
            .source_tool_id = self.header.source_tool_id,
            .reqif_version = self.header.reqif_version,
        };

        const type_system = try self.resolveTypeSystem();
        const spec_objects = try self.resolveSpecObjects();
        const spec_relations = try self.resolveSpecRelations();
        const specifications = try self.resolveSpecifications();

        const bundles = try self.allocator.alloc(types.Bundle, specifications.len);
        for (specifications, 0..) |specification, index| {
            bundles[index] = .{
                .source_name = self.source_name,
                .header = header,
                .type_system = type_system,
                .spec_objects = spec_objects,
                .spec_relations = spec_relations,
                .specification = specification,
            };
        }
        return bundles;
    }

    fn resolveTypeSystem(self: *Parser) !types.TypeSystem {
        const datatypes = try self.allocator.alloc(types.DatatypeDefinition, self.datatypes.items.len);
        for (self.datatypes.items, 0..) |datatype, index| {
            datatypes[index] = try self.resolveDatatype(datatype);
        }

        const spec_object_types = try self.allocator.alloc(types.SpecObjectType, self.spec_object_types.items.len);
        for (self.spec_object_types.items, 0..) |spec_type, index| {
            spec_object_types[index] = .{
                .identifier = spec_type.identifier,
                .long_name = spec_type.long_name,
                .attribute_definitions = try self.resolveAttributeDefinitions(spec_type.attribute_definitions.items),
            };
        }

        const spec_relation_types = try self.allocator.alloc(types.SpecRelationType, self.spec_relation_types.items.len);
        for (self.spec_relation_types.items, 0..) |spec_type, index| {
            spec_relation_types[index] = .{
                .identifier = spec_type.identifier,
                .long_name = spec_type.long_name,
                .attribute_definitions = try self.resolveAttributeDefinitions(spec_type.attribute_definitions.items),
            };
        }

        const specification_types = try self.allocator.alloc(types.SpecificationType, self.specification_types.items.len);
        for (self.specification_types.items, 0..) |spec_type, index| {
            specification_types[index] = .{
                .identifier = spec_type.identifier,
                .long_name = spec_type.long_name,
                .attribute_definitions = try self.resolveAttributeDefinitions(spec_type.attribute_definitions.items),
            };
        }

        return .{
            .datatypes = datatypes,
            .spec_object_types = spec_object_types,
            .spec_relation_types = spec_relation_types,
            .specification_types = specification_types,
        };
    }

    fn resolveDatatype(self: *Parser, raw: *RawDatatype) !types.DatatypeDefinition {
        const enum_values = try self.allocator.alloc(types.EnumValueDefinition, raw.enum_values.items.len);
        for (raw.enum_values.items, 0..) |enum_value, index| {
            enum_values[index] = .{
                .identifier = enum_value.identifier,
                .display_name = enum_value.long_name orelse enum_value.identifier,
                .embedded_values = try enum_value.embedded_values.toOwnedSlice(self.allocator),
            };
        }
        return .{
            .identifier = raw.identifier,
            .long_name = raw.long_name,
            .kind = raw.kind,
            .enum_values = enum_values,
        };
    }

    fn resolveAttributeDefinitions(self: *Parser, raw_defs: []const *RawAttributeDefinition) ![]const types.AttributeDefinition {
        const defs = try self.allocator.alloc(types.AttributeDefinition, raw_defs.len);
        for (raw_defs, 0..) |raw, index| {
            const datatype = if (raw.datatype_ref) |datatype_ref| self.datatype_by_id.get(datatype_ref) else null;
            defs[index] = .{
                .identifier = raw.identifier,
                .long_name = raw.long_name,
                .kind = raw.kind,
                .datatype_identifier = raw.datatype_ref,
                .datatype_name = if (datatype) |dt| dt.long_name else null,
                .multi_valued = raw.multi_valued,
            };
        }
        return defs;
    }

    fn resolveSpecObjects(self: *Parser) ![]const types.SpecObject {
        const out = try self.allocator.alloc(types.SpecObject, self.spec_objects.items.len);
        for (self.spec_objects.items, 0..) |raw, index| {
            const resolved_type_name = if (raw.type_ref) |type_ref|
                if (self.spec_object_type_by_id.get(type_ref)) |spec_type| spec_type.long_name else null
            else
                null;
            if (raw.type_ref != null and resolved_type_name == null) {
                try self.diags.warn(raw.identifier, "unresolvable spec object type ref: {s}", .{raw.type_ref.?});
            }
            out[index] = .{
                .identifier = raw.identifier,
                .long_name = raw.long_name,
                .description = raw.description,
                .last_change = raw.last_change,
                .type_identifier = raw.type_ref,
                .type_name = resolved_type_name,
                .attribute_values = try self.resolveValues(raw.identifier, raw.values.items),
            };
        }
        return out;
    }

    fn resolveSpecRelations(self: *Parser) ![]const types.SpecRelation {
        const out = try self.allocator.alloc(types.SpecRelation, self.spec_relations.items.len);
        for (self.spec_relations.items, 0..) |raw, index| {
            const resolved_type_name = if (raw.type_ref) |type_ref|
                if (self.spec_relation_type_by_id.get(type_ref)) |spec_type| spec_type.long_name else null
            else
                null;
            if (raw.type_ref != null and resolved_type_name == null) {
                try self.diags.warn(raw.identifier, "unresolvable spec relation type ref: {s}", .{raw.type_ref.?});
            }
            if (raw.source_ref) |source_ref| {
                if (!self.spec_object_by_id.contains(source_ref)) {
                    try self.diags.warn(raw.identifier, "unresolvable source object ref: {s}", .{source_ref});
                }
            }
            if (raw.target_ref) |target_ref| {
                if (!self.spec_object_by_id.contains(target_ref)) {
                    try self.diags.warn(raw.identifier, "unresolvable target object ref: {s}", .{target_ref});
                }
            }
            out[index] = .{
                .identifier = raw.identifier,
                .source_object_ref = raw.source_ref,
                .target_object_ref = raw.target_ref,
                .type_identifier = raw.type_ref,
                .type_name = resolved_type_name,
                .attribute_values = try self.resolveValues(raw.identifier, raw.values.items),
            };
        }
        return out;
    }

    fn resolveSpecifications(self: *Parser) ![]const types.Specification {
        const out = try self.allocator.alloc(types.Specification, self.specifications.items.len);
        for (self.specifications.items, 0..) |raw, index| {
            const resolved_type_name = if (raw.type_ref) |type_ref|
                if (self.specification_type_by_id.get(type_ref)) |spec_type| spec_type.long_name else null
            else
                null;
            if (raw.type_ref != null and resolved_type_name == null) {
                try self.diags.warn(raw.identifier, "unresolvable specification type ref: {s}", .{raw.type_ref.?});
            }
            out[index] = .{
                .identifier = raw.identifier,
                .long_name = raw.long_name,
                .last_change = raw.last_change,
                .type_identifier = raw.type_ref,
                .type_name = resolved_type_name,
                .attribute_values = try self.resolveValues(raw.identifier, raw.values.items),
                .children = try self.resolveHierarchies(raw.identifier, raw.hierarchies.items),
            };
        }
        return out;
    }

    fn resolveHierarchies(self: *Parser, context_identifier: []const u8, raw_nodes: []const *RawHierarchy) ![]const types.SpecHierarchy {
        const out = try self.allocator.alloc(types.SpecHierarchy, raw_nodes.len);
        for (raw_nodes, 0..) |raw, index| {
            if (raw.object_ref) |object_ref| {
                if (!self.spec_object_by_id.contains(object_ref)) {
                    try self.diags.warn(context_identifier, "unresolvable hierarchy object ref: {s}", .{object_ref});
                }
            }
            out[index] = .{
                .identifier = raw.identifier,
                .long_name = raw.long_name,
                .last_change = raw.last_change,
                .object_ref = raw.object_ref,
                .children = try self.resolveHierarchies(context_identifier, raw.children.items),
            };
        }
        return out;
    }

    fn resolveValues(self: *Parser, context_identifier: []const u8, raw_values: []const *RawAttributeValue) ![]const types.AttributeValue {
        const out = try self.allocator.alloc(types.AttributeValue, raw_values.len);
        for (raw_values, 0..) |raw, index| {
            out[index] = try self.resolveValue(context_identifier, raw);
        }
        return out;
    }

    fn resolveValue(self: *Parser, context_identifier: []const u8, raw: *RawAttributeValue) !types.AttributeValue {
        const attr_def = if (raw.definition_ref) |definition_ref| self.attr_def_by_id.get(definition_ref) else null;
        if (raw.definition_ref != null and attr_def == null) {
            try self.diags.warn(context_identifier, "unresolvable attribute definition ref: {s}", .{raw.definition_ref.?});
        }
        const datatype = if (attr_def) |definition|
            if (definition.datatype_ref) |datatype_ref| self.datatype_by_id.get(datatype_ref) else null
        else
            null;
        if (attr_def != null and attr_def.?.datatype_ref != null and datatype == null) {
            try self.diags.warn(context_identifier, "unresolvable datatype ref: {s}", .{attr_def.?.datatype_ref.?});
        }

        const kind = if (datatype) |resolved_datatype| resolved_datatype.kind else raw.kind;
        const definition_name = if (attr_def) |definition| definition.long_name else null;
        const datatype_identifier = if (attr_def) |definition| definition.datatype_ref else null;
        const datatype_name = if (datatype) |resolved_datatype| resolved_datatype.long_name else null;

        switch (kind) {
            .string => {
                const text = try self.normalizeRawText(raw.raw_text orelse "");
                return .{
                    .definition_identifier = raw.definition_ref,
                    .definition_name = definition_name,
                    .datatype_identifier = datatype_identifier,
                    .datatype_name = datatype_name,
                    .kind = .string,
                    .text = text,
                    .data = .{ .string = {} },
                };
            },
            .xhtml => {
                const text = try xhtml.stripMarkup(self.allocator, raw.raw_text orelse "");
                return .{
                    .definition_identifier = raw.definition_ref,
                    .definition_name = definition_name,
                    .datatype_identifier = datatype_identifier,
                    .datatype_name = datatype_name,
                    .kind = .xhtml,
                    .text = text,
                    .data = .{ .xhtml = {} },
                };
            },
            .date => {
                const text = try self.normalizeRawText(raw.raw_text orelse "");
                return .{
                    .definition_identifier = raw.definition_ref,
                    .definition_name = definition_name,
                    .datatype_identifier = datatype_identifier,
                    .datatype_name = datatype_name,
                    .kind = .date,
                    .text = text,
                    .data = .{ .date = {} },
                };
            },
            .boolean => {
                const text = try self.normalizeRawText(raw.raw_text orelse "");
                const value = parseBoolean(text) orelse {
                    try self.diags.warn(context_identifier, "malformed boolean value: {s}", .{text});
                    return .{
                        .definition_identifier = raw.definition_ref,
                        .definition_name = definition_name,
                        .datatype_identifier = datatype_identifier,
                        .datatype_name = datatype_name,
                        .kind = .boolean,
                        .text = text,
                        .data = .{ .boolean = false },
                    };
                };
                return .{
                    .definition_identifier = raw.definition_ref,
                    .definition_name = definition_name,
                    .datatype_identifier = datatype_identifier,
                    .datatype_name = datatype_name,
                    .kind = .boolean,
                    .text = text,
                    .data = .{ .boolean = value },
                };
            },
            .integer => {
                const text = try self.normalizeRawText(raw.raw_text orelse "");
                const value = std.fmt.parseInt(i64, text, 10) catch {
                    try self.diags.warn(context_identifier, "malformed integer value: {s}", .{text});
                    return .{
                        .definition_identifier = raw.definition_ref,
                        .definition_name = definition_name,
                        .datatype_identifier = datatype_identifier,
                        .datatype_name = datatype_name,
                        .kind = .integer,
                        .text = text,
                        .data = .{ .integer = 0 },
                    };
                };
                return .{
                    .definition_identifier = raw.definition_ref,
                    .definition_name = definition_name,
                    .datatype_identifier = datatype_identifier,
                    .datatype_name = datatype_name,
                    .kind = .integer,
                    .text = text,
                    .data = .{ .integer = value },
                };
            },
            .real => {
                const text = try self.normalizeRawText(raw.raw_text orelse "");
                const value = std.fmt.parseFloat(f64, text) catch {
                    try self.diags.warn(context_identifier, "malformed real value: {s}", .{text});
                    return .{
                        .definition_identifier = raw.definition_ref,
                        .definition_name = definition_name,
                        .datatype_identifier = datatype_identifier,
                        .datatype_name = datatype_name,
                        .kind = .real,
                        .text = text,
                        .data = .{ .real = 0.0 },
                    };
                };
                return .{
                    .definition_identifier = raw.definition_ref,
                    .definition_name = definition_name,
                    .datatype_identifier = datatype_identifier,
                    .datatype_name = datatype_name,
                    .kind = .real,
                    .text = text,
                    .data = .{ .real = value },
                };
            },
            .enumeration => {
                const selections = try self.allocator.alloc(types.EnumerationSelection, raw.enum_value_refs.items.len);
                var text_builder: std.ArrayList(u8) = .empty;
                defer text_builder.deinit(self.allocator);
                for (raw.enum_value_refs.items, 0..) |ref, index| {
                    const raw_enum = self.enum_value_by_id.get(ref);
                    if (raw_enum == null) {
                        try self.diags.warn(context_identifier, "unresolvable enum value ref: {s}", .{ref});
                    }
                    selections[index] = .{
                        .identifier = ref,
                        .display_name = if (raw_enum) |resolved| (resolved.long_name orelse resolved.identifier) else null,
                        .embedded_values = if (raw_enum) |resolved| try resolved.embedded_values.toOwnedSlice(self.allocator) else &.{},
                    };
                    if (selections[index].display_name) |name| {
                        if (text_builder.items.len > 0) try text_builder.appendSlice(self.allocator, ", ");
                        try text_builder.appendSlice(self.allocator, name);
                    }
                }
                const text = if (text_builder.items.len == 0)
                    try self.allocator.dupe(u8, "")
                else
                    try text_builder.toOwnedSlice(self.allocator);
                return .{
                    .definition_identifier = raw.definition_ref,
                    .definition_name = definition_name,
                    .datatype_identifier = datatype_identifier,
                    .datatype_name = datatype_name,
                    .kind = .enumeration,
                    .text = text,
                    .data = .{ .enumeration = selections },
                };
            },
        }
    }

    fn normalizeRawText(self: *Parser, raw_text: []const u8) ![]const u8 {
        const decoded = try xhtml.decodeEntities(self.allocator, raw_text);
        return xhtml.normalizePlainText(self.allocator, decoded);
    }

    fn requireIdentifier(self: *Parser, start: xml.StartTag) ![]const u8 {
        return self.dupRaw(xml.attr(start, "IDENTIFIER") orelse return error.InvalidXml);
    }

    fn dupRaw(self: *Parser, value: []const u8) ![]const u8 {
        return self.allocator.dupe(u8, value);
    }

    fn dupOptionalRaw(self: *Parser, value: ?[]const u8) !?[]const u8 {
        if (value) |v| return try self.dupRaw(v);
        return null;
    }

    fn dupOptionalText(self: *Parser, value: ?[]const u8) !?[]const u8 {
        if (value) |v| return try self.dupText(v);
        return null;
    }

    fn dupText(self: *Parser, value: []const u8) ![]const u8 {
        const decoded = try xhtml.decodeEntities(self.allocator, value);
        return xhtml.normalizePlainText(self.allocator, decoded);
    }

    fn setIfEmpty(_: *Parser, field: *?[]const u8, value: []const u8) void {
        if (field.* == null) field.* = value;
    }
};

fn parseReqifDocument(
    allocator: Allocator,
    xml_bytes: []const u8,
    source_name: ?[]const u8,
    collector: *diagnostics.Collector,
) ![]const types.Bundle {
    var parser = Parser.init(allocator, source_name, collector);
    return parser.parse(xml_bytes);
}

fn parseBoolAttr(value: ?[]const u8) bool {
    return if (value) |v| parseBoolean(v) orelse false else false;
}

fn parseBoolean(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

fn kindFromDatatypeTag(name: []const u8) ?types.ValueKind {
    if (std.mem.eql(u8, name, "DATATYPE-DEFINITION-STRING")) return .string;
    if (std.mem.eql(u8, name, "DATATYPE-DEFINITION-INTEGER")) return .integer;
    if (std.mem.eql(u8, name, "DATATYPE-DEFINITION-BOOLEAN")) return .boolean;
    if (std.mem.eql(u8, name, "DATATYPE-DEFINITION-REAL")) return .real;
    if (std.mem.eql(u8, name, "DATATYPE-DEFINITION-DATE")) return .date;
    if (std.mem.eql(u8, name, "DATATYPE-DEFINITION-ENUMERATION")) return .enumeration;
    if (std.mem.eql(u8, name, "DATATYPE-DEFINITION-XHTML")) return .xhtml;
    return null;
}

fn kindFromAttributeDefinitionTag(name: []const u8) ?types.ValueKind {
    if (std.mem.eql(u8, name, "ATTRIBUTE-DEFINITION-STRING")) return .string;
    if (std.mem.eql(u8, name, "ATTRIBUTE-DEFINITION-INTEGER")) return .integer;
    if (std.mem.eql(u8, name, "ATTRIBUTE-DEFINITION-BOOLEAN")) return .boolean;
    if (std.mem.eql(u8, name, "ATTRIBUTE-DEFINITION-REAL")) return .real;
    if (std.mem.eql(u8, name, "ATTRIBUTE-DEFINITION-DATE")) return .date;
    if (std.mem.eql(u8, name, "ATTRIBUTE-DEFINITION-ENUMERATION")) return .enumeration;
    if (std.mem.eql(u8, name, "ATTRIBUTE-DEFINITION-XHTML")) return .xhtml;
    return null;
}

fn kindFromAttributeValueTag(name: []const u8) ?types.ValueKind {
    if (std.mem.eql(u8, name, "ATTRIBUTE-VALUE-STRING")) return .string;
    if (std.mem.eql(u8, name, "ATTRIBUTE-VALUE-INTEGER")) return .integer;
    if (std.mem.eql(u8, name, "ATTRIBUTE-VALUE-BOOLEAN")) return .boolean;
    if (std.mem.eql(u8, name, "ATTRIBUTE-VALUE-REAL")) return .real;
    if (std.mem.eql(u8, name, "ATTRIBUTE-VALUE-DATE")) return .date;
    if (std.mem.eql(u8, name, "ATTRIBUTE-VALUE-ENUMERATION")) return .enumeration;
    if (std.mem.eql(u8, name, "ATTRIBUTE-VALUE-XHTML")) return .xhtml;
    return null;
}

const testing = std.testing;

fn loadFixture(allocator: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_file_bytes);
}

test "minimal reqif fixture parses with zero bundles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif/01_minimal_reqif/sample.reqif");
    const result = try parseReqifBytes(alloc, bytes);
    try testing.expectEqual(@as(usize, 0), result.bundles.len);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "rmf fixture parses relations and hierarchy using old namespace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/org.eclipse.rmf_01_specRelationTest/sample.reqif");
    const result = try parseReqifBytes(alloc, bytes);

    try testing.expectEqual(@as(usize, 1), result.bundles.len);
    try testing.expectEqual(@as(usize, 2), result.bundles[0].spec_objects.len);
    try testing.expectEqual(@as(usize, 1), result.bundles[0].spec_relations.len);
    try testing.expectEqualStrings("Example SpecType", result.bundles[0].spec_objects[0].type_name.?);
    try testing.expectEqualStrings("Max Mustermann", result.bundles[0].spec_objects[0].attribute_values[0].text);
    try testing.expectEqualStrings("2c84e85a-59d1-11da-8ef5-afdbd01c7a79", result.bundles[0].specification.children[0].object_ref.?);
}

test "ea fixture resolves enums and relation type names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/SparxSystems_Enterprise_Architect_8.0_01_example/sample.reqif");
    const result = try parseReqifBytes(alloc, bytes);

    try testing.expectEqual(@as(usize, 1), result.bundles.len);
    try testing.expectEqualStrings("R001", result.bundles[0].spec_objects[0].identifier);
    try testing.expectEqualStrings("Proposed", result.bundles[0].spec_objects[0].attribute_values[1].text);
    try testing.expectEqualStrings("deriveReq", result.bundles[0].spec_relations[0].type_identifier.?);
    try testing.expectEqualStrings("Derive Requirement Relationship", result.bundles[0].spec_relations[0].type_name.?);
}

test "doors fixture handles vendor namespaces and xhtml text extraction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/02_example_from_a_user/sample.reqif");
    const result = try parseReqifBytes(alloc, bytes);

    try testing.expect(result.bundles.len >= 1);
    try testing.expect(result.bundles[0].type_system.datatypes.len > 0);
    try testing.expect(result.bundles[0].spec_objects.len > 0);

    var found_xhtml = false;
    for (result.bundles[0].spec_objects) |spec_object| {
        for (spec_object.attribute_values) |value| {
            if (value.kind == .xhtml and (std.mem.eql(u8, value.text, "susan") or std.mem.eql(u8, value.text, "Carbon Trust Standard"))) {
                found_xhtml = true;
                break;
            }
        }
        if (found_xhtml) break;
    }
    try testing.expect(found_xhtml);
}

test "polarion fixture parses into non-empty objects and specifications" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqif_software/Polarion_01_anonimized_example/sample.reqif");
    const result = try parseReqifBytes(alloc, bytes);

    try testing.expect(result.bundles.len >= 1);
    try testing.expect(result.bundles[0].spec_objects.len > 0);
    try testing.expect(result.bundles[0].type_system.spec_object_types.len > 0);
}

test "reqifz fixture discovers reqif payload and source name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const zip_bytes = try loadFixture(alloc, "libreqif/test/fixtures/strictdoc/reqifz/01_reqifz_with_one_reqif_and_one_attachments/sample.reqifz");
    const result = try parseReqifzBytes(alloc, zip_bytes);

    try testing.expectEqual(@as(usize, 1), result.bundles.len);
    try testing.expectEqualStrings("sample.reqif", result.bundles[0].source_name.?);
    try testing.expect(result.diagnostics.len == 0);
}

test "multiple specifications split into multiple bundles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/multi_spec.reqif");
    const result = try parseReqifBytes(alloc, bytes);

    try testing.expectEqual(@as(usize, 2), result.bundles.len);
    try testing.expectEqualStrings("SPEC-1", result.bundles[0].specification.identifier);
    try testing.expectEqualStrings("SPEC-2", result.bundles[1].specification.identifier);
    try testing.expectEqual(@as(usize, 1), result.bundles[0].spec_objects.len);
    try testing.expectEqual(@as(usize, 1), result.bundles[1].spec_objects.len);
}

test "malformed scalar values and unresolved refs become diagnostics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/malformed_values.reqif");
    const result = try parseReqifBytes(alloc, bytes);

    try testing.expectEqual(@as(usize, 1), result.bundles.len);
    try testing.expect(result.diagnostics.len >= 3);
}

test "xhtml synthetic fixture flattens nested markup to plain text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bytes = try loadFixture(alloc, "libreqif/test/fixtures/synthetic/xhtml_blocks.reqif");
    const result = try parseReqifBytes(alloc, bytes);

    try testing.expectEqual(@as(usize, 1), result.bundles.len);
    try testing.expectEqualStrings("Alpha Beta Bold Tail", result.bundles[0].spec_objects[0].attribute_values[0].text);
}

test "invalid root hard fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedRoot, parseReqifBytes(arena.allocator(), "<not-reqif/>"));
}

test "file helper matches bytes helper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "libreqif/test/fixtures/strictdoc/reqif_software/SparxSystems_Enterprise_Architect_8.0_01_example/sample.reqif";
    const bytes = try loadFixture(alloc, path);
    const from_bytes = try parseReqifBytes(alloc, bytes);
    const from_file = try parseReqifFile(alloc, path);

    try testing.expectEqual(from_bytes.bundles.len, from_file.bundles.len);
    try testing.expectEqualStrings(from_bytes.bundles[0].specification.identifier, from_file.bundles[0].specification.identifier);
}
