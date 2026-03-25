const std = @import("std");
const Allocator = std.mem.Allocator;

const design_artifacts = @import("design_artifacts.zig");
const xlsx = @import("rtmify").xlsx;

pub const CandidateKind = enum {
    rtm_workbook,
    urs_docx,
    srs_docx,
    swrs_docx,
    hrs_docx,
    sysrd_docx,
    bom,
    soup,
    test_results,

    pub fn toString(self: CandidateKind) []const u8 {
        return switch (self) {
            .rtm_workbook => "rtm_workbook",
            .urs_docx => "urs_docx",
            .srs_docx => "srs_docx",
            .swrs_docx => "swrs_docx",
            .hrs_docx => "hrs_docx",
            .sysrd_docx => "sysrd_docx",
            .bom => "bom",
            .soup => "soup",
            .test_results => "test_results",
        };
    }
};

pub const Confidence = enum {
    low,
    medium,
    high,

    pub fn toString(self: Confidence) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

pub const SignalKind = enum {
    extension,
    filename_token,
    docx_heading_keyword,
    docx_id_family,
    docx_assertion_count,
    xlsx_sheet_name,
    xlsx_required_sheet_set,
    xlsx_bom_shape,
    xlsx_soup_shape,
    json_top_level_key,
    csv_header_shape,
};

pub const Signal = struct {
    kind: SignalKind,
    detail: []const u8,
    weight: i16,
};

pub const DiscriminationResult = struct {
    accepted: bool,
    kind: ?CandidateKind,
    confidence: Confidence,
    reason_code: []const u8,
    reason: []const u8,
    filename_stem_slug: []const u8,
    signals: []Signal,

    pub fn deinit(self: *DiscriminationResult, alloc: Allocator) void {
        alloc.free(self.reason_code);
        alloc.free(self.reason);
        alloc.free(self.filename_stem_slug);
        for (self.signals) |signal| alloc.free(signal.detail);
        alloc.free(self.signals);
    }
};

const CandidateScore = struct {
    kind: CandidateKind,
    score: i16 = 0,
};

pub fn candidateKindToDesignArtifactKind(kind: CandidateKind) ?design_artifacts.ArtifactKind {
    return switch (kind) {
        .rtm_workbook => .rtm_workbook,
        .urs_docx => .urs_docx,
        .srs_docx => .srs_docx,
        .swrs_docx => .swrs_docx,
        .hrs_docx => .hrs_docx,
        .sysrd_docx => .sysrd_docx,
        else => null,
    };
}

pub fn slugLogicalKeyFromFilename(filename: []const u8, alloc: Allocator) ![]u8 {
    const stem = std.fs.path.stem(filename);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var last_dash = false;
    for (stem) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buf.append(alloc, std.ascii.toLower(c));
            last_dash = false;
        } else if (!last_dash) {
            try buf.append(alloc, '-');
            last_dash = true;
        }
    }
    return alloc.dupe(u8, std.mem.trim(u8, buf.items, "-"));
}

pub fn discriminateInboxPath(path: []const u8, filename: []const u8, alloc: Allocator) !DiscriminationResult {
    const extension = std.fs.path.extension(filename);
    if (std.ascii.eqlIgnoreCase(extension, ".docx")) {
        return discriminateDocxPath(path, filename, alloc);
    }
    if (std.ascii.eqlIgnoreCase(extension, ".xlsx")) {
        return discriminateXlsxPath(path, filename, alloc);
    }
    if (std.ascii.eqlIgnoreCase(extension, ".json")) {
        return discriminateJsonPath(path, filename, alloc);
    }
    if (std.ascii.eqlIgnoreCase(extension, ".csv")) {
        return discriminateCsvPath(path, filename, alloc);
    }
    return rejectResult(filename, null, .low, "UNSUPPORTED_EXTENSION", "Inbox only accepts .docx, .xlsx, .json, or .csv.", &.{}, alloc);
}

