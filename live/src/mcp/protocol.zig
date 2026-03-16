const std = @import("std");

pub const resources_json =
    \\[
    \\{"uri":"report://status","name":"Live Status","description":"Current sync and connection status.","mimeType":"text/markdown"},
    \\{"uri":"report://chain-gaps","name":"Chain Gap Summary","description":"Summary of current profile-specific traceability gaps.","mimeType":"text/markdown"},
    \\{"uri":"report://rtm","name":"RTM Summary","description":"Summary of requirements traceability matrix coverage.","mimeType":"text/markdown"},
    \\{"uri":"report://code-traceability","name":"Code Traceability Summary","description":"Summary of source and test file traceability.","mimeType":"text/markdown"},
    \\{"uri":"report://review","name":"Review Summary","description":"Summary of suspect items requiring review.","mimeType":"text/markdown"}
    \\]
;

pub const prompts_json =
    \\[
    \\{"name":"trace_requirement","description":"Trace one requirement through tests, risks, code, commits, and gaps.","arguments":[{"name":"id","description":"Requirement ID (e.g. REQ-001)","required":true}]},
    \\{"name":"impact_of_change","description":"Analyze downstream impact from changing a traced node.","arguments":[{"name":"id","description":"Node ID (e.g. UN-001 or REQ-001)","required":true}]},
    \\{"name":"explain_gap","description":"Explain why RTMify raised a specific chain gap.","arguments":[{"name":"code","description":"Gap code (e.g. 1203)","required":true},{"name":"node_id","description":"Node ID tied to the gap","required":true}]},
    \\{"name":"audit_readiness_summary","description":"Summarize RTMify readiness for the selected profile.","arguments":[{"name":"profile","description":"Profile name (generic, medical, aerospace, automotive)","required":true}]},
    \\{"name":"repo_coverage_summary","description":"Summarize repo-backed implementation and test coverage.","arguments":[{"name":"repo","description":"Optional repo path filter","required":false}]},
    \\{"name":"design_history_summary","description":"Summarize design history for a requirement.","arguments":[{"name":"req_id","description":"Requirement ID (e.g. REQ-001)","required":true}]}
    \\]
;

