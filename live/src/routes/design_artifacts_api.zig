const std = @import("std");
const Allocator = std.mem.Allocator;

const artifact_discriminator = @import("../artifact_discriminator.zig");
const design_artifacts = @import("../design_artifacts.zig");
const graph_live = @import("../graph_live.zig");
const test_results_auth = @import("../test_results_auth.zig");
const workspace_state = @import("../workspace_state.zig");
const shared = @import("shared.zig");

fn validationErrorJson(code: []const u8, detail: []const u8, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"error\":");
    try shared.appendJsonStr(&buf, code, alloc);
    try buf.appendSlice(alloc, ",\"detail\":");
    try shared.appendJsonStr(&buf, detail, alloc);
    try buf.append(alloc, '}');
    return alloc.dupe(u8, buf.items);
}

pub fn handleListArtifactsResponse(
    db: *graph_live.GraphDb,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    const body = try design_artifacts.listArtifactsJson(db, alloc);
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handleGetArtifactResponse(
    db: *graph_live.GraphDb,
    artifact_id: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    const body = design_artifacts.getArtifactJson(db, artifact_id, alloc) catch |err| switch (err) {
        error.NotFound => return shared.jsonRouteResponse(
            .not_found,
            try validationErrorJson("artifact_not_found", "No matching design artifact was found.", alloc),
            false,
        ),
        else => return err,
    };
    return shared.jsonRouteResponse(.ok, body, true);
}

pub fn handlePostUploadResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    content_type: ?[]const u8,
    body: []const u8,
    inbox_dir: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    const upload = parseArtifactUpload(content_type, body, alloc) catch |err| switch (err) {
        error.InvalidUpload => {
            std.log.warn("design artifact upload rejected reason=invalid_upload", .{});
            return shared.jsonRouteResponse(
                .bad_request,
                try validationErrorJson("invalid_upload", "Upload must include file and kind fields.", alloc),
                false,
            );
        },
        error.UnsupportedContentType => {
            std.log.warn("design artifact upload rejected reason=unsupported_content_type", .{});
            return shared.jsonRouteResponse(
                .unsupported_media_type,
                try validationErrorJson("unsupported_content_type", "Upload must use multipart/form-data.", alloc),
                false,
            );
        },
        else => return err,
    };
    defer upload.deinit(alloc);

    const kind = design_artifacts.ArtifactKind.fromString(upload.kind) orelse {
            std.log.warn("design artifact upload rejected filename={s} kind={s} reason=invalid_kind", .{ upload.filename, upload.kind });
            return shared.jsonRouteResponse(
                .bad_request,
                try validationErrorJson("invalid_kind", "kind must be urs_docx, srs_docx, swrs_docx, hrs_docx, sysrd_docx, or rtm_workbook.", alloc),
                false,
            );
        };

    const logical_key = try artifact_discriminator.slugLogicalKeyFromFilename(upload.filename, alloc);
    defer alloc.free(logical_key);
    const display_name = upload.display_name orelse upload.filename;
    if (std.mem.endsWith(u8, upload.filename, ".docx")) {
        if (!kind.isRequirementDocKind()) {
            std.log.warn("design artifact upload rejected filename={s} kind={s} reason=invalid_kind_for_extension", .{ upload.filename, upload.kind });
            return shared.jsonRouteResponse(.bad_request, try validationErrorJson("invalid_kind", ".docx uploads require a requirement-document kind (urs_docx, srs_docx, swrs_docx, hrs_docx, or sysrd_docx).", alloc), false);
        }
    } else if (std.mem.endsWith(u8, upload.filename, ".xlsx")) {
        if (kind != .rtm_workbook) {
            std.log.warn("design artifact upload rejected filename={s} kind={s} reason=invalid_kind_for_extension", .{ upload.filename, upload.kind });
            return shared.jsonRouteResponse(.bad_request, try validationErrorJson("invalid_kind", ".xlsx uploads require kind rtm_workbook.", alloc), false);
        }
    } else {
        std.log.warn("design artifact upload rejected filename={s} kind={s} reason=invalid_extension", .{ upload.filename, upload.kind });
        return shared.jsonRouteResponse(.bad_request, try validationErrorJson("invalid_upload", "Design artifact uploads must be .docx or .xlsx.", alloc), false);
    }

    const stored_path = try storeUpload(inbox_dir, kind, logical_key, upload.filename, upload.file_bytes, alloc);
    defer alloc.free(stored_path);
    var validation = try artifact_discriminator.validateDeclaredUpload(stored_path, upload.filename, kind, alloc);
    defer validation.deinit(alloc);
    if (!validation.accepted) {
        std.log.warn(
            "design artifact upload rejected filename={s} kind={s} reason={s}",
            .{ upload.filename, upload.kind, validation.reason_code },
        );
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("invalid_kind", validation.reason, alloc),
            false,
        );
    }
    var ingest_result = switch (kind) {
        .urs_docx, .srs_docx, .swrs_docx, .hrs_docx, .sysrd_docx => design_artifacts.ingestDocxPath(db, stored_path, kind, logical_key, display_name, "dashboard_upload", alloc),
        .rtm_workbook => design_artifacts.ingestRtmWorkbookPath(db, stored_path, logical_key, display_name, "dashboard_upload", alloc),
    } catch |err| {
        std.log.warn("design artifact upload rejected filename={s} kind={s} reason={s}", .{ upload.filename, upload.kind, @errorName(err) });
        return err;
    };
    defer ingest_result.deinit(alloc);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(alloc);
    try resp.appendSlice(alloc, "{\"artifact_id\":");
    try shared.appendJsonStr(&resp, ingest_result.artifact_id, alloc);
    try resp.appendSlice(alloc, ",\"path\":");
    try shared.appendJsonStr(&resp, stored_path, alloc);
    try resp.appendSlice(alloc, ",\"kind\":");
    try shared.appendJsonStr(&resp, upload.kind, alloc);
    try resp.appendSlice(alloc, ",\"ingest_summary\":");
    try appendIngestSummaryJson(&resp, ingest_result.summary, alloc);
    try resp.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, resp.items), true);
}

