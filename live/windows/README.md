# RTMify Live on Windows

This directory contains the native Windows tray shell for RTMify Live.

For the overall Live architecture, including the boundary between the native shell, the local `rtmify-live` process, and the browser dashboard, see [architecture.md](/Users/colinsteele/Projects/rtmify/sys/live/docs/architecture.md).

## Installed Layout

The packaged Windows installer installs this application layout:

```text
RTMify Live/
├── RTMify Live.exe
├── rtmify-live.exe
```

`RTMify Live.exe` expects `rtmify-live.exe` to be present beside it. The release flow preserves that adjacency by staging both files into the Windows payload zip locally, then letting the `windows-installer-packaging.yml` workflow build the unsigned Inno installer on `windows-latest`, and finally signing the installer locally.

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

For operator/release builds, use:

```sh
cd /Users/colinsteele/Projects/rtmify/sys
./release.sh
```

That script resolves the signing key once, builds the native binaries and apps,
generates smoke licenses, and verifies those licenses against the binaries from
that same run before packaging artifacts. The Windows installer itself is not
built on macOS; it is built in GitHub Actions from the staged Windows payload
zip and then signed locally during the final `package.sh --windows-unsigned-dir`
step. See [release-operations.md](/Users/colinsteele/Projects/rtmify/sys/docs/release-operations.md).

On a native Windows host, also run:

```powershell
zig build test-live
```

## Behavior

When the user clicks `Start Server`:

1. the tray shell spawns `rtmify-live.exe`
2. it waits for `http://127.0.0.1:<port>/api/status` to become reachable
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

- The Windows tray shell does not yet have macOS-style crash restart supervision parity.
- Windows UI automation is not part of the current assurance lane.
