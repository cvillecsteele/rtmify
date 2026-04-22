# RTMify Live — Windows Shell

Native Win32 tray-icon shell that ships beside a `rtmify-live.exe` binary, supervises it as a child process, and presents the dashboard at `http://127.0.0.1:<port>` in the user's default browser.

This README is the developer entrypoint for the Windows shell. For the cross-platform Live runtime see [/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md).

## What This Is

- a hand-rolled Win32 tray app written in Zig (no .NET, no MFC, no DLLs beyond standard system libs)
- a thin process manager around a sibling `rtmify-live.exe` built in ReleaseSafe
- a license gate dialog (hand-rolled Win32 controls, file picker, status box)
- a single-instance guard (named mutex) — a second launch silently exits
- a Registry-based "Launch at Login" toggle (`HKCU\...\Run`)

## What It Does

- on launch: spawns `rtmify-live.exe` with explicit per-user DB and log paths, then opens the dashboard
- exposes a tray menu with start/stop, dashboard open, license import, launch-at-login, and quit
- polls `/api/status` until the server is ready (10s timeout, 250ms interval) before opening the dashboard
- waits for `/api/status` on a 5s timer to detect server crashes
- displays the license dialog on demand (file picker → status box → install/clear buttons)
- sets the console code page to UTF-8 at startup so log lines render correctly

## What It Does Not Do

- it is not the dashboard — that's served by the sibling `rtmify-live.exe` and rendered in the browser
- it does not parse XLSX, render reports, or query the graph
- it does not own license verification — it only collects the file and asks the runtime to validate it
- it does not yet have crash-restart-with-backoff parity with the macOS shell
- it does not run on Windows earlier than 10

## First Day

From `/Users/colinsteele/Projects/rtmify/sys`:

```sh
zig build live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
zig build win-gui-live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
zig build check-live-windows
```

Outputs in `zig-out/bin/`:

- `rtmify-live.exe` — the runtime
- `RTMify Live.exe` — the tray shell

For a debug build with symbols:

```sh
zig build live -Dtarget=x86_64-windows -Doptimize=Debug
zig build win-gui-live -Dtarget=x86_64-windows -Doptimize=Debug
```

To override the version string without editing any files:

```sh
zig build win-gui-live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Drelease-version=20260421-b
zig build live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Drelease-version=20260421-b
```

The version is stored in `build/options.zig` and is auto-bumped by `tools/publish.py release` — never edit that file manually.

## Building a Test Installer

The full installer is built by GitHub Actions using Inno Setup on a `windows-latest` runner. `tools/publish.py` handles orchestration. You do **not** need Azure signing credentials to get an installable `.exe` for testing — the CI step produces unsigned installers, and signing is a separate local finalize pass.

```sh
cd /Users/colinsteele/Projects/rtmify/sys
./tools/publish.py release --windows --skip-validation --skip-site --version 20260421-b
```

This will:

1. Build `rtmify-live.exe`, `RTMify Live.exe`, and `rtmify-trace.exe`
2. Stage and upload a signed Windows payload zip to a draft GitHub Release
3. Dispatch `windows-installer-packaging.yml` on a `windows-latest` runner
4. Download the unsigned `RTMify_Live_Installer_<version>_unsigned.exe`

The unsigned installer is sufficient for local testing. SmartScreen will warn on first run — right-click → Run anyway.

The signing step (Azure Trusted Signing via `jsign`) only matters for distribution. See [release-operations.md](/Users/colinsteele/Projects/rtmify/sys/docs/release-operations.md).

For operator/release builds, use `./release.sh` (called transitively by `publish.py`).

## Installed Layout

The packaged installer drops both files into one directory:

```text
RTMify Live/
├── RTMify Live.exe
└── rtmify-live.exe
```

`RTMify Live.exe` expects `rtmify-live.exe` to be present beside it. The release flow preserves that adjacency by staging both files into the Windows payload zip locally, then letting the `windows-installer-packaging.yml` workflow build the unsigned Inno installer on `windows-latest`, and finally signing the installer locally.

## Project Layout