pub fn handlePostOnboardingSourceArtifactResponse(
    db: *graph_live.GraphDb,
    content_type: ?[]const u8,
    body: []const u8,
    inbox_dir: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    const upload = parseOnboardingArtifactUpload(content_type, body, alloc) catch |err| switch (err) {
        error.InvalidUpload => {
            std.log.warn("onboarding artifact upload rejected reason=invalid_upload", .{});
            return shared.jsonRouteResponse(
                .bad_request,
                try validationErrorJson("invalid_upload", "Upload must include a file field.", alloc),
                false,
            );
        },
        error.UnsupportedContentType => {
            std.log.warn("onboarding artifact upload rejected reason=unsupported_content_type", .{});
            return shared.jsonRouteResponse(
                .unsupported_media_type,
                try validationErrorJson("unsupported_content_type", "Upload must use multipart/form-data.", alloc),
                false,
            );
        },
        else => return err,
    };
    defer upload.deinit(alloc);

    if (!(std.mem.endsWith(u8, upload.filename, ".docx") or std.mem.endsWith(u8, upload.filename, ".xlsx"))) {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("invalid_upload", "Onboarding uploads must be a .docx requirements document or an .xlsx RTM workbook.", alloc),
            false,
        );
    }

    const logical_key = try artifact_discriminator.slugLogicalKeyFromFilename(upload.filename, alloc);
    defer alloc.free(logical_key);
    const stored_path = try storeOnboardingUpload(inbox_dir, logical_key, upload.filename, upload.file_bytes, alloc);
    defer alloc.free(stored_path);

    var discrimination = try artifact_discriminator.discriminateInboxPath(stored_path, upload.filename, alloc);
    defer discrimination.deinit(alloc);
    if (!discrimination.accepted or discrimination.kind == null) {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson(discrimination.reason_code, discrimination.reason, alloc),
            false,
        );
    }

    const artifact_kind = artifact_discriminator.candidateKindToDesignArtifactKind(discrimination.kind.?) orelse {
        return shared.jsonRouteResponse(
            .bad_request,
            try validationErrorJson("unsupported_artifact", "Onboarding accepts requirement documents and RTM workbooks only.", alloc),
            false,
        );
    };
    const display_name = upload.display_name orelse upload.filename;
    var ingest_result = switch (artifact_kind) {
        .urs_docx, .srs_docx, .swrs_docx, .hrs_docx, .sysrd_docx => design_artifacts.ingestDocxPath(db, stored_path, artifact_kind, logical_key, display_name, "onboarding_upload", alloc),
        .rtm_workbook => design_artifacts.ingestRtmWorkbookPath(db, stored_path, logical_key, display_name, "onboarding_upload", alloc),
    } catch |err| {
        std.log.warn("onboarding artifact upload rejected filename={s} reason={s}", .{ upload.filename, @errorName(err) });
        return err;
    };
    defer ingest_result.deinit(alloc);

    try workspace_state.writeWorkspaceReady(db, true);
    try workspace_state.writeSourceOfTruth(db, if (artifact_kind == .rtm_workbook) .workbook_first else .document_first);
    try workspace_state.clearAttachWorkbookPromptDismissed(db);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(alloc);
    try resp.appendSlice(alloc, "{\"artifact_id\":");
    try shared.appendJsonStr(&resp, ingest_result.artifact_id, alloc);
    try resp.appendSlice(alloc, ",\"path\":");
    try shared.appendJsonStr(&resp, stored_path, alloc);
    try resp.appendSlice(alloc, ",\"kind\":");
    try shared.appendJsonStr(&resp, artifact_kind.toString(), alloc);
    try resp.appendSlice(alloc, ",\"source_of_truth\":");
    try shared.appendJsonStr(&resp, if (artifact_kind == .rtm_workbook)
        workspace_state.SourceOfTruth.workbook_first.asString()
    else
        workspace_state.SourceOfTruth.document_first.asString(), alloc);
    try resp.appendSlice(alloc, ",\"ingest_summary\":");
    try appendIngestSummaryJson(&resp, ingest_result.summary, alloc);
    try resp.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, resp.items), true);
}

