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
- `design-bom://<full_product_identifier>/<bom_name>`
- `software-boms://`
- `soup-components://<full_product_identifier>/<bom_name>`
- `soup-component://<full_product_identifier>/<bom_name>/<part>@<revision>`
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

`design-bom://...` is the BOM-wide read model. It summarizes:
- matching Design BOM variants (`hardware`, `software`)
- root assembly tree
- item counts
- unresolved traceability warnings

`bom-item://...` is the BOM-trace drilldown resource. It summarizes:
- parent chains
- declared `requirement_ids` and `test_ids`
- resolved linked Requirement and Test nodes
- unresolved declared refs that did not match the graph

`soup-components://...` is the SOUP/software register read model. It summarizes:
- component inventory
- supplier, license, purl, and safety class
- anomaly documentation and evaluation text
- resolved and unresolved requirement/test links
- SOUP status flags such as `SOUP_VERSION_UNKNOWN`

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
- BOM queries such as `get_bom`, `get_bom_item`, `list_design_boms`, `find_part_usage`, `bom_gaps`, `bom_impact_analysis`, `list_software_boms`, `get_soup_components`, `soup_by_safety_class`, `soup_by_license`, `get_product_serials`

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

### `list_design_boms`

Returns BOM summary rows for the active workbook, optionally filtered by:
- `full_product_identifier`
- `bom_name`

Each row includes:
- `full_product_identifier`
- `bom_name`
- `bom_type`
- `source_format`
- `ingested_at`
- `item_count`

### `find_part_usage`

Arguments:
- `part` required

Returns every Design BOM occurrence where that part is present, including:
- owning product
- Design BOM identity
- parent item context
- `CONTAINS` edge facts such as quantity, supplier, and ref designator

### `bom_gaps`

Arguments:
- `full_product_identifier` optional
- `bom_name` optional

Returns only BOM items with traceability gaps, including:
- unresolved requirement IDs
- unresolved test/test-group IDs
- linked requirement count
- linked test/test-group count

### `bom_impact_analysis`

Arguments:
- `full_product_identifier` required
- `bom_name` required

Returns BOM items plus their currently linked requirements and tests/test-groups, so clients can answer BOM-centered impact questions without switching tools.

## Prompts

Built-in prompts:
- `trace_requirement`
- `impact_of_change`
- `explain_gap`
- `audit_readiness_summary`
- `repo_coverage_summary`
- `design_history_summary`
- `inspect_bom_item_traceability`
- `eol_impact`
- `bom_coverage`
- `component_substitute`
- `soup_audit_prep`
- `soup_coverage`

## SOUP Tool Contracts

### `list_software_boms`

Returns software `DesignBOM` summaries, including manual SOUP registers and automated SBOM ingests. Optional filters:

- `full_product_identifier`
- `bom_name`
- `include_obsolete`

### `get_soup_components`

Arguments:

- `full_product_identifier` required
- `bom_name` optional, defaults to `SOUP Components`
- `include_obsolete` optional

Returns flattened component rows with:

- `part`
- `revision`
- `supplier`
- `category`
- `license`
- `purl`
- `safety_class`
- `known_anomalies`
- `anomaly_evaluation`
- declared and linked requirement/test counts
- unresolved declared refs
- SOUP status flags

### `soup_by_safety_class`

Arguments:

- `full_product_identifier` required
- `safety_class` required
- `include_obsolete` optional

Returns software components filtered to one product and one safety class.

### `soup_by_license`

Arguments:

- `full_product_identifier` optional
- `license` optional
- `include_obsolete` optional

Returns software components filtered by product and/or a license substring.

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

The Design BOM prompts are complementary:

- `eol_impact`
  - guides the client to use `find_part_usage` and `bom_impact_analysis`
  - answers which products and linked controls are affected by an obsolete component
- `bom_coverage`
  - guides the client to use `list_design_boms`, `get_bom_item`, and `bom_gaps`
  - summarizes explicit BOM trace coverage and unresolved refs
- `component_substitute`
  - guides the client to inspect one part’s current usage and trace obligations before substitution

## Compatibility

Legacy MCP tools remain available. New resources and prompts are additive.
Structured tool results are additive and backward-compatible because the
existing `content[].text` payloads remain unchanged.

## Scope

This phase is local-first only. RTMify does not yet expose a public/authenticated remote MCP mode.
