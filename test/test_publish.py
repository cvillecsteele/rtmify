"""Comprehensive test suite for tools/publish.py.

Replaces:
- test/test_package.sh (59 tests)
- test/test_generate_download_manifest.py (2 tests)
- test/test_release_version.sh (version helper tests)
"""

from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tools.publish import (
    LINUX_REQUIRED_ARTIFACTS,
    MACOS_REQUIRED_ARTIFACTS,
    WINDOWS_LIVE_FINAL_TEMPLATE,
    WINDOWS_LIVE_UNSIGNED_TEMPLATE,
    WINDOWS_PAYLOAD_ZIP_TEMPLATE,
    WINDOWS_REQUIRED_ARTIFACTS,
    WINDOWS_SIGNED_BINARY_PATHS,
    WINDOWS_TRACE_FINAL_TEMPLATE,
    WINDOWS_TRACE_UNSIGNED_TEMPLATE,
    ChecksumFile,
    LinuxCredentials,
    MacOSCredentials,
    PlatformSelection,
    PublishState,
    StepCounter,
    WindowsCredentials,
    _resolve_jsign_cmd,
    build_asset_entry,
    build_download_manifest,
    collect_and_write_package_manifest,
    create_deterministic_zip,
    find_latest_release_dir,
    finalize_windows_installers,
    increment_release_suffix,
    infer_kind,
    infer_product,
    is_valid_release_version,
    main,
    next_release_version,
    package_linux,
    product_title,
    read_release_version,
    release_url,
    run_cmd,
    sha256_file,
    sha256_path,
    stage_windows_payloads,
    validate_release_prereqs,
    validate_windows_unsigned_dir,
    write_release_version,
)


# ---------------------------------------------------------------------------
# Version Helpers
# ---------------------------------------------------------------------------


def test_is_valid_release_version_valid():
    assert is_valid_release_version("20260328-a")
    assert is_valid_release_version("20260328-abc")


def test_is_valid_release_version_invalid():
    assert not is_valid_release_version("")
    assert not is_valid_release_version("not-a-version")
    assert not is_valid_release_version("2026032-a")  # 7 digits
    assert not is_valid_release_version("20260328-A")  # uppercase
    assert not is_valid_release_version("20260328-1")  # digit suffix


def test_increment_release_suffix():
    assert increment_release_suffix("a") == "b"
    assert increment_release_suffix("y") == "z"
    assert increment_release_suffix("z") == "aa"
    assert increment_release_suffix("az") == "ba"
    assert increment_release_suffix("zz") == "aaa"


def test_next_release_version_new_day():
    assert next_release_version("20260308-c", "20260314") == "20260314-a"


def test_next_release_version_same_day():
    assert next_release_version("20260308-a", "20260308") == "20260308-b"


def test_read_release_version(tmp_path):
    f = tmp_path / "options.zig"
    f.write_text('const default_version = "20260328-a";\n')
    assert read_release_version(f) == "20260328-a"


def test_write_release_version(tmp_path):
    f = tmp_path / "options.zig"
    f.write_text('const default_version = "20260328-a";\nconst other = "foo";\n')
    write_release_version(f, "20260329-b")
    assert read_release_version(f) == "20260329-b"
    assert "other" in f.read_text()  # didn't destroy other content


# ---------------------------------------------------------------------------
# PlatformSelection
# ---------------------------------------------------------------------------


def test_platform_selection_default_all():
    p = PlatformSelection.from_flags(macos=False, windows=False, linux=False)
    assert p.macos and p.windows and p.linux


def test_platform_selection_single():
    p = PlatformSelection.from_flags(macos=False, windows=True, linux=False)
    assert not p.macos and p.windows and not p.linux


def test_platform_selection_combined():
    p = PlatformSelection.from_flags(macos=True, windows=False, linux=True)
    assert p.macos and not p.windows and p.linux


def test_platform_selection_description():
    assert "macOS" in PlatformSelection(macos=True, windows=False, linux=False).description
    assert "Windows" in PlatformSelection(macos=False, windows=True, linux=False).description


