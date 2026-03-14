# RTMify Trace — macOS App

Native SwiftUI application that wraps `librtmify.a` in a drag-and-drop GUI. All XLSX parsing, graph construction, gap detection, and report rendering happen in the Zig library. Swift handles the window, file drops, signed-license import, and progress display.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Xcode | 16+ (26.0 tested) | App Store / developer.apple.com |
| Zig | 0.15.2 | `brew install zig` or ziglang.org |
| Command Line Tools | any | `xcode-select --install` |

---

## Quick Start

```sh
# 1. Build librtmify.a (arm64, ~9.7 MB)
cd sys/trace/macos
make lib

# 2. Open in Xcode
open "RTMify Trace.xcodeproj"
# Cmd+B to build, Cmd+R to run
```

Or build entirely from the command line:

```sh
make build   # runs make lib then xcodebuild Release
```

For release packaging, prefer:

```sh
cd /Users/colinsteele/Projects/rtmify/sys
./release.sh
```

That script resolves the signing key once and smoke-verifies generated
licenses against the built Trace and Live binaries before packaging artifacts.

---

## Make Targets

| Target | What it does |
|---|---|
| `make lib` | Builds `lib/librtmify.a` (arm64, ReleaseSafe) |
| `make build` | Builds `lib/librtmify.a` then `xcodebuild Release` |
| `make build-universal` | lipo arm64 + x64 → universal `lib/librtmify.a` |
| `make clean` | Removes `lib/` and `.build/` |

`lib/librtmify.a` is not committed — always build it from source first.

Signing key resolution order for release builds:

1. `LICENSE_HMAC_KEY_FILE=/path/to/key.txt`
2. `RTMIFY_LICENSE_HMAC_KEY_FILE`
3. `~/.rtmify/secrets/license-hmac-key.txt`

---

## Development Workflow

### First time

```sh
cd sys/trace/macos
make lib
open "RTMify Trace.xcodeproj"
```

### After changing Zig source

```sh
cd sys
zig build test-lib --summary all
zig build lib -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
cp zig-out/lib/librtmify.a trace/macos/lib/librtmify.a
```

Then Cmd+B in Xcode (or `make build`).

### After changing Swift source only

Just Cmd+B in Xcode — no library rebuild needed.

---

## Licensing

The app accepts signed offline license files.

- Manual install path: `~/.rtmify/license.json`
- In-app flow: import a `license.json` file from the license gate

Trace also allows one full free run. After one successful report generation,
future runs require a valid signed license file unless the marker file is
removed:

```sh
rm ~/.rtmify/.trace-used
```

To remove an installed license file from within the app: **RTMify Trace menu → Clear Installed License...**

---

## Project Layout

```text
sys/trace/macos/
├── Makefile
├── RTMify Trace.xcodeproj/
│   └── project.pbxproj          ← hand-generated; edit here for build settings
├── RTMify Trace/
│   ├── App.swift                 ← @main, Window scene, clear-license menu
│   ├── ContentView.swift         ← state switcher + error alert
│   ├── ViewModel.swift           ← AppState machine, all async C calls
│   ├── RTMifyBridge.swift        ← async Swift wrappers over C ABI
│   ├── LicenseGateView.swift     ← signed-license import gate
│   ├── DropZoneView.swift        ← drag-and-drop zone, file summary, format picker
│   ├── DoneView.swift            ← results, Show in Finder, Generate Another
│   ├── rtmify-bridge.h           ← C ABI declarations (bridging header)
│   ├── Info.plist                ← bundle ID io.rtmify.trace, macOS 13+
│   └── Assets.xcassets/          ← placeholder app icon
├── lib/
│   └── librtmify.a               ← built by `make lib`; not committed
└── docs/
    └── prd.md                    ← product requirements document
```

---

## Architecture

