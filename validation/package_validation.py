#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import openpyxl


ROOT = Path(__file__).resolve().parent
EXPECTED_GAPS_PATH = ROOT / "expected-gaps.json"
COMMITTED_FIXTURE_GLOB = "RTMify_OQ_Fixture_v*.xlsx"
RELEVANT_SHEETS = {
    "User Needs": 5,
    "Requirements": 8,
    "Tests": 6,
    "Risks": 8,
    "Design Inputs": 4,
    "Design Outputs": 6,
    "Configuration Items": 6,
}
VALIDATION_PROFILE = "medical"
PROFILE_CODE_MIN = 1200
PROFILE_CODE_MAX = 1299


class ValidationPackageError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the RTMify Trace validation package.")
    parser.add_argument("--version", required=True)
    parser.add_argument("--trace-binary", required=True)
    parser.add_argument("--trace-binary-windows", required=True)
    parser.add_argument("--trace-binary-linux", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--checksums-file", required=True)
    return parser.parse_args()


def committed_fixture_path() -> Path:
    matches = sorted(ROOT.glob(COMMITTED_FIXTURE_GLOB))
    if not matches:
        raise ValidationPackageError("No committed validation fixture workbook found.")
    return matches[0]


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def strip_row(values: list[object]) -> list[object]:
    trimmed = list(values)
    while trimmed and trimmed[-1] is None:
        trimmed.pop()
    return trimmed


def workbook_snapshot(path: Path) -> dict[str, list[list[object]]]:
    wb = openpyxl.load_workbook(path)
    snapshot: dict[str, list[list[object]]] = {}
    for sheet_name, width in RELEVANT_SHEETS.items():
        ws = wb[sheet_name]
        rows: list[list[object]] = []
        for row in ws.iter_rows(values_only=True):
            rows.append(strip_row(list(row[:width])))
        snapshot[sheet_name] = rows
    return snapshot


def compare_workbooks(expected: Path, actual: Path) -> None:
    expected_snapshot = workbook_snapshot(expected)
    actual_snapshot = workbook_snapshot(actual)
    if expected_snapshot != actual_snapshot:
        raise ValidationPackageError(
            f"Regenerated fixture {actual} drifted from committed fixture {expected}."
        )


def normalize_gap(gap: dict) -> tuple:
    return (
        gap.get("severity"),
        gap.get("code"),
        gap.get("kind"),
        gap.get("primary_id"),
        gap.get("node_id"),
        gap.get("related_id"),
        gap.get("profile_rule"),
        gap.get("clause"),
        gap.get("message"),
    )


def normalize_diagnostic(diagnostic: dict) -> tuple:
    return (
        diagnostic.get("level"),
        diagnostic.get("code"),
        diagnostic.get("source"),
        diagnostic.get("tab"),
        diagnostic.get("row"),
        diagnostic.get("message"),
    )


def compare_expected_results(expected: dict, actual: dict) -> None:
    root_fields = ("profile", "gap_count", "warning_count", "error_count")
    for field in root_fields:
        if expected.get(field) != actual.get(field):
            raise ValidationPackageError(
                f"Generated gaps JSON field {field}={actual.get(field)!r} did not match expected {expected.get(field)!r}."
            )

    expected_gaps = sorted(normalize_gap(item) for item in expected.get("gaps", []))
    actual_gaps = sorted(normalize_gap(item) for item in actual.get("gaps", []))
    if expected_gaps != actual_gaps:
        raise ValidationPackageError("Generated gaps JSON gaps[] did not match expected-gaps.json.")

    expected_diags = sorted(normalize_diagnostic(item) for item in expected.get("diagnostics", []))
    actual_diags = sorted(normalize_diagnostic(item) for item in actual.get("diagnostics", []))
    if expected_diags != actual_diags:
        raise ValidationPackageError("Generated gaps JSON diagnostics[] did not match expected-gaps.json.")


def assert_generic_run_has_no_profile_gaps(actual: dict) -> None:
    if actual.get("profile") != "generic":
        raise ValidationPackageError("Generic regression run did not report profile='generic'.")
    for gap in actual.get("gaps", []):
        code = gap.get("code")
        profile_rule = gap.get("profile_rule")
        clause = gap.get("clause")
        if code is not None and PROFILE_CODE_MIN <= code <= PROFILE_CODE_MAX:
            raise ValidationPackageError("Generic regression run emitted profile E12xx gap codes.")
        if profile_rule is not None or clause is not None:
            raise ValidationPackageError("Generic regression run emitted profile_rule/clause metadata.")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_checksums(path: Path, mac_trace: Path, windows_trace: Path, linux_trace: Path) -> None:
    entries = [
        (sha256_file(mac_trace), "trace/macos/rtmify-trace"),
        (sha256_file(windows_trace), "trace/windows/rtmify-trace.exe"),
        (sha256_file(linux_trace), "trace/linux/rtmify-trace"),
    ]
    with path.open("w", encoding="utf-8") as fh:
        for digest, rel in entries:
            fh.write(f"{digest}  {rel}\n")


def write_package_readme(path: Path, version: str, fixture_name: str) -> None:
    path.write_text(
        "\n".join(
            [
                f"RTMify Trace Validation Package v{version}",
                "",
                f"This package qualifies RTMify Trace against the controlled fixture {fixture_name} using the {VALIDATION_PROFILE} industry profile. The fixture is the input, the files under golden/ are the known-good reference outputs, the protocol PDF is the step-by-step IQ/OQ procedure, the evidence PDF is the blank record your quality team completes, and checksums.txt contains the published SHA-256 hashes for the Trace binaries covered by this package.",
                "",
                f"Recommended order of operations: first verify the Trace binary version and hash using the protocol and checksums.txt, then run the fixture through Trace with --profile {VALIDATION_PROFILE} to produce customer.pdf, customer.docx, customer.md, and customer-gaps.json, then compare those results to the files in golden/ while completing the protocol and evidence record.",
                "",
                "When finished, file the completed evidence record, the generated customer outputs, and any comparison evidence in your quality system.",
                "",
            ]
        ),
        encoding="utf-8",
    )


def run(cmd: list[str], *, allow_exit_codes: tuple[int, ...] = (0,), env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(cmd, check=False, capture_output=True, text=True, env=env)
    if result.returncode not in allow_exit_codes:
        raise ValidationPackageError(
            f"Command failed ({result.returncode}): {' '.join(cmd)}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def render_pdf(template_name: str, output_path: Path, data_path: Path) -> None:
    run(
        [
            "node",
            str(ROOT / "render_pdf.mjs"),
            "--input",
            str(ROOT / template_name),
            "--output",
            str(output_path),
            "--data",
            str(data_path),
        ]
    )


def make_zip(source_dir: Path, zip_path: Path) -> None:
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(source_dir.rglob("*")):
            if path.is_dir():
                continue
            zf.write(path, arcname=path.relative_to(source_dir))


def create_package(args: argparse.Namespace) -> None:
    version = args.version
    trace_binary = Path(args.trace_binary).resolve()
    trace_binary_windows = Path(args.trace_binary_windows).resolve()
    trace_binary_linux = Path(args.trace_binary_linux).resolve()
    out_dir = Path(args.out_dir).resolve()
    checksums_file = Path(args.checksums_file).resolve()
    package_root = out_dir
    validation_root = package_root.parent
    zip_path = validation_root / f"RTMify_Trace_Validation_Package_v{version}.zip"
    package_root.mkdir(parents=True, exist_ok=True)
    golden_dir = package_root / "golden"
    golden_dir.mkdir(parents=True, exist_ok=True)

    fixture_name = f"RTMify_OQ_Fixture_v{version}.xlsx"
    versioned_fixture = package_root / fixture_name
    committed_fixture = committed_fixture_path()

    with tempfile.TemporaryDirectory(prefix="rtmify-validation-") as tmp:
        tmp_dir = Path(tmp)
        shutil.copy2(committed_fixture, versioned_fixture)
        strict_docx = tmp_dir / "strict.docx"
        generic_docx = tmp_dir / "generic.docx"
        generic_gaps = tmp_dir / "generic-gaps.json"

        golden_pdf = golden_dir / "golden.pdf"
        golden_docx = golden_dir / "golden.docx"
        golden_md = golden_dir / "golden.md"
        golden_gaps = golden_dir / "golden-gaps.json"

        run([str(trace_binary), str(versioned_fixture), "--profile", VALIDATION_PROFILE, "--format", "pdf", "--output", str(golden_pdf)])
        run([str(trace_binary), str(versioned_fixture), "--profile", VALIDATION_PROFILE, "--format", "docx", "--output", str(golden_docx)])
        run([str(trace_binary), str(versioned_fixture), "--profile", VALIDATION_PROFILE, "--format", "md", "--output", str(golden_md)])
        run(
            [
                str(trace_binary),
                str(versioned_fixture),
                "--profile",
                VALIDATION_PROFILE,
                "--strict",
                "--output",
                str(strict_docx),
                "--gaps-json",
                str(golden_gaps),
            ],
            allow_exit_codes=(5,),
        )

        compare_expected_results(load_json(EXPECTED_GAPS_PATH), load_json(golden_gaps))
        run(
            [
                str(trace_binary),
                str(versioned_fixture),
                "--profile",
                "generic",
                "--strict",
                "--output",
                str(generic_docx),
                "--gaps-json",
                str(generic_gaps),
            ],
            allow_exit_codes=(1,),
        )
        assert_generic_run_has_no_profile_gaps(load_json(generic_gaps))

        write_checksums(checksums_file, trace_binary, trace_binary_windows, trace_binary_linux)
        write_package_readme(package_root / "README.txt", version, fixture_name)

        render_data = {
            "version": version,
            "fixture_filename": fixture_name,
            "profile_name": VALIDATION_PROFILE,
            "release_date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        }
        render_data_path = validation_root / "render-data.json"
        render_data_path.write_text(json.dumps(render_data, indent=2))

        try:
            render_pdf("protocol.html", package_root / f"RTMify_Trace_IQOQ_Protocol_v{version}.pdf", render_data_path)
            render_pdf("evidence.html", package_root / f"RTMify_Trace_IQOQ_Evidence_v{version}.pdf", render_data_path)
        finally:
            if render_data_path.exists():
                render_data_path.unlink()

        make_zip(package_root, zip_path)


def main() -> None:
    args = parse_args()
    try:
        create_package(args)
    except ValidationPackageError as err:
        print(f"Error: {err}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
