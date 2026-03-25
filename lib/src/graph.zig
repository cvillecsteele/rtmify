const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const NodeType = enum {
    product,
    user_need,
    requirement,
    artifact,
    requirement_text,
    test_group,
    test_case,
    risk,
    design_input,
    design_output,
    config_item,
    source_file,
    test_file,
    commit_node,
    code_annotation,

    pub fn fromString(s: []const u8) ?NodeType {
        if (std.mem.eql(u8, s, "Product")) return .product;
        if (std.mem.eql(u8, s, "UserNeed")) return .user_need;
        if (std.mem.eql(u8, s, "Requirement")) return .requirement;
        if (std.mem.eql(u8, s, "Artifact")) return .artifact;
        if (std.mem.eql(u8, s, "RequirementText")) return .requirement_text;
        if (std.mem.eql(u8, s, "TestGroup")) return .test_group;
        if (std.mem.eql(u8, s, "Test")) return .test_case;
        if (std.mem.eql(u8, s, "Risk")) return .risk;
        if (std.mem.eql(u8, s, "DesignInput")) return .design_input;
        if (std.mem.eql(u8, s, "DesignOutput")) return .design_output;
        if (std.mem.eql(u8, s, "ConfigurationItem")) return .config_item;
        if (std.mem.eql(u8, s, "SourceFile")) return .source_file;
        if (std.mem.eql(u8, s, "TestFile")) return .test_file;
        if (std.mem.eql(u8, s, "Commit")) return .commit_node;
        if (std.mem.eql(u8, s, "CodeAnnotation")) return .code_annotation;
        return null;
    }

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .product => "Product",
            .user_need => "UserNeed",
            .requirement => "Requirement",
            .artifact => "Artifact",
            .requirement_text => "RequirementText",
            .test_group => "TestGroup",
            .test_case => "Test",
            .risk => "Risk",
            .design_input => "DesignInput",
            .design_output => "DesignOutput",
            .config_item => "ConfigurationItem",
            .source_file => "SourceFile",
            .test_file => "TestFile",
            .commit_node => "Commit",
            .code_annotation => "CodeAnnotation",
        };
    }
};

pub const EdgeLabel = enum {
    derives_from,
    tested_by,
    has_test,
    mitigated_by,
    allocated_to,
    satisfied_by,
    refined_by,
    controlled_by,
    implemented_in,
    verified_by_code,
    committed_in,
    changed_in,
    changes,
    annotated_at,
    contains,
    asserts,
    conflicts_with,
    contains_annotation, // kept for backward-compat with old DB rows

    pub fn fromString(s: []const u8) ?EdgeLabel {
        if (std.mem.eql(u8, s, "DERIVES_FROM")) return .derives_from;
        if (std.mem.eql(u8, s, "TESTED_BY")) return .tested_by;
        if (std.mem.eql(u8, s, "HAS_TEST")) return .has_test;
        if (std.mem.eql(u8, s, "MITIGATED_BY")) return .mitigated_by;
        if (std.mem.eql(u8, s, "ALLOCATED_TO")) return .allocated_to;
        if (std.mem.eql(u8, s, "SATISFIED_BY")) return .satisfied_by;
        if (std.mem.eql(u8, s, "REFINED_BY")) return .refined_by;
        if (std.mem.eql(u8, s, "CONTROLLED_BY")) return .controlled_by;
        if (std.mem.eql(u8, s, "IMPLEMENTED_IN")) return .implemented_in;
        if (std.mem.eql(u8, s, "VERIFIED_BY_CODE")) return .verified_by_code;
        if (std.mem.eql(u8, s, "COMMITTED_IN")) return .committed_in;
        if (std.mem.eql(u8, s, "CHANGED_IN")) return .changed_in;
        if (std.mem.eql(u8, s, "CHANGES")) return .changes;
        if (std.mem.eql(u8, s, "ANNOTATED_AT")) return .annotated_at;
        if (std.mem.eql(u8, s, "CONTAINS")) return .contains;
        if (std.mem.eql(u8, s, "ASSERTS")) return .asserts;
        if (std.mem.eql(u8, s, "CONFLICTS_WITH")) return .conflicts_with;
        if (std.mem.eql(u8, s, "CONTAINS_ANNOTATION")) return .contains_annotation;
        return null;
    }

    pub fn toString(self: EdgeLabel) []const u8 {
        return switch (self) {
            .derives_from => "DERIVES_FROM",
            .tested_by => "TESTED_BY",
            .has_test => "HAS_TEST",
            .mitigated_by => "MITIGATED_BY",
            .allocated_to => "ALLOCATED_TO",
            .satisfied_by => "SATISFIED_BY",
            .refined_by => "REFINED_BY",
            .controlled_by => "CONTROLLED_BY",
            .implemented_in => "IMPLEMENTED_IN",
            .verified_by_code => "VERIFIED_BY_CODE",
            .committed_in => "COMMITTED_IN",
            .changed_in => "CHANGED_IN",
            .changes => "CHANGES",
            .annotated_at => "ANNOTATED_AT",
            .contains => "CONTAINS",
            .asserts => "ASSERTS",
            .conflicts_with => "CONFLICTS_WITH",
            .contains_annotation => "CONTAINS_ANNOTATION",
        };
    }
};

