# RTMify Live Architecture

This document describes the current developer-facing architecture of RTMify Live as implemented in the Zig codebase.

The key UX model is:

- a native shell for OS integration
- a local application server for state and business logic
- an embedded web UI served from that local server

RTMify Live is not a traditional native desktop app with native controls for the full product surface, and it is not a remote web app backed by a hosted service. It is a local-first application whose primary user interface is a browser UI delivered by a local Zig process.

The HTTP surface is intentionally loopback-only. `rtmify-live` binds `127.0.0.1`, opens the browser against that loopback origin, and does not support CORS or remote multi-user access.

## Core Pattern

RTMify Live uses a `native shim + embedded webserver + browser UI` architecture.

There are three layers:

1. Native shell
2. Local application runtime
3. Browser UI

These layers have distinct responsibilities.

## 1. Native Shell

The native shell exists to do the small set of things that want platform APIs:

- tray or menu-bar presence
- start and stop lifecycle
- launch at login
- opening the dashboard in the default browser
- process supervision for the local server
- platform-specific packaging behavior

On Windows, this shell is implemented in:

- [main.zig](/Users/colinsteele/Projects/rtmify/sys/live/windows/src/main.zig)
- [process.zig](/Users/colinsteele/Projects/rtmify/sys/live/windows/src/process.zig)
- [tray_menu.zig](/Users/colinsteele/Projects/rtmify/sys/live/windows/src/tray_menu.zig)
- [lifecycle.zig](/Users/colinsteele/Projects/rtmify/sys/live/windows/src/lifecycle.zig)

The shell is intentionally thin. It does not own the dashboard, graph queries, reports, sync logic, or MCP behavior. Its job is to start the real application process, observe its state, and make that process feel native on the host OS.

## 2. Local Application Runtime

The real application runtime is `rtmify-live`.

It is implemented primarily in:

- [main_live.zig](/Users/colinsteele/Projects/rtmify/sys/live/src/main_live.zig)
- [server.zig](/Users/colinsteele/Projects/rtmify/sys/live/src/server.zig)
- [routes.zig](/Users/colinsteele/Projects/rtmify/sys/live/src/routes.zig)

This process owns:

- SQLite persistence
- in-process configuration storage
- the graph model and query surface
- background sync threads
- repo scanning threads
- diagnostics and gap analysis
- report generation
- MCP endpoints
- serving the embedded dashboard

This is the architectural center of the product. The browser UI and native shell are both clients of this local process.

## 3. Browser UI

The operator-facing product surface is the embedded web UI in:

- [index.html](/Users/colinsteele/Projects/rtmify/sys/live/src/static/index.html)

That UI is compiled into the binary and served from memory via:

- [routes.zig](/Users/colinsteele/Projects/rtmify/sys/live/src/routes.zig)

using:

- `pub const index_html = @embedFile("static/index.html");`

The browser UI handles:

- navigation
- data tables and drill-downs
- operator workflows
- guide content
- reports/download triggers
- MCP help and examples
- dashboard state transitions

It talks to the local runtime over same-origin HTTP requests to endpoints such as:

- `/api/status`
- `/api/info`
- `/query/rtm`
- `/query/chain-gaps`
- `/api/guide/errors`
- `/report/rtm`
- `/report/dhr/md`
- `/mcp`

The frontend is therefore not a separate deployment unit. It is part of the application binary.

## Runtime Topology

At runtime, the shape is:

```text
Native shell (optional, platform-specific)
        |
        | starts / supervises
        v
  rtmify-live local process
        |
        | serves HTTP on 127.0.0.1
        v
 Default browser renders embedded dashboard UI
```

Or, when no native shell is used:

```text
User launches rtmify-live directly
        |
        v
  rtmify-live local process
        |
        | optionally opens browser
        v
 Default browser renders embedded dashboard UI
```

## Why This Split Exists

This split is deliberate.

The product needs native integration for a few reasons:

- packaged desktop distribution
- tray presence
- login/startup behavior
- process lifecycle control

But most of the UX surface changes frequently and benefits from a web UI:

- tabs and dashboard layout
- rich drill-down behavior
- report and guide pages
- fast iteration without building a native widget hierarchy for every screen

The architecture keeps native code focused on things that are truly native concerns, while allowing the application UX to be built as a local web app.

## Boundary Rules

Developers should treat the layer boundaries this way.

### Native shell responsibilities

- start and stop `rtmify-live`
- know where logs and DB live for that platform
- reflect runtime state in tray/menu UI
- open `http://127.0.0.1:<port>`

### Local runtime responsibilities

- own all durable state
- own all API contracts
- own report rendering
- own sync logic and graph mutation
- expose MCP and dashboard data

### Browser UI responsibilities

- present runtime state
- call backend routes
- manage tabs, drawers, and client-side interaction state
- avoid embedding business logic that belongs in the runtime

If a feature needs durable state, graph mutation, sync semantics, or report correctness, it belongs in the runtime, not in the native shell or browser-only code.

## Startup Flow

The common startup path is:

1. A user launches either `rtmify-live` directly or a native shell.
2. The native shell, if present, starts `rtmify-live`.
3. `rtmify-live` opens the SQLite DB, loads config, and starts background workers.
4. `rtmify-live` binds an HTTP port on loopback (`127.0.0.1`).
5. The browser opens to `http://127.0.0.1:<port>`.
6. The embedded web UI loads and hydrates itself by calling local JSON routes.

On Windows, the tray shell waits for `/api/status` before marking the server as running and opening the dashboard.

## Developer Implications

For implementation work:

- route and report changes usually belong in `sys/live/src`
- dashboard UX changes usually belong in `sys/live/src/static/index.html`
- tray, startup, and packaging behavior belong in platform-native shell code

For debugging:

- if the UI looks wrong but the data is correct, start with `index.html`
- if the UI is missing data, start with `routes.zig` and the backend query/build path
- if launch, tray state, or browser opening is wrong, start with the native shell

## Related Docs

- [prd.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/prd.md)
- [mcp.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/mcp.md)
- [Windows README](/Users/colinsteele/Projects/rtmify/sys/live/windows/README.md)