pub fn validateDeclaredUpload(
    path: []const u8,
    filename: []const u8,
    declared_kind: design_artifacts.ArtifactKind,
    alloc: Allocator,
) !DiscriminationResult {
    var result = try discriminateInboxPath(path, filename, alloc);
    errdefer result.deinit(alloc);
    if (!result.accepted) return result;

    const actual_design_kind = if (result.kind) |kind| candidateKindToDesignArtifactKind(kind) else null;
    if (actual_design_kind != declared_kind) {
        const actual = if (result.kind) |kind| kind.toString() else "unknown";
        alloc.free(result.reason_code);
        alloc.free(result.reason);
        result.accepted = false;
        result.reason_code = try alloc.dupe(u8, "DECLARED_KIND_MISMATCH");
        result.reason = try std.fmt.allocPrint(
            alloc,
            "Declared kind {s} does not match classified file kind {s}.",
            .{ declared_kind.toString(), actual },
        );
        return result;
    }
    return result;
}

fn discriminateDocxPath(path: []const u8, filename: []const u8, alloc: Allocator) !DiscriminationResult {
    var signals: std.ArrayList(Signal) = .empty;
    defer {
        for (signals.items) |signal| alloc.free(signal.detail);
        signals.deinit(alloc);
    }

    try addSignal(&signals, .extension, "docx", 0, alloc);

    const tokens = try filenameTokens(filename, alloc);
    defer {
        for (tokens) |token| alloc.free(token);
        alloc.free(tokens);
    }

    for (tokens) |token| {
        if (std.mem.eql(u8, token, "urs") or
            std.mem.eql(u8, token, "user") or
            std.mem.eql(u8, token, "srs") or
            std.mem.eql(u8, token, "swrs") or
            std.mem.eql(u8, token, "software") or
            std.mem.eql(u8, token, "hrs") or
            std.mem.eql(u8, token, "hardware") or
            std.mem.eql(u8, token, "sysrd") or
            std.mem.eql(u8, token, "srd") or
            std.mem.eql(u8, token, "system"))
        {
            try addSignal(&signals, .filename_token, token, 10, alloc);
        }
    }

    var assertions = design_artifacts.parseDocxAssertions(path, alloc) catch {
        return rejectResult(filename, null, .low, "DOCX_PARSE_FAILED", "Could not parse DOCX content.", signals.items, alloc);
    };
    defer {
        for (assertions.items) |item| {
            alloc.free(item.req_id);
            alloc.free(item.section);
            if (item.text) |value| alloc.free(value);
            if (item.normalized_text) |value| alloc.free(value);
            alloc.free(item.parse_status);
        }
        assertions.deinit(alloc);
    }

    if (assertions.items.len == 0) {
        return rejectResult(filename, null, .low, "DOCX_NO_ASSERTIONS", "DOCX file did not contain recognizable requirement assertions.", signals.items, alloc);
    }

    {
        const detail = try std.fmt.allocPrint(alloc, "{d}", .{assertions.items.len});
        defer alloc.free(detail);
        try addSignal(&signals, .docx_assertion_count, detail, 0, alloc);
    }

    var urs_count: usize = 0;
    var srs_count: usize = 0;
    var swrs_count: usize = 0;
    var hrs_count: usize = 0;
    var req_count: usize = 0;
    var other_count: usize = 0;
    for (assertions.items) |item| {
        if (startsWithIgnoreCase(item.req_id, "URS-")) {
            urs_count += 1;
        } else if (startsWithIgnoreCase(item.req_id, "SWRS-")) {
            swrs_count += 1;
        } else if (startsWithIgnoreCase(item.req_id, "HRS-")) {
            hrs_count += 1;
        } else if (startsWithIgnoreCase(item.req_id, "SRS-")) {
            srs_count += 1;
        } else if (startsWithIgnoreCase(item.req_id, "REQ-")) {
            req_count += 1;
        } else {
            other_count += 1;
        }
    }
    if (urs_count > 0) {
        const detail = try std.fmt.allocPrint(alloc, "URS:{d}", .{urs_count});
        defer alloc.free(detail);
        try addSignal(&signals, .docx_id_family, detail, if (urs_count >= 3) 35 else 0, alloc);
    }
    if (srs_count > 0) {
        const detail = try std.fmt.allocPrint(alloc, "SRS:{d}", .{srs_count});
        defer alloc.free(detail);
        try addSignal(&signals, .docx_id_family, detail, if (srs_count >= 3) 35 else 0, alloc);
    }
    if (swrs_count > 0) {
        const detail = try std.fmt.allocPrint(alloc, "SWRS:{d}", .{swrs_count});
        defer alloc.free(detail);
        try addSignal(&signals, .docx_id_family, detail, if (swrs_count >= 3) 35 else 0, alloc);
    }
    if (hrs_count > 0) {
        const detail = try std.fmt.allocPrint(alloc, "HRS:{d}", .{hrs_count});
        defer alloc.free(detail);
        try addSignal(&signals, .docx_id_family, detail, if (hrs_count >= 3) 35 else 0, alloc);
    }
    if (req_count > 0) {
        const detail = try std.fmt.allocPrint(alloc, "REQ:{d}", .{req_count});
        defer alloc.free(detail);
        try addSignal(&signals, .docx_id_family, detail, if (req_count >= 3) 35 else 0, alloc);
    }
    if (other_count > 0) {
        const detail = try std.fmt.allocPrint(alloc, "OTHER:{d}", .{other_count});
        defer alloc.free(detail);
        try addSignal(&signals, .docx_id_family, detail, 0, alloc);
    }

    const all_text = design_artifacts.extractDocxAllText(path, alloc) catch {
        return rejectResult(filename, null, .low, "DOCX_PARSE_FAILED", "Could not extract DOCX text.", signals.items, alloc);
    };
    defer alloc.free(all_text);
    const lower_text = try asciiLowerDup(all_text, alloc);
    defer alloc.free(lower_text);

    var urs_score = CandidateScore{ .kind = .urs_docx };
    var srs_score = CandidateScore{ .kind = .srs_docx };
    var swrs_score = CandidateScore{ .kind = .swrs_docx };
    var hrs_score = CandidateScore{ .kind = .hrs_docx };
    var sysrd_score = CandidateScore{ .kind = .sysrd_docx };

    const has_urs_spec = containsPhrase(lower_text, "user requirements specification");
    const has_swrs_spec = containsPhrase(lower_text, "software requirements specification");
    const has_hrs_spec = containsPhrase(lower_text, "hardware requirements specification");
    const has_srs_spec = containsPhrase(lower_text, "system requirements specification");
    const has_sysrd_doc = containsPhrase(lower_text, "system requirements document");

    if (has_urs_spec) {
        urs_score.score += 60;
        try addSignal(&signals, .docx_heading_keyword, "user requirements specification", 60, alloc);
    }
    if (has_swrs_spec) {
        swrs_score.score += 60;
        try addSignal(&signals, .docx_heading_keyword, "software requirements specification", 60, alloc);
    }
    if (has_hrs_spec) {
        hrs_score.score += 60;
        try addSignal(&signals, .docx_heading_keyword, "hardware requirements specification", 60, alloc);
    }
    if (has_srs_spec) {
        srs_score.score += 60;
        try addSignal(&signals, .docx_heading_keyword, "system requirements specification", 60, alloc);
    }
    if (has_sysrd_doc) {
        sysrd_score.score += 60;
        try addSignal(&signals, .docx_heading_keyword, "system requirements document", 60, alloc);
    }

    if (!has_urs_spec and containsPhrase(lower_text, "user requirements")) {
        urs_score.score += 40;
        try addSignal(&signals, .docx_heading_keyword, "user requirements", 40, alloc);
    }
    if (!has_swrs_spec and containsPhrase(lower_text, "software requirements")) {
        swrs_score.score += 40;
        try addSignal(&signals, .docx_heading_keyword, "software requirements", 40, alloc);
    }
    if (!has_hrs_spec and containsPhrase(lower_text, "hardware requirements")) {
        hrs_score.score += 40;
        try addSignal(&signals, .docx_heading_keyword, "hardware requirements", 40, alloc);
    }
    if (!has_srs_spec and !has_sysrd_doc and containsPhrase(lower_text, "system requirements")) {
        srs_score.score += 35;
        sysrd_score.score += 25;
        try addSignal(&signals, .docx_heading_keyword, "system requirements", 35, alloc);
    }

    if (containsPhrase(lower_text, "intended use") or
        containsPhrase(lower_text, "environment of use") or
        containsPhrase(lower_text, "clinical"))
    {
        urs_score.score += 15;
    }
    if (containsPhrase(lower_text, "software interface") or
        containsPhrase(lower_text, "error handling") or
        containsPhrase(lower_text, "data security") or
        containsPhrase(lower_text, "algorithm"))
    {
        swrs_score.score += 15;
    }
    if (containsPhrase(lower_text, "emi") or
        containsPhrase(lower_text, "emc") or
        containsPhrase(lower_text, "vibration") or
        containsPhrase(lower_text, "material") or
        containsPhrase(lower_text, "lifecycle") or
        containsPhrase(lower_text, "thermal"))
    {
        hrs_score.score += 15;
    }

    if (containsStandaloneToken(tokens, "urs")) urs_score.score += 25;
    if (containsStandaloneToken(tokens, "srs")) srs_score.score += 25;
    if (containsStandaloneToken(tokens, "swrs")) swrs_score.score += 25;
    if (containsStandaloneToken(tokens, "hrs")) hrs_score.score += 25;
    if (containsStandaloneToken(tokens, "sysrd") or containsStandaloneToken(tokens, "srd")) sysrd_score.score += 25;

    if (urs_count >= 3) urs_score.score += 35;
    if (srs_count >= 3) srs_score.score += 35;
    if (swrs_count >= 3) swrs_score.score += 35;
    if (hrs_count >= 3) hrs_score.score += 35;
    if (req_count >= 3) sysrd_score.score += 35;
    if (urs_count >= srs_count + swrs_count + hrs_count + req_count + 2) urs_score.score += 20;
    if (srs_count >= urs_count + swrs_count + hrs_count + req_count + 2) srs_score.score += 20;
    if (swrs_count >= urs_count + srs_count + hrs_count + req_count + 2) swrs_score.score += 20;
    if (hrs_count >= urs_count + srs_count + swrs_count + req_count + 2) hrs_score.score += 20;
    if (req_count >= urs_count + srs_count + swrs_count + hrs_count + 2) sysrd_score.score += 20;

    if (containsToken(tokens, "urs") or containsToken(tokens, "user")) urs_score.score += 10;
    if (containsToken(tokens, "srs")) srs_score.score += 10;
    if (containsToken(tokens, "swrs") or containsToken(tokens, "software")) swrs_score.score += 10;
    if (containsToken(tokens, "hrs") or containsToken(tokens, "hardware")) hrs_score.score += 10;
    if (containsToken(tokens, "sysrd") or containsToken(tokens, "srd") or containsToken(tokens, "system")) sysrd_score.score += 10;

    const scores = [_]CandidateScore{ urs_score, srs_score, swrs_score, hrs_score, sysrd_score };
    var top = scores[0];
    var runner_up = scores[1];
    if (runner_up.score > top.score) {
        const tmp = top;
        top = runner_up;
        runner_up = tmp;
    }
    for (scores[2..]) |score| {
        if (score.score > top.score) {
            runner_up = top;
            top = score;
        } else if (score.score > runner_up.score) {
            runner_up = score;
        }
    }
    const lead = top.score - runner_up.score;
    if (top.score >= 45 and lead >= 20) {
        return acceptResult(filename, top.kind, .high, "CLASSIFIED", "DOCX classification succeeded.", signals.items, alloc);
    }
    if (top.score >= 45) {
        const legacy_fallback: CandidateKind = if (sysrd_score.score >= srs_score.score and sysrd_score.score >= 45) .sysrd_docx else .srs_docx;
        return acceptResult(filename, legacy_fallback, .medium, "CLASSIFIED", "DOCX classified to conservative legacy requirement-document kind.", signals.items, alloc);
    }
    if (lead < 20) {
        return rejectResult(filename, top.kind, .medium, "DOCX_AMBIGUOUS_KIND", "DOCX signals were too mixed to classify safely.", signals.items, alloc);
    }
    return rejectResult(filename, top.kind, .medium, "DOCX_WEAK_CLASSIFICATION", "DOCX classification evidence was too weak.", signals.items, alloc);
}

