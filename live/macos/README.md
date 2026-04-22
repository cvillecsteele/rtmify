# RTMify Live — macOS App

Native SwiftUI menu-bar shell that bundles a `rtmify-live` binary, supervises it as a child process, and presents the dashboard at `http://127.0.0.1:<port>` in the user's default browser.

This README is the developer entrypoint for the macOS shell. For the cross-platform Live runtime (the actual server) see [/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md).

## What This Is

- a SwiftUI `MenuBarExtra` app — no main window, no Dock presence
- a thin process manager around a bundled `rtmify-live` binary built in ReleaseSafe
- a license gate that calls into `librtmify` via the bundled binary's `--license-status-json` and `license install` commands
- a crash supervisor that restarts the runtime with backoff (2s, 4s, 8s) up to 3 times
- a SMAppService-based "Launch at Login" toggle

## What It Does

- launches the bundled `rtmify-live` binary on app start
- watches the server process; restarts it if it dies unexpectedly
- exposes a menu-bar dropdown with start/stop, dashboard open, license import, launch-at-login, and quit
- reports last sync and last scan timestamps from `/api/status`
- opens the dashboard in the default browser when the server reaches `Running`
- captures the runtime's stdout/stderr into a ring buffer for diagnostics

## What It Does Not Do

- it is not the dashboard — that's served by the bundled `rtmify-live` and rendered in the browser
- it does not parse XLSX, render reports, or query the graph — all that lives in `librtmify`
- it does not own license verification — it only collects the file and asks the runtime to validate it
- it does not currently support multi-server / multi-port mode
- it does not run on macOS earlier than Ventura (13.0)

## First Day

```sh
cd /Users/colinsteele/Projects/rtmify/sys/live/macos

# Build everything: rtmify-live (ReleaseSafe) + bundle into the app
make app

# Output is here:
open .build/Build/Products/Release/RTMify\ Live.app
```

For development, open the project in Xcode after building the bundled binary at least once:

```sh
make bin                   # builds & embeds rtmify-live, no Xcode needed
open "RTMify Live.xcodeproj"   # then Cmd+R to run from Xcode
```

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Xcode | 16+ | App Store / developer.apple.com |
| Zig | 0.15.2 | `brew install zig` |
| Command Line Tools | any | `xcode-select --install` |
| HMAC signing key | 64 lowercase hex chars | see below |

The license HMAC signing key is required for the bundled `rtmify-live` to be built in ReleaseSafe (release builds refuse to compile without it). It is **not** stored in the repo.

Resolution order:

1. `make app LICENSE_HMAC_KEY_FILE=/abs/path/to/key.txt`
2. `RTMIFY_LICENSE_HMAC_KEY_FILE=/abs/path/to/key.txt` env var
3. `~/.rtmify/secrets/license-hmac-key.txt`

If you don't have the production key, `make bin RELEASE_VERSION=test-local` will still fail unless you point at a key file. For a debug build that doesn't need the real key, use `cd ../.. && zig build live -Doptimize=Debug` directly.

## Make Targets

| Target | What it does |
|---|---|
| `make bin` | Builds `rtmify-live` (ReleaseSafe, arm64) and copies it into `RTMify Live/Resources/rtmify-live` |
| `make app` | Runs `bin`, then `xcodebuild Release` to produce `.build/Build/Products/Release/RTMify Live.app` |
| `make clean` | Removes `.build/` and the embedded binary |

Variables:

- `LICENSE_HMAC_KEY_FILE=/path` — explicit signing key
- `RELEASE_VERSION=20260421-b` — override the version stamped into the binary

## Project Layout

```text
sys/live/macos/
├── Makefile                       — build orchestration
├── Package.swift                  — Swift package manifest
├── RTMify Live.xcodeproj/         — Xcode project (hand-maintained)
├── RTMify Live/
│   ├── App.swift                  — @main, MenuBarExtra scene, License window scene
│   ├── ViewModel.swift            — AppState machine, server lifecycle, license, restart logic
│   ├── MenuBarView.swift          — menu-bar dropdown UI
│   ├── LicenseGateView.swift      — license import dialog
│   ├── CrashSupervisor.swift      — restart-with-backoff policy
│   ├── OutputRingBuffer.swift     — captures runtime stdout/stderr
│   ├── PortSelection.swift        — port allocation (8000 + fallback)
│   ├── Info.plist                 — bundle ID io.rtmify.live, LSUIElement=true (no Dock)
│   ├── RTMify Live.entitlements   — sandboxing/network entitlements
│   ├── Assets.xcassets/           — icons
│   └── Resources/
│       └── rtmify-live            — bundled runtime binary (built by `make bin`, not committed)
└── Tests/
```

