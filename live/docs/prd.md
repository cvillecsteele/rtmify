# RTMify Live — Zig Port
## Product Requirements Document
### Version 0.1

For the current implementation architecture, including the `native shim + embedded webserver + browser UI` split, see [architecture.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md).

---

## 1. What This Is

RTMify Live is a local server that syncs a Google Sheet to a requirements graph, runs continuous gap analysis and suspect propagation, writes status back to the sheet, serves a web dashboard on loopback (`127.0.0.1`), and exposes an MCP endpoint for AI agent integration. One binary. One command. One process.

```
$ rtmify-live
RTMify Live running at http://127.0.0.1:8000
MCP endpoint: http://127.0.0.1:8000/mcp
Syncing: https://docs.google.com/spreadsheets/d/1abc.../
```

The product exists today as a working Python prototype (CALM). FastAPI server, Google Sheets polling, SQLite-backed graph, Jinja2 PDF reports, vanilla JS web UI, MCP via fastapi-mcp. It works. It can't ship. Python requires a runtime, a package manager, a virtual environment, and eleven pip dependencies including WeasyPrint (which has native library dependencies of its own). The target user — a quality engineer at a medical device or aerospace company — cannot and will not install any of that.

This document specifies the port from Python to Zig. The architecture, data model, sync behavior, API surface, web UI, and MCP protocol are all proven. The work is a reimplementation, not a redesign.

---

## 2. What We Have

### 2.1 Python Prototype (CALM)

| File | Lines | Role |
|------|-------|------|
| `graph.py` | 656 | Graph layer: nodes, edges, traversal, RTM/risk/test queries, suspect propagation, impact analysis |
| `sync.py` | ~500 | Google Sheets polling: row hashing, change detection, ingestion, status writeback, row coloring, error tab |
| `backend.py` | ~800 | FastAPI: all API routes, report generation (PDF/MD/DOCX), config endpoints, MCP mount, static file serving |
| `index.html` | 46K | Web UI: requirements table, user needs, tests, risks, RTM, impact analysis, review queue, node drawer, inline expansion |
| `templates/rtm.html` | ~180 | Jinja2 HTML template for WeasyPrint PDF generation |

Dependencies: FastAPI, uvicorn, WeasyPrint, Jinja2, google-api-python-client, google-auth, python-docx, fastapi-mcp.

### 2.2 Zig Codebase (librtmify / Trace)

| File | Lines | Reusable in Live? |
|------|-------|-------------------|
| `graph.zig` | 656 | **Partially.** Trace's graph is in-memory with arena allocation. Live needs SQLite persistence, node history, and suspect columns. The query interface (rtm, risks, tests, gaps, impact) is the same. |
| `schema.zig` | 1,756 | **Yes.** Tab discovery, column mapping, row normalization, all seven validation layers. Live parses the same four-tab schema from Sheets API data instead of XLSX. |
| `diagnostic.zig` | 459 | **Yes.** Same warning/error infrastructure. |
| `xlsx.zig` | 1,033 | **No.** Live reads from the Sheets API, not XLSX files. |
| `render_md.zig` | 337 | **Yes.** Same Markdown report. |
| `render_docx.zig` | 665 | **Yes.** Same DOCX report. |
| `render_pdf.zig` | 829 | **Yes.** Same PDF report. |
| `license.zig` | 633 | **Yes.** Same LemonSqueezy integration, same cache path. |
| `main.zig` | 592 | **No.** Trace's CLI entry point. Live has its own. |
| `lib.zig` | 350 | **Partially.** C ABI exports stay for future native shells. Module re-exports restructured. |

### 2.3 What Live Needs That Trace Doesn't Have

