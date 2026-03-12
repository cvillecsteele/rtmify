const std = @import("std");
const cfb = @import("cfb.zig");
const detect = @import("detect.zig");
const evidence = @import("evidence.zig");
const eval = @import("eval.zig");
const normalize = @import("normalize.zig");
const sample_probe = @import("sample_probe.zig");

pub const ExtractOptions = struct {
    known_ids: ?[]const []const u8 = null,
};

const candidate_streams = [_][]const u8{
    "Components6/Data",
    "Nets6/Data",
    "Rules6/Data",
    "PrimitiveParameters/Data",
    "Models/Data",
    "BoardRegions/Data",
    "UniqueIDPrimitiveInformation/Data",
    "FileHeaderSix",
    "FileHeader",
};

const schdoc_stream_name = "FileHeader";

pub fn extractAuto(path: []const u8, options: ExtractOptions, allocator: std.mem.Allocator) ![]evidence.EvidenceRecord {
    const det = try detect.detectFile(path, allocator);
    return switch (det.kind) {
        .altium_pcbdoc => extractPcbDoc(path, options, allocator),
        .altium_schdoc => extractSchDoc(path, options, allocator),
        else => error.UnsupportedArtifact,
    };
}

pub fn extractReportable(path: []const u8, options: ExtractOptions, allocator: std.mem.Allocator) ![]evidence.EvidenceRecord {
    const all_records = try extractAuto(path, options, allocator);
    errdefer freeRecords(all_records, allocator);

    var filtered: std.ArrayList(evidence.EvidenceRecord) = .empty;
    errdefer {
        for (filtered.items) |rec| freeEvidenceRecord(rec, allocator);
        filtered.deinit(allocator);
    }

    for (all_records) |record| {
        if (eval.classifyRecord(record) == .reportable) {
            try filtered.append(allocator, record);
        } else {
            freeEvidenceRecord(record, allocator);
        }
    }
    allocator.free(all_records);
    return try filtered.toOwnedSlice(allocator);
}

pub fn extractPcbDoc(path: []const u8, options: ExtractOptions, allocator: std.mem.Allocator) ![]evidence.EvidenceRecord {
    const det = try detect.detectFile(path, allocator);
    if (det.kind != .altium_pcbdoc) return error.UnsupportedArtifact;

    var compound = try cfb.open(path, allocator);
    defer compound.deinit(allocator);

    var out: std.ArrayList(evidence.EvidenceRecord) = .empty;
    errdefer {
        for (out.items) |rec| freeEvidenceRecord(rec, allocator);
        out.deinit(allocator);
    }

    for (candidate_streams) |stream_name| {
        const data_opt = try compound.readStreamByName(stream_name, allocator);
        if (data_opt == null) continue;
        const data = data_opt.?;
        defer allocator.free(data);

        const slash = std.mem.lastIndexOfScalar(u8, stream_name, '/');
        const storage_name = if (slash) |idx| stream_name[0..idx] else "";
        const leaf_name = if (slash) |idx| stream_name[idx + 1 ..] else stream_name;

        const records = try parseRecords(data, allocator);
        defer {
            for (records) |props| freeProperties(props, allocator);
            allocator.free(records);
        }

        if (records.len == 0 and (std.ascii.eqlIgnoreCase(stream_name, "FileHeaderSix") or std.ascii.eqlIgnoreCase(stream_name, "FileHeader"))) {
            if (try buildDocumentRecordFromRaw(path, .altium_pcbdoc, storage_name, leaf_name, data, allocator)) |doc_rec| {
                try out.append(allocator, doc_rec);
            }
        }

        for (records, 0..) |props, idx| {
            const rec = try buildEvidenceRecord(
                path,
                .altium_pcbdoc,
                .altium_pipe_record,
                storage_name,
                leaf_name,
                idx,
                props,
                classifyPcbDocScope(storage_name, props),
                options.known_ids,
                allocator,
            );
            try out.append(allocator, rec);
        }
    }

    return try out.toOwnedSlice(allocator);
}