/// A key-value property pair passed to addNode.
pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const Node = struct {
    id: []const u8,
    node_type: NodeType,
    properties: std.StringHashMapUnmanaged([]const u8),

    pub fn get(self: *const Node, key: []const u8) ?[]const u8 {
        return self.properties.get(key);
    }
};

pub const Edge = struct {
    from_id: []const u8,
    to_id: []const u8,
    label: EdgeLabel,
};

/// One row of the Requirements Traceability Matrix.
pub const RtmRow = struct {
    req_id: []const u8,
    statement: []const u8,
    status: []const u8,
    user_need_id: ?[]const u8,
    test_group_id: ?[]const u8,
    test_id: ?[]const u8,
    test_type: ?[]const u8,
    test_method: ?[]const u8,
    /// First SourceFile linked via IMPLEMENTED_IN edge (if any).
    source_file: ?[]const u8 = null,
    /// First TestFile linked via VERIFIED_BY_CODE edge (if any).
    test_file: ?[]const u8 = null,
    /// blame_author + short_hash from first linked CodeAnnotation (if any).
    last_commit: ?[]const u8 = null,
};

/// One row of the Risk Register.
pub const RiskRow = struct {
    risk_id: []const u8,
    description: []const u8,
    initial_severity: ?[]const u8,
    initial_likelihood: ?[]const u8,
    mitigation: ?[]const u8,
    residual_severity: ?[]const u8,
    residual_likelihood: ?[]const u8,
    req_id: ?[]const u8,
};

pub const GapSeverity = enum {
    hard,
    advisory,

    pub fn toString(self: GapSeverity) []const u8 {
        return switch (self) {
            .hard => "hard",
            .advisory => "advisory",
        };
    }
};

pub const GapKind = enum {
    requirement_no_user_need_link,
    requirement_no_test_group_link,
    requirement_only_unresolved_test_group_refs,
    requirement_linked_to_empty_test_group,
    user_need_without_requirements,
    test_group_without_requirements,
    risk_without_mitigation_requirement,
    risk_unresolved_mitigation_requirement,

    pub fn toString(self: GapKind) []const u8 {
        return switch (self) {
            .requirement_no_user_need_link => "requirement_no_user_need_link",
            .requirement_no_test_group_link => "requirement_no_test_group_link",
            .requirement_only_unresolved_test_group_refs => "requirement_only_unresolved_test_group_refs",
            .requirement_linked_to_empty_test_group => "requirement_linked_to_empty_test_group",
            .user_need_without_requirements => "user_need_without_requirements",
            .test_group_without_requirements => "test_group_without_requirements",
            .risk_without_mitigation_requirement => "risk_without_mitigation_requirement",
            .risk_unresolved_mitigation_requirement => "risk_unresolved_mitigation_requirement",
        };
    }
};

