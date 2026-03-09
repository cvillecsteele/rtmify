# librtmify Input Validation
## PRD: Defensive Parsing for Hostile Spreadsheets
### Version 0.1

---

## 1. Why This Document Exists

The single most expensive thing that can happen to RTMify Trace at a $99 price point is a support email. The second most expensive thing is a user who silently concludes the tool is broken and requests a refund. Both happen for the same reason: the tool choked on their spreadsheet and either crashed, produced garbage, or gave an error message that meant nothing to them.

The user's spreadsheet will be wrong. Not maliciously — just wrong in the way that real spreadsheets maintained by real engineers at real companies are always wrong. Columns in a different order than the template. An extra "Notes" column jammed between B and C. A tab named "Reqs" instead of "Requirements." Trailing spaces in every ID because someone copy-pasted from Word. A BOM character at the start of cell A1 that's invisible in Excel but breaks string comparison. A file that was exported from Google Sheets and has subtly different internal XML than Excel produces. A `.xlsx` that's actually a `.xls` (legacy binary format) that someone renamed. A file that got truncated during a bad OneDrive sync.

Every one of these inputs must produce a clear, specific, actionable error message — or, where possible, must be handled silently and correctly without the user ever knowing there was a problem. The tool should be harder to break than the spreadsheet editor that created the file.

This document specifies every validation layer, every recovery strategy, and every error message. It is the spec for the parsing and validation subsystem of librtmify. It is large on purpose. The entire support model depends on this code being right.

---

## 2. Design Principles

**Fix it if you can. Explain it if you can't. Never crash.**

The tool operates in three modes for every input anomaly:

1. **Silent recovery.** The input is technically wrong but the intent is unambiguous. Fix it. Don't mention it. Trailing whitespace in an ID? Trim it. Tab named "requirements" instead of "Requirements"? Case-insensitive match. Extra columns after H? Ignore them. The user doesn't need to know.

2. **Warning with continuation.** The input is wrong in a way that might affect output quality, but the tool can still produce a useful report. A cross-reference ID that doesn't resolve. A requirement with no statement. A risk with severity "high" instead of a number. Produce the report. Flag the issue in the gap summary. Print a warning to stderr.

3. **Hard error with actionable message.** The input is broken beyond recovery. The file isn't an XLSX. There's no Requirements tab (or anything close to one). Column A doesn't contain IDs. Stop, print exactly what's wrong, and tell the user exactly what to do about it.

**The error message is the product.** At this price point, the error message *is* the support interaction. It must be specific ("Column B in the 'Requirements' tab appears to contain IDs, not statements — are your columns in a different order than expected?"), not generic ("Parse error in Requirements tab"). It must be actionable ("Expected a tab named 'Requirements' — found tabs: Reqs, Tests, Risk Register, User Stories. Did you rename it?"). It must never expose implementation details ("XML parse error at byte offset 4,847 in xl/worksheets/sheet2.xml").

**Validate at the boundary, trust internally.** All validation happens during the parse/load phase. Once data crosses into the Graph, it is known-good. Graph operations never check for malformed input. This keeps the hot path clean and concentrates all defensive code in one place.

---

## 3. Validation Layers

Input validation is organized into seven layers. Each layer runs in order. A hard error at any layer halts processing and reports the failure. Warnings accumulate across layers and are reported in the output.

```
Layer 0: Filesystem          Does the file exist? Can we read it?
Layer 1: Container           Is it a ZIP? Can we decompress it?
Layer 2: XLSX structure      Does it contain the expected XML files?
Layer 3: Tab discovery       Can we find sheets matching our schema?
Layer 4: Column mapping      Can we identify the expected columns in each sheet?
Layer 5: Row parsing         Can we extract typed values from each row?
Layer 6: Semantic validation Is the data internally consistent?
Layer 7: Cross-reference     Do cross-tab references resolve?
```

---

## 4. Layer 0: Filesystem

### Checks

| Check | Recovery | Severity |
|-------|----------|----------|
| Path does not exist | — | Hard error |
| Path is a directory, not a file | — | Hard error |
| File is not readable (permissions) | — | Hard error |
| File is zero bytes | — | Hard error |
| File is suspiciously large (>500MB) | — | Hard error |
| File has wrong extension (.xls, .csv, .ods, .xlsm) | Attempt to parse anyway, warn | Warning |
| File has no extension | Attempt to parse anyway, warn | Warning |

### Error Messages

```
File not found: /path/to/requirements.xlsx
  Check the path and try again.

Cannot read /path/to/requirements.xlsx — permission denied.
  Check file permissions. On macOS, you may need to grant disk access
  in System Preferences → Privacy & Security.

/path/to/requirements is a directory, not a file.
  Point RTMify Trace at the .xlsx file itself, not the folder containing it.

/path/to/requirements.xlsx is empty (0 bytes).
  The file may be corrupted or incompletely downloaded. Try exporting
  a fresh copy from your spreadsheet application.

/path/to/requirements.xls appears to be a legacy Excel format (.xls),
not the modern .xlsx format.
  Open the file in Excel or Google Sheets and re-save as .xlsx
  (File → Save As → Excel Workbook (.xlsx)).

/path/to/data.csv is a CSV file, not an XLSX workbook.
  RTMify Trace reads .xlsx files with multiple tabs. Import your CSV
  into the RTMify Template spreadsheet, or save as .xlsx from Excel.
```

### Notes

The `.xls` case deserves special handling because it will be common. Legacy `.xls` files are not ZIP archives; they use the OLE2 binary compound document format. Detecting them is easy: OLE2 files start with the magic bytes `D0 CF 11 E0 A1 B1 1A E1`. Check for this signature before attempting ZIP parsing and give the specific "re-save as .xlsx" message.