pub fn extractSchDoc(path: []const u8, options: ExtractOptions, allocator: std.mem.Allocator) ![]evidence.EvidenceRecord {
    const det = try detect.detectFile(path, allocator);
    if (det.kind != .altium_schdoc) return error.UnsupportedArtifact;

    var compound = try cfb.open(path, allocator);
    defer compound.deinit(allocator);

    const data = (try compound.readStreamByName(schdoc_stream_name, allocator)) orelse return error.StreamNotFound;
    defer allocator.free(data);

    const records = try parseSchDocFileHeaderRecords(data, allocator);
    defer {
        for (records) |props| freeProperties(props, allocator);
        allocator.free(records);
    }

    var out: std.ArrayList(evidence.EvidenceRecord) = .empty;
    errdefer {
        for (out.items) |rec| freeEvidenceRecord(rec, allocator);
        out.deinit(allocator);
    }

    var idx: usize = 0;
    while (idx < records.len) {
        const props = records[idx];
        if (isSchDocComponentAnchor(props)) {
            const coalesced = try coalesceSchDocComponent(records, idx, allocator);
            defer freeProperties(coalesced.properties, allocator);

            const rec = try buildEvidenceRecord(
                path,
                .altium_schdoc,
                .altium_schdoc_file_header_record,
                "",
                schdoc_stream_name,
                idx,
                coalesced.properties,
                .component,
                options.known_ids,
                allocator,
            );
            try out.append(allocator, rec);
            idx = coalesced.next_index;
            continue;
        }

        const scope = classifySchDocScope(props, idx);
        if (scope == .document or scope == .unknown) {
            const rec = try buildEvidenceRecord(
                path,
                .altium_schdoc,
                .altium_schdoc_file_header_record,
                "",
                schdoc_stream_name,
                idx,
                props,
                scope,
                options.known_ids,
                allocator,
            );
            try out.append(allocator, rec);
        }
        idx += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn buildDocumentRecordFromRaw(
    source_path: []const u8,
    artifact_kind: detect.ArtifactKind,
    storage_name: []const u8,
    stream_name: []const u8,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) !?evidence.EvidenceRecord {
    var printable: std.ArrayList(u8) = .empty;
    defer printable.deinit(allocator);
    var last_break = false;
    for (bytes) |b| {
        const ch: u8 = switch (b) {
            9, 10, 13 => '\n',
            32...126 => b,
            else => '\n',
        };
        if (ch == '\n') {
            if (!last_break) try printable.append(allocator, '\n');
            last_break = true;
        } else {
            try printable.append(allocator, ch);
            last_break = false;
        }
    }
    const text = try printable.toOwnedSlice(allocator);
    defer allocator.free(text);

    var title: ?[]const u8 = null;
    var guid: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = normalize.normalizeValue(raw_line);
        if (line.len == 0) continue;
        if (title == null and std.mem.indexOf(u8, line, "PCB") != null) title = line;
        if (guid == null and std.mem.indexOfScalar(u8, line, '{') != null and std.mem.indexOfScalar(u8, line, '}') != null) guid = line;
    }
    if (title == null and guid == null) return null;

    var props: std.ArrayList(evidence.Property) = .empty;
    errdefer {
        for (props.items) |prop| {
            allocator.free(prop.key);
            allocator.free(prop.value);
        }
        props.deinit(allocator);
    }
    if (title) |v| try props.append(allocator, .{ .key = try allocator.dupe(u8, "Format"), .value = try allocator.dupe(u8, v) });
    if (guid) |v| try props.append(allocator, .{ .key = try allocator.dupe(u8, "Guid"), .value = try allocator.dupe(u8, v) });

    return .{
        .artifact_kind = artifact_kind,
        .source_path = try allocator.dupe(u8, source_path),
        .scope_kind = .document,
        .scope_identifier = try dupOptional(guid, allocator),
        .display_name = try dupOptional(title, allocator),
        .properties = try props.toOwnedSlice(allocator),
        .matched_requirement_ids = try allocator.dupe(evidence.MatchedId, &.{}),
        .provenance = .{
            .storage_name = try allocator.dupe(u8, storage_name),
            .stream_name = try allocator.dupe(u8, stream_name),
            .record_index = 0,
            .extraction_method = .altium_pipe_record,
        },
    };
}

fn freeProperties(props: []const evidence.Property, allocator: std.mem.Allocator) void {
    for (props) |prop| {
        allocator.free(prop.key);
        allocator.free(prop.value);
    }
    allocator.free(props);
}

fn freeEvidenceRecord(rec: evidence.EvidenceRecord, allocator: std.mem.Allocator) void {
    allocator.free(rec.source_path);
    if (rec.scope_identifier) |v| allocator.free(v);
    if (rec.display_name) |v| allocator.free(v);
    freeProperties(rec.properties, allocator);
    for (rec.matched_requirement_ids) |m| {
        allocator.free(m.id);
        allocator.free(m.source_property);
        allocator.free(m.matched_from_value);
    }
    allocator.free(rec.matched_requirement_ids);
    allocator.free(rec.provenance.storage_name);
    allocator.free(rec.provenance.stream_name);
}

pub fn freeRecords(records: []const evidence.EvidenceRecord, allocator: std.mem.Allocator) void {
    for (records) |rec| freeEvidenceRecord(rec, allocator);
    allocator.free(records);
}

fn parseRecords(bytes: []const u8, allocator: std.mem.Allocator) ![][]evidence.Property {
    var printable: std.ArrayList(u8) = .empty;
    defer printable.deinit(allocator);
    var last_was_break = false;
    for (bytes) |b| {
        const ch: u8 = switch (b) {
            9, 10, 13 => '\n',
            32...126 => b,
            else => '\n',
        };
        if (ch == '\n') {
            if (!last_was_break) try printable.append(allocator, '\n');
            last_was_break = true;
        } else {
            try printable.append(allocator, ch);
            last_was_break = false;
        }
    }

    const text = try printable.toOwnedSlice(allocator);
    defer allocator.free(text);

    var out: std.ArrayList([]evidence.Property) = .empty;
    errdefer {
        for (out.items) |props| freeProperties(props, allocator);
        out.deinit(allocator);
    }

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = normalize.normalizeValue(line_raw);
        if (line.len < 4) continue;
        if (std.mem.indexOfScalar(u8, line, '|') == null or std.mem.indexOfScalar(u8, line, '=') == null) continue;

        var props: std.ArrayList(evidence.Property) = .empty;
        errdefer {
            for (props.items) |prop| {
                allocator.free(prop.key);
                allocator.free(prop.value);
            }
            props.deinit(allocator);
        }

        var tokens = std.mem.tokenizeScalar(u8, line, '|');
        while (tokens.next()) |token| {
            const eq = std.mem.indexOfScalar(u8, token, '=') orelse continue;
            const key = normalize.normalizeKey(token[0..eq]);
            const value = normalize.normalizeValue(token[eq + 1 ..]);
            if (key.len == 0 or value.len == 0) continue;
            try props.append(allocator, .{
                .key = try allocator.dupe(u8, key),
                .value = try allocator.dupe(u8, value),
            });
        }

        if (props.items.len == 0) continue;
        try out.append(allocator, try props.toOwnedSlice(allocator));
    }

    return try out.toOwnedSlice(allocator);
}