pub const GapFinding = struct {
    kind: GapKind,
    severity: GapSeverity,
    primary_id: []const u8,
    related_id: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Graph
// ---------------------------------------------------------------------------

/// In-memory graph of nodes and edges. All memory is owned by an internal
/// ArenaAllocator; call deinit() to free everything at once.
///
/// Build the graph (addNode / addEdge), then query it (rtm, risks, etc.).
/// Do not hold node pointers across addNode calls — the internal HashMap
/// may resize and invalidate pointers. In practice, build first, then query.
pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.StringHashMapUnmanaged(*Node) = .{},
    edges: std.ArrayListUnmanaged(Edge) = .{},

    pub fn init(allocator: Allocator) Graph {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Graph) void {
        self.arena.deinit();
    }

    fn a(self: *Graph) Allocator {
        return self.arena.allocator();
    }

    // -----------------------------------------------------------------------
    // Mutation
    // -----------------------------------------------------------------------

    /// Add a node. Idempotent: a second call with the same id is a no-op.
    pub fn addNode(self: *Graph, id: []const u8, node_type: NodeType, props: []const Property) !void {
        if (self.nodes.contains(id)) return;
        const alloc = self.a();
        const node = try alloc.create(Node);
        node.* = .{
            .id = try alloc.dupe(u8, id),
            .node_type = node_type,
            .properties = .{},
        };
        for (props) |p| {
            try node.properties.put(alloc, try alloc.dupe(u8, p.key), try alloc.dupe(u8, p.value));
        }
        try self.nodes.put(alloc, node.id, node);
    }

    /// Add a directed edge. Idempotent: duplicate from/to/label is a no-op.
    pub fn addEdge(self: *Graph, from_id: []const u8, to_id: []const u8, label: EdgeLabel) !void {
        for (self.edges.items) |e| {
            if (e.label == label and
                std.mem.eql(u8, e.from_id, from_id) and
                std.mem.eql(u8, e.to_id, to_id)) return;
        }
        const alloc = self.a();
        try self.edges.append(alloc, .{
            .from_id = try alloc.dupe(u8, from_id),
            .to_id = try alloc.dupe(u8, to_id),
            .label = label,
        });
    }

    // -----------------------------------------------------------------------
    // Basic queries
    // -----------------------------------------------------------------------

    pub fn getNode(self: *const Graph, id: []const u8) ?*const Node {
        return self.nodes.get(id);
    }

    pub fn nodesByType(self: *const Graph, node_type: NodeType, alloc: Allocator, result: *std.ArrayList(*const Node)) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            if (ptr.*.node_type == node_type) try result.append(alloc, ptr.*);
        }
    }

    pub fn edgesFrom(self: *const Graph, from_id: []const u8, alloc: Allocator, result: *std.ArrayList(Edge)) !void {
        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.from_id, from_id)) try result.append(alloc, e);
        }
    }

    pub fn edgesTo(self: *const Graph, to_id: []const u8, alloc: Allocator, result: *std.ArrayList(Edge)) !void {
        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.to_id, to_id)) try result.append(alloc, e);
        }
    }

    fn hasOutgoingEdge(self: *const Graph, from_id: []const u8, label: EdgeLabel) bool {
        for (self.edges.items) |e| {
            if (e.label == label and std.mem.eql(u8, e.from_id, from_id)) return true;
        }
        return false;
    }

    fn hasIncomingEdge(self: *const Graph, to_id: []const u8, label: EdgeLabel) bool {
        for (self.edges.items) |e| {
            if (e.label == label and std.mem.eql(u8, e.to_id, to_id)) return true;
        }
        return false;
    }

    fn propertyInt(node: *const Node, key: []const u8) usize {
        const raw = node.get(key) orelse return 0;
        return std.fmt.parseInt(usize, raw, 10) catch 0;
    }

    // -----------------------------------------------------------------------
    // Gap queries
    // -----------------------------------------------------------------------

    /// Returns all nodes of node_type that have no outgoing edge with label.
    pub fn nodesMissingEdge(
        self: *const Graph,
        node_type: NodeType,
        label: EdgeLabel,
        alloc: Allocator,
        result: *std.ArrayList(*const Node),
    ) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            const node = ptr.*;
            if (node.node_type != node_type) continue;
            var has_edge = false;
            for (self.edges.items) |e| {
                if (e.label == label and std.mem.eql(u8, e.from_id, node.id)) {
                    has_edge = true;
                    break;
                }
            }
            if (!has_edge) try result.append(alloc, node);
        }
    }

    pub fn collectGapFindings(self: *const Graph, alloc: Allocator, result: *std.ArrayList(GapFinding)) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            const node = ptr.*;
            switch (node.node_type) {
                .requirement => {
                    if (!self.hasOutgoingEdge(node.id, .derives_from)) {
                        try result.append(alloc, .{
                            .kind = .requirement_no_user_need_link,
                            .severity = .hard,
                            .primary_id = node.id,
                        });
                    }

                    var valid_test_group_count: usize = 0;
                    var any_test_group_ref = false;
                    var first_unresolved_test_group_ref: ?[]const u8 = null;
                    for (self.edges.items) |e| {
                        if (e.label != .tested_by or !std.mem.eql(u8, e.from_id, node.id)) continue;
                        any_test_group_ref = true;
                        if (self.getNode(e.to_id)) |tg| {
                            if (tg.node_type == .test_group) {
                                valid_test_group_count += 1;
                            } else if (first_unresolved_test_group_ref == null) {
                                first_unresolved_test_group_ref = e.to_id;
                            }
                        } else if (first_unresolved_test_group_ref == null) {
                            first_unresolved_test_group_ref = e.to_id;
                        }
                    }
                    const declared_test_group_refs = propertyInt(node, "declared_test_group_ref_count");
                    if (valid_test_group_count == 0) {
                        try result.append(alloc, .{
                            .kind = if (declared_test_group_refs > 0 or any_test_group_ref)
                                .requirement_only_unresolved_test_group_refs
                            else
                                .requirement_no_test_group_link,
                            .severity = .hard,
                            .primary_id = node.id,
                            .related_id = if (declared_test_group_refs > 0 or any_test_group_ref) first_unresolved_test_group_ref else null,
                        });
                    } else {
                        for (self.edges.items) |e| {
                            if (e.label != .tested_by or !std.mem.eql(u8, e.from_id, node.id)) continue;
                            if (self.getNode(e.to_id)) |tg| {
                                if (tg.node_type == .test_group and !self.hasOutgoingEdge(tg.id, .has_test)) {
                                    try result.append(alloc, .{
                                        .kind = .requirement_linked_to_empty_test_group,
                                        .severity = .advisory,
                                        .primary_id = node.id,
                                        .related_id = tg.id,
                                    });
                                }
                            }
                        }
                    }
                },
                .user_need => {
                    if (!self.hasIncomingEdge(node.id, .derives_from)) {
                        try result.append(alloc, .{
                            .kind = .user_need_without_requirements,
                            .severity = .advisory,
                            .primary_id = node.id,
                        });
                    }
                },
                .test_group => {
                    if (!self.hasIncomingEdge(node.id, .tested_by)) {
                        try result.append(alloc, .{
                            .kind = .test_group_without_requirements,
                            .severity = .advisory,
                            .primary_id = node.id,
                        });
                    }
                },
                .risk => {
                    var valid_mitigation_req_count: usize = 0;
                    var any_mitigation_ref = false;
                    var first_unresolved_mitigation_ref: ?[]const u8 = null;
                    for (self.edges.items) |e| {
                        if (e.label != .mitigated_by or !std.mem.eql(u8, e.from_id, node.id)) continue;
                        any_mitigation_ref = true;
                        if (self.getNode(e.to_id)) |req| {
                            if (req.node_type == .requirement) {
                                valid_mitigation_req_count += 1;
                            } else if (first_unresolved_mitigation_ref == null) {
                                first_unresolved_mitigation_ref = e.to_id;
                            }
                        } else if (first_unresolved_mitigation_ref == null) {
                            first_unresolved_mitigation_ref = e.to_id;
                        }
                    }
                    const declared_mitigation_refs = propertyInt(node, "declared_mitigation_req_ref_count");
                    if (valid_mitigation_req_count == 0) {
                        try result.append(alloc, .{
                            .kind = if (declared_mitigation_refs > 0 or any_mitigation_ref)
                                .risk_unresolved_mitigation_requirement
                            else
                                .risk_without_mitigation_requirement,
                            .severity = .hard,
                            .primary_id = node.id,
                            .related_id = if (declared_mitigation_refs > 0 or any_mitigation_ref) first_unresolved_mitigation_ref else null,
                        });
                    }
                },
                else => {},
            }
        }
        std.mem.sort(GapFinding, result.items, {}, gapFindingLt);
    }

    pub fn hardGapCount(self: *const Graph, alloc: Allocator) !usize {
        var findings: std.ArrayList(GapFinding) = .empty;
        defer findings.deinit(alloc);
        try self.collectGapFindings(alloc, &findings);
        var count: usize = 0;
        for (findings.items) |finding| {
            if (finding.severity == .hard) count += 1;
        }
        return count;
    }

    // -----------------------------------------------------------------------
    // Traversal
    // -----------------------------------------------------------------------

    /// BFS reachable from from_id following any outgoing edge, up to max_depth.
    /// Uses an internal arena for temporary state so the caller's allocator is
    /// not polluted with intermediary data.
    pub fn downstream(
        self: *const Graph,
        from_id: []const u8,
        max_depth: usize,
        alloc: Allocator,
        result: *std.ArrayList(*const Node),
    ) !void {
        var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tmp_arena.deinit();
        const tmp = tmp_arena.allocator();

        var visited = std.StringHashMapUnmanaged(void){};
        // Pre-mark the start node so cycles back to it don't add it to results
        try visited.put(tmp, from_id, {});
        const QueueItem = struct { id: []const u8, depth: usize };
        var queue = std.ArrayListUnmanaged(QueueItem){};

        for (self.edges.items) |e| {
            if (std.mem.eql(u8, e.from_id, from_id)) {
                try queue.append(tmp, .{ .id = e.to_id, .depth = 1 });
            }
        }

        var qi: usize = 0;
        while (qi < queue.items.len) {
            const item = queue.items[qi];
            qi += 1;

            if (visited.contains(item.id)) continue;
            try visited.put(tmp, item.id, {});

            if (self.nodes.get(item.id)) |node| try result.append(alloc, node);
            if (item.depth >= max_depth) continue;

            for (self.edges.items) |e| {
                if (std.mem.eql(u8, e.from_id, item.id) and !visited.contains(e.to_id)) {
                    try queue.append(tmp, .{ .id = e.to_id, .depth = item.depth + 1 });
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Report queries
    // -----------------------------------------------------------------------

    /// Requirements Traceability Matrix. Each row is one (req, test) pair.
    /// A req with no test group yields one row with null test fields.
    /// A test group with N tests yields N rows for that req.
    pub fn rtm(self: *const Graph, alloc: Allocator, result: *std.ArrayList(RtmRow)) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            const req = ptr.*;
            if (req.node_type != .requirement) continue;

            const statement = req.get("statement") orelse "";
            const status = req.get("status") orelse "";

            var user_need_id: ?[]const u8 = null;
            for (self.edges.items) |e| {
                if (e.label == .derives_from and std.mem.eql(u8, e.from_id, req.id)) {
                    user_need_id = e.to_id;
                    break;
                }
            }

            var test_group_ids: std.ArrayList([]const u8) = .empty;
            defer test_group_ids.deinit(alloc);
            for (self.edges.items) |e| {
                if (e.label == .tested_by and std.mem.eql(u8, e.from_id, req.id)) {
                    try test_group_ids.append(alloc, e.to_id);
                }
            }

            // Scan for code traceability edges
            var source_file_id: ?[]const u8 = null;
            var test_file_id: ?[]const u8 = null;
            var last_commit: ?[]const u8 = null;
            for (self.edges.items) |e| {
                if (std.mem.eql(u8, e.from_id, req.id)) {
                    if (e.label == .implemented_in and source_file_id == null) {
                        source_file_id = e.to_id;
                    } else if (e.label == .verified_by_code and test_file_id == null) {
                        test_file_id = e.to_id;
                    }
                } else if (e.label == .contains_annotation and std.mem.eql(u8, e.to_id, req.id)) {
                    if (last_commit == null) {
                        if (self.nodes.get(e.from_id)) |ann| {
                            const hash = ann.get("short_hash") orelse "";
                            if (hash.len > 0) {
                                const author = ann.get("blame_author") orelse "";
                                last_commit = if (author.len > 0)
                                    std.fmt.allocPrint(alloc, "{s} {s}", .{ author, hash }) catch null
                                else
                                    hash;
                            }
                        }
                    }
                }
            }

            if (test_group_ids.items.len == 0) {
                try result.append(alloc, .{
                    .req_id = req.id,
                    .statement = statement,
                    .status = status,
                    .user_need_id = user_need_id,
                    .test_group_id = null,
                    .test_id = null,
                    .test_type = null,
                    .test_method = null,
                    .source_file = source_file_id,
                    .test_file = test_file_id,
                    .last_commit = last_commit,
                });
                continue;
            }

            for (test_group_ids.items) |test_group_id| {
                var found_tests = false;
                for (self.edges.items) |e| {
                    if (e.label == .has_test and std.mem.eql(u8, e.from_id, test_group_id)) {
                        found_tests = true;
                        const t = self.nodes.get(e.to_id);
                        try result.append(alloc, .{
                            .req_id = req.id,
                            .statement = statement,
                            .status = status,
                            .user_need_id = user_need_id,
                            .test_group_id = test_group_id,
                            .test_id = e.to_id,
                            .test_type = if (t) |n| n.get("test_type") else null,
                            .test_method = if (t) |n| n.get("test_method") else null,
                            .source_file = source_file_id,
                            .test_file = test_file_id,
                            .last_commit = last_commit,
                        });
                    }
                }
                if (!found_tests) {
                    try result.append(alloc, .{
                        .req_id = req.id,
                        .statement = statement,
                        .status = status,
                        .user_need_id = user_need_id,
                        .test_group_id = test_group_id,
                        .test_id = null,
                        .test_type = null,
                        .test_method = null,
                        .source_file = source_file_id,
                        .test_file = test_file_id,
                        .last_commit = last_commit,
                    });
                }
            }
        }
    }

    /// Risk Register: each Risk node with its linked Requirement (if any).
    pub fn risks(self: *const Graph, alloc: Allocator, result: *std.ArrayList(RiskRow)) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |ptr| {
            const risk = ptr.*;
            if (risk.node_type != .risk) continue;

            var req_id: ?[]const u8 = null;
            for (self.edges.items) |e| {
                if (e.label == .mitigated_by and std.mem.eql(u8, e.from_id, risk.id)) {
                    req_id = e.to_id;
                    break;
                }
            }

            try result.append(alloc, .{
                .risk_id = risk.id,
                .description = risk.get("description") orelse "",
                .initial_severity = risk.get("initial_severity"),
                .initial_likelihood = risk.get("initial_likelihood"),
                .mitigation = risk.get("mitigation"),
                .residual_severity = risk.get("residual_severity"),
                .residual_likelihood = risk.get("residual_likelihood"),
                .req_id = req_id,
            });
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (translated from live/tests/test_graph.py)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn hasId(nodes: []const *const Node, id: []const u8) bool {
    for (nodes) |n| if (std.mem.eql(u8, n.id, id)) return true;
    return false;
}

fn gapFindingLt(_: void, a: GapFinding, b: GapFinding) bool {
    const sev_ord = std.math.order(@intFromEnum(a.severity), @intFromEnum(b.severity));
    if (sev_ord != .eq) return sev_ord == .lt;
    const kind_ord = std.math.order(@intFromEnum(a.kind), @intFromEnum(b.kind));
    if (kind_ord != .eq) return kind_ord == .lt;
    const primary_ord = std.mem.order(u8, a.primary_id, b.primary_id);
    if (primary_ord != .eq) return primary_ord == .lt;
    if (a.related_id == null) return false;
    if (b.related_id == null) return true;
    return std.mem.order(u8, a.related_id.?, b.related_id.?) == .lt;
}

test "addNode and getNode" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system SHALL detect loss of GPS" },
    });
    const node = g.getNode("REQ-001");
    try testing.expect(node != null);
    try testing.expectEqualStrings("REQ-001", node.?.id);
    try testing.expectEqual(NodeType.requirement, node.?.node_type);
    try testing.expectEqualStrings("The system SHALL detect loss of GPS", node.?.get("statement").?);
}

