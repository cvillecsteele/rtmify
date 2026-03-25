const std = @import("std");
const testing = std.testing;

const artifact_discriminator = @import("artifact_discriminator.zig");
const artifact_test_files = @import("artifact_test_files.zig");
const design_artifacts = @import("design_artifacts.zig");
const external_ingest_inbox = @import("external_ingest_inbox.zig");
const graph_live = @import("graph_live.zig");
const shared = @import("routes/shared.zig");
const design_artifacts_api = @import("routes/design_artifacts_api.zig");
const test_results_auth = @import("test_results_auth.zig");

const UploadRequest = struct {
    content_type: []const u8,
    body: []const u8,

    fn deinit(self: UploadRequest, alloc: std.mem.Allocator) void {
        alloc.free(self.content_type);
        alloc.free(self.body);
    }
};

fn makeTmpPath(tmp: anytype, suffix: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path, suffix });
}

fn writeSrsDocx(path: []const u8, alloc: std.mem.Allocator) !void {
    const paragraphs = [_][]const u8{
        "Software Requirements Specification",
        "SRS-001 - Device shall display heart rate.",
        "SRS-002 - Device shall display SpO2.",
        "SRS-003 - Device shall display battery level.",
    };
    try artifact_test_files.writeMinimalDocx(path, &paragraphs, alloc);
}

fn writeSysrdDocx(path: []const u8, alloc: std.mem.Allocator) !void {
    const paragraphs = [_][]const u8{
        "System Requirements Document",
        "REQ-001 - Device shall operate for 8 hours.",
        "REQ-002 - Device shall trigger an alarm within 10 seconds.",
        "REQ-003 - Device shall store measurements locally.",
    };
    try artifact_test_files.writeMinimalDocx(path, &paragraphs, alloc);
}

fn writeAmbiguousDocx(path: []const u8, alloc: std.mem.Allocator) !void {
    const paragraphs = [_][]const u8{
        "Requirements Draft",
        "SRS-001 - Software behavior.",
        "REQ-001 - System behavior.",
    };
    try artifact_test_files.writeMinimalDocx(path, &paragraphs, alloc);
}

fn writeRtmWorkbook(path: []const u8, alloc: std.mem.Allocator) !void {
    const requirements_rows = [_][]const []const u8{
        &[_][]const u8{ "ID", "Statement" },
        &[_][]const u8{ "REQ-001", "Device shall operate for 8 hours." },
    };
    const simple_rows = [_][]const []const u8{
        &[_][]const u8{ "ID", "Statement" },
    };
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "Requirements", .rows = &requirements_rows },
        .{ .name = "User Needs", .rows = &simple_rows },
        .{ .name = "Tests", .rows = &simple_rows },
        .{ .name = "Risks", .rows = &simple_rows },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, alloc);
}

fn writeBomWorkbook(path: []const u8, alloc: std.mem.Allocator) !void {
    const rows = [_][]const []const u8{
        &[_][]const u8{ "bom_name", "full_identifier", "child_part" },
        &[_][]const u8{ "pcba", "ASM-1000-REV-C", "C0805-10UF" },
    };
    const sheets = [_]artifact_test_files.Sheet{
        .{ .name = "Design BOM", .rows = &rows },
    };
    try artifact_test_files.writeMinimalXlsx(path, &sheets, alloc);
}

fn buildUploadRequest(
    filename: []const u8,
    kind: []const u8,
    display_name: ?[]const u8,
    file_bytes: []const u8,
    alloc: std.mem.Allocator,
) !UploadRequest {
    const boundary = "----RTMIFY-DISCRIMINATION-TEST";
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);

    try std.fmt.format(body.writer(alloc), "--{s}\r\n", .{boundary});
    try body.appendSlice(alloc, "Content-Disposition: form-data; name=\"kind\"\r\n\r\n");
    try body.appendSlice(alloc, kind);
    try body.appendSlice(alloc, "\r\n");

    if (display_name) |value| {
        try std.fmt.format(body.writer(alloc), "--{s}\r\n", .{boundary});
        try body.appendSlice(alloc, "Content-Disposition: form-data; name=\"display_name\"\r\n\r\n");
        try body.appendSlice(alloc, value);
        try body.appendSlice(alloc, "\r\n");
    }

    try std.fmt.format(body.writer(alloc), "--{s}\r\n", .{boundary});
    try std.fmt.format(
        body.writer(alloc),
        "Content-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\n",
        .{filename},
    );
    try body.appendSlice(alloc, "Content-Type: application/octet-stream\r\n\r\n");
    try body.appendSlice(alloc, file_bytes);
    try body.appendSlice(alloc, "\r\n");
    try std.fmt.format(body.writer(alloc), "--{s}--\r\n", .{boundary});

    return .{
        .content_type = try std.fmt.allocPrint(alloc, "multipart/form-data; boundary={s}", .{boundary}),
        .body = try alloc.dupe(u8, body.items),
    };
}