fn discriminateXlsxPath(path: []const u8, filename: []const u8, alloc: Allocator) !DiscriminationResult {
    var signals: std.ArrayList(Signal) = .empty;
    defer {
        for (signals.items) |signal| alloc.free(signal.detail);
        signals.deinit(alloc);
    }

    try addSignal(&signals, .extension, "xlsx", 0, alloc);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sheets = xlsx.parse(arena_state.allocator(), path) catch {
        return rejectResult(filename, null, .low, "XLSX_PARSE_FAILED", "Could not parse XLSX workbook.", signals.items, alloc);
    };

    var has_requirements = false;
    var has_user_needs = false;
    var has_tests = false;
    var has_risks = false;
    var has_bom = false;
    var has_soup = false;

    for (sheets) |sheet| {
        const trimmed = std.mem.trim(u8, sheet.name, " \t\r\n");
        try addSignal(&signals, .xlsx_sheet_name, trimmed, 0, alloc);
        if (std.ascii.eqlIgnoreCase(trimmed, "Requirements")) has_requirements = true;
        if (std.ascii.eqlIgnoreCase(trimmed, "User Needs")) has_user_needs = true;
        if (std.ascii.eqlIgnoreCase(trimmed, "Tests")) has_tests = true;
        if (std.ascii.eqlIgnoreCase(trimmed, "Risks")) has_risks = true;
        if (std.ascii.eqlIgnoreCase(trimmed, "Design BOM")) has_bom = true;
        if (std.ascii.eqlIgnoreCase(trimmed, "SOUP Components")) has_soup = true;
    }

    const rtm_matches = @as(u8, @intFromBool(has_requirements)) + @as(u8, @intFromBool(has_user_needs)) + @as(u8, @intFromBool(has_tests)) + @as(u8, @intFromBool(has_risks));
    const is_complete_rtm = rtm_matches == 4;
    if (has_requirements) try addSignal(&signals, .xlsx_required_sheet_set, "Requirements", 25, alloc);
    if (has_user_needs) try addSignal(&signals, .xlsx_required_sheet_set, "User Needs", 25, alloc);
    if (has_tests) try addSignal(&signals, .xlsx_required_sheet_set, "Tests", 25, alloc);
    if (has_risks) try addSignal(&signals, .xlsx_required_sheet_set, "Risks", 25, alloc);
    if (has_bom) try addSignal(&signals, .xlsx_bom_shape, "Design BOM", 100, alloc);
    if (has_soup) try addSignal(&signals, .xlsx_soup_shape, "SOUP Components", 100, alloc);

    var recognized: usize = 0;
    if (is_complete_rtm) recognized += 1;
    if (has_bom) recognized += 1;
    if (has_soup) recognized += 1;

    if (recognized > 1) {
        return rejectResult(filename, null, .medium, "XLSX_AMBIGUOUS_KIND", "Workbook matches more than one supported workbook shape.", signals.items, alloc);
    }
    if (has_requirements or has_user_needs or has_tests or has_risks) {
        if (!is_complete_rtm and !has_bom and !has_soup) {
            return rejectResult(filename, .rtm_workbook, .medium, "XLSX_INVALID_RTM_SHAPE", "Workbook looks like RTM content but is missing required sheets.", signals.items, alloc);
        }
    }
    if (is_complete_rtm) {
        design_artifacts.validateRtmWorkbookShape(sheets) catch {
            return rejectResult(filename, .rtm_workbook, .medium, "XLSX_INVALID_RTM_SHAPE", "Workbook is missing required RTM workbook sheets.", signals.items, alloc);
        };
        return acceptResult(filename, .rtm_workbook, .high, "CLASSIFIED", "Workbook classified as RTM workbook.", signals.items, alloc);
    }
    if (has_bom) return acceptResult(filename, .bom, .high, "CLASSIFIED", "Workbook classified as BOM workbook.", signals.items, alloc);
    if (has_soup) return acceptResult(filename, .soup, .high, "CLASSIFIED", "Workbook classified as SOUP workbook.", signals.items, alloc);
    return rejectResult(filename, null, .low, "XLSX_UNSUPPORTED_WORKBOOK", "Workbook did not match RTM, BOM, or SOUP workbook shapes.", signals.items, alloc);
}

