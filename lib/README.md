# rtmify-trace

A local, offline CLI that reads an RTMify XLSX spreadsheet and generates a
Requirements Traceability Matrix as PDF, Markdown, or Word (DOCX). No cloud.
No runtime dependencies. Single binary per platform.

## Quick start

```sh
cd sys
zig build trace                   # build trace CLI
zig-out/bin/rtmify-trace --help
```

## Usage

```
rtmify-trace <input.xlsx> [options]

Options:
  --format <md|docx|pdf|all>  Output format (default: docx)
  --output <path>             Output file or directory (default: same dir as input)
  --project <name>            Project name for report header (default: filename)
  --activate <key>            Activate license key for this machine
  --deactivate                Deactivate license on this machine
  --gaps-json <path>          Write diagnostics and gap list as JSON
  --strict                    Exit with gap count when gaps are found (for CI)
  --version                   Print version and exit
  --help                      Print this help and exit

Exit codes:
  0   success
  1   input file error (not found, not XLSX, missing required tabs)
  2   license error (not activated, expired, revoked)
  3   output error (cannot write destination)
  N   gap count (with --strict only)
```

### Examples

```sh
rtmify-trace requirements.xlsx
rtmify-trace requirements.xlsx --format all --output ./reports/
rtmify-trace requirements.xlsx --format md --project "Ventilator v2.1"
rtmify-trace --activate XXXX-XXXX-XXXX-XXXX
```

## Building

Requires [Zig 0.15.2](https://ziglang.org/download/).

```sh
cd sys
zig build                        # native trace + live + librtmify
zig build trace -Doptimize=ReleaseSafe
zig build lib -Doptimize=ReleaseSafe
zig build test-lib               # librtmify unit tests
zig build release                # cross-compile trace + live + static libs
zig build run-trace -- requirements.xlsx --format pdf
```

### Cross-compilation

`zig build release` cross-compiles for all six targets in one command, from any
host platform (macOS, Linux, or Windows). No cross-toolchains, SDKs, or Docker
required — Zig bundles everything it needs.

`zig build release` produces binaries and static libraries in `zig-out/release/`:

| File | Platform |
|---|---|
| `rtmify-trace-macos-arm64` | macOS Apple Silicon |
| `rtmify-trace-macos-x64` | macOS Intel |
| `rtmify-trace-windows-x64.exe` | Windows x64 |
| `rtmify-trace-windows-arm64.exe` | Windows ARM64 |
| `rtmify-trace-linux-x64` | Linux x64 (musl, fully static) |
| `rtmify-trace-linux-arm64` | Linux ARM64 (musl, fully static) |

Linux binaries link musl libc statically — no glibc version dependency.

## Input format

The input must be an XLSX file with four tabs:

| Tab | Key columns |
|---|---|
| **User Needs** | ID, Statement, Source, Priority |
| **Requirements** | ID, Statement, Source (→ User Need), Test Group IDs, Status |
| **Tests** | Test Group ID, Test ID, Type, Method |
| **Risks** | ID, Description, Severity, Likelihood, Mitigation, Linked Req |

Column order does not matter — headers are matched by name (case-insensitive).
Blank rows and extra columns are ignored. Missing optional columns are treated
as empty.

## License activation

The tool requires a LemonSqueezy license key on first run:

```sh
rtmify-trace --activate XXXX-XXXX-XXXX-XXXX
```

This validates the key online and writes a cache to `~/.rtmify/license.json`.
The license is bound to the activating machine via a hardware fingerprint.
Subsequent runs are offline. The tool silently re-validates with LemonSqueezy
every 7 days; if the server is unreachable, a 30-day offline grace period
applies before the license is considered lapsed.

## C ABI

`librtmify` exports a C-callable surface for native GUI shells:

```c
RtmifyStatus rtmify_load(const char* xlsx_path, RtmifyGraph** out_graph);
RtmifyStatus rtmify_generate(const RtmifyGraph*, const char* format,
                              const char* output_path, const char* project_name);
int          rtmify_gap_count(const RtmifyGraph*);
const char*  rtmify_last_error(void);
int          rtmify_warning_count(void);
void         rtmify_free(RtmifyGraph*);

RtmifyStatus rtmify_activate_license(const char* license_key);
RtmifyStatus rtmify_check_license(void);
RtmifyStatus rtmify_deactivate_license(void);
```

See [docs/architecture.md](docs/architecture.md) for full details.

## Project layout

```text
sys/
├── build.zig           canonical build graph (trace + live + libs + release)
├── lib/
│   ├── src/
│   │   ├── lib.zig         librtmify root: module re-exports + C ABI exports
│   │   ├── graph.zig       in-memory graph (nodes, edges, gap queries, RTM traversal)
│   │   ├── xlsx.zig        XLSX/ZIP/XML parser
│   │   ├── schema.zig      four-tab ingestion → graph nodes and edges
│   │   ├── render_md.zig   Markdown report renderer
│   │   ├── render_docx.zig DOCX report renderer (ZIP+XML, no external deps)
│   │   ├── render_pdf.zig  PDF 1.4 report renderer (Helvetica AFM, direct PDF)
│   │   └── license.zig     LemonSqueezy license verification + local cache
│   ├── docs/
│   │   └── architecture.md deep-dive on design decisions and module internals
│   └── vendor/
├── trace/
│   └── src/main.zig        Trace CLI entry point
└── test/
    └── fixtures/           XLSX test files and golden output
```
