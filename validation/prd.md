# RTMify Trace — Validation Package Specification

**Purpose:** Define the contents, structure, and acceptance criteria for the RTMify Trace Validation Package (IQ/OQ). This package enables customers in regulated industries to qualify RTMify Trace as a software tool within their quality management system.

---

## Package contents

The validation package ships as a ZIP archive containing six artifacts:

| #  | Artifact | Filename | What it is | Who produces it |
|----|----------|----------|------------|-----------------|
| 1  | **Input fixture** | `RTMify_OQ_Fixture_vX.Y.Z.xlsx` | A filled-in RTMify template with 25 items across 4 tabs. Contains intentional gaps, warnings, and valid chains — all documented. | RTMify (shipped) |
| 2  | **Golden outputs** | `golden/` directory | The exact outputs Trace produces when run against the fixture: `golden.pdf`, `golden.docx`, `golden.md`, `golden-gaps.json`. Regenerated and verified by RTMify on each release. | RTMify (shipped) |
| 3  | **Protocol document** | `RTMify_Trace_IQOQ_Protocol_vX.Y.Z.pdf` | Step-by-step IQ and OQ procedures with numbered checkpoints, pass/fail fields, and signature blocks. | RTMify (shipped) |
| 4  | **Evidence record** | `RTMify_Trace_IQOQ_Evidence_vX.Y.Z.pdf` | Blank form. The customer executes the protocol on their machine, records results, signs it. This becomes their quality record. | Customer (executed) |
| 5  | **Checksums** | `checksums.txt` | SHA-256 hashes for the Trace binaries covered by the qualification package (macOS, Windows, Linux). Used by IQ step `IQ-03`. | RTMify (shipped) |
| 6  | **Package guide** | `README.txt` | Plain-text quickstart that explains the files in the package and the recommended order of operations for the customer's quality engineer. | RTMify (shipped) |

**Version binding:** The `vX.Y.Z` in every filename matches the Trace release it was verified against. A package for Trace 1.2.0 is only valid for qualifying Trace 1.2.0. If the customer upgrades Trace, they re-execute with the corresponding package.

---

## Artifact 1 — Input fixture

### Design principles

Every row in the fixture exists to exercise a specific Trace behavior. Nothing is filler. The protocol references each item by ID and states the expected result.

All IDs use an `-OQ-` infix (e.g., `REQ-OQ-001`) so the fixture is visually distinguishable from production data if a customer accidentally mixes files.

### Fixture summary

| Tab            | Items | OK | Hard gaps | Advisory gaps | Diag errors | Diag warnings |
|----------------|------:|---:|----------:|--------------:|------------:|--------------:|
| User Needs     |     5 |  3 |         0 |             2 |           0 |             0 |
| Requirements   |    10 |  4 |         3 |             0 |           0 |             5 |
| Tests          |     6 |  4 |         0 |             2 |           0 |             0 |
| Risks          |     4 |  1 |         2 |             0 |           0 |             2 |
| **Totals**     |**25** |**12**|      **5**|           **4**|         **0**|           **7**|

`gap_count` in JSON output = **5** (hard gaps only). `--strict` exits with code **5**.

### Tab 1 — User Needs

#### UN-OQ-001 — Happy path (multiple derived requirements)

| Field          | Value |
|----------------|-------|
| ID             | `UN-OQ-001` |
| Description    | The system shall allow the operator to initiate a self-test sequence. |
| Derived Reqs   | `REQ-OQ-001`, `REQ-OQ-002` |

**Expected result:** `OK` — both derived requirements exist and are traceable.

#### UN-OQ-002 — Happy path (single derived requirement)

| Field          | Value |
|----------------|-------|
| ID             | `UN-OQ-002` |
| Description    | The system shall log all operator actions with timestamps. |
| Derived Reqs   | `REQ-OQ-008` |

**Expected result:** `OK`