Similarly, detect `.ods` (OpenDocument) files by checking for the ZIP entry `mimetype` containing `application/vnd.oasis.opendocument.spreadsheet`. Give the specific "re-save as .xlsx" message.

The 500MB limit is a sanity check. A legitimate RTM spreadsheet is under 10MB. A 500MB file is either the wrong file or something has gone very wrong.

---

## 5. Layer 1: Container (ZIP)

### Checks

| Check | Recovery | Severity |
|-------|----------|----------|
| File does not start with ZIP magic bytes (`PK\x03\x04`) | — | Hard error |
| ZIP central directory is missing or corrupt | — | Hard error |
| ZIP entries cannot be decompressed (bad deflate stream) | — | Hard error |
| ZIP uses encryption | — | Hard error |
| ZIP uses unsupported compression method (not stored/deflate) | — | Hard error |
| ZIP entry paths contain path traversal (`../`) | Skip entry, warn | Warning |
| ZIP bomb (decompressed size > 100× compressed size AND > 1GB) | — | Hard error |

### Error Messages

```
/path/to/file.xlsx is not a valid .xlsx file — it does not appear to
be a ZIP archive.
  This can happen if the file was renamed from another format, or if
  it was corrupted during transfer. Try re-exporting from your
  spreadsheet application.

/path/to/file.xlsx is a password-protected Excel file.
  Remove the password protection in Excel (File → Info → Protect
  Workbook → Encrypt with Password → clear the password), save,
  and try again.

/path/to/file.xlsx appears to be corrupted — the internal archive
structure is damaged.
  Try opening the file in Excel or Google Sheets and re-saving it.
  If the file won't open there either, restore from a backup.
```

### Notes

Some XLSX files produced by non-Microsoft tools (Google Sheets, LibreOffice, Apache POI) have minor ZIP format deviations: extra data descriptors, slightly nonstandard central directory entries, or missing ZIP64 extensions for files that don't actually need them. The ZIP reader must be tolerant of these. Don't reject a file because its ZIP metadata is slightly nonstandard if the entries themselves decompress correctly.

Specifically: Google Sheets exports sometimes include a data descriptor *after* the local file header even for entries using the STORED method. Some ZIP parsers choke on this. Handle it.

---

## 6. Layer 2: XLSX Structure

### Checks

| Check | Recovery | Severity |
|-------|----------|----------|
| Missing `[Content_Types].xml` | — | Hard error |
| Missing `xl/workbook.xml` | — | Hard error |
| Missing `xl/_rels/workbook.xml.rels` | — | Hard error |
| Missing `xl/sharedStrings.xml` | Treat all cell values as inline strings | Silent recovery |
| `workbook.xml` is not valid XML | — | Hard error |
| Sheet XML file referenced by workbook is missing from ZIP | — per tab, only hard error if all four target tabs are missing | Warning per tab |
| `sharedStrings.xml` is not valid XML | — | Hard error |

### Error Messages

```
/path/to/file.xlsx has the .xlsx extension but does not contain
the expected internal structure.
  This sometimes happens with files exported from older tools.
  Open the file in Excel, make no changes, and re-save it — Excel
  will regenerate the internal structure.

/path/to/file.xlsx is missing internal data (shared strings table).
  The file may have been partially saved or corrupted. Try opening
  in Excel and re-saving.
```

### Notes

`xl/sharedStrings.xml` is technically optional in the OOXML spec. Some minimal XLSX writers (particularly Python libraries like openpyxl writing very small files) can produce valid XLSX files where all string values are inline in the sheet XML. The parser must handle both modes: shared string references (`<c t="s"><v>42</v></c>` where 42 is an index into `sharedStrings.xml`) and inline strings (`<c t="inlineStr"><is><t>hello</t></is></c>`).

The workbook relationship file (`xl/_rels/workbook.xml.rels`) maps relationship IDs (rId1, rId2, ...) to sheet XML filenames. The mapping is not guaranteed to be in order. Sheet "rId1" might be `worksheets/sheet3.xml`. Always follow the relationship chain; never assume `sheet1.xml` is the first tab.

---

## 7. Layer 3: Tab Discovery

This is where most real-world failures will occur. The user has a spreadsheet with tabs, but they're not named exactly what we expect.

### Expected Tab Names

Primary names (exact match, case-insensitive):
- `User Needs`
- `Requirements`
- `Tests`
- `Risks`

### Matching Strategy: Cascading Fuzzy Match

For each expected tab, try the following in order. Stop at the first match.

**Tier 1: Exact match (case-insensitive)**

`user needs` matches `User Needs`, `USER NEEDS`, `user needs`, `User needs`.

**Tier 2: Common synonyms**

| Expected | Synonyms (case-insensitive) |
|----------|---------------------------|
| User Needs | `needs`, `user requirements`, `stakeholder needs`, `user stories`, `stakeholder requirements`, `voice of customer`, `voc` |
| Requirements | `reqs`, `requirements list`, `system requirements`, `functional requirements`, `product requirements`, `req`, `design inputs` |
| Tests | `test plan`, `test cases`, `test matrix`, `verification`, `verification tests`, `test procedures`, `v&v` |
| Risks | `risk register`, `risk analysis`, `risk assessment`, `fmea`, `hazard analysis`, `risk matrix`, `risk log` |

**Tier 3: Substring match**

A tab whose name *contains* the primary name as a substring. `"System Requirements v2"` matches `Requirements`. `"Risk Register (current)"` matches `Risks`. Only match if the substring is the dominant word, not incidental (e.g., `"Testing Requirements"` should match `Requirements`, not `Tests` — match on longest substring first).

**Tier 4: Levenshtein distance ≤ 2**

`Requirments` (typo) matches `Requirements`. `Tets` matches `Tests`. Only apply this to the primary name, not synonyms.