test "addNode idempotent" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "first" }});
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "second" }});
    const node = g.getNode("REQ-001");
    try testing.expectEqualStrings("first", node.?.get("statement").?);
}

test "getNode missing returns null" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try testing.expect(g.getNode("DOES-NOT-EXIST") == null);
}

test "addEdge idempotent" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(testing.allocator);
    try g.edgesFrom("REQ-001", testing.allocator, &edges);
    try testing.expectEqual(1, edges.items.len);
    try testing.expectEqual(EdgeLabel.tested_by, edges.items[0].label);
}

test "nodesByType" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("REQ-002", .requirement, &.{});
    try g.addNode("UN-001", .user_need, &.{});
    var reqs: std.ArrayList(*const Node) = .empty;
    defer reqs.deinit(testing.allocator);
    try g.nodesByType(.requirement, testing.allocator, &reqs);
    try testing.expectEqual(2, reqs.items.len);
}

test "nodesMissingEdge" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("REQ-002", .requirement, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    var gaps: std.ArrayList(*const Node) = .empty;
    defer gaps.deinit(testing.allocator);
    try g.nodesMissingEdge(.requirement, .tested_by, testing.allocator, &gaps);
    try testing.expectEqual(1, gaps.items.len);
    try testing.expectEqualStrings("REQ-002", gaps.items[0].id);
}

