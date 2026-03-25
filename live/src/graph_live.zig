/// graph_live.zig — backward-compatible shim for the graph package.
const graph = @import("graph/mod.zig");

pub const Node = graph.Node;
pub const Edge = graph.Edge;
pub const RuntimeDiagnostic = graph.RuntimeDiagnostic;
pub const RtmRow = graph.RtmRow;
pub const RiskRow = graph.RiskRow;
pub const TestRow = graph.TestRow;
pub const ImpactNode = graph.ImpactNode;
pub const ImplementationChangeEvidence = graph.ImplementationChangeEvidence;
pub const GraphCounts = graph.GraphCounts;
pub const RequirementSourceAssertion = graph.RequirementSourceAssertion;
pub const RequirementTextResolution = graph.RequirementTextResolution;
pub const GraphDb = graph.GraphDb;
pub const hashRow = graph.hashRow;