pub const tools_json =
    \\[
    \\{"name":"list_workbooks","description":"List configured non-removed workbooks in this Live server.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"get_active_workbook","description":"Get the currently active workbook.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"switch_workbook","description":"Switch the active workbook by id or display name.","inputSchema":{"oneOf":[{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},{"type":"object","properties":{"display_name":{"type":"string"}},"required":["display_name"]}]},"outputSchema":{"type":"object"}},
    \\{"name":"get_rtm","description":"Get the Requirements Traceability Matrix. Optional limit/offset and suspect-only filtering.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"},"suspect_only":{"type":"boolean"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_gaps","description":"Get requirements with no test linked. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_suspects","description":"Get all suspect nodes. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_nodes","description":"Get graph nodes, optionally filtered by type. Supports limit and offset.","inputSchema":{"type":"object","properties":{"type":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_node","description":"Get a single node by ID. Set include_edges or include_properties to false to omit those sections from the result.","inputSchema":{"type":"object","properties":{"id":{"type":"string"},"include_edges":{"type":"boolean","default":true},"include_properties":{"type":"boolean","default":true}},"required":["id"]},"outputSchema":{"type":"object"}},
    \\{"name":"search","description":"Full-text search across node IDs and properties. Supports limit.","inputSchema":{"type":"object","properties":{"q":{"type":"string"},"limit":{"type":"integer"}},"required":["q"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_user_needs","description":"Get User Need nodes. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_tests","description":"Get Test nodes with linked requirements. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_risks","description":"Get the risk register. Optional limit and offset.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_impact","description":"Get impact analysis for a node.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_schema","description":"Get the graph schema: node types, edge labels, and meanings.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"get_status","description":"Get sync state, connection, and license status.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"clear_suspect","description":"Mark a suspect node as reviewed.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},"outputSchema":{"type":"object"}},
    \\{"name":"code_traceability","description":"Source and test files with annotation counts. Supports repo and limit.","inputSchema":{"type":"object","properties":{"repo":{"type":"string"},"limit":{"type":"integer"}},"required":[]},"outputSchema":{"type":"object"}},
    \\{"name":"unimplemented_requirements","description":"Requirements with no IMPLEMENTED_IN edge.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"untested_source_files","description":"Source files with no VERIFIED_BY_CODE edge.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"file_annotations","description":"Code annotations found in a specific source file.","inputSchema":{"type":"object","properties":{"file_path":{"type":"string"},"limit":{"type":"integer"}},"required":["file_path"]},"outputSchema":{"type":"array"}},
    \\{"name":"blame_for_requirement","description":"Code annotations with blame data linked to a requirement.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"},"limit":{"type":"integer"}},"required":["req_id"]},"outputSchema":{"type":"array"}},
    \\{"name":"commit_history","description":"Commits linked to a requirement via COMMITTED_IN edges. Supports limit.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"},"limit":{"type":"integer"}},"required":["req_id"]},"outputSchema":{"type":"array"}},
    \\{"name":"design_history","description":"Full upstream/downstream chain for a requirement.","inputSchema":{"type":"object","properties":{"req_id":{"type":"string"}},"required":["req_id"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_test_results","description":"Get ingested test results for a test case, newest first.","inputSchema":{"type":"object","properties":{"test_case_ref":{"type":"string"}},"required":["test_case_ref"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_execution","description":"Get a stored test execution by execution_id.","inputSchema":{"type":"object","properties":{"execution_id":{"type":"string"}},"required":["execution_id"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_verification_status","description":"Get verification rollup and latest results for a requirement.","inputSchema":{"type":"object","properties":{"requirement_ref":{"type":"string"}},"required":["requirement_ref"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_dangling_results","description":"Get ingested test results that do not resolve to a known Test node.","inputSchema":{"type":"object","properties":{},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"get_unit_history","description":"Get test execution history for a serial number, newest first.","inputSchema":{"type":"object","properties":{"serial_number":{"type":"string"}},"required":["serial_number"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_bom","description":"Get BOM trees for a product, optionally filtered by bom_type or bom_name.","inputSchema":{"type":"object","properties":{"full_product_identifier":{"type":"string"},"bom_type":{"type":"string","enum":["hardware","software"]},"bom_name":{"type":"string"}},"required":["full_product_identifier"]},"outputSchema":{"type":"object"}},
    \\{"name":"get_bom_item","description":"Get a single BOM item and its parent chains.","inputSchema":{"oneOf":[{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},{"type":"object","properties":{"full_product_identifier":{"type":"string"},"bom_type":{"type":"string","enum":["hardware","software"]},"bom_name":{"type":"string"},"part":{"type":"string"},"revision":{"type":"string"}},"required":["full_product_identifier","bom_type","bom_name","part","revision"]}]},"outputSchema":{"type":"object"}},
    \\{"name":"get_product_serials","description":"Get serial-bearing test executions scoped to a product.","inputSchema":{"type":"object","properties":{"full_product_identifier":{"type":"string"}},"required":["full_product_identifier"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_components_by_supplier","description":"Get BOM components linked through CONTAINS edges with a matching supplier.","inputSchema":{"type":"object","properties":{"supplier":{"type":"string"}},"required":["supplier"]},"outputSchema":{"type":"array"}},
    \\{"name":"get_software_components","description":"Get software BOM components, optionally filtered by purl prefix or license.","inputSchema":{"type":"object","properties":{"purl_prefix":{"type":"string"},"license":{"type":"string"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"chain_gaps","description":"Traceability chain gaps for the active or requested industry profile. Supports severity, profile, limit, and offset.","inputSchema":{"type":"object","properties":{"profile":{"type":"string"},"severity":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":[]},"outputSchema":{"type":"array"}},
    \\{"name":"implementation_changes_since","description":"Find requirements or user needs whose implementation files changed since an ISO timestamp. This uses file/commit history, not explicit COMMITTED_IN message references. Supports repo, limit, and offset.","inputSchema":{"type":"object","properties":{"since":{"type":"string"},"node_type":{"type":"string","enum":["Requirement","UserNeed"]},"repo":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"}},"required":["since","node_type"]},"outputSchema":{"type":"array"}},
    \\{"name":"requirement_trace","description":"Concise markdown trace summary for a requirement.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
    \\{"name":"gap_explanation","description":"Concise markdown explanation for a specific chain gap.","inputSchema":{"type":"object","properties":{"code":{"type":"integer"},"node_id":{"type":"string"}},"required":["code","node_id"]}},
    \\{"name":"impact_summary","description":"Concise markdown impact summary for a node.","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},
    \\{"name":"status_summary","description":"Concise markdown summary of Live status.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"review_summary","description":"Concise markdown summary of suspects and open chain gaps.","inputSchema":{"type":"object","properties":{},"required":[]}}
    \\]
;

pub const initialize_result =
    \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{},"prompts":{}},"serverInfo":{"name":"rtmify-live","version":"1.0"}}
;

pub const json_rpc_headers = [_]std.http.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Connection", .value = "close" },
};
