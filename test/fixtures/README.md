# Fixture Inventory

- `RTMify_Requirements_Tracking_Template.xlsx`
  - Minimal legacy 4-tab workbook used by existing parser/render tests.

- `RTMify_Test_Sheet_Realistic.xlsx`
  - Realistic user-provided workbook copied from `/Users/colinsteele/Downloads/RTMify Test Sheet.xlsx`.
  - Use for parser and ingest smoke tests against nontrivial real-world XLSX structure.

- `RTMify_Profile_Tabs_Golden.xlsx`
  - Deterministic 7-tab workbook covering:
    - `User Needs`
    - `Requirements`
    - `Tests`
    - `Risks`
    - `Design Inputs`
    - `Design Outputs`
    - `Configuration Items`
  - Intended for golden-path integration tests of the extended profile-tab model.

- `RTMify_Profile_Tabs_Errors.xlsx`
  - Deterministic 7-tab workbook with intentional data defects.
  - Intended for integration tests that assert diagnostics from the extended profile-tab shape.

- `golden_rtm.md`
  - Golden Markdown render output for the minimal template workbook.
