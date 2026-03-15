# BOM Ingestion Guide

RTMify Live accepts product-scoped BOM evidence through the local HTTP API and the shared inbox directory. This is a Live-only feature: Trace ignores BOM and SBOM artifacts, and product matching is exact on the `Product` tab's `full_identifier` value.

## What To Send

Use `POST /api/v1/bom` with the same bearer token exposed in `/api/info`. Supported payloads are:

- raw `text/csv` for RTMify hardware BOM CSV
- `application/json` for RTMify hardware BOM JSON
- `application/json` for CycloneDX JSON
- `application/json` for SPDX JSON

Every BOM submission must include a `bom_name`. The replacement key is `(full_product_identifier, bom_type, bom_name)`, so re-uploading `pcba` replaces only that hardware BOM and leaves a software BOM like `firmware` untouched.

## Operator Workflow

1. Declare the product first on the `Product` tab and make sure `full_identifier` is exactly the value your BOM payload will use.
2. Submit the BOM through `POST /api/v1/bom`, or drop the artifact into `~/.rtmify/inbox`.
3. Verify the result with `GET /api/v1/bom/:full_product_identifier` or the MCP `get_bom` tool.

The inbox accepts mixed evidence: test results, hardware BOMs, and SBOMs can all be placed in the same directory. The canonical config key is `inbox_dir`; `test_results_inbox_dir` remains as a backward-compatible alias. Processed files are archived to `processed/`; rejected files are archived to `rejected/` and recorded as runtime diagnostics under `external_ingest_inbox`.

## Minimal Examples

### Hardware CSV

```csv
bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity
pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4
```

### Hardware JSON

```json
{
  "bom_name": "pcba",
  "full_product_identifier": "ASM-1000-REV-C",
  "bom_items": [
    {
      "parent_part": "ASM-1000",
      "parent_revision": "REV-C",
      "child_part": "C0805-10UF",
      "child_revision": "A",
      "quantity": "4"
    }
  ]
}
```

### CycloneDX / SPDX

For SBOM uploads, keep `bom_name` at the top level. `full_product_identifier` may also be supplied at the top level and is the safest way to bind the SBOM to the correct Product row.

## Failure Modes

- `415 unsupported_content_type`: body was neither JSON nor raw CSV
- `413 payload_too_large`: body exceeded the route size limit
- `BOM_NO_PRODUCT_MATCH`: no `Product` row matched `full_product_identifier`
- `SBOM_UNRESOLVABLE_ROOT`: the SBOM root could not be bound to a Product
- `BOM_DUPLICATE_CHILD`: duplicate child under the same parent was skipped
- `BOM_ORPHAN_CHILD`: dependency referenced a parent or child that was not present in the submitted BOM

If a workflow depends on an operator remembering hidden naming rules, fix the naming rule or encode it in the toolchain. For BOM ingestion, the critical invariant is simple: the `Product.full_identifier` and the incoming `full_product_identifier` must match exactly.
