const std = @import("std");
const graph = @import("../graph.zig");
const diagnostic = @import("../diagnostic.zig");
const internal = @import("internal.zig");

const Diagnostics = internal.Diagnostics;
const Graph = internal.Graph;

const vague_words = &[_][]const u8{
    "appropriate", "adequate", "reasonable", "user-friendly", "fast",
    "reliable", "safe", "sufficient", "timely", "as needed", "if necessary",
    "etc.", "and/or",
};

fn hasEdgeFrom(g: *const Graph, from_id: []const u8, label: graph.EdgeLabel) bool {
    for (g.edges.items) |e| {
        if (e.label == label and std.mem.eql(u8, e.from_id, from_id)) return true;
    }
    return false;
}

pub fn semanticValidate(g: *const Graph, diag: *Diagnostics) !void {
    var it = g.nodes.valueIterator();
    while (it.next()) |node_ptr| {
        const node = node_ptr.*;
        switch (node.node_type) {
            .requirement => {
                const stmt = node.get("statement") orelse "";
                if (stmt.len == 0) {
                    try diag.warn(diagnostic.E.req_empty, .semantic, null, null,
                        "REQ {s}: empty requirement statement", .{node.id});
                    continue;
                }
                if (stmt.len < 10) {
                    try diag.warn(diagnostic.E.req_short, .semantic, null, null,
                        "REQ {s}: statement very short ({d} chars)", .{ node.id, stmt.len });
                }
                var shall_count: usize = 0;
                var sp: usize = 0;
                while (sp < stmt.len) {
                    if (std.ascii.indexOfIgnoreCase(stmt[sp..], "shall")) |rel| {
                        shall_count += 1;
                        sp += rel + 5;
                    } else break;
                }
                if (shall_count == 0) {
                    try diag.warn(diagnostic.E.req_no_shall, .semantic, null, null,
                        "REQ {s}: statement has no 'shall'", .{node.id});
                } else if (shall_count > 1) {
                    try diag.warn(diagnostic.E.req_compound, .semantic, null, null,
                        "REQ {s}: compound requirement — {d} 'shall' clauses detected; split into separate requirements",
                        .{ node.id, shall_count });
                }
                for (vague_words) |vw| {
                    if (std.ascii.indexOfIgnoreCase(stmt, vw) != null) {
                        try diag.warn(diagnostic.E.req_vague, .semantic, null, null,
                            "REQ {s}: vague term '{s}' in statement", .{ node.id, vw });
                    }
                }
                const status = node.get("status") orelse "";
                if (std.ascii.eqlIgnoreCase(status, "obsolete")) {
                    if (hasEdgeFrom(g, node.id, .derives_from) or
                        hasEdgeFrom(g, node.id, .tested_by))
                    {
                        try diag.warn(diagnostic.E.req_obsolete_traced, .semantic, null, null,
                            "REQ {s}: status is 'obsolete' but still has active trace links",
                            .{node.id});
                    }
                }
            },
            .risk => {
                const isev_s = node.get("initial_severity") orelse "";
                const ilik_s = node.get("initial_likelihood") orelse "";
                const rsev_s = node.get("residual_severity") orelse "";
                const rlik_s = node.get("residual_likelihood") orelse "";

                if ((isev_s.len > 0) != (ilik_s.len > 0)) {
                    try diag.warn(diagnostic.E.risk_score_mismatch, .semantic, null, null,
                        "Risk {s}: severity and likelihood must both be present or both absent",
                        .{node.id});
                }
                const mit = node.get("mitigation") orelse "";
                if (isev_s.len > 0 and ilik_s.len > 0 and mit.len == 0) {
                    const sev = std.fmt.parseInt(u32, isev_s, 10) catch 0;
                    const lik = std.fmt.parseInt(u32, ilik_s, 10) catch 0;
                    if (sev * lik > 12) {
                        try diag.warn(diagnostic.E.risk_unmitigated, .semantic, null, null,
                            "Risk {s}: score {d} > 12 but no mitigation", .{ node.id, sev * lik });
                    }
                }
                if ((rsev_s.len > 0 or rlik_s.len > 0) and
                    (isev_s.len == 0 or ilik_s.len == 0))
                {
                    try diag.warn(diagnostic.E.risk_residual_no_init, .semantic, null, null,
                        "Risk {s}: residual scores present but initial scores absent", .{node.id});
                }
                if (isev_s.len > 0 and ilik_s.len > 0 and
                    rsev_s.len > 0 and rlik_s.len > 0)
                {
                    const isev = std.fmt.parseInt(u32, isev_s, 10) catch 0;
                    const ilik = std.fmt.parseInt(u32, ilik_s, 10) catch 0;
                    const rsev = std.fmt.parseInt(u32, rsev_s, 10) catch 0;
                    const rlik = std.fmt.parseInt(u32, rlik_s, 10) catch 0;
                    if (isev > 0 and ilik > 0 and rsev * rlik > isev * ilik) {
                        try diag.warn(diagnostic.E.risk_residual_exceeds, .semantic, null, null,
                            "Risk {s}: residual score ({d}) exceeds initial score ({d}) — mitigation should reduce risk, not increase it",
                            .{ node.id, rsev * rlik, isev * ilik });
                    }
                }
            },
            .test_group => {
                if (!hasEdgeFrom(g, node.id, .has_test)) {
                    try diag.warn(diagnostic.E.test_group_empty, .semantic, null, null,
                        "Test group {s} has no test cases", .{node.id});
                }
            },
            else => {},
        }
    }
}