### Conflict Resolution

If multiple discovery tiers match different tabs to the same expected name, prefer the lower-numbered tier. If two tabs match at the same tier, it's ambiguous — hard error listing both candidates.

If a tab matches two expected names (e.g., `"Test Requirements"` could match both `Tests` and `Requirements`), assign it to whichever expected name has the longer substring match, or to the expected name that has no other candidate.

### Required vs. Optional Tabs

- `Requirements` is **required.** Without it, there's no RTM to trace. Hard error.
- `User Needs`, `Tests`, `Risks` are **optional.** If missing, the report generates without that section and includes a note: "No User Needs tab found — DERIVES_FROM traceability not available."

### Error Messages

```
No 'Requirements' tab found.
  Found tabs: Sheet1, Sheet2, Sheet3
  RTMify Trace expects a tab named 'Requirements' (or 'Reqs',
  'System Requirements', etc.) containing your requirement rows.
  Rename one of your tabs or use the RTMify Template.

Ambiguous tab match: both 'System Reqs' and 'Product Requirements'
could be the Requirements tab.
  Rename one of them so RTMify Trace can tell which is which, or
  rename the one you want to 'Requirements'.

Matched tab 'Requirments' as 'Requirements' (possible typo).
  Processing will continue. Consider renaming the tab to avoid
  this warning in future runs.
```

### Notes

The synonym list will grow over time based on what actual users name their tabs. Ship with the initial list above, and instrument the tool to log (locally, never uploaded) which synonym or fuzzy match was used. If the porcelain GUI ships, it can show "Matched 'Reqs' → Requirements — is this correct?" with a confirmation step.

---

## 8. Layer 4: Column Mapping

Once we've identified the sheet, we need to find the expected columns. Users will have extra columns, missing optional columns, reordered columns, and renamed columns.

### Matching Strategy

**Do not assume column order.** The template defines columns A through G (or H), but real users will have inserted columns, deleted columns, or rearranged them. Column position is a hint, not an authority.

**Step 1: Read the header row.**

Row 1 of each sheet is the header. Read all cell values in row 1. Trim whitespace. Lowercase for comparison.

**Step 2: Match by header text.**

For each expected column, maintain a list of acceptable header names:

**Requirements tab:**

| Expected Field | Acceptable Headers (case-insensitive, trimmed) |
|---------------|----------------------------------------------|
| ID | `id`, `req id`, `requirement id`, `req #`, `#`, `identifier`, `req`, `requirement number`, `item` |
| Statement | `statement`, `requirement`, `requirement statement`, `description`, `req statement`, `shall statement`, `text`, `requirement text`, `req description` |
| Source | `source`, `parent`, `parent need`, `user need`, `user need id`, `derives from`, `origin`, `traced from`, `un`, `un id` |
| Priority | `priority`, `pri`, `importance`, `criticality`, `level` |
| Test Group ID | `test group`, `test group id`, `test id`, `test`, `verification`, `verification id`, `test ref`, `tested by`, `vt`, `vt id`, `test reference` |
| Status | `status`, `state`, `maturity`, `review status`, `approval`, `lifecycle` |
| Notes | `notes`, `comments`, `remarks`, `note` |

**User Needs tab:**

| Expected Field | Acceptable Headers |
|---------------|-------------------|
| ID | `id`, `need id`, `un id`, `user need id`, `#`, `identifier`, `item` |
| Statement | `statement`, `need`, `user need`, `description`, `text`, `need statement` |
| Source | `source`, `origin`, `stakeholder`, `customer` |
| Priority | `priority`, `pri`, `importance`, `criticality`, `level` |

**Tests tab:**

| Expected Field | Acceptable Headers |
|---------------|-------------------|
| Test Group ID | `test group`, `test group id`, `group`, `group id`, `tg`, `tg id`, `test suite` |
| Test ID | `test id`, `test`, `id`, `test case`, `test #`, `tc id`, `test case id`, `item` |
| Type | `type`, `test type`, `category`, `level`, `test level` |
| Method | `method`, `test method`, `verification method`, `approach`, `technique` |

**Risks tab:**

| Expected Field | Acceptable Headers |
|---------------|-------------------|
| ID | `id`, `risk id`, `risk #`, `#`, `identifier`, `hazard id`, `item` |
| Description | `description`, `risk`, `risk description`, `hazard`, `failure mode`, `risk statement` |
| Initial Severity | `initial severity`, `severity`, `sev`, `init sev`, `initial sev`, `s`, `pre-mitigation severity`, `inherent severity` |
| Initial Likelihood | `initial likelihood`, `likelihood`, `prob`, `probability`, `init prob`, `initial prob`, `occ`, `occurrence`, `p`, `pre-mitigation likelihood`, `inherent likelihood` |
| Mitigation | `mitigation`, `control`, `control measure`, `risk control`, `mitigation measure`, `action`, `treatment` |
| Linked Req | `linked req`, `requirement`, `req`, `req id`, `mitigated by`, `addressed by`, `control requirement`, `mitigation req` |
| Residual Severity | `residual severity`, `res sev`, `residual sev`, `post-mitigation severity`, `final severity` |
| Residual Likelihood | `residual likelihood`, `res prob`, `residual prob`, `res likelihood`, `post-mitigation likelihood`, `final likelihood` |

**Step 3: Handle ambiguous matches.**

If a header matches two expected fields (e.g., `"ID"` in the Tests tab could match Test Group ID or Test ID), use column position as a tiebreaker: the leftmost match wins for the first expected field in the schema.

If two headers in the same sheet match the same expected field, use the leftmost one and warn.

**Step 4: Handle missing required columns.**

For each tab, only the ID column and one content column (Statement/Description/Test ID) are required. All other columns are optional. Missing optional columns are treated as empty for every row.

