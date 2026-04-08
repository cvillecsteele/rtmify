# libreqif

`libreqif` is a standalone Zig library for parsing ReqIF `.reqif` and `.reqifz` files into structured in-memory data.

It does not depend on Trace, Live, UI code, or networked services. It only answers:

- what header metadata is present
- what datatypes and ReqIF types are defined
- what SpecObjects, SpecRelations, and Specifications exist
- what resolved attribute values those records carry
- whether a built-in semantic profile can safely project graph-ready requirement assertions

## v1 scope

- `.reqif` bytes and file-path parsing
- `.reqifz` bytes and file-path parsing
- root namespace support for `20110401` and `20101201`
- ref resolution for attribute definitions, datatypes, enum values, and ReqIF type names
- plain-text extraction from XHTML attribute values
- non-fatal diagnostics for malformed values and unresolved refs
- fail-closed assertion projection for built-in `doors` and `polarion` profiles

## Out of scope

- XSD validation
- embedded attachment extraction
- XHTML rendering
- requirement-vs-section classification
- canonical requirement ID or requirement text extraction
- graph analysis across files
- semantic projection for unknown or ambiguous exporter shapes
