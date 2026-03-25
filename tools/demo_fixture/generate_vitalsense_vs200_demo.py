#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import sqlite3
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from datetime import datetime
from html import escape as xml_escape
from pathlib import Path
from typing import Any

import vitalsense_vs200_dataset as ds


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS nodes (
    id          TEXT PRIMARY KEY,
    type        TEXT NOT NULL,
    properties  TEXT NOT NULL,
    row_hash    TEXT,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    suspect     INTEGER NOT NULL DEFAULT 0,
    suspect_reason TEXT
);
CREATE TABLE IF NOT EXISTS node_history (
    node_id       TEXT NOT NULL,
    properties    TEXT NOT NULL,
    superseded_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS edges (
    id          TEXT PRIMARY KEY,
    from_id     TEXT NOT NULL,
    to_id       TEXT NOT NULL,
    label       TEXT NOT NULL,
    properties  TEXT,
    created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_edges_from   ON edges(from_id);
CREATE INDEX IF NOT EXISTS idx_edges_to     ON edges(to_id);
CREATE INDEX IF NOT EXISTS idx_nodes_type   ON nodes(type);
CREATE INDEX IF NOT EXISTS idx_history_node ON node_history(node_id);
CREATE TABLE IF NOT EXISTS credentials (
    id         TEXT PRIMARY KEY,
    content    TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS runtime_diagnostics (
    dedupe_key   TEXT PRIMARY KEY,
    code         INTEGER NOT NULL,
    severity     TEXT NOT NULL,
    title        TEXT NOT NULL,
    message      TEXT NOT NULL,
    source       TEXT NOT NULL,
    subject      TEXT,
    details_json TEXT NOT NULL,
    updated_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_runtime_diag_source ON runtime_diagnostics(source);
CREATE INDEX IF NOT EXISTS idx_runtime_diag_subject ON runtime_diagnostics(subject);
"""


REQUIREMENT_IDS = {item["id"] for item in ds.REQUIREMENTS}
TEST_GROUP_IDS = {item["id"] for item in ds.TEST_GROUPS}
TEST_IDS = {item["id"] for item in ds.TEST_CASES}
RISK_IDS = {item["id"] for item in ds.RISKS}
USER_NEED_IDS = {item["id"] for item in ds.USER_NEEDS}
ARTIFACT_IDS = {item["id"] for item in ds.ARTIFACTS}
COMMIT_BY_ID = {item["id"]: item for item in ds.COMMITS}
ARTIFACT_BY_ID = {item["id"]: item for item in ds.ARTIFACTS}
GENERATED_DOC_ARTIFACT_IDS = {ds.SRS_ARTIFACT_ID, ds.SYSRD_ARTIFACT_ID}


@dataclass
class Summary:
    output_path: str
    node_count: int
    edge_count: int
    runtime_diagnostic_count: int
    production_serial_count: int
    product_identifier: str
    demo_moments: dict[str, Any]
    artifact_dir: str
    artifact_count: int
    artifact_ids: list[str]
    generated_artifact_paths: list[str]


def json_dumps(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def iso_to_epoch(value: str) -> int:
    normalized = value
    if value.endswith("Z"):
        normalized = value[:-1] + "+00:00"
    return int(datetime.fromisoformat(normalized).timestamp())


def stable_edge_id(from_id: str, label: str, to_id: str) -> str:
    digest = hashlib.sha256(f"{from_id}|{label}|{to_id}".encode("utf-8")).hexdigest()
    return f"edge://{digest}"


def execution_node_id(execution_id: str) -> str:
    return f"execution://{execution_id}"


def result_node_id(result_id: str) -> str:
    return f"test-result://{result_id}"


def bom_item_id(full_product_identifier: str, bom_type: str, bom_name: str, part: str, revision: str) -> str:
    return f"bom-item://{full_product_identifier}/{bom_type}/{bom_name}/{part}@{revision}"


def artifact_default_dir(output_path: str) -> Path:
    return Path(f"{output_path}.artifacts")


def artifact_output_paths(artifact_dir: Path) -> dict[str, str]:
    return {
        ds.RTM_ARTIFACT_ID: str(artifact_dir / "rtm" / f"{ds.RTM_ARTIFACT_LOGICAL_KEY}.xlsx"),
        ds.SRS_ARTIFACT_ID: str(artifact_dir / "srs" / f"{ds.SRS_ARTIFACT_LOGICAL_KEY}.docx"),
        ds.SYSRD_ARTIFACT_ID: str(artifact_dir / "sysrd" / f"{ds.SYSRD_ARTIFACT_LOGICAL_KEY}.docx"),
    }


def ensure_parent_dir(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def normalize_text(text: str) -> str:
    parts = text.lower().split()
    return " ".join(parts)


def text_hash(text: str | None) -> str:
    if not text:
        return ""
    return hashlib.sha256(normalize_text(text).encode("utf-8")).hexdigest()


def compute_execution_status(test_cases: list[dict[str, Any]]) -> str:
    if any(case["status"] in {"failed", "error", "blocked"} for case in test_cases):
        return "failed"
    if all(case["status"] == "passed" for case in test_cases):
        return "passed"
    return "partial"


def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA_SQL)
    return conn


def initialize_schema(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA_SQL)


def build_document_xml_from_paragraphs(paragraphs: list[str]) -> str:
    body = "".join(
        f"<w:p><w:r><w:t>{xml_escape(paragraph)}</w:t></w:r></w:p>"
        for paragraph in paragraphs
    )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{body}</w:body>"
        "</w:document>"
    )


def build_document_xml_from_table(rows: list[tuple[str, str]]) -> str:
    row_xml = []
    for left, right in rows:
        row_xml.append(
            "<w:tr>"
            f"<w:tc><w:p><w:r><w:t>{xml_escape(left)}</w:t></w:r></w:p></w:tc>"
            f"<w:tc><w:p><w:r><w:t>{xml_escape(right)}</w:t></w:r></w:p></w:tc>"
            "</w:tr>"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body><w:tbl>{''.join(row_xml)}</w:tbl></w:body>"
        "</w:document>"
    )


def write_minimal_docx(path: Path, document_xml: str) -> None:
    ensure_parent_dir(path)
    content_types = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"""
    root_rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""
    doc_rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types)
        zf.writestr("_rels/.rels", root_rels)
        zf.writestr("word/document.xml", document_xml)
        zf.writestr("word/_rels/document.xml.rels", doc_rels)


def excel_col_name(index: int) -> str:
    value = index + 1
    out: list[str] = []
    while value > 0:
        value, rem = divmod(value - 1, 26)
        out.append(chr(ord("A") + rem))
    return "".join(reversed(out))


def build_sheet_xml(rows: list[list[str]]) -> str:
    row_xml: list[str] = []
    for row_idx, row in enumerate(rows, start=1):
        cell_xml: list[str] = []
        for col_idx, value in enumerate(row):
            cell_ref = f"{excel_col_name(col_idx)}{row_idx}"
            cell_xml.append(
                f'<c r="{cell_ref}" t="inlineStr"><is><t>{xml_escape(value)}</t></is></c>'
            )
        row_xml.append(f'<row r="{row_idx}">{"".join(cell_xml)}</row>')
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f'<sheetData>{"".join(row_xml)}</sheetData>'
        "</worksheet>"
    )


def write_minimal_xlsx(path: Path, sheets: list[tuple[str, list[list[str]]]]) -> None:
    ensure_parent_dir(path)
    workbook_sheets = []
    workbook_rels = []
    content_type_overrides = [
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    ]
    sheet_xml_by_name: dict[str, str] = {}
    for idx, (name, rows) in enumerate(sheets, start=1):
        workbook_sheets.append(
            f'<sheet name="{xml_escape(name)}" sheetId="{idx}" r:id="rId{idx}"/>'
        )
        workbook_rels.append(
            f'<Relationship Id="rId{idx}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{idx}.xml"/>'
        )
        content_type_overrides.append(
            f'<Override PartName="/xl/worksheets/sheet{idx}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        )
        sheet_xml_by_name[f"xl/worksheets/sheet{idx}.xml"] = build_sheet_xml(rows)

    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        f'{"".join(content_type_overrides)}'
        "</Types>"
    )
    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        "</Relationships>"
    )
    workbook_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f'<sheets>{"".join(workbook_sheets)}</sheets>'
        "</workbook>"
    )
    workbook_xml_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        f'{"".join(workbook_rels)}'
        "</Relationships>"
    )

    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types)
        zf.writestr("_rels/.rels", root_rels)
        zf.writestr("xl/workbook.xml", workbook_xml)
        zf.writestr("xl/_rels/workbook.xml.rels", workbook_xml_rels)
        for sheet_path, xml in sheet_xml_by_name.items():
            zf.writestr(sheet_path, xml)


