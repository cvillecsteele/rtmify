const std = @import("std");
const Db = @import("../db.zig").Db;
const types = @import("types.zig");
const encode = @import("encode.zig");
const nodes = @import("nodes.zig");
const edges = @import("edges.zig");
const require_text = @import("require_text.zig");
const suspect = @import("suspect.zig");
const impact_mod = @import("impact.zig");
const projections = @import("projections.zig");
const code_queries = @import("code_queries.zig");
const config = @import("config.zig");
const diagnostics = @import("diagnostics.zig");

pub const Node = types.Node;
pub const Edge = types.Edge;
pub const RuntimeDiagnostic = types.RuntimeDiagnostic;
pub const RtmRow = types.RtmRow;
pub const RiskRow = types.RiskRow;
pub const TestRow = types.TestRow;
pub const ImpactNode = types.ImpactNode;
pub const ImplementationChangeEvidence = types.ImplementationChangeEvidence;
pub const GraphCounts = types.GraphCounts;
pub const RequirementSourceAssertion = types.RequirementSourceAssertion;
pub const RequirementTextResolution = types.RequirementTextResolution;
pub const hashRow = nodes.hashRow;

pub const GraphDb = struct {
    db: Db,

    pub fn init(path: [:0]const u8) !GraphDb {
        var d = try Db.open(path);
        try d.initSchema();
        return .{ .db = d };
    }

    pub fn deinit(g: *GraphDb) void {
        g.db.close();
    }

    pub fn countGraph(g: *GraphDb) !GraphCounts {
        return nodes.countGraph(g);
    }

    pub fn addNode(g: *GraphDb, id: []const u8, node_type: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
        return nodes.addNode(g, id, node_type, properties_json, row_hash);
    }

    pub fn updateNode(g: *GraphDb, id: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
        return nodes.updateNode(g, id, properties_json, row_hash);
    }

    pub fn upsertNode(g: *GraphDb, id: []const u8, node_type: []const u8, properties_json: []const u8, row_hash: ?[]const u8) !void {
        return nodes.upsertNode(g, id, node_type, properties_json, row_hash);
    }

    pub fn getNode(g: *GraphDb, id: []const u8, alloc: std.mem.Allocator) !?Node {
        return nodes.getNode(g, id, alloc);
    }

    pub fn allNodes(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList(Node)) !void {
        return nodes.allNodes(g, alloc, result);
    }

    pub fn nodesByType(g: *GraphDb, node_type: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(Node)) !void {
        return nodes.nodesByType(g, node_type, alloc, result);
    }

    pub fn nodesByTypePresent(g: *GraphDb, node_type: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(Node)) !void {
        return nodes.nodesByTypePresent(g, node_type, alloc, result);
    }

    pub fn allNodeTypes(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList([]const u8)) !void {
        return nodes.allNodeTypes(g, alloc, result);
    }

    pub fn allEdgeLabels(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList([]const u8)) !void {
        return edges.allEdgeLabels(g, alloc, result);
    }

    pub fn requirementSourceAssertions(g: *GraphDb, req_id: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(RequirementSourceAssertion)) !void {
        return require_text.requirementSourceAssertions(g, req_id, alloc, result);
    }

    pub fn resolveRequirementText(g: *GraphDb, req_id: []const u8, alloc: std.mem.Allocator) !RequirementTextResolution {
        return require_text.resolveRequirementText(g, req_id, alloc);
    }

    pub fn nodesByRepo(g: *GraphDb, repo_path: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(Node)) !void {
        return code_queries.nodesByRepo(g, repo_path, alloc, result);
    }

    pub fn requirementsWithImplementationChangesSince(g: *GraphDb, since: []const u8, repo_path: ?[]const u8, alloc: std.mem.Allocator, result: *std.ArrayList(ImplementationChangeEvidence)) !void {
        return code_queries.requirementsWithImplementationChangesSince(g, since, repo_path, alloc, result);
    }

    pub fn userNeedsWithImplementationChangesSince(g: *GraphDb, since: []const u8, repo_path: ?[]const u8, alloc: std.mem.Allocator, result: *std.ArrayList(ImplementationChangeEvidence)) !void {
        return code_queries.userNeedsWithImplementationChangesSince(g, since, repo_path, alloc, result);
    }

    pub fn addEdge(g: *GraphDb, from_id: []const u8, to_id: []const u8, label: []const u8) !void {
        return edges.addEdge(g, from_id, to_id, label);
    }

    pub fn addEdgeWithProperties(g: *GraphDb, from_id: []const u8, to_id: []const u8, label: []const u8, properties_json: ?[]const u8) !void {
        return edges.addEdgeWithProperties(g, from_id, to_id, label, properties_json);
    }

    pub fn edgesFrom(g: *GraphDb, from_id: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(Edge)) !void {
        return edges.edgesFrom(g, from_id, alloc, result);
    }

    pub fn edgesTo(g: *GraphDb, to_id: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(Edge)) !void {
        return edges.edgesTo(g, to_id, alloc, result);
    }

    pub fn allEdges(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList(Edge)) !void {
        return edges.allEdges(g, alloc, result);
    }

    pub fn clearSuspect(g: *GraphDb, id: []const u8) !void {
        return suspect.clearSuspect(g, id);
    }

    pub fn suspects(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList(Node)) !void {
        return suspect.suspects(g, alloc, result);
    }

    pub fn impact(g: *GraphDb, node_id: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(ImpactNode)) !void {
        return impact_mod.impact(g, node_id, alloc, result);
    }

    pub fn nodesMissingEdge(g: *GraphDb, node_type: []const u8, edge_label: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(Node)) !void {
        return edges.nodesMissingEdge(g, node_type, edge_label, alloc, result);
    }

    pub fn rtm(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList(RtmRow)) !void {
        return projections.rtm(g, alloc, result);
    }

    pub fn risks(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList(RiskRow)) !void {
        return projections.risks(g, alloc, result);
    }

    pub fn tests(g: *GraphDb, alloc: std.mem.Allocator, result: *std.ArrayList(TestRow)) !void {
        return projections.tests(g, alloc, result);
    }

    pub fn search(g: *GraphDb, query: []const u8, alloc: std.mem.Allocator, result: *std.ArrayList(Node)) !void {
        return nodes.search(g, query, alloc, result);
    }

    pub fn storeCredential(g: *GraphDb, content: []const u8) !void {
        return config.storeCredential(g, content);
    }

    pub fn getLatestCredential(g: *GraphDb, alloc: std.mem.Allocator) !?[]const u8 {
        return config.getLatestCredential(g, alloc);
    }

    pub fn hasLegacyCredential(g: *GraphDb) !bool {
        return config.hasLegacyCredential(g);
    }

    pub fn clearLegacyCredentials(g: *GraphDb) !void {
        return config.clearLegacyCredentials(g);
    }

    pub fn storeConfig(g: *GraphDb, key: []const u8, value: []const u8) !void {
        return config.storeConfig(g, key, value);
    }

    pub fn getConfig(g: *GraphDb, key: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
        return config.getConfig(g, key, alloc);
    }

    pub fn upsertRuntimeDiagnostic(
        g: *GraphDb,
        dedupe_key: []const u8,
        code: u16,
        severity: []const u8,
        title: []const u8,
        message: []const u8,
        source: []const u8,
        subject: ?[]const u8,
        details_json: []const u8,
    ) !void {
        return diagnostics.upsertRuntimeDiagnostic(g, dedupe_key, code, severity, title, message, source, subject, details_json);
    }

    pub fn clearRuntimeDiagnosticsBySource(g: *GraphDb, source: []const u8) !void {
        return diagnostics.clearRuntimeDiagnosticsBySource(g, source);
    }

    pub fn clearRuntimeDiagnosticsBySubjectPrefix(g: *GraphDb, source: []const u8, prefix: []const u8) !void {
        return diagnostics.clearRuntimeDiagnosticsBySubjectPrefix(g, source, prefix);
    }

    pub fn clearRuntimeDiagnostic(g: *GraphDb, dedupe_key: []const u8) !void {
        return diagnostics.clearRuntimeDiagnostic(g, dedupe_key);
    }

    pub fn listRuntimeDiagnostics(g: *GraphDb, source_filter: ?[]const u8, alloc: std.mem.Allocator, result: *std.ArrayList(RuntimeDiagnostic)) !void {
        return diagnostics.listRuntimeDiagnostics(g, source_filter, alloc, result);
    }

    pub fn deleteNode(g: *GraphDb, id: []const u8) !void {
        return nodes.deleteNode(g, id);
    }

    pub fn deleteConfig(g: *GraphDb, key: []const u8) !void {
        return config.deleteConfig(g, key);
    }
};
