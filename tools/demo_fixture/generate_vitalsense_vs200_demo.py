#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
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
COMMIT_BY_ID = {item["id"]: item for item in ds.COMMITS}


@dataclass
class Summary:
    output_path: str
    node_count: int
    edge_count: int
    runtime_diagnostic_count: int
    production_serial_count: int
    product_identifier: str
    demo_moments: dict[str, Any]


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


def compute_execution_status(test_cases: list[dict[str, Any]]) -> str:
    if any(case["status"] in {"failed", "error", "blocked"} for case in test_cases):
        return "failed"
    if all(case["status"] == "passed" for case in test_cases):
        return "passed"
    return "partial"


def ensure_parent_dir(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA_SQL)
    return conn


def initialize_schema(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(SCHEMA_SQL)


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


def validate_dataset() -> None:
    if ds.EXPECTED_PRODUCTION_SERIAL_COUNT != len(ds.generate_passing_ate_batch()) + 2:
        raise ValueError("expected production serial count does not match generated ATE data")

    stale_req = next(item for item in ds.REQUIREMENTS if item["id"] == "SRS-015")
    if stale_req.get("changed_at") != ds.REQUIREMENT_CHANGED_AT:
        raise ValueError("SRS-015 changed_at missing or incorrect")
    if not stale_req.get("previous_statement"):
        raise ValueError("SRS-015 previous_statement missing")

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


def make_requirement_properties(requirement: dict[str, Any]) -> dict[str, Any]:
    props: dict[str, Any] = {
        "statement": requirement["statement"],
        "priority": requirement["priority"],
        "status": requirement["status"],
        "notes": "",
        "declared_test_group_ref_count": str(len(requirement.get("tested_by", []))),
    }
    if requirement.get("safety_class"):
        props["safety_class"] = requirement["safety_class"]
    if requirement.get("changed_at"):
        props["changed_at"] = requirement["changed_at"]
    if requirement.get("risk_ids"):
        props["risk_refs"] = requirement["risk_ids"]
    return props


def make_test_properties(test_case: dict[str, str]) -> dict[str, Any]:
    return {
        "name": test_case["name"],
        "test_id": test_case["id"],
        "test_group_id": test_case["test_group_id"],
        "test_type": test_case["test_type"],
        "test_method": test_case["test_method"],
        "status": test_case["status"],
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


def add_trace_graph(builder: FixtureBuilder) -> None:
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

    for requirement in ds.REQUIREMENTS:
        suspect = requirement["id"] == "SRS-015"
        suspect_reason = None
        updated_at = ds.DEFAULT_CREATED_AT
        if requirement["id"] == "SRS-015":
            updated_at = requirement["changed_at"]
            suspect_reason = "Requirement changed on 2026-03-10 after latest linked execution on 2026-03-05"
        builder.insert_node(
            requirement["id"],
            "Requirement",
            make_requirement_properties(requirement),
            updated_at_iso=updated_at,
            suspect=suspect,
            suspect_reason=suspect_reason,
        )
        if requirement["id"] == "SRS-015":
            previous_props = make_requirement_properties(
                {
                    **requirement,
                    "statement": requirement["previous_statement"],
                    "changed_at": ds.REQUIREMENT_PREVIOUS_UPDATED_AT,
                }
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
            make_test_properties(test_case),
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


def validate_graph(conn: sqlite3.Connection) -> Summary:
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

    for requirement_id in ds.EXPECTED_DEMO_MOMENTS["untested_requirements"]:
        tested_by_count = conn.execute("SELECT COUNT(*) FROM edges WHERE from_id=? AND label='TESTED_BY'", (requirement_id,)).fetchone()[0]
        if tested_by_count != 0:
            raise ValueError(f"{requirement_id} unexpectedly has test coverage")
        impl_count = conn.execute("SELECT COUNT(*) FROM edges WHERE from_id=? AND label='IMPLEMENTED_IN'", (requirement_id,)).fetchone()[0]
        if impl_count != 0:
            raise ValueError(f"{requirement_id} unexpectedly has implementation evidence")

    if conn.execute("SELECT COUNT(*) FROM node_history WHERE node_id='SRS-015'").fetchone()[0] < 1:
        raise ValueError("SRS-015 node_history missing")

    suspect_row = conn.execute("SELECT suspect, suspect_reason FROM nodes WHERE id='SRS-015'").fetchone()
    if not suspect_row or suspect_row[0] != 1 or not suspect_row[1]:
        raise ValueError("SRS-015 suspect metadata missing")

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

    if diagnostic_count < len(ds.DEMO_DIAGNOSTICS):
        raise ValueError("runtime diagnostics count lower than expected")

    return Summary(
        output_path=":memory:",
        node_count=node_count,
        edge_count=edge_count,
        runtime_diagnostic_count=diagnostic_count,
        production_serial_count=production_serial_count,
        product_identifier=ds.PRODUCT_FULL_IDENTIFIER,
        demo_moments=ds.EXPECTED_DEMO_MOMENTS,
    )


def build_fixture(conn: sqlite3.Connection) -> Summary:
    initialize_schema(conn)
    builder = FixtureBuilder(conn)
    add_trace_graph(builder)
    add_bom_graph(builder)
    add_execution_history(builder)
    add_code_trace(builder)
    add_runtime_diagnostics(builder)
    conn.commit()
    return validate_graph(conn)


def generate_fixture(output_path: str, overwrite: bool, quiet: bool) -> Summary:
    path = Path(output_path)
    if path.exists() and not overwrite:
        raise FileExistsError(f"refusing to overwrite existing file without --overwrite: {path}")
    ensure_parent_dir(path)
    if path.exists():
        path.unlink()

    conn = open_db(str(path))
    try:
        summary = build_fixture(conn)
    finally:
        conn.close()

    summary.output_path = str(path)
    if not quiet:
        print_human_summary(summary)
    return summary


def validate_only(quiet: bool) -> Summary:
    conn = sqlite3.connect(":memory:")
    try:
        summary = build_fixture(conn)
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
    print("demo_moments:")
    for key, value in summary.demo_moments.items():
        print(f"  {key}: {value}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate the VitalSense VS-200 RTMify Live demo fixture database.")
    parser.add_argument("--output", default="/tmp/vitalsense-vs200-demo.sqlite", help="Output SQLite database path.")
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
            summary = validate_only(suppress_human_summary)
        else:
            summary = generate_fixture(args.output, args.overwrite, suppress_human_summary)
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