| Capability | Python Implementation | Zig Implementation |
|-----------|----------------------|-------------------|
| HTTP server | FastAPI + uvicorn | `std.http.Server` |
| JSON API routes | FastAPI route decorators | Request path matching + `std.json` serialization |
| Static file serving | `StaticFiles` mount | Read file from embedded or disk, write to response |
| Google Sheets API client | `google-api-python-client` | HTTP client + JSON (REST calls) |
| Google service account auth | `google.oauth2.service_account` | JWT construction (RS256 signing) + token exchange |
| Polling sync loop | `threading.Thread` daemon | `std.Thread.spawn` |
| Row-level change detection | `hashlib.sha256` | `std.crypto.hash.sha2.Sha256` |
| SQLite persistence | `sqlite3` stdlib | C library linked via Zig's C interop |
| Node history / audit trail | `INSERT INTO node_history` | Same SQL through SQLite C API |
| Suspect propagation | Python BFS on edges | Same algorithm, Zig implementation |
| Status writeback to sheet | `spreadsheets.values.batchUpdate` | HTTP POST with JSON body |
| Row color writeback | `spreadsheets.batchUpdate` (repeatCell) | HTTP POST with JSON body |
| MCP server (SSE transport) | `fastapi-mcp` | SSE: chunked HTTP response with `text/event-stream` |
| HTML template rendering | Jinja2 | Not needed — PDF uses `render_pdf.zig`, HTML reports served as web UI |
| WeasyPrint PDF | `HTML(string=...).write_pdf()` | Not needed — `render_pdf.zig` already exists |
| python-docx | `Document()` builder | Not needed — `render_docx.zig` already exists |

---

## 3. Build Artifact

One binary per platform: `rtmify-live`. Same cross-compilation model as Trace.

```
zig build live -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
zig build live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

The build step in `sys/build.zig` adds a `live` executable that links:
- All shared modules (graph, schema, diagnostic, renderers, license)
- The Live-specific modules (server, sync, sheets API client, MCP, SQLite)
- SQLite amalgamation (`sqlite3.c`) compiled as a C source file via Zig's C compilation

The web UI (`index.html` and any static assets) is embedded into the binary at compile time using `@embedFile`. No external files to distribute. No `static/` directory to keep next to the exe. One file.

Expected binary size: 5-10MB (larger than Trace's 4MB due to SQLite and the embedded web UI).

Release targets — same six as Trace:

```
rtmify-live-macos-arm64
rtmify-live-macos-x64
rtmify-live-windows-x64
rtmify-live-windows-arm64
rtmify-live-linux-x64
rtmify-live-linux-arm64
```

---

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  rtmify-live binary                                             │
│                                                                 │
│  ┌─────────────────┐   ┌──────────────────────────────────┐    │
│  │  Sync Thread     │   │  HTTP Server (main thread)        │    │
│  │  polls Sheets    │   │                                    │    │
│  │  every 30s       │   │  /              → index.html       │    │
│  │  diffs rows      │   │  /api/status    → config state     │    │
│  │  updates graph   │   │  /query/rtm     → RTM JSON         │    │
│  │  writes back     │   │  /query/gaps    → gaps JSON        │    │
│  │  status + colors │   │  /query/impact  → impact JSON      │    │
│  └───────┬─────────┘   │  /query/suspects → suspects JSON   │    │
│          │              │  /report/rtm     → PDF              │    │
│          │              │  /report/rtm.md  → Markdown         │    │
│          │              │  /report/rtm.docx → Word            │    │
│          ▼              │  /mcp            → SSE (MCP)        │    │
│  ┌─────────────────┐   │  ... (all routes from backend.py)   │    │
│  │  SQLite          │   └──────────────────────────────────┘    │
│  │  graph.db        │                                           │
│  │  nodes + edges   │◄──── shared: sync thread writes,         │
│  │  node_history    │      HTTP server reads                    │
│  │  credentials     │                                           │
│  │  config          │                                           │
│  └─────────────────┘                                            │
└─────────────────────────────────────────────────────────────────┘
         │
         │  HTTPS (Google Sheets API)
         ▼
┌─────────────────────┐
│  Google Sheets       │
│  (user's workspace)  │
└─────────────────────┘
```

Two threads share one SQLite connection in WAL mode. The sync thread writes. The HTTP server reads. WAL mode ensures readers never block writers and writers never block readers. This is the same concurrency model as the Python prototype (which uses `check_same_thread=False` and `PRAGMA journal_mode=WAL`).