fn discriminateJsonPath(path: []const u8, filename: []const u8, alloc: Allocator) !DiscriminationResult {
    var signals: std.ArrayList(Signal) = .empty;
    defer {
        for (signals.items) |signal| alloc.free(signal.detail);
        signals.deinit(alloc);
    }
    try addSignal(&signals, .extension, "json", 0, alloc);

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 25 * 1024 * 1024) catch {
        return rejectResult(filename, null, .low, "JSON_READ_FAILED", "Could not read JSON file.", signals.items, alloc);
    };
    defer alloc.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch {
        return rejectResult(filename, null, .low, "JSON_PARSE_FAILED", "Could not parse JSON file.", signals.items, alloc);
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return rejectResult(filename, null, .low, "JSON_UNSUPPORTED_SHAPE", "JSON top-level value must be an object.", signals.items, alloc);
    }

    const obj = parsed.value.object;
    if (obj.get("test_cases") != null) {
        try addSignal(&signals, .json_top_level_key, "test_cases", 100, alloc);
        return acceptResult(filename, .test_results, .high, "CLASSIFIED", "JSON classified as test results payload.", signals.items, alloc);
    }
    if (obj.get("bom_items") != null) {
        try addSignal(&signals, .json_top_level_key, "bom_items", 100, alloc);
        return acceptResult(filename, .bom, .high, "CLASSIFIED", "JSON classified as BOM payload.", signals.items, alloc);
    }
    if (obj.get("bomFormat")) |value| {
        if (value == .string and std.mem.eql(u8, value.string, "CycloneDX")) {
            try addSignal(&signals, .json_top_level_key, "bomFormat=CycloneDX", 100, alloc);
            return acceptResult(filename, .bom, .high, "CLASSIFIED", "JSON classified as CycloneDX BOM.", signals.items, alloc);
        }
    }
    if (obj.get("spdxVersion") != null) {
        try addSignal(&signals, .json_top_level_key, "spdxVersion", 100, alloc);
        return acceptResult(filename, .bom, .high, "CLASSIFIED", "JSON classified as SPDX BOM.", signals.items, alloc);
    }
    if (obj.get("components") != null) {
        try addSignal(&signals, .json_top_level_key, "components", 100, alloc);
        return acceptResult(filename, .soup, .high, "CLASSIFIED", "JSON classified as SOUP/components payload.", signals.items, alloc);
    }
    return rejectResult(filename, null, .low, "JSON_UNSUPPORTED_SHAPE", "JSON did not match a supported ingest payload shape.", signals.items, alloc);
}

