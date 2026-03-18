# BOM and SOUP Ingestion Guide

RTMify Live accepts product-scoped Design BOM evidence and SOUP/software BOM evidence through the local HTTP API, grouped workbook/XLSX ingest, and the shared inbox directory. This is a Live-only feature: Trace ignores BOM, SOUP, and SBOM artifacts, and product matching is exact on the `Product` tab's `full_identifier` value unless grouped workbook ingest is explicitly running in warning-only mode.

## What To Send

Use `POST /api/v1/bom` with the same bearer token exposed in `/api/info`. Supported payloads are:

- raw `text/csv` for RTMify hardware BOM CSV
- `application/json` for RTMify hardware BOM JSON
- `application/json` for CycloneDX JSON
- `application/json` for SPDX JSON

Use `POST /api/v1/bom/xlsx` for workbook-style Design BOM uploads. The workbook must contain:

- a `Design BOM` tab
- optionally a `Product` tab, which is upserted first

Workbook/XLSX Design BOM ingest groups rows by `(full_product_identifier, bom_name)` and processes each group independently.

Every BOM submission must include a `bom_name`. The replacement key is `(full_product_identifier, bom_type, bom_name)`, so re-uploading `pcba` replaces only that hardware BOM and leaves a software BOM like `firmware` untouched.

Use the dedicated SOUP endpoints for manual software inventories:

- `POST /api/v1/soup`
- `POST /api/v1/soup/xlsx`
- `GET /api/v1/soup`
- `GET /api/v1/soup/components`
- `GET /api/v1/soup/gaps`
- `GET /api/v1/soup/licenses`
- `GET /api/v1/soup/safety-classes`

SOUP writes still land in the same graph model:

- `DesignBOM`
- `BOMItem`
- `bom_type = "software"`
- `bom_class = "design"`

The SOUP workbook path is intentionally single-purpose. The workbook must contain a `SOUP Components` tab. Connected SOUP sync also requires an existing Product anchor in config.

## Product Status Semantics

`Product Status` is now interpreted, not just stored:

- `Active` and `In Development` remain in the default Design BOM views
- `Superseded` and `EOL` remain in the graph, but `GET /api/v1/bom/gaps` and the `bom_gaps` MCP tool exclude them by default
- `Obsolete` is hidden from default Design BOM list/tree/items/usage/impact surfaces

Override flags:

- `include_obsolete=true`
  - `GET /api/v1/bom/:full_product_identifier`
  - `GET /api/v1/bom/design`
  - `GET /api/v1/bom/design/:bom_name`
  - `GET /api/v1/bom/design/:bom_name/items`
  - `GET /api/v1/bom/part-usage`
  - `GET /api/v1/bom/impact-analysis`
  - matching MCP tools: `get_bom`, `list_design_boms`, `find_part_usage`, `bom_impact_analysis`
- `include_inactive=true`
  - `GET /api/v1/bom/gaps`
  - matching MCP tool: `bom_gaps`

Unknown nonblank `Product Status` values do not block Product ingest, but Product sheet writeback now marks them as `PRODUCT_UNKNOWN_STATUS`.

These lifecycle rules apply to SOUP/software views too:

- `GET /api/v1/soup`
- `GET /api/v1/soup/components`
- `GET /api/v1/soup/licenses`
- `GET /api/v1/soup/safety-classes`
  - use `include_obsolete=true`
- `GET /api/v1/soup/gaps`
  - use `include_inactive=true`

## Operator Workflow

1. Declare the product first on the `Product` tab and make sure `full_identifier` is exactly the value your BOM payload will use.
2. Submit the BOM through `POST /api/v1/bom`, `POST /api/v1/bom/xlsx`, or drop the artifact into `~/.rtmify/inbox`.
3. Verify the result with:
   - `GET /api/v1/bom/:full_product_identifier`
   - `GET /api/v1/bom/design`
   - `GET /api/v1/bom/design/:bom_name?full_product_identifier=...`
   - add `include_obsolete=true` or `include_inactive=true` when you intentionally need non-current lifecycle states
   - the MCP tools `get_bom`, `get_bom_item`, `list_design_boms`, `find_part_usage`, `bom_gaps`, and `bom_impact_analysis`

The inbox accepts mixed evidence: test results, hardware BOMs, and SBOMs can all be placed in the same directory. The canonical config key is `inbox_dir`; `test_results_inbox_dir` remains as a backward-compatible alias. Processed files are archived to `processed/`; rejected files are archived to `rejected/` and recorded as runtime diagnostics under `external_ingest_inbox`.

For SOUP `.xlsx` inbox files:

- the workbook must contain `SOUP Components`
- the filename must be `SOUP__{full_product_identifier}.xlsx`
- the Product must already exist, or the inbox upload is rejected

## Optional BOM Trace Fields

Hardware BOM CSV and hardware BOM JSON can declare direct design-control references on each BOM row:

- `requirement_ids`
- `test_ids`

Singular aliases are also accepted:

- `requirement_id`
- `test_id`

These values are:

- tokenized on `,`, `;`, or `|`
- trimmed and deduped
- stored on the `BOMItem` node as `requirement_ids` and `test_ids`
- resolved by exact ID match to `Requirement`, `Test`, and `TestGroup` nodes

Resolved matches create:

- `BOMItem --REFERENCES_REQUIREMENT--> Requirement`
- `BOMItem --REFERENCES_TEST--> Test` or `TestGroup`

Unresolved IDs do not fail the upload. RTMify ingests the BOM, preserves the declared IDs on the BOM item, and emits ingest warnings.