pub fn handleReingestArtifactResponse(
    db: *graph_live.GraphDb,
    auth: *test_results_auth.AuthState,
    authorization: ?[]const u8,
    artifact_id: []const u8,
    alloc: Allocator,
) !shared.JsonRouteResponse {
    if (!auth.validateBearerHeader(authorization)) {
        return shared.jsonRouteResponse(.unauthorized, try alloc.dupe(u8, ""), false);
    }
    var ingest_result = design_artifacts.reingestArtifact(db, artifact_id, alloc) catch |err| switch (err) {
        error.NotFound => return shared.jsonRouteResponse(
            .not_found,
            try validationErrorJson("artifact_not_found", "No matching design artifact was found.", alloc),
            false,
        ),
        else => return err,
    };
    defer ingest_result.deinit(alloc);

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(alloc);
    try resp.appendSlice(alloc, "{\"ok\":true,\"artifact_id\":");
    try shared.appendJsonStr(&resp, ingest_result.artifact_id, alloc);
    try resp.appendSlice(alloc, ",\"ingest_summary\":");
    try appendIngestSummaryJson(&resp, ingest_result.summary, alloc);
    try resp.append(alloc, '}');
    return shared.jsonRouteResponse(.ok, try alloc.dupe(u8, resp.items), true);
}

const Upload = struct {
    filename: []const u8,
    kind: []const u8,
    file_bytes: []const u8,
    display_name: ?[]const u8,

    fn deinit(self: Upload, alloc: Allocator) void {
        alloc.free(self.filename);
        alloc.free(self.kind);
        alloc.free(self.file_bytes);
        if (self.display_name) |value| alloc.free(value);
    }
};

const OnboardingUpload = struct {
    filename: []const u8,
    file_bytes: []const u8,
    display_name: ?[]const u8,

    fn deinit(self: OnboardingUpload, alloc: Allocator) void {
        alloc.free(self.filename);
        alloc.free(self.file_bytes);
        if (self.display_name) |value| alloc.free(value);
    }
};

