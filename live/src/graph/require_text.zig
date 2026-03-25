const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

pub fn requirementSourceAssertions(
    g: anytype,
    req_id: []const u8,
    alloc: Allocator,
    result: *std.ArrayList(types.RequirementSourceAssertion),
) !void {
    var st = try g.db.prepare(
        \\SELECT
        \\  rt.id,
        \\  art.id,
        \\  json_extract(rt.properties, '$.source_kind'),
        \\  json_extract(rt.properties, '$.section'),
        \\  json_extract(rt.properties, '$.text'),
        \\  json_extract(rt.properties, '$.normalized_text'),
        \\  json_extract(rt.properties, '$.hash'),
        \\  json_extract(rt.properties, '$.parse_status'),
        \\  COALESCE(CAST(json_extract(rt.properties, '$.occurrence_count') AS INTEGER), 0)
        \\FROM nodes rt
        \\JOIN edges e_assert ON e_assert.from_id = rt.id AND e_assert.to_id = ? AND e_assert.label = 'ASSERTS'
        \\LEFT JOIN edges e_contains ON e_contains.to_id = rt.id AND e_contains.label = 'CONTAINS'
        \\LEFT JOIN nodes art ON art.id = e_contains.from_id AND art.type = 'Artifact'
        \\WHERE rt.type = 'RequirementText'
        \\ORDER BY
        \\  CASE WHEN json_extract(rt.properties, '$.source_kind') = 'rtm_workbook' THEN 0 ELSE 1 END,
        \\  art.id,
        \\  rt.id
    );
    defer st.finalize();
    try st.bindText(1, req_id);
    while (try st.step()) {
        try result.append(alloc, .{
            .text_id = try alloc.dupe(u8, st.columnText(0)),
            .artifact_id = if (st.columnIsNull(1)) null else try alloc.dupe(u8, st.columnText(1)),
            .source_kind = if (st.columnIsNull(2)) null else try alloc.dupe(u8, st.columnText(2)),
            .section = if (st.columnIsNull(3)) null else try alloc.dupe(u8, st.columnText(3)),
            .text = if (st.columnIsNull(4)) null else try alloc.dupe(u8, st.columnText(4)),
            .normalized_text = if (st.columnIsNull(5)) null else try alloc.dupe(u8, st.columnText(5)),
            .hash = if (st.columnIsNull(6)) null else try alloc.dupe(u8, st.columnText(6)),
            .parse_status = if (st.columnIsNull(7)) null else try alloc.dupe(u8, st.columnText(7)),
            .occurrence_count = @intCast(st.columnInt(8)),
        });
    }
}

pub fn resolveRequirementText(g: anytype, req_id: []const u8, alloc: Allocator) !types.RequirementTextResolution {
    var assertions: std.ArrayList(types.RequirementSourceAssertion) = .empty;
    try requirementSourceAssertions(g, req_id, alloc, &assertions);

    var text_status: []const u8 = try alloc.dupe(u8, "no_source");
    var effective_statement: ?[]const u8 = null;
    var authoritative_source: ?[]const u8 = null;

    var rtm_assertion: ?types.RequirementSourceAssertion = null;
    var first_non_rtm_text: ?[]const u8 = null;
    var first_non_rtm_normalized: ?[]const u8 = null;
    var non_rtm_count: usize = 0;
    var non_rtm_conflict = false;

    for (assertions.items) |assertion| {
        const assertion_text = assertion.text orelse "";
        const normalized = assertion.normalized_text orelse assertion_text;
        if (assertion.source_kind) |source_kind| {
            if (std.mem.eql(u8, source_kind, "rtm_workbook") and assertion_text.len > 0) {
                rtm_assertion = assertion;
                continue;
            }
        }
        if (assertion_text.len == 0) continue;
        non_rtm_count += 1;
        if (first_non_rtm_text == null) {
            first_non_rtm_text = assertion_text;
            first_non_rtm_normalized = normalized;
            if (assertion.artifact_id) |artifact_id| authoritative_source = try alloc.dupe(u8, artifact_id);
        } else if (!std.mem.eql(u8, first_non_rtm_normalized.?, normalized)) {
            non_rtm_conflict = true;
        }
    }

    if (rtm_assertion) |assertion| {
        const rtm_text = assertion.text orelse "";
        effective_statement = try alloc.dupe(u8, rtm_text);
        if (assertion.artifact_id) |artifact_id| {
            if (authoritative_source) |value| alloc.free(value);
            authoritative_source = try alloc.dupe(u8, artifact_id);
        }
        const rtm_normalized = assertion.normalized_text orelse rtm_text;
        var conflict = false;
        for (assertions.items) |candidate| {
            if (candidate.source_kind) |source_kind| {
                if (std.mem.eql(u8, source_kind, "rtm_workbook")) continue;
            }
            const candidate_text = candidate.text orelse "";
            if (candidate_text.len == 0) continue;
            const candidate_normalized = candidate.normalized_text orelse candidate_text;
            if (!std.mem.eql(u8, rtm_normalized, candidate_normalized)) {
                conflict = true;
                break;
            }
        }
        alloc.free(text_status);
        text_status = try alloc.dupe(u8, if (conflict) "conflict" else "aligned");
    } else if (non_rtm_count == 1 and first_non_rtm_text != null) {
        effective_statement = try alloc.dupe(u8, first_non_rtm_text.?);
        alloc.free(text_status);
        text_status = try alloc.dupe(u8, "single_source");
    } else if (non_rtm_count > 1 and !non_rtm_conflict and first_non_rtm_text != null) {
        effective_statement = try alloc.dupe(u8, first_non_rtm_text.?);
        alloc.free(text_status);
        text_status = try alloc.dupe(u8, "aligned");
    } else if (non_rtm_count > 1 and non_rtm_conflict) {
        if (authoritative_source) |value| {
            alloc.free(value);
            authoritative_source = null;
        }
        alloc.free(text_status);
        text_status = try alloc.dupe(u8, "conflict");
    }

    return .{
        .effective_statement = effective_statement,
        .authoritative_source = authoritative_source,
        .text_status = text_status,
        .source_count = assertions.items.len,
        .assertions = try assertions.toOwnedSlice(alloc),
    };
}