# ---------------------------------------------------------------------------
# Hashing and Checksums
# ---------------------------------------------------------------------------


def test_sha256_file_deterministic(tmp_path):
    f = tmp_path / "test.txt"
    f.write_text("hello\n")
    h1 = sha256_file(f)
    h2 = sha256_file(f)
    assert h1 == h2
    assert len(h1) == 64


def test_checksum_file_record_and_write(tmp_path):
    f = tmp_path / "data.txt"
    f.write_text("content")
    cf = ChecksumFile()
    sha = cf.record("data.txt", f)
    assert len(sha) == 64
    out = tmp_path / "checksums.txt"
    cf.write(out)
    text = out.read_text()
    assert "data.txt" in text
    assert sha in text


def test_checksum_file_replaces_existing(tmp_path):
    f = tmp_path / "data.txt"
    f.write_text("before")
    cf = ChecksumFile()
    sha1 = cf.record("data.txt", f)
    f.write_text("after")
    sha2 = cf.record("data.txt", f)
    assert sha1 != sha2
    out = tmp_path / "checksums.txt"
    cf.write(out)
    lines = out.read_text().strip().split("\n")
    assert len(lines) == 1  # replaced, not duplicated
    assert sha2 in lines[0]


# ---------------------------------------------------------------------------
# Deterministic Zip
# ---------------------------------------------------------------------------


def test_deterministic_zip_reproducible(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "a.txt").write_text("aaa")
    (src / "b.txt").write_text("bbb")

    out1 = tmp_path / "out1.zip"
    out2 = tmp_path / "out2.zip"
    create_deterministic_zip(src, out1)
    create_deterministic_zip(src, out2)
    assert out1.read_bytes() == out2.read_bytes()


def test_deterministic_zip_contents(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "hello.txt").write_text("hello")
    out = tmp_path / "out.zip"
    create_deterministic_zip(src, out)

    with zipfile.ZipFile(out) as zf:
        assert "hello.txt" in zf.namelist()
        assert zf.read("hello.txt") == b"hello"


# ---------------------------------------------------------------------------
# Jsign Resolution
# ---------------------------------------------------------------------------


def test_resolve_jsign_cmd_explicit_bin(tmp_path):
    fake = tmp_path / "jsign"
    fake.write_text("#!/bin/sh\n")
    fake.chmod(0o755)
    result = _resolve_jsign_cmd(str(fake), "")
    assert isinstance(result, list)
    assert str(fake) in result


def test_resolve_jsign_cmd_not_found():
    result = _resolve_jsign_cmd("/nonexistent/jsign", "")
    assert isinstance(result, str)  # error message


def test_resolve_jsign_cmd_jar(tmp_path, monkeypatch):
    import shutil

    jar = tmp_path / "jsign.jar"
    jar.write_text("fake jar")
    # Hide jsign from PATH so the function falls through to jar logic
    original_which = shutil.which

    def patched_which(name, *args, **kwargs):
        if name == "jsign":
            return None
        return original_which(name, *args, **kwargs)

    monkeypatch.setattr(shutil, "which", patched_which)
    if original_which("java"):
        result = _resolve_jsign_cmd("", str(jar))
        assert isinstance(result, list)
        assert "java" in result[0]


# ---------------------------------------------------------------------------
# Release Artifact Validation
# ---------------------------------------------------------------------------


def test_validate_release_prereqs_linux_missing_file(tmp_path):
    """Missing file on disk should exit 2."""
    release_dir = tmp_path / "rel"
    (release_dir / "linux").mkdir(parents=True)
    manifest = {
        "version": "20260328-a",
        "artifacts": [
            {"path": "linux/rtmify-trace", "product": "trace", "platform": "linux"}
        ],
    }
    (release_dir / "manifest.json").write_text(json.dumps(manifest))
    # File is in manifest but NOT on disk
    with pytest.raises(SystemExit) as exc_info:
        validate_release_prereqs(
            release_dir,
            manifest,
            PlatformSelection(macos=False, windows=False, linux=True),
        )
    assert exc_info.value.code == 2