---

## 5. SQLite

### 5.1 Why SQLite Instead of In-Memory

Trace's graph lives in memory because Trace processes one file and exits. Live runs continuously. The graph must survive restarts — if the user quits and relaunches, they should see their requirements, not an empty dashboard waiting for the next sync cycle. SQLite also provides the node history table (audit trail) and the credentials/config tables that the Python prototype already uses.

### 5.2 Integration

The SQLite amalgamation (`sqlite3.c` + `sqlite3.h`, ~250KB of C source) is compiled directly by Zig. No system SQLite dependency. No dynamic linking. The amalgamation is included in the source tree and compiled as a C source file in `sys/build.zig`:

```zig
live_exe.addCSourceFile(.{
    .file = b.path("lib/vendor/sqlite3.c"),
    .flags = &.{ "-DSQLITE_THREADSAFE=2", "-DSQLITE_ENABLE_FTS5=0" },
});
```

`SQLITE_THREADSAFE=2` enables multi-thread mode (one connection shared across threads with Zig-side serialization via a mutex around write operations). Combined with WAL mode, this gives safe concurrent reads and writes.

### 5.3 Schema

Identical to the Python prototype's `graph.py._init_schema`:

```sql
CREATE TABLE IF NOT EXISTS nodes (
    id          TEXT PRIMARY KEY,
    type        TEXT NOT NULL,
    properties  TEXT NOT NULL,        -- JSON
    row_hash    TEXT,
    suspect     INTEGER DEFAULT 0,
    suspect_reason TEXT,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS node_history (
    node_id       TEXT NOT NULL,
    properties    TEXT NOT NULL,
    superseded_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS edges (
    id          TEXT PRIMARY KEY,
    from_id     TEXT NOT NULL REFERENCES nodes(id),
    to_id       TEXT NOT NULL REFERENCES nodes(id),
    label       TEXT NOT NULL,
    properties  TEXT,
    created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS credentials (
    id         TEXT PRIMARY KEY,
    content    TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_edges_from   ON edges(from_id);
CREATE INDEX IF NOT EXISTS idx_edges_to     ON edges(to_id);
CREATE INDEX IF NOT EXISTS idx_nodes_type   ON nodes(type);
CREATE INDEX IF NOT EXISTS idx_history_node ON node_history(node_id);
```

### 5.4 Graph Layer Differences from Trace

Trace's `graph.zig` uses `ArenaAllocator` and in-memory arrays/hashmaps. Live's graph layer wraps SQLite with the same public API but different internals:

| Operation | Trace (in-memory) | Live (SQLite) |
|-----------|-------------------|---------------|
| `addNode` | append to ArrayList, insert in HashMap | `INSERT OR IGNORE INTO nodes` |
| `updateNode` | overwrite in ArrayList | `INSERT INTO node_history` then `UPDATE nodes` |
| `upsertNode` | check HashMap, add or update | `SELECT row_hash`, then add or update |
| `addEdge` | append to ArrayList | `INSERT INTO edges` (with idempotency check) |
| `getNode` | HashMap lookup | `SELECT ... WHERE id=?` |
| `edgesFrom` | scan edges ArrayList | `SELECT ... WHERE from_id=?` (indexed) |
| `rtm()` | iterate nodes, join in memory | Single SQL JOIN query (same as Python) |
| `risks()` | iterate nodes, join in memory | Single SQL JOIN query |
| `tests()` | iterate nodes, join in memory | Single SQL JOIN query |
| `nodesMissingEdge` | scan with filter | `SELECT ... WHERE NOT EXISTS` |
| `impact()` | BFS in memory | BFS with SQLite edge lookups per step |
| `suspects()` | scan with filter | `SELECT ... WHERE suspect=1` |
| `_propagateSuspect` | N/A in Trace | `UPDATE nodes SET suspect=1` for downstream nodes |