```text
sys/live/windows/
├── src/
│   ├── main.zig              — wWinMain, WndProc, single-instance guard, tray icon, message loop
│   ├── tray_menu.zig         — popup menu construction (Start/Stop/License/etc.)
│   ├── lifecycle.zig         — server state machine (stopped/starting/running/error)
│   ├── process.zig           — CreateProcess wrapper, stdout/stderr capture, exe path resolution
│   ├── status_probe.zig      — HTTP GET to /api/status with timeout
│   ├── license_gate.zig      — hand-rolled Win32 license dialog, file picker, status box
│   └── state.zig             — ServerState enum, Config struct, error message buffer
├── res/
│   ├── rtmify_live.rc        — icon + version info + manifest reference
│   └── rtmify_live.manifest  — PerMonitorV2 DPI + Common Controls v6
├── smoke.ps1                 — native Windows smoke test
├── MANUAL_CHECKLIST.md       — manual smoke steps for clean-install verification
└── README.md
```

## Architecture

```text
┌─────────────────────────────────────────────────────────┐
│              RTMify Live.exe (tray)                     │
│  ┌──────────────────────────────────────────────────┐   │
│  │              Win32 shell (~700 LOC Zig)          │   │
│  │   main.zig (WndProc + message loop)              │   │
│  │   tray_menu.zig / license_gate.zig / lifecycle   │   │
│  └────────────────────┬─────────────────────────────┘   │
│                       │ CreateProcess                   │
│  ┌────────────────────▼─────────────────────────────┐   │
│  │     rtmify-live.exe (Zig, ReleaseSafe)           │   │
│  │   HTTP server on 127.0.0.1:<port>                │   │
│  │   SQLite DB, sync, repo scan, MCP, etc.          │   │
│  └────────────────────┬─────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
                        │ user clicks "Open Dashboard"
                        ▼
                Default browser → http://127.0.0.1:<port>
```

| Layer | Responsibility |
|---|---|
| `main.zig` | wWinMain entry, single-instance mutex, WndProc dispatch, tray icon lifecycle, server start/stop coordination, message loop |
| `tray_menu.zig` | popup menu construction, label text logic for licensed vs preview mode |
| `lifecycle.zig` | `ServerState` transitions (stopped → starting → running → error) |
| `process.zig` | `CreateProcessW` wrapper, log file open, exe directory resolution, child handle ownership |
| `status_probe.zig` | HTTP GET to `/api/status` with timeout (used during startup wait + periodic liveness check) |
| `license_gate.zig` | Win32 dialog with hand-rolled controls, `GetOpenFileNameW` file picker, license install/clear via FFI |
| `state.zig` | shared types: `ServerState`, `Config`, error buffer |

Boundary rules:

- **the shell does not parse XLSX, render reports, or query the graph** — those live in the sibling `rtmify-live.exe`
- **the shell never reaches into `librtmify` directly** — it spawns the runtime binary and talks to it via:
  - process spawn arguments (port, DB path, log path)
  - HTTP polling of `/api/status`
  - `rtmify-live.exe license install <path>` / `--license-status-json` for license operations
- **state transitions go through `lifecycle.handle*`** — do not mutate `ServerState` directly
- **all WndProc message handling lives in `main.zig`** — submodules expose pure functions, not message handlers

## Runtime Paths

The tray shell launches `rtmify-live.exe` with explicit per-user state paths:

- DB: `%LOCALAPPDATA%\RTMify Live\graph.db`
- Logs: `%LOCALAPPDATA%\RTMify Live\logs\server.log`
- License: `%USERPROFILE%\.rtmify\license.json` (shared with the CLI)

The shell does not rely on the current working directory.

## Behavior

When the user launches the app:

1. Single-instance mutex check (`Local\RTMifyLive-SingleInstance-{GUID}`) — second launch silently exits
2. UTF-8 console code page set via `SetConsoleOutputCP(65001)`
3. Tray icon registered with `Shell_NotifyIcon(NIM_ADD)`
4. `startServer()` auto-spawns `rtmify-live.exe`
5. A worker thread polls `/api/status` until ready (250ms intervals, 10s timeout)
6. On ready: tray state → "Running", dashboard opens via `ShellExecuteW`
7. A 5s timer polls process liveness; if the server dies, tray shows "Error"

