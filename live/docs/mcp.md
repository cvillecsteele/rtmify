# RTMify Live MCP

RTMify Live serves MCP over local Streamable HTTP at `/mcp`.

## Endpoint

- Local MCP URL: `http://127.0.0.1:<port>/mcp`
- Transport:
  - `POST /mcp` for JSON-RPC requests
  - `GET /mcp` for legacy SSE endpoint discovery
- Scope:
  - loopback-only transport
  - no CORS support
  - remote/browser-cross-origin access is intentionally unsupported

## Methods

RTMify exposes:
- `tools/list`
- `tools/call`
- `resources/list`
- `resources/read`
- `prompts/list`
- `prompts/get`

## Resource URIs

Canonical resource URIs:
- `bom-item://<full_product_identifier>/<bom_type>/<bom_name>/<part>@<revision>`
- `requirement://<id>`
- `user-need://<id>`
- `risk://<id>`
- `test://<id>`
- `test-group://<id>`
- `node://<id>`
- `impact://<id>`
- `design-history://<id>`
- `gap://<code>/<node_id>`
- `report://status`
- `report://chain-gaps`
- `report://rtm`
- `report://code-traceability`
- `report://review`

Resource bodies are returned as Markdown.

`bom-item://...` is the BOM-trace drilldown resource. It summarizes:
- parent chains
- declared `requirement_ids` and `test_ids`
- resolved linked Requirement and Test nodes
- unresolved declared refs that did not match the graph

When node-like resources include edge lists, the Markdown now preserves
non-null edge properties inline. This matters most for BOM `CONTAINS`
relationships, where occurrence data such as `quantity`, `ref_designator`,
`supplier`, and `relation_source` live on the edge rather than the node.

## Tool Results

RTMify MCP tools are split into two output classes:

- Structured data tools
  - return the existing `content[].text` block for backward compatibility
  - also return `structuredContent` with the parsed JSON object or array
- Narrative tools
  - return text-only Markdown in `content`
  - omit `structuredContent`

Structured data tools include:
- graph queries such as `get_rtm`, `get_node`, `search`, `get_schema`
- verification/test-result queries such as `get_execution`, `get_verification_status`
- BOM queries such as `get_bom`, `get_bom_item`, `get_product_serials`

Narrative tools include:
- `requirement_trace`
- `gap_explanation`
- `impact_summary`
- `status_summary`
- `review_summary`

The compatibility rule is simple:
- old clients may continue reading `content[].text`
- MCP-native clients should prefer `structuredContent` when it is present

Every tool response now carries explicit workbook context:

- structured tools return:
  - `structuredContent.workbook`
  - `structuredContent.data`
- narrative tools prefix the markdown with `[Workbook: ...]`
  and return structured content shaped like:
  - `workbook`
  - `markdown`

This is intentional. Live now supports multiple workbooks inside one running
server, so MCP clients must always be able to tell which workbook they are
reading.

## Workbook Tools

New workbook-management tools:
- `list_workbooks`
- `get_active_workbook`
- `switch_workbook`

`switch_workbook` accepts either:
- `id`
- `display_name`

Switching is hot at the MCP boundary:
- the MCP endpoint stays the same
- the active workbook runtime changes underneath it
- subsequent tool calls operate on the newly active workbook

## Important Tool Contracts

### `get_node`

Arguments:
- `id` required
- `include_edges` optional, defaults to `true`
- `include_properties` optional, defaults to `true`

Behavior:
- `include_edges = false` omits `edges_out` and `edges_in`
- `include_properties = false` omits `properties`
- both false return only the top-level node identity and suspect metadata

### `get_bom_item`

This tool accepts exactly one of two selector modes:

1. Direct ID lookup
   - `id`

2. Composite lookup
   - `full_product_identifier`
   - `bom_type`
   - `bom_name`
   - `part`
   - `revision`

Partial composite selectors are rejected. The tool returns a specific
invalid-argument message telling the caller to provide either `id` or the full
composite selector.

The result includes:
- `node`
- `parent_chains`
- `linked_requirements`
- `linked_tests`
- `unresolved_requirement_ids`
- `unresolved_test_ids`

## Prompts

Built-in prompts:
- `trace_requirement`
- `impact_of_change`
- `explain_gap`
- `audit_readiness_summary`
- `repo_coverage_summary`
- `design_history_summary`
- `inspect_bom_item_traceability`

`inspect_bom_item_traceability` is the guided entrypoint for BOM trace review.
It accepts either:
- `id`
- or the full composite selector:
  - `full_product_identifier`
  - `bom_type`
  - `bom_name`
  - `part`
  - `revision`

The prompt instructs the client to call `get_bom_item`, read the matching
`bom-item://...` resource, distinguish resolved links from unresolved declared
refs, and summarize likely next fixes.

## Compatibility

Legacy MCP tools remain available. New resources and prompts are additive.
Structured tool results are additive and backward-compatible because the
existing `content[].text` payloads remain unchanged.

## Scope

This phase is local-first only. RTMify does not yet expose a public/authenticated remote MCP mode.
