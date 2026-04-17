#!/usr/bin/env python3
"""RTMify release tooling — build, sign, package, and publish releases.

Replaces package.sh, publish.sh, version.sh, and generate_download_manifest.py
with a single Python entry point.

Usage:
    tools/publish.py package --release-dir <path> [flags]
    tools/publish.py release [--version X] [flags] [--dry-run]
    tools/publish.py status  [--version X]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Section 1: Constants
# ---------------------------------------------------------------------------

REPO = "cvillecsteele/rtmify"
SITE_MANIFEST_REL = "public/downloads/latest.json"
VERSION_FILE_REL = "build/options.zig"
AZURE_SIGNING_RESOURCE = "https://codesigning.azure.net"
SIGNER_ROLE = "Artifact Signing Certificate Profile Signer"

# Entitlements paths (relative to ROOT_DIR)
TRACE_ENTITLEMENTS_REL = "trace/macos/RTMify Trace/RTMify Trace.entitlements"
LIVE_ENTITLEMENTS_REL = "live/macos/RTMify Live/RTMify Live.entitlements"

# Windows naming templates
WINDOWS_PAYLOAD_ZIP_TEMPLATE = "RTMify_Windows_Payloads_{}.zip"
WINDOWS_TRACE_UNSIGNED_TEMPLATE = "RTMify_Trace_Installer_{}_unsigned.exe"
WINDOWS_LIVE_UNSIGNED_TEMPLATE = "RTMify_Live_Installer_{}_unsigned.exe"
WINDOWS_TRACE_FINAL_TEMPLATE = "RTMify_Trace_Installer_{}.exe"
WINDOWS_LIVE_FINAL_TEMPLATE = "RTMify_Live_Installer_{}.exe"

# Required artifacts per platform
MACOS_REQUIRED_ARTIFACTS = [
    ("bin/rtmify-license-gen", "macOS operator binary"),
    ("bin/rtmify-trace", "macOS trace CLI binary"),
    ("bin/rtmify-live", "macOS live CLI binary"),
    ("macos/RTMify Trace.app", "RTMify Trace.app bundle"),
    ("macos/RTMify Live.app", "RTMify Live.app bundle"),
]
WINDOWS_REQUIRED_ARTIFACTS = [
    ("windows/rtmify-trace.exe", "Windows trace binary"),
    ("windows/RTMify Live.exe", "Windows live shell binary"),
    ("windows/rtmify-live.exe", "Windows live server binary"),
]
LINUX_REQUIRED_ARTIFACTS = [
    ("linux/rtmify-trace", "Linux trace binary"),
]

# Windows signed binary relative paths
WINDOWS_SIGNED_BINARY_PATHS = [
    "windows/rtmify-trace.exe",
    "windows/RTMify Live.exe",
    "windows/rtmify-live.exe",
]

# ---------------------------------------------------------------------------
# Section 2: Version Helpers
# ---------------------------------------------------------------------------


def read_release_version(version_file: Path) -> str:
    """Extract version from ``const default_version = "...";`` in a Zig source file."""
    text = version_file.read_text()
    m = re.search(r'const (?:default_)?version = "([^"]+)";', text)
    return m.group(1) if m else ""


def is_valid_release_version(version: str) -> bool:
    return bool(re.fullmatch(r"\d{8}-[a-z]+", version))


def increment_release_suffix(suffix: str) -> str:
    """a->b, z->aa, az->ba — base-26 increment."""
    if not re.fullmatch(r"[a-z]+", suffix):
        raise ValueError(f"invalid suffix: {suffix}")
    carry = 1
    result: list[str] = []
    for ch in reversed(suffix):
        if carry == 0:
            result.append(ch)
            continue
        if ch == "z":
            result.append("a")
            # carry stays 1
        else:
            result.append(chr(ord(ch) + 1))
            carry = 0
    if carry == 1:
        result.append("a")
    return "".join(reversed(result))


def next_release_version(current: str, today: str | None = None) -> str:
    """If date changed -> YYYYMMDD-a. Same date -> increment suffix."""
    if not is_valid_release_version(current):
        raise ValueError(f"invalid version: {current}")
    if today is None:
        today = time.strftime("%Y%m%d")
    if not re.fullmatch(r"\d{8}", today):
        raise ValueError(f"invalid date: {today}")
    current_date, suffix = current.split("-", 1)
    if current_date < today:
        return f"{today}-a"
    return f"{current_date}-{increment_release_suffix(suffix)}"


def write_release_version(version_file: Path, version: str) -> None:
    """Replace const default_version in the zig source file."""
    if not is_valid_release_version(version):
        raise ValueError(f"invalid version: {version}")
    text = version_file.read_text()
    new_text, count = re.subn(
        r'(const default_version = ")[^"]*(")',
        rf"\g<1>{version}\2",
        text,
        count=1,
    )
    if count == 0:
        raise RuntimeError(f"could not find const default_version in {version_file}")
    version_file.write_text(new_text)


# ---------------------------------------------------------------------------
# Section 3: Dataclasses
# ---------------------------------------------------------------------------


@dataclass
class PlatformSelection:
    macos: bool = True
    windows: bool = True
    linux: bool = True

    @classmethod
    def from_flags(cls, *, macos: bool, windows: bool, linux: bool) -> PlatformSelection:
        if macos or windows or linux:
            return cls(macos=macos, windows=windows, linux=linux)
        return cls()

    @property
    def description(self) -> str:
        parts: list[str] = []
        if self.macos:
            parts.append("macOS")
        if self.windows:
            parts.append("Windows")
        if self.linux:
            parts.append("Linux")
        return " ".join(parts)


@dataclass
class MacOSCredentials:
    signing_identity: str
    notary_key_file: str
    notary_key_id: str
    notary_issuer: str

    @classmethod
    def from_env(cls, **overrides: str | None) -> MacOSCredentials:
        return cls(
            signing_identity=(overrides.get("signing_identity") or "") or os.environ.get("APPLE_SIGNING_IDENTITY", ""),
            notary_key_file=(overrides.get("notary_key_file") or "") or os.environ.get("RTMIFY_NOTARY_KEY_FILE", ""),
            notary_key_id=(overrides.get("notary_key_id") or "") or os.environ.get("RTMIFY_NOTARY_KEY_ID", ""),
            notary_issuer=(overrides.get("notary_issuer") or "") or os.environ.get("RTMIFY_NOTARY_ISSUER_UUID", ""),
        )


@dataclass
class WindowsCredentials:
    azure_endpoint: str
    azure_account: str
    azure_profile: str
    azure_access_token: str
    jsign_bin: str
    jsign_jar: str

    @classmethod
    def from_env(cls, **overrides: str | None) -> WindowsCredentials:
        return cls(
            azure_endpoint=(overrides.get("azure_endpoint") or "") or os.environ.get("AZURE_TRUSTED_SIGNING_ENDPOINT", ""),
            azure_account=(overrides.get("azure_account") or "") or os.environ.get("AZURE_TRUSTED_SIGNING_ACCOUNT", ""),
            azure_profile=(overrides.get("azure_profile") or "") or os.environ.get("AZURE_TRUSTED_SIGNING_PROFILE", ""),
            azure_access_token=(overrides.get("azure_access_token") or "") or os.environ.get("AZURE_ACCESS_TOKEN", ""),
            jsign_bin=(overrides.get("jsign_bin") or "") or os.environ.get("JSIGN_BIN", ""),
            jsign_jar=(overrides.get("jsign_jar") or "") or os.environ.get("JSIGN_JAR", ""),
        )


@dataclass
class LinuxCredentials:
    gpg_key: str

    @classmethod
    def from_env(cls, **overrides: str | None) -> LinuxCredentials:
        return cls(gpg_key=(overrides.get("gpg_key") or "") or os.environ.get("GPG_SIGNING_KEY_ID", ""))


@dataclass
class ResolvedWindowsContext:
    jsign_cmd: list[str]
    access_token: str
    endpoint: str
    account: str
    profile: str


# ---------------------------------------------------------------------------
# Section 4: Subprocess Wrapper
# ---------------------------------------------------------------------------


def run_cmd(
    args: list[str | Path],
    *,
    check: bool = True,
    capture: bool = False,
    dry_run: bool = False,
    quiet: bool = False,
) -> subprocess.CompletedProcess[str]:
    str_args = [str(a) for a in args]
    if dry_run:
        if not quiet:
            print(f"  (dry-run) {' '.join(str_args)}")
        return subprocess.CompletedProcess(str_args, 0, stdout="", stderr="")
    if not quiet:
        print(f"==> {' '.join(str_args)}")
    kwargs: dict[str, Any] = {}
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
        kwargs["text"] = True
    return subprocess.run(str_args, check=check, **kwargs)


# ---------------------------------------------------------------------------
# Section 5: Hashing / Checksums
# ---------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_dir(path: Path) -> str:
    """Hash directory by tarring contents (matches the bash ``tar -cf - | shasum`` approach)."""
    result = subprocess.run(
        ["tar", "-cf", "-", "-C", str(path.parent), path.name],
        capture_output=True,
        check=True,
    )
    return hashlib.sha256(result.stdout).hexdigest()


def sha256_path(path: Path) -> str:
    return sha256_dir(path) if path.is_dir() else sha256_file(path)


class ChecksumFile:
    def __init__(self) -> None:
        self._entries: dict[str, str] = {}  # rel_path -> sha256

    def record(self, rel_path: str, abs_path: Path) -> str:
        sha = sha256_path(abs_path)
        self._entries[rel_path] = sha
        return sha

    def write(self, path: Path) -> None:
        with path.open("w") as f:
            for rel_path in sorted(self._entries):
                f.write(f"{self._entries[rel_path]}  {rel_path}\n")


# ---------------------------------------------------------------------------
# Section 6: Pre-flight Checks
# ---------------------------------------------------------------------------


def preflight_macos(creds: MacOSCredentials, root_dir: Path) -> list[str]:
    errors: list[str] = []
    # Check tools
    for tool in ("codesign", "hdiutil", "xcrun"):
        if not shutil.which(tool):
            errors.append(f"missing tool: {tool} (fix: xcode-select --install)")
    # Check credentials
    if not creds.signing_identity:
        errors.append("APPLE_SIGNING_IDENTITY (or --signing-identity) not set")
    if not creds.notary_key_file:
        errors.append("RTMIFY_NOTARY_KEY_FILE (or --notary-key-file) not set")
    if not creds.notary_key_id:
        errors.append("RTMIFY_NOTARY_KEY_ID (or --notary-key-id) not set")
    if not creds.notary_issuer:
        errors.append("RTMIFY_NOTARY_ISSUER_UUID (or --notary-issuer) not set")
    if errors:
        return errors
    # Check files exist
    if not Path(creds.notary_key_file).is_file():
        errors.append(f"notary key file not found: {creds.notary_key_file}")
    trace_ent = root_dir / TRACE_ENTITLEMENTS_REL
    live_ent = root_dir / LIVE_ENTITLEMENTS_REL
    if not trace_ent.is_file():
        errors.append(f"missing entitlements: {trace_ent}")
    if not live_ent.is_file():
        errors.append(f"missing entitlements: {live_ent}")
    if errors:
        return errors
    # Check signing identity in Keychain
    result = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True,
        text=True,
    )
    if creds.signing_identity not in result.stdout:
        errors.append(f"signing identity not found in Keychain: {creds.signing_identity}")
    if errors:
        return errors
    # Check notarytool auth
    result = subprocess.run(
        [
            "xcrun", "notarytool", "history",
            "--key", creds.notary_key_file,
            "--key-id", creds.notary_key_id,
            "--issuer", creds.notary_issuer,
            "--page-size", "1",
        ],
        capture_output=True,
    )
    if result.returncode != 0:
        errors.append("notarytool authentication failed — check key file, key ID, and issuer")
    return errors


def _resolve_jsign_cmd(jsign_bin: str, jsign_jar: str) -> list[str] | str:
    """Returns command list on success, error string on failure."""
    if jsign_bin:
        p = Path(jsign_bin)
        if p.is_file() and os.access(jsign_bin, os.X_OK):
            return [jsign_bin]
        if shutil.which(jsign_bin):
            return [jsign_bin]
        return f"jsign executable not found: {jsign_bin}"
    if shutil.which("jsign"):
        return ["jsign"]
    if jsign_jar:
        if not Path(jsign_jar).is_file():
            return f"jsign jar not found: {jsign_jar}"
        if not shutil.which("java"):
            return f"java is required to run jsign from {jsign_jar}"
        return ["java", "-jar", jsign_jar]
    return "jsign is not available. Install jsign or pass --jsign-bin/--jsign-jar."


def preflight_windows(creds: WindowsCredentials) -> tuple[list[str], ResolvedWindowsContext | None]:
    """Returns (errors, resolved_context). If errors non-empty, context is None."""
    errors: list[str] = []
    # Check required fields
    if not creds.azure_endpoint:
        errors.append("AZURE_TRUSTED_SIGNING_ENDPOINT (or --azure-endpoint) not set")
    if not creds.azure_account:
        errors.append("AZURE_TRUSTED_SIGNING_ACCOUNT (or --azure-account) not set")
    if not creds.azure_profile:
        errors.append("AZURE_TRUSTED_SIGNING_PROFILE (or --azure-profile) not set")
    if errors:
        return errors, None

    endpoint = creds.azure_endpoint.rstrip("/")

    # Resolve jsign
    jsign_result = _resolve_jsign_cmd(creds.jsign_bin, creds.jsign_jar)
    if isinstance(jsign_result, str):
        return [jsign_result], None
    jsign_cmd = jsign_result

    # If explicit token, skip az CLI probes
    if creds.azure_access_token:
        print("==> Windows: pre-flight OK (using explicit AZURE_ACCESS_TOKEN)")
        return [], ResolvedWindowsContext(
            jsign_cmd=jsign_cmd,
            access_token=creds.azure_access_token,
            endpoint=endpoint,
            account=creds.azure_account,
            profile=creds.azure_profile,
        )

    # az CLI checks
    if not shutil.which("az"):
        errors.append(
            "az CLI is required to acquire an Azure Trusted Signing access token. "
            "Fix: install from https://aka.ms/installazureclimacos or set AZURE_ACCESS_TOKEN."
        )
        return errors, None

    # Logged-in session
    result = subprocess.run(["az", "account", "show"], capture_output=True)
    if result.returncode != 0:
        errors.append("az CLI is not logged in. Fix: az login")
        return errors, None

    # trustedsigning extension
    result = subprocess.run(["az", "trustedsigning", "--help"], capture_output=True)
    if result.returncode != 0:
        errors.append("az CLI 'trustedsigning' extension is not installed. Fix: az extension add --name trustedsigning")
        return errors, None

    # Certificate profile exists and is Active
    result = subprocess.run(
        [
            "az", "trustedsigning", "certificate-profile", "show",
            "--account-name", creds.azure_account,
            "--profile-name", creds.azure_profile,
            "--resource-group", creds.azure_account,
            "-o", "json",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        errors.append(
            f"certificate profile '{creds.azure_profile}' not found in account '{creds.azure_account}'. "
            f"Fix: az trustedsigning certificate-profile list "
            f"--account-name {creds.azure_account} --resource-group {creds.azure_account}"
        )
        return errors, None

    try:
        profile_data = json.loads(result.stdout)
        profile_status = profile_data.get("status", "")
    except json.JSONDecodeError:
        profile_status = ""

    if profile_status != "Active":
        errors.append(
            f"certificate profile '{creds.azure_profile}' status is '{profile_status}', expected 'Active'."
        )
        return errors, None

    # RBAC — check for Artifact Signing Certificate Profile Signer role
    sub_result = subprocess.run(
        ["az", "account", "show", "--query", "id", "-o", "tsv"],
        capture_output=True,
        text=True,
    )
    sub_id = sub_result.stdout.strip()
    scope = (
        f"/subscriptions/{sub_id}/resourceGroups/{creds.azure_account}"
        f"/providers/Microsoft.CodeSigning/codeSigningAccounts/{creds.azure_account}"
    )

    oid_result = subprocess.run(
        ["az", "ad", "signed-in-user", "show", "--query", "id", "-o", "tsv"],
        capture_output=True,
        text=True,
    )
    user_oid = oid_result.stdout.strip()

    display_result = subprocess.run(
        ["az", "account", "show", "--query", "user.name", "-o", "tsv"],
        capture_output=True,
        text=True,
    )
    user_display = display_result.stdout.strip()

    if user_oid:
        role_result = subprocess.run(
            [
                "az", "role", "assignment", "list",
                "--assignee", user_oid,
                "--scope", scope,
                "--role", SIGNER_ROLE,
                "--query", "length(@)",
                "-o", "tsv",
            ],
            capture_output=True,
            text=True,
        )
        role_count = role_result.stdout.strip()
        if role_count == "0" or not role_count:
            errors.append(
                f"'{user_display}' lacks the '{SIGNER_ROLE}' role on the signing account. "
                f"Fix: az role assignment create --assignee-object-id {user_oid} "
                f"--assignee-principal-type User --role \"{SIGNER_ROLE}\" --scope {scope}"
            )
            return errors, None

    # Acquire access token
    token_result = subprocess.run(
        [
            "az", "account", "get-access-token",
            "--resource", AZURE_SIGNING_RESOURCE,
            "--query", "accessToken",
            "-o", "tsv",
        ],
        capture_output=True,
        text=True,
    )
    access_token = token_result.stdout.strip()
    if not access_token:
        errors.append("failed to acquire Azure Trusted Signing access token via az CLI.")
        return errors, None

    print("==> Windows: pre-flight OK")
    return [], ResolvedWindowsContext(
        jsign_cmd=jsign_cmd,
        access_token=access_token,
        endpoint=endpoint,
        account=creds.azure_account,
        profile=creds.azure_profile,
    )


def preflight_linux(creds: LinuxCredentials) -> list[str]:
    errors: list[str] = []
    if not shutil.which("tar"):
        errors.append("tar is required")
    if creds.gpg_key:
        if not shutil.which("gpg"):
            errors.append("gpg is required for tarball signing (fix: brew install gnupg)")
        else:
            result = subprocess.run(
                ["gpg", "--batch", "--list-keys", creds.gpg_key],
                capture_output=True,
            )
            if result.returncode != 0:
                errors.append(f"GPG key '{creds.gpg_key}' not found in keyring")
    return errors


# ---------------------------------------------------------------------------
# Section 7: macOS Packaging
# ---------------------------------------------------------------------------


def read_bundle_id(app_path: Path) -> str:
    plist_path = app_path / "Contents" / "Info.plist"
    with plist_path.open("rb") as f:
        data = plistlib.load(f)
    return data.get("CFBundleIdentifier", "")


def codesign_binary(
    binary: Path,
    identity: str,
    entitlements: Path | None = None,
    *,
    dry_run: bool = False,
) -> None:
    if not binary.is_file():
        print(f"Warning: binary not found, skipping: {binary}", file=sys.stderr)
        return
    args: list[str | Path] = [
        "codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp",
    ]
    if entitlements:
        args += ["--entitlements", str(entitlements)]
    args.append(str(binary))
    run_cmd(args, dry_run=dry_run)


def create_signed_dmg(
    product: str,
    app_path: Path,
    dmg_path: Path,
    identity: str,
    *,
    tmp_dir: Path,
    dry_run: bool = False,
) -> None:
    title = product_title(product)
    volume_name = f"RTMify {title}"
    staging = tmp_dir / f"dmg-{product}"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copytree(app_path, staging / app_path.name, symlinks=True)
    (staging / "Applications").symlink_to("/Applications")

    run_cmd(
        [
            "hdiutil", "create", "-fs", "HFS+", "-format", "UDZO",
            "-volname", volume_name, "-srcfolder", str(staging), str(dmg_path),
        ],
        dry_run=dry_run,
    )
    run_cmd(["codesign", "--force", "--sign", identity, "--timestamp", str(dmg_path)], dry_run=dry_run)
    run_cmd(["codesign", "--verify", "--verbose", str(dmg_path)], dry_run=dry_run)


def notarize_and_staple(
    artifact_path: Path,
    artifact_name: str,
    creds: MacOSCredentials,
    *,
    tmp_dir: Path,
    dry_run: bool = False,
) -> str:
    """Returns notarization request_id."""
    log_path = tmp_dir / f"{artifact_name}.notarize.json"

    result = run_cmd(
        [
            "xcrun", "notarytool", "submit", str(artifact_path),
            "--key", creds.notary_key_file,
            "--key-id", creds.notary_key_id,
            "--issuer", creds.notary_issuer,
            "--wait",
            "--output-format", "json",
        ],
        capture=True,
        dry_run=dry_run,
    )

    if dry_run:
        return "dry-run-request-id"

    log_path.write_text(result.stdout)
    data = json.loads(result.stdout)
    request_id = data.get("id", "")
    status_value = data.get("status", "")

    if status_value != "Accepted":
        print(
            f"Error: notarization failed for {artifact_name} "
            f"(status={status_value}, id={request_id})",
            file=sys.stderr,
        )
        print(result.stdout, file=sys.stderr)
        sys.exit(2)

    run_cmd(["xcrun", "stapler", "staple", str(artifact_path)], dry_run=dry_run)
    run_cmd(["xcrun", "stapler", "validate", str(artifact_path)], dry_run=dry_run)
    return request_id


def package_macos(
    release_dir: Path,
    version: str,
    root_dir: Path,
    creds: MacOSCredentials,
    *,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Returns macOS state dict for package-manifest.json."""
    trace_entitlements = root_dir / TRACE_ENTITLEMENTS_REL
    live_entitlements = root_dir / LIVE_ENTITLEMENTS_REL

    bin_dir = release_dir / "bin"
    trace_app = release_dir / "macos" / "RTMify Trace.app"
    live_app = release_dir / "macos" / "RTMify Live.app"
    live_embedded = live_app / "Contents" / "Resources" / "rtmify-live"
    macos_pkgs_dir = release_dir / "packages" / "macos"
    macos_pkgs_dir.mkdir(parents=True, exist_ok=True)

    # Clean old DMGs
    for old in macos_pkgs_dir.glob(f"RTMify_*_{version}.dmg"):
        old.unlink()

    # Sign CLI binaries
    print("==> macOS: signing CLI binaries")
    codesign_binary(bin_dir / "rtmify-trace", creds.signing_identity, dry_run=dry_run)
    codesign_binary(bin_dir / "rtmify-live", creds.signing_identity, dry_run=dry_run)
    codesign_binary(bin_dir / "rtmify-license-gen", creds.signing_identity, dry_run=dry_run)

    # Sign embedded binary in RTMify Live.app
    print("==> macOS: signing embedded binary in RTMify Live.app")
    codesign_binary(live_embedded, creds.signing_identity, live_entitlements, dry_run=dry_run)

    # Sign app bundles (deep)
    print("==> macOS: signing RTMify Trace.app")
    run_cmd(
        [
            "codesign", "--force", "--deep", "--sign", creds.signing_identity,
            "--options", "runtime", "--timestamp",
            "--entitlements", str(trace_entitlements),
            str(trace_app),
        ],
        dry_run=dry_run,
    )

    print("==> macOS: signing RTMify Live.app")
    run_cmd(
        [
            "codesign", "--force", "--deep", "--sign", creds.signing_identity,
            "--options", "runtime", "--timestamp",
            "--entitlements", str(live_entitlements),
            str(live_app),
        ],
        dry_run=dry_run,
    )

    # Verify signatures
    print("==> macOS: verifying signatures")
    run_cmd(["codesign", "--verify", "--deep", "--strict", str(trace_app)], dry_run=dry_run)
    run_cmd(["codesign", "--verify", "--deep", "--strict", str(live_app)], dry_run=dry_run)

    notarization_ids: dict[str, str] = {}

    with tempfile.TemporaryDirectory(prefix="rtmify-package-") as tmp_str:
        tmp_dir = Path(tmp_str)

        for product, app_path in [("trace", trace_app), ("live", live_app)]:
            if not app_path.is_dir():
                print(f"Error: app bundle not found: {app_path}", file=sys.stderr)
                sys.exit(2)

            bundle_id = read_bundle_id(app_path)
            if not bundle_id and not dry_run:
                print(
                    f"Error: could not read CFBundleIdentifier from {app_path}/Contents/Info.plist",
                    file=sys.stderr,
                )
                sys.exit(2)

            title = product_title(product)
            dmg_name = f"RTMify_{title}_{version}.dmg"
            dmg_path = macos_pkgs_dir / dmg_name

            print(f"==> macOS: building {dmg_name} (bundle id: {bundle_id})")
            create_signed_dmg(product, app_path, dmg_path, creds.signing_identity, tmp_dir=tmp_dir, dry_run=dry_run)

            print(f"==> macOS: notarizing {dmg_name}")
            req_id = notarize_and_staple(dmg_path, dmg_name, creds, tmp_dir=tmp_dir, dry_run=dry_run)
            notarization_ids[dmg_name] = req_id

    return {
        "signing_identity": creds.signing_identity,
        "notarization_ids": notarization_ids,
    }