test "nodesMissingEdge all covered" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    var gaps: std.ArrayList(*const Node) = .empty;
    defer gaps.deinit(testing.allocator);
    try g.nodesMissingEdge(.requirement, .tested_by, testing.allocator, &gaps);
    try testing.expectEqual(0, gaps.items.len);
}

test "nodesMissingEdge empty graph" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    var gaps: std.ArrayList(*const Node) = .empty;
    defer gaps.deinit(testing.allocator);
    try g.nodesMissingEdge(.requirement, .tested_by, testing.allocator, &gaps);
    try testing.expectEqual(0, gaps.items.len);
}

test "downstream direct and recursive" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    try g.addNode("B", .test_group, &.{});
    try g.addNode("C", .test_case, &.{});
    try g.addEdge("A", "B", .tested_by);
    try g.addEdge("B", "C", .has_test);
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 20, testing.allocator, &result);
    try testing.expectEqual(2, result.items.len);
    try testing.expect(hasId(result.items, "B"));
    try testing.expect(hasId(result.items, "C"));
}

test "downstream direct only" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    try g.addNode("B", .test_group, &.{});
    try g.addNode("C", .test_case, &.{});
    try g.addEdge("A", "B", .tested_by);
    try g.addEdge("B", "C", .has_test);
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 1, testing.allocator, &result);
    try testing.expectEqual(1, result.items.len);
    try testing.expectEqualStrings("B", result.items[0].id);
}

