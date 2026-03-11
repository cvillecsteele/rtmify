# libcadcruncher

`libcadcruncher` is a standalone metadata-extraction library for CAD and design artifacts.

It is not graph-aware. It does not know about RTMify Live, MCP, dashboard views, or requirement semantics. It only answers:

- what structured metadata records exist in this artifact
- which known IDs do those records match

## v0.2 scope

- OLE/CFB reader
- Altium `.PcbDoc` extraction
- first-pass Altium `.SchDoc` extraction
- developer CLI: `rtmify-cadinspect`

## Out of scope

- Live integration
- SolidWorks extraction
- geometry/electrical parsing
- fuzzy matching
- dashboard or MCP surfacing

`.SchDoc` support in v0.2 is intentionally narrow. It extracts:

- document/title-block metadata
- placed component/symbol metadata

It does not yet extract:

- nets
- wires
- ports
- full schematic topology

## Fixtures and local sample workflow

This repo now includes a minimal Altium fixture set under:

- `/Users/colinsteele/Projects/rtmify/sys/libcadcruncher/test/fixtures/altium/`

Those fixtures are the default source for the core `libcadcruncher` tests and now include both `.PcbDoc` and `.SchDoc` samples.

You can also point the library at a larger local sample corpus for ad hoc inspection and extra validation:

```sh
export RTMIFY_CAD_SAMPLES=/tmp/rtmify-cad-samples
```

Keep the committed fixture set small and deliberate. Do not bulk-copy large or unclear-license public CAD corpora into the repo.

## Example output

```text
artifact_kind = altium_pcbdoc
scope_kind = component
scope_identifier = U14
display_name = STM32F405RG
properties = {
  Designator: U14,
  Comment: MCU,
  Footprint: LQFP64,
  Requirement: REQ-893
}
matched_requirement_ids = [REQ-893]
provenance = PrimitiveParameters/Data
```