fn discriminateCsvPath(path: []const u8, filename: []const u8, alloc: Allocator) !DiscriminationResult {
    var signals: std.ArrayList(Signal) = .empty;
    defer {
        for (signals.items) |signal| alloc.free(signal.detail);
        signals.deinit(alloc);
    }
    try addSignal(&signals, .extension, "csv", 0, alloc);

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch {
        return rejectResult(filename, null, .low, "CSV_READ_FAILED", "Could not read CSV file.", signals.items, alloc);
    };
    defer alloc.free(bytes);

    if (looksLikeBomCsv(bytes)) {
        try addSignal(&signals, .csv_header_shape, "bom_csv", 100, alloc);
        return acceptResult(filename, .bom, .high, "CLASSIFIED", "CSV classified as BOM payload.", signals.items, alloc);
    }
    return rejectResult(filename, null, .low, "CSV_UNSUPPORTED_SHAPE", "CSV did not match the BOM inbox schema.", signals.items, alloc);
}

fn acceptResult(
    filename: []const u8,
    kind: CandidateKind,
    confidence: Confidence,
    reason_code: []const u8,
    reason: []const u8,
    source_signals: []const Signal,
    alloc: Allocator,
) !DiscriminationResult {
    return .{
        .accepted = true,
        .kind = kind,
        .confidence = confidence,
        .reason_code = try alloc.dupe(u8, reason_code),
        .reason = try alloc.dupe(u8, reason),
        .filename_stem_slug = try slugLogicalKeyFromFilename(filename, alloc),
        .signals = try cloneSignals(source_signals, alloc),
    };
}