test "downstream no edges" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 20, testing.allocator, &result);
    try testing.expectEqual(0, result.items.len);
}

test "downstream cycle guard" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("A", .requirement, &.{});
    try g.addNode("B", .requirement, &.{});
    try g.addNode("C", .requirement, &.{});
    try g.addEdge("A", "B", .derives_from);
    try g.addEdge("B", "C", .derives_from);
    try g.addEdge("C", "A", .derives_from);
    var result: std.ArrayList(*const Node) = .empty;
    defer result.deinit(testing.allocator);
    try g.downstream("A", 20, testing.allocator, &result);
    try testing.expectEqual(2, result.items.len);
    try testing.expect(hasId(result.items, "B"));
    try testing.expect(hasId(result.items, "C"));
}

test "rtm unverified requirement" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system SHALL work" },
        .{ .key = "status", .value = "approved" },
    });
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    const row = rows.items[0];
    try testing.expectEqualStrings("REQ-001", row.req_id);
    try testing.expect(row.test_group_id == null);
    try testing.expect(row.test_id == null);
    try testing.expect(row.user_need_id == null);
}

test "rtm with test" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("UN-001", .user_need, &.{.{ .key = "statement", .value = "I need GPS" }});
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "The system SHALL detect loss of GPS" },
        .{ .key = "status", .value = "approved" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("TG-001-T01", .test_case, &.{
        .{ .key = "test_type", .value = "system" },
        .{ .key = "test_method", .value = "test" },
    });
    try g.addEdge("REQ-001", "UN-001", .derives_from);
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("TG-001", "TG-001-T01", .has_test);
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    const row = rows.items[0];
    try testing.expectEqualStrings("REQ-001", row.req_id);
    try testing.expectEqualStrings("UN-001", row.user_need_id.?);
    try testing.expectEqualStrings("TG-001", row.test_group_id.?);
    try testing.expectEqualStrings("TG-001-T01", row.test_id.?);
    try testing.expectEqualStrings("system", row.test_type.?);
    try testing.expectEqualStrings("test", row.test_method.?);
}