When the user clicks **Start Server / Start Preview** from the tray menu (after a stop):

- Same flow as auto-start, with the menu re-rendered to show "Stop" + "Open Dashboard"

When no license is installed, the shell still launches the runtime in preview mode. The tray menu's status line shows "Preview running" and the runtime keeps its existing preview-mode feature locks. Installing a valid license via the dialog stops and restarts the runtime.

## Tray Menu

Right-click (or two-finger tap on a trackpad) the tray icon to open the menu:

| State | Menu items |
|---|---|
| Stopped | Status line · Start Server / Start Preview · Install License File... · Launch at Login · Quit |
| Starting | Status line · "Starting..." (grayed) · Install License File... · Launch at Login · Quit |
| Running | Status line · Open Dashboard · Stop Server · Manage License... · Launch at Login · Quit |
| Error | "Error: <message>" · Start Server · Install License File... · Launch at Login · Quit |

The tray icon may end up in the **overflow area** by default on Windows 11. To pin it: Settings → Personalization → Taskbar → Other system tray icons → toggle RTMify Live on. Drag-from-overflow was removed in Windows 11.

## Console Output

`rtmify-live.exe` calls `SetConsoleOutputCP(65001)` at startup to set the console to UTF-8. This ensures log lines with em-dashes and other non-ASCII characters render correctly in PowerShell and Windows Terminal. Legacy `cmd.exe` may still need `chcp 65001` run manually beforehand.

## Common Change Recipes

### Add a tray menu item

Touch:

- `tray_menu.zig` — add a `CMD_*` constant + `AppendMenuW` call in `showMenu`
- `main.zig` — add a case in `handleMenuCmd` for the new command
- if the action needs new state, add it to `state.zig` and update `lifecycle.zig` transitions

### Change the startup timeout or poll interval

Touch:

- `main.zig` — `STARTUP_TIMEOUT_MS` and `STARTUP_INTERVAL_MS` constants

### Change the periodic liveness check interval

Touch:

- `main.zig` — `TIMER_INTERVAL_MS` constant (currently 5s)

### Add a license-related UI element

Touch:

- `license_gate.zig` — add the control via `CreateWindowExW`, handle its `WM_COMMAND` ID
- never call `librtmify` C ABI directly from the shell — go through `rtmify-live.exe license ...` subcommands

### Add a server lifecycle state

Touch:

- `state.zig` — add the new variant to `ServerState`
- `lifecycle.zig` — add transition handlers (`handleStart`, `handleStarted`, etc.)
- `tray_menu.zig` — add the menu rendering branch in `showMenu`
- `main.zig` — handle the state in `WM_TIMER` and `WM_STARTUP_COMPLETE`

### Override the version string for a test build

```sh
zig build win-gui-live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Drelease-version=20260421-b
```

For real releases, let `tools/publish.py release` handle versioning.

## Invariants And Safety Rules

These are the rules worth protecting:

- **the shell does not own license verification** — only the runtime does
- **the shell does not own state** — SQLite, sync, scans, all live in the runtime
- **the bundled `rtmify-live.exe` must always be a ReleaseSafe build for distribution** — debug builds use a hardcoded HMAC key that production licenses won't validate against
- **single-instance enforcement uses a Local\\ named mutex** — never use a Global\\ mutex (that would block other users on the same machine)
- **server process lifetime is owned by the shell** — startup_seq atomic guards against late completion of cancelled startups
- **WndProc must return promptly** — long-running work (server start, status poll) goes on a worker thread with `PostMessage`-back to the UI thread
- **never block the message loop** — modal `MessageBoxW` is OK for fatal errors only
- **registry "Launch at Login" lives in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`** — do not use the per-machine `HKLM` variant
- **error messages are bounded** — the `server_error` buffer in `Config` is 256 bytes; truncate, don't allocate

## Native Windows Smoke

After building or unpacking a bundle on a Windows machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\smoke.ps1
```