def test_validate_release_prereqs_linux_missing_manifest_entry(tmp_path):
    """Missing entry in manifest should exit 2."""
    release_dir = tmp_path / "rel"
    linux_dir = release_dir / "linux"
    linux_dir.mkdir(parents=True)
    (linux_dir / "rtmify-trace").write_text("binary")
    manifest = {"version": "20260328-a", "artifacts": []}  # no entry
    (release_dir / "manifest.json").write_text(json.dumps(manifest))

    with pytest.raises(SystemExit) as exc_info:
        validate_release_prereqs(
            release_dir,
            manifest,
            PlatformSelection(macos=False, windows=False, linux=True),
        )
    assert exc_info.value.code == 2


# ---------------------------------------------------------------------------
# Linux Packaging — helpers
# ---------------------------------------------------------------------------


def _make_linux_release(tmp_path, version="20260328-a"):
    """Create a minimal release dir with linux binary."""
    release_dir = tmp_path / "release"
    linux_dir = release_dir / "linux"
    linux_dir.mkdir(parents=True)
    (linux_dir / "rtmify-trace").write_text("#!/bin/sh\necho hello")
    (linux_dir / "rtmify-trace").chmod(0o755)
    manifest = {
        "version": version,
        "artifacts": [
            {
                "path": "linux/rtmify-trace",
                "product": "trace",
                "platform": "linux",
                "sha256": "test",
            }
        ],
    }
    (release_dir / "manifest.json").write_text(json.dumps(manifest))
    return release_dir


def test_linux_tarball_creation(tmp_path):
    release_dir = _make_linux_release(tmp_path)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    tarball = (
        release_dir / "packages" / "linux" / "rtmify-trace-linux-x64-20260328-a.tar.gz"
    )
    assert tarball.is_file()


def test_linux_tarball_contents(tmp_path):
    import tarfile

    release_dir = _make_linux_release(tmp_path)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    tarball = (
        release_dir / "packages" / "linux" / "rtmify-trace-linux-x64-20260328-a.tar.gz"
    )
    with tarfile.open(tarball) as tf:
        names = tf.getnames()
        assert "rtmify-trace" in names


def test_linux_multiple_binaries(tmp_path):
    release_dir = _make_linux_release(tmp_path)
    (release_dir / "linux" / "rtmify-live").write_text("#!/bin/sh\necho live")
    (release_dir / "linux" / "rtmify-live").chmod(0o755)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    assert (
        release_dir / "packages" / "linux" / "rtmify-trace-linux-x64-20260328-a.tar.gz"
    ).is_file()
    assert (
        release_dir / "packages" / "linux" / "rtmify-live-linux-x64-20260328-a.tar.gz"
    ).is_file()


def test_linux_manifest_written(tmp_path):
    release_dir = _make_linux_release(tmp_path)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    collect_and_write_package_manifest(release_dir, "20260328-a")

    pkg_manifest = json.loads((release_dir / "package-manifest.json").read_text())
    assert "linux" in pkg_manifest
    packages = pkg_manifest["linux"]["packages"]
    assert len(packages) >= 1
    assert packages[0]["product"] == "trace"
    assert "sha256" in packages[0]


def test_linux_checksums_written(tmp_path):
    release_dir = _make_linux_release(tmp_path)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    collect_and_write_package_manifest(release_dir, "20260328-a")

    checksums = (release_dir / "checksums.txt").read_text()
    assert "packages/linux/rtmify-trace-linux-x64-20260328-a.tar.gz" in checksums


# ---------------------------------------------------------------------------
# Windows Packaging — helpers
# ---------------------------------------------------------------------------