# ---------------------------------------------------------------------------
# Section 8: Windows Packaging
# ---------------------------------------------------------------------------


def sign_with_jsign(ctx: ResolvedWindowsContext, *files: Path, dry_run: bool = False) -> None:
    run_cmd(
        [
            *ctx.jsign_cmd,
            "--storetype", "TRUSTEDSIGNING",
            "--keystore", ctx.endpoint,
            "--storepass", ctx.access_token,
            "--alias", f"{ctx.account}/{ctx.profile}",
            *[str(f) for f in files],
        ],
        dry_run=dry_run,
    )


def create_deterministic_zip(source_dir: Path, output_path: Path) -> None:
    """Create a deterministic ZIP with fixed timestamps and sorted entries."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source_dir.rglob("*")):
            if path.is_dir():
                continue
            rel = path.relative_to(source_dir).as_posix()
            info = zipfile.ZipInfo(rel)
            info.date_time = (2020, 1, 1, 0, 0, 0)
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = stat.S_IFREG | 0o644
            if os.access(path, os.X_OK):
                mode = stat.S_IFREG | 0o755
            info.external_attr = mode << 16
            archive.writestr(info, path.read_bytes())


def stage_windows_payloads(
    release_dir: Path,
    version: str,
    win_ctx: ResolvedWindowsContext,
    *,
    dry_run: bool = False,
) -> None:
    """Sign payload binaries, create payload ZIP for CI."""
    print("==> Windows: signing payload binaries for CI packaging")
    pkgs_dir = release_dir / "packages" / "windows"
    pkgs_dir.mkdir(parents=True, exist_ok=True)

    # Clean old outputs
    for template in (
        WINDOWS_PAYLOAD_ZIP_TEMPLATE,
        WINDOWS_TRACE_FINAL_TEMPLATE,
        WINDOWS_LIVE_FINAL_TEMPLATE,
        WINDOWS_TRACE_UNSIGNED_TEMPLATE,
        WINDOWS_LIVE_UNSIGNED_TEMPLATE,
    ):
        p = pkgs_dir / template.format(version)
        p.unlink(missing_ok=True)

    trace_exe = release_dir / "windows" / "rtmify-trace.exe"
    live_shell = release_dir / "windows" / "RTMify Live.exe"
    live_server = release_dir / "windows" / "rtmify-live.exe"

    sign_with_jsign(win_ctx, trace_exe, live_shell, live_server, dry_run=dry_run)

    with tempfile.TemporaryDirectory(prefix="rtmify-win-") as tmp:
        payload_dir = Path(tmp) / "windows-payloads"
        payload_dir.mkdir()
        shutil.copy2(trace_exe, payload_dir / "rtmify-trace.exe")
        shutil.copy2(live_shell, payload_dir / "RTMify Live.exe")
        shutil.copy2(live_server, payload_dir / "rtmify-live.exe")

        # Write windows-installer-input.json
        manifest = {
            "version": version,
            "unsigned_installers": [
                WINDOWS_TRACE_UNSIGNED_TEMPLATE.format(version),
                WINDOWS_LIVE_UNSIGNED_TEMPLATE.format(version),
            ],
            "final_installers": [
                WINDOWS_TRACE_FINAL_TEMPLATE.format(version),
                WINDOWS_LIVE_FINAL_TEMPLATE.format(version),
            ],
        }
        (payload_dir / "windows-installer-input.json").write_text(
            json.dumps(manifest, indent=2),
            encoding="utf-8",
        )

        create_deterministic_zip(
            payload_dir,
            pkgs_dir / WINDOWS_PAYLOAD_ZIP_TEMPLATE.format(version),
        )


def validate_windows_unsigned_dir(unsigned_dir: Path, version: str) -> None:
    """Validate the directory of unsigned Windows installers from CI. Exits on error."""
    if not unsigned_dir.is_dir():
        die(f"unsigned Windows installer dir not found: {unsigned_dir}")
    expected = {
        WINDOWS_TRACE_UNSIGNED_TEMPLATE.format(version),
        WINDOWS_LIVE_UNSIGNED_TEMPLATE.format(version),
    }
    for name in expected:
        if not (unsigned_dir / name).is_file():
            die(f"missing unsigned Windows installer: {name}")
    unexpected = [
        f.name
        for f in sorted(unsigned_dir.glob("*.exe"))
        if f.name not in expected
    ]
    if unexpected:
        for name in unexpected:
            print(f"Error: unexpected unsigned Windows installer file: {name}", file=sys.stderr)
        sys.exit(2)


def finalize_windows_installers(
    release_dir: Path,
    version: str,
    unsigned_dir: Path,
    win_ctx: ResolvedWindowsContext,
    *,
    dry_run: bool = False,
) -> None:
    """Sign CI-built unsigned installers."""
    print("==> Windows: signing final installers from CI output")
    pkgs_dir = release_dir / "packages" / "windows"
    payload_zip = pkgs_dir / WINDOWS_PAYLOAD_ZIP_TEMPLATE.format(version)
    if not payload_zip.is_file():
        die(
            f"payload zip not found: {payload_zip}\n"
            "Run package once without --windows-unsigned-dir first."
        )

    validate_windows_unsigned_dir(unsigned_dir, version)
    pkgs_dir.mkdir(parents=True, exist_ok=True)

    trace_final = pkgs_dir / WINDOWS_TRACE_FINAL_TEMPLATE.format(version)
    live_final = pkgs_dir / WINDOWS_LIVE_FINAL_TEMPLATE.format(version)
    trace_final.unlink(missing_ok=True)
    live_final.unlink(missing_ok=True)

    shutil.copy2(
        unsigned_dir / WINDOWS_TRACE_UNSIGNED_TEMPLATE.format(version),
        trace_final,
    )
    shutil.copy2(
        unsigned_dir / WINDOWS_LIVE_UNSIGNED_TEMPLATE.format(version),
        live_final,
    )

    sign_with_jsign(win_ctx, trace_final, live_final, dry_run=dry_run)


# ---------------------------------------------------------------------------
# Section 9: Linux Packaging
# ---------------------------------------------------------------------------


def package_linux(
    release_dir: Path,
    version: str,
    creds: LinuxCredentials,
    *,
    dry_run: bool = False,
) -> bool:
    """Create tarballs, optionally GPG-sign. Returns True if any packages created."""
    pkgs_dir = release_dir / "packages" / "linux"
    pkgs_dir.mkdir(parents=True, exist_ok=True)
    linux_dir = release_dir / "linux"
    if not linux_dir.is_dir():
        print("Warning: no linux/ dir in release dir, skipping Linux packaging.", file=sys.stderr)
        return False

    # Clean old tarballs
    for old in pkgs_dir.glob(f"*-linux-x64-{version}.tar.gz"):
        old.unlink()

    found = False
    for binary in sorted(linux_dir.glob("rtmify-*")):
        if not binary.is_file():
            continue
        found = True
        tarball_name = f"{binary.name}-linux-x64-{version}.tar.gz"
        tarball_path = pkgs_dir / tarball_name
        run_cmd(
            ["tar", "czf", str(tarball_path), "-C", str(linux_dir), binary.name],
            dry_run=dry_run,
        )
        if creds.gpg_key:
            print(f"==> Linux: GPG signing {tarball_name}")
            run_cmd(
                [
                    "gpg", "--batch", "--yes", "--detach-sign", "--armor",
                    "--local-user", creds.gpg_key, str(tarball_path),
                ],
                dry_run=dry_run,
            )

    if not found:
        print(f"Warning: no binaries found in {linux_dir}", file=sys.stderr)
    return found


# ---------------------------------------------------------------------------
# Section 10: Manifest Collection
# ---------------------------------------------------------------------------


def product_title(product: str) -> str:
    return {"trace": "Trace", "live": "Live"}.get(product, product)


def _collect_macos_state(
    release_dir: Path,
    version: str,
    checksums: ChecksumFile,
    macos_state: dict[str, Any] | None,
    previous_manifest: dict[str, Any] | None,
) -> dict[str, Any] | None:
    """Scan packages/macos/ for DMGs and build the macOS manifest section."""
    macos_pkgs = release_dir / "packages" / "macos"
    disk_images: list[dict[str, Any]] = []

    for product in ("trace", "live"):
        title = product_title(product)
        dmg_name = f"RTMify_{title}_{version}.dmg"
        rel_path = f"packages/macos/{dmg_name}"
        abs_path = release_dir / rel_path
        if not abs_path.is_file():
            continue
        sha = checksums.record(rel_path, abs_path)
        disk_images.append({"product": product, "path": rel_path, "sha256": sha})

    if not disk_images:
        # Carry forward from previous manifest if available
        if previous_manifest and "macos" in previous_manifest:
            prev_macos = previous_manifest["macos"]
            # Re-record checksums for existing DMGs
            for img in prev_macos.get("disk_images", []):
                p = release_dir / img["path"]
                if p.is_file():
                    checksums.record(img["path"], p)
            # Also record CLI binary checksums
            for bin_rel in ("bin/rtmify-license-gen", "bin/rtmify-trace", "bin/rtmify-live"):
                if (release_dir / bin_rel).is_file():
                    checksums.record(bin_rel, release_dir / bin_rel)
            return prev_macos
        return None

    # Record CLI binary checksums
    for bin_rel in ("bin/rtmify-license-gen", "bin/rtmify-trace", "bin/rtmify-live"):
        if (release_dir / bin_rel).is_file():
            checksums.record(bin_rel, release_dir / bin_rel)

    signing_identity = ""
    notarization_ids: dict[str, str] = {}
    if macos_state:
        signing_identity = macos_state.get("signing_identity", "")
        notarization_ids = macos_state.get("notarization_ids", {})
    elif previous_manifest and "macos" in previous_manifest:
        signing_identity = previous_manifest["macos"].get("signing_identity", "")
        notarization_ids = previous_manifest["macos"].get("notarization_ids", {})

    return {
        "signing_identity": signing_identity,
        "notarization_ids": notarization_ids,
        "disk_images": disk_images,
    }


def _collect_windows_state(
    release_dir: Path,
    version: str,
    checksums: ChecksumFile,
    previous_manifest: dict[str, Any] | None,
) -> dict[str, Any] | None:
    """Scan for Windows artifacts and build the Windows manifest section."""
    signed_binaries: list[str] = []
    for rel_path in WINDOWS_SIGNED_BINARY_PATHS:
        if (release_dir / rel_path).is_file():
            signed_binaries.append(rel_path)

    # Payload zip
    payload_zip_rel = f"packages/windows/{WINDOWS_PAYLOAD_ZIP_TEMPLATE.format(version)}"
    payload_zip_abs = release_dir / payload_zip_rel
    payload_zip_entry: dict[str, str] | None = None
    if payload_zip_abs.is_file():
        sha = checksums.record(payload_zip_rel, payload_zip_abs)
        payload_zip_entry = {"path": payload_zip_rel, "sha256": sha}

    # Installers
    installers: list[dict[str, Any]] = []
    for product in ("trace", "live"):
        title = product_title(product)
        installer_name = f"RTMify_{title}_Installer_{version}.exe"
        installer_rel = f"packages/windows/{installer_name}"
        installer_abs = release_dir / installer_rel
        if not installer_abs.is_file():
            continue
        sha = checksums.record(installer_rel, installer_abs)
        installers.append({"product": product, "path": installer_rel, "sha256": sha})

    has_anything = bool(signed_binaries) or payload_zip_entry is not None or bool(installers)
    has_previous = previous_manifest is not None and "windows" in (previous_manifest or {})

    if not has_anything and not has_previous:
        return None

    # Record signed binary checksums
    for rel_path in signed_binaries:
        checksums.record(rel_path, release_dir / rel_path)

    windows_status = "finalized" if installers else "payloads_signed"

    return {
        "status": windows_status,
        "signed_binaries": signed_binaries,
        "payload_zip": payload_zip_entry,
        "installers": installers,
    }


def _collect_linux_state(
    release_dir: Path,
    version: str,
    checksums: ChecksumFile,
) -> dict[str, Any] | None:
    """Scan packages/linux/ for tarballs and build the Linux manifest section."""
    linux_pkgs = release_dir / "packages" / "linux"
    if not linux_pkgs.is_dir():
        return None

    packages: list[dict[str, Any]] = []
    for tarball in sorted(linux_pkgs.glob(f"*-linux-x64-{version}.tar.gz")):
        rel_path = str(tarball.relative_to(release_dir))
        sha = checksums.record(rel_path, tarball)
        # Extract product name: rtmify-<product>-linux-x64-<version>.tar.gz
        product = tarball.name
        product = product.removesuffix(f"-linux-x64-{version}.tar.gz")
        product = product.removeprefix("rtmify-")
        packages.append({"product": product, "path": rel_path, "sha256": sha})

    if not packages:
        return None
    return {"packages": packages}


def collect_and_write_package_manifest(
    release_dir: Path,
    version: str,
    *,
    macos_state: dict[str, Any] | None = None,
    previous_manifest: dict[str, Any] | None = None,
) -> None:
    """Build package-manifest.json and checksums.txt from disk state."""
    checksums = ChecksumFile()
    manifest: dict[str, Any] = {"version": version, "packaged_at": int(time.time())}

    # Validation checksums
    manifest_file = release_dir / "manifest.json"
    if manifest_file.is_file():
        manifest_data = json.loads(manifest_file.read_text())
        for artifact in manifest_data.get("artifacts", []):
            rel_path = artifact.get("path", "")
            if isinstance(rel_path, str) and rel_path.startswith("validation/") and (release_dir / rel_path).is_file():
                checksums.record(rel_path, release_dir / rel_path)

    # macOS
    macos_section = _collect_macos_state(release_dir, version, checksums, macos_state, previous_manifest)
    if macos_section:
        manifest["macos"] = macos_section

    # Windows
    windows_section = _collect_windows_state(release_dir, version, checksums, previous_manifest)
    if windows_section:
        manifest["windows"] = windows_section

    # Linux
    linux_section = _collect_linux_state(release_dir, version, checksums)
    if linux_section:
        manifest["linux"] = linux_section

    checksums.write(release_dir / "checksums.txt")
    (release_dir / "package-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Section 11: Download Manifest (absorbed from generate_download_manifest.py)
# ---------------------------------------------------------------------------


def infer_product(rel_path: str) -> str:
    lower = rel_path.lower()
    if "trace" in lower:
        return "trace"
    if "live" in lower:
        return "live"
    if "license" in lower:
        return "operator"
    return "unknown"


def infer_kind(rel_path: str) -> str:
    name = Path(rel_path).name.lower()
    if name.endswith(".dmg"):
        return "dmg"
    if name.endswith(".pkg"):
        return "pkg"
    if name.endswith(".exe"):
        return "exe"
    if name.endswith(".tar.gz"):
        return "tar.gz"
    if name.endswith(".zip"):
        return "zip"
    if name.endswith(".pdf"):
        return "pdf"
    if name.endswith(".json"):
        return "json"
    if name.endswith(".txt"):
        return "txt"
    return Path(rel_path).suffix.lstrip(".") or "file"


def release_url(repo: str, tag: str, asset_name: str | None = None) -> str:
    base = f"https://github.com/{repo}/releases"
    if asset_name is None:
        return f"{base}/tag/{tag}"
    return f"{base}/download/{tag}/{asset_name}"


def build_asset_entry(
    *,
    repo: str,
    tag: str,
    version: str,
    release_dir: Path,
    rel_path: str,
    product: str,
    platform: str,
    kind: str | None = None,
    sha256: str | None = None,
) -> dict[str, Any]:
    filename = Path(rel_path).name
    abs_path = release_dir / rel_path
    return {
        "product": product,
        "platform": platform,
        "version": version,
        "path": rel_path,
        "filename": filename,
        "kind": kind or infer_kind(rel_path),
        "sha256": sha256 or sha256_path(abs_path),
        "url": release_url(repo, tag, filename),
    }


def build_download_manifest(release_dir: Path, repo: str, tag: str) -> dict[str, Any]:
    release_manifest = json.loads((release_dir / "manifest.json").read_text(encoding="utf-8"))
    package_manifest = json.loads((release_dir / "package-manifest.json").read_text(encoding="utf-8"))
    version = release_manifest["version"]

    assets: list[dict[str, Any]] = []

    # macOS
    macos_entries = package_manifest.get("macos", {}).get("disk_images")
    if macos_entries is None:
        macos_entries = package_manifest.get("macos", {}).get("packages", [])

    for pkg in macos_entries:
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=pkg["path"],
                product=pkg["product"],
                platform="macos",
                sha256=pkg.get("sha256"),
            )
        )

    # Linux
    for pkg in package_manifest.get("linux", {}).get("packages", []):
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=pkg["path"],
                product=pkg["product"],
                platform="linux",
                sha256=pkg.get("sha256"),
            )
        )

    # Windows
    windows_installers = package_manifest.get("windows", {}).get("installers")
    if windows_installers is None:
        windows_installers = [
            {"product": infer_product(rel_path), "path": rel_path}
            for rel_path in package_manifest.get("windows", {}).get("signed", [])
        ]

    for installer in windows_installers:
        rel_path = installer["path"]
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=rel_path,
                product=installer.get("product", infer_product(rel_path)),
                platform="windows",
                sha256=installer.get("sha256"),
            )
        )

    # Utility / metadata
    utility_paths = [
        ("checksums.txt", "metadata", "any"),
        ("package-manifest.json", "metadata", "any"),
        ("manifest.json", "metadata", "any"),
    ]
    for rel_path, product, platform in utility_paths:
        if (release_dir / rel_path).exists():
            assets.append(
                build_asset_entry(
                    repo=repo,
                    tag=tag,
                    version=version,
                    release_dir=release_dir,
                    rel_path=rel_path,
                    product=product,
                    platform=platform,
                )
            )

    # Validation artifacts
    for artifact in release_manifest.get("artifacts", []):
        rel_path = artifact.get("path")
        if not rel_path or not isinstance(rel_path, str):
            continue
        if not rel_path.startswith("validation/"):
            continue
        abs_path = release_dir / rel_path
        if not abs_path.exists() or abs_path.is_dir():
            continue
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=rel_path,
                product=artifact.get("product", "validation"),
                platform=artifact.get("platform", "any"),
                kind=artifact.get("kind"),
                sha256=artifact.get("sha256"),
            )
        )

    assets.sort(key=lambda item: (item["platform"], item["product"], item["filename"]))

    return {
        "version": version,
        "tag": tag,
        "releaseUrl": release_url(repo, tag),
        "repo": repo,
        "assets": assets,
    }


def generate_download_manifest(release_dir: Path, repo: str, tag: str, output: Path) -> None:
    manifest = build_download_manifest(release_dir, repo, tag)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Section 12: Publish State
# ---------------------------------------------------------------------------


class PublishState:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._data: dict[str, Any] = {}
        if path.is_file():
            self._data = json.loads(path.read_text())

    def get(self, dotted_key: str, default: Any = None) -> Any:
        d: Any = self._data
        for k in dotted_key.split("."):
            if not isinstance(d, dict):
                return default
            d = d.get(k)
            if d is None:
                return default
        return d

    def set(self, key: str, value: Any) -> None:
        keys = key.split(".")
        d = self._data
        for k in keys[:-1]:
            d = d.setdefault(k, {})
        d[keys[-1]] = value
        self._data["updated_at"] = int(time.time())

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self._data, indent=2) + "\n")

    def mark_step(self, step_name: str) -> None:
        self.set(f"steps.{step_name}", int(time.time()))
        self.save()

    def step_done(self, step_name: str) -> bool:
        return self.get(f"steps.{step_name}") is not None


# ---------------------------------------------------------------------------
# Section 13: Release Pipeline Helpers
# ---------------------------------------------------------------------------


def find_latest_release_dir(dist_dir: Path) -> str | None:
    if not dist_dir.is_dir():
        return None
    latest: str | None = None
    for d in dist_dir.iterdir():
        if d.is_dir() and is_valid_release_version(d.name):
            if latest is None or d.name > latest:
                latest = d.name
    return latest


class StepCounter:
    def __init__(self, total: int) -> None:
        self.total = total
        self.current = 0

    def next(self, label: str) -> None:
        self.current += 1
        print(f"\n\033[1;36m[{self.current}/{self.total}]\033[0m {label}")


def _generate_release_notes_draft(version: str, tag: str, root_dir: Path, repo: str) -> str:
    """Build a starting-point release notes draft from git log."""
    lines = [f"## RTMify {version}\n"]

    # Try to find the previous release tag for a changelog
    prev_tag = ""
    result = subprocess.run(
        ["gh", "release", "list", "--repo", repo, "--limit", "10", "--json", "tagName",
         "-q", "[.[].tagName]"],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        try:
            tags = json.loads(result.stdout)
            for t in sorted(tags, reverse=True):
                if t != tag:
                    prev_tag = t
                    break
        except (json.JSONDecodeError, TypeError):
            pass

    # Git log since previous tag (or last 10 commits)
    if prev_tag:
        git_range = f"{prev_tag}..HEAD"
        lines.append(f"### Changes since {prev_tag}\n")
    else:
        git_range = "-10"
        lines.append("### Recent changes\n")

    result = subprocess.run(
        ["git", "-C", str(root_dir), "log", git_range, "--format=- %s"],
        capture_output=True, text=True,
    )
    if result.returncode == 0 and result.stdout.strip():
        lines.append(result.stdout.strip())
    else:
        lines.append("- (no commits found)")

    lines.append("")
    return "\n".join(lines)


def prepare_release_notes(
    version: str, tag: str, root_dir: Path, release_dir: Path, repo: str, *, dry_run: bool = False,
) -> Path:
    """Prepare release notes, offering the operator a chance to edit.

    Returns the path to the release notes file.
    """
    notes_file = release_dir / "release-notes.md"

    if notes_file.is_file():
        print(f"  Using existing release notes: {notes_file}")
        existing = notes_file.read_text().strip()
        if existing:
            print()
            for line in existing.split("\n"):
                print(f"    {line}")
            print()
    else:
        draft = _generate_release_notes_draft(version, tag, root_dir, repo)
        notes_file.parent.mkdir(parents=True, exist_ok=True)
        notes_file.write_text(draft, encoding="utf-8")
        print(f"  Generated draft release notes: {notes_file}")
        print()
        for line in draft.strip().split("\n"):
            print(f"    {line}")
        print()

    if dry_run:
        print("  (dry-run) would prompt to edit release notes")
        return notes_file

    # Offer to edit
    editor = os.environ.get("EDITOR", "emacs")
    try:
        answer = input(f"  Edit release notes? [{editor}] (Y/n): ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        answer = "n"

    if answer not in ("n", "no"):
        subprocess.run([editor, str(notes_file)], check=True)
        print(f"  Release notes saved: {notes_file}")

    return notes_file


def _ensure_draft_release(tag: str, version: str, notes_file: Path, *, dry_run: bool = False) -> None:
    """Create a draft GitHub release if one doesn't exist yet."""
    if not dry_run:
        result = subprocess.run(
            ["gh", "release", "view", tag, "--repo", REPO],
            capture_output=True,
        )
        if result.returncode == 0:
            print(f"  Draft release {tag} already exists")
            return
    create_args = [
        "gh", "release", "create", tag,
        "--repo", REPO, "--draft",
        "--title", f"RTMify {version}", "--prerelease",
    ]
    if notes_file.is_file():
        create_args += ["--notes-file", str(notes_file)]
    run_cmd(create_args, dry_run=dry_run)