`smoke.ps1`:

- starts `rtmify-live.exe`
- waits for `/api/status`
- verifies the DB is created
- stops the process

For a thorough manual check before distribution, see `MANUAL_CHECKLIST.md`.

## Troubleshooting

### Tray icon doesn't appear

It's almost certainly in the **overflow area**. Click the `^` caret at the left edge of the system tray. Pin it via Settings → Personalization → Taskbar → Other system tray icons.

### Log lines show `ΓÇö` instead of `—`

The console code page isn't UTF-8. `rtmify-live.exe` sets it on startup, but legacy `cmd.exe` may need `chcp 65001` run manually before launching the binary directly. PowerShell and Windows Terminal handle this correctly.

### Two processes appear in Task Manager

The single-instance guard uses a named mutex (`Local\RTMifyLive-SingleInstance-{GUID}`). If you're seeing duplicates, the mutex name may have changed between builds without a clean shutdown — kill all processes and relaunch.

### Server starts but dashboard doesn't open

Check the default browser association in Windows Settings → Apps → Default apps → Web browser. The shell uses `ShellExecuteW(hwnd, "open", "http://127.0.0.1:<port>", ...)`.

### "Server did not become ready within 10s"

The runtime is taking longer than expected to bind the port. Check `%LOCALAPPDATA%\RTMify Live\logs\server.log` for the actual startup error — usually port conflict, missing DB directory permissions, or schema migration issue.

### "Server binary not found beside RTMify Live.exe"

`rtmify-live.exe` must be in the same directory as `RTMify Live.exe`. The installer guarantees this — if you're testing a manually-staged build, copy both binaries side-by-side.

### License import succeeds but tray still says "Preview running"

The shell calls `rtmify-live.exe license install <path>` and then restarts the runtime. If it still shows preview, the license likely has a fingerprint mismatch with the bundled binary's signing key. The license dialog's status box should show the specific error — install a license generated against the same key.

### `addWin32ResourceFile` not found at build time

This API was added in Zig 0.12. Verify Zig 0.15.2 is on PATH.

### `.exe` won't launch on Windows ("missing DLL")

Run `dumpbin /dependents "RTMify Live.exe"` on Windows. Expected dependencies only: `KERNEL32.dll`, `USER32.dll`, `SHELL32.dll`, `GDI32.dll`, `COMDLG32.dll`, `ADVAPI32.dll`, `OLE32.dll`. Anything else is a build configuration bug.

## Current Status

Working today:

- tray shell launches and supervises the bundled runtime
- single-instance guard via named mutex
- auto-start of runtime on shell launch (added 2026-04-21)
- license import and clear via Win32 dialog
- launch-at-login via Registry `HKCU\Run` key
- preview mode allowed without a license
- dashboard auto-open on first start
- 5s periodic liveness check
- UTF-8 console output

Still intentionally incomplete:

- no crash-restart-with-backoff parity with the macOS shell (Known Limitation: tray reports error after one death, no auto-retry)
- no Windows UI automation in the assurance lane
- no in-app log viewer
- no notification center integration for crash events
- ARM64 Windows tray shell builds but is not regularly smoked

## Related Docs

- Live runtime architecture: [/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md)
- Live MCP protocol: [/Users/colinsteele/Projects/rtmify/sys/live/docs/mcp.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/mcp.md)
- macOS menu-bar shell: [/Users/colinsteele/Projects/rtmify/sys/live/macos/README.md](/Users/colinsteele/Projects/rtmify/sys/live/macos/README.md)
- Manual smoke checklist: [/Users/colinsteele/Projects/rtmify/sys/live/windows/MANUAL_CHECKLIST.md](/Users/colinsteele/Projects/rtmify/sys/live/windows/MANUAL_CHECKLIST.md)
- Release operations: [/Users/colinsteele/Projects/rtmify/sys/docs/release-operations.md](/Users/colinsteele/Projects/rtmify/sys/docs/release-operations.md)