If the ID column can't be found, try a heuristic: look for the column where the most cells match the pattern `XX-NNN` or `XXX-NNN` (letters, hyphen, digits). If found, use it as the ID column and warn.

If neither header matching nor the heuristic identifies an ID column, hard error for that tab.

**Step 5: Handle extra columns.**

Columns that don't match any expected field are silently ignored. Never error on extra columns. Users put all kinds of stuff in their spreadsheets (internal notes, conditional formatting helpers, old columns they forgot to delete). Ignoring unknown columns is the single most important tolerance behavior.

### Error Messages

```
Cannot identify columns in the 'Requirements' tab.
  Row 1 (header): "Item Number", "Desc", "Cat", "Owner", "Due Date"
  Expected: an 'ID' column and a 'Statement' column at minimum.
  RTMify Trace maps columns by header text, not by position.
  Rename your headers to match the RTMify Template, or add a header
  row if row 1 contains data.

Found 'ID' column in Requirements tab (column A), but cannot
identify a 'Statement' column.
  Row 1 headers: "ID", "Category", "Owner", "Priority", "Notes"
  Expected one of: 'Statement', 'Requirement', 'Description', etc.
  Which column contains your requirement text?

Multiple columns match 'ID' in the Requirements tab: column A ("ID")
and column D ("Req ID"). Using column A (leftmost).
```

### Notes

The header matching lists will grow. Every time a user's spreadsheet doesn't match, the header that *should* have matched becomes a candidate for the synonym list. The synonym lists above are a starting point based on common conventions in AS9100, ISO 13485, and DO-178C documentation.

The heuristic ID detection (pattern `XX-NNN`) is a fallback. It catches the case where someone has an ID column but named it something we didn't anticipate, like `"Item"` or `"Reference"` or just left it blank.

---

## 9. Layer 5: Row Parsing

Header is mapped. Now parse the data rows.

### Cell Value Extraction

Each cell can contain:

| XLSX Cell Type | XML Attribute | Handling |
|---------------|--------------|---------|
| Shared string | `t="s"` | Look up index in sharedStrings.xml |
| Inline string | `t="inlineStr"` | Extract from `<is><t>` element |
| Number | `t="n"` or no `t` attribute | Read as float, format as string |
| Boolean | `t="b"` | `1` → `"TRUE"`, `0` → `"FALSE"` |
| Error | `t="e"` | Treat as empty, warn |
| Formula result | `<f>` element | Use the cached value in `<v>`, ignore the formula |
| Date | Number with date format | Detect via style reference, convert Excel serial date to ISO 8601 |
| Empty/missing | Cell element absent for that column | Treat as empty string |

### Normalization (Silent Recovery)

Apply these normalizations to every cell value before further processing. None of these produce warnings. They are invisible to the user.

| Input | Normalized | Why |
|-------|-----------|-----|
| Leading/trailing whitespace | Trimmed | Copy-paste from Word, PDF, email |
| BOM character (`\uFEFF`) at start of string | Stripped | Google Sheets export, CSV import artifacts |
| Non-breaking space (`\u00A0`) | Replaced with regular space | Copy-paste from web pages, Word |
| Smart quotes (`\u201C`, `\u201D`, `\u2018`, `\u2019`) | Replaced with ASCII quotes | Copy-paste from Word, macOS autocorrect |
| En dash (`\u2013`), em dash (`\u2014`) | Replaced with ASCII hyphen | Copy-paste from Word |
| Multiple consecutive spaces | Collapsed to single space | Alignment attempts in cells |
| Newline characters (`\n`, `\r\n`, `\r`) within a cell | Replaced with space | Multi-line cell values (Alt+Enter in Excel) |
| Tab characters | Replaced with space | Paste from TSV or tab-indented text |
| Null character (`\x00`) | Stripped | Corrupt data, binary artifacts |
| Zero-width characters (`\u200B`, `\u200C`, `\u200D`, `\uFEFF` mid-string) | Stripped | Copy-paste from web, rich text editors |

### ID Normalization (Silent Recovery, Additional)

ID fields (any column mapped to an ID role) get additional normalization:

| Input | Normalized | Why |
|-------|-----------|-----|
| Leading zeros: `REQ-001` vs `REQ-1` | Preserved as-is (string comparison) | Both are valid; don't collapse |
| Mixed case: `req-001` vs `REQ-001` | **Uppercase for matching, preserve original for display** | Cross-references should match case-insensitively |
| Leading/trailing hyphens: `-REQ-001` | Stripped | Typo |
| Parenthetical suffix: `REQ-001 (old)` | Use `REQ-001`, warn | User annotated the ID |
| Entire value is whitespace | Treat as empty | Spacebar in cell |

### Row-Level Checks