test "rtm multiple tests in group" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{
        .{ .key = "statement", .value = "SHALL work" },
        .{ .key = "status", .value = "approved" },
    });
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("TG-001-T01", .test_case, &.{});
    try g.addNode("TG-001-T02", .test_case, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("TG-001", "TG-001-T01", .has_test);
    try g.addEdge("TG-001", "TG-001-T02", .has_test);
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(2, rows.items.len);
    try testing.expectEqualStrings("REQ-001", rows.items[0].req_id);
    try testing.expectEqualStrings("REQ-001", rows.items[1].req_id);
}

test "rtm includes multiple test groups for one requirement" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "SHALL work" }});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("TG-002", .test_group, &.{});
    try g.addNode("T-001", .test_case, &.{});
    try g.addNode("T-002", .test_case, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("REQ-001", "TG-002", .tested_by);
    try g.addEdge("TG-001", "T-001", .has_test);
    try g.addEdge("TG-002", "T-002", .has_test);

    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);

    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("TG-001", rows.items[0].test_group_id.?);
    try testing.expectEqualStrings("TG-002", rows.items[1].test_group_id.?);
}

test "rtm includes empty linked test groups instead of dropping them" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "SHALL work" }});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addNode("TG-002", .test_group, &.{});
    try g.addNode("T-001", .test_case, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);
    try g.addEdge("REQ-001", "TG-002", .tested_by);
    try g.addEdge("TG-001", "T-001", .has_test);

    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);

    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqualStrings("TG-001", rows.items[0].test_group_id.?);
    try testing.expectEqualStrings("T-001", rows.items[0].test_id.?);
    try testing.expectEqualStrings("TG-002", rows.items[1].test_group_id.?);
    try testing.expect(rows.items[1].test_id == null);
}

test "rtm multiple requirements" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("REQ-001", .requirement, &.{.{ .key = "statement", .value = "one" }});
    try g.addNode("REQ-002", .requirement, &.{.{ .key = "statement", .value = "two" }});
    var rows: std.ArrayList(RtmRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.rtm(testing.allocator, &rows);
    try testing.expectEqual(2, rows.items.len);
}

test "risks with linked req" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "description", .value = "GPS loss" },
        .{ .key = "initial_severity", .value = "4" },
        .{ .key = "initial_likelihood", .value = "3" },
        .{ .key = "mitigation", .value = "Add redundant sensor" },
    });
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addEdge("RSK-001", "REQ-001", .mitigated_by);
    var rows: std.ArrayList(RiskRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.risks(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    const row = rows.items[0];
    try testing.expectEqualStrings("RSK-001", row.risk_id);
    try testing.expectEqualStrings("GPS loss", row.description);
    try testing.expectEqualStrings("REQ-001", row.req_id.?);
    try testing.expectEqualStrings("4", row.initial_severity.?);
}

test "risks no linked req" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("RSK-001", .risk, &.{
        .{ .key = "description", .value = "Unmitigated risk" },
    });
    var rows: std.ArrayList(RiskRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.risks(testing.allocator, &rows);
    try testing.expectEqual(1, rows.items.len);
    try testing.expect(rows.items[0].req_id == null);
}

test "risks empty graph" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    var rows: std.ArrayList(RiskRow) = .empty;
    defer rows.deinit(testing.allocator);
    try g.risks(testing.allocator, &rows);
    try testing.expectEqual(0, rows.items.len);
}

test "collectGapFindings distinguishes missing and unresolved test-group coverage" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("REQ-001", .requirement, &.{.{ .key = "declared_test_group_ref_count", .value = "0" }});
    try g.addNode("REQ-002", .requirement, &.{.{ .key = "declared_test_group_ref_count", .value = "2" }});

    var findings: std.ArrayList(GapFinding) = .empty;
    defer findings.deinit(testing.allocator);
    try g.collectGapFindings(testing.allocator, &findings);

    var saw_missing = false;
    var saw_unresolved = false;
    for (findings.items) |finding| {
        if (std.mem.eql(u8, finding.primary_id, "REQ-001") and finding.kind == .requirement_no_test_group_link) {
            saw_missing = true;
        }
        if (std.mem.eql(u8, finding.primary_id, "REQ-002") and finding.kind == .requirement_only_unresolved_test_group_refs) {
            saw_unresolved = true;
        }
    }
    try testing.expect(saw_missing);
    try testing.expect(saw_unresolved);
}