The Zig wrapper around SQLite is a thin module (`db.zig`) that handles: opening the connection, WAL pragma, schema init, prepared statement caching, and translating between Zig types and SQLite bind/column calls. The graph module (`graph_live.zig`) calls `db.zig` and never touches the SQLite C API directly.

---

## 6. Google Sheets API Client

### 6.1 Authentication: Service Account JWT

The Python prototype uses `google.oauth2.service_account` which handles JWT construction, RSA signing, and token exchange. In Zig, this is:

1. Read the service account JSON (same file the Python version uses)
2. Extract `client_email` and `private_key` (PEM-encoded RSA key)
3. Construct a JWT: `{"iss": email, "scope": "spreadsheets drive.readonly", "aud": "https://oauth2.googleapis.com/token", "iat": now, "exp": now+3600}`
4. Sign the JWT with RS256 (RSA-SHA256). Zig's `std.crypto` has SHA256. RSA signing requires parsing the PEM private key and performing the signing operation. This is the most complex cryptographic operation in the entire port.
5. POST the signed JWT to `https://oauth2.googleapis.com/token` with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`
6. Receive an access token valid for 1 hour
7. Cache the token, refresh when expired

**PEM/RSA complexity:** The service account JSON contains a PEM-encoded PKCS#8 RSA private key. Parsing this requires: base64 decoding the PEM body, parsing the DER/ASN.1 structure to extract the RSA key parameters, then performing RSA-PKCS1v15-SHA256 signing. Zig's stdlib includes `std.crypto.Certificate` for TLS, which handles X.509 parsing, but JWT signing with a raw PEM key may need a thin wrapper.

Alternative: shell out to `openssl` for signing during prototyping, replace with native Zig crypto before shipping. This is a pragmatic phasing choice.

### 6.2 Sheets API Calls

All calls are HTTPS REST to `sheets.googleapis.com` and `www.googleapis.com/drive`. The Python client library abstracts these, but the raw HTTP calls are straightforward:

**Read rows:**
```
GET https://sheets.googleapis.com/v4/spreadsheets/{id}/values/{tab}!A2:H
Authorization: Bearer {token}
```

**Write status column:**
```
POST https://sheets.googleapis.com/v4/spreadsheets/{id}/values:batchUpdate
Authorization: Bearer {token}
Content-Type: application/json

{"valueInputOption": "RAW", "data": [{"range": "Requirements!H2", "values": [["OK"]]}]}
```

**Write row colors:**
```
POST https://sheets.googleapis.com/v4/spreadsheets/{id}:batchUpdate
Authorization: Bearer {token}
Content-Type: application/json

{"requests": [{"repeatCell": {"range": {...}, "cell": {"userEnteredFormat": {"backgroundColor": {...}}}, "fields": "userEnteredFormat.backgroundColor"}}]}
```

**Drive file metadata (change detection):**
```
GET https://www.googleapis.com/drive/v3/files/{id}?fields=modifiedTime
Authorization: Bearer {token}
```

Four types of HTTP calls. All use the same HTTP client with the same auth header. The JSON request bodies are constructed from Zig structs serialized with `std.json`.

---

## 7. Sync Engine

Direct port of `sync.py`. The sync loop runs in a daemon thread:

```
loop:
    if sheet_has_changed(drive API modifiedTime check):
        fetch Tests tab    → ingest test rows
        fetch User Needs tab → ingest UN rows, write status column
        fetch Requirements tab → ingest req rows, write status column, write row colors
        fetch Risks tab    → ingest risk rows, write status column
    sleep 30 seconds (with exponential backoff on failures)