#### UN-OQ-003 — Gap: no derived requirements

| Field          | Value |
|----------------|-------|
| ID             | `UN-OQ-003` |
| Description    | The system shall support firmware updates in the field. |
| Derived Reqs   | *(empty)* |

**Expected result:** **Advisory gap — `user_need_without_requirements`** — user need exists but no requirements trace to it. Appears in `gaps[]` with `severity: "advisory"`. Does not contribute to `gap_count` or `--strict` exit code.

#### UN-OQ-004 — Happy path (derived reqs have downstream issues)

| Field          | Value |
|----------------|-------|
| ID             | `UN-OQ-004` |
| Description    | The system shall detect and report sensor faults within 500ms. |
| Derived Reqs   | `REQ-OQ-005`, `REQ-OQ-006` |

**Expected result:** `OK` — both IDs exist. REQ-OQ-005 and REQ-OQ-006 each have their own downstream issues, but the user need linkage itself is valid.

#### UN-OQ-005 — Advisory gap: no requirements derived from this need

| Field          | Value |
|----------------|-------|
| ID             | `UN-OQ-005` |
| Statement      | The system shall provide audible alarm for critical faults. |
| Source         | Customer |
| Priority       | High |

**Expected result:** **Advisory gap — `user_need_without_requirements`** — no requirement in the fixture links back to `UN-OQ-005`. The template has no "Derived Reqs" column on the User Needs tab, so dangling cross-references from this tab cannot be represented; the gap appears instead because no requirement carries this user need's ID in its User Need field. Appears in `gaps[]` with `severity: "advisory"`. Does not contribute to `gap_count` or `--strict` exit code.

---

### Tab 2 — Requirements

#### REQ-OQ-001 — Happy path (fully traced)

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-001` |
| Description    | The software shall execute a power-on self-test (POST) and report pass/fail within 3 seconds of boot. |
| User Need      | `UN-OQ-001` |
| Linked Tests   | `TST-OQ-001` |
| Linked Risks   | `RSK-OQ-001` |
| Priority       | High |

**Expected result:** `OK` — full bidirectional traceability: user need → requirement → test → risk.

#### REQ-OQ-002 — Happy path (no risk linkage required)

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-002` |
| Description    | The software shall display POST results on the operator console within 1 second of test completion. |
| User Need      | `UN-OQ-001` |
| Linked Tests   | `TST-OQ-002` |
| Linked Risks   | *(empty)* |
| Priority       | Medium |

**Expected result:** `OK` — no linked risk is acceptable; not every requirement carries risk. Test coverage present.

#### REQ-OQ-003 — Gap: no test linked

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-003` |
| Description    | The software shall retain the last 1,000 operator log entries in non-volatile memory. |
| User Need      | `UN-OQ-002` |
| Linked Tests   | *(empty)* |
| Linked Risks   | *(empty)* |
| Priority       | Medium |

**Expected result:** **Hard gap — `requirement_no_test_group_link`** — requirement declares no test-group references. Appears in `gaps[]` with `severity: "hard"`. Contributes to `gap_count` and `--strict` exit code.

#### REQ-OQ-004 — Gap: no user need derivation

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-004` |
| Description    | The software shall enforce a minimum password length of 12 characters. |
| User Need      | *(empty)* |
| Linked Tests   | `TST-OQ-006` |
| Linked Risks   | *(empty)* |
| Priority       | Low |

**Expected result:** **Hard gap — `requirement_no_user_need_link`** — requirement has no upstream user need link. Appears in `gaps[]` with `severity: "hard"`. Contributes to `gap_count` and `--strict` exit code.