fn rejectResult(
    filename: []const u8,
    kind: ?CandidateKind,
    confidence: Confidence,
    reason_code: []const u8,
    reason: []const u8,
    source_signals: []const Signal,
    alloc: Allocator,
) !DiscriminationResult {
    return .{
        .accepted = false,
        .kind = kind,
        .confidence = confidence,
        .reason_code = try alloc.dupe(u8, reason_code),
        .reason = try alloc.dupe(u8, reason),
        .filename_stem_slug = try slugLogicalKeyFromFilename(filename, alloc),
        .signals = try cloneSignals(source_signals, alloc),
    };
}

fn cloneSignals(source_signals: []const Signal, alloc: Allocator) ![]Signal {
    var out = try alloc.alloc(Signal, source_signals.len);
    errdefer alloc.free(out);
    for (source_signals, 0..) |signal, idx| {
        out[idx] = .{
            .kind = signal.kind,
            .detail = try alloc.dupe(u8, signal.detail),
            .weight = signal.weight,
        };
    }
    return out;
}

fn addSignal(list: *std.ArrayList(Signal), kind: SignalKind, detail: []const u8, weight: i16, alloc: Allocator) !void {
    try list.append(alloc, .{
        .kind = kind,
        .detail = try alloc.dupe(u8, detail),
        .weight = weight,
    });
}

