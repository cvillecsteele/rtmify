# RTMify Trace — Windows Shell

Native Win32 GUI for RTMify Trace. Single self-contained `.exe` — no installer, no DLLs.

## Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) on PATH (cross-compile from macOS or Linux)
- The monorepo Zig build root at `sys/`

## Quick Start

```sh
cd sys/trace/windows
make build           # x86_64-windows (most common)
make build-arm64     # aarch64-windows (Surface Pro X, Copilot+ PCs)
```

Output: `../../zig-out/bin/rtmify-trace.exe`

## Make Targets

| Target | Description |
|--------|-------------|
| `make build` | x86_64 Windows, ReleaseSafe |
| `make build-arm64` | ARM64 Windows, ReleaseSafe |
| `make clean` | Remove build artifacts |

## Manual Build

```sh
cd sys
zig build win-gui -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

For operator/release packaging, use:

```sh
cd /Users/colinsteele/Projects/rtmify/sys
./release.sh
```

## Development Licensing

Release and operator flows resolve the signing key in this order:

1. `--key-file /path/to/key.txt`
2. `RTMIFY_LICENSE_HMAC_KEY_FILE`
3. `~/.rtmify/secrets/license-hmac-key.txt`

Debug builds can still use the deterministic development HMAC key, but
`rtmify-license-gen` now requires an explicit key path unless `--allow-dev-key`
is passed. For local debug-only work:

```sh
cd sys
zig build license-gen
./zig-out/bin/rtmify-license-gen \
  --allow-dev-key \
  --product trace \
  --tier individual \
  --to dev@example.com \
  --org "Local Dev" \
  --perpetual \
  --out /tmp/trace-license.json
```

Then either:
- import `/tmp/trace-license.json` in the app
- or copy it to `~/.rtmify/license.json`

## Project Layout

```text
sys/trace/windows/
├── src/
│   ├── main.zig      — wWinMain entry point, WndProc, global state
│   ├── ui.zig        — control creation, visibility, WM_PAINT drawing
│   ├── bridge.zig    — librtmify C ABI declarations, worker thread spawners
│   ├── state.zig     — AppState machine, FileSummary, output path logic
│   ├── drop.zig      — WM_DROPFILES handler, UTF-16→UTF-8, extension check
│   └── dialogs.zig   — GetOpenFileNameW browse dialog, MessageBoxW error helper
├── res/
│   ├── rtmify.rc     — icon + version info + manifest reference
│   ├── rtmify.manifest — PerMonitorV2 DPI + Common Controls v6
│   └── rtmify.ico    — application icon (replace before distribution)
├── Makefile
└── README.md
```

## Architecture

| Layer | Responsibility |
|-------|---------------|
| `main.zig` | Win32 message loop, WndProc dispatch, state transitions |
| `ui.zig` | Control layout, DPI scaling, WM_PAINT custom drawing |
| `bridge.zig` | C ABI extern declarations, worker thread lifecycle |
| `state.zig` | App state machine, output path/project name derivation |
| `drop.zig` | WM_DROPFILES handling, file extension validation |
| `dialogs.zig` | File open dialog, error message boxes |
| `librtmify.a` | All XLSX parsing, graph analysis, report rendering |

## 3-State UX

```
Launch
  │
  ├─ License missing → [License Gate]
  │     Import signed license file → [Drop Zone]
  │
  └─ License OK → [Drop Zone]
        Drop .xlsx or Browse → Load (worker) → [File Loaded]
        Generate → render (worker) → [Done]
        Show in Explorer / Open / Generate Another
```

## Troubleshooting

**Linking errors about `___divtf3` or similar:** Ensure `static_lib.bundle_compiler_rt = true` in `sys/build.zig`. This bundles f128 builtins used internally by Zig's JSON parser (for license checks).

**Window appears tiny on 4K display:** Verify the manifest is embedded correctly — the `PerMonitorV2` dpiAwareness entry is required. Without it, Windows scales the window as a bitmap.

**`addWin32ResourceFile` not found:** This API was added in Zig 0.12. If using an older build, remove the RC step and embed the manifest via linker flags instead.

**`.exe` won't launch (missing DLL):** Run `dumpbin /dependents rtmify-trace.exe` on Windows. Expected dependencies: KERNEL32.dll, USER32.dll, SHELL32.dll, GDI32.dll, COMDLG32.dll only.