```

### 7.1 Change Detection

Same two-stage approach as Python:

1. **File-level:** Call Drive API `files.get` for `modifiedTime`. Compare to last seen. If unchanged, skip the cycle. One cheap API call per cycle.
2. **Row-level:** Compute SHA-256 of `"|".join(cell_values)` for each row. Compare to `nodes.row_hash`. Only process changed rows.

### 7.2 Ingestion

Row parsing reuses `schema.zig`'s normalization (trimming, BOM stripping, smart quote replacement, ID normalization, section divider detection, numeric field parsing) but operates on `[][]const u8` rows from the Sheets API JSON response rather than from XLSX XML. A thin adapter converts Sheets API row data into the same format `schema.zig` expects.

Edge creation logic is identical to Python: `DERIVES_FROM` from Source column, `TESTED_BY` from Test Group ID column, `HAS_TEST` from Tests tab, `MITIGATED_BY` from Risks tab. Edges are idempotent. Node updates trigger suspect propagation.

### 7.3 Writeback

Status column and row colors are written back to the sheet on every sync cycle, same as Python. Status values: `OK`, `MISSING_USER_NEED`, `NO_TEST_LINKED`, `UNRESOLVED: xxx`, `MISSING ID`.

### 7.4 Error Handling

Hard errors (network failures, auth failures, API quota) are logged and trigger exponential backoff: 30s, 60s, 120s, capped at 5 minutes. The web UI shows the last sync timestamp and error state so the user knows if sync is stalled.

---

## 8. HTTP Server

### 8.1 Implementation

`std.http.Server` from Zig stdlib. Listens on `127.0.0.1:8000` (configurable via `--port`).

Request handling: read the request, match the path against a route table, dispatch to the handler function, write the response. No framework. The route table is a `switch` on the path string (or a small comptime-built hashmap).

### 8.2 Route Table

Direct port of every route from `backend.py`:

**Discovery / Schema:**
| Route | Method | Response |
|-------|--------|----------|
| `GET /schema` | — | Node types, edge semantics, propagation rules |
| `GET /nodes/types` | — | Distinct node types |
| `GET /edges/labels` | — | Distinct edge labels |

**Queries:**
| Route | Method | Response |
|-------|--------|----------|
| `GET /nodes?type=X` | — | All nodes, optionally filtered |
| `GET /query/node/{id}` | — | Single node with edges in/out |
| `GET /search?q=...` | — | Full-text search |
| `GET /query/gaps` | — | Untested requirements |
| `GET /query/rtm` | — | Full RTM as JSON |
| `GET /query/user-needs` | — | All UserNeed nodes |
| `GET /query/tests` | — | Tests with linked requirements |
| `GET /query/risks` | — | Risk register with scores |
| `GET /query/suspects` | — | All suspect nodes |
| `GET /query/impact/{id}` | — | Impact analysis for a node |

**Actions:**
| Route | Method | Response |
|-------|--------|----------|
| `POST /ingest` | JSON body | Add/update node or edge |
| `POST /suspect/{id}/clear` | — | Mark suspect as reviewed |

**Reports:**
| Route | Method | Response |
|-------|--------|----------|
| `GET /report/rtm` | — | PDF (inline) |
| `GET /report/rtm.md` | — | Markdown (download) |
| `GET /report/rtm.docx` | — | DOCX (download) |

**Config / Status:**
| Route | Method | Response |
|-------|--------|----------|
| `GET /api/status` | — | Sync state, service account email |
| `POST /api/service-account` | JSON body | Upload credentials |
| `POST /api/config` | JSON body | Set sheet URL, start sync |

**Static / UI:**
| Route | Method | Response |
|-------|--------|----------|
| `GET /` | — | `index.html` (embedded) |
| `GET /mcp` | — | MCP SSE endpoint |

### 8.3 JSON Serialization

All API responses are JSON. Use `std.json.stringifyAlloc` for serialization. Query results come from SQLite as rows; each row is converted to a struct, the struct is serialized. No Jinja2 templates — JSON endpoints return data, the web UI renders it.

### 8.4 Report Generation

PDF, Markdown, and DOCX reports reuse Trace's renderers (`render_pdf.zig`, `render_md.zig`, `render_docx.zig`). The data source changes: Trace passes an in-memory graph; Live passes query results from SQLite. The renderers accept the same data structures either way — the interface is a slice of RTM rows, a slice of risk rows, etc.

The Jinja2 HTML template (`rtm.html`) is not ported. The Python prototype used it for WeasyPrint PDF generation. The Zig port uses `render_pdf.zig` directly, which is already proven and produces better output (exact Helvetica metrics, proper page breaks).

---

## 9. Web UI

`index.html` ships as-is, embedded in the binary via `@embedFile("static/index.html")`. The HTTP server returns it for `GET /` with `Content-Type: text/html`.

The web UI is 46KB of vanilla HTML/CSS/JS with no build step, no framework, no npm. It calls the API endpoints (`/query/rtm`, `/query/gaps`, etc.) and renders tables, the node drawer, the impact analysis, the review queue. It works with the Python backend today. It will work with the Zig backend tomorrow because the API contract is identical.

Any future changes to the web UI are edits to `index.html` in the source tree. The binary is recompiled and the new UI is embedded. No deployment pipeline, no CDN, no static hosting.

If additional static files are needed later (CSS, JS, images), they're embedded the same way and served from a `/static/` route prefix.

---

## 10. MCP Server

### 10.1 Protocol

MCP uses Server-Sent Events (SSE) as its transport. The client (Claude Desktop, Claude Code, Cursor) connects to `http://127.0.0.1:8000/mcp` and holds open an HTTP connection. The server sends events as newline-delimited `data:` frames.

