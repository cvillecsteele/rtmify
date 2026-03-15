# RTMify Live+Repo — Local Code Traceability
## Product Requirements Document
### Version 0.1

Note: Live now manages multiple workbook entries inside one running server.
One workbook is active at a time. UI routes, sync, inbox watching, and MCP
operate on that active workbook context, while each workbook keeps its own
graph DB, token file, and inbox path.

---

## 1. What This Is

An extension to RTMify Live that watches a local git repository and links source code, test code, commits, and blame data into the requirements graph. The traceability chain extends from user need to the specific line of code written by a specific person on a specific date. No GitHub API. No GitLab API. No network calls. The tool reads the filesystem and the local `.git` directory.

The engineer configures a repo path in the Live dashboard. Live scans the working tree for requirement ID annotations in source files and test files, reads git history for commits that reference requirement IDs, and runs git blame on annotated files to attribute lines to authors. The graph grows new node types (SourceFile, TestFile, Commit, CodeAnnotation) and new edges linking them to existing Requirement, Test, and DesignOutput nodes.

The result: an auditor can start at a user need and walk the graph to current code annotations, current implementation files, historical commits that explicitly referenced traced IDs, and file-level change history. The DHR is no longer a document assembled by hand. It's a traversal.

### Evidence Semantics

RTMify deliberately keeps three evidence classes separate:

- **Current code annotation evidence**
  - Derived from the current checked-out working tree.
  - If a source or test file currently contains a traced ID in a comment, that is present-state evidence.
  - This evidence creates `IMPLEMENTED_IN`, `VERIFIED_BY_CODE`, `ANNOTATED_AT`, and `CONTAINS` relationships.

- **Historical explicit commit evidence**
  - Derived from commit messages that explicitly mention traced IDs.
  - This is historical traceability evidence, not present-state file implication.
  - This evidence creates `COMMITTED_IN`.

- **Historical file change evidence**
  - Derived from git history showing that a source or test file changed in a commit.
  - This means only "this file changed in this commit".
  - It does **not** imply that the file is currently implicated in a requirement just because an old commit once referenced that requirement.
  - This evidence creates file/commit relationships such as `CHANGED_IN` and `CHANGES`.

Two explicit product rules follow from this:

1. RTMify does **not** mine old blob contents or historical diffs for present-state code annotations. What matters for code-comment traceability is what the code says **right now** in the checked-out working tree.
2. RTMify does **not** infer current requirement/file implication from old commit messages. Historical commit-message references remain valuable history, but they are not a substitute for current code annotations.

---

## 2. What This Builds On

Live+Repo requires RTMify Live (Zig port) to be running. It extends the existing graph, web UI, and MCP surface. It does not function standalone.

**Existing graph nodes:** UserNeed, Requirement, TestGroup, Test, Risk
**Existing edges:** DERIVES_FROM, TESTED_BY, HAS_TEST, MITIGATED_BY

**Existing infrastructure reused:**
- SQLite graph database (new tables for new node types)
- HTTP server (new API routes)
- Web UI (new tab)
- MCP server (new tools)
- Sync loop architecture (new filesystem watcher alongside Sheets poller)
- Diagnostic system (new error codes)

---

## 3. Industry-Specific Traceability Chains

Different regulatory frameworks require different traceability paths. The graph captures all relationships. The industry configuration determines which paths are required and which gaps are flagged.

### 3.1 FDA / ISO 13485 / IEC 62304 (Medical Device)

```
UserNeed
  └─ DERIVES_FROM ← Requirement
       └─ ALLOCATED_TO → DesignInput
            └─ SATISFIED_BY → DesignOutput
                 └─ IMPLEMENTED_IN → SourceFile
                      └─ VERIFIED_BY → TestFile
                           └─ RESULT_OF ← TestResult
```

IEC 62304 specifically requires:
- Software requirements traceable to system requirements
- Software units (source files) traceable to software requirements
- Software verification (test code) traceable to software requirements
- The full chain documented in the Software Development Plan

The DHR (Design History File) is the aggregation of every node associated with a product, traversed from user needs down to verification evidence.

### 3.2 DO-178C (Aerospace Software)

```
UserNeed (System Requirement)
  └─ DERIVES_FROM ← Requirement (High-Level Requirement)
       └─ REFINED_BY → Requirement (Low-Level Requirement)
            └─ IMPLEMENTED_IN → SourceFile
                 └─ VERIFIED_BY → TestFile (Low-Level Test)
            └─ VERIFIED_BY → TestFile (High-Level Test)
```

DO-178C requires:
- High-level requirements traceable to system requirements
- Low-level requirements traceable to high-level requirements
- Source code traceable to low-level requirements
- Test cases traceable to requirements at both levels
- Structural coverage analysis (which lines of code are exercised by which tests)

Key difference from FDA: the two-level requirement decomposition (high/low) and the structural coverage mandate.

### 3.3 AS9100 (Aerospace Quality)

```
UserNeed (Customer Requirement)
  └─ DERIVES_FROM ← Requirement (Product Requirement)
       └─ IMPLEMENTED_IN → DesignOutput
            └─ VERIFIED_BY → TestFile
       └─ IMPLEMENTED_IN → SourceFile
            └─ VERIFIED_BY → TestFile
```

AS9100 requires:
- Customer requirements traceable to product requirements
- Product requirements traceable to design outputs
- Verification evidence for each requirement
- Configuration management of all controlled items

Less prescriptive about the depth of decomposition than DO-178C. More focused on configuration control and nonconformance tracking.

### 3.4 ISO 26262 (Automotive Functional Safety)

```
UserNeed (Vehicle-Level Safety Goal, ASIL rated)
  └─ DERIVES_FROM ← Requirement (Functional Safety Requirement)
       └─ REFINED_BY → Requirement (Technical Safety Requirement)
            └─ IMPLEMENTED_IN → SourceFile (Software Unit)
                 └─ VERIFIED_BY → TestFile (Unit Test)
            └─ VERIFIED_BY → TestFile (Integration Test)
       └─ VERIFIED_BY → TestFile (System Test)
```

ISO 26262 requires:
- ASIL (Automotive Safety Integrity Level) inheritance through the chain
- Requirements decomposition with ASIL allocation
- Software unit verification to the rigor dictated by ASIL level
- Bidirectional traceability at every level

Key difference: ASIL rating flows through the graph. A safety-critical requirement (ASIL D) demands more rigorous verification than a non-critical one (QM).

### 3.5 ASPICE (Automotive SPICE)

