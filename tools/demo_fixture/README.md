# VitalSense VS-200 Demo Fixture

This directory contains a stdlib-only Python generator that writes a fully populated RTMify Live SQLite graph database for the VitalSense VS-200 demo product.

The fixture is intended for demos, screenshots, and MCP / dashboard walkthroughs. It still seeds the graph end-state directly. It does not replay workbook sync, BOM ingest, SOUP ingest, repo scanning, or test-results ingest.

The major difference after the multi-source requirement PRD is that the generator now also writes companion design-artifact files so the demo DB stays aligned with the post-PRD provenance model:

- canonical `Requirement` nodes store no `statement`
- canonical `Requirement` nodes store no derived `effective_statement`
- requirement text is carried by `RequirementText` nodes
- `Artifact` nodes represent RTM, SRS, and SysRD sources
- the generated RTM `.xlsx`, SRS `.docx`, and SysRD `.docx` files support Design Artifacts inspection and re-ingest

## Files

- `generate_vitalsense_vs200_demo.py`
- `vitalsense_vs200_dataset.py`
- `test_generate_vitalsense_vs200_demo.py`

## Generate The Fixture

```bash
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/generate_vitalsense_vs200_demo.py --output /tmp/vitalsense-vs200-demo.sqlite --overwrite
```

This writes:

- SQLite DB: `/tmp/vitalsense-vs200-demo.sqlite`
- companion artifact dir: `/tmp/vitalsense-vs200-demo.sqlite.artifacts`

Choose an explicit artifact directory:

```bash
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/generate_vitalsense_vs200_demo.py --output /tmp/vitalsense-vs200-demo.sqlite --artifact-dir /tmp/vitalsense-demo-artifacts --overwrite
```

Validate without leaving files behind:

```bash
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/generate_vitalsense_vs200_demo.py --validate-only
```

Generate and print a machine-readable summary:

```bash
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/generate_vitalsense_vs200_demo.py --output /tmp/vitalsense-vs200-demo.sqlite --overwrite --summary-json
```

## Launch Live Against The Fixture

```bash
/Users/colinsteele/Projects/rtmify/sys/zig-out/bin/rtmify-live --db /tmp/vitalsense-vs200-demo.sqlite
```

Passing `--db` is sufficient. The fixture does not need workbook config mutation, sync setup, or a checked-in SQLite asset.

## What The Fixture Seeds

- Product `VS-200-REV-C`
- user needs, system requirements, software requirements, tests, and risks
- canonical `Requirement` nodes without stored text
- `Artifact` nodes for:
  - RTM workbook provenance and local `.xlsx` re-ingest
  - SRS `.docx`
  - SysRD `.docx`
- `RequirementText` nodes plus `CONTAINS`, `ASSERTS`, and `CONFLICTS_WITH` edges
- hardware Design BOM for `main-pcba`
- software SOUP register for `SOUP Components`
- CI executions and serial-bearing ATE / ATP production executions
- source-file, test-file, annotation, and commit traceability nodes
- `node_history` for changed requirement `SRS-015`
- `node_history` for the authoritative RTM `RequirementText` on `SRS-015`
- `suspect` flags and reasons for the stale-verification and text-mismatch demo moment
- runtime diagnostics for the planted BOM / SOUP / coverage / provenance / production gaps

## Seeded Provenance Moments

- `REQ-001` through `REQ-007` are aligned between RTM and SysRD
- `SRS-001` through `SRS-014` are aligned between RTM and SRS
- `SRS-015` conflicts between RTM and SRS, with RTM authoritative
- `SRS-016` and `SRS-017` exist only in the SRS artifact and have no RTM assertion

## Seeded Demo Moments

- `SRS-016` and `SRS-017` have no `TESTED_BY` edges and no `IMPLEMENTED_IN` edges
- `SRS-015` changed on `2026-03-10` after the latest linked `TC-FHIR-003` execution on `2026-03-05`
- SOUP items include:
  - `zlib@1.2.11` with anomaly text and blank evaluation
  - `Micro-ECC@unknown` with blank evaluation
  - `mbedTLS@3.4.0` with completed anomaly evaluation
- hardware BOM includes `BSS138LT1G` and `SI8621EC-B-IS` to support BOM impact and missing test-linkage demos
- production history includes one failed unit: `UNIT-1246`
- open risk `RSK-010` remains visible for security / SOUP audit demos

## Design Artifacts In The Demo

The generator writes three real companion design-artifact files:

- RTM workbook `.xlsx`
- SRS artifact
- SysRD artifact

Those generated files are the ones to use when demoing:

- `Design Controls -> Design Artifacts`
- `artifact://...` MCP resources
- artifact re-ingest flows

Keep the artifact directory available if you want the Design Artifacts re-ingest demo to work after launching Live with the generated DB.

## Deliberate Limits

- This is a graph-state fixture, not an ingest fixture
- No actual repo checkout is created; code evidence nodes are seeded directly
- No workbook sync status or settings state is populated; the `config` table is intentionally left empty
- Runtime settings and connected-workbook panes are not the focus of this fixture
- RTM workbook sync itself is not replayed by the generator; the generated RTM `.xlsx` is a local artifact fixture, not a provider-managed sync source

## Shipped-Unit Compression

The PRD text mentions `1,247` total shipped units, but the explicit serial-number narrative only defines `UNIT-1201` through `UNIT-1247`.

This fixture resolves that contradiction by seeding exactly `47` serial-bearing production executions:

- passing batch: `UNIT-1201` through `UNIT-1245`
- failing unit: `UNIT-1246`
- passing unit: `UNIT-1247`

That keeps the demo deterministic and realistic without fabricating another 1,200 production records that add little value to the graph walkthrough.

## Verification

Run the local smoke tests:

```bash
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/test_generate_vitalsense_vs200_demo.py
```

Recommended broader verification:

```bash
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/generate_vitalsense_vs200_demo.py --validate-only
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/generate_vitalsense_vs200_demo.py --output /tmp/vitalsense-vs200-demo.sqlite --overwrite --summary-json
zig build live
zig build test-live
```