## Minimal Examples

### Hardware CSV

```csv
bom_name,full_identifier,parent_part,parent_revision,child_part,child_revision,quantity,requirement_ids,test_ids
pcba,ASM-1000-REV-C,ASM-1000,REV-C,C0805-10UF,A,4,REQ-001;REQ-002,TEST-001
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
      "quantity": "4",
      "requirement_ids": "REQ-001;REQ-002",
      "test_ids": ["TEST-001"]
    }
  ]
}
```

### CycloneDX / SPDX

For SBOM uploads, keep `bom_name` at the top level. `full_product_identifier` may also be supplied at the top level and is the safest way to bind the SBOM to the correct Product row.

### SOUP JSON

```json
{
  "full_product_identifier": "ASM-1000-REV-C",
  "bom_name": "SOUP Components",
  "components": [
    {
      "component_name": "FreeRTOS",
      "version": "10.5.1",
      "supplier": "Amazon/AWS",
      "category": "RTOS",
      "license": "MIT",
      "purl": "pkg:github/FreeRTOS/FreeRTOS-Kernel@10.5.1",
      "safety_class": "C",
      "known_anomalies": "None known",
      "anomaly_evaluation": "No anomalies to evaluate",
      "requirement_ids": ["REQ-001"],
      "test_ids": ["TG-001"]
    }
  ]
}
```

SOUP-specific fields persisted on `BOMItem`:

- `safety_class`
- `known_anomalies`
- `anomaly_evaluation`

CycloneDX and SPDX leave those three fields `null`. SOUP workbook rows write them as strings, with blank cells preserved as `""`.

## Failure Modes

- `415 unsupported_content_type`: body was neither JSON nor raw CSV
- `413 payload_too_large`: body exceeded the route size limit
- `BOM_NO_PRODUCT_MATCH`: no `Product` row matched `full_product_identifier`
- `SBOM_UNRESOLVABLE_ROOT`: the SBOM root could not be bound to a Product
- `BOM_DUPLICATE_CHILD`: duplicate child under the same parent was skipped
- `BOM_ORPHAN_CHILD`: dependency referenced a parent or child that was not present in the submitted BOM
- `BOM_UNRESOLVED_REQUIREMENT_REF`: a hardware BOM row referenced a Requirement ID that was not present in the graph
- `BOM_UNRESOLVED_TEST_REF`: a hardware BOM row referenced a Test ID that was not present in the graph
- `SOUP_PRODUCT_NOT_FOUND`: the configured or uploaded SOUP source referenced a Product that does not exist
- `SOUP_NO_PRODUCT_IDENTIFIER`: a SOUP inbox `.xlsx` filename did not encode the Product anchor
- `NO_SOUP_TAB`: the uploaded workbook did not contain `SOUP Components`
- `SOUP_MISSING_REQUIRED_FIELD`: one SOUP row was skipped because `component_name` or `version` was blank
- `SOUP_NO_ANOMALY_EVALUATION`: component declared anomalies but left `anomaly_evaluation` blank
- `SOUP_NO_ANOMALIES_DOCUMENTED`: both `known_anomalies` and `anomaly_evaluation` were blank
- `SOUP_VERSION_UNKNOWN`: component version was `unknown`
- `SOUP_NO_REQUIREMENT_LINKAGE`: component declared no requirement IDs
- `SOUP_NO_TEST_LINKAGE`: component declared no test IDs
- `SOUP_UNRESOLVED_REQUIREMENT_REF`: a declared requirement ID did not resolve
- `SOUP_UNRESOLVED_TEST_REF`: a declared test or test-group ID did not resolve

Inbox uploads with warning-only BOM issues still land in `processed/`. Those warnings are also copied into runtime diagnostics under `external_ingest_inbox` so operator workflows do not silently miss unresolved BOM trace refs.

## Design BOM Sync

Live can also attach one optional secondary Design BOM source to the active workbook. This source is read-only and does not participate in sheet status writeback.

Supported source kinds:

- Google Sheets
- Excel Online
- local `.xlsx`

The dashboard settings surface this as `Design BOM Sync`, backed by:

- `GET /api/design-bom-sync`
- `POST /api/design-bom-sync/validate`
- `POST /api/design-bom-sync`
- `DELETE /api/design-bom-sync`

When configured, the sync worker keeps ingesting the secondary Design BOM source after the primary RTM workbook sync completes. Sync results are recorded separately from the primary workbook sync status.

## SOUP Sync

Live can also attach one optional secondary SOUP source to the active workbook. This source is read-only and never writes status back to the workbook.

Supported source kinds:

- Google Sheets
- Excel Online
- local `.xlsx`

The dashboard settings surface this as `SOUP Sync`, backed by:

- `GET /api/soup-sync`
- `POST /api/soup-sync/validate`
- `POST /api/soup-sync`
- `DELETE /api/soup-sync`

SOUP Sync requires:

- an existing Product anchor via `full_product_identifier`
- a workbook exposing `SOUP Components`
- optionally a `bom_name` override, which defaults to `SOUP Components`

If a SOUP sheet and a CycloneDX/SPDX ingest target the same `(full_product_identifier, "software", bom_name)` key, last writer wins. If you want both inventories to coexist, use distinct `bom_name` values.

If a workflow depends on an operator remembering hidden naming rules, fix the naming rule or encode it in the toolchain. For BOM ingestion, the critical invariant is simple: the `Product.full_identifier` and the incoming `full_product_identifier` must match exactly.