## Architecture

```text
┌────────────────────────────────────────────────────────┐
│              RTMify Live.app (MenuBarExtra)            │
│  ┌──────────────────────────────────────────────────┐  │
│  │              SwiftUI shell (~600 LOC)            │  │
│  │   App.swift / ViewModel.swift / MenuBarView      │  │
│  │   LicenseGateView / CrashSupervisor              │  │
│  └────────────────────┬─────────────────────────────┘  │
│                       │ spawns / supervises            │
│  ┌────────────────────▼─────────────────────────────┐  │
│  │     Resources/rtmify-live (Zig, ReleaseSafe)     │  │
│  │   HTTP server on 127.0.0.1:<port>                │  │
│  │   SQLite DB, sync, repo scan, MCP, etc.          │  │
│  └────────────────────┬─────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                        │ user clicks "Open Dashboard"
                        ▼
                Default browser → http://127.0.0.1:<port>
```

Boundary rules:

- **App.swift** owns the SwiftUI scene graph (menu-bar + license window only)
- **ViewModel.swift** owns the `AppState` enum and all process/license interactions
- **MenuBarView.swift** owns the dropdown UI and reads from `ViewModel`
- **LicenseGateView.swift** is opened as a separate window via `Window("License", id: "license")`
- **CrashSupervisor.swift** owns the restart policy; it does not know about UI
- **OutputRingBuffer.swift** owns stdout/stderr capture; bounded to prevent memory bloat
- The bundled `rtmify-live` is the only thing that touches SQLite, makes HTTP requests, parses XLSX, etc.

The Swift shell never reaches into `librtmify` directly — it only talks to the bundled binary via:

- spawning the process with port + DB path arguments
- polling `http://127.0.0.1:<port>/api/status` for liveness
- invoking `rtmify-live --license-status-json` and `rtmify-live license install <path>` for license operations

## Runtime Paths

The bundled `rtmify-live` is launched with explicit per-user state paths:

- DB: `~/Library/Application Support/RTMify Live/graph.db`
- Logs: `~/Library/Logs/RTMify Live/server.log`
- License: `~/.rtmify/license.json` (shared with the CLI)

The shell does not rely on the current working directory.

## Behavior

When the user launches the app:

1. The menu-bar icon appears (no Dock entry, `LSUIElement=true`)
2. The shell auto-spawns the bundled `rtmify-live`
3. It polls `/api/status` until the server responds
4. It opens the dashboard in the default browser
5. The menu-bar icon now reflects "Running" with the port

When `rtmify-live` dies unexpectedly:

- The crash supervisor schedules a restart at 2s, then 4s, then 8s
- After 3 failed attempts, the menu-bar shows "Error" and stops retrying
- A clean shutdown (Quit, or user clicks Stop) resets the retry counter

When no license is installed, the shell still launches the runtime in preview mode. The `MenuBarView` shows "Preview running" and the runtime keeps its existing preview-mode feature locks. Installing a valid license restarts the managed runtime.

## Common Change Recipes

### Add a menu-bar item

Touch:

- `MenuBarView.swift` — add the `Button(...)` or `Menu(...)` entry
- `ViewModel.swift` — if the action needs new state or a side effect

### Change the restart policy

Touch:

- `CrashSupervisor.swift` — adjust `RestartPolicy.delaysSeconds` or `maxRetries`
- `ViewModel.swift` — only if the policy needs new state surfaced to the UI

### Change the auto-launch port range

Touch:

- `PortSelection.swift` — `defaultPort` and `fallbackRange`

### Add a license-related UI element

Touch:

- `LicenseGateView.swift` for layout
- `ViewModel.swift` for the data path (calls `rtmify-live --license-status-json` or `license install`)
- never call `librtmify` C ABI directly from Swift on macOS — go through the runtime binary