def _make_windows_release(tmp_path, version="20260328-a"):
    release_dir = tmp_path / "release"
    win_dir = release_dir / "windows"
    win_dir.mkdir(parents=True)
    (win_dir / "rtmify-trace.exe").write_bytes(b"trace exe")
    (win_dir / "RTMify Live.exe").write_bytes(b"live shell exe")
    (win_dir / "rtmify-live.exe").write_bytes(b"live server exe")
    manifest = {
        "version": version,
        "artifacts": [
            {
                "path": "windows/rtmify-trace.exe",
                "product": "trace",
                "platform": "windows",
                "sha256": "t",
            },
            {
                "path": "windows/RTMify Live.exe",
                "product": "live",
                "platform": "windows",
                "sha256": "l",
            },
            {
                "path": "windows/rtmify-live.exe",
                "product": "live",
                "platform": "windows",
                "sha256": "s",
            },
        ],
    }
    (release_dir / "manifest.json").write_text(json.dumps(manifest))
    return release_dir


def _make_fake_jsign(tmp_path):
    """Create a fake jsign that logs invocations and exits 0."""
    fake = tmp_path / "fake-jsign.sh"
    fake.write_text("#!/bin/sh\nexit 0\n")
    fake.chmod(0o755)
    return fake


def test_windows_stage_creates_payload_zip(tmp_path):
    from tools.publish import ResolvedWindowsContext

    release_dir = _make_windows_release(tmp_path)
    fake_jsign = _make_fake_jsign(tmp_path)
    ctx = ResolvedWindowsContext(
        jsign_cmd=[str(fake_jsign)],
        access_token="test-token",
        endpoint="https://eus.codesigning.azure.net",
        account="RTMify",
        profile="RTMify",
    )
    stage_windows_payloads(release_dir, "20260328-a", ctx)
    payload_zip = (
        release_dir / "packages" / "windows" / "RTMify_Windows_Payloads_20260328-a.zip"
    )
    assert payload_zip.is_file()


def test_windows_payload_zip_contents(tmp_path):
    from tools.publish import ResolvedWindowsContext

    release_dir = _make_windows_release(tmp_path)
    fake_jsign = _make_fake_jsign(tmp_path)
    ctx = ResolvedWindowsContext(
        jsign_cmd=[str(fake_jsign)],
        access_token="test-token",
        endpoint="https://eus.codesigning.azure.net",
        account="RTMify",
        profile="RTMify",
    )
    stage_windows_payloads(release_dir, "20260328-a", ctx)
    payload_zip = (
        release_dir / "packages" / "windows" / "RTMify_Windows_Payloads_20260328-a.zip"
    )

    with zipfile.ZipFile(payload_zip) as zf:
        names = sorted(zf.namelist())
        assert "RTMify Live.exe" in names
        assert "rtmify-live.exe" in names
        assert "rtmify-trace.exe" in names
        assert "windows-installer-input.json" in names


def test_windows_stage_manifest_status(tmp_path):
    from tools.publish import ResolvedWindowsContext

    release_dir = _make_windows_release(tmp_path)
    fake_jsign = _make_fake_jsign(tmp_path)
    ctx = ResolvedWindowsContext(
        jsign_cmd=[str(fake_jsign)],
        access_token="test-token",
        endpoint="https://eus.codesigning.azure.net",
        account="RTMify",
        profile="RTMify",
    )
    stage_windows_payloads(release_dir, "20260328-a", ctx)
    collect_and_write_package_manifest(release_dir, "20260328-a")

    pkg = json.loads((release_dir / "package-manifest.json").read_text())
    assert pkg["windows"]["status"] == "payloads_signed"
    assert pkg["windows"]["installers"] == []


def test_windows_finalize_rejects_wrong_filenames(tmp_path):
    unsigned_dir = tmp_path / "unsigned"
    unsigned_dir.mkdir()
    (unsigned_dir / "wrong-name.exe").write_bytes(b"wrong")
    with pytest.raises(SystemExit) as exc_info:
        validate_windows_unsigned_dir(unsigned_dir, "20260328-a")
    assert exc_info.value.code == 2