SSE in Zig: the HTTP server writes the response headers (`Content-Type: text/event-stream`, `Cache-Control: no-cache`, `Connection: keep-alive`), then writes `data: {json}\n\n` frames as they become available. The connection stays open. This is chunked transfer encoding with a specific content type.

### 10.2 Tool Exposure

The Python prototype uses `fastapi-mcp` which auto-generates MCP tool definitions from FastAPI route metadata. In Zig, the tool definitions are hand-written JSON that maps to the same API routes:

Each API endpoint becomes an MCP tool. The tool's `name` matches the route, the `description` comes from the docstring in `backend.py` (which was written specifically for MCP discoverability), and the `inputSchema` defines the parameters.

The MCP handler receives a JSON-RPC request, extracts the tool name and parameters, calls the same handler function the HTTP route would call, and returns the result as a JSON-RPC response over SSE.

### 10.3 Discovery

A connected agent should call `GET /schema` first (exposed as the `schema` MCP tool) to understand the data model, then `GET /nodes/types` to see what exists. This discovery pattern is documented in the README and in the tool descriptions.

---

## 11. First-Launch UX

On first launch with no configuration:

1. Binary starts, listens on `127.0.0.1:8000`
2. Opens the user's default browser to `http://127.0.0.1:8000`
3. The web UI shows the lobby screen (already implemented in `index.html`):
   - Drag-drop zone for `service-account.json`
   - Service account email display (once uploaded)
   - Sheet URL input field
   - "Connect" button
4. User uploads credentials → `POST /api/service-account` → stored in SQLite `credentials` table
5. User pastes sheet URL → `POST /api/config` → sheet ID extracted, sync thread starts
6. Lobby disappears, dashboard appears, data flows within 30 seconds

On subsequent launches:

1. Binary starts, reads `sheet_id` from SQLite `config` table, reads credentials from `credentials` table
2. Sync thread starts automatically
3. Browser opens to dashboard — data is already there from the SQLite graph

---

## 12. License Integration

Same as Trace. `rtmify_check_license()` at startup. If invalid, the web UI shows a license gate (text field + activate button) instead of the lobby/dashboard. Activation calls `rtmify_activate_license()`, caches at `~/.rtmify/license.json`, same path both products share.

A user who already activated Trace is already activated for Live if both products share the same LemonSqueezy product ID. If Live is a separate product (separate price tier), they need a separate license key. LemonSqueezy handles this: separate product, separate key, same activation flow.

---

## 13. CLI Interface

```
rtmify-live [options]

Options:
  --port <N>             Listen port (default: 8000)
  --db <path>            SQLite database path (default: ./graph.db)
  --no-browser           Don't open browser on startup
  --activate <key>       Activate license key
  --deactivate           Deactivate license
  --version              Print version and exit
  --help                 Print usage and exit
```

