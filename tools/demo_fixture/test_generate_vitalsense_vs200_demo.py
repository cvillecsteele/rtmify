from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


THIS_DIR = Path(__file__).resolve().parent
if str(THIS_DIR) not in sys.path:
    sys.path.insert(0, str(THIS_DIR))

import generate_vitalsense_vs200_demo as fixture
import vitalsense_vs200_dataset as ds


class VitalSenseFixtureTests(unittest.TestCase):
    def test_validate_only(self) -> None:
        summary = fixture.validate_only(quiet=True)
        self.assertGreater(summary.node_count, 0)
        self.assertGreater(summary.edge_count, 0)
        self.assertEqual(summary.product_identifier, ds.PRODUCT_FULL_IDENTIFIER)
        self.assertEqual(summary.production_serial_count, ds.EXPECTED_PRODUCTION_SERIAL_COUNT)
        self.assertEqual(summary.artifact_count, len(ds.ARTIFACTS))

    def test_validate_only_does_not_write_requested_artifact_dir(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            requested = Path(tmpdir) / "artifacts"
            summary = fixture.validate_only(quiet=True, artifact_dir=str(requested))
            self.assertFalse(requested.exists())
            self.assertTrue(summary.artifact_dir)

    def test_generate_fixture_and_smoke_queries(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = Path(tmpdir) / "vitalsense.sqlite"
            artifact_dir = Path(tmpdir) / "demo-artifacts"
            summary = fixture.generate_fixture(str(db_path), overwrite=True, quiet=True, artifact_dir=str(artifact_dir))
            self.assertTrue(db_path.exists())
            self.assertEqual(Path(summary.artifact_dir), artifact_dir)
            self.assertEqual(summary.artifact_count, len(ds.ARTIFACTS))
            self.assertEqual(set(summary.artifact_ids), {item["id"] for item in ds.ARTIFACTS})
            self.assertEqual(set(summary.generated_artifact_paths), {
                str(artifact_dir / "rtm" / f"{ds.RTM_ARTIFACT_LOGICAL_KEY}.xlsx"),
                str(artifact_dir / "srs" / f"{ds.SRS_ARTIFACT_LOGICAL_KEY}.docx"),
                str(artifact_dir / "sysrd" / f"{ds.SYSRD_ARTIFACT_LOGICAL_KEY}.docx"),
            })

            for generated_path in summary.generated_artifact_paths:
                path = Path(generated_path)
                self.assertTrue(path.exists())
                with zipfile.ZipFile(path, "r") as zf:
                    if path.suffix == ".docx":
                        self.assertIn("word/document.xml", zf.namelist())
                        document_xml = zf.read("word/document.xml").decode("utf-8")
                    else:
                        self.assertIn("xl/workbook.xml", zf.namelist())
                        workbook_xml = zf.read("xl/workbook.xml").decode("utf-8")
                        self.assertIn("Requirements", workbook_xml)
                        self.assertIn("User Needs", workbook_xml)
                        requirements_sheet = zf.read("xl/worksheets/sheet1.xml").decode("utf-8")
                        self.assertIn("SRS-015", requirements_sheet)
                        self.assertIn(ds.REQUIREMENT_TEXTS["SRS-015"], requirements_sheet)
                        continue
                    if "srs" in path.parts:
                        self.assertIn("SRS-015", document_xml)
                        self.assertIn(ds.PREVIOUS_RTM_TEXTS["SRS-015"], document_xml)
                        self.assertIn("SRS-017", document_xml)
                    else:
                        self.assertIn("REQ-003", document_xml)
                        self.assertIn(ds.REQUIREMENT_TEXTS["REQ-003"], document_xml)

            conn = sqlite3.connect(str(db_path))
            try:
                self.assertEqual(
                    conn.execute(
                        "SELECT COUNT(*) FROM nodes WHERE id=? AND type='Product'",
                        (ds.PRODUCT_NODE_ID,),
                    ).fetchone()[0],
                    1,
                )

                requirement_statement_count = conn.execute(
                    """
                    SELECT COUNT(*)
                    FROM nodes
                    WHERE type='Requirement'
                      AND json_extract(properties, '$.statement') IS NOT NULL
                    """
                ).fetchone()[0]
                self.assertEqual(requirement_statement_count, 0)
                requirement_effective_statement_count = conn.execute(
                    """
                    SELECT COUNT(*)
                    FROM nodes
                    WHERE type='Requirement'
                      AND json_extract(properties, '$.effective_statement') IS NOT NULL
                    """
                ).fetchone()[0]
                self.assertEqual(requirement_effective_statement_count, 0)

                artifact_ids = {
                    row[0]
                    for row in conn.execute("SELECT id FROM nodes WHERE type='Artifact'")
                }
                self.assertEqual(artifact_ids, {item["id"] for item in ds.ARTIFACTS})

                requirement_text_count = conn.execute(
                    "SELECT COUNT(*) FROM nodes WHERE type='RequirementText'"
                ).fetchone()[0]
                self.assertEqual(
                    requirement_text_count,
                    sum(len(ds.artifact_assertions_for(item["id"])) for item in ds.ARTIFACTS),
                )

                contains_count = conn.execute(
                    "SELECT COUNT(*) FROM edges WHERE label='CONTAINS'"
                ).fetchone()[0]
                asserts_count = conn.execute(
                    "SELECT COUNT(*) FROM edges WHERE label='ASSERTS'"
                ).fetchone()[0]
                conflict_count = conn.execute(
                    "SELECT COUNT(*) FROM edges WHERE label='CONFLICTS_WITH'"
                ).fetchone()[0]
                self.assertGreaterEqual(contains_count, requirement_text_count)
                self.assertGreaterEqual(asserts_count, requirement_text_count)
                self.assertEqual(conflict_count, 2)

                srs_015 = conn.execute(
                    """
                    SELECT
                      json_extract(properties, '$.text_status'),
                      json_extract(properties, '$.authoritative_source'),
                      json_extract(properties, '$.source_count')
                    FROM nodes
                    WHERE id='SRS-015'
                    """
                ).fetchone()
                self.assertEqual(srs_015[0], "conflict")
                self.assertEqual(srs_015[1], ds.RTM_ARTIFACT_ID)
                self.assertEqual(int(srs_015[2]), 2)

                for req_id in ("SRS-016", "SRS-017"):
                    row = conn.execute(
                        """
                        SELECT
                          json_extract(properties, '$.text_status'),
                          json_extract(properties, '$.authoritative_source'),
                          json_extract(properties, '$.source_count')
                        FROM nodes
                        WHERE id=?
                        """,
                        (req_id,),
                    ).fetchone()
                    self.assertEqual(row[0], "single_source")
                    self.assertEqual(row[1], ds.SRS_ARTIFACT_ID)
                    self.assertEqual(int(row[2]), 1)
                    rtm_assertions = conn.execute(
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
                    self.assertEqual(rtm_assertions, 0)

                req_003 = conn.execute(
                    """
                    SELECT
                      json_extract(properties, '$.text_status'),
                      json_extract(properties, '$.authoritative_source')
                    FROM nodes
                    WHERE id='REQ-003'
                    """
                ).fetchone()
                self.assertEqual(req_003[0], "aligned")
                self.assertEqual(req_003[1], ds.RTM_ARTIFACT_ID)

                self.assertGreaterEqual(
                    conn.execute(
                        "SELECT COUNT(*) FROM node_history WHERE node_id='SRS-015'"
                    ).fetchone()[0],
                    1,
                )
                self.assertGreaterEqual(
                    conn.execute(
                        "SELECT COUNT(*) FROM node_history WHERE node_id=?",
                        (ds.requirement_text_node_id(ds.RTM_ARTIFACT_ID, "SRS-015"),),
                    ).fetchone()[0],
                    1,
                )

                untested = {
                    row[0]
                    for row in conn.execute(
                        """
                        SELECT id
                        FROM nodes
                        WHERE type='Requirement'
                          AND id NOT IN (SELECT from_id FROM edges WHERE label='TESTED_BY')
                        ORDER BY id
                        """
                    )
                }
                self.assertIn("SRS-016", untested)
                self.assertIn("SRS-017", untested)

                unimplemented = {
                    row[0]
                    for row in conn.execute(
                        """
                        SELECT id
                        FROM nodes
                        WHERE type='Requirement'
                          AND id NOT IN (SELECT from_id FROM edges WHERE label='IMPLEMENTED_IN')
                        ORDER BY id
                        """
                    )
                }
                self.assertIn("SRS-016", unimplemented)
                self.assertIn("SRS-017", unimplemented)

                srs_015_changed = conn.execute(
                    "SELECT json_extract(properties, '$.changed_at') FROM nodes WHERE id='SRS-015'"
                ).fetchone()[0]
                latest_fhir_bulk = conn.execute(
                    """
                    SELECT json_extract(e.properties, '$.executed_at')
                    FROM edges eo
                    JOIN nodes r ON r.id = eo.from_id AND r.type='TestResult'
                    JOIN edges hr ON hr.to_id = r.id AND hr.label='HAS_RESULT'
                    JOIN nodes e ON e.id = hr.from_id AND e.type='TestExecution'
                    WHERE eo.label='EXECUTION_OF' AND eo.to_id='TG-FHIR/TC-FHIR-003'
                    ORDER BY json_extract(e.properties, '$.executed_at') DESC
                    LIMIT 1
                    """
                ).fetchone()[0]
                self.assertLess(latest_fhir_bulk, srs_015_changed)

                zlib_eval = conn.execute(
                    """
                    SELECT json_extract(properties, '$.anomaly_evaluation')
                    FROM nodes
                    WHERE id=?
                    """,
                    (fixture.bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "software", ds.SOUP_BOM_NAME, "zlib", "1.2.11"),),
                ).fetchone()[0]
                micro_version = conn.execute(
                    """
                    SELECT json_extract(properties, '$.revision')
                    FROM nodes
                    WHERE id=?
                    """,
                    (fixture.bom_item_id(ds.PRODUCT_FULL_IDENTIFIER, "software", ds.SOUP_BOM_NAME, "Micro-ECC", "unknown"),),
                ).fetchone()[0]
                self.assertEqual(zlib_eval, "")
                self.assertEqual(micro_version, "unknown")

                open_risks = {
                    row[0]
                    for row in conn.execute(
                        "SELECT id FROM nodes WHERE type='Risk' AND json_extract(properties, '$.status')='Open'"
                    )
                }
                self.assertEqual(open_risks, {"RSK-010"})

                failed_units = {
                    row[0]
                    for row in conn.execute(
                        """
                        SELECT json_extract(properties, '$.serial_number')
                        FROM nodes
                        WHERE type='TestExecution' AND json_extract(properties, '$.computed_status')='failed'
                        """
                    )
                }
                self.assertEqual(failed_units, {"UNIT-1246"})

                failed_refs = {
                    row[0]
                    for row in conn.execute(
                        """
                        SELECT json_extract(r.properties, '$.test_case_ref')
                        FROM nodes e
                        JOIN edges hr ON hr.from_id = e.id AND hr.label='HAS_RESULT'
                        JOIN nodes r ON r.id = hr.to_id AND r.type='TestResult'
                        WHERE e.type='TestExecution'
                          AND json_extract(e.properties, '$.serial_number')='UNIT-1246'
                          AND json_extract(r.properties, '$.status')='failed'
                        """
                    )
                }
                self.assertEqual(failed_refs, {"TG-ATP/TC-ATP-004"})

                reqs_for_atp = {
                    row[0]
                    for row in conn.execute(
                        """
                        SELECT e.from_id
                        FROM edges e
                        WHERE e.label='TESTED_BY' AND e.to_id='TG-ATP'
                        """
                    )
                }
                self.assertIn("SRS-005", reqs_for_atp)

                risk_for_srs005 = {
                    row[0]
                    for row in conn.execute(
                        """
                        SELECT r.id
                        FROM nodes r
                        JOIN edges e ON e.from_id = r.id AND e.label='MITIGATED_BY'
                        WHERE r.type='Risk' AND e.to_id='SRS-005'
                        """
                    )
                }
                self.assertIn("RSK-003", risk_for_srs005)

                production_count = conn.execute(
                    """
                    SELECT COUNT(*)
                    FROM nodes
                    WHERE type='TestExecution'
                      AND json_extract(properties, '$.serial_number') IS NOT NULL
                    """
                ).fetchone()[0]
                self.assertEqual(production_count, ds.EXPECTED_PRODUCTION_SERIAL_COUNT)

                diagnostics = {
                    row[0] for row in conn.execute("SELECT dedupe_key FROM runtime_diagnostics")
                }
                self.assertEqual(diagnostics, {item["dedupe_key"] for item in ds.DEMO_DIAGNOSTICS})
            finally:
                conn.close()

    def test_default_artifact_dir_and_cli_summary_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = Path(tmpdir) / "demo.sqlite"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(THIS_DIR / "generate_vitalsense_vs200_demo.py"),
                    "--output",
                    str(db_path),
                    "--overwrite",
                    "--summary-json",
                    "--quiet",
                ],
                check=True,
                text=True,
                capture_output=True,
            )
            data = json.loads(proc.stdout)
            self.assertEqual(data["product_identifier"], ds.PRODUCT_FULL_IDENTIFIER)
            self.assertEqual(data["production_serial_count"], ds.EXPECTED_PRODUCTION_SERIAL_COUNT)
            self.assertEqual(data["artifact_count"], len(ds.ARTIFACTS))
            self.assertEqual(Path(data["artifact_dir"]), Path(f"{db_path}.artifacts"))
            self.assertTrue(db_path.exists())
            for generated_path in data["generated_artifact_paths"]:
                self.assertTrue(Path(generated_path).exists())


if __name__ == "__main__":
    unittest.main()
