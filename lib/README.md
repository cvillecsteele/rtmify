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
  --license <path>            Use a specific signed license file
  --gaps-json <path>          Write diagnostics and gap list as JSON
  --strict                    Exit with hard-gap count when hard gaps are found
  --version                   Print version and exit
  --help                      Print this help and exit

Exit codes:
  0   success
  1   input/general error
  2   license required / trial exhausted
  3   license expired
  4   invalid, tampered, or wrong-product license
  5   output error
```

### Examples

```sh
rtmify-trace requirements.xlsx
rtmify-trace requirements.xlsx --format all --output ./reports/
rtmify-trace requirements.xlsx --format md --project "Ventilator v2.1"
rtmify-trace license info --json
rtmify-trace license install /path/to/license.json
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

## Licensing

RTMify uses signed offline license files.

- Manual install path: `~/.rtmify/license.json`
- Override for one run: `--license /path/to/license.json`

Trace allows one full free run with no installed license. After a successful
generation, subsequent runs require a valid signed license file.

Commands:

```sh
rtmify-trace license info --json
rtmify-trace license install /path/to/license.json
rtmify-trace license clear
```

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

int          rtmify_trace_license_get_status(RtmifyLicenseStatus* out_status);
int          rtmify_trace_license_install(const char* path, RtmifyLicenseStatus* out_status);
int          rtmify_trace_license_clear(RtmifyLicenseStatus* out_status);
int          rtmify_trace_license_record_successful_use(void);
char*        rtmify_trace_license_info_json(void);
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
│   │   ├── license.zig     signed license file service + trial policy
│   │   ├── license_file.zig canonical payload JSON + HMAC verification
│   │   └── license_gen.zig operator-side signed license generator
│   ├── docs/
│   │   └── architecture.md deep-dive on design decisions and module internals
│   └── vendor/
├── trace/
│   └── src/main.zig        Trace CLI entry point
└── test/
    └── fixtures/           XLSX test files and golden output
```
