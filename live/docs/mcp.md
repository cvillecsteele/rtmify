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

## Prompts

Built-in prompts:
- `trace_requirement`
- `impact_of_change`
- `explain_gap`
- `audit_readiness_summary`
- `repo_coverage_summary`
- `design_history_summary`

## Compatibility

Legacy MCP tools remain available. New resources and prompts are additive.

## Scope

This phase is local-first only. RTMify does not yet expose a public/authenticated remote MCP mode.