test "collectGapFindings includes advisory graph gaps" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("UN-001", .user_need, &.{});
    try g.addNode("REQ-001", .requirement, &.{});
    try g.addNode("TG-001", .test_group, &.{});
    try g.addEdge("REQ-001", "TG-001", .tested_by);

    var findings: std.ArrayList(GapFinding) = .empty;
    defer findings.deinit(testing.allocator);
    try g.collectGapFindings(testing.allocator, &findings);

    var saw_user_need = false;
    var saw_empty_group = false;
    for (findings.items) |finding| {
        if (finding.kind == .user_need_without_requirements and std.mem.eql(u8, finding.primary_id, "UN-001")) {
            saw_user_need = true;
        }
        if (finding.kind == .requirement_linked_to_empty_test_group and
            std.mem.eql(u8, finding.primary_id, "REQ-001") and
            std.mem.eql(u8, finding.related_id.?, "TG-001"))
        {
            saw_empty_group = true;
        }
    }
    try testing.expect(saw_user_need);
    try testing.expect(saw_empty_group);
}

test "collectGapFindings distinguishes missing and unresolved mitigations" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();

    try g.addNode("RSK-001", .risk, &.{.{ .key = "declared_mitigation_req_ref_count", .value = "0" }});
    try g.addNode("RSK-002", .risk, &.{.{ .key = "declared_mitigation_req_ref_count", .value = "1" }});
    try g.addEdge("RSK-002", "REQ-404", .mitigated_by);

    var findings: std.ArrayList(GapFinding) = .empty;
    defer findings.deinit(testing.allocator);
    try g.collectGapFindings(testing.allocator, &findings);

    var saw_missing = false;
    var saw_unresolved = false;
    for (findings.items) |finding| {
        if (finding.kind == .risk_without_mitigation_requirement and std.mem.eql(u8, finding.primary_id, "RSK-001")) {
            saw_missing = true;
        }
        if (finding.kind == .risk_unresolved_mitigation_requirement and std.mem.eql(u8, finding.primary_id, "RSK-002")) {
            saw_unresolved = true;
        }
    }
    try testing.expect(saw_missing);
    try testing.expect(saw_unresolved);
    try testing.expectEqual(@as(usize, 2), try g.hardGapCount(testing.allocator));
}

test "NodeType DI/DO/CI fromString and toString roundtrip" {
    try testing.expectEqual(NodeType.product, NodeType.fromString("Product").?);
    try testing.expectEqual(NodeType.design_input, NodeType.fromString("DesignInput").?);
    try testing.expectEqual(NodeType.design_output, NodeType.fromString("DesignOutput").?);
    try testing.expectEqual(NodeType.config_item, NodeType.fromString("ConfigurationItem").?);
    try testing.expectEqualStrings("Product", NodeType.product.toString());
    try testing.expectEqualStrings("DesignInput", NodeType.design_input.toString());
    try testing.expectEqualStrings("DesignOutput", NodeType.design_output.toString());
    try testing.expectEqualStrings("ConfigurationItem", NodeType.config_item.toString());
    try testing.expect(NodeType.fromString("Unknown") == null);
}

test "EdgeLabel new variants fromString and toString roundtrip" {
    try testing.expectEqual(EdgeLabel.allocated_to, EdgeLabel.fromString("ALLOCATED_TO").?);
    try testing.expectEqual(EdgeLabel.satisfied_by, EdgeLabel.fromString("SATISFIED_BY").?);
    try testing.expectEqual(EdgeLabel.refined_by, EdgeLabel.fromString("REFINED_BY").?);
    try testing.expectEqual(EdgeLabel.controlled_by, EdgeLabel.fromString("CONTROLLED_BY").?);
    try testing.expectEqual(EdgeLabel.changed_in, EdgeLabel.fromString("CHANGED_IN").?);
    try testing.expectEqual(EdgeLabel.changes, EdgeLabel.fromString("CHANGES").?);
    try testing.expectEqualStrings("ALLOCATED_TO", EdgeLabel.allocated_to.toString());
    try testing.expectEqualStrings("SATISFIED_BY", EdgeLabel.satisfied_by.toString());
    try testing.expectEqualStrings("REFINED_BY", EdgeLabel.refined_by.toString());
    try testing.expectEqualStrings("CONTROLLED_BY", EdgeLabel.controlled_by.toString());
    try testing.expectEqualStrings("CHANGED_IN", EdgeLabel.changed_in.toString());
    try testing.expectEqualStrings("CHANGES", EdgeLabel.changes.toString());
}

test "addNode and nodesByType for design_input" {
    var g = Graph.init(testing.allocator);
    defer g.deinit();
    try g.addNode("DI-001", .design_input, &.{.{ .key = "description", .value = "GPS timing spec" }});
    try g.addNode("DO-001", .design_output, &.{.{ .key = "description", .value = "GPS module" }});
    try g.addNode("CI-001", .config_item, &.{.{ .key = "version", .value = "1.0" }});

    var dis: std.ArrayList(*const Node) = .empty;
    defer dis.deinit(testing.allocator);
    try g.nodesByType(.design_input, testing.allocator, &dis);
    try testing.expectEqual(1, dis.items.len);
    try testing.expectEqualStrings("DI-001", dis.items[0].id);
}