#### REQ-OQ-005 — Gap: dangling test reference

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-005` |
| Description    | The software shall detect sensor fault conditions within 500ms of occurrence. |
| User Need      | `UN-OQ-004` |
| Linked Tests   | `TST-OQ-999` |
| Linked Risks   | `RSK-OQ-002` |
| Priority       | High |

**Expected result:** **Hard gap — `requirement_only_unresolved_test_group_refs`** — all declared test-group references are unresolvable. Appears in `gaps[]` with `severity: "hard"`. Contributes to `gap_count` and `--strict` exit code.

#### REQ-OQ-006 — Warning: no "shall" clause

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-006` |
| Description    | Sensor fault reporting is expected to include the fault type and timestamp. |
| User Need      | `UN-OQ-004` |
| Linked Tests   | `TST-OQ-003` |
| Linked Risks   | *(empty)* |
| Priority       | Medium |

**Expected result:** **Diagnostic warning — E703 (`semantic`)** — requirement text contains no "shall" clause. Appears in `diagnostics[]` with `level: "warn"`, `code: 703`. Traceability chain is otherwise intact. Contributes to `warning_count`.

#### REQ-OQ-007 — Warning: compound requirement

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-007` |
| Description    | The software shall encrypt all data at rest using AES-256, and the software shall rotate encryption keys every 90 days. |
| User Need      | `UN-OQ-002` |
| Linked Tests   | `TST-OQ-002` |
| Linked Risks   | *(empty)* |
| Priority       | High |

**Expected result:** **Diagnostic warning — E704 (`semantic`)** — multiple "shall" clauses detected. Appears in `diagnostics[]` with `level: "warn"`, `code: 704`. Contributes to `warning_count`.

#### REQ-OQ-008 — Happy path (fully traced)

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-008` |
| Description    | The software shall write each operator action to the log within 200ms of the action. |
| User Need      | `UN-OQ-002` |
| Linked Tests   | `TST-OQ-003` |
| Linked Risks   | *(empty)* |
| Priority       | Medium |

**Expected result:** `OK`

#### REQ-OQ-009 — Gap: missing ID

| Field          | Value |
|----------------|-------|
| ID             | *(empty cell)* |
| Description    | The system shall support at least 50 concurrent users. |
| User Need      | `UN-OQ-001` |
| Linked Tests   | `TST-OQ-001` |
| Linked Risks   | *(empty)* |
| Priority       | Medium |

**Expected result:** **Diagnostic warning — E603 (`row_parsing`)** — requirement row has no ID. Appears in `diagnostics[]` with `level: "warn"`, `code: 603`. Cannot participate in traceability chain. Contributes to `warning_count`.

#### REQ-OQ-010 — Gap: duplicate ID

| Field          | Value |
|----------------|-------|
| ID             | `REQ-OQ-001` |
| Description    | The software shall provide a manual override for the self-test sequence. |
| User Need      | `UN-OQ-001` |
| Linked Tests   | `TST-OQ-001` |
| Linked Risks   | *(empty)* |
| Priority       | Low |

**Expected result:** **Diagnostic warning — E604 (`row_parsing`)** — `REQ-OQ-001` already exists. Appears in `diagnostics[]` with `level: "warn"`, `code: 604`. Contributes to `warning_count`.

---

### Tab 3 — Tests

#### TST-OQ-001 — Happy path (linked, passing)

| Field            | Value |
|------------------|-------|
| ID               | `TST-OQ-001` |
| Description      | Verify POST completes within 3 seconds of power-on and reports pass/fail. |
| Linked Reqs      | `REQ-OQ-001` |
| Status           | Pass |

**Expected result:** `OK`

#### TST-OQ-002 — Happy path (linked, passing)

| Field            | Value |
|------------------|-------|
| ID               | `TST-OQ-002` |
| Description      | Verify POST results display on operator console within 1 second. |
| Linked Reqs      | `REQ-OQ-002` |
| Status           | Pass |

**Expected result:** `OK`

#### TST-OQ-003 — Happy path (linked, failing test)

| Field            | Value |
|------------------|-------|
| ID               | `TST-OQ-003` |
| Description      | Verify operator actions are logged within 200ms. |
| Linked Reqs      | `REQ-OQ-008` |
| Status           | Fail |