def test_windows_finalize_creates_signed_installers(tmp_path):
    from tools.publish import ResolvedWindowsContext

    release_dir = _make_windows_release(tmp_path)
    fake_jsign = _make_fake_jsign(tmp_path)
    ctx = ResolvedWindowsContext(
        jsign_cmd=[str(fake_jsign)],
        access_token="test-token",
        endpoint="https://eus.codesigning.azure.net",
        account="RTMify",
        profile="RTMify",
    )
    # Stage first
    stage_windows_payloads(release_dir, "20260328-a", ctx)

    # Create unsigned installers (simulating CI output)
    unsigned_dir = tmp_path / "unsigned"
    unsigned_dir.mkdir()
    (unsigned_dir / "RTMify_Trace_Installer_20260328-a_unsigned.exe").write_bytes(
        b"trace unsigned"
    )
    (unsigned_dir / "RTMify_Live_Installer_20260328-a_unsigned.exe").write_bytes(
        b"live unsigned"
    )

    finalize_windows_installers(release_dir, "20260328-a", unsigned_dir, ctx)

    assert (
        release_dir
        / "packages"
        / "windows"
        / "RTMify_Trace_Installer_20260328-a.exe"
    ).is_file()
    assert (
        release_dir
        / "packages"
        / "windows"
        / "RTMify_Live_Installer_20260328-a.exe"
    ).is_file()


def test_windows_finalize_manifest_status(tmp_path):
    from tools.publish import ResolvedWindowsContext

    release_dir = _make_windows_release(tmp_path)
    fake_jsign = _make_fake_jsign(tmp_path)
    ctx = ResolvedWindowsContext(
        jsign_cmd=[str(fake_jsign)],
        access_token="test-token",
        endpoint="https://eus.codesigning.azure.net",
        account="RTMify",
        profile="RTMify",
    )
    stage_windows_payloads(release_dir, "20260328-a", ctx)

    unsigned_dir = tmp_path / "unsigned"
    unsigned_dir.mkdir()
    (unsigned_dir / "RTMify_Trace_Installer_20260328-a_unsigned.exe").write_bytes(
        b"trace"
    )
    (unsigned_dir / "RTMify_Live_Installer_20260328-a_unsigned.exe").write_bytes(
        b"live"
    )
    finalize_windows_installers(release_dir, "20260328-a", unsigned_dir, ctx)
    collect_and_write_package_manifest(release_dir, "20260328-a")

    pkg = json.loads((release_dir / "package-manifest.json").read_text())
    assert pkg["windows"]["status"] == "finalized"
    assert len(pkg["windows"]["installers"]) == 2


# ---------------------------------------------------------------------------
# Manifest Collection
# ---------------------------------------------------------------------------


def test_manifest_linux_only(tmp_path):
    release_dir = _make_linux_release(tmp_path)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    collect_and_write_package_manifest(release_dir, "20260328-a")

    pkg = json.loads((release_dir / "package-manifest.json").read_text())
    assert "linux" in pkg
    assert "macos" not in pkg
    assert "windows" not in pkg


def test_manifest_sha_consistency(tmp_path):
    """SHA in checksums.txt should match SHA in package-manifest.json."""
    release_dir = _make_linux_release(tmp_path)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    collect_and_write_package_manifest(release_dir, "20260328-a")

    pkg = json.loads((release_dir / "package-manifest.json").read_text())
    checksums_text = (release_dir / "checksums.txt").read_text()

    for pkg_entry in pkg["linux"]["packages"]:
        assert pkg_entry["sha256"] in checksums_text


# ---------------------------------------------------------------------------
# Download Manifest (port from test_generate_download_manifest.py)
# ---------------------------------------------------------------------------