```
UserNeed (Stakeholder Requirement)
  └─ DERIVES_FROM ← Requirement (System Requirement)
       └─ REFINED_BY → Requirement (Software Requirement)
            └─ IMPLEMENTED_IN → SourceFile (Software Unit)
                 └─ VERIFIED_BY → TestFile
       └─ VERIFIED_BY → TestFile (Integration Test)
```

ASPICE requires bidirectional traceability at every level and explicitly assesses it in process area assessments (SWE.1 through SWE.6). The traceability chain is similar to ISO 26262 but framed as process maturity rather than safety integrity.

### 3.6 Configuration

The user selects an industry profile in the Live dashboard. The profile determines:

1. **Which tabs are created in the Google Sheet** (provisioned automatically on first connect)
2. **Which traceability paths are required** (and therefore which gaps are flagged)
3. **Which node types are expected** (e.g., DesignInput/DesignOutput for FDA, not for AS9100)
4. **Whether requirement decomposition is expected** (two-level for DO-178C and ISO 26262, flat for AS9100)
5. **Which additional properties are required** (e.g., ASIL rating for ISO 26262)
6. **Report section titles and structure** (DHR for FDA, PSAC/SAS for DO-178C)

The profile is stored in the SQLite config table. Changing it re-evaluates all gaps and offers to create any missing tabs in the connected sheet. No data is lost — the graph is the same, only the gap analysis changes.

Default profiles shipped with the product:

| Profile | Standards | Tabs Provisioned |
|---------|----------|-----------------|
| `medical-device` | ISO 13485, IEC 62304, FDA 21 CFR Part 820 | User Needs, Requirements, Tests, Risks, Product, Design Inputs, Design Outputs, Configuration Items |
| `aerospace-sw` | DO-178C | User Needs, Requirements, Tests, Risks, Product, Configuration Items, Decomposition |
| `aerospace-quality` | AS9100 | User Needs, Requirements, Tests, Risks, Product, Configuration Items |
| `automotive-safety` | ISO 26262 | User Needs, Requirements, Tests, Risks, Product, Configuration Items |
| `automotive-process` | ASPICE | User Needs, Requirements, Tests, Risks, Product |
| `generic` | No industry-specific gaps, all traceability optional | User Needs, Requirements, Tests, Risks, Product |

`Product` and `Decomposition` are provisioned and ingested only by Live. Trace
and the shared template/report path ignore both tabs entirely in this cut.

---

## 4. New Graph Nodes

| Node Type | Description | Properties |
|-----------|-------------|------------|
| `Product` | Live-only product declaration row keyed by `full_identifier` for future manufacturing joins | `assembly`, `revision`, `full_identifier`, `description`, `product_status` |
| `Decomposition` | Live-only requirement refinement rows that create `REFINED_BY` edges between Requirement nodes | `parent_id`, `child_id` |
| `BOM` | Live-only named hardware or software BOM attached to a Product | `full_product_identifier`, `bom_name`, `bom_type`, `source_format`, `ingested_at` |
| `BOMItem` | Live-only component or package node namespaced to one BOM | `part`, `revision`, `description`, `category`, `purl`, `license`, `hashes` |
| `DesignInput` | Formal design input derived from a requirement (FDA/IEC 62304) | `description`, `source_req`, `status` |
| `DesignOutput` | Design artifact satisfying a design input (drawing, spec, firmware, BOM) | `description`, `type`, `version`, `status` |
| `SourceFile` | A source code file in the working tree linked to a requirement or design output | `path`, `language`, `last_modified`, `line_count` |
| `TestFile` | A test code file in the working tree linked to a requirement or test | `path`, `language`, `framework`, `last_modified` |
| `Commit` | A git commit referencing one or more requirement IDs | `hash`, `short_hash`, `author`, `date`, `message`, `req_ids[]` |
| `CodeAnnotation` | A specific location in a source or test file that references a requirement ID | `file_path`, `line_number`, `req_id`, `context` (surrounding line text) |
| `ConfigurationItem` | A controlled artifact: firmware version, BOM revision, document revision | `ci_id`, `type`, `version`, `status`, `description` |

---

## 5. New Graph Edges

| Edge | From | To | Meaning |
|------|------|----|---------|
| `ALLOCATED_TO` | Requirement | DesignInput | Requirement allocated to design input (FDA chain) |
| `SATISFIED_BY` | DesignInput | DesignOutput | Design input satisfied by output artifact |
| `REFINED_BY` | Requirement | Requirement | High-level requirement decomposed to low-level (DO-178C, ISO 26262) |
| `IMPLEMENTED_IN` | Requirement | SourceFile | Requirement implemented in this source file |
| `IMPLEMENTED_IN` | DesignOutput | SourceFile | Design output realized in this source file |
| `VERIFIED_BY_CODE` | Requirement | TestFile | Requirement verified by this test file |
| `VERIFIED_BY_CODE` | SourceFile | TestFile | Source file tested by this test file |
| `COMMITTED_IN` | Requirement | Commit | Requirement referenced in this commit |
| `CHANGED_IN` | SourceFile/TestFile | Commit | This file changed in this commit |
| `CHANGES` | Commit | SourceFile/TestFile | This commit changed this file |
| `ANNOTATED_AT` | Requirement | CodeAnnotation | Requirement annotation found at this location |
| `CONTAINS` | SourceFile | CodeAnnotation | Source file contains this annotation |
| `CONTAINS` | TestFile | CodeAnnotation | Test file contains this annotation |
| `CONTROLLED_BY` | DesignOutput | ConfigurationItem | Design output under configuration control |
| `FOR_PRODUCT` | TestExecution | Product | Execution evidence scoped to a product configuration |
| `HAS_BOM` | Product | BOM | Product currently declares this named BOM |
| `CONTAINS` | BOM/BOMItem | BOMItem | BOM tree containment; occurrence facts like quantity and ref designator live on the edge properties |

### External Evidence Ingestion

Live accepts product-scoped external evidence through the local ingestion API and the shared inbox directory:

- `POST /api/v1/test-results`
- `POST /api/v1/bom`
- `GET /api/v1/bom/:full_product_identifier`

`/api/v1/bom` accepts:

- raw `text/csv` for RTMify hardware BOM CSV uploads
- `application/json` for RTMify hardware BOM JSON, CycloneDX JSON, and SPDX JSON

The inbox at `~/.rtmify/inbox` uses the same bearer token and dispatches `.json` and `.csv` files by content. Product matching is exact on `Product.full_identifier`; BOM and SBOM uploads are Live-only and do not affect Trace output.

For DO-178C workbooks, Live also provisions a `Decomposition` tab with
`parent_id` and `child_id`. Each nonblank row creates `Requirement(parent) --REFINED_BY--> Requirement(child)`.
There is no writeback or status column on this tab in the first cut.

