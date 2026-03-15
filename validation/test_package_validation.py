#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import zipfile
import re
from pathlib import Path

sys_path = Path(__file__).resolve().parent

if str(sys_path) not in sys.path:
    sys.path.insert(0, str(sys_path))

import package_validation


class ValidationPackageTests(unittest.TestCase):
    def test_compare_expected_results_accepts_expected_file(self) -> None:
        expected = package_validation.load_json(package_validation.EXPECTED_GAPS_PATH)
        package_validation.compare_expected_results(expected, expected)

    def test_compare_expected_results_rejects_wrong_gap_count(self) -> None:
        expected = package_validation.load_json(package_validation.EXPECTED_GAPS_PATH)
        actual = json.loads(json.dumps(expected))
        actual["gap_count"] = 99
        with self.assertRaises(package_validation.ValidationPackageError):
            package_validation.compare_expected_results(expected, actual)

    def test_compare_expected_results_rejects_profile_metadata_drift(self) -> None:
        expected = package_validation.load_json(package_validation.EXPECTED_GAPS_PATH)
        actual = json.loads(json.dumps(expected))
        actual["gaps"][4]["profile_rule"] = "wrong_rule"
        with self.assertRaises(package_validation.ValidationPackageError):
            package_validation.compare_expected_results(expected, actual)

    def test_generic_regression_rejects_profile_gap_metadata(self) -> None:
        actual = {
            "profile": "generic",
            "gaps": [
                {
                    "code": 1201,
                    "profile_rule": "medical_user_need_requirement_chain",
                    "clause": "ISO 13485 §7.3.2",
                }
            ],
        }
        with self.assertRaises(package_validation.ValidationPackageError):
            package_validation.assert_generic_run_has_no_profile_gaps(actual)

    def test_write_checksums_contains_all_platform_entries(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            mac = tmp_dir / "mac"
            windows = tmp_dir / "win.exe"
            linux = tmp_dir / "linux"
            for path in (mac, windows, linux):
                path.write_text("sample")
            checksums = tmp_dir / "checksums.txt"
            package_validation.write_checksums(checksums, mac, windows, linux)
            content = checksums.read_text()
            self.assertIn("trace/macos/rtmify-trace", content)
            self.assertIn("trace/windows/rtmify-trace.exe", content)
            self.assertIn("trace/linux/rtmify-trace", content)

    def test_make_zip_includes_expected_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            src = tmp_dir / "package"
            (src / "golden").mkdir(parents=True)
            (src / "golden" / "golden-gaps.json").write_text("{}")
            (src / "checksums.txt").write_text("abc")
            (src / "README.txt").write_text("hello")
            zf = tmp_dir / "package.zip"
            package_validation.make_zip(src, zf)
            with zipfile.ZipFile(zf) as archive:
                names = set(archive.namelist())
            self.assertIn("golden/golden-gaps.json", names)
            self.assertIn("checksums.txt", names)
            self.assertIn("README.txt", names)

    def test_package_readme_mentions_order_of_operations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "README.txt"
            package_validation.write_package_readme(path, "1.2.3", "RTMify_OQ_Fixture_v1.2.3.xlsx")
            content = path.read_text()
            self.assertIn("RTMify Trace Validation Package v1.2.3", content)
            self.assertIn("Recommended order of operations", content)
            self.assertIn("--profile medical", content)
            self.assertIn("golden/", content)

    def test_workbook_snapshot_matches_committed_fixture_shape(self) -> None:
        fixture = package_validation.committed_fixture_path()
        snapshot = package_validation.workbook_snapshot(fixture)
        self.assertEqual(
            ["ID", "Statement", "Source of Need Statement", "Priority", "RTMify Status"],
            snapshot["User Needs"][0],
        )
        self.assertEqual("REQ-001", snapshot["Requirements"][1][0])
        self.assertEqual("TG-001", snapshot["Tests"][1][0])
        self.assertEqual("RSK-001", snapshot["Risks"][1][0])
        self.assertEqual("DI-001", snapshot["Design Inputs"][1][0])
        self.assertEqual("DO-001", snapshot["Design Outputs"][1][0])

    def test_protocol_defines_all_referenced_output_checkpoints(self) -> None:
        protocol = (sys_path / "protocol.html").read_text()
        referenced = set(re.findall(r"CP-OQ-\d{2}", protocol))
        self.assertEqual(
            {
                "CP-OQ-01",
                "CP-OQ-02",
                "CP-OQ-03",
                "CP-OQ-04",
                "CP-OQ-05",
                "CP-OQ-06",
                "CP-OQ-07",
                "CP-OQ-08",
                "CP-OQ-09",
                "CP-OQ-10",
                "CP-OQ-11",
                "CP-OQ-12",
            },
            referenced,
        )
        self.assertIn("Appendix — Output Verification Checkpoints", protocol)
        self.assertIn("--profile {{profile_name}}", protocol)
        self.assertIn("Use these checkpoints when completing OQ-06, OQ-07, OQ-08, and OQ-09.", protocol)
        for checkpoint in sorted(referenced):
            self.assertRegex(protocol, rf"<tr><td>{checkpoint}</td><td>.+?</td></tr>")


if __name__ == "__main__":
    unittest.main()