**Expected result:** `OK` — the test exists and is linked. A failing test is not a traceability gap; it is a verification result. Trace reports the chain as intact. The `Fail` status appears in the output RTM for reviewer visibility.

**OQ design note:** This item exists specifically to confirm Trace distinguishes between "chain broken" (gap) and "test didn't pass" (not a gap). Auditors care about this distinction.

#### TST-OQ-004 — Advisory gap: test group linked to no requirement

| Field            | Value |
|------------------|-------|
| Test Group ID    | `TST-OQ-004` |
| Test ID          | `T-OQ-004` |
| Test Type        | Verification |
| Test Method      | Test |
| Notes            | Verify alarm volume exceeds 85dB at 1 meter. Status: Not Run |

**Expected result:** **Advisory gap — `test_group_without_requirements`** — no requirement in the fixture references `TST-OQ-004`. The template has no "Linked Reqs" column on the Tests tab, so dangling cross-references from this tab cannot be represented; the gap appears because no requirement carries this test group's ID in its Test Group IDs field. Appears in `gaps[]` with `severity: "advisory"`. Does not contribute to `gap_count` or `--strict` exit code.

#### TST-OQ-005 — Warning: orphan test

| Field            | Value |
|------------------|-------|
| ID               | `TST-OQ-005` |
| Description      | Verify system survives 10,000 power cycles without data loss. |
| Linked Reqs      | *(empty)* |
| Status           | Pass |

**Expected result:** **Advisory gap — `test_group_without_requirements`** — test group has no linked requirements. Appears in `gaps[]` with `severity: "advisory"`. Does not contribute to `gap_count` or `--strict` exit code.

#### TST-OQ-006 — Happy path (provides coverage for orphaned requirement)

| Field            | Value |
|------------------|-------|
| ID               | `TST-OQ-006` |
| Description      | Verify password enforcement rejects inputs under 12 characters. |
| Linked Reqs      | `REQ-OQ-004` |
| Status           | Pass |

**Expected result:** `OK` — provides test coverage for REQ-OQ-004. REQ-OQ-004 still has a separate hard gap (`requirement_no_user_need_link`), but the test linkage itself is valid.

**OQ design note:** This item confirms that a single item can be simultaneously OK on one traceability axis and gapped on another. The test linkage is clean even though the requirement it covers has a separate upstream gap.

---

### Tab 4 — Risks

#### RSK-OQ-001 — Happy path (mitigated, linked)

| Field            | Value |
|------------------|-------|
| ID               | `RSK-OQ-001` |
| Description      | POST failure undetected, leading to operation with degraded sensor. |
| Severity         | High |
| Linked Reqs      | `REQ-OQ-001` |
| Mitigation       | POST runs automatically on every boot; failure blocks normal operation mode. |
| Residual Risk    | Low |

**Expected result:** `OK`

#### RSK-OQ-002 — Warning: high severity, no mitigation

| Field            | Value |
|------------------|-------|
| ID               | `RSK-OQ-002` |
| Description      | Sensor fault not detected within safety window, leading to incorrect output. |
| Severity         | High |
| Linked Reqs      | `REQ-OQ-005` |
| Mitigation       | *(empty)* |
| Residual Risk    | *(empty)* |

**Expected result:** **Hard gap — `risk_without_mitigation_requirement`** — risk declares no mitigation requirement at all. Appears in `gaps[]` with `severity: "hard"`. Contributes to `gap_count` and `--strict` exit code. Note: despite being a "warning" in the fixture design intent, the binary classifies this as a hard gap.

#### RSK-OQ-003 — Warning: residual risk exceeds initial severity

| Field            | Value |
|------------------|-------|
| ID               | `RSK-OQ-003` |
| Description      | Logging subsystem overflow causes loss of audit trail. |
| Severity         | Medium |
| Linked Reqs      | `REQ-OQ-003` |
| Mitigation       | Circular buffer overwrites oldest entries. |
| Residual Risk    | High |