For operator-focused ingestion instructions and minimal payload examples, see [BOM Ingestion Guide](./bom_ingestion.md).

---

## 6. New Google Sheets Tabs

### 6.1 Design Inputs Tab (FDA/IEC 62304 profiles only)

| Column | Field | Required | Notes |
|--------|-------|----------|-------|
| A | ID | Yes | e.g. DI-001 |
| B | Description | Yes | Formal design input statement |
| C | Source Requirement | No | Requirement ID (creates ALLOCATED_TO edge) |
| D | Status | No | draft / approved / obsolete |

### 6.2 Design Outputs Tab (FDA/IEC 62304 profiles only)

| Column | Field | Required | Notes |
|--------|-------|----------|-------|
| A | ID | Yes | e.g. DO-001 |
| B | Description | Yes | Design output description |
| C | Type | No | firmware / hardware / software / document / BOM |
| D | Design Input | No | Design Input ID (creates SATISFIED_BY edge) |
| E | Version | No | Current version/revision |
| F | Status | No | draft / released / obsolete |

### 6.3 Configuration Items Tab (all profiles)

| Column | Field | Required | Notes |
|--------|-------|----------|-------|
| A | ID | Yes | e.g. CI-001 |
| B | Description | Yes | Configuration item description |
| C | Type | No | firmware / BOM / drawing / document / tool |
| D | Version | No | Current version |
| E | Linked Design Output | No | Design Output ID (creates CONTROLLED_BY edge) |
| F | Status | No | draft / released / obsolete |

### 6.4 Tab Discovery

Same cascading fuzzy match logic from schema.zig. Synonym lists for the new tabs:

| Expected | Synonyms |
|----------|----------|
| Design Inputs | `design input`, `design inputs`, `DI`, `inputs` |
| Design Outputs | `design output`, `design outputs`, `DO`, `outputs`, `design artifacts` |
| Configuration Items | `configuration items`, `CI`, `config items`, `controlled items`, `configuration`, `BOM` |

All three new tabs are optional. If missing, the corresponding node types don't populate. Gap analysis for chains that require them (e.g., FDA requiring DesignInput → DesignOutput) flags the missing link.

### 6.5 Sheet Provisioning

Live can create tabs in the connected Google Sheet via the Sheets API `spreadsheets.batchUpdate` with `AddSheetRequest`. When the user connects a sheet and selects an industry profile, Live provisions the entire spreadsheet automatically.

**Provisioning flow:**

1. User connects a Google Sheet (new or existing) and selects an industry profile
2. Live reads the sheet's existing tabs
3. For each tab required by the profile that doesn't already exist (exact match or fuzzy match):
   - Create the tab via `AddSheetRequest`
   - Write the header row (Row 1) with the canonical column names for that tab
   - Apply header formatting: bold text, frozen row, light gray background
4. For tabs that already exist: leave them untouched, use the existing tab discovery / column mapping logic

**API call:**

```json
{
  "requests": [
    {
      "addSheet": {
        "properties": {
          "title": "Design Inputs",
          "index": 4
        }
      }
    },
    {
      "addSheet": {
        "properties": {
          "title": "Design Outputs",
          "index": 5
        }
      }
    }
  ]
}
```

Followed by a `values.batchUpdate` to write headers:

```json
{
  "valueInputOption": "RAW",
  "data": [
    {
      "range": "Design Inputs!A1:D1",
      "values": [["ID", "Description", "Source Requirement", "Status"]]
    },
    {
      "range": "Design Outputs!A1:F1",
      "values": [["ID", "Description", "Type", "Design Input", "Version", "Status"]]
    }
  ]
}
```

**Provisioning behavior by scenario:**

| Scenario | Action |
|----------|--------|
| Blank sheet, no tabs | Create all profile tabs with headers |
| Existing sheet, some tabs match | Create only missing tabs, leave existing ones alone |
| Existing sheet, all tabs present | No provisioning needed, proceed to sync |
| Profile changed after initial setup | Offer to create newly required tabs, never delete existing tabs |

**The RTMify Template becomes unnecessary for Live users.** A user connecting a blank Google Sheet to Live with the `medical-device` profile gets seven tabs with correct headers in seconds. They open their sheet and start typing. The template download remains valuable for Trace users (who work offline with XLSX files) and as an SEO artifact.

**Provisioning is non-destructive.** Live never deletes tabs, never renames tabs, never overwrites existing data. If a tab named "Requirements" already exists with data in it, Live uses it as-is. If a tab doesn't exist, Live creates it. The user always has the option to decline provisioning and create tabs manually.

---

## 7. Repo Watching

### 7.1 Configuration

The user configures a repo path in the Live web dashboard:

```
Repo Path: /Users/jsmith/projects/ventilator-firmware
```

Or via CLI:

```
rtmify-live --repo /path/to/repo
```

Multiple repos can be watched by specifying the flag multiple times or adding paths in the dashboard. Each repo is identified by its path and scanned independently.

Live validates:
- Path exists and is a directory
- Path contains a `.git` directory (or is inside a git repo — walk up to find `.git`)
- Path is readable

If validation fails, a clear error message in the dashboard. "No .git directory found at /path/to/repo — is this a git repository?"

### 7.2 Scan Cycle

The repo scanner runs on a separate thread alongside the Sheets sync thread. Scan frequency: every 60 seconds (configurable). The scan is fast because it only checks file modification times against the last scan timestamp.

```
loop:
    for each watched repo:
        scan working tree for new/modified files since last scan
        for each changed file:
            scan for requirement ID annotations
            create/update SourceFile or TestFile nodes
            create CodeAnnotation nodes
            create edges
        scan git log for new commits since last scanned hash
        for each new commit:
            parse message for requirement IDs
            create Commit nodes
            create COMMITTED_IN edges
        for annotated files:
            run git blame on annotated lines
            update CodeAnnotation with author/date
    sleep 60 seconds
```

### 7.3 File Classification

Files are classified as source or test based on path and name patterns:

**Test files (TestFile nodes):**
- Path contains `/test/`, `/tests/`, `/spec/`, `/specs/`, `/__tests__/`
- Filename starts with `test_` or ends with `_test.*` or `.test.*` or `.spec.*`
- Filename matches `*_test.go`, `*_test.c`, `*_test.py`, `test_*.py`, etc.
- File contains a known test framework import (`import pytest`, `#include <gtest`, `import XCTest`, `describe(`, `it(`, `#[test]`, `test "..."` for Zig)