test "docx discriminator accepts loosely named SRS docx" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try makeTmpPath(tmp, "V1_SRS_FOOBarProduct.docx", testing.allocator);
    defer testing.allocator.free(path);
    try writeSrsDocx(path, testing.allocator);

    var result = try artifact_discriminator.discriminateInboxPath(path, "V1_SRS_FOOBarProduct.docx", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(result.accepted);
    try testing.expectEqual(artifact_discriminator.CandidateKind.srs_docx, result.kind.?);
}

test "docx discriminator accepts loosely named SysRD docx" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try makeTmpPath(tmp, "FooBar System Requirements revB.docx", testing.allocator);
    defer testing.allocator.free(path);
    try writeSysrdDocx(path, testing.allocator);

    var result = try artifact_discriminator.discriminateInboxPath(path, "FooBar System Requirements revB.docx", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(result.accepted);
    try testing.expectEqual(artifact_discriminator.CandidateKind.sysrd_docx, result.kind.?);
}

test "docx discriminator rejects ambiguous mixed docx" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try makeTmpPath(tmp, "requirements-draft.docx", testing.allocator);
    defer testing.allocator.free(path);
    try writeAmbiguousDocx(path, testing.allocator);

    var result = try artifact_discriminator.discriminateInboxPath(path, "requirements-draft.docx", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(!result.accepted);
    try testing.expectEqualStrings("DOCX_AMBIGUOUS_KIND", result.reason_code);
}

test "xlsx discriminator accepts valid RTM workbook without prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try makeTmpPath(tmp, "traceability-matrix-v2.xlsx", testing.allocator);
    defer testing.allocator.free(path);
    try writeRtmWorkbook(path, testing.allocator);

    var result = try artifact_discriminator.discriminateInboxPath(path, "traceability-matrix-v2.xlsx", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(result.accepted);
    try testing.expectEqual(artifact_discriminator.CandidateKind.rtm_workbook, result.kind.?);
}

test "xlsx discriminator classifies Design BOM workbook as bom" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try makeTmpPath(tmp, "hardware-structure.xlsx", testing.allocator);
    defer testing.allocator.free(path);
    try writeBomWorkbook(path, testing.allocator);

    var result = try artifact_discriminator.discriminateInboxPath(path, "hardware-structure.xlsx", testing.allocator);
    defer result.deinit(testing.allocator);

    try testing.expect(result.accepted);
    try testing.expectEqual(artifact_discriminator.CandidateKind.bom, result.kind.?);
}

test "inbox accepts loosely named SRS docx without prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try makeTmpPath(tmp, "inbox", testing.allocator);
    defer testing.allocator.free(inbox_dir);
    try std.fs.cwd().makePath(inbox_dir);
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "V1_SRS_FOOBarProduct.docx" });
    defer testing.allocator.free(file_path);
    try writeSrsDocx(file_path, testing.allocator);

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try external_ingest_inbox.processInboxOnce(&db, inbox_dir, testing.allocator);

    const artifact_id = try design_artifacts.artifactIdFor(.srs_docx, "v1-srs-foobarproduct", testing.allocator);
    defer testing.allocator.free(artifact_id);
    const artifact_node = try db.getNode(artifact_id, testing.allocator);
    defer if (artifact_node) |node| shared.freeNode(node, testing.allocator);
    try testing.expect(artifact_node != null);

    var resolution = try db.resolveRequirementText("SRS-001", testing.allocator);
    defer resolution.deinit(testing.allocator);
    try testing.expectEqualStrings("single_source", resolution.text_status);
    try testing.expect(resolution.effective_statement != null);
}

test "inbox rejects ambiguous docx without mutating graph" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try makeTmpPath(tmp, "inbox", testing.allocator);
    defer testing.allocator.free(inbox_dir);
    try std.fs.cwd().makePath(inbox_dir);
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "requirements-draft.docx" });
    defer testing.allocator.free(file_path);
    try writeAmbiguousDocx(file_path, testing.allocator);

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try external_ingest_inbox.processInboxOnce(&db, inbox_dir, testing.allocator);

    var diags: std.ArrayList(graph_live.RuntimeDiagnostic) = .empty;
    defer {
        for (diags.items) |diag| shared.freeRuntimeDiagnostic(diag, testing.allocator);
        diags.deinit(testing.allocator);
    }
    try db.listRuntimeDiagnostics("external_ingest_inbox", testing.allocator, &diags);
    try testing.expect(diags.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, diags.items[0].details_json, "DOCX_AMBIGUOUS_KIND") != null);

    const req_node = try db.getNode("SRS-001", testing.allocator);
    defer if (req_node) |node| shared.freeNode(node, testing.allocator);
    try testing.expect(req_node == null);
}