**Expected result:** **Diagnostic warning — E710 (`semantic`)** — residual risk (High) exceeds initial severity (Medium). Appears in `diagnostics[]` with `level: "warn"`, `code: 710`. Contributes to `warning_count`.

#### RSK-OQ-004 — Gap: dangling requirement reference

| Field            | Value |
|------------------|-------|
| ID               | `RSK-OQ-004` |
| Description      | Unauthorized firmware update bricks field unit. |
| Severity         | Critical |
| Linked Reqs      | `REQ-OQ-888` |
| Mitigation       | Firmware update requires cryptographic signature verification. |
| Residual Risk    | Low |

**Expected result:** **Hard gap — `risk_unresolved_mitigation_requirement`** — declared mitigation requirement `REQ-OQ-888` does not exist. Appears in `gaps[]` with `severity: "hard"`. Contributes to `gap_count` and `--strict` exit code.

---

## Artifact 2 — Golden outputs

RTMify ships pre-generated outputs produced by running Trace against the fixture. These are the reference the customer compares against.

### Contents of `golden/` directory

| File | How it was produced |
|------|---------------------|
| `golden.pdf` | `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --format pdf -o golden.pdf` |
| `golden.docx` | `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --format docx -o golden.docx` |
| `golden.md` | `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --format md -o golden.md` |
| `golden-gaps.json` | `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --strict --gaps-json golden-gaps.json` |

### What "matches" means

PDF and DOCX files will differ on timestamps, file metadata, and rendering artifacts between runs and between platforms. Byte-for-byte comparison will fail. The protocol does **not** require binary identity.

Instead, the protocol defines acceptance at two levels:

**Level 1 — Machine-verifiable (required):**

The customer runs `rtmify-trace` with `--strict --gaps-json` and compares the resulting JSON to `golden-gaps.json`. The acceptance criterion: the JSON root fields match the expected counts, every entry in `gaps[]` matches by `kind` and `primary_id`, and every entry in `diagnostics[]` matches by `code` and `level`. Field order and whitespace are ignored.

The JSON output has two separate arrays. `gaps[]` contains graph-level traceability findings (from `graph.zig`). `diagnostics[]` contains parser, schema, and semantic findings (from `diagnostic.zig`). `gap_count` reflects only hard-severity gaps; advisory gaps appear in `gaps[]` but are not counted.

Specifically, `golden-gaps.json` contains:

```json
{
  "diagnostics": [
    { "level": "info", "code": 304, "url": "https://rtmify.io/errors/E304", "source": "structure",    "tab": null,             "row": null, "message": "xl/sharedStrings.xml not found — treating all cells as inline values" },
    { "level": "warn", "code": 801, "url": "https://rtmify.io/errors/E801", "source": "cross_ref",    "tab": "Requirements",   "row": 6,   "message": "reference 'TST-OQ-999' not found; available TestGroup IDs: TST-OQ-003, TST-OQ-006, TST-OQ-002, TST-OQ-005, TST-OQ-004 (6 total)" },
    { "level": "warn", "code": 603, "url": "https://rtmify.io/errors/E603", "source": "row_parsing",  "tab": "Requirements",   "row": 10,  "message": "row has content but ID column is empty — skipping" },
    { "level": "warn", "code": 604, "url": "https://rtmify.io/errors/E604", "source": "row_parsing",  "tab": "Requirements",   "row": 11,  "message": "duplicate ID 'REQ-OQ-001' — skipping" },
    { "level": "warn", "code": 801, "url": "https://rtmify.io/errors/E801", "source": "cross_ref",    "tab": "Risks",          "row": 5,   "message": "reference 'REQ-OQ-888' not found; available Requirement IDs: REQ-OQ-002, REQ-OQ-008, REQ-OQ-005, REQ-OQ-003, REQ-OQ-001 (8 total)" },
    { "level": "warn", "code": 710, "url": "https://rtmify.io/errors/E710", "source": "semantic",     "tab": null,             "row": null, "message": "Risk RSK-OQ-003: residual score (8) exceeds initial score (6) — mitigation should reduce risk, not increase it" },
    { "level": "warn", "code": 704, "url": "https://rtmify.io/errors/E704", "source": "semantic",     "tab": null,             "row": null, "message": "REQ REQ-OQ-007: compound requirement — 2 'shall' clauses detected; split into separate requirements" },
    { "level": "warn", "code": 703, "url": "https://rtmify.io/errors/E703", "source": "semantic",     "tab": null,             "row": null, "message": "REQ REQ-OQ-006: statement has no 'shall'" }
  ],
  "gaps": [
    { "severity": "hard",     "kind": "requirement_no_user_need_link",               "primary_id": "REQ-OQ-004", "related_id": null        },
    { "severity": "hard",     "kind": "requirement_no_test_group_link",              "primary_id": "REQ-OQ-003", "related_id": null        },
    { "severity": "hard",     "kind": "requirement_only_unresolved_test_group_refs", "primary_id": "REQ-OQ-005", "related_id": "TST-OQ-999" },
    { "severity": "hard",     "kind": "risk_without_mitigation_requirement",         "primary_id": "RSK-OQ-002", "related_id": null        },
    { "severity": "hard",     "kind": "risk_unresolved_mitigation_requirement",      "primary_id": "RSK-OQ-004", "related_id": "REQ-OQ-888" },
    { "severity": "advisory", "kind": "user_need_without_requirements",              "primary_id": "UN-OQ-003",  "related_id": null        },
    { "severity": "advisory", "kind": "user_need_without_requirements",              "primary_id": "UN-OQ-005",  "related_id": null        },
    { "severity": "advisory", "kind": "test_group_without_requirements",             "primary_id": "TST-OQ-004", "related_id": null        },
    { "severity": "advisory", "kind": "test_group_without_requirements",             "primary_id": "TST-OQ-005", "related_id": null        }
  ],
  "gap_count": 5,
  "warning_count": 7,
  "error_count": 0
}
```

**Level 2 — Human-verified (required):**

The customer opens their generated PDF/DOCX alongside the golden PDF/DOCX and confirms structural equivalence:

| Checkpoint | What to verify |
|------------|----------------|
| CP-OQ-01   | User Needs table contains exactly 5 rows with IDs `UN-OQ-001` through `UN-OQ-005`. |
| CP-OQ-02   | RTM table contains exactly 10 requirement rows. Row for `REQ-OQ-009` (missing ID) appears with a missing-ID indicator. |
| CP-OQ-03   | Coverage status column for each requirement matches the expected result from this spec. |
| CP-OQ-04   | Test table contains exactly 6 rows. `TST-OQ-003` shows `Fail` status but `OK` traceability. |
| CP-OQ-05   | Risk Register contains exactly 4 rows. Mitigation column is populated for RSK-OQ-001 and RSK-OQ-003; empty for RSK-OQ-002. |
| CP-OQ-06   | Gap Summary section lists exactly 9 gaps matching the gap summary table in this spec. |
| CP-OQ-07   | Warning section lists exactly 7 warnings matching the warning summary table in this spec. |
| CP-OQ-08   | Gap rows are visually distinguished (colored cells in DOCX/PDF; markers in Markdown). |

---

## Artifact 3 — Protocol document

The protocol document is the procedure the customer's quality team follows. It contains three sections:

### Section A — Installation Qualification (IQ)

Confirms the correct binary is installed and runs on the target system.

