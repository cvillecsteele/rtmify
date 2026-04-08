pub const ValueKind = enum {
    string,
    integer,
    boolean,
    real,
    date,
    enumeration,
    xhtml,
};

pub const ParseResult = struct {
    bundles: []const Bundle,
    diagnostics: []const @import("diagnostics.zig").Diagnostic,
};

pub const Bundle = struct {
    source_name: ?[]const u8,
    header: Header,
    type_system: TypeSystem,
    spec_objects: []const SpecObject,
    spec_relations: []const SpecRelation,
    specification: Specification,
};

pub const Header = struct {
    identifier: ?[]const u8 = null,
    creation_time: ?[]const u8 = null,
    repository_id: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    title: ?[]const u8 = null,
    reqif_tool_id: ?[]const u8 = null,
    source_tool_id: ?[]const u8 = null,
    reqif_version: ?[]const u8 = null,
};

pub const TypeSystem = struct {
    datatypes: []const DatatypeDefinition,
    spec_object_types: []const SpecObjectType,
    spec_relation_types: []const SpecRelationType,
    specification_types: []const SpecificationType,
};

pub const EmbeddedValue = struct {
    key: []const u8,
    other_content: ?[]const u8 = null,
};

pub const EnumValueDefinition = struct {
    identifier: []const u8,
    display_name: ?[]const u8 = null,
    embedded_values: []const EmbeddedValue,
};

pub const DatatypeDefinition = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    kind: ValueKind,
    enum_values: []const EnumValueDefinition,
};

pub const AttributeDefinition = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    kind: ValueKind,
    datatype_identifier: ?[]const u8 = null,
    datatype_name: ?[]const u8 = null,
    multi_valued: bool = false,
};

pub const SpecObjectType = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    attribute_definitions: []const AttributeDefinition,
};

pub const SpecRelationType = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    attribute_definitions: []const AttributeDefinition,
};

pub const SpecificationType = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    attribute_definitions: []const AttributeDefinition,
};

pub const EnumerationSelection = struct {
    identifier: []const u8,
    display_name: ?[]const u8 = null,
    embedded_values: []const EmbeddedValue,
};

pub const AttributeValueData = union(ValueKind) {
    string: void,
    integer: i64,
    boolean: bool,
    real: f64,
    date: void,
    enumeration: []const EnumerationSelection,
    xhtml: void,
};

pub const AttributeValue = struct {
    definition_identifier: ?[]const u8 = null,
    definition_name: ?[]const u8 = null,
    datatype_identifier: ?[]const u8 = null,
    datatype_name: ?[]const u8 = null,
    kind: ValueKind,
    text: []const u8,
    data: AttributeValueData,
};

pub const SpecObject = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    last_change: ?[]const u8 = null,
    type_identifier: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    attribute_values: []const AttributeValue,
};

pub const SpecRelation = struct {
    identifier: []const u8,
    source_object_ref: ?[]const u8 = null,
    target_object_ref: ?[]const u8 = null,
    type_identifier: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    attribute_values: []const AttributeValue,
};

pub const SpecHierarchy = struct {
    identifier: ?[]const u8 = null,
    long_name: ?[]const u8 = null,
    last_change: ?[]const u8 = null,
    object_ref: ?[]const u8 = null,
    children: []const SpecHierarchy,
};

pub const Specification = struct {
    identifier: []const u8,
    long_name: ?[]const u8 = null,
    last_change: ?[]const u8 = null,
    type_identifier: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    attribute_values: []const AttributeValue,
    children: []const SpecHierarchy,
};