fn parseArtifactUpload(content_type: ?[]const u8, body: []const u8, alloc: Allocator) !Upload {
    const value = content_type orelse return error.UnsupportedContentType;
    if (std.mem.indexOf(u8, value, "multipart/form-data") == null) return error.UnsupportedContentType;
    const boundary_key = "boundary=";
    const boundary_pos = std.mem.indexOf(u8, value, boundary_key) orelse return error.UnsupportedContentType;
    const boundary = value[boundary_pos + boundary_key.len ..];
    if (boundary.len == 0) return error.UnsupportedContentType;
    const delimiter = try std.fmt.allocPrint(alloc, "--{s}", .{boundary});
    defer alloc.free(delimiter);

    var filename: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var file_bytes: ?[]const u8 = null;
    var display_name: ?[]const u8 = null;

    var search_start: usize = 0;
    while (true) {
        const start_rel = std.mem.indexOfPos(u8, body, search_start, delimiter) orelse break;
        var part_start = start_rel + delimiter.len;
        if (part_start + 1 < body.len and body[part_start] == '\r' and body[part_start + 1] == '\n') part_start += 2;
        const header_end = std.mem.indexOfPos(u8, body, part_start, "\r\n\r\n") orelse break;
        const headers = body[part_start..header_end];
        const part_body_start = header_end + 4;
        const next_rel = std.mem.indexOfPos(u8, body, part_body_start, delimiter) orelse break;
        var part_body_end = next_rel;
        while (part_body_end > part_body_start and (body[part_body_end - 1] == '\n' or body[part_body_end - 1] == '\r')) : (part_body_end -= 1) {}

        const name = extractDispositionValue(headers, "name") orelse {
            search_start = next_rel;
            continue;
        };
        if (std.mem.eql(u8, name, "file")) {
            const part_filename = extractDispositionValue(headers, "filename") orelse return error.InvalidUpload;
            filename = try alloc.dupe(u8, part_filename);
            file_bytes = try alloc.dupe(u8, body[part_body_start..part_body_end]);
        } else if (std.mem.eql(u8, name, "kind")) {
            kind = try alloc.dupe(u8, std.mem.trim(u8, body[part_body_start..part_body_end], " \t\r\n"));
        } else if (std.mem.eql(u8, name, "display_name")) {
            const trimmed = std.mem.trim(u8, body[part_body_start..part_body_end], " \t\r\n");
            if (trimmed.len > 0) display_name = try alloc.dupe(u8, trimmed);
        }
        search_start = next_rel;
    }

    if (filename == null or kind == null or file_bytes == null) return error.InvalidUpload;
    return .{
        .filename = filename.?,
        .kind = kind.?,
        .file_bytes = file_bytes.?,
        .display_name = display_name,
    };
}

fn parseOnboardingArtifactUpload(content_type: ?[]const u8, body: []const u8, alloc: Allocator) !OnboardingUpload {
    const value = content_type orelse return error.UnsupportedContentType;
    if (std.mem.indexOf(u8, value, "multipart/form-data") == null) return error.UnsupportedContentType;
    const boundary_key = "boundary=";
    const boundary_pos = std.mem.indexOf(u8, value, boundary_key) orelse return error.UnsupportedContentType;
    const boundary = value[boundary_pos + boundary_key.len ..];
    if (boundary.len == 0) return error.UnsupportedContentType;
    const delimiter = try std.fmt.allocPrint(alloc, "--{s}", .{boundary});
    defer alloc.free(delimiter);

    var filename: ?[]const u8 = null;
    var file_bytes: ?[]const u8 = null;
    var display_name: ?[]const u8 = null;

    var search_start: usize = 0;
    while (true) {
        const start_rel = std.mem.indexOfPos(u8, body, search_start, delimiter) orelse break;
        var part_start = start_rel + delimiter.len;
        if (part_start + 1 < body.len and body[part_start] == '\r' and body[part_start + 1] == '\n') part_start += 2;
        const header_end = std.mem.indexOfPos(u8, body, part_start, "\r\n\r\n") orelse break;
        const headers = body[part_start..header_end];
        const part_body_start = header_end + 4;
        const next_rel = std.mem.indexOfPos(u8, body, part_body_start, delimiter) orelse break;
        var part_body_end = next_rel;
        while (part_body_end > part_body_start and (body[part_body_end - 1] == '\n' or body[part_body_end - 1] == '\r')) : (part_body_end -= 1) {}

        const name = extractDispositionValue(headers, "name") orelse {
            search_start = next_rel;
            continue;
        };
        if (std.mem.eql(u8, name, "file")) {
            const part_filename = extractDispositionValue(headers, "filename") orelse return error.InvalidUpload;
            filename = try alloc.dupe(u8, part_filename);
            file_bytes = try alloc.dupe(u8, body[part_body_start..part_body_end]);
        } else if (std.mem.eql(u8, name, "display_name")) {
            const trimmed = std.mem.trim(u8, body[part_body_start..part_body_end], " \t\r\n");
            if (trimmed.len > 0) display_name = try alloc.dupe(u8, trimmed);
        }
        search_start = next_rel;
    }

    if (filename == null or file_bytes == null) return error.InvalidUpload;
    return .{
        .filename = filename.?,
        .file_bytes = file_bytes.?,
        .display_name = display_name,
    };
}