fn filenameTokens(filename: []const u8, alloc: Allocator) ![]const []const u8 {
    const stem = std.fs.path.stem(filename);
    const lower = try asciiLowerDup(stem, alloc);
    defer alloc.free(lower);
    for (lower) |*c| {
        if (!(std.ascii.isAlphanumeric(c.*) or c.* == '_')) c.* = ' ';
    }
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |token| alloc.free(token);
        list.deinit(alloc);
    }
    var it = std.mem.tokenizeScalar(u8, lower, ' ');
    while (it.next()) |token| {
        try list.append(alloc, try alloc.dupe(u8, token));
    }
    return list.toOwnedSlice(alloc);
}

fn asciiLowerDup(text: []const u8, alloc: Allocator) ![]u8 {
    const out = try alloc.dupe(u8, text);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn containsPhrase(text: []const u8, phrase: []const u8) bool {
    return std.mem.indexOf(u8, text, phrase) != null;
}

fn containsToken(tokens: []const []const u8, want: []const u8) bool {
    for (tokens) |token| {
        if (std.mem.eql(u8, token, want)) return true;
    }
    return false;
}

fn containsStandaloneToken(tokens: []const []const u8, want: []const u8) bool {
    return containsToken(tokens, want);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn looksLikeBomCsv(body: []const u8) bool {
    const first_newline = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    const header = std.mem.trimRight(u8, body[0..first_newline], "\r");
    return std.mem.indexOf(u8, header, "bom_name") != null and
        std.mem.indexOf(u8, header, "full_identifier") != null and
        std.mem.indexOf(u8, header, "child_part") != null;
}