def test_download_manifest_full(tmp_path):
    """Port of test_build_manifest_includes_packaged_assets_and_metadata."""
    release_dir = tmp_path / "rel"
    (release_dir / "packages" / "macos").mkdir(parents=True)
    (release_dir / "packages" / "windows").mkdir(parents=True)
    (release_dir / "packages" / "linux").mkdir(parents=True)
    (release_dir / "validation" / "package").mkdir(parents=True)

    (release_dir / "packages" / "macos" / "RTMify_Trace_20260329-a.dmg").write_bytes(
        b"mac trace"
    )
    (
        release_dir / "packages" / "linux" / "rtmify-trace-linux-x64-20260329-a.tar.gz"
    ).write_bytes(b"linux trace")
    (
        release_dir
        / "packages"
        / "windows"
        / "RTMify_Trace_Installer_20260329-a.exe"
    ).write_bytes(b"win trace")
    (release_dir / "checksums.txt").write_text("abc  checksums.txt\n")
    (
        release_dir
        / "validation"
        / "RTMify_Trace_Validation_Package_v20260329-a.zip"
    ).write_bytes(b"zip")
    (
        release_dir
        / "validation"
        / "package"
        / "RTMify_Trace_IQOQ_Protocol_v20260329-a.pdf"
    ).write_bytes(b"pdf")

    (release_dir / "package-manifest.json").write_text(
        json.dumps(
            {
                "version": "20260329-a",
                "macos": {
                    "disk_images": [
                        {
                            "product": "trace",
                            "path": "packages/macos/RTMify_Trace_20260329-a.dmg",
                            "sha256": "mac-sha",
                        }
                    ]
                },
                "linux": {
                    "packages": [
                        {
                            "product": "trace",
                            "path": "packages/linux/rtmify-trace-linux-x64-20260329-a.tar.gz",
                            "sha256": "linux-sha",
                        }
                    ]
                },
                "windows": {
                    "status": "finalized",
                    "payload_zip": {
                        "path": "packages/windows/RTMify_Windows_Payloads_20260329-a.zip",
                        "sha256": "p",
                    },
                    "installers": [
                        {
                            "product": "trace",
                            "path": "packages/windows/RTMify_Trace_Installer_20260329-a.exe",
                            "sha256": "win-sha",
                        }
                    ],
                },
            }
        )
    )
    (release_dir / "manifest.json").write_text(
        json.dumps(
            {
                "version": "20260329-a",
                "artifacts": [
                    {
                        "product": "trace-validation",
                        "platform": "any",
                        "kind": "zip",
                        "path": "validation/RTMify_Trace_Validation_Package_v20260329-a.zip",
                        "sha256": "zip-sha",
                    },
                    {
                        "product": "trace-validation",
                        "platform": "any",
                        "kind": "pdf",
                        "path": "validation/package/RTMify_Trace_IQOQ_Protocol_v20260329-a.pdf",
                        "sha256": "pdf-sha",
                    },
                ],
            }
        )
    )

    manifest = build_download_manifest(
        release_dir, "cvillecsteele/rtmify", "v20260329-a"
    )
    assert manifest["version"] == "20260329-a"
    assert manifest["tag"] == "v20260329-a"

    filenames = {a["filename"] for a in manifest["assets"]}
    assert "RTMify_Trace_20260329-a.dmg" in filenames
    assert "RTMify_Trace_Installer_20260329-a.exe" in filenames
    assert "checksums.txt" in filenames
    assert "RTMify_Trace_Validation_Package_v20260329-a.zip" in filenames


def test_download_manifest_omits_payload_zip_before_finalize(tmp_path):
    """Port of test_build_manifest_omits_windows_payload_zip_before_finalize."""
    release_dir = tmp_path / "rel"
    (release_dir / "packages" / "windows").mkdir(parents=True)
    (release_dir / "checksums.txt").write_text("abc  checksums.txt\n")
    (
        release_dir
        / "packages"
        / "windows"
        / "RTMify_Windows_Payloads_20260329-a.zip"
    ).write_bytes(b"payload")

    (release_dir / "package-manifest.json").write_text(
        json.dumps(
            {
                "version": "20260329-a",
                "windows": {
                    "status": "payloads_signed",
                    "signed_binaries": ["windows/rtmify-trace.exe"],
                    "payload_zip": {
                        "path": "packages/windows/RTMify_Windows_Payloads_20260329-a.zip",
                        "sha256": "p",
                    },
                    "installers": [],
                },
            }
        )
    )
    (release_dir / "manifest.json").write_text(
        json.dumps({"version": "20260329-a", "artifacts": []})
    )

    manifest = build_download_manifest(
        release_dir, "cvillecsteele/rtmify", "v20260329-a"
    )
    filenames = {a["filename"] for a in manifest["assets"]}
    assert "RTMify_Windows_Payloads_20260329-a.zip" not in filenames