fn propertyValue(props: []const evidence.Property, key: []const u8) ?[]const u8 {
    for (props) |prop| {
        if (std.ascii.eqlIgnoreCase(prop.key, key)) return prop.value;
    }
    return null;
}

fn anyPropertyPrefix(props: []const evidence.Property, prefix: []const u8) bool {
    for (props) |prop| {
        if (std.ascii.startsWithIgnoreCase(prop.key, prefix)) return true;
    }
    return false;
}

fn classifyPcbDocScope(storage_name: []const u8, props: []const evidence.Property) evidence.ScopeKind {
    if (std.ascii.eqlIgnoreCase(storage_name, "Rules6") or
        propertyValue(props, "RULEKIND") != null or
        propertyValue(props, "ENABLED") != null)
        return .rule;

    if (propertyValue(props, "OBJECTKIND")) |v| {
        if (std.ascii.eqlIgnoreCase(v, "BoardRegion")) return .layer_stack_region;
    }
    if (propertyValue(props, "NAME")) |v| {
        if (std.mem.startsWith(u8, v, "Layer Stack Region")) return .layer_stack_region;
    }

    if (std.ascii.eqlIgnoreCase(storage_name, "Models") or propertyValue(props, "MODELSOURCE") != null) return .model;
    if (std.ascii.eqlIgnoreCase(storage_name, "Nets6") or propertyValue(props, "NET") != null) return .net;
    if (propertyValue(props, "DESIGNATOR") != null or propertyValue(props, "SOURCEDESIGNATOR") != null or propertyValue(props, "PATTERN") != null or anyPropertyPrefix(props, "Component.")) return .component;
    if (std.ascii.eqlIgnoreCase(storage_name, "FileHeader") or std.ascii.eqlIgnoreCase(storage_name, "FileHeaderSix")) return .document;
    return .unknown;
}