Minimal. The real configuration happens in the web UI (credentials upload, sheet URL). The CLI options are for power users who want to change the port or point at a different database.

---

## 14. System Tray / Menu Bar

A small platform-native indicator that Live is running:

**macOS:** Menu bar icon (NSStatusItem). Menu: "Open Dashboard" (opens browser), "Quit".
**Windows:** Notification area icon (Shell_NotifyIconW). Menu: "Open Dashboard", "Quit".

This is optional for v1. The binary can run in a terminal window with `Ctrl+C` to quit. The tray icon is polish for v1.1. It requires a small amount of platform-specific code (Objective-C calls on macOS, Win32 calls on Windows) but the Live binary already cross-compiles per-platform, so conditional compilation handles it.

---

## 15. Module Structure

```
src/
├── main_live.zig          ← Entry point: arg parse, license check, start server + sync
├── server.zig             ← HTTP server: listen, route dispatch, response writing
├── routes.zig             ← All API route handlers (port of backend.py endpoints)
├── mcp.zig                ← MCP/SSE endpoint: tool definitions, JSON-RPC dispatch
├── sync_live.zig          ← Sync loop thread: poll, diff, ingest, writeback
├── sheets.zig             ← Google Sheets API client: auth (JWT/RS256), read, write
├── db.zig                 ← SQLite wrapper: open, schema init, prepared statements
├── graph_live.zig         ← Graph operations on SQLite (port of graph.py)
│
├── schema.zig             ← [shared] Tab discovery, column mapping, normalization
├── diagnostic.zig         ← [shared] Warning/error infrastructure
├── render_md.zig          ← [shared] Markdown report
├── render_docx.zig        ← [shared] DOCX report
├── render_pdf.zig         ← [shared] PDF report
├── license.zig            ← [shared] LemonSqueezy license verification
│
└── static/
    └── index.html         ← [embedded] Web UI
```

Shared modules are identical between Trace and Live. They live in the same source tree and are imported by both `main.zig` (Trace) and `main_live.zig` (Live) via the `rtmify` module.

New modules for Live: 7 files. Estimated total: ~2,500-3,500 lines of new Zig.

---

## 16. Build Integration

Implemented in `sys/build.zig`:

```zig
// RTMify Live executable
const live_exe = b.addExecutable(.{
    .name = "rtmify-live",
    .root_module = b.createModule(.{
        .root_source_file = b.path("live/src/main_live.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rtmify", .module = lib_mod },
            .{ .name = "build_options", .module = opts_mod },
        },
    }),
});
// SQLite amalgamation
live_exe.addCSourceFile(.{
    .file = b.path("lib/vendor/sqlite3.c"),
    .flags = &.{ "-DSQLITE_THREADSAFE=2" },
});
live_exe.addIncludePath(b.path("lib/vendor/"));

const live_step = b.step("live", "Build rtmify-live");
live_step.dependOn(&b.addInstallArtifact(live_exe, .{}).step);
```

Both `zig build` (Trace+Live default install) and `zig build live` (Live-only step) run from the same `sys/build.zig`. The release step adds Live binaries alongside Trace binaries for all six targets.

---

## 17. Implementation Phases

### Phase 1: SQLite + Graph Layer (3-4 days)

- Vendor `sqlite3.c` amalgamation into `lib/vendor/`
- Implement `db.zig`: open, WAL pragma, schema init, exec, prepare, bind, step, column extraction
- Implement `graph_live.zig`: all operations from `graph.py` — `addNode`, `updateNode`, `upsertNode`, `addEdge`, `getNode`, `edgesFrom`, `edgesTo`, `nodesMissingEdge`, `rtm()`, `risks()`, `tests()`, `suspects()`, `impact()`, `_propagateSuspect()`, `clearSuspect()`, `allNodes`, `allNodeTypes`, `allEdgeLabels`, `search()`
- Port `store_credential`, `get_latest_credential`, `store_config`, `get_config`
- Tests: all graph operations against a real SQLite database in a temp directory