# ---------------------------------------------------------------------------
# PublishState
# ---------------------------------------------------------------------------


def test_publish_state_read_write(tmp_path):
    path = tmp_path / "state.json"
    state = PublishState(path)
    state.set("version", "20260328-a")
    state.set("platforms.macos", True)
    state.save()

    loaded = PublishState(path)
    assert loaded.get("version") == "20260328-a"
    assert loaded.get("platforms.macos") is True


def test_publish_state_mark_step(tmp_path):
    path = tmp_path / "state.json"
    state = PublishState(path)
    assert not state.step_done("build")
    state.mark_step("build")
    assert state.step_done("build")

    # Reload from disk
    loaded = PublishState(path)
    assert loaded.step_done("build")


# ---------------------------------------------------------------------------
# Find Latest Release Dir
# ---------------------------------------------------------------------------


def test_find_latest_release_dir(tmp_path):
    (tmp_path / "20260328-a").mkdir()
    (tmp_path / "20260329-b").mkdir()
    (tmp_path / "not-a-version").mkdir()
    assert find_latest_release_dir(tmp_path) == "20260329-b"


def test_find_latest_release_dir_empty(tmp_path):
    assert find_latest_release_dir(tmp_path) is None


# ---------------------------------------------------------------------------
# CLI Argument Parsing
# ---------------------------------------------------------------------------


def test_cli_package_requires_release_dir():
    with pytest.raises(SystemExit) as exc_info:
        main(["package"])
    assert exc_info.value.code == 2


def test_cli_help_exits_zero():
    with pytest.raises(SystemExit) as exc_info:
        main(["--help"])
    assert exc_info.value.code == 0


def test_cli_no_command_exits():
    result = main([])
    assert result == 2


def test_product_title():
    assert product_title("trace") == "Trace"
    assert product_title("live") == "Live"
    assert product_title("other") == "other"


def test_infer_product():
    assert infer_product("packages/macos/RTMify_Trace_20260329-a.dmg") == "trace"
    assert (
        infer_product("packages/windows/RTMify_Live_Installer_20260329-a.exe") == "live"
    )
    assert infer_product("bin/rtmify-license-gen") == "operator"


def test_infer_kind():
    assert infer_kind("foo.dmg") == "dmg"
    assert infer_kind("foo.exe") == "exe"
    assert infer_kind("foo.tar.gz") == "tar.gz"
    assert infer_kind("foo.pdf") == "pdf"


def test_release_url():
    assert (
        release_url("owner/repo", "v1.0")
        == "https://github.com/owner/repo/releases/tag/v1.0"
    )
    assert (
        release_url("owner/repo", "v1.0", "file.zip")
        == "https://github.com/owner/repo/releases/download/v1.0/file.zip"
    )


# ---------------------------------------------------------------------------
# Platform Selection Flags (port from test_package.sh)
# ---------------------------------------------------------------------------


def test_package_linux_only(tmp_path):
    """--linux flag packages only Linux, no macOS/Windows sections in manifest."""
    release_dir = _make_linux_release(tmp_path)
    creds = LinuxCredentials(gpg_key="")
    package_linux(release_dir, "20260328-a", creds)
    collect_and_write_package_manifest(release_dir, "20260328-a")

    pkg = json.loads((release_dir / "package-manifest.json").read_text())
    assert "linux" in pkg
    assert "macos" not in pkg
    assert "windows" not in pkg