fn classifySchDocScope(props: []const evidence.Property, record_index: usize) evidence.ScopeKind {
    _ = record_index;
    if (propertyValue(props, "HEADER") != null) return .document;
    if (propertyValue(props, "NAME")) |v| {
        if (isSchDocDocumentName(v)) return .document;
    }
    if (propertyValue(props, "LIBREFERENCE") != null or
        propertyValue(props, "DESIGNITEMID") != null or
        propertyValue(props, "SOURCELIBRARYNAME") != null or
        propertyValue(props, "COMPONENTKIND") != null)
        return .component;
    if (propertyValue(props, "RECORD")) |v| {
        if (std.mem.eql(u8, v, "1") and (propertyValue(props, "LIBREFERENCE") != null or propertyValue(props, "DESIGNITEMID") != null)) {
            return .component;
        }
    }
    return .unknown;
}

fn isSchDocDocumentName(name: []const u8) bool {
    const names = [_][]const u8{
        "Author",
        "Title",
        "DocumentName",
        "ProjectName",
        "Revision",
        "SheetNumber",
        "SheetTotal",
        "CurrentDate",
        "CurrentTime",
    };
    for (names) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn parseSchDocFileHeaderRecords(bytes: []const u8, allocator: std.mem.Allocator) ![][]evidence.Property {
    return parseRecords(bytes, allocator);
}

fn isSchDocComponentAnchor(props: []const evidence.Property) bool {
    if (propertyValue(props, "RECORD")) |v| {
        if (!std.mem.eql(u8, v, "1")) return false;
    } else {
        return false;
    }
    return propertyValue(props, "LIBREFERENCE") != null or propertyValue(props, "DESIGNITEMID") != null;
}

const CoalescedRecord = struct {
    properties: []evidence.Property,
    next_index: usize,
};

fn coalesceSchDocComponent(records: [][]evidence.Property, anchor_index: usize, allocator: std.mem.Allocator) !CoalescedRecord {
    var merged: std.ArrayList(evidence.Property) = .empty;
    errdefer {
        for (merged.items) |prop| {
            allocator.free(prop.key);
            allocator.free(prop.value);
        }
        merged.deinit(allocator);
    }

    for (records[anchor_index]) |prop| {
        try appendOrReplaceProperty(&merged, prop.key, prop.value, allocator);
    }

    const anchor_indexinsheet = propertyValue(records[anchor_index], "INDEXINSHEET");
    const anchor_ownerpartid = propertyValue(records[anchor_index], "OWNERPARTID");

    var idx = anchor_index + 1;
    while (idx < records.len) : (idx += 1) {
        const props = records[idx];
        if (isSchDocComponentAnchor(props)) break;
        if (!isSchDocComponentChild(props, anchor_indexinsheet, anchor_ownerpartid)) break;
        if (propertyValue(props, "NAME")) |name| {
            if (propertyValue(props, "TEXT")) |text| {
                try appendOrReplaceProperty(&merged, name, text, allocator);
            }
        }
        for (props) |prop| {
            if (std.ascii.eqlIgnoreCase(prop.key, "NAME") or std.ascii.eqlIgnoreCase(prop.key, "TEXT")) continue;
            try appendOrReplaceProperty(&merged, prop.key, prop.value, allocator);
        }
    }

    return .{
        .properties = try merged.toOwnedSlice(allocator),
        .next_index = idx,
    };
}

fn isSchDocComponentChild(props: []const evidence.Property, anchor_indexinsheet: ?[]const u8, anchor_ownerpartid: ?[]const u8) bool {
    if (propertyValue(props, "NAME")) |name| {
        if (std.ascii.eqlIgnoreCase(name, "Designator") or std.ascii.eqlIgnoreCase(name, "Comment")) {
            if (anchor_indexinsheet) |idx| {
                if (propertyValue(props, "OWNERINDEX")) |owner| {
                    if (std.mem.eql(u8, normalize.normalizeValue(owner), normalize.normalizeValue(idx))) return true;
                }
            }
            if (anchor_ownerpartid) |part| {
                if (propertyValue(props, "OWNERPARTID")) |owner_part| {
                    if (std.mem.eql(u8, normalize.normalizeValue(owner_part), normalize.normalizeValue(part))) return true;
                }
            }
        }
    }
    return false;
}

fn appendOrReplaceProperty(list: *std.ArrayList(evidence.Property), key: []const u8, value: []const u8, allocator: std.mem.Allocator) !void {
    for (list.items) |*prop| {
        if (std.ascii.eqlIgnoreCase(prop.key, key)) {
            allocator.free(prop.value);
            prop.value = try allocator.dupe(u8, value);
            return;
        }
    }
    try list.append(allocator, .{
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    });
}

fn dupOptional(value: ?[]const u8, allocator: std.mem.Allocator) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn preferredValue(props: []const evidence.Property, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| {
        if (propertyValue(props, k)) |v| return v;
    }
    return null;
}

fn buildEvidenceRecord(
    source_path: []const u8,
    artifact_kind: detect.ArtifactKind,
    extraction_method: evidence.ExtractionMethod,
    storage_name: []const u8,
    stream_name: []const u8,
    record_index: usize,
    props: []const evidence.Property,
    scope_kind: evidence.ScopeKind,
    known_ids: ?[]const []const u8,
    allocator: std.mem.Allocator,
) !evidence.EvidenceRecord {
    const identifier_keys_component = [_][]const u8{ "Designator", "SOURCE DESIGNATOR", "SOURCEDESIGNATOR", "UNIQUEID" };
    const identifier_keys_net = [_][]const u8{ "NAME", "NET", "UNIQUEID" };
    const display_keys_component = [_][]const u8{ "Comment", "Pattern", "NAME", "VALUE" };
    const sch_identifier_keys_component = [_][]const u8{ "Designator", "DESIGNATOR", "LIBREFERENCE", "DESIGNITEMID", "UNIQUEID" };
    const sch_display_keys_component = [_][]const u8{ "Comment", "COMMENT", "LIBREFERENCE", "DESIGNITEMID", "TEXT" };

    const scope_identifier = switch (artifact_kind) {
        .altium_schdoc => switch (scope_kind) {
            .component => preferredValue(props, &sch_identifier_keys_component),
            .document => preferredValue(props, &.{ "UNIQUEID", "NAME" }),
            .unknown => preferredValue(props, &.{ "UNIQUEID", "NAME" }),
            else => preferredValue(props, &.{ "UNIQUEID", "NAME" }),
        },
        else => switch (scope_kind) {
            .component => preferredValue(props, &identifier_keys_component),
            .net => preferredValue(props, &identifier_keys_net),
            .rule => preferredValue(props, &.{ "NAME", "UNIQUEID" }),
            .layer_stack_region => preferredValue(props, &.{ "NAME", "UNIQUEID" }),
            .model => preferredValue(props, &.{ "NAME", "UNIQUEID" }),
            .document => preferredValue(props, &.{ "TITLE", "NAME", "FILENAME" }),
            .unknown => preferredValue(props, &.{ "UNIQUEID", "NAME" }),
        },
    };
    const display_name = switch (artifact_kind) {
        .altium_schdoc => switch (scope_kind) {
            .component => preferredValue(props, &sch_display_keys_component),
            .document => preferredValue(props, &.{ "HEADER", "TEXT", "NAME" }),
            else => preferredValue(props, &.{ "TEXT", "Comment", "NAME", "VALUE", "Pattern" }),
        },
        else => switch (scope_kind) {
            .component => preferredValue(props, &display_keys_component),
            else => preferredValue(props, &.{ "Comment", "NAME", "VALUE", "Pattern" }),
        },
    };

    var properties_copy = try allocator.alloc(evidence.Property, props.len);
    errdefer {
        for (properties_copy[0..props.len]) |prop| {
            allocator.free(prop.key);
            allocator.free(prop.value);
        }
        allocator.free(properties_copy);
    }
    for (props, 0..) |prop, i| {
        properties_copy[i] = .{
            .key = try allocator.dupe(u8, prop.key),
            .value = try allocator.dupe(u8, prop.value),
        };
    }

    if (artifact_kind == .altium_schdoc and scope_kind == .document) {
        if (propertyValue(props, "NAME")) |name| {
            if (propertyValue(props, "TEXT")) |text| {
                const expanded = try allocator.realloc(properties_copy, properties_copy.len + 1);
                properties_copy = expanded;
                properties_copy[properties_copy.len - 1] = .{
                    .key = try allocator.dupe(u8, name),
                    .value = try allocator.dupe(u8, text),
                };
            }
        }
    }

    const matches = try normalize.collectExactMatches(properties_copy, known_ids, allocator);
    errdefer {
        for (matches) |m| {
            allocator.free(m.id);
            allocator.free(m.source_property);
            allocator.free(m.matched_from_value);
        }
        allocator.free(matches);
    }

    return .{
        .artifact_kind = artifact_kind,
        .source_path = try allocator.dupe(u8, source_path),
        .scope_kind = scope_kind,
        .scope_identifier = try dupOptional(scope_identifier, allocator),
        .display_name = try dupOptional(display_name, allocator),
        .properties = properties_copy,
        .matched_requirement_ids = matches,
        .provenance = .{
            .storage_name = try allocator.dupe(u8, storage_name),
            .stream_name = try allocator.dupe(u8, stream_name),
            .record_index = record_index,
            .extraction_method = extraction_method,
        },
    };
}

test "parseRecords extracts pipe-delimited properties" {
    const alloc = std.testing.allocator;
    const records = try parseRecords("|DESIGNATOR=U14|Comment=MCU|Pattern=LQFP64|Requirement=REQ-893|\x00", alloc);
    defer {
        for (records) |props| freeProperties(props, alloc);
        alloc.free(records);
    }
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("U14", propertyValue(records[0], "DESIGNATOR").?);
}

test "buildEvidenceRecord classifies component and matches IDs" {
    const alloc = std.testing.allocator;
    const props = [_]evidence.Property{
        .{ .key = "Designator", .value = "U14" },
        .{ .key = "Comment", .value = "STM32F405RG" },
        .{ .key = "Pattern", .value = "LQFP64" },
        .{ .key = "Requirement", .value = "REQ-893" },
    };
    const ids = [_][]const u8{"REQ-893"};
    const rec = try buildEvidenceRecord("board.PcbDoc", .altium_pcbdoc, .altium_pipe_record, "Components6", "Data", 0, &props, .component, &ids, alloc);
    defer freeEvidenceRecord(rec, alloc);

    try std.testing.expectEqual(evidence.ScopeKind.component, rec.scope_kind);
    try std.testing.expectEqualStrings("U14", rec.scope_identifier.?);
    try std.testing.expectEqualStrings("STM32F405RG", rec.display_name.?);
    try std.testing.expectEqual(@as(usize, 1), rec.matched_requirement_ids.len);
}

test "parseSchDocFileHeaderRecords parses pipe-delimited records" {
    const alloc = std.testing.allocator;
    const records = try parseSchDocFileHeaderRecords("|HEADER=Protel|\n|RECORD=1|LIBREFERENCE=Stamp|\n", alloc);
    defer {
        for (records) |props| freeProperties(props, alloc);
        alloc.free(records);
    }
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("Protel", propertyValue(records[0], "HEADER").?);
    try std.testing.expectEqualStrings("Stamp", propertyValue(records[1], "LIBREFERENCE").?);
}

test "schdoc ownership coalescing merges designator and comment" {
    const alloc = std.testing.allocator;
    const text =
        "|RECORD=1|INDEXINSHEET=5|LIBREFERENCE=Stamp|DESIGNITEMID=Stamp|SOURCELIBRARYNAME=ShieldsLib.SchLib|\n" ++
        "|OWNERINDEX=5|NAME=Designator|TEXT=Stamp|\n" ++
        "|OWNERINDEX=5|NAME=Comment|TEXT=Stamp|\n";
    const records = try parseSchDocFileHeaderRecords(text, alloc);
    defer {
        for (records) |props| freeProperties(props, alloc);
        alloc.free(records);
    }
    const merged = try coalesceSchDocComponent(records, 0, alloc);
    defer freeProperties(merged.properties, alloc);

    try std.testing.expectEqualStrings("Stamp", propertyValue(merged.properties, "Designator").?);
    try std.testing.expectEqualStrings("Stamp", propertyValue(merged.properties, "Comment").?);
    try std.testing.expectEqualStrings("Stamp", propertyValue(merged.properties, "LIBREFERENCE").?);
}

test "schdoc buildEvidenceRecord preserves formula-like text" {
    const alloc = std.testing.allocator;
    const props = [_]evidence.Property{
        .{ .key = "NAME", .value = "Title" },
        .{ .key = "TEXT", .value = "=GlobalProjectName" },
    };
    const rec = try buildEvidenceRecord("sheet.SchDoc", .altium_schdoc, .altium_schdoc_file_header_record, "", "FileHeader", 0, &props, .document, null, alloc);
    defer freeEvidenceRecord(rec, alloc);

    try std.testing.expectEqual(evidence.ScopeKind.document, rec.scope_kind);
    try std.testing.expectEqualStrings("=GlobalProjectName", propertyValue(rec.properties, "TEXT").?);
}

test "schdoc component classification and exact known-id matching work" {
    const alloc = std.testing.allocator;
    const props = [_]evidence.Property{
        .{ .key = "RECORD", .value = "1" },
        .{ .key = "LIBREFERENCE", .value = "Stamp" },
        .{ .key = "DESIGNITEMID", .value = "Stamp" },
        .{ .key = "Comment", .value = "REQ-893" },
    };
    const ids = [_][]const u8{"REQ-893"};
    const rec = try buildEvidenceRecord("sheet.SchDoc", .altium_schdoc, .altium_schdoc_file_header_record, "", "FileHeader", 4, &props, classifySchDocScope(&props, 4), &ids, alloc);
    defer freeEvidenceRecord(rec, alloc);

    try std.testing.expectEqual(evidence.ScopeKind.component, rec.scope_kind);
    try std.testing.expectEqualStrings("Stamp", rec.scope_identifier.?);
    try std.testing.expectEqualStrings("REQ-893", rec.display_name.?);
    try std.testing.expectEqual(@as(usize, 1), rec.matched_requirement_ids.len);
}

test "repo fixture extraction yields structured records" {
    const alloc = std.testing.allocator;
    const sample = try sample_probe.fixturePath(alloc, &.{ "altium", "STM32_PCB_Design.PcbDoc" });
    defer alloc.free(sample);

    const ids = [_][]const u8{"REQ-893"};
    const records = try extractPcbDoc(sample, .{ .known_ids = &ids }, alloc);
    defer {
        for (records) |rec| freeEvidenceRecord(rec, alloc);
        alloc.free(records);
    }

    try std.testing.expect(records.len > 0);
    var found_component = false;
    var found_document = false;
    var found_named_property = false;
    for (records) |rec| {
        if (rec.scope_kind == .component) found_component = true;
        if (rec.scope_kind == .document) found_document = true;
        for (rec.properties) |prop| {
            if (std.ascii.eqlIgnoreCase(prop.key, "Designator") or
                std.ascii.eqlIgnoreCase(prop.key, "Comment") or
                std.ascii.eqlIgnoreCase(prop.key, "Pattern"))
            {
                found_named_property = true;
            }
        }
    }
    try std.testing.expect(found_component);
    try std.testing.expect(found_document);
    try std.testing.expect(found_named_property);
}

test "repo fixture sch.SchDoc extraction yields document records" {
    const alloc = std.testing.allocator;
    const sample = try sample_probe.fixturePath(alloc, &.{ "altium", "sch.SchDoc" });
    defer alloc.free(sample);

    const records = try extractSchDoc(sample, .{}, alloc);
    defer {
        for (records) |rec| freeEvidenceRecord(rec, alloc);
        alloc.free(records);
    }

    try std.testing.expect(records.len > 0);
    var found_document = false;
    var found_document_prop = false;
    for (records) |rec| {
        if (rec.scope_kind == .document) found_document = true;
        for (rec.properties) |prop| {
            if (std.ascii.eqlIgnoreCase(prop.key, "Author") or
                std.ascii.eqlIgnoreCase(prop.key, "Title") or
                std.ascii.eqlIgnoreCase(prop.key, "DocumentName") or
                std.ascii.eqlIgnoreCase(prop.key, "ProjectName"))
            {
                found_document_prop = true;
            }
        }
    }
    try std.testing.expect(found_document);
    try std.testing.expect(found_document_prop);
}

test "repo fixture TopLevel_2Layer.SchDoc extraction yields component records" {
    const alloc = std.testing.allocator;
    const sample = try sample_probe.fixturePath(alloc, &.{ "altium", "TopLevel_2Layer.SchDoc" });
    defer alloc.free(sample);

    const records = try extractSchDoc(sample, .{}, alloc);
    defer {
        for (records) |rec| freeEvidenceRecord(rec, alloc);
        alloc.free(records);
    }

    try std.testing.expect(records.len > 0);
    var found_component = false;
    var found_component_prop = false;
    for (records) |rec| {
        if (rec.scope_kind == .component) found_component = true;
        for (rec.properties) |prop| {
            if (std.ascii.eqlIgnoreCase(prop.key, "LIBREFERENCE") or
                std.ascii.eqlIgnoreCase(prop.key, "DESIGNITEMID") or
                std.ascii.eqlIgnoreCase(prop.key, "Designator") or
                std.ascii.eqlIgnoreCase(prop.key, "Comment"))
            {
                found_component_prop = true;
            }
        }
    }
    try std.testing.expect(found_component);
    try std.testing.expect(found_component_prop);
}

test "extractAuto dispatches for pcbdoc and schdoc" {
    const alloc = std.testing.allocator;
    const pcb = try sample_probe.fixturePath(alloc, &.{ "altium", "SpiralTest.PcbDoc" });
    defer alloc.free(pcb);
    const sch = try sample_probe.fixturePath(alloc, &.{ "altium", "sch.SchDoc" });
    defer alloc.free(sch);

    const pcb_records = try extractAuto(pcb, .{}, alloc);
    defer {
        for (pcb_records) |rec| freeEvidenceRecord(rec, alloc);
        alloc.free(pcb_records);
    }
    const sch_records = try extractAuto(sch, .{}, alloc);
    defer {
        for (sch_records) |rec| freeEvidenceRecord(rec, alloc);
        alloc.free(sch_records);
    }

    try std.testing.expect(pcb_records.len > 0);
    try std.testing.expect(sch_records.len > 0);
    try std.testing.expectEqual(detect.ArtifactKind.altium_pcbdoc, pcb_records[0].artifact_kind);
    try std.testing.expectEqual(detect.ArtifactKind.altium_schdoc, sch_records[0].artifact_kind);
}