def generate_artifact_files(artifact_dir: Path) -> tuple[dict[str, str], list[str]]:
    paths = artifact_output_paths(artifact_dir)
    rtm_path = Path(paths[ds.RTM_ARTIFACT_ID])
    srs_path = Path(paths[ds.SRS_ARTIFACT_ID])
    sysrd_path = Path(paths[ds.SYSRD_ARTIFACT_ID])
    write_minimal_xlsx(
        rtm_path,
        [
            ("Requirements", [["ID", "Statement"]] + [[req_id, ds.REQUIREMENT_TEXTS[req_id]] for req_id in ds.RTM_ASSERTION_REQ_IDS]),
            ("User Needs", [["ID", "Statement"]] + [[item["id"], item["statement"]] for item in ds.USER_NEEDS]),
            ("Tests", [["ID", "Method"]] + [[item["id"], item["test_method"]] for item in ds.TEST_CASES[:5]]),
            ("Risks", [["ID", "Description"]] + [[item["id"], item["description"]] for item in ds.RISKS]),
        ],
    )
    write_minimal_docx(srs_path, build_document_xml_from_paragraphs(ds.SRS_DOC_PARAGRAPHS))
    write_minimal_docx(sysrd_path, build_document_xml_from_table(ds.SYSRD_DOC_ROWS))
    return paths, [str(rtm_path), str(srs_path), str(sysrd_path)]


def assertions_by_requirement() -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {req_id: [] for req_id in REQUIREMENT_IDS}
    for artifact_id in ARTIFACT_IDS:
        for assertion in ds.artifact_assertions_for(artifact_id):
            grouped.setdefault(assertion["req_id"], []).append(assertion)
    return grouped


def resolution_from_assertions(assertions: list[dict[str, Any]]) -> dict[str, Any]:
    effective_statement: str | None = None
    authoritative_source: str | None = None
    text_status = "no_source"
    source_count = len(assertions)

    rtm_assertion: dict[str, Any] | None = None
    first_non_rtm_text: str | None = None
    first_non_rtm_normalized: str | None = None
    non_rtm_count = 0
    non_rtm_conflict = False

    for assertion in assertions:
        assertion_text = assertion["text"] or ""
        normalized = normalize_text(assertion_text) if assertion_text else ""
        if assertion["source_kind"] == "rtm_workbook" and assertion_text:
            rtm_assertion = assertion
            continue
        if not assertion_text:
            continue
        non_rtm_count += 1
        if first_non_rtm_text is None:
            first_non_rtm_text = assertion_text
            first_non_rtm_normalized = normalized
            authoritative_source = assertion["artifact_id"]
        elif first_non_rtm_normalized != normalized:
            non_rtm_conflict = True

    if rtm_assertion is not None:
        rtm_text = rtm_assertion["text"] or ""
        effective_statement = rtm_text
        authoritative_source = rtm_assertion["artifact_id"]
        rtm_normalized = normalize_text(rtm_text) if rtm_text else ""
        conflict = False
        for candidate in assertions:
            if candidate["source_kind"] == "rtm_workbook":
                continue
            candidate_text = candidate["text"] or ""
            if not candidate_text:
                continue
            if normalize_text(candidate_text) != rtm_normalized:
                conflict = True
                break
        text_status = "conflict" if conflict else "aligned"
    elif non_rtm_count == 1 and first_non_rtm_text is not None:
        effective_statement = first_non_rtm_text
        text_status = "single_source"
    elif non_rtm_count > 1 and not non_rtm_conflict and first_non_rtm_text is not None:
        effective_statement = first_non_rtm_text
        text_status = "aligned"
    elif non_rtm_count > 1 and non_rtm_conflict:
        authoritative_source = None
        text_status = "conflict"

    return {
        "effective_statement": effective_statement,
        "authoritative_source": authoritative_source,
        "text_status": text_status,
        "source_count": source_count,
    }


def current_requirement_resolutions() -> dict[str, dict[str, Any]]:
    return {
        req_id: resolution_from_assertions(assertions)
        for req_id, assertions in assertions_by_requirement().items()
    }


def previous_srs015_resolution() -> dict[str, Any]:
    assertions = []
    for assertion in assertions_by_requirement()["SRS-015"]:
        if assertion["artifact_id"] == ds.RTM_ARTIFACT_ID:
            assertions.append({**assertion, "text": ds.PREVIOUS_RTM_TEXTS["SRS-015"]})
        else:
            assertions.append(assertion)
    return resolution_from_assertions(assertions)