| Step | Action | Acceptance criterion | Pass/Fail |
|------|--------|----------------------|-----------|
| IQ-01 | Record target OS and version. | Matches one of: macOS 13+, Windows 10+, Linux (glibc 2.31+). | ☐ |
| IQ-02 | Record Trace binary version: `rtmify-trace --version` | Output matches `vX.Y.Z` (the version this package was built for). | ☐ |
| IQ-03 | Record SHA-256 hash of the binary. | Matches the hash published in the package's `checksums.txt`. | ☐ |
| IQ-04 | Run `rtmify-trace --help` | Help text prints without error. | ☐ |

### Section B — Operational Qualification (OQ)

Confirms Trace produces correct analysis on known input.

| Step | Action | Acceptance criterion | Pass/Fail |
|------|--------|----------------------|-----------|
| OQ-01 | Run: `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --format pdf -o customer.pdf` | Exits 0. File `customer.pdf` is created. | ☐ |
| OQ-02 | Run: `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --format docx -o customer.docx` | Exits 0. File `customer.docx` is created. | ☐ |
| OQ-03 | Run: `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --format md -o customer.md` | Exits 0. File `customer.md` is created. | ☐ |
| OQ-04 | Run: `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --strict` | Exit code equals **5**. | ☐ |
| OQ-05 | Run: `rtmify-trace RTMify_OQ_Fixture_vX.Y.Z.xlsx --strict --gaps-json customer-gaps.json` | Exit code equals 5. File `customer-gaps.json` is created. | ☐ |
| OQ-06 | Compare `customer-gaps.json` to `golden/golden-gaps.json`. | `gap_count` equals 5. `error_count` equals 0. `warning_count` equals 7. `gaps[]` contains exactly 9 entries (5 hard, 4 advisory) matching by `kind` and `primary_id`. `diagnostics[]` contains exactly 8 entries matching by `code` and `level`. | ☐ |
| OQ-07 | Open `customer.pdf` alongside `golden/golden.pdf`. Verify checkpoints CP-OQ-01 through CP-OQ-08. | All 8 checkpoints pass. | ☐ |
| OQ-08 | Open `customer.docx` alongside `golden/golden.docx`. Verify checkpoints CP-OQ-01 through CP-OQ-08. | All 8 checkpoints pass. | ☐ |
| OQ-09 | Open `customer.md` alongside `golden/golden.md`. Verify checkpoints CP-OQ-01 through CP-OQ-08. | All 8 checkpoints pass. | ☐ |

### Section C — Signatures

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Executor (ran the protocol) | | | |
| Reviewer (verified results) | | | |
| Quality approver | | | |

---

## Artifact 4 — Evidence record

The evidence record is a blank copy of the protocol with space for the customer to attach:

1. The completed pass/fail table from Section A (IQ) with values filled in.
2. The completed pass/fail table from Section B (OQ) with values filled in.
3. A copy of `customer-gaps.json` (or a screenshot of the diff against the golden file).
4. The signed Section C.

The customer files the completed evidence record in their quality system (DHF, technical file, QMS records) as proof of tool qualification.

---

## Artifact 5 — Checksums

`checksums.txt` is shipped at the top level of the validation package ZIP.

It contains the published SHA-256 hashes for the Trace binaries covered by this qualification package:

- macOS Trace CLI
- Windows Trace CLI
- Linux Trace CLI

IQ step `IQ-03` compares the customer binary to the corresponding published hash.

---

## Expected aggregate results

### Hard gaps in `gaps[]` (5 items — break `--strict`, contribute to `gap_count`)

| #  | `primary_id`  | `kind`                                      | Description |
|----|---------------|---------------------------------------------|-------------|
| 1  | `REQ-OQ-003`  | `requirement_no_test_group_link`            | Requirement declares no test-group references |
| 2  | `REQ-OQ-004`  | `requirement_no_user_need_link`             | Requirement has no upstream user need link |
| 3  | `REQ-OQ-005`  | `requirement_only_unresolved_test_group_refs` | All test-group references are unresolvable |
| 4  | `RSK-OQ-002`  | `risk_without_mitigation_requirement`       | Risk declares no mitigation requirement |
| 5  | `RSK-OQ-004`  | `risk_unresolved_mitigation_requirement`    | Mitigation requirement `REQ-OQ-888` does not exist |