fn extractDispositionValue(headers: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=\"", .{key}) catch return null;
    const pos = std.mem.indexOf(u8, headers, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOfScalarPos(u8, headers, start, '"') orelse return null;
    return headers[start..end];
}

fn storeUpload(inbox_dir: []const u8, kind: design_artifacts.ArtifactKind, logical_key: []const u8, filename: []const u8, bytes: []const u8, alloc: Allocator) ![]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ inbox_dir, "processed", "design-artifacts", kind.toString() });
    defer alloc.free(dir_path);
    try std.fs.cwd().makePath(dir_path);
    const ext = std.fs.path.extension(filename);
    const stored_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ logical_key, if (ext.len > 0) ext else ".bin" });
    defer alloc.free(stored_name);
    const full_path = try std.fs.path.join(alloc, &.{ dir_path, stored_name });
    try std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = bytes });
    return full_path;
}

fn storeOnboardingUpload(inbox_dir: []const u8, logical_key: []const u8, filename: []const u8, bytes: []const u8, alloc: Allocator) ![]const u8 {
    const dir_path = try std.fs.path.join(alloc, &.{ inbox_dir, "processed", "onboarding-source-artifacts" });
    defer alloc.free(dir_path);
    try std.fs.cwd().makePath(dir_path);
    const ext = std.fs.path.extension(filename);
    const stored_name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ logical_key, if (ext.len > 0) ext else ".bin" });
    defer alloc.free(stored_name);
    const full_path = try std.fs.path.join(alloc, &.{ dir_path, stored_name });
    try std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = bytes });
    return full_path;
}

fn appendIngestSummaryJson(buf: *std.ArrayList(u8), summary: design_artifacts.IngestSummary, alloc: Allocator) !void {
    try buf.appendSlice(alloc, "{\"artifact_id\":");
    try shared.appendJsonStr(buf, summary.artifact_id, alloc);
    try buf.appendSlice(alloc, ",\"kind\":");
    try shared.appendJsonStr(buf, summary.kind.toString(), alloc);
    try std.fmt.format(buf.writer(alloc), ",\"requirements_seen\":{d},\"nodes_added\":{d},\"nodes_updated\":{d},\"nodes_deleted\":{d},\"unchanged\":{d},\"conflicts_detected\":{d},\"null_text_count\":{d},\"low_confidence_count\":{d},\"diagnostics_emitted\":{d},\"timestamp\":{d},\"disposition\":", .{
        summary.requirements_seen,
        summary.nodes_added,
        summary.nodes_updated,
        summary.nodes_deleted,
        summary.unchanged,
        summary.conflicts_detected,
        summary.null_text_count,
        summary.low_confidence_count,
        summary.diagnostics_emitted,
        summary.timestamp,
    });
    try shared.appendJsonStr(buf, summary.disposition.toString(), alloc);
    try buf.appendSlice(alloc, ",\"new_since_last_ingest\":[");
    for (summary.new_since_last_ingest, 0..) |req_id, idx| {
        if (idx > 0) try buf.append(alloc, ',');
        try shared.appendJsonStr(buf, req_id, alloc);
    }
    try buf.appendSlice(alloc, "]}");
}