def dispatch_and_wait_windows_ci(version: str, repo: str, *, dry_run: bool = False) -> str | None:
    """Dispatch the Windows installer workflow and wait for completion. Returns run ID."""
    workflow = "windows-installer-packaging.yml"

    if dry_run:
        run_cmd(
            ["gh", "workflow", "run", workflow, "--repo", repo, "-f", f"version={version}"],
            dry_run=True,
        )
        print("  (dry-run) would poll until complete, then download artifacts")
        return None

    # Get current latest run
    result = run_cmd(
        [
            "gh", "run", "list", "--repo", repo, "--workflow", workflow,
            "--limit", "1", "--json", "databaseId", "-q", ".[0].databaseId",
        ],
        capture=True,
        quiet=True,
    )
    before_run = result.stdout.strip()

    # Dispatch
    run_cmd(["gh", "workflow", "run", workflow, "--repo", repo, "-f", f"version={version}"])
    print("  Workflow dispatched, waiting for run to appear...")

    # Find new run
    run_id: str | None = None
    for _ in range(20):
        time.sleep(3)
        result = run_cmd(
            [
                "gh", "run", "list", "--repo", repo, "--workflow", workflow,
                "--limit", "1", "--json", "databaseId", "-q", ".[0].databaseId",
            ],
            capture=True,
            quiet=True,
        )
        latest = result.stdout.strip()
        if latest and latest != before_run:
            run_id = latest
            break

    if not run_id:
        die("Could not find workflow run after dispatch")

    print(f"  Run ID: {run_id}")
    print(f"  https://github.com/{repo}/actions/runs/{run_id}")

    # Poll
    print("  Waiting for workflow to complete...")
    poll_interval = 5
    poll_timeout = 300
    elapsed = 0
    while True:
        result = run_cmd(
            [
                "gh", "run", "view", run_id, "--repo", repo,
                "--json", "status", "-q", ".status",
            ],
            capture=True,
            quiet=True,
        )
        if result.stdout.strip() == "completed":
            result2 = run_cmd(
                [
                    "gh", "run", "view", run_id, "--repo", repo,
                    "--json", "conclusion", "-q", ".conclusion",
                ],
                capture=True,
                quiet=True,
            )
            conclusion = result2.stdout.strip()
            if conclusion != "success":
                print(f"\n  Workflow failed ({conclusion}). Logs:")
                run_cmd(
                    ["gh", "run", "view", run_id, "--repo", repo, "--log-failed"],
                    check=False,
                )
                die(
                    f"Windows installer workflow failed — fix and re-run: "
                    f"./tools/publish.py release --version {version} --skip-build --windows"
                )
            print("  Workflow completed successfully")
            break
        time.sleep(poll_interval)
        elapsed += poll_interval
        if elapsed >= poll_timeout:
            die(f"Workflow timed out after {poll_timeout}s — check: gh run view {run_id}")

    return run_id


