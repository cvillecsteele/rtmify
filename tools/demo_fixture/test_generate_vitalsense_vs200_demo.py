from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
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

    def test_generate_fixture_and_smoke_queries(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = Path(tmpdir) / "vitalsense.sqlite"
            summary = fixture.generate_fixture(str(db_path), overwrite=True, quiet=True)
            self.assertTrue(db_path.exists())
            self.assertGreater(summary.runtime_diagnostic_count, 0)

            conn = sqlite3.connect(str(db_path))
            try:
                self.assertEqual(
                    conn.execute(
                        "SELECT COUNT(*) FROM nodes WHERE id=? AND type='Product'",
                        (ds.PRODUCT_NODE_ID,),
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
            finally:
                conn.close()

    def test_cli_summary_json(self) -> None:
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
            self.assertTrue(db_path.exists())


if __name__ == "__main__":
    unittest.main()