class FixtureBuilder:
    def __init__(self, conn: sqlite3.Connection) -> None:
        self.conn = conn
        self.node_ids: set[str] = set()
        self.edge_ids: set[str] = set()
        self.node_records: dict[str, dict[str, Any]] = {}
        self.execution_ids: set[str] = set()
        self.result_ids: set[str] = set()

    def insert_node(
        self,
        node_id: str,
        node_type: str,
        properties: dict[str, Any],
        *,
        created_at_iso: str = ds.DEFAULT_CREATED_AT,
        updated_at_iso: str | None = None,
        suspect: bool = False,
        suspect_reason: str | None = None,
        row_hash: str | None = None,
    ) -> None:
        if node_id in self.node_ids:
            raise ValueError(f"duplicate node id: {node_id}")
        self.node_ids.add(node_id)
        updated_at_iso = updated_at_iso or created_at_iso
        properties_json = json_dumps(properties)
        self.node_records[node_id] = {
            "id": node_id,
            "type": node_type,
            "properties": properties,
            "properties_json": properties_json,
        }
        self.conn.execute(
            """
            INSERT INTO nodes (id, type, properties, row_hash, created_at, updated_at, suspect, suspect_reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                node_id,
                node_type,
                properties_json,
                row_hash,
                iso_to_epoch(created_at_iso),
                iso_to_epoch(updated_at_iso),
                1 if suspect else 0,
                suspect_reason,
            ),
        )

    def insert_edge(
        self,
        from_id: str,
        to_id: str,
        label: str,
        *,
        properties: dict[str, Any] | None = None,
        created_at_iso: str = ds.DEFAULT_CREATED_AT,
    ) -> None:
        edge_id = stable_edge_id(from_id, label, to_id)
        if edge_id in self.edge_ids:
            raise ValueError(f"duplicate edge id: {edge_id}")
        self.edge_ids.add(edge_id)
        self.conn.execute(
            """
            INSERT INTO edges (id, from_id, to_id, label, properties, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                edge_id,
                from_id,
                to_id,
                label,
                json_dumps(properties) if properties is not None else None,
                iso_to_epoch(created_at_iso),
            ),
        )

    def insert_node_history(self, node_id: str, properties: dict[str, Any], superseded_at_iso: str) -> None:
        self.conn.execute(
            "INSERT INTO node_history (node_id, properties, superseded_at) VALUES (?, ?, ?)",
            (node_id, json_dumps(properties), iso_to_epoch(superseded_at_iso)),
        )

    def insert_runtime_diag(
        self,
        dedupe_key: str,
        code: int,
        severity: str,
        title: str,
        message: str,
        source: str,
        subject: str | None,
        details: dict[str, Any] | None,
        updated_at_iso: str = ds.REQUIREMENT_CHANGED_AT,
    ) -> None:
        self.conn.execute(
            """
            INSERT INTO runtime_diagnostics
            (dedupe_key, code, severity, title, message, source, subject, details_json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                dedupe_key,
                code,
                severity,
                title,
                message,
                source,
                subject,
                json_dumps(details or {}),
                iso_to_epoch(updated_at_iso),
            ),
        )


def ensure_unique_ids(values: list[str], label: str) -> None:
    seen: set[str] = set()
    for value in values:
        if value in seen:
            raise ValueError(f"duplicate {label}: {value}")
        seen.add(value)


def validate_dataset() -> None:
    if ds.EXPECTED_PRODUCTION_SERIAL_COUNT != len(ds.generate_passing_ate_batch()) + 2:
        raise ValueError("expected production serial count does not match generated ATE data")

    ensure_unique_ids([item["id"] for item in ds.REQUIREMENTS], "requirement id")
    ensure_unique_ids([item["id"] for item in ds.TEST_GROUPS], "test group id")
    ensure_unique_ids([item["id"] for item in ds.TEST_CASES], "test id")
    ensure_unique_ids([item["id"] for item in ds.RISKS], "risk id")
    ensure_unique_ids([item["id"] for item in ds.USER_NEEDS], "user need id")
    ensure_unique_ids([item["id"] for item in ds.ARTIFACTS], "artifact id")

    for artifact in ds.ARTIFACTS:
        if artifact["kind"] not in {"rtm_workbook", "srs_docx", "sysrd_docx"}:
            raise ValueError(f"unsupported artifact kind: {artifact['kind']}")

    stale_req = next(item for item in ds.REQUIREMENTS if item["id"] == "SRS-015")
    if stale_req.get("changed_at") != ds.REQUIREMENT_CHANGED_AT:
        raise ValueError("SRS-015 changed_at missing or incorrect")
    if "SRS-015" not in ds.PREVIOUS_RTM_TEXTS:
        raise ValueError("SRS-015 previous RTM text missing")

    assertion_coverage: dict[str, int] = {req_id: 0 for req_id in REQUIREMENT_IDS}
    text_node_ids: list[str] = []
    for artifact in ds.ARTIFACTS:
        assertions = ds.artifact_assertions_for(artifact["id"])
        ensure_unique_ids([item["req_id"] for item in assertions], f"assertion req id for {artifact['id']}")
        for assertion in assertions:
            if assertion["artifact_id"] != artifact["id"]:
                raise ValueError(f"assertion artifact mismatch for {assertion['req_id']}")
            if assertion["req_id"] not in REQUIREMENT_IDS:
                raise ValueError(f"unknown assertion requirement id: {assertion['req_id']}")
            assertion_coverage[assertion["req_id"]] += 1
            text_node_ids.append(ds.requirement_text_node_id(artifact["id"], assertion["req_id"]))
    ensure_unique_ids(text_node_ids, "requirement text node id")

    for req_id, count in assertion_coverage.items():
        if count == 0:
            raise ValueError(f"requirement has no source assertions: {req_id}")

    srs015_assertions = assertions_by_requirement()["SRS-015"]
    if {item["artifact_id"] for item in srs015_assertions} != {ds.RTM_ARTIFACT_ID, ds.SRS_ARTIFACT_ID}:
        raise ValueError("SRS-015 assertions must come from RTM and SRS")
    if len({normalize_text(item["text"]) for item in srs015_assertions}) != 2:
        raise ValueError("SRS-015 RTM and SRS text should differ")

    for req_id in ds.EXPECTED_MISSING_RTM_REQUIREMENTS:
        if any(item["artifact_id"] == ds.RTM_ARTIFACT_ID for item in assertions_by_requirement()[req_id]):
            raise ValueError(f"{req_id} unexpectedly has an RTM assertion")

    for requirement in ds.REQUIREMENTS:
        for parent_id in requirement.get("parent_user_need_ids", []):
            if parent_id not in USER_NEED_IDS:
                raise ValueError(f"unknown parent user need id: {parent_id}")
        for parent_id in requirement.get("parent_requirement_ids", []):
            if parent_id not in REQUIREMENT_IDS:
                raise ValueError(f"unknown parent requirement id: {parent_id}")
        for test_group_id in requirement.get("tested_by", []):
            if test_group_id not in TEST_GROUP_IDS:
                raise ValueError(f"unknown test group id on requirement {requirement['id']}: {test_group_id}")
        for risk_id in requirement.get("risk_ids", []):
            if risk_id not in RISK_IDS:
                raise ValueError(f"unknown risk id on requirement {requirement['id']}: {risk_id}")

    for risk in ds.RISKS:
        for requirement_id in risk["requirement_ids"]:
            if requirement_id not in REQUIREMENT_IDS:
                raise ValueError(f"unknown mitigated requirement id on risk {risk['id']}: {requirement_id}")

    for test_case in ds.TEST_CASES:
        if test_case["test_group_id"] not in TEST_GROUP_IDS:
            raise ValueError(f"test case {test_case['id']} references unknown group")

    for test_id, requirement_ids in ds.TEST_CASE_TO_REQUIREMENTS.items():
        if test_id not in TEST_IDS:
            raise ValueError(f"test case mapping references unknown test id: {test_id}")
        for requirement_id in requirement_ids:
            if requirement_id not in REQUIREMENT_IDS:
                raise ValueError(f"test case mapping references unknown requirement id: {requirement_id}")

    for item in ds.HARDWARE_BOM_ITEMS:
        for requirement_id in item["requirement_ids"]:
            if requirement_id not in REQUIREMENT_IDS:
                raise ValueError(f"hardware BOM item {item['part']} references unknown requirement id")
        for test_id in item["test_ids"]:
            if test_id not in TEST_GROUP_IDS and test_id not in TEST_IDS:
                raise ValueError(f"hardware BOM item {item['part']} references unknown test id")

    for component in ds.SOUP_COMPONENTS:
        for requirement_id in component["requirement_ids"]:
            if requirement_id not in REQUIREMENT_IDS:
                raise ValueError(f"SOUP component {component['component_name']} references unknown requirement id")
        for test_id in component["test_ids"]:
            if test_id not in TEST_GROUP_IDS and test_id not in TEST_IDS:
                raise ValueError(f"SOUP component {component['component_name']} references unknown test id")

    commit_ids = {item["id"] for item in ds.COMMITS}
    for file_path, commit_id in ds.FILE_TO_COMMIT_ID.items():
        if commit_id not in commit_ids:
            raise ValueError(f"file {file_path} references unknown commit {commit_id}")

    for annotation in ds.ANNOTATIONS:
        if annotation["req_id"] not in REQUIREMENT_IDS:
            raise ValueError(f"annotation references unknown requirement id: {annotation['req_id']}")
        if annotation["file_kind"] not in {"source", "test"}:
            raise ValueError(f"invalid file kind for annotation: {annotation['file_path']}")

    execution_ids: set[str] = set()
    result_ids: set[str] = set()
    for execution in ds.CI_EXECUTIONS + ds.all_ate_executions():
        execution_id = execution["execution_id"]
        if execution_id in execution_ids:
            raise ValueError(f"duplicate execution id: {execution_id}")
        execution_ids.add(execution_id)
        for test_case in execution["test_cases"]:
            result_id = test_case["result_id"]
            if result_id in result_ids:
                raise ValueError(f"duplicate result id: {result_id}")
            result_ids.add(result_id)
            if test_case["test_case_ref"] not in TEST_IDS:
                raise ValueError(f"execution {execution_id} references unknown test case {test_case['test_case_ref']}")

    if ds.ATE_UNIT_1246["serial_number"] != ds.EXPECTED_DEMO_MOMENTS["failed_unit"]:
        raise ValueError("failed unit mismatch")


def make_requirement_properties(requirement: dict[str, Any], resolution: dict[str, Any], *, changed_at: str | None = None) -> dict[str, Any]:
    props: dict[str, Any] = {
        "priority": requirement["priority"],
        "status": requirement["status"],
        "kind": requirement["kind"],
        "notes": "",
        "declared_test_group_ref_count": str(len(requirement.get("tested_by", []))),
        "text_status": resolution["text_status"],
        "authoritative_source": resolution["authoritative_source"],
        "source_count": resolution["source_count"],
    }
    if requirement.get("safety_class"):
        props["safety_class"] = requirement["safety_class"]
    if changed_at:
        props["changed_at"] = changed_at
    elif requirement.get("changed_at"):
        props["changed_at"] = requirement["changed_at"]
    if requirement.get("risk_ids"):
        props["risk_refs"] = requirement["risk_ids"]
    return props


def make_requirement_text_properties(assertion: dict[str, Any], imported_at_iso: str) -> dict[str, Any]:
    text = assertion["text"]
    normalized = normalize_text(text) if text else None
    return {
        "req_id": assertion["req_id"],
        "artifact_id": assertion["artifact_id"],
        "source_kind": assertion["source_kind"],
        "section": assertion["section"],
        "text": text,
        "normalized_text": normalized,
        "hash": text_hash(text),
        "imported_at": str(iso_to_epoch(imported_at_iso)),
        "parse_status": assertion["parse_status"],
        "occurrence_count": assertion["occurrence_count"],
    }


def make_bom_properties(bom_name: str, bom_type: str, source_format: str, ingested_at: str) -> dict[str, Any]:
    return {
        "full_product_identifier": ds.PRODUCT_FULL_IDENTIFIER,
        "bom_name": bom_name,
        "bom_type": bom_type,
        "bom_class": "design",
        "source_format": source_format,
        "ingested_at": iso_to_epoch(ingested_at),
    }


def make_bom_item_properties(item: dict[str, Any], *, software: bool) -> dict[str, Any]:
    return {
        "part": item["component_name"] if software else item["part"],
        "revision": item["version"] if software else item["revision"],
        "description": None if software else item["description"],
        "category": item["category"],
        "supplier": item["supplier"],
        "requirement_ids": item["requirement_ids"],
        "test_ids": item["test_ids"],
        "purl": item.get("purl"),
        "license": item.get("license"),
        "safety_class": item.get("safety_class"),
        "known_anomalies": item.get("known_anomalies") if software else None,
        "anomaly_evaluation": item.get("anomaly_evaluation") if software else None,
        "hashes": None,
    }


def make_execution_properties(execution: dict[str, Any]) -> dict[str, Any]:
    return {
        "execution_id": execution["execution_id"],
        "executed_at": execution["executed_at"],
        "computed_status": compute_execution_status(execution["test_cases"]),
        "serial_number": execution.get("serial_number"),
        "full_product_identifier": execution.get("full_product_identifier"),
        "product_resolution_state": "resolved" if execution.get("full_product_identifier") else None,
        "executor": execution.get("executor"),
        "source": execution.get("source"),
        "ingested_at": iso_to_epoch(execution["executed_at"]),
    }


def make_result_properties(execution_id: str, test_case: dict[str, Any]) -> dict[str, Any]:
    return {
        "result_id": test_case["result_id"],
        "execution_id": execution_id,
        "test_case_ref": test_case["test_case_ref"],
        "status": test_case["status"],
        "duration_ms": test_case.get("duration_ms"),
        "notes": test_case.get("notes"),
        "measurements": test_case.get("measurements", []),
        "attachments": test_case.get("attachments", []),
        "resolution_state": "resolved",
    }


def file_annotation_count(file_path: str) -> int:
    return sum(1 for annotation in ds.ANNOTATIONS if annotation["file_path"] == file_path)


def commit_for_file(file_path: str) -> dict[str, Any]:
    return COMMIT_BY_ID[ds.FILE_TO_COMMIT_ID[file_path]]


def add_trace_graph(builder: FixtureBuilder, resolutions: dict[str, dict[str, Any]]) -> None:
    product = ds.PRODUCT
    builder.insert_node(
        ds.PRODUCT_NODE_ID,
        "Product",
        {
            "assembly": product.assembly,
            "revision": product.revision,
            "full_identifier": product.full_identifier,
            "description": product.description,
            "product_status": product.product_status,
        },
        created_at_iso=ds.DEFAULT_CREATED_AT,
    )

    for user_need in ds.USER_NEEDS:
        builder.insert_node(
            user_need["id"],
            "UserNeed",
            {
                "statement": user_need["statement"],
                "source": user_need["source"],
                "priority": user_need["priority"],
            },
        )

    previous_srs015 = previous_srs015_resolution()
    for requirement in ds.REQUIREMENTS:
        suspect = requirement["id"] == "SRS-015"
        suspect_reason = None
        updated_at = ds.DEFAULT_CREATED_AT
        if requirement["id"] == "SRS-015":
            updated_at = requirement["changed_at"]
            suspect_reason = "RTM text changed on 2026-03-10 after latest linked execution on 2026-03-05; SRS source still carries the prior text."
        builder.insert_node(
            requirement["id"],
            "Requirement",
            make_requirement_properties(requirement, resolutions[requirement["id"]]),
            updated_at_iso=updated_at,
            suspect=suspect,
            suspect_reason=suspect_reason,
        )
        if requirement["id"] == "SRS-015":
            previous_props = make_requirement_properties(
                requirement,
                previous_srs015,
                changed_at=ds.REQUIREMENT_PREVIOUS_UPDATED_AT,
            )
            builder.insert_node_history(requirement["id"], previous_props, requirement["changed_at"])

    for test_group in ds.TEST_GROUPS:
        builder.insert_node(
            test_group["id"],
            "TestGroup",
            {"name": test_group["name"], "status": test_group["status"]},
            suspect=test_group["id"] == "TG-FHIR",
            suspect_reason="Contains TC-FHIR-003, whose latest execution predates the SRS-015 change." if test_group["id"] == "TG-FHIR" else None,
        )

    for test_case in ds.TEST_CASES:
        builder.insert_node(
            test_case["id"],
            "Test",
            {
                "name": test_case["name"],
                "test_id": test_case["id"],
                "test_group_id": test_case["test_group_id"],
                "test_type": test_case["test_type"],
                "test_method": test_case["test_method"],
                "status": test_case["status"],
            },
            suspect=test_case["id"] == "TG-FHIR/TC-FHIR-003",
            suspect_reason="Latest execution predates changed requirement SRS-015." if test_case["id"] == "TG-FHIR/TC-FHIR-003" else None,
        )
        builder.insert_edge(test_case["test_group_id"], test_case["id"], "HAS_TEST")

    for risk in ds.RISKS:
        builder.insert_node(
            risk["id"],
            "Risk",
            {
                "description": risk["description"],
                "initial_severity": risk["initial_severity"],
                "initial_likelihood": risk["initial_likelihood"],
                "mitigation": risk["mitigation"],
                "residual_severity": risk["residual_severity"],
                "residual_likelihood": risk["residual_likelihood"],
                "status": risk["status"],
                "risk_score": str(int(risk["initial_severity"]) * int(risk["initial_likelihood"])),
            },
        )

    for requirement in ds.REQUIREMENTS:
        for user_need_id in requirement.get("parent_user_need_ids", []):
            builder.insert_edge(requirement["id"], user_need_id, "DERIVES_FROM")
        for parent_requirement_id in requirement.get("parent_requirement_ids", []):
            builder.insert_edge(parent_requirement_id, requirement["id"], "REFINED_BY")
        for test_group_id in requirement.get("tested_by", []):
            builder.insert_edge(requirement["id"], test_group_id, "TESTED_BY")

    for risk in ds.RISKS:
        for requirement_id in risk["requirement_ids"]:
            builder.insert_edge(risk["id"], requirement_id, "MITIGATED_BY")


def add_artifact_graph(builder: FixtureBuilder, artifact_paths: dict[str, str]) -> dict[tuple[str, str], str]:
    text_node_ids: dict[tuple[str, str], str] = {}
    for artifact in ds.ARTIFACTS:
        path = artifact_paths[artifact["id"]]
        last_ingested_at = artifact["last_ingested_at"]
        builder.insert_node(
            artifact["id"],
            "Artifact",
            {
                "kind": artifact["kind"],
                "path": path,
                "display_name": artifact["display_name"],
                "last_ingested_at": str(iso_to_epoch(last_ingested_at)),
                "ingest_source": artifact["ingest_source"],
                "logical_key": artifact["logical_key"],
            },
            created_at_iso=last_ingested_at,
            updated_at_iso=last_ingested_at,
        )
        for assertion in ds.artifact_assertions_for(artifact["id"]):
            text_id = ds.requirement_text_node_id(artifact["id"], assertion["req_id"])
            text_node_ids[(artifact["id"], assertion["req_id"])] = text_id
            builder.insert_node(
                text_id,
                "RequirementText",
                make_requirement_text_properties(assertion, last_ingested_at),
                created_at_iso=last_ingested_at,
                updated_at_iso=last_ingested_at,
            )
            builder.insert_edge(artifact["id"], text_id, "CONTAINS", created_at_iso=last_ingested_at)
            builder.insert_edge(text_id, assertion["req_id"], "ASSERTS", created_at_iso=last_ingested_at)

    for req_id in ds.EXPECTED_CONFLICT_REQUIREMENTS:
        matching_text_ids = [
            text_id
            for (artifact_id, candidate_req_id), text_id in text_node_ids.items()
            if candidate_req_id == req_id and artifact_id in {ds.RTM_ARTIFACT_ID, ds.SRS_ARTIFACT_ID}
        ]
        if len(matching_text_ids) == 2:
            builder.insert_edge(matching_text_ids[0], matching_text_ids[1], "CONFLICTS_WITH", created_at_iso=ds.REQUIREMENT_CHANGED_AT)
            builder.insert_edge(matching_text_ids[1], matching_text_ids[0], "CONFLICTS_WITH", created_at_iso=ds.REQUIREMENT_CHANGED_AT)

    current_props = make_requirement_text_properties(
        next(item for item in ds.artifact_assertions_for(ds.RTM_ARTIFACT_ID) if item["req_id"] == "SRS-015"),
        ds.REQUIREMENT_CHANGED_AT,
    )
    previous_props = {
        **current_props,
        "text": ds.PREVIOUS_RTM_TEXTS["SRS-015"],
        "normalized_text": normalize_text(ds.PREVIOUS_RTM_TEXTS["SRS-015"]),
        "hash": text_hash(ds.PREVIOUS_RTM_TEXTS["SRS-015"]),
        "imported_at": str(iso_to_epoch(ds.REQUIREMENT_PREVIOUS_UPDATED_AT)),
    }
    _ = current_props
    builder.insert_node_history(
        text_node_ids[(ds.RTM_ARTIFACT_ID, "SRS-015")],
        previous_props,
        ds.REQUIREMENT_CHANGED_AT,
    )
    return text_node_ids


def add_bom_graph(builder: FixtureBuilder) -> None:
    ingested_at = "2026-03-17T12:00:00Z"
    builder.insert_node(
        ds.HARDWARE_BOM_ID,
        "DesignBOM",
        make_bom_properties(ds.HARDWARE_BOM_NAME, "hardware", "fixture_hardware", ingested_at),
        created_at_iso=ingested_at,
        updated_at_iso=ingested_at,
    )
    builder.insert_edge(ds.PRODUCT_NODE_ID, ds.HARDWARE_BOM_ID, "HAS_DESIGN_BOM", created_at_iso=ingested_at)

    for item in ds.HARDWARE_BOM_ITEMS:
        item_id = bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "hardware", ds.HARDWARE_BOM_NAME, item["part"], item["revision"])
        builder.insert_node(
            item_id,
            "BOMItem",
            make_bom_item_properties(item, software=False),
            created_at_iso=ingested_at,
            updated_at_iso=ingested_at,
        )
        parent_part = item["parent_part"]
        if parent_part is None:
            builder.insert_edge(
                ds.HARDWARE_BOM_ID,
                item_id,
                "CONTAINS",
                properties={
                    "quantity": item["quantity"],
                    "ref_designator": item["ref_designator"],
                    "supplier": item["supplier"],
                    "relation_source": "fixture_hardware",
                },
                created_at_iso=ingested_at,
            )
        else:
            parent_id = bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "hardware", ds.HARDWARE_BOM_NAME, parent_part, item["parent_revision"])
            builder.insert_edge(
                parent_id,
                item_id,
                "CONTAINS",
                properties={
                    "quantity": item["quantity"],
                    "ref_designator": item["ref_designator"],
                    "supplier": item["supplier"],
                    "relation_source": "fixture_hardware",
                },
                created_at_iso=ingested_at,
            )
        for requirement_id in item["requirement_ids"]:
            builder.insert_edge(item_id, requirement_id, "REFERENCES_REQUIREMENT", properties={"relation_source": "fixture_hardware", "declared_field": "requirement_ids"}, created_at_iso=ingested_at)
        for test_id in item["test_ids"]:
            builder.insert_edge(item_id, test_id, "REFERENCES_TEST", properties={"relation_source": "fixture_hardware", "declared_field": "test_ids"}, created_at_iso=ingested_at)

    builder.insert_node(
        ds.SOUP_BOM_ID,
        "DesignBOM",
        make_bom_properties(ds.SOUP_BOM_NAME, "software", "fixture_soup", ingested_at),
        created_at_iso=ingested_at,
        updated_at_iso=ingested_at,
    )
    builder.insert_edge(ds.PRODUCT_NODE_ID, ds.SOUP_BOM_ID, "HAS_DESIGN_BOM", created_at_iso=ingested_at)

    for component in ds.SOUP_COMPONENTS:
        item_id = bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "software", ds.SOUP_BOM_NAME, component["component_name"], component["version"])
        builder.insert_node(
            item_id,
            "BOMItem",
            make_bom_item_properties(component, software=True),
            created_at_iso=ingested_at,
            updated_at_iso=ingested_at,
        )
        builder.insert_edge(
            ds.SOUP_BOM_ID,
            item_id,
            "CONTAINS",
            properties={
                "quantity": "1",
                "ref_designator": None,
                "supplier": component["supplier"],
                "relation_source": "fixture_soup",
            },
            created_at_iso=ingested_at,
        )
        for requirement_id in component["requirement_ids"]:
            builder.insert_edge(item_id, requirement_id, "REFERENCES_REQUIREMENT", properties={"relation_source": "fixture_soup", "declared_field": "requirement_ids"}, created_at_iso=ingested_at)
        for test_id in component["test_ids"]:
            builder.insert_edge(item_id, test_id, "REFERENCES_TEST", properties={"relation_source": "fixture_soup", "declared_field": "test_ids"}, created_at_iso=ingested_at)


def add_execution_history(builder: FixtureBuilder) -> None:
    for execution in ds.CI_EXECUTIONS + ds.all_ate_executions():
        execution_id = execution["execution_id"]
        builder.execution_ids.add(execution_id)
        execution_node = execution_node_id(execution_id)
        builder.insert_node(
            execution_node,
            "TestExecution",
            make_execution_properties(execution),
            created_at_iso=execution["executed_at"],
            updated_at_iso=execution["executed_at"],
        )
        if execution.get("full_product_identifier"):
            builder.insert_edge(execution_node, ds.PRODUCT_NODE_ID, "FOR_PRODUCT", created_at_iso=execution["executed_at"])
        for test_case in execution["test_cases"]:
            builder.result_ids.add(test_case["result_id"])
            result_node = result_node_id(test_case["result_id"])
            builder.insert_node(
                result_node,
                "TestResult",
                make_result_properties(execution_id, test_case),
                created_at_iso=execution["executed_at"],
                updated_at_iso=execution["executed_at"],
            )
            builder.insert_edge(execution_node, result_node, "HAS_RESULT", created_at_iso=execution["executed_at"])
            builder.insert_edge(result_node, test_case["test_case_ref"], "EXECUTION_OF", created_at_iso=execution["executed_at"])


def add_code_trace(builder: FixtureBuilder) -> None:
    source_paths = sorted({item["file_path"] for item in ds.ANNOTATIONS if item["file_kind"] == "source"})
    test_paths = sorted({item["file_path"] for item in ds.ANNOTATIONS if item["file_kind"] == "test"})

    for file_path in source_paths:
        builder.insert_node(
            file_path,
            "SourceFile",
            {
                "path": file_path,
                "repo": ds.REPO_PATH,
                "annotation_count": file_annotation_count(file_path),
                "present": True,
            },
        )

    for file_path in test_paths:
        builder.insert_node(
            file_path,
            "TestFile",
            {
                "path": file_path,
                "repo": ds.REPO_PATH,
                "annotation_count": file_annotation_count(file_path),
                "present": True,
            },
        )

    for commit in ds.COMMITS:
        builder.insert_node(
            commit["id"],
            "Commit",
            {
                "hash": commit["id"],
                "short_hash": commit["short_hash"],
                "date": commit["date"],
                "message": commit["message"],
            },
            created_at_iso=commit["date"],
            updated_at_iso=commit["date"],
        )

    for annotation in ds.ANNOTATIONS:
        commit = commit_for_file(annotation["file_path"])
        annotation_id = f"{annotation['file_path']}:{annotation['line_number']}"
        builder.insert_node(
            annotation_id,
            "CodeAnnotation",
            {
                "req_id": annotation["req_id"],
                "file_path": annotation["file_path"],
                "line_number": annotation["line_number"],
                "context": annotation["context"],
                "blame_author": "VitalSense Demo Bot",
                "author_time": iso_to_epoch(commit["date"]),
                "short_hash": commit["short_hash"],
            },
            created_at_iso=commit["date"],
            updated_at_iso=commit["date"],
        )
        builder.insert_edge(annotation["req_id"], annotation_id, "ANNOTATED_AT", created_at_iso=commit["date"])
        if annotation["file_kind"] == "source":
            builder.insert_edge(annotation["req_id"], annotation["file_path"], "IMPLEMENTED_IN", created_at_iso=commit["date"])
        else:
            builder.insert_edge(annotation["req_id"], annotation["file_path"], "VERIFIED_BY_CODE", created_at_iso=commit["date"])

    for file_path, commit_id in ds.FILE_TO_COMMIT_ID.items():
        builder.insert_edge(file_path, commit_id, "CHANGED_IN", created_at_iso=COMMIT_BY_ID[commit_id]["date"])

    for requirement in ds.REQUIREMENTS:
        for file_path in requirement.get("implemented_in", []):
            commit = commit_for_file(file_path)
            builder.insert_edge(requirement["id"], commit["id"], "COMMITTED_IN", created_at_iso=commit["date"])

    for source_file, test_files in ds.FILE_TO_TEST_FILES.items():
        for test_file in test_files:
            builder.insert_edge(source_file, test_file, "VERIFIED_BY_CODE")


def add_runtime_diagnostics(builder: FixtureBuilder) -> None:
    for diagnostic in ds.DEMO_DIAGNOSTICS:
        builder.insert_runtime_diag(
            diagnostic["dedupe_key"],
            diagnostic["code"],
            diagnostic["severity"],
            diagnostic["title"],
            diagnostic["message"],
            diagnostic["source"],
            diagnostic["subject"],
            {},
        )


def validate_graph(
    conn: sqlite3.Connection,
    artifact_dir: str,
    generated_artifact_paths: list[str],
) -> Summary:
    node_count = conn.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
    edge_count = conn.execute("SELECT COUNT(*) FROM edges").fetchone()[0]
    diagnostic_count = conn.execute("SELECT COUNT(*) FROM runtime_diagnostics").fetchone()[0]
    if node_count <= 0 or edge_count <= 0:
        raise ValueError("generated database is unexpectedly empty")

    missing_edge_endpoints = conn.execute(
        """
        SELECT COUNT(*)
        FROM edges e
        LEFT JOIN nodes n1 ON n1.id = e.from_id
        LEFT JOIN nodes n2 ON n2.id = e.to_id
        WHERE n1.id IS NULL OR n2.id IS NULL
        """
    ).fetchone()[0]
    if missing_edge_endpoints != 0:
        raise ValueError("generated database contains dangling edge endpoints")

    if conn.execute("SELECT COUNT(*) FROM nodes WHERE id=? AND type='Product'", (ds.PRODUCT_NODE_ID,)).fetchone()[0] != 1:
        raise ValueError("product node missing")

    artifact_count = conn.execute("SELECT COUNT(*) FROM nodes WHERE type='Artifact'").fetchone()[0]
    if artifact_count != len(ds.ARTIFACTS):
        raise ValueError(f"expected {len(ds.ARTIFACTS)} artifact nodes, found {artifact_count}")
    requirement_text_count = conn.execute("SELECT COUNT(*) FROM nodes WHERE type='RequirementText'").fetchone()[0]
    expected_text_count = sum(len(ds.artifact_assertions_for(item["id"])) for item in ds.ARTIFACTS)
    if requirement_text_count != expected_text_count:
        raise ValueError(f"expected {expected_text_count} requirement text nodes, found {requirement_text_count}")

    for requirement_id in REQUIREMENT_IDS:
        stmt, effective_stmt = conn.execute(
            "SELECT json_extract(properties, '$.statement'), json_extract(properties, '$.effective_statement') FROM nodes WHERE id=? AND type='Requirement'",
            (requirement_id,),
        ).fetchone()
        if stmt is not None or effective_stmt is not None:
            raise ValueError(f"{requirement_id} unexpectedly stores canonical requirement text")

    contains_count = conn.execute("SELECT COUNT(*) FROM edges WHERE label='CONTAINS'").fetchone()[0]
    asserts_count = conn.execute("SELECT COUNT(*) FROM edges WHERE label='ASSERTS'").fetchone()[0]
    if contains_count < expected_text_count or asserts_count < expected_text_count:
        raise ValueError("artifact provenance edges missing")
    if conn.execute("SELECT COUNT(*) FROM edges WHERE label='CONFLICTS_WITH'").fetchone()[0] != 2:
        raise ValueError("expected exactly two CONFLICTS_WITH edges for SRS-015")

    for requirement_id in ds.EXPECTED_DEMO_MOMENTS["untested_requirements"]:
        tested_by_count = conn.execute("SELECT COUNT(*) FROM edges WHERE from_id=? AND label='TESTED_BY'", (requirement_id,)).fetchone()[0]
        if tested_by_count != 0:
            raise ValueError(f"{requirement_id} unexpectedly has test coverage")
    for requirement_id in ds.EXPECTED_DEMO_MOMENTS["unimplemented_requirements"]:
        impl_count = conn.execute("SELECT COUNT(*) FROM edges WHERE from_id=? AND label='IMPLEMENTED_IN'", (requirement_id,)).fetchone()[0]
        if impl_count != 0:
            raise ValueError(f"{requirement_id} unexpectedly has implementation evidence")

    if conn.execute("SELECT COUNT(*) FROM node_history WHERE node_id='SRS-015'").fetchone()[0] < 1:
        raise ValueError("SRS-015 canonical node_history missing")
    if conn.execute("SELECT COUNT(*) FROM node_history WHERE node_id=?", (ds.requirement_text_node_id(ds.RTM_ARTIFACT_ID, "SRS-015"),)).fetchone()[0] < 1:
        raise ValueError("SRS-015 RTM RequirementText node_history missing")

    suspect_row = conn.execute("SELECT suspect, suspect_reason FROM nodes WHERE id='SRS-015'").fetchone()
    if not suspect_row or suspect_row[0] != 1 or not suspect_row[1]:
        raise ValueError("SRS-015 suspect metadata missing")

    srs015_props = conn.execute(
        """
        SELECT
          json_extract(properties, '$.text_status'),
          json_extract(properties, '$.authoritative_source'),
          json_extract(properties, '$.source_count')
        FROM nodes
        WHERE id='SRS-015' AND type='Requirement'
        """
    ).fetchone()
    if not srs015_props or srs015_props[0] != "conflict" or srs015_props[1] != ds.RTM_ARTIFACT_ID:
        raise ValueError("SRS-015 requirement provenance metadata incorrect")
    if int(srs015_props[2]) != 2:
        raise ValueError("SRS-015 source count incorrect")

    srs015_assertion_count = conn.execute(
        """
        SELECT COUNT(*)
        FROM edges e
        JOIN nodes rt ON rt.id = e.from_id AND rt.type='RequirementText'
        WHERE e.label='ASSERTS' AND e.to_id='SRS-015'
        """
    ).fetchone()[0]
    if srs015_assertion_count != 2:
        raise ValueError("SRS-015 should have exactly two source assertions")

    for req_id in ds.EXPECTED_SINGLE_SOURCE_REQUIREMENTS:
        row = conn.execute(
            """
            SELECT
              json_extract(properties, '$.text_status'),
              json_extract(properties, '$.authoritative_source'),
              json_extract(properties, '$.source_count')
            FROM nodes
            WHERE id=? AND type='Requirement'
            """,
            (req_id,),
        ).fetchone()
        if not row or row[0] != "single_source" or row[1] != ds.SRS_ARTIFACT_ID or int(row[2]) != 1:
            raise ValueError(f"{req_id} single-source provenance metadata incorrect")
        rtm_count = conn.execute(
            """
            SELECT COUNT(*)
            FROM edges e
            JOIN nodes rt ON rt.id = e.from_id AND rt.type='RequirementText'
            WHERE e.label='ASSERTS'
              AND e.to_id=?
              AND json_extract(rt.properties, '$.source_kind')='rtm_workbook'
            """,
            (req_id,),
        ).fetchone()[0]
        if rtm_count != 0:
            raise ValueError(f"{req_id} unexpectedly has an RTM assertion")

    req003 = conn.execute(
        """
        SELECT
          json_extract(properties, '$.text_status'),
          json_extract(properties, '$.authoritative_source')
        FROM nodes
        WHERE id='REQ-003' AND type='Requirement'
        """
    ).fetchone()
    if not req003 or req003[0] != "aligned" or req003[1] != ds.RTM_ARTIFACT_ID:
        raise ValueError("REQ-003 aligned provenance metadata incorrect")

    if conn.execute("SELECT COUNT(*) FROM nodes WHERE id=?", (bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "software", ds.SOUP_BOM_NAME, "zlib", "1.2.11"),)).fetchone()[0] != 1:
        raise ValueError("zlib SOUP item missing")
    if conn.execute("SELECT COUNT(*) FROM nodes WHERE id=?", (bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "software", ds.SOUP_BOM_NAME, "Micro-ECC", "unknown"),)).fetchone()[0] != 1:
        raise ValueError("Micro-ECC SOUP item missing")
    if conn.execute("SELECT COUNT(*) FROM nodes WHERE id=?", (bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "hardware", ds.HARDWARE_BOM_NAME, "BSS138LT1G", "-"),)).fetchone()[0] != 1:
        raise ValueError("BSS138 hardware BOM item missing")

    failed_execution_status = conn.execute(
        "SELECT json_extract(properties, '$.computed_status') FROM nodes WHERE id=?",
        (execution_node_id(ds.ATE_UNIT_1246["execution_id"]),),
    ).fetchone()
    if not failed_execution_status or failed_execution_status[0] != "failed":
        raise ValueError("UNIT-1246 failed execution missing")

    passed_execution_status = conn.execute(
        "SELECT json_extract(properties, '$.computed_status') FROM nodes WHERE id=?",
        (execution_node_id(ds.ATE_UNIT_1247["execution_id"]),),
    ).fetchone()
    if not passed_execution_status or passed_execution_status[0] != "passed":
        raise ValueError("UNIT-1247 passed execution missing")

    production_serial_count = conn.execute(
        """
        SELECT COUNT(*)
        FROM nodes
        WHERE type='TestExecution'
          AND json_extract(properties, '$.serial_number') IS NOT NULL
        """
    ).fetchone()[0]
    if production_serial_count != ds.EXPECTED_PRODUCTION_SERIAL_COUNT:
        raise ValueError(
            f"expected {ds.EXPECTED_PRODUCTION_SERIAL_COUNT} production serial executions, found {production_serial_count}"
        )

    diag_keys = {
        row[0]
        for row in conn.execute("SELECT dedupe_key FROM runtime_diagnostics ORDER BY dedupe_key")
    }
    expected_keys = {item["dedupe_key"] for item in ds.DEMO_DIAGNOSTICS}
    if diag_keys != expected_keys:
        raise ValueError("runtime diagnostics do not match expected demo diagnostics")

    for artifact in ds.ARTIFACTS:
        if conn.execute("SELECT COUNT(*) FROM nodes WHERE id=? AND type='Artifact'", (artifact["id"],)).fetchone()[0] != 1:
            raise ValueError(f"artifact node missing: {artifact['id']}")

    for path_str in generated_artifact_paths:
        path = Path(path_str)
        if not path.exists():
            raise ValueError(f"generated artifact path missing: {path}")
        with zipfile.ZipFile(path, "r") as zf:
            if path.suffix == ".docx":
                if "word/document.xml" not in zf.namelist():
                    raise ValueError(f"generated artifact missing word/document.xml: {path}")
            elif path.suffix == ".xlsx":
                if "xl/workbook.xml" not in zf.namelist():
                    raise ValueError(f"generated artifact missing xl/workbook.xml: {path}")
            else:
                raise ValueError(f"unexpected generated artifact extension: {path}")

    return Summary(
        output_path=":memory:",
        node_count=node_count,
        edge_count=edge_count,
        runtime_diagnostic_count=diagnostic_count,
        production_serial_count=production_serial_count,
        product_identifier=ds.PRODUCT_FULL_IDENTIFIER,
        demo_moments=ds.EXPECTED_DEMO_MOMENTS,
        artifact_dir=artifact_dir,
        artifact_count=len(ds.ARTIFACTS),
        artifact_ids=[item["id"] for item in ds.ARTIFACTS],
        generated_artifact_paths=generated_artifact_paths,
    )


def build_fixture(
    conn: sqlite3.Connection,
    artifact_dir: str,
    artifact_paths: dict[str, str],
    generated_artifact_paths: list[str],
) -> Summary:
    initialize_schema(conn)
    builder = FixtureBuilder(conn)
    resolutions = current_requirement_resolutions()
    add_trace_graph(builder, resolutions)
    add_artifact_graph(builder, artifact_paths)
    add_bom_graph(builder)
    add_execution_history(builder)
    add_code_trace(builder)
    add_runtime_diagnostics(builder)
    conn.commit()
    return validate_graph(conn, artifact_dir, generated_artifact_paths)


def generate_fixture(output_path: str, overwrite: bool, quiet: bool, artifact_dir: str | None = None) -> Summary:
    path = Path(output_path)
    artifact_dir_path = Path(artifact_dir) if artifact_dir else artifact_default_dir(output_path)
    if path.exists() and not overwrite:
        raise FileExistsError(f"refusing to overwrite existing file without --overwrite: {path}")
    ensure_parent_dir(path)
    if path.exists():
        path.unlink()

    artifact_paths, generated_artifact_paths = generate_artifact_files(artifact_dir_path)
    conn = open_db(str(path))
    try:
        summary = build_fixture(conn, str(artifact_dir_path), artifact_paths, generated_artifact_paths)
    finally:
        conn.close()

    summary.output_path = str(path)
    if not quiet:
        print_human_summary(summary)
    return summary


def validate_only(quiet: bool, artifact_dir: str | None = None) -> Summary:
    with tempfile.TemporaryDirectory(prefix="vitalsense-artifacts-") as tmpdir:
        artifact_dir_path = Path(tmpdir)
        artifact_paths, generated_artifact_paths = generate_artifact_files(artifact_dir_path)
        conn = sqlite3.connect(":memory:")
        try:
            summary = build_fixture(conn, str(artifact_dir_path), artifact_paths, generated_artifact_paths)
        finally:
            conn.close()
        if not quiet:
            print_human_summary(summary)
        return summary


def print_human_summary(summary: Summary) -> None:
    print(f"output_path: {summary.output_path}")
    print(f"product_identifier: {summary.product_identifier}")
    print(f"node_count: {summary.node_count}")
    print(f"edge_count: {summary.edge_count}")
    print(f"runtime_diagnostic_count: {summary.runtime_diagnostic_count}")
    print(f"production_serial_count: {summary.production_serial_count}")
    print(f"artifact_dir: {summary.artifact_dir}")
    print(f"artifact_count: {summary.artifact_count}")
    print(f"artifact_ids: {summary.artifact_ids}")
    print(f"generated_artifact_paths: {summary.generated_artifact_paths}")
    print("demo_moments:")
    for key, value in summary.demo_moments.items():
        print(f"  {key}: {value}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate the VitalSense VS-200 RTMify Live demo fixture database.")
    parser.add_argument("--output", default="/tmp/vitalsense-vs200-demo.sqlite", help="Output SQLite database path.")
    parser.add_argument("--artifact-dir", help="Directory for generated demo design artifacts. Defaults to <output>.artifacts.")
    parser.add_argument("--overwrite", action="store_true", help="Replace an existing output file.")
    parser.add_argument("--summary-json", action="store_true", help="Print a JSON summary.")
    parser.add_argument("--validate-only", action="store_true", help="Validate generation without writing an output file.")
    parser.add_argument("--quiet", action="store_true", help="Suppress human-readable summary output.")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    args = parse_args(argv)
    try:
        validate_dataset()
        suppress_human_summary = args.quiet or args.summary_json
        if args.validate_only:
            summary = validate_only(suppress_human_summary, args.artifact_dir)
        else:
            summary = generate_fixture(args.output, args.overwrite, suppress_human_summary, args.artifact_dir)
        if args.summary_json:
            print(
                json_dumps(
                    {
                        "output_path": summary.output_path,
                        "product_identifier": summary.product_identifier,
                        "node_count": summary.node_count,
                        "edge_count": summary.edge_count,
                        "runtime_diagnostic_count": summary.runtime_diagnostic_count,
                        "production_serial_count": summary.production_serial_count,
                        "artifact_dir": summary.artifact_dir,
                        "artifact_count": summary.artifact_count,
                        "artifact_ids": summary.artifact_ids,
                        "generated_artifact_paths": summary.generated_artifact_paths,
                        "demo_moments": summary.demo_moments,
                    }
                )
            )
        return 0
    except FileExistsError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except Exception as exc:  # pragma: no cover - CLI fallback
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
