# VitalSense VS-200 Demo Fixture

This directory contains a stdlib-only Python generator that writes a fully populated RTMify Live SQLite graph database for the VitalSense VS-200 demo product.

The fixture is intended for demos, screenshots, and MCP / dashboard walkthroughs. It seeds the graph end-state directly. It does not exercise workbook sync, BOM ingest, SOUP ingest, repo scanning, or test-results ingest.

## Files

- `generate_vitalsense_vs200_demo.py`
- `vitalsense_vs200_dataset.py`
- `test_generate_vitalsense_vs200_demo.py`

## Generate The Fixture

```bash
python3 /Users/colinsteele/Projects/rtmify/sys/tools/demo_fixture/generate_vitalsense_vs200_demo.py --output /tmp/vitalsense-vs200-demo.sqlite --overwrite
```

Validate without writing a file:

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

Passing `--db` is sufficient. The fixture does not need any workbook config mutation, sync setup, or checked-in SQLite asset.

## What The Fixture Seeds

- Product `VS-200-REV-C`
- user needs, system requirements, software requirements, tests, and risks
- hardware Design BOM for `main-pcba`
- software SOUP register for `SOUP Components`
- CI executions and serial-bearing ATE / ATP production executions
- source-file, test-file, annotation, and commit traceability nodes
- `node_history` for changed requirement `SRS-015`
- `suspect` flags and reasons for the stale-verification demo moment
- runtime diagnostics for the planted BOM / SOUP / coverage / production gaps

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

## Deliberate Limits

- This is a graph-state fixture, not an ingest fixture
- No actual repo checkout is created; code evidence nodes are seeded directly
- No workbook sync status or settings state is populated; the `config` table is intentionally left empty
- Runtime settings and connected-workbook panes are not the focus of this fixture

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
```
