# RTMify Live on Windows

This directory contains the native Windows tray shell for RTMify Live.

For the overall Live architecture, including the boundary between the native shell, the local `rtmify-live` process, and the browser dashboard, see [architecture.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md).

## Portable Bundle Layout

The supported v1 Windows distribution is a portable directory containing:

```text
RTMify Live/
├── RTMify Live.exe
├── rtmify-live.exe
```

`RTMify Live.exe` expects `rtmify-live.exe` to be present beside it.

## Runtime Paths

The Windows tray shell launches `rtmify-live.exe` with explicit per-user state paths:

- DB:
  - `%LOCALAPPDATA%\RTMify Live\graph.db`
- Logs:
  - `%LOCALAPPDATA%\RTMify Live\logs\server.log`

The tray shell does not rely on the current working directory for DB or logs.

## Build Commands

From `/Users/colinsteele/Projects/rtmify/sys`:

```sh
zig build win-gui-live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
zig build live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
zig build check-live-windows
```

On a native Windows host, also run:

```powershell
zig build test-live
```

## Behavior

When the user clicks `Start Server`:

1. the tray shell spawns `rtmify-live.exe`
2. it waits for `http://localhost:<port>/api/status` to become reachable
3. only then does it mark the server `Running`
4. then it opens the dashboard in the default browser

If startup fails, the tray shows a specific error message.

## Native Windows Smoke

On Windows, after building or unpacking a bundle, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\smoke.ps1
```

`smoke.ps1`:

- starts `rtmify-live.exe`
- waits for `/api/status`
- verifies the DB is created
- stops the process

## Known Limitations

- This is a portable bundle workflow only. Installer/signing work is out of scope here.
- The Windows tray shell does not yet have macOS-style crash restart supervision parity.
- Windows UI automation is not part of the current assurance lane.