### Phase 2: Google Sheets API Client (3-4 days)

- Implement `sheets.zig`: PEM key parsing, JWT construction, RS256 signing, token exchange, token caching/refresh
- Implement Sheets API calls: read rows, batch update values, batch update formatting, Drive modifiedTime
- Test auth against a real Google Sheet with a service account
- This phase has the highest crypto complexity (RSA signing). May require a spike.

### Phase 3: Sync Engine (2-3 days)

- Implement `sync_live.zig`: port of `sync.py`
- Sync loop thread with exponential backoff
- Row hashing, change detection, ingestion calls to `graph_live.zig`
- Status writeback and row coloring via `sheets.zig`
- Reuse `schema.zig` normalization for row parsing
- Test: connect to a real sheet, verify nodes appear in SQLite, verify status column updates

### Phase 4: HTTP Server + API Routes (3-4 days)

- Implement `server.zig`: TCP listener, request parsing, route dispatch, response writing, static file serving
- Implement `routes.zig`: port all endpoints from `backend.py`
- Embed `index.html` via `@embedFile`
- Report endpoints call shared renderers
- Test: start server, hit all endpoints with `curl`, verify JSON matches Python output

### Phase 5: MCP Server (2-3 days)

- Implement `mcp.zig`: SSE transport, tool definitions, JSON-RPC request parsing, dispatch to route handlers
- Test: connect Claude Desktop to `127.0.0.1:8000/mcp`, verify tool discovery and query execution
- The MCP protocol spec is small. The tool definitions are a JSON structure mapping names to handlers. SSE is chunked HTTP with a specific content type.

### Phase 6: CLI + Integration + Polish (2-3 days)

- Implement `main_live.zig`: arg parsing, license check, server start, sync start, browser open
- Auto-open browser: `std.process.Child` calling `open` (macOS), `start` (Windows), `xdg-open` (Linux)
- Verify full flow: launch, lobby, upload credentials, connect sheet, dashboard populates, reports generate, MCP works
- Cross-compile for all six targets
- Smoke test on macOS and Windows (VM)

**Total estimated new Zig: 2,500-3,500 lines over 15-21 days of work.**

---

## 18. What This Is Not

- Not a cloud service. Runs on the user's machine. Data never touches a server you control.
- Not a multi-user server. One process, one sheet, one user (or one team sharing a sheet). No authentication on the HTTP server because it only listens on loopback (`127.0.0.1`). Cross-origin browser access is intentionally unsupported.
- Not a replacement for the web UI. The existing `index.html` ships unchanged. No redesign.
- Not a rewrite of the graph model. Same nodes, same edges, same queries, same schema. Different storage backend (SQLite instead of in-memory).
- Not an incremental migration. The Python prototype continues to exist for development and testing. The Zig binary is a clean-room reimplementation that produces identical API responses and identical reports.

---

## 19. Risk: RSA Signing

The single highest-risk item is Google service account authentication. The JWT must be signed with RS256, which requires parsing a PEM-encoded PKCS#8 RSA private key and performing RSA-PKCS1v15 signing with SHA-256.

Zig's stdlib includes TLS support (which includes RSA), but the public API for "sign this blob with this PEM key" may not be directly exposed in a convenient form. Options if the stdlib API is insufficient:

1. **Use Zig's TLS internals.** The TLS implementation parses PEM keys and performs RSA operations. The types may be accessible even if they're not part of the documented public surface.
2. **Vendor a minimal C RSA library.** BearSSL or a stripped-down subset of libcrypto. Zig compiles C natively, so adding a `.c` file is the same as the SQLite amalgamation.
3. **Shell out to `openssl` at runtime.** `echo $jwt | openssl dgst -sha256 -sign key.pem`. Pragmatic, works everywhere, adds a system dependency. Acceptable for a beta, not for shipping.

Spike this on day 1. If the stdlib path works, Phase 2 is 3 days. If it doesn't, budget 1-2 extra days for the BearSSL integration.