```
┌─────────────────────────────────────┐
│           RTMify Trace.app          │
│  ┌─────────────────────────────┐   │
│  │         SwiftUI (~400 LOC)  │   │
│  │  App / ContentView          │   │
│  │  ViewModel (AppState)       │   │
│  │  LicenseGateView            │   │
│  │  DropZoneView               │   │
│  │  DoneView                   │   │
│  └────────────┬────────────────┘   │
│               │ rtmify-bridge.h    │
│  ┌────────────▼────────────────┐   │
│  │      librtmify.a (Zig)      │   │
│  │  XLSX parsing (7 layers)    │   │
│  │  Graph construction         │   │
│  │  Gap detection              │   │
│  │  PDF / DOCX / MD rendering  │   │
│  │  Signed license files       │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

**C ABI surface** (all 9 functions in `rtmify-bridge.h`):

```c
rtmify_load()              // parse XLSX → opaque graph handle
rtmify_generate()          // graph + format + path → output file
rtmify_gap_count()         // number of traceability gaps
rtmify_warning_count()     // number of validation warnings
rtmify_last_error()        // human-readable error from last failure
rtmify_free()              // release graph handle
rtmify_trace_license_get_status()            // Trace status + free-run policy
rtmify_trace_license_install()               // install signed license file
rtmify_trace_license_clear()                 // remove installed license file
rtmify_trace_license_record_successful_use() // consume Trace free run
```

---

## Build Settings (key ones)

| Setting | Value | Why |
|---|---|---|
| `SWIFT_OBJC_BRIDGING_HEADER` | `RTMify Trace/rtmify-bridge.h` | Exposes C ABI to Swift |
| `LIBRARY_SEARCH_PATHS` | `$(SRCROOT)/lib` | Finds `librtmify.a` |
| `OTHER_LINKER_FLAGS` | `-lrtmify` | Links the static library |
| `MACOSX_DEPLOYMENT_TARGET` | `13.0` | Ventura minimum |
| `SWIFT_VERSION` | `5.9` | |
| `CODE_SIGN_IDENTITY` | `-` | Ad-hoc signing (no Apple account needed) |
| `ENABLE_HARDENED_RUNTIME` | `NO` | Simplified local dev |

To change any of these, edit `RTMify Trace.xcodeproj/project.pbxproj` directly or open the project in Xcode → target → Build Settings.

---

## Troubleshooting

### `make lib` fails
```
zig: command not found
```
Install Zig 0.15.2: `brew install zig` or download from [ziglang.org](https://ziglang.org/download/).

---

### `Undefined symbols: ___divtf3` (linker error)
The library was built without bundling Zig's compiler-rt. Ensure `static_lib.bundle_compiler_rt = true;` is present in `sys/build.zig`:
```zig
static_lib.bundle_compiler_rt = true;
```
Then `make lib` again.

---

### `Cannot link directly with SwiftUICore` (linker warning → error)
Seen on some Xcode/SDK combinations. Usually caused by incorrect code signing settings. Verify `CODE_SIGN_IDENTITY = "-"` and `CODE_SIGN_STYLE = Manual` in the project.

---

### App still shows the license gate after importing a valid file
Verify the library was rebuilt after the last change to `license.zig`, then
check that the imported `license.json` is for product `trace` and has not
expired or been tampered with.

---

### Drop zone rejects a valid XLSX
The drop handler checks UTType `org.openxmlformats.spreadsheetml.sheet` first, then falls back to path extension. If macOS hasn't registered the UTType, the extension check should catch it. If neither works, verify the file is a true XLSX (ZIP-based) and not an XLS renamed to `.xlsx`.

---

## Release Build (Universal Binary)

```sh
# Build universal librtmify.a (arm64 + x86_64)
make build-universal

# Build the app against it
xcodebuild -project "RTMify Trace.xcodeproj" \
           -scheme "RTMify Trace" \
           -configuration Release \
           -derivedDataPath .build
```

The resulting `.app` is at `.build/Build/Products/Release/RTMify Trace.app`.

For a distributable DMG, use [create-dmg](https://github.com/create-dmg/create-dmg) or Packages.app — not yet automated in the Makefile.