test "upload rejects declared sysrd kind for clear SRS docx" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try makeTmpPath(tmp, "inbox", testing.allocator);
    defer testing.allocator.free(inbox_dir);
    try std.fs.cwd().makePath(inbox_dir);

    const token_path = try makeTmpPath(tmp, "api-token", testing.allocator);
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const authorization = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(authorization);

    const file_path = try makeTmpPath(tmp, "upload.docx", testing.allocator);
    defer testing.allocator.free(file_path);
    try writeSrsDocx(file_path, testing.allocator);
    const bytes = try std.fs.cwd().readFileAlloc(testing.allocator, file_path, 1_000_000);
    defer testing.allocator.free(bytes);

    var upload = try buildUploadRequest("upload.docx", "sysrd_docx", null, bytes, testing.allocator);
    defer upload.deinit(testing.allocator);

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    const response = try design_artifacts_api.handlePostUploadResponse(
        &db,
        &auth,
        authorization,
        upload.content_type,
        upload.body,
        inbox_dir,
        testing.allocator,
    );
    defer testing.allocator.free(response.body);
    try testing.expectEqual(std.http.Status.bad_request, response.status);
    try testing.expect(std.mem.indexOf(u8, response.body, "classified file kind srs_docx") != null);
}

test "upload rejects BOM workbook declared as RTM workbook" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try makeTmpPath(tmp, "inbox", testing.allocator);
    defer testing.allocator.free(inbox_dir);
    try std.fs.cwd().makePath(inbox_dir);

    const token_path = try makeTmpPath(tmp, "api-token", testing.allocator);
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const authorization = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(authorization);

    const file_path = try makeTmpPath(tmp, "structure.xlsx", testing.allocator);
    defer testing.allocator.free(file_path);
    try writeBomWorkbook(file_path, testing.allocator);
    const bytes = try std.fs.cwd().readFileAlloc(testing.allocator, file_path, 1_000_000);
    defer testing.allocator.free(bytes);

    var upload = try buildUploadRequest("structure.xlsx", "rtm_workbook", null, bytes, testing.allocator);
    defer upload.deinit(testing.allocator);

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    const response = try design_artifacts_api.handlePostUploadResponse(
        &db,
        &auth,
        authorization,
        upload.content_type,
        upload.body,
        inbox_dir,
        testing.allocator,
    );
    defer testing.allocator.free(response.body);
    try testing.expectEqual(std.http.Status.bad_request, response.status);
    try testing.expect(std.mem.indexOf(u8, response.body, "classified file kind bom") != null);
}

test "upload accepts valid RTM workbook" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try makeTmpPath(tmp, "inbox", testing.allocator);
    defer testing.allocator.free(inbox_dir);
    try std.fs.cwd().makePath(inbox_dir);

    const token_path = try makeTmpPath(tmp, "api-token", testing.allocator);
    defer testing.allocator.free(token_path);
    var auth = try test_results_auth.AuthState.initForPath(token_path, testing.allocator);
    defer auth.deinit(testing.allocator);
    const token = try auth.currentToken(testing.allocator);
    defer testing.allocator.free(token);
    const authorization = try std.fmt.allocPrint(testing.allocator, "Bearer {s}", .{token});
    defer testing.allocator.free(authorization);

    const file_path = try makeTmpPath(tmp, "traceability-matrix-v2.xlsx", testing.allocator);
    defer testing.allocator.free(file_path);
    try writeRtmWorkbook(file_path, testing.allocator);
    const bytes = try std.fs.cwd().readFileAlloc(testing.allocator, file_path, 1_000_000);
    defer testing.allocator.free(bytes);

    var upload = try buildUploadRequest("traceability-matrix-v2.xlsx", "rtm_workbook", null, bytes, testing.allocator);
    defer upload.deinit(testing.allocator);

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    const response = try design_artifacts_api.handlePostUploadResponse(
        &db,
        &auth,
        authorization,
        upload.content_type,
        upload.body,
        inbox_dir,
        testing.allocator,
    );
    defer testing.allocator.free(response.body);
    try testing.expectEqual(std.http.Status.ok, response.status);
    try testing.expect(std.mem.indexOf(u8, response.body, "\"artifact_id\"") != null);
}

test "inbox accepts loosely named RTM workbook without prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const inbox_dir = try makeTmpPath(tmp, "inbox", testing.allocator);
    defer testing.allocator.free(inbox_dir);
    try std.fs.cwd().makePath(inbox_dir);
    const file_path = try std.fs.path.join(testing.allocator, &.{ inbox_dir, "traceability-matrix-v2.xlsx" });
    defer testing.allocator.free(file_path);
    try writeRtmWorkbook(file_path, testing.allocator);

    var db = try graph_live.GraphDb.init(":memory:");
    defer db.deinit();
    try external_ingest_inbox.processInboxOnce(&db, inbox_dir, testing.allocator);

    const artifact_id = try design_artifacts.artifactIdFor(.rtm_workbook, "traceability-matrix-v2", testing.allocator);
    defer testing.allocator.free(artifact_id);
    const artifact_node = try db.getNode(artifact_id, testing.allocator);
    defer if (artifact_node) |node| shared.freeNode(node, testing.allocator);
    try testing.expect(artifact_node != null);
}