### Bump the bundled runtime version

Pass it to make:

```sh
make app RELEASE_VERSION=20260421-b
```

For real releases, let `tools/publish.py release` handle versioning.

## Invariants And Safety Rules

These are the rules worth protecting:

- **the shell does not own license verification** — only the runtime does
- **the shell does not own state** — SQLite, sync, scans, all live in the runtime
- **the bundled `rtmify-live` must always be a ReleaseSafe build** — debug builds use a hardcoded HMAC key that production licenses won't validate against
- **stdout/stderr capture is bounded** — `OutputRingBuffer` caps memory; do not log unbounded streams
- **process supervision must distinguish intentional stop from crash** — `intentionalStopInProgress` guards against the supervisor restarting a quit
- **launch-at-login uses `SMAppService.mainApp`** — do not roll a `LaunchAgent` plist by hand
- **never block the main actor for runtime calls** — all `runCommand` calls are async
- **the menu-bar icon's state must reflect the actual server state** — if you add a new `AppState` case, every menu render path needs to handle it

## Troubleshooting

### `make bin` fails with `release builds require -Dlicense-hmac-key-file...`

You don't have a signing key. Either point at one explicitly:

```sh
make bin LICENSE_HMAC_KEY_FILE=/path/to/key.txt
```

Or set `RTMIFY_LICENSE_HMAC_KEY_FILE` in your environment, or create `~/.rtmify/secrets/license-hmac-key.txt`.

### Menu-bar icon doesn't appear

Check `Info.plist` has `LSUIElement = true`. Without it, macOS expects a Dock entry and may not show the menu-bar item correctly.

### "Open Dashboard" opens the wrong browser

The shell uses `NSWorkspace.shared.open(URL)`, which respects the system default browser. Change the default in System Settings → Desktop & Dock → Default web browser.

### Server keeps restarting

Check `~/Library/Logs/RTMify Live/server.log` for the runtime's startup error. The crash supervisor will give up after 3 attempts and surface the error in the menu bar.

### License import succeeds but the menu still says "Preview running"

The shell calls `rtmify-live license install` then re-fetches `/api/status`. If the runtime didn't pick up the new license, restart the app. Most often this is a fingerprint mismatch between the license file and the bundled binary's signing key — install a license generated against the same key.

### Xcode build fails with `librtmify`-related symbol errors

The macOS shell doesn't link `librtmify` directly — it spawns the bundled binary. If you see linker errors mentioning `librtmify`, you may have accidentally added the static library to the Xcode target. Remove it.

### `xcodebuild` succeeds but the `.app` won't launch

Check entitlements (`RTMify Live.entitlements`) — the sandboxed app needs `com.apple.security.network.server` to bind a loopback HTTP port and `com.apple.security.network.client` for the status probe.

## Current Status

Working today:

- menu-bar shell launches and supervises the bundled runtime
- license import and clear via SwiftUI dialog
- launch-at-login toggle via SMAppService
- crash restart with backoff (2s, 4s, 8s, then give up)
- preview mode allowed without a license
- dashboard auto-open on first start
- port fallback (8000 → 8001 → ... → 8010)

Still intentionally incomplete:

- no notification center integration for crash events
- no dock icon mode toggle (always menu-bar only)
- no in-app log viewer (logs live on disk; users open them via Finder)
- no auto-update mechanism (rely on installer + DMG re-download)
- no native dashboard preview window (always opens in browser)

## Related Docs

- Live runtime architecture: [/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md)
- Live MCP protocol: [/Users/colinsteele/Projects/rtmify/sys/live/docs/mcp.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/mcp.md)
- Live BOM/SOUP ingestion: [/Users/colinsteele/Projects/rtmify/sys/live/docs/bom_ingestion.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/bom_ingestion.md)
- Windows tray shell: [/Users/colinsteele/Projects/rtmify/sys/live/windows/README.md](/Users/colinsteele/Projects/rtmify/sys/live/windows/README.md)
- Release operations: [/Users/colinsteele/Projects/rtmify/sys/docs/release-operations.md](/Users/colinsteele/Projects/rtmify/sys/docs/release-operations.md)