# ---------------------------------------------------------------------------
# Section 14: Status Display
# ---------------------------------------------------------------------------


def show_status(
    release_dir: Path,
    version: str,
    tag: str,
    repo: str,
    site_dir: Path | None,
) -> None:
    G = "\033[1;32m"  # green
    Y = "\033[1;33m"  # yellow
    R = "\033[1;31m"  # red
    D = "\033[0;37m"  # dim
    N = "\033[0m"  # reset

    print(f"\nRTMify {version} — pipeline status")
    print(f"Release dir: {release_dir}")

    # Show targeted platforms from publish-state.json
    state = PublishState(release_dir / "publish-state.json")
    platforms = state.get("platforms", {})
    has_state = bool(platforms)
    if has_state:
        names: list[str] = []
        for p, label in [("macos", "macOS"), ("windows", "Windows"), ("linux", "Linux")]:
            if platforms.get(p):
                names.append(label)
        if names:
            print(f"Platforms:   {' '.join(names)}")
    print()

    def symbol(color: str, label: str, detail: str = "") -> None:
        sym = {G: f"{G}\u2713{N}", Y: f"{Y}~{N}", R: f"{R}\u2717{N}"}[color]
        if detail:
            print(f"  {sym} {label:<20s} {D}{detail}{N}")
        else:
            print(f"  {sym} {label}")

    def hint(text: str) -> None:
        print(f"       {D}{text}{N}")

    def show_platform(name: str) -> bool:
        return not has_state or bool(platforms.get(name))

    # Build
    if (release_dir / "manifest.json").is_file():
        symbol(G, "Build")
    elif release_dir.is_dir():
        symbol(Y, "Build", "(dir exists but no manifest)")
        hint(f"run: ./tools/publish.py release --version {version}")
        print()
        return
    else:
        symbol(R, "Build", f"(run: ./tools/publish.py release --version {version})")
        print()
        return

    # macOS
    if show_platform("macos"):
        macos_pkg_dir = release_dir / "packages" / "macos"
        dmg_count = len(list(macos_pkg_dir.glob("*.dmg"))) if macos_pkg_dir.is_dir() else 0
        if dmg_count >= 2:
            symbol(G, "macOS", f"({dmg_count} DMGs signed + notarized)")
        elif dmg_count > 0:
            symbol(Y, "macOS", f"({dmg_count}/2 DMGs — incomplete)")
        else:
            symbol(R, "macOS")
            hint(f"run: ./tools/publish.py release --version {version} --skip-build --macos")

    # Windows
    if show_platform("windows"):
        pkg_manifest_path = release_dir / "package-manifest.json"
        win_status = ""
        if pkg_manifest_path.is_file():
            pkg_data = json.loads(pkg_manifest_path.read_text())
            win_status = pkg_data.get("windows", {}).get("status", "")

        win_pkgs = release_dir / "packages" / "windows"
        installer_count = len(list(win_pkgs.glob("*_Installer_*.exe"))) if win_pkgs.is_dir() else 0
        unsigned_dir = release_dir / "windows-unsigned"
        unsigned_count = len(list(unsigned_dir.glob("*_unsigned.exe"))) if unsigned_dir.is_dir() else 0

        if win_status == "finalized" and installer_count >= 2:
            symbol(G, "Windows", f"({installer_count} installers signed)")
        elif win_status == "payloads_signed":
            if unsigned_count >= 2:
                symbol(Y, "Windows", "(payloads signed, unsigned installers ready — need finalize)")
            else:
                symbol(Y, "Windows", "(payloads signed — need CI build)")
            hint(f"run: ./tools/publish.py release --version {version} --skip-build --windows")
        else:
            symbol(R, "Windows")
            hint(f"run: ./tools/publish.py release --version {version} --skip-build --windows")

    # Linux
    if show_platform("linux"):
        linux_pkgs = release_dir / "packages" / "linux"
        tarball_count = len(list(linux_pkgs.glob("*.tar.gz"))) if linux_pkgs.is_dir() else 0
        if tarball_count > 0:
            symbol(G, "Linux", f"({tarball_count} tarballs)")
        else:
            symbol(R, "Linux")
            hint(f"run: ./tools/publish.py release --version {version} --skip-build --linux")

    # Download manifest
    if (release_dir / "latest.json").is_file():
        symbol(G, "Download manifest")
    else:
        symbol(R, "Download manifest")

    # GitHub Release
    if shutil.which("gh"):
        result = subprocess.run(
            ["gh", "release", "view", tag, "--repo", repo, "--json", "isDraft,assets"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            n_assets = len(data.get("assets", []))
            if data.get("isDraft"):
                symbol(Y, "GitHub Release", f"(draft, {n_assets} assets)")
                hint(f"publish: gh release edit {tag} --repo {repo} --draft=false")
            else:
                symbol(G, "GitHub Release", f"(published, {n_assets} assets)")
        else:
            symbol(R, "GitHub Release")

    # Site manifest
    if site_dir:
        site_manifest_path = site_dir / SITE_MANIFEST_REL
        if site_manifest_path.is_file():
            site_data = json.loads(site_manifest_path.read_text())
            site_version = site_data.get("version", "")
            if site_version == version:
                symbol(G, "Site manifest", f"({version})")
            else:
                symbol(Y, "Site manifest", f"(currently {site_version or 'unknown'})")
        else:
            symbol(R, "Site manifest")

    print()


# ---------------------------------------------------------------------------
# Section 15: CLI Commands
# ---------------------------------------------------------------------------


def die(msg: str) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(2)


def validate_release_prereqs(
    release_dir: Path,
    manifest_data: dict[str, Any],
    platforms: PlatformSelection,
) -> None:
    """Check that required artifacts exist in both manifest and on disk."""
    errors: list[str] = []
    required: list[tuple[str, str]] = []
    if platforms.macos:
        required.extend(MACOS_REQUIRED_ARTIFACTS)
    if platforms.windows:
        required.extend(WINDOWS_REQUIRED_ARTIFACTS)
    if platforms.linux:
        required.extend(LINUX_REQUIRED_ARTIFACTS)

    artifact_paths = {a.get("path") for a in manifest_data.get("artifacts", [])}
    for rel_path, description in required:
        if rel_path not in artifact_paths:
            errors.append(f"manifest.json is missing {description} ({rel_path})")
        if not (release_dir / rel_path).exists():
            errors.append(f"release dir is missing {description} ({rel_path})")

    if errors:
        print("Error: release dir is missing required artifacts from release.sh:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(2)


def cmd_package(args: argparse.Namespace) -> int:
    release_dir = Path(args.release_dir).resolve()
    if not release_dir.is_dir():
        die(f"release dir not found: {release_dir}")
    manifest_file = release_dir / "manifest.json"
    if not manifest_file.is_file():
        die("manifest.json not found — is this a valid release dir?")

    manifest_data = json.loads(manifest_file.read_text())
    version = manifest_data.get("version", "")
    if not is_valid_release_version(version):
        die(f"invalid version in manifest: {version}")

    root_dir = Path(__file__).resolve().parent.parent

    # Resolve platforms
    platforms = PlatformSelection.from_flags(
        macos=args.macos,
        windows=args.windows,
        linux=args.linux,
    )
    # Apply skip flags
    if args.skip_macos:
        platforms.macos = False
    if args.skip_windows:
        platforms.windows = False
    if args.skip_linux:
        platforms.linux = False

    # --windows-unsigned-dir implies Windows-only finalize mode
    windows_unsigned_dir = Path(args.windows_unsigned_dir) if args.windows_unsigned_dir else None
    if windows_unsigned_dir:
        if not platforms.windows:
            die("--windows-unsigned-dir cannot be combined with --skip-windows")
        platforms.macos = False
        platforms.linux = False

    validate_release_prereqs(release_dir, manifest_data, platforms)

    # Create package dirs
    for sub in ("macos", "windows", "linux"):
        (release_dir / "packages" / sub).mkdir(parents=True, exist_ok=True)

    # Load previous manifest for incremental state
    pkg_manifest_path = release_dir / "package-manifest.json"
    previous_manifest = json.loads(pkg_manifest_path.read_text()) if pkg_manifest_path.is_file() else None

    print(f"RTMify publish.py package — version {version}")
    print(f"Release dir: {release_dir}")

    macos_state: dict[str, Any] | None = None

    if platforms.macos:
        macos_creds = MacOSCredentials.from_env(
            signing_identity=args.signing_identity,
            notary_key_file=args.notary_key_file,
            notary_key_id=args.notary_key_id,
            notary_issuer=args.notary_issuer,
        )
        errors = preflight_macos(macos_creds, root_dir)
        if errors:
            print("Error: macOS pre-flight failed:", file=sys.stderr)
            for e in errors:
                print(f"  {e}", file=sys.stderr)
            sys.exit(2)
        print("==> macOS: pre-flight OK")
        macos_state = package_macos(release_dir, version, root_dir, macos_creds)

    if platforms.windows:
        win_creds = WindowsCredentials.from_env(
            azure_endpoint=args.azure_endpoint,
            azure_account=args.azure_account,
            azure_profile=args.azure_profile,
            jsign_bin=args.jsign_bin,
            jsign_jar=args.jsign_jar,
        )
        errors, win_ctx = preflight_windows(win_creds)
        if errors:
            print("Error: Windows pre-flight failed:", file=sys.stderr)
            for e in errors:
                print(f"  {e}", file=sys.stderr)
            sys.exit(2)
        print("==> Windows: pre-flight OK")
        assert win_ctx is not None
        if windows_unsigned_dir:
            finalize_windows_installers(release_dir, version, windows_unsigned_dir, win_ctx)
        else:
            stage_windows_payloads(release_dir, version, win_ctx)

    if platforms.linux:
        linux_creds = LinuxCredentials.from_env(gpg_key=args.gpg_key)
        errors = preflight_linux(linux_creds)
        if errors:
            print("Error: Linux pre-flight failed:", file=sys.stderr)
            for e in errors:
                print(f"  {e}", file=sys.stderr)
            sys.exit(2)
        print("==> Linux: pre-flight OK")
        package_linux(release_dir, version, linux_creds)

    collect_and_write_package_manifest(
        release_dir,
        version,
        macos_state=macos_state,
        previous_manifest=previous_manifest,
    )

    print(f"Package artifacts written to {release_dir / 'packages'}")
    print(f"Package manifest: {release_dir / 'package-manifest.json'}")
    return 0


def cmd_release(args: argparse.Namespace) -> int:
    root_dir = Path(__file__).resolve().parent.parent
    version_file = root_dir / VERSION_FILE_REL

    version: str = args.version or ""
    if not version:
        tracked = read_release_version(version_file)
        version = next_release_version(tracked)

    if not is_valid_release_version(version):
        die(f"invalid version: {version}")

    tag = f"v{version}"
    release_dir = root_dir / "dist" / version
    site_dir = Path(args.site_dir) if args.site_dir else (root_dir / ".." / "site")
    dry_run: bool = args.dry_run
    skip_site: bool = args.skip_site

    platforms = PlatformSelection.from_flags(
        macos=args.macos,
        windows=args.windows,
        linux=args.linux,
    )

    # Compute step count
    total = 4  # build + notes + package + upload
    if platforms.windows:
        total += 3  # draft+payload, CI+wait, finalize
    total += 1  # manifest
    if not skip_site:
        total += 1

    steps = StepCounter(total)

    # Banner
    print(f"\n{'=' * 50}")
    print(f"  RTMify Release — {version}")
    print(f"{'=' * 50}")
    print(f"\n  Tag:         {tag}")
    print(f"  Platforms:   {platforms.description}")
    print(f"  Release dir: {release_dir}")
    if dry_run:
        print("  Mode:        DRY RUN")
    print()

    # Pre-flight
    if not shutil.which("gh"):
        die("gh CLI is required")
    result = subprocess.run(["gh", "auth", "status"], capture_output=True)
    if result.returncode != 0:
        die("gh CLI is not authenticated — run: gh auth login")
    if not skip_site:
        if not site_dir.is_dir():
            die(f"Site repo not found: {site_dir} — pass --site-dir or --skip-site")

    # Write state
    state = PublishState(release_dir / "publish-state.json")
    if not dry_run:
        state.set("version", version)
        state.set("platforms.macos", platforms.macos)
        state.set("platforms.windows", platforms.windows)
        state.set("platforms.linux", platforms.linux)
        state.save()

    # Build
    if args.skip_build:
        steps.next("Build (skipped)")
        if not release_dir.is_dir() or not (release_dir / "manifest.json").is_file():
            die(f"Release dir not found or missing manifest: {release_dir}")
    else:
        steps.next("Build")
        build_args: list[str | Path] = [
            str(root_dir / "release.sh"),
            "--version", version,
            "--out-dir", str(release_dir),
        ]
        if args.skip_tests:
            build_args.append("--skip-tests")
        if args.skip_validation:
            build_args.append("--skip-validation")
        run_cmd(build_args, dry_run=dry_run)
    if not dry_run:
        state.mark_step("build")

    # Release notes
    steps.next("Release notes")
    notes_file = prepare_release_notes(version, tag, root_dir, release_dir, REPO, dry_run=dry_run)

    # Package
    steps.next(f"Sign and package ({platforms.description})")
    pkg_args = [sys.executable, __file__, "package", "--release-dir", str(release_dir)]
    if not (platforms.macos and platforms.windows and platforms.linux):
        if platforms.macos:
            pkg_args.append("--macos")
        if platforms.windows:
            pkg_args.append("--windows")
        if platforms.linux:
            pkg_args.append("--linux")
    run_cmd(pkg_args, dry_run=dry_run)
    if not dry_run:
        state.mark_step("package")

    # Windows CI round-trip
    if platforms.windows:
        # Draft release + upload payload zip
        steps.next("Create draft release and upload Windows payload zip")
        payload_zip = release_dir / "packages" / "windows" / WINDOWS_PAYLOAD_ZIP_TEMPLATE.format(version)

        if not dry_run:
            if not payload_zip.is_file():
                die(f"Payload zip not found: {payload_zip}")
            _ensure_draft_release(tag, version, notes_file, dry_run=False)
            run_cmd(["gh", "release", "upload", tag, "--repo", REPO, str(payload_zip), "--clobber"])
        else:
            _ensure_draft_release(tag, version, notes_file, dry_run=True)
            run_cmd(
                ["gh", "release", "upload", tag, "--repo", REPO, str(payload_zip), "--clobber"],
                dry_run=True,
            )

        # Trigger Windows installer build + wait
        steps.next("Build Windows installers (GitHub Actions)")
        run_id = dispatch_and_wait_windows_ci(version, REPO, dry_run=dry_run)

        if run_id:
            unsigned_dir = release_dir / "windows-unsigned"
            unsigned_dir.mkdir(parents=True, exist_ok=True)
            artifact_name = f"windows-installers-unsigned-{version}"
            run_cmd([
                "gh", "run", "download", run_id,
                "--repo", REPO,
                "--name", artifact_name,
                "--dir", str(unsigned_dir),
            ])
            if not dry_run:
                state.set("windows_ci_run_id", run_id)
                state.mark_step("windows_ci")

        # Sign final installers
        steps.next("Sign Windows installers")
        win_unsigned_dir = str(release_dir / "windows-unsigned")
        finalize_args = [
            sys.executable, __file__, "package",
            "--release-dir", str(release_dir),
            "--windows-unsigned-dir", win_unsigned_dir,
        ]
        run_cmd(finalize_args, dry_run=dry_run)
        if not dry_run:
            state.mark_step("windows_finalize")

    # Generate manifest
    steps.next("Generate download manifest")
    if not dry_run:
        generate_download_manifest(release_dir, REPO, tag, release_dir / "latest.json")
    else:
        print(f"  (dry-run) generate_download_manifest -> {release_dir / 'latest.json'}")
    if not dry_run:
        state.mark_step("manifest")

    # Upload
    steps.next("Upload release assets")
    if not dry_run:
        _ensure_draft_release(tag, version, notes_file, dry_run=False)

        assets: list[str] = []
        if platforms.macos:
            macos_pkg_dir = release_dir / "packages" / "macos"
            if macos_pkg_dir.is_dir():
                assets.extend(str(f) for f in sorted(macos_pkg_dir.glob("*.dmg")))
        if platforms.windows:
            win_pkg_dir = release_dir / "packages" / "windows"
            if win_pkg_dir.is_dir():
                assets.extend(str(f) for f in sorted(win_pkg_dir.glob("*.exe")))
        if platforms.linux:
            linux_pkg_dir = release_dir / "packages" / "linux"
            if linux_pkg_dir.is_dir():
                assets.extend(str(f) for f in sorted(linux_pkg_dir.glob("*.tar.gz")))

        for name in ("checksums.txt", "package-manifest.json", "manifest.json", "latest.json"):
            p = release_dir / name
            if p.is_file():
                assets.append(str(p))

        # Validation
        val_dir = release_dir / "validation"
        if val_dir.is_dir():
            assets.extend(str(f) for f in sorted(val_dir.glob("*.zip")))
            pkg_dir = val_dir / "package"
            if pkg_dir.is_dir():
                assets.extend(str(f) for f in sorted(pkg_dir.glob("*.pdf")))

        if not assets:
            die("No assets found to upload")
        print(f"  Uploading {len(assets)} assets...")
        run_cmd(["gh", "release", "upload", tag, "--repo", REPO, "--clobber"] + assets)
        state.mark_step("upload")
    else:
        print(f"  (dry-run) would upload packaged assets to {tag}")

    # Site
    if not skip_site:
        steps.next("Update site download manifest")
        site_manifest = site_dir / SITE_MANIFEST_REL
        if not dry_run:
            shutil.copy2(release_dir / "latest.json", site_manifest)
            run_cmd(["git", "-C", str(site_dir), "add", SITE_MANIFEST_REL])
            run_cmd(["git", "-C", str(site_dir), "commit", "-m", f"Update download manifest to {version}"])
            run_cmd(["git", "-C", str(site_dir), "push"])
            state.mark_step("site")
            print("  Site updated and pushed")
        else:
            print(f"  (dry-run) cp latest.json -> {site_manifest}")
            print("  (dry-run) would commit and push to site repo")

    # Done
    print(f"\n{'=' * 50}")
    print(f"  Release {version} — {platforms.description} complete")
    print(f"{'=' * 50}")
    print(f"\n  GitHub Release: https://github.com/{REPO}/releases/tag/{tag}")
    print(f"\n  The release is in DRAFT state.")
    print("  Review the assets, then publish:")
    print(f"    gh release edit {tag} --repo {REPO} --draft=false\n")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    root_dir = Path(__file__).resolve().parent.parent
    dist_dir = root_dir / "dist"

    version: str = args.version or ""
    if not version:
        found = find_latest_release_dir(dist_dir)
        if not found:
            die("No release dirs found in dist/")
        version = found

    if not is_valid_release_version(version):
        die(f"invalid version: {version}")

    release_dir = dist_dir / version
    tag = f"v{version}"
    site_dir = Path(args.site_dir) if args.site_dir else (root_dir / ".." / "site")

    show_status(release_dir, version, tag, REPO, site_dir if site_dir.is_dir() else None)
    return 0


# ---------------------------------------------------------------------------
# Section 16: argparse main
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="publish.py", description="RTMify release tooling")
    subparsers = parser.add_subparsers(dest="command")

    # package
    pkg = subparsers.add_parser("package", help="Sign and package release artifacts")
    pkg.add_argument("--release-dir", required=True)
    pkg.add_argument("--macos", action="store_true")
    pkg.add_argument("--windows", action="store_true")
    pkg.add_argument("--linux", action="store_true")
    pkg.add_argument("--skip-macos", action="store_true")
    pkg.add_argument("--skip-windows", action="store_true")
    pkg.add_argument("--skip-linux", action="store_true")
    pkg.add_argument("--windows-unsigned-dir")
    pkg.add_argument("--signing-identity")
    pkg.add_argument("--notary-key-file")
    pkg.add_argument("--notary-key-id")
    pkg.add_argument("--notary-issuer")
    pkg.add_argument("--azure-endpoint")
    pkg.add_argument("--azure-account")
    pkg.add_argument("--azure-profile")
    pkg.add_argument("--jsign-bin")
    pkg.add_argument("--jsign-jar")
    pkg.add_argument("--gpg-key")

    # release
    rel = subparsers.add_parser("release", help="Full release pipeline")
    rel.add_argument("--version")
    rel.add_argument("--macos", action="store_true")
    rel.add_argument("--windows", action="store_true")
    rel.add_argument("--linux", action="store_true")
    rel.add_argument("--skip-build", action="store_true")
    rel.add_argument("--skip-tests", action="store_true")
    rel.add_argument("--skip-validation", action="store_true")
    rel.add_argument("--skip-site", action="store_true")
    rel.add_argument("--site-dir")
    rel.add_argument("--dry-run", action="store_true")

    # status
    st = subparsers.add_parser("status", help="Show pipeline status")
    st.add_argument("--version")
    st.add_argument("--site-dir")

    parsed = parser.parse_args(argv)

    if not parsed.command:
        parser.print_help()
        return 2

    if parsed.command == "package":
        return cmd_package(parsed)
    elif parsed.command == "release":
        return cmd_release(parsed)
    elif parsed.command == "status":
        return cmd_status(parsed)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