### Advisory gaps in `gaps[]` (4 items — do not break `--strict`, not counted in `gap_count`)

| #  | `primary_id`  | `kind`                            | Description |
|----|---------------|-----------------------------------|-------------|
| 1  | `UN-OQ-003`   | `user_need_without_requirements`  | User need has no derived requirements |
| 2  | `UN-OQ-005`   | `user_need_without_requirements`  | User need has no derived requirements (template has no Derived Reqs column — cannot represent as E801) |
| 3  | `TST-OQ-004`  | `test_group_without_requirements` | Test group not linked to any requirement (template has no Linked Reqs column — cannot represent as E801) |
| 4  | `TST-OQ-005`  | `test_group_without_requirements` | Test group not linked to any requirement |

### Diagnostic warnings in `diagnostics[]` (`level: "warn"`, contribute to `warning_count: 7`)

There are no `level: "err"` diagnostics in this fixture. E603, E604, and E801 are all emitted at `level: "warn"`.

| #  | Item          | `code` | `source`      | Description |
|----|---------------|--------|---------------|-------------|
| 1  | `REQ-OQ-005`  | 801    | `cross_ref`   | References nonexistent test group `TST-OQ-999` |
| 2  | `REQ-OQ-009`  | 603    | `row_parsing` | Requirement row has no ID — skipped |
| 3  | `REQ-OQ-010`  | 604    | `row_parsing` | Duplicate of `REQ-OQ-001` — skipped |
| 4  | `RSK-OQ-004`  | 801    | `cross_ref`   | References nonexistent requirement `REQ-OQ-888` |
| 5  | `RSK-OQ-003`  | 710    | `semantic`    | Residual score (8) exceeds initial score (6) |
| 6  | `REQ-OQ-007`  | 704    | `semantic`    | Multiple "shall" clauses detected |
| 7  | `REQ-OQ-006`  | 703    | `semantic`    | No "shall" clause in requirement text |

---

## Scope and exclusions

### What this package qualifies

The OQ confirms that RTMify Trace, when given a well-formed `.xlsx` file conforming to the RTMify template schema, correctly identifies traceability gaps, warnings, and valid chains — and produces accurate output artifacts in all three formats.

### What this package does NOT qualify

| Exclusion | Rationale |
|-----------|-----------|
| Input validation edge cases (BOM, smart quotes, renamed tabs, reordered columns) | Covered by Trace's internal test suite. OQ tests analytical correctness, not parser robustness. |
| RTMify Live (Google Sheets sync, git integration, MCP server) | Separate product. If Live requires its own OQ, it would be a separate package. |
| Customer's specific data or requirements | The fixture is a controlled test vector. Qualification of Trace on the fixture does not constitute qualification of the customer's actual requirements data. |
| Regulatory compliance determination | This package helps qualify the tool. It does not constitute regulatory advice or assurance of compliance with any specific standard. |

---

## Release process (internal — RTMify maintainer)

When cutting a new Trace release:

1. Run `./release.sh` and allow it to generate the validation package into `dist/<version>/validation/`.
2. Visually inspect the generated protocol PDF and evidence PDF to confirm printable layout and signature blocks.
3. Visually inspect the golden PDF/DOCX to confirm all checkpoint criteria are met.
4. Verify `golden-gaps.json` matches the expected aggregate results in this spec.
5. If the gap detection taxonomy has changed (new codes, reclassified items), update this spec, `expected-gaps.json`, and the fixture to match.
6. Publish the generated ZIP alongside the Trace release.

If the fixture or expected results change between releases, the changelog for the validation package must document what changed and why.