**Source files (SourceFile nodes):**
- Everything else that matches a known source extension
- Extensions: `.c`, `.h`, `.cpp`, `.hpp`, `.py`, `.js`, `.ts`, `.go`, `.rs`, `.zig`, `.java`, `.cs`, `.swift`, `.vhdl`, `.vhd`, `.v`, `.sv` (hardware description languages matter in this domain)

**Ignored:**
- `.git/` directory
- Files matching `.gitignore` patterns
- Binary files (detected by null bytes in first 512 bytes)
- Files over 1MB (safety limit)
- `node_modules/`, `venv/`, `.venv/`, `__pycache__/`, `build/`, `dist/`, `target/`, `zig-out/`, `zig-cache/`

### 7.4 Requirement ID Annotation Scanning

The scanner looks for requirement IDs in source and test files. A requirement ID is any string matching the pattern of IDs already in the graph (e.g., `REQ-001`, `UN-003`, `DI-007`, `RSK-101`).

**Annotation patterns recognized:**

```c
// REQ-001: implement GPS timeout detection
/* REQ-001 */
# REQ-001
// @req REQ-001
// @requirement REQ-001
// @trace REQ-001
// @verify REQ-001, REQ-002
/// REQ-001: GPS loss detection timing test
```

The scanner extracts:
- The requirement ID(s)
- The file path
- The line number
- The surrounding context (the full line, trimmed)

**Multi-ID annotations:** A single comment can reference multiple IDs separated by `,`, `;`, or whitespace. Each gets its own CodeAnnotation node and edge.

**Annotation format is not prescribed.** The scanner matches any occurrence of a known requirement ID in a comment. The user doesn't need to adopt a specific annotation syntax. If their code says `// implements REQ-001` or `// see REQ-001 for rationale` or just `// REQ-001`, it all works.

The scanner does NOT match requirement IDs in string literals, variable names, or executable code. It only matches in comments. This prevents false positives from strings like `error_REQ_001_not_met` or log messages containing requirement IDs.

**Comment detection by language:**

| Language | Line comment | Block comment |
|----------|-------------|---------------|
| C/C++/Java/Go/Zig/Rust/Swift/JS/TS | `//` | `/* */` |
| Python | `#` | `""" """` (docstrings) |
| VHDL | `--` | — |
| Verilog/SV | `//` | `/* */` |

The scanner doesn't need a full parser. It needs to know enough about comment syntax to avoid matching inside strings. A simple state machine (in-string / in-comment / in-code) per language is sufficient.

---

## 8. Git Integration

### 8.1 Reading Git Data

Two approaches, in order of preference:

**Option A: Fork/exec `git` commands.** The user already has git installed (they have a git repo). Shell out to:

```
git log --format='%H|%h|%an|%ae|%aI|%s' --since='2026-01-01' -- .
git blame --porcelain <file> -L <start>,<end>
```

Parse the output. Portable, simple, no library dependency. The git CLI format is stable and well-documented.

**Option B: Read `.git` directory directly.** Parse packfiles, loose objects, refs. This avoids the fork/exec overhead but requires implementing a substantial portion of git's internal format. Not worth it. Git's CLI is the stable interface.

**Decision: Option A.** Fork/exec `git`. It's on the user's machine. It's the right tool for the job. The overhead of spawning a process every 60 seconds is negligible.

### 8.2 Commit Scanning

```
git log --format='%H|%h|%an|%ae|%aI|%s' --after=<last_scanned_timestamp>
```

For each commit, parse the subject line for requirement IDs using the same pattern matcher as the annotation scanner. Create a Commit node and `COMMITTED_IN` edges for explicit requirement references. Separately, parse changed source/test file paths and create file/commit change edges.

Important semantic boundary:
- `COMMITTED_IN` means the commit message explicitly named a traced ID.
- It does **not** mean every file touched by that commit is now permanently implicated in that requirement.
- File/commit edges capture historical change evidence only.

Store the most recent scanned commit hash in the SQLite config table. On next scan, only fetch commits after that hash.

### 8.3 Git Blame

For each CodeAnnotation (a line in a file that references a requirement ID), run:

```
git blame --porcelain <file> -L <line>,<line>
```

Extract: commit hash, author name, author email, author timestamp. Store on the CodeAnnotation node.

Blame is expensive on large files. Mitigations:
- Only blame lines that contain annotations (not the entire file)
- Cache blame results; only re-blame if the file has changed since last scan
- Rate limit: no more than 50 blame calls per scan cycle

### 8.4 Branch Awareness

The scanner reads whatever is currently checked out. It does not traverse branches. If the user switches branches, the next scan picks up the new working tree state. Old annotations from the previous branch are not deleted — they persist in the graph with their file path and commit hash, allowing the auditor to see the history.

This is deliberately simple. Branch-aware traceability (tracking which requirements are implemented on which branches) is a feature for the $4,999/year VCS Integration tier, not for Live+Repo.

---

## 9. Gap Analysis — Extended

### 9.1 Existing Gaps (unchanged)

| Gap | Query |
|-----|-------|
| Untested requirement | Requirement with no TESTED_BY edge |
| Orphan requirement | Requirement with no DERIVES_FROM edge |
| Unmitigated risk | Risk with no MITIGATED_BY edge |
| Unresolved reference | Cross-reference to nonexistent node |

### 9.2 New Gaps — Code Traceability

| Gap | Query | Profiles |
|-----|-------|----------|
| Unimplemented requirement | Requirement with no IMPLEMENTED_IN edge to any SourceFile | All except `generic` |
| Untested source file | SourceFile with no VERIFIED_BY_CODE edge to any TestFile | All except `generic` |
| Uncommitted requirement | Requirement with IMPLEMENTED_IN edge but no COMMITTED_IN edge | All except `generic` |
| Unattributed annotation | CodeAnnotation with no blame data (git blame failed or file is untracked) | All except `generic` |

### 9.3 New Gaps — FDA / IEC 62304 Specific

| Gap | Query | Profile |
|-----|-------|---------|
| Requirement without design input | Requirement with no ALLOCATED_TO edge | `medical-device` |
| Design input without design output | DesignInput with no SATISFIED_BY edge | `medical-device` |
| Design output without source | DesignOutput with no IMPLEMENTED_IN edge to SourceFile | `medical-device` |
| Design output without config control | DesignOutput with no CONTROLLED_BY edge | `medical-device` |

### 9.4 New Gaps — DO-178C Specific

| Gap | Query | Profile |
|-----|-------|---------|
| High-level requirement without low-level decomposition | Requirement with no REFINED_BY edge (when decomposition is expected) | `aerospace-sw` |
| Low-level requirement without source | Low-level Requirement with no IMPLEMENTED_IN edge | `aerospace-sw` |
| Source without structural coverage | SourceFile with annotations but no VERIFIED_BY_CODE edge (partial coverage) | `aerospace-sw` |