| Check | Recovery | Severity |
|-------|----------|----------|
| Row is entirely empty (all cells blank) | Skip silently | Silent |
| ID cell is empty, but other cells have content | Skip row, warn | Warning |
| ID cell contains only whitespace | Skip row, warn | Warning |
| ID is a duplicate of a previous row | Keep first occurrence, skip duplicate, warn | Warning |
| Required content field (Statement/Description) is empty | Create node with empty field, warn | Warning |
| Numeric field (severity, likelihood) contains non-numeric text | Store as-is, warn; attempt to parse common text values | Warning |
| Row appears to be a sub-header or section divider | Skip silently | Silent |
| Row contains a formula error (#REF!, #N/A, #VALUE!) | Treat cell as empty, warn | Warning |

### Detecting Sub-Headers and Section Dividers

Users insert visual structure into spreadsheets: merged cells used as section headers, rows with bold text and no ID, rows containing "---" or "Section 2: Performance Requirements". These are not data rows.

Heuristic: a row is a section divider if:
- The ID cell is empty AND
- Exactly one cell in the row has content AND
- That content does not match the format of a requirement statement (too short, no verb, all caps, contains "section" or "---" or "===")

OR:
- The ID cell contains text that doesn't match the ID pattern of other rows in the same tab (e.g., other IDs are `REQ-NNN` but this one says `"Performance Requirements"`)

Skip these rows silently. They are visual formatting, not data.

### Numeric Field Parsing

Severity and likelihood fields should be integers 1-5, but users will write all kinds of things:

| Input | Parsed Value | Action |
|-------|-------------|--------|
| `3` | 3 | OK |
| `3.0` | 3 | Silent (Excel stores integers as floats) |
| `3.5` | 3.5 | Warn: "Severity 3.5 for RSK-001 — expected integer 1-5" |
| `high` | Attempt mapping: high=4, medium=3, low=2, negligible=1, critical=5, catastrophic=5 | Warn: "Converted severity 'high' to 4 for RSK-001" |
| `H` | Attempt mapping: H=4, M=3, L=2 | Warn with conversion |
| `III` | Attempt mapping: Roman numeral → integer | Warn with conversion |
| `` (empty) | null | OK (optional field) |
| `N/A` | null | Silent |
| `TBD` | null | Silent, record as gap |
| Anything else | null | Warn: "Could not parse severity 'banana' for RSK-001 — treating as blank" |

### Error Messages

```
Row 14 in 'Requirements' has content but no ID in column A.
  Skipped. Add an ID (e.g., REQ-014) to include this row.

Duplicate ID 'REQ-003' in Requirements tab (rows 5 and 12).
  Kept row 5, skipped row 12. Each requirement needs a unique ID.

Severity value 'high' for RSK-007 converted to 4 (high=4 on a 1-5 scale).
  Use numeric values 1-5 for consistent scoring.

Cell D8 in 'Risks' contains a formula error (#REF!).
  Treated as blank. Fix the formula in your spreadsheet.
```

---

## 10. Layer 6: Semantic Validation

The data is parsed. Now check whether it makes sense.

### Requirement Quality Warnings

These are not blockers. They produce warnings in the gap summary.

| Check | Condition | Warning Text |
|-------|-----------|-------------|
| Missing statement | Statement field is empty or whitespace-only | "REQ-001 has no requirement statement" |
| Not a SHALL statement | Statement doesn't contain "shall" (case-insensitive) | "REQ-001 may not be a proper SHALL statement — no 'shall' found" |
| Compound requirement | Statement contains "shall" more than once | "REQ-003 may be a compound requirement (multiple 'shall' clauses) — consider splitting" |
| Ambiguous language | Statement contains: "appropriate", "adequate", "reasonable", "user-friendly", "fast", "reliable", "safe", "sufficient", "timely", "as needed", "if necessary", "etc.", "and/or" | "REQ-005 contains ambiguous language ('appropriate') — may not be verifiable" |
| Very short statement | Statement is under 10 characters | "REQ-009 statement is very short — is it complete?" |
| Status is 'obsolete' but has active traces | Status field = obsolete but TESTED_BY or DERIVES_FROM edges exist | "REQ-012 is marked obsolete but has active test and traceability links" |

### Risk Register Quality Warnings

| Check | Condition | Warning Text |
|-------|-----------|-------------|
| Severity without likelihood (or vice versa) | One is populated, the other is empty | "RSK-003 has severity but no likelihood — risk score cannot be computed" |
| Score > 12 with no mitigation | (sev × likelihood) > 12 and mitigation field is empty | "RSK-005 has a high initial risk score (15) with no mitigation described" |
| Residual score > initial score | Residual sev × lik > initial sev × lik | "RSK-007 residual risk (12) is higher than initial risk (9) — check values" |
| Residual severity/likelihood without initial | Residual values present but initial values empty | "RSK-008 has residual scores but no initial scores" |

### Test Quality Warnings

| Check | Condition | Warning Text |
|-------|-----------|-------------|
| Test group with no tests | TestGroup node has no HAS_TEST edges | "Test group TG-003 has no individual tests listed" |
| Test with no group | Test ID present but Test Group ID empty | "Test T-015 has no test group — orphaned test" |
| Duplicate test IDs across groups | Same Test ID appears in multiple rows with different groups | "Test ID T-007 appears in both TG-001 and TG-003" |

---

## 11. Layer 7: Cross-Reference Resolution

Cross-references are the traceability chain. This is where the RTM comes from. It's also where the most subtle bugs hide.

### Resolution Rules

A cross-reference field contains an ID string that should match a node in another tab. Resolution is:

1. Trim and normalize the reference string (same normalization as IDs).
2. Look up the normalized string in the target node set, **case-insensitively**.
3. If found: create the edge. If not found: record as unresolved reference.

### Common Cross-Reference Problems

| Problem | Example | Handling |
|---------|---------|---------|
| ID exists but in the wrong tab | Requirements Source column says "REQ-005" (another requirement, not a user need) | Warn: "REQ-001 source 'REQ-005' matches a Requirement, not a User Need — did you mean a User Need ID?" |
| Multiple IDs in one cell | `"UN-001, UN-002"` or `"UN-001; UN-002"` or `"UN-001 / UN-002"` | **Parse as multiple references.** Split on `,`, `;`, `/`, `\n`. Trim each. Create an edge for each. |
| ID with extra text | `"UN-001 (see also UN-003)"` | Extract all ID-like tokens (pattern: letters + hyphen + digits). Create edges for each. Warn about the extra text. |
| ID with embedded newline | `"UN-001\nUN-002"` (Alt+Enter in Excel) | Split on newline, trim, resolve each |
| ID references a node that hasn't been created yet | Requirements tab processed before User Needs tab | **Process all tabs and create all nodes first, resolve cross-references second.** (The construction sequence in Section 6.2 already specifies this.) |
| ID matches multiple nodes | Shouldn't happen if IDs are unique, but could if same ID exists across tabs | Match against the expected target type only. Requirements Source column only resolves against UserNeed nodes. |
| Empty cross-reference field | Source column is blank | Not an error. Record as a gap (orphan requirement). |
| Cross-reference field contains "N/A", "TBD", "—", "-", "none" | Explicit "no link" | Treat as empty. Not an error, not a gap. Record as intentionally unlinked. |
| Cross-reference field contains a cell formula result | `=VLOOKUP(...)` that resolved to the right ID | Already handled — we read the cached formula result in Layer 5. |
| Cross-reference field contains a formula error | `#REF!` because the lookup table was deleted | Treat as empty, warn. Record as a gap. |

### Error Messages

```
REQ-001 references source 'UN-099', but no User Need with that ID exists.
  Check the ID in column C of the Requirements tab.
  Available User Needs: UN-001, UN-002, UN-003, UN-004, UN-005
  (showing first 5 of 23)

REQ-005 references source 'REQ-002', which is a Requirement, not a User Need.
  The Source column should contain a User Need ID (e.g., UN-001).
  Did you mean to reference a User Need instead?

REQ-010 has multiple sources in one cell: "UN-001, UN-002".
  Created traceability links to both. Consider using one row per
  requirement-to-need link for cleaner traceability.

RSK-004 references linked requirement 'REQ-050', but that requirement
does not exist.
  Available Requirements: REQ-001 through REQ-047
  Check the ID in column F of the Risks tab.
```

### Notes

The "Available User Needs: ..." message with a truncated list is deliberate. It gives the user enough context to spot a typo (they typed `UN-099` and can see the list goes up to `UN-005`) without dumping 500 IDs to the terminal. Show first 5, note the total count.

Listing available IDs also catches the case where the user put IDs in the Source column that use a different prefix convention than the User Needs tab. They wrote `NEED-001` in the Source column but the User Needs tab uses `UN-001`. The mismatch is visible in the error message.

---

## 12. Mega-Category: Things That Aren't XLSX Files

The tool will be invoked on files that are not XLSX. Sometimes deliberately (user confused about file formats), sometimes accidentally (dragged the wrong file). Each impersonator gets a specific message.

### Detection and Messages

| Input | Detection Method | Message |
|-------|-----------------|---------|
| `.xls` (Excel 97-2003) | OLE2 magic bytes: `D0 CF 11 E0` | "This is a legacy .xls file. Re-save as .xlsx from Excel." |
| `.xlsm` (macro-enabled) | Valid ZIP, contains `xl/vbaProject.bin` | "This is a macro-enabled .xlsm file. RTMify Trace can read it, but macros will be ignored." (Process normally — it's structurally identical to .xlsx.) |
| `.xlsb` (binary workbook) | OLE2 or ZIP with binary sheet format | "This is a binary .xlsb file. Re-save as .xlsx from Excel." |
| `.ods` (OpenDocument) | ZIP with `mimetype` = `application/vnd.oasis.opendocument.spreadsheet` | "This is an OpenDocument .ods file. Re-save as .xlsx from your spreadsheet application." |
| `.csv` | No ZIP magic, text content with delimiters | "This is a CSV file, not an XLSX workbook. RTMify Trace needs a multi-tab .xlsx file." |
| `.tsv` | No ZIP magic, text content with tabs | Same as CSV |
| `.numbers` (Apple Numbers) | ZIP containing `Index/Tables/` | "This is an Apple Numbers file. Export as .xlsx from Numbers (File → Export To → Excel)." |
| `.pdf` | `%PDF` magic bytes | "This is a PDF, not a spreadsheet." |
| `.docx` | ZIP containing `word/document.xml` | "This is a Word document, not a spreadsheet. RTMify Trace reads .xlsx files." |
| `.pptx` | ZIP containing `ppt/presentation.xml` | "This is a PowerPoint file, not a spreadsheet." |
| `.zip` (generic) | Valid ZIP, no XLSX or OOXML structure inside | "This is a ZIP archive but not an Excel file." |
| Random binary | No recognized magic bytes, not valid ZIP | "This file is not a recognized spreadsheet format." |
| Text file renamed to .xlsx | No ZIP magic, ASCII/UTF-8 content | "This appears to be a text file renamed to .xlsx. It needs to be an actual Excel workbook." |
| Empty file | 0 bytes | "This file is empty (0 bytes)." |
| HTML renamed to .xlsx | `<html` or `<!DOCTYPE` near start | "This appears to be an HTML file renamed to .xlsx." (Common: some web apps "export to Excel" by generating an HTML table with an .xlsx extension. Excel opens these fine; they are not XLSX.) |

### The HTML-as-XLSX Problem

This one is insidious and deserves special attention. Many web applications generate "Excel exports" that are actually HTML tables with a `.xlsx` extension. Excel opens them without complaint (it sniffs the content and renders the HTML table). But they are not ZIP archives and will fail at Layer 1.

Detection: if the file is not a valid ZIP, read the first 1,024 bytes as text. If they contain `<html`, `<table`, `<tr`, or `<!DOCTYPE`, it's an HTML file masquerading as XLSX.

Message:
```
This file has an .xlsx extension but is actually an HTML file — a common
"fake Excel" export from web applications. Excel can open it, but it's
not a true .xlsx workbook.

To convert: open this file in Excel, then File → Save As → choose
"Excel Workbook (.xlsx)" as the format. This creates a real .xlsx file
that RTMify Trace can read.
```

---

## 13. Encoding and Character Nightmares

### UTF-8 Expectations

XLSX XML files are always UTF-8 (per the OOXML spec). But:

- Some XLSX writers produce XML with an explicit `encoding="UTF-8"` declaration; others omit it (defaulting to UTF-8 per the XML spec). Handle both.
- The shared strings table can contain any Unicode character. The Zig XML parser must handle the full UTF-8 range.
- Cell values may contain XML entities: `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`. The XML parser handles these, but verify they're decoded correctly before string comparison.
- Numeric character references (`&#x2019;`, `&#8217;`) must also be decoded.

### Encoding Mismatches in Cell Values

Even though the XML is UTF-8, the *content* of cells may have been pasted from sources with different encodings:

| Problem | Example | Handling |
|---------|---------|---------|
| Latin-1 characters stored as UTF-8 | `"Ã©"` instead of `"é"` (double-encoded UTF-8) | Detect mojibake pattern, attempt repair, warn |
| Windows-1252 smart quotes | Already handled by normalization (Layer 5) | Silent |
| Chinese/Japanese/Korean characters in IDs | `"要求-001"` | Fully supported — UTF-8 handles this natively |
| RTL characters (Arabic, Hebrew) | `"REQ-001 متطلب"` | Supported in data; display direction is the output renderer's problem |

### The BOM Plague

The Byte Order Mark (`\uFEFF`) appears in three places:

1. At the start of the XML file itself — the XML parser should ignore it.
2. At the start of a cell value in `sharedStrings.xml` — strip it during normalization.
3. In the middle of a cell value (rare but possible from bad copy-paste chains) — strip it.

Always strip `\uFEFF` everywhere. It has no valid use in an XLSX cell value.

---

## 14. The Validation Report

Every warning and error accumulated across all seven layers is compiled into a validation report. This report appears in three places:

### 1. stderr (CLI output)

Warnings and errors printed to stderr during processing. Errors stop processing; warnings accumulate. Format:

```
[WARN] Requirements row 14: no ID in column A — skipped
[WARN] Requirements row 17: duplicate ID 'REQ-003' — skipped (keeping row 5)
[WARN] Cross-reference: REQ-001 source 'UN-099' not found
[WARN] Semantic: REQ-005 contains ambiguous language ('appropriate')
[INFO] Matched tab 'Reqs' → Requirements (synonym match)
[INFO] Matched tab 'Risk Register' → Risks (synonym match)

Processed: 47 requirements, 23 user needs, 15 test groups, 42 tests, 12 risks
Warnings: 4
Gaps: 7 (3 untested requirements, 2 orphan requirements, 2 unmitigated risks)
Output: ./requirements-rtm.pdf
```

### 2. Gap Summary in the output document

The output document (PDF, DOCX, MD) includes a "Validation & Gaps" section at the end containing:

- Summary counts (N untested requirements, N orphan requirements, N unresolved references, etc.)
- Per-gap detail: node ID, gap type, human-readable explanation
- Warnings from semantic validation (ambiguous language, compound requirements, etc.)

### 3. Machine-readable gap report (optional, `--gaps-json`)

For CI integration, an optional JSON output of all gaps and warnings:

```json
{
  "input": "requirements.xlsx",
  "timestamp": "2026-03-08T14:22:00Z",
  "counts": {
    "requirements": 47,
    "user_needs": 23,
    "test_groups": 15,
    "tests": 42,
    "risks": 12
  },
  "gaps": [
    {"type": "untested_requirement", "node_id": "REQ-012", "detail": "No TESTED_BY edge"},
    {"type": "orphan_requirement", "node_id": "REQ-031", "detail": "No DERIVES_FROM edge"},
    {"type": "unresolved_reference", "node_id": "REQ-041", "field": "source", "value": "UN-099"}
  ],
  "warnings": [
    {"layer": "semantic", "node_id": "REQ-005", "message": "Contains ambiguous language ('appropriate')"}
  ]
}
```

---

## 15. Testing This Subsystem

The input validation subsystem gets its own dedicated test suite, separate from the graph and report tests. Fixtures are organized by layer and failure mode.

### Fixture Categories

**Layer 0 fixtures:**
- `not-a-file.xlsx` → nonexistent path
- `empty.xlsx` → 0-byte file
- `actually-a-pdf.xlsx` → PDF with .xlsx extension
- `actually-html.xlsx` → HTML table with .xlsx extension
- `actually-xls.xlsx` → OLE2 binary Excel with .xlsx extension
- `actually-csv.xlsx` → CSV with .xlsx extension
- `readonly.xlsx` → valid file with read-only permissions (platform-dependent)
- `huge.xlsx` → 600MB file (over size limit)

**Layer 1 fixtures:**
- `corrupt-zip.xlsx` → valid ZIP header, corrupt central directory
- `truncated.xlsx` → valid start, truncated mid-file
- `password-protected.xlsx` → encrypted XLSX
- `zip-bomb.xlsx` → tiny compressed, huge decompressed

**Layer 2 fixtures:**
- `missing-content-types.xlsx` → ZIP but no `[Content_Types].xml`
- `missing-workbook.xlsx` → no `xl/workbook.xml`
- `no-shared-strings.xlsx` → valid XLSX with inline strings only
- `google-sheets-export.xlsx` → exported from Google Sheets
- `libreoffice-export.xlsx` → exported from LibreOffice Calc
- `numbers-export.xlsx` → exported from Apple Numbers via .xlsx

**Layer 3 fixtures:**
- `renamed-tabs.xlsx` → tabs named "Reqs", "Risk Register", "V&V", "Stakeholder Needs"
- `typo-tabs.xlsx` → tabs named "Requirments", "Tets"
- `missing-optional-tabs.xlsx` → only Requirements tab present
- `extra-tabs.xlsx` → expected tabs plus "Scratch", "Archive", "Pivot Table"
- `all-wrong-tabs.xlsx` → no tab name matches anything

**Layer 4 fixtures:**
- `reordered-columns.xlsx` → correct headers but in wrong order (Statement in A, ID in C)
- `extra-columns.xlsx` → expected columns plus "Owner", "Due Date", "Reviewed By"
- `renamed-headers.xlsx` → columns named "Req #", "Shall Statement", "Verification Ref"
- `no-headers.xlsx` → data starts in row 1, no header row
- `merged-header-cells.xlsx` → header row has merged cells spanning two columns
- `missing-required-columns.xlsx` → no ID column, no Statement column

**Layer 5 fixtures:**
- `unicode-ids.xlsx` → IDs with non-ASCII characters
- `whitespace-ids.xlsx` → IDs with leading/trailing spaces, tabs, BOM
- `duplicate-ids.xlsx` → same ID appears in multiple rows
- `formula-cells.xlsx` → cells containing formulas (=VLOOKUP, =IF, etc.)
- `formula-errors.xlsx` → cells containing #REF!, #N/A, #VALUE!
- `mixed-types.xlsx` → severity column with "high", "3", "H", "III", "TBD"
- `section-dividers.xlsx` → rows used as visual section headers
- `blank-rows.xlsx` → scattered empty rows between data rows
- `smart-quotes.xlsx` → requirement statements with Word-style smart quotes
- `multiline-cells.xlsx` → cells with Alt+Enter newlines
- `trailing-rows.xlsx` → 50 rows of data, then 500 empty rows (Excel default)

**Layer 6 fixtures:**
- `compound-requirements.xlsx` → requirements with multiple "shall" clauses
- `ambiguous-requirements.xlsx` → requirements using "appropriate", "reliable", etc.
- `obsolete-with-traces.xlsx` → obsolete requirements still linked to tests
- `risk-score-inconsistencies.xlsx` → residual > initial, missing pairs

**Layer 7 fixtures:**
- `broken-references.xlsx` → cross-reference IDs that don't exist
- `wrong-type-references.xlsx` → source column containing REQ IDs instead of UN IDs
- `multi-reference-cells.xlsx` → cells with "UN-001, UN-002" and "UN-003 / UN-004"
- `case-mismatch-references.xlsx` → ID is "UN-001", reference says "un-001"
- `circular-references.xlsx` → requirement A derives from need B, but "need B" is actually a requirement ID

### Golden File Tests

For each fixture that should process successfully (with warnings), maintain a golden file of expected:
- Warning messages (exact text)
- Constructed graph (node count, edge count, gap count)
- Gap report (JSON)

Tests compare actual output against golden files. Any change to validation behavior is immediately visible as a golden file diff.

### Fuzz Testing

In addition to hand-crafted fixtures, generate malformed XLSX files programmatically:
- Take a valid fixture, corrupt random bytes in the ZIP stream
- Take a valid fixture, truncate at random byte offsets
- Take a valid fixture, shuffle ZIP entries
- Take a valid fixture, replace sharedStrings.xml with garbage
- Generate random ZIP files with XLSX-like entry names but random XML content

The fuzz target is: **the tool never crashes.** It may produce unhelpful error messages on truly random input, but it must exit cleanly with a nonzero exit code. No segfaults. No panics. No infinite loops. No memory corruption. Zig's safety-checked release mode (`ReleaseSafe`) helps here — bounds checks remain active.

---

## 16. Performance Budget

Input validation should not dominate processing time. Targets for a 1,000-requirement spreadsheet on a 2020-era laptop:

| Phase | Budget |
|-------|--------|
| ZIP decompression | < 100ms |
| XML parsing (all tabs) | < 200ms |
| Normalization + column mapping | < 50ms |
| Graph construction | < 50ms |
| Cross-reference resolution | < 50ms |
| Semantic validation | < 50ms |
| **Total parse + validate** | **< 500ms** |

Report generation is separate and has its own budget. The user should never wait more than one second for the validation phase, even with warnings.

The fuzzy tab matching (Levenshtein distance) is O(n×m) per tab name comparison. With ~4 expected names and ~20 actual tabs (generous), this is negligible. Do not optimize it.

---

## 17. Summary of Severity Levels

For quick reference, here is every check across all layers, sorted by severity:

### Hard Errors (processing stops, no output)

- File not found / not readable / empty / too large
- Not a ZIP archive (and not a recognized alternative format)
- ZIP is encrypted or corrupt beyond recovery
- Missing `[Content_Types].xml` or `xl/workbook.xml`
- No tab matches or fuzzy-matches to "Requirements"
- Cannot identify ID column in Requirements tab (neither by header nor by heuristic)
- License invalid

### Warnings (processing continues, flagged in output)

- File extension mismatch (.xlsm treated as .xlsx, etc.)
- Tab matched by synonym, substring, or typo correction
- Column matched by synonym rather than primary name
- Duplicate IDs (first wins)
- Rows skipped (no ID, section divider)
- Numeric fields parsed from text ("high" → 4)
- Unresolved cross-references
- Cross-reference to wrong node type
- Multiple IDs in one cross-reference cell
- Requirement quality issues (ambiguous language, compound, missing statement)
- Risk score inconsistencies
- Formula errors in cells
- Encoding anomalies (mojibake detected, BOM stripped)

### Silent Recovery (no user-visible indication)

- Whitespace trimming
- BOM stripping
- Smart quote normalization
- Non-breaking space replacement
- Zero-width character stripping
- Extra columns ignored
- Extra tabs ignored
- Empty rows skipped
- Trailing empty rows ignored
- sharedStrings.xml missing (inline strings used instead)
- Formula cells (cached value used)
- "N/A" / "TBD" / "—" in cross-reference fields treated as intentionally blank