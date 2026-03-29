pub const extraction_prompt =
    \\Extract traveler data as JSON only.
    \\
    \\Return this exact shape:
    \\{
    \\  "header": {
    \\    "product_name": string|null,
    \\    "assembly": string|null,
    \\    "serial_number": string|null,
    \\    "bom_revision": string|null,
    \\    "work_order": string|null,
    \\    "lot_batch": string|null,
    \\    "traveler_date": string|null
    \\  },
    \\  "verification": {
    \\    "atp_test_report_id": string|null,
    \\    "final_disposition": string|null,
    \\    "rework_ncr_number": string|null
    \\  }
    \\}
    \\
    \\Rules:
    \\- Return valid JSON only.
    \\- Return null for any field that is blank, unreadable, or missing.
    \\- Do not infer values from other rows.
    \\- Do not emit repeated top-level keys.
    \\- Treat traveler PART NUMBER as the top-level assembly field.
    \\- Focus on the required fields first: product_name, assembly, serial_number, bom_revision, atp_test_report_id.
    \\- Ignore footer boilerplate unless it maps directly to a field above.
    \\- If uncertain, use null.
;