### 9.5 New Gaps — ISO 26262 Specific

| Gap | Query | Profile |
|-----|-------|---------|
| Safety requirement without ASIL | Requirement in safety chain with no `asil` property | `automotive-safety` |
| ASIL inheritance gap | Child requirement with lower ASIL than parent (unless ASIL decomposition is documented) | `automotive-safety` |

### 9.6 Gap Severity by Profile

Each profile defines which gaps are errors (audit failures) and which are warnings (should fix, won't fail audit):

| Gap | `medical-device` | `aerospace-sw` | `aerospace-quality` | `automotive-safety` | `generic` |
|-----|------------------|-----------------|---------------------|---------------------|-----------|
| Untested requirement | Error | Error | Error | Error | Warning |
| Orphan requirement | Error | Error | Warning | Error | Warning |
| Unimplemented requirement | Error | Error | Warning | Error | — |
| Req without design input | Error | — | — | — | — |
| DI without DO | Error | — | — | — | — |
| HLR without LLR | — | Error | — | — | — |
| Missing ASIL | — | — | — | Error | — |

`—` means the gap type doesn't apply to that profile.

---

## 10. Diagnostic Codes — New Range

Extend the existing E1xx-E8xx scheme:

| Range | Layer |
|-------|-------|
| E9xx | Repo configuration and filesystem |
| E10xx | Git integration |
| E11xx | Annotation scanning |
| E12xx | Industry profile and chain validation |

### E9xx — Repo Configuration

| Code | Title | Severity |
|------|-------|----------|
| E901 | Repo path does not exist | Error |
| E902 | Repo path is not a directory | Error |
| E903 | No .git directory found | Error |
| E904 | Repo path not readable | Error |
| E905 | git executable not found on PATH | Error |
| E906 | git version too old (need 2.x+) | Warning |

### E10xx — Git Integration

| Code | Title | Severity |
|------|-------|----------|
| E1001 | git log command failed | Warning (skip cycle, retry) |
| E1002 | git blame command failed for file | Warning (skip file) |
| E1003 | Commit message parse error | Info (skip commit) |
| E1004 | Blame output parse error | Info (skip line) |
| E1005 | git command timed out (>10s) | Warning |

### E11xx — Annotation Scanning

| Code | Title | Severity |
|------|-------|----------|
| E1101 | Annotation references unknown requirement ID | Warning |
| E1102 | Annotation in non-comment context (possible false positive) | Info |
| E1103 | File too large to scan (>1MB) | Info |
| E1104 | Binary file skipped | Info |
| E1105 | Unrecognized file extension | Info |
| E1106 | Multiple annotations on same line | Info |

### E12xx — Industry Profile

| Code | Title | Severity |
|------|-------|----------|
| E1201 | Requirement missing in required chain (profile-specific) | Warning or Error per profile |
| E1202 | Design input without design output | Error (medical-device only) |
| E1203 | High-level requirement without low-level decomposition | Error (aerospace-sw only) |
| E1204 | ASIL not specified for safety requirement | Error (automotive-safety only) |
| E1205 | ASIL inheritance violation | Error (automotive-safety only) |
| E1206 | Traceability chain incomplete | Warning |
| E1207 | Industry profile not configured | Info (defaults to generic) |

---

## 11. Web UI Extensions

### 11.1 New Tab: Code Traceability

A new tab in the web dashboard showing:

- **Watched repos** with scan status (last scan time, file count, annotation count)
- **Source files** with requirement annotations, grouped by repo
- **Test files** with requirement coverage
- **Recent commits** referencing requirements
- **Unimplemented requirements** (requirements with no code link)
- **Untested source files** (code with no test coverage)

Each row is expandable (same inline expansion pattern as the existing tabs) to show annotations, blame data, and linked graph nodes.

### 11.2 New Tab: Design History (FDA profile)

A dedicated DHR view showing the full chain from user need to verification evidence, formatted for the FDA submission pattern:

```
UN-001 → REQ-001 → DI-001 → DO-001 → motor_controller.c → test_motor.c → PASS
```

Each step is a clickable node that opens the drawer with full properties and edges.

### 11.3 Extended Node Drawer

The existing node drawer (right-side panel showing node properties and edges) is extended to show:

- For SourceFile nodes: file path, language, line count, all annotations, blame summary
- For TestFile nodes: file path, framework, linked requirements, linked source files
- For Commit nodes: hash, author, date, full message, linked requirements
- For CodeAnnotation nodes: file, line, context, blame author, blame date

### 11.4 Industry Profile Selector

A dropdown in the dashboard settings area:

```
Industry Profile: [Medical Device (FDA/IEC 62304) ▾]
```

Changing the profile re-evaluates gaps and updates the gap badge counts immediately. No data loss.

**On first connect with a blank or partial sheet**, the profile selector appears in the lobby flow *before* sync starts:

```
1. Upload service account credentials     ✓
2. Paste sheet URL                        ✓
3. Select industry profile                [Medical Device (FDA/IEC 62304) ▾]
   
   This will create 8 tabs in your sheet:
   User Needs, Requirements, Tests, Risks,
   Product, Design Inputs, Design Outputs, Configuration Items
   
   [Connect & Create Tabs]
```

The user sees exactly what will happen before it happens. If the sheet already has matching tabs, the message adjusts: "Found 4 existing tabs. Will create 4 additional tabs: Product, Design Inputs, Design Outputs, Configuration Items."

If the user connects an existing sheet with all tabs already present, the profile selector still appears but provisioning is skipped: "All required tabs found. No changes to your sheet."

### 11.5 Repo Configuration Panel

In the dashboard lobby/settings:

```
Watched Repositories:
  /Users/jsmith/projects/ventilator-firmware  ✓ scanning
  [Add Repository...]
```

Add by typing a path or using a browse button. Remove with an × button. Validation feedback inline.

---

## 12. MCP Extensions

New MCP tools exposed at `127.0.0.1:8000/mcp`:

| Tool | Description |
|------|-------------|
| `code_traceability` | List all source/test files with their requirement links |
| `unimplemented_requirements` | Requirements with no code link |
| `untested_source_files` | Source files with no test file link |
| `file_annotations` | All requirement annotations in a specific file |
| `blame_for_requirement` | Who wrote the code implementing a specific requirement, and when |
| `commit_history` | Commits referencing a specific requirement |
| `design_history` | Full traceability chain for a requirement (UN → REQ → DI → DO → code → test) |
| `chain_gaps` | Industry-profile-specific chain gaps |

The `design_history` tool is the high-value one. An engineer connected to Live via Claude asks "show me the full design history for REQ-001" and gets the complete chain from user need to git blame, with every gap flagged.

Live MCP now exposes structured tool data for machine consumption while keeping
the existing text payloads for compatibility. JSON-returning tools include
`structuredContent`; narrative tools remain Markdown-first. BOM occurrence facts
stored on edge properties are preserved in both JSON node detail and
human-readable Markdown resource output.

---

## 13. Report Extensions

### 13.1 Extended RTM

The existing RTM report (PDF/MD/DOCX) gains new columns when code data is available:

| Req ID | User Need | Statement | Test Group | Source File | Test File | Last Commit | Status |
|--------|-----------|-----------|------------|-------------|-----------|-------------|--------|

Source File and Test File columns show the file paths. Last Commit shows the short hash and date. Gaps in code traceability are flagged the same way test gaps are flagged today.

### 13.2 DHR Report (new, FDA profile)

A new report format: Design History File. One section per user need, showing the complete chain:

```
User Need: UN-001 — System shall detect loss of GPS

  Requirement: REQ-001 — The system SHALL detect loss of GPS within 500ms
    Design Input: DI-001 — GPS loss detection timing specification
      Design Output: DO-001 — GPS module firmware v1.4
        Source: src/gps/timeout.c (47 lines, 3 annotations)
          Author: jsmith, 2026-02-14
        Test: test/gps/test_timeout.c (23 lines)
          Result: PASS (via TG-001/T-002)
    Risk: RSK-101 — Clock drift at high temp (mitigated by REQ-602)
```

Output formats: PDF and Markdown. Same renderers, new data structure.

### 13.3 Code Coverage Report (new)

A report showing which requirements have code traceability and which don't:

- Requirements with source annotations: count and percentage
- Requirements with test file coverage: count and percentage
- Source files with no requirement annotation (orphan code)
- Test files with no requirement link (orphan tests)

---

## 14. Data Flow

### 14.1 Three Input Sources, One Graph

```
Google Sheets ──(sync thread)──┐
      — or —                    │
Local XLSX ────(file watcher)──┤
                                ├──▶ SQLite Graph ──▶ API/Web UI/MCP/Reports
Local Git Repo ──(scan thread)──┘
                                │
Manual API ─────(HTTP POST)─────┘
```

The sync thread (Sheets or local XLSX) and the repo scan thread both write to the same SQLite database. WAL mode handles concurrency. The HTTP server reads from the database to serve queries, reports, and MCP.

In Google Sheets mode, the sync thread polls the Sheets API and writes status back to the sheet. In local XLSX mode (for air-gapped and classified environments), the sync thread watches a local `.xlsx` file for modification time changes and re-parses it on each change. No writeback occurs — the XLSX is read-only input. Status and gap data are visible in the web dashboard only.

### 14.2 Edge Creation from Repo Data

When the scanner finds `// REQ-001` in `src/gps/timeout.c` at line 31:

1. Check if `REQ-001` exists in the graph (it should — it was synced from the sheet)
2. If yes: create SourceFile node for `src/gps/timeout.c` (or update if exists)
3. Create CodeAnnotation node: `{file: "src/gps/timeout.c", line: 31, req_id: "REQ-001"}`
4. Create IMPLEMENTED_IN edge: `REQ-001 → src/gps/timeout.c`
5. Create ANNOTATED_AT edge: `REQ-001 → annotation`
6. Create CONTAINS edge: `src/gps/timeout.c → annotation`
7. Run git blame on line 31, store author/date on the annotation node

When the scanner finds the file is in a test directory:

1. Create TestFile node instead of SourceFile
2. Create VERIFIED_BY_CODE edge instead of IMPLEMENTED_IN

### 14.2.1 Current Code vs Historical Commits

The scanner reads annotations from the **current** working tree only. If a line once contained `REQ-001` in an old commit but no longer does, RTMify does not treat that historical comment as current implementation evidence.

Commit history is retained as a separate historical signal:

- if a commit message explicitly references `REQ-001`, RTMify records that with `COMMITTED_IN`
- if a commit changed `src/gps/timeout.c`, RTMify records that with file/commit change edges

Those signals are intentionally not collapsed into one another. An old commit message referencing `REQ-001` does not, by itself, prove that `src/gps/timeout.c` is still currently implicated in `REQ-001`.

### 14.3 Suspect Propagation — Code Aware

When a requirement changes (detected by the Sheets sync):
- Existing behavior: downstream Tests go suspect
- New behavior: downstream SourceFile and TestFile nodes also go suspect

This means: when an engineer changes a requirement statement in the spreadsheet, the code that implements it is flagged for review. The developer sees "REQ-001 changed" in the review queue and knows to check whether `src/gps/timeout.c` still satisfies the updated requirement.

When a source file changes (detected by the repo scanner via modification time):
- Upstream requirements do NOT automatically go suspect (code changes are expected during development)
- But: if the annotation is removed (requirement ID disappears from the file), the IMPLEMENTED_IN edge is removed and the requirement gains an "unimplemented" gap

---

## 15. Module Structure

New modules added to the Live source tree:

```
src/
├── ... (existing Live modules)
├── repo.zig              ← Repo watcher: scan loop, file classification, modification tracking
├── annotations.zig       ← Annotation scanner: comment detection, requirement ID extraction
├── git.zig               ← Git CLI wrapper: log, blame, fork/exec, output parsing
├── chain.zig             ← Chain validation: walk industry-specific paths, flag gaps
├── provision.zig         ← Sheet provisioning: create tabs, write headers, apply formatting
```

Estimated new Zig for Live+Repo: ~2,500-3,500 lines across these six modules plus extensions to existing routes, web UI, MCP tools, and renderers.

---

## 16. Implementation Phases

### Phase 1: Repo Watcher + Annotation Scanner (3-4 days)

- `repo.zig`: file system traversal, ignore patterns, file classification, modification time tracking
- `annotations.zig`: comment detection state machine, requirement ID extraction, multi-language support
- New node types (SourceFile, TestFile, CodeAnnotation) in `graph_live.zig`
- New edges (IMPLEMENTED_IN, VERIFIED_BY_CODE, ANNOTATED_AT, CONTAINS)
- Tests: scan a fixture repo with known annotations, verify correct nodes and edges

### Phase 2: Git Integration (2-3 days)

- `git.zig`: fork/exec wrapper, log parsing, blame parsing, timeout handling
- Commit node creation, COMMITTED_IN edges
- Blame attribution on CodeAnnotation nodes
- Incremental scanning (only new commits since last scan)
- Tests: scan a real git repo, verify commit nodes and blame data

### Phase 3: Industry Profiles + Chain Validation + Sheet Provisioning (4-5 days)

- `rtmify.profile` (`sys/lib/src/profile.zig`): shared profile definitions, required chains, gap severity mapping, tab list per profile
- `chain.zig`: walk each required path, collect gaps, classify by profile severity
- `provision.zig`: read existing tabs, diff against profile, create missing tabs via Sheets API, write header rows, apply header formatting
- New gap types in diagnostic.zig (E9xx through E12xx)
- New sheet tabs: Design Inputs, Design Outputs, Configuration Items
- Tab discovery synonyms in schema.zig
- Profile selector in web UI lobby flow (before first sync)
- Tests: fixture data with known chain gaps per profile; provisioning against a test sheet

### Phase 4: Web UI + Reports + MCP (3-4 days)

- Code Traceability tab in index.html
- DHR view for FDA profile
- Extended node drawer for new node types
- Repo configuration panel
- New MCP tools
- Extended RTM report columns
- New DHR report format
- Tests: end-to-end with a fixture repo + fixture spreadsheet

**Total: 12-16 days on top of the Live Zig port.**

---

## 17. What This Is Not

- Not a CI/CD integration. It doesn't trigger builds or run tests. It observes the results.
- Not a code review tool. It doesn't comment on PRs or enforce policy. It records traceability.
- Not a coverage tool. It doesn't measure line or branch coverage. It measures requirement-to-code traceability (which lines of code claim to implement which requirements).
- Not a GitHub/GitLab integration. It reads the local filesystem and the local `.git` directory. No API calls to any VCS hosting provider.
- Not a replacement for the spreadsheet. DesignInput, DesignOutput, and ConfigurationItem tabs are provisioned in the connected Google Sheet automatically based on the selected industry profile. The spreadsheet remains the authoring UI. Live creates the structure; the engineer fills in the content.

---

## 18. Air-Gapped and Classified Deployment

### 18.1 The Problem

Defense programs operating under ITAR, CUI, or at classified levels cannot connect to Google Sheets. The machines are on standalone networks or inside SCIFs with no internet access. Every other ALM tool on the market requires a network connection or a server deployment. Live's Google Sheets dependency would disqualify it from the highest-value market segment.

### 18.2 Local XLSX Mode

Live supports a second input mode: watching a local XLSX file instead of polling Google Sheets. The user starts Live with:

```
rtmify-live --xlsx /path/to/requirements.xlsx
```

Or configures the path in the web dashboard lobby (which is served on loopback regardless of network access).

In this mode:
- The sync thread watches the file's modification timestamp instead of calling the Drive API
- When the file changes, Live re-parses it using the same XLSX parser and schema ingestion logic from Trace (`xlsx.zig` + `schema.zig`)
- All seven input validation layers apply
- The graph updates, gaps are re-evaluated, suspects propagate
- No writeback to the XLSX (the file is read-only input — the engineer edits it in Excel or LibreOffice and saves)
- Status, gaps, and suspect flags are visible in the web dashboard only

### 18.3 Deployment to Classified Networks

The deployment procedure:

1. Install the signed license file on an unclassified machine, or prepare it for manual placement as `~/.rtmify/license.json`
2. Copy three files to approved transfer media (CD-R, USB per site policy):
   - `rtmify-live` (the binary)
   - `~/.rtmify/license.json` (the signed license file)
   - The XLSX spreadsheet
3. Transfer media to the classified machine per the site's data transfer procedures
4. Place files on the classified machine's local drive
5. Run `rtmify-live --xlsx /path/to/requirements.xlsx --no-browser`
6. Open `http://127.0.0.1:8000` in the local browser

The binary never phones home. The license check reads the signed
`license.json` from disk and verifies its HMAC signature locally. There is no
runtime network dependency, no revalidation loop, and no offline grace model.
Perpetual licenses (`expires_at: null`) run indefinitely.

### 18.4 Repo Scanning in Air-Gapped Environments

Git repos on classified networks work identically to unclassified networks. The `.git` directory is on the local filesystem. `git log`, `git blame`, and working tree scanning all operate on local files. No network calls.

The full stack — XLSX input, repo scanning, graph construction, gap analysis, suspect propagation, report generation, MCP endpoint — runs on a machine with no network interface at all.

### 18.5 What This Means for the Market

There is no other product in the requirements management space that can make this deployment claim. Jama requires the internet. DOORS requires a server. Polarion requires Siemens infrastructure. Codebeamer requires PTC infrastructure. Every ALM tool assumes a network.

RTMify Live requires a filesystem and a browser. It runs in a SCIF. This is not a marginal capability. It is a qualitative differentiator for the defense market.

---

## 19. Hardware Artifact Scanning (Future: Live+Hardware)

### 19.1 The Pattern

The same annotation pattern that works for source code works for mechanical and electrical design artifacts. The file formats are local, binary, and stable. The engineer annotates with a requirement ID. The scanner reads the file on disk.

| Domain | Artifact | File Format | Where the annotation goes | Scanner reads |
|--------|----------|-------------|--------------------------|---------------|
| Software | Source code | `.c`, `.py`, `.zig`, etc. | Comment: `// REQ-001` | File contents (text) |
| Software | Git history | `.git/` | Commit message: `REQ-001: ...` | `git log`, `git blame` |
| Mechanical | CAD part/assembly | `.sldprt`, `.sldasm` (SolidWorks) | Custom property: `Requirement = REQ-001` | OLE2 compound document stream |
| Mechanical | CAD drawing | `.slddrw` (SolidWorks) | Custom property or title block field | OLE2 compound document stream |
| Electrical | Schematic | `.SchDoc` (Altium) | Schematic parameter: `Requirement = REQ-001` | OLE2 compound document stream |
| Electrical | PCB layout | `.PcbDoc` (Altium) | Board parameter: `Requirement = REQ-001` | OLE2 compound document stream |
| Electrical | Schematic | `.kicad_sch` (KiCad) | Text field in symbol properties | S-expression text file |
| Documentation | Drawing/spec PDF | `.pdf` | Custom metadata field | PDF metadata dictionary |

### 19.2 Why This Works

SolidWorks `.sldprt` and `.sldasm` files are OLE2 compound documents. Custom properties are stored in a well-known stream inside the OLE2 structure. Reading them requires no SolidWorks installation, no COM API, no Windows dependency. Read the bytes, parse the OLE2 directory, extract the property stream, find the `Requirement` field. This is the same level of effort as parsing an XLSX (which is also a structured binary format).

Altium `.SchDoc` and `.PcbDoc` are also OLE2 compound documents with parameter records following the same pattern.

KiCad files are S-expression text, even simpler to parse than OLE2.

These file formats change slowly. OLE2 hasn't changed in 25 years. SolidWorks has used it since the 1990s. The risk of a breaking format change is lower than the risk of Google changing their Sheets API.

### 19.3 Adoption Path

The adoption conversation with the ME and EE is the same conversation as with the SWE:

"Put the requirement ID in the custom property field you're already filling out."

SolidWorks custom properties are already used at every company for BOM extraction, part numbering, and revision tracking. The field infrastructure exists. The ME is already editing custom properties. Adding `Requirement = REQ-001` is one more field.

Altium schematic parameters serve the same role. The EE already fills in part numbers, values, and tolerances as parameters. Adding a requirement reference is the same gesture.

### 19.4 New Node Types

| Node Type | Description | Properties |
|-----------|-------------|------------|
| `CADPart` | A SolidWorks part or assembly with a requirement annotation | `path`, `format`, `custom_properties`, `last_modified` |
| `CADDrawing` | A SolidWorks drawing linked to a part/assembly | `path`, `format`, `title_block`, `last_modified` |
| `Schematic` | An Altium or KiCad schematic with a requirement annotation | `path`, `format`, `parameters`, `last_modified` |
| `PCBLayout` | An Altium or KiCad PCB layout linked to a schematic | `path`, `format`, `parameters`, `last_modified` |

### 19.5 New Edges

| Edge | From | To | Meaning |
|------|------|----|---------|
| `IMPLEMENTED_IN` | DesignOutput | CADPart | Design output realized in this CAD part |
| `DRAWN_IN` | CADPart | CADDrawing | CAD part documented in this drawing |
| `IMPLEMENTED_IN` | DesignOutput | Schematic | Design output realized in this schematic |
| `LAID_OUT_IN` | Schematic | PCBLayout | Schematic realized in this PCB layout |
| `ANNOTATED_AT` | Requirement | CodeAnnotation | (reused — annotation on hardware file) |

### 19.6 The Full Traceability Chain

With software, mechanical, and electrical scanning, the graph captures the entire product:

```
UN-003  "System shall detect loss of GPS within 500ms"
  └─ REQ-001  (requirement, from spreadsheet)
       └─ DI-001  (design input, from spreadsheet)
            └─ DO-001  "GPS module firmware v1.4" (design output, from spreadsheet)
                 ├─ src/gps/timeout.c:31  (source code, from git repo)
                 │    └─ git blame: jsmith, 2026-02-14, abc123f
                 ├─ GPS_Module.sldprt  (CAD part, from SolidWorks file on disk)
                 │    └─ Custom Property: Requirement = REQ-001
                 └─ GPS_Board.SchDoc  (schematic, from Altium file on disk)
                      └─ Parameter: Requirement = REQ-001
       └─ TG-001  (test group, from spreadsheet)
            └─ T-002  (test, from spreadsheet)
                 └─ test/gps/test_timeout.c  (test code, from git repo)
```

The MCP endpoint exposes the full chain. An engineer asks Claude "show me everything that implements the GPS timeout requirement" and gets the source code, the CAD part, the schematic, the test file, and the git history — all from local files on disk, all linked through the graph.

### 19.7 Implementation Scope

OLE2 parsing is a well-understood problem. The format is documented by Microsoft and has open-source parsers in every language. In Zig, it's byte-level struct parsing — the same kind of work as XLSX/ZIP parsing in `xlsx.zig`. Estimated: 400-600 lines for an OLE2 reader, plus ~200 lines per file format (SolidWorks custom properties, Altium parameters).

KiCad S-expression parsing is simpler: text tokenization. ~150 lines.

Total for hardware scanning: ~1,000-1,500 lines of new Zig. One new scan thread alongside the repo scanner and the Sheets/XLSX sync thread.

### 19.8 Not in v1

Hardware scanning ships after Live+Repo is proven. The infrastructure (scan thread architecture, node/edge creation, MCP tool registration, web UI tabs) is built for Repo and reused for Hardware. The incremental work is the file format parsers.

---

## 20. Product Ladder and Pricing

The full product ladder, each rung building on the one below:

| Product | Price | What it does | Maintenance burden | Deployment |
|---------|-------|-------------|-------------------|------------|
| **Template** | Free | Spreadsheet schema, four tabs, cross-reference conventions | Zero | Download |
| **Trace** | $99-199 once | XLSX → RTM report (PDF, Word, Markdown) | Zero | Single binary |
| **Live** | $299-999 once | Continuous Google Sheets sync, gap analysis, suspect propagation, MCP, web dashboard | Zero | Single binary |
| **Live+Repo** | $4,999 once | + local git working tree scanning, code traceability, industry profiles, DHR generation | Zero | Single binary |
| **Live+Hardware** | $9,999 once | + SolidWorks, Altium, KiCad file scanning, full product traceability | Zero | Single binary |
| **Live+Hardware (Defense)** | $49,999 once | + air-gapped/SCIF deployment support, local XLSX mode, classified network documentation | Zero | Single binary + license.json on approved media |
| **VCS Integration** | TBD/year | GitHub/GitLab/Azure DevOps API polling | Nonzero — API maintenance | Requires network |

Everything above the VCS Integration line is a local binary that reads local files. One-time purchase. Zero infrastructure. Zero recurring costs for the buyer. Zero operational burden for you.

The defense tier at $49,999 is the same binary as Live+Hardware. The price reflects the procurement context (rounding error on a defense contract), the deployment documentation, and the value delivered (replaces $500K/year in audit prep labor). The product is identical. The customer is different.

The VCS Integration line is the boundary. Below it: passive income, shrinkwrap, the product sells itself while you sleep. Above it: API maintenance, a subscription model, the beginning of a job. Build it only if someone offers to pay for it.

### 20.1 Pricing Rationale

| Tier | Buyer | Why this price |
|------|-------|---------------|
| Trace $99-199 | Individual engineer, credit card purchase | Below procurement threshold, impulse buy |
| Live $299-999 | Small team, quality engineer's budget | Still credit card territory, 10x value over manual process |
| Live+Repo $4,999 | Engineering manager, program budget | Replaces one week of audit prep, pays for itself instantly |
| Live+Hardware $9,999 | VP of Engineering, tool budget | Full product traceability, 97% cheaper than Jama annually |
| Defense $49,999 | Program manager, contract line item | Three decimal places below what they're arguing about at CDR |

Every price point is justified by the labor it replaces, not by the cost to produce. The cost to produce is zero after the first binary is compiled. The margin is 95%+ at every tier.
