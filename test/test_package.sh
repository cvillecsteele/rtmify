#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT_DIR}/package.sh"

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "FAIL: ${message}" >&2
    echo "  expected: $(printf '%q' "${expected}")" >&2
    echo "  actual:   $(printf '%q' "${actual}")" >&2
    FAIL=$(( FAIL + 1 ))
  else
    echo "PASS: ${message}"
    PASS=$(( PASS + 1 ))
  fi
}

assert_exits() {
  local expected_code="$1"
  local message="$2"
  shift 2
  local actual_code=0
  "$@" >/dev/null 2>&1 || actual_code=$?
  if [[ "${actual_code}" -ne "${expected_code}" ]]; then
    echo "FAIL: ${message}" >&2
    echo "  expected exit ${expected_code}, got ${actual_code}" >&2
    FAIL=$(( FAIL + 1 ))
  else
    echo "PASS: ${message}"
    PASS=$(( PASS + 1 ))
  fi
}

assert_file_exists() {
  local path="$1"
  local message="$2"
  if [[ ! -f "${path}" ]]; then
    echo "FAIL: ${message}" >&2
    echo "  file not found: ${path}" >&2
    FAIL=$(( FAIL + 1 ))
  else
    echo "PASS: ${message}"
    PASS=$(( PASS + 1 ))
  fi
}

assert_contains() {
  local pattern="$1"
  local actual="$2"
  local message="$3"
  if ! echo "${actual}" | grep -qF "${pattern}"; then
    echo "FAIL: ${message}" >&2
    echo "  pattern not found: ${pattern}" >&2
    echo "  actual: ${actual}" >&2
    FAIL=$(( FAIL + 1 ))
  else
    echo "PASS: ${message}"
    PASS=$(( PASS + 1 ))
  fi
}

assert_not_contains() {
  local pattern="$1"
  local actual="$2"
  local message="$3"
  if echo "${actual}" | grep -qF "${pattern}"; then
    echo "FAIL: ${message}" >&2
    echo "  unexpected pattern found: ${pattern}" >&2
    echo "  actual: ${actual}" >&2
    FAIL=$(( FAIL + 1 ))
  else
    echo "PASS: ${message}"
    PASS=$(( PASS + 1 ))
  fi
}

write_release_manifest() {
  local path="$1"
  local version="$2"
  local artifacts="${3:-}"
  cat > "${path}" <<EOF
{
  "version": "${version}",
  "built_at": 1711152000,
  "key_fingerprint": "test-fingerprint",
  "artifacts": [
${artifacts}
  ],
  "smoke_checks": []
}
EOF
}

ARTIFACT_LINUX_TRACE='    {"product":"trace","platform":"linux","kind":"binary","path":"linux/rtmify-trace","sha256":"linux-trace-sha"}'
ARTIFACT_MACOS_LICENSE='    {"product":"operator","platform":"macos","kind":"binary","path":"bin/rtmify-license-gen","sha256":"license-sha"}'
ARTIFACT_MACOS_TRACE='    {"product":"trace","platform":"macos","kind":"binary","path":"bin/rtmify-trace","sha256":"trace-sha"}'
ARTIFACT_MACOS_LIVE='    {"product":"live","platform":"macos","kind":"binary","path":"bin/rtmify-live","sha256":"live-sha"}'
ARTIFACT_MACOS_TRACE_APP='    {"product":"trace","platform":"macos","kind":"app","path":"macos/RTMify Trace.app","sha256":"trace-app-sha"}'
ARTIFACT_MACOS_LIVE_APP='    {"product":"live","platform":"macos","kind":"app","path":"macos/RTMify Live.app","sha256":"live-app-sha"}'
ARTIFACT_WINDOWS_TRACE='    {"product":"trace","platform":"windows","kind":"binary","path":"windows/rtmify-trace.exe","sha256":"trace-win-sha"}'
ARTIFACT_WINDOWS_LIVE_SHELL='    {"product":"live","platform":"windows","kind":"binary","path":"windows/RTMify Live.exe","sha256":"live-shell-sha"}'
ARTIFACT_WINDOWS_LIVE_SERVER='    {"product":"live","platform":"windows","kind":"binary","path":"windows/rtmify-live.exe","sha256":"live-server-sha"}'

# ---------------------------------------------------------------------------
# Temp dirs
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtmify-package-test.XXXXXX")"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

FAKE_JSIGN="${TMP_DIR}/fake-jsign.sh"
cat > "${FAKE_JSIGN}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${TMP_DIR}/fake-jsign.log"
exit 0
EOF
chmod +x "${FAKE_JSIGN}"

# ---------------------------------------------------------------------------
# Source package.sh to test helper functions in-process
# ---------------------------------------------------------------------------

# Sourcing only defines functions; main() is not called.
# shellcheck disable=SC1090
source "${SCRIPT}"

# ---------------------------------------------------------------------------
# product_title
# ---------------------------------------------------------------------------

assert_eq "Trace" "$(product_title trace)" "product_title: trace → Trace"
assert_eq "Live"  "$(product_title live)"  "product_title: live → Live"
assert_eq "myapp" "$(product_title myapp)" "product_title: unknown passthrough"

# ---------------------------------------------------------------------------
# append_json_line
# ---------------------------------------------------------------------------

JSONL="${TMP_DIR}/test.jsonl"
touch "${JSONL}"

append_json_line "${JSONL}" '{"a":1}'
assert_eq '{"a":1}' "$(cat "${JSONL}")" "append_json_line: first entry has no prefix comma"

append_json_line "${JSONL}" '{"b":2}'
EXPECTED=$'{"a":1},\n{"b":2}'
assert_eq "${EXPECTED}" "$(cat "${JSONL}")" "append_json_line: second entry gets comma+newline prefix"

append_json_line "${JSONL}" '{"c":3}'
EXPECTED=$'{"a":1},\n{"b":2},\n{"c":3}'
assert_eq "${EXPECTED}" "$(cat "${JSONL}")" "append_json_line: third entry gets comma+newline prefix"

# ---------------------------------------------------------------------------
# hash_path — file
# ---------------------------------------------------------------------------

HASH_FILE="${TMP_DIR}/hashme.txt"
echo "hello" > "${HASH_FILE}"
HASH1="$(hash_path "${HASH_FILE}")"
HASH2="$(hash_path "${HASH_FILE}")"
assert_eq "${HASH1}" "${HASH2}" "hash_path: identical file produces identical hash"
assert_eq 64 "${#HASH1}" "hash_path: SHA-256 is 64 hex chars"

# ---------------------------------------------------------------------------
# record_checksum
# ---------------------------------------------------------------------------

CHECKSUMS_FILE="${TMP_DIR}/checksums.txt"
TMP_DIR="${TMP_DIR}"
CHECKSUM_TARGET="${TMP_DIR}/checksummed.txt"
echo "before" > "${CHECKSUM_TARGET}"
OLD_SHA="$(hash_path "${CHECKSUM_TARGET}")"
printf '%s  windows/rtmify-trace.exe\n' "${OLD_SHA}" > "${CHECKSUMS_FILE}"

echo "after" > "${CHECKSUM_TARGET}"
NEW_SHA="$(record_checksum "windows/rtmify-trace.exe" "${CHECKSUM_TARGET}")"
assert_eq 64 "${#NEW_SHA}" "record_checksum: returns SHA-256 hash"
CHECKSUM_LINES="$(grep -c 'windows/rtmify-trace.exe' "${CHECKSUMS_FILE}")"
assert_eq "1" "${CHECKSUM_LINES}" "record_checksum: replaces existing checksum entry"
CHECKSUM_ENTRY="$(cat "${CHECKSUMS_FILE}")"
assert_contains "${NEW_SHA}  windows/rtmify-trace.exe" "${CHECKSUM_ENTRY}" "record_checksum: writes updated checksum"

# ---------------------------------------------------------------------------
# CLI: argument validation (subprocess)
# ---------------------------------------------------------------------------

assert_exits 2 "no args → exit 2"                       "${SCRIPT}"
assert_exits 0 "--help → exit 0"                         "${SCRIPT}" --help
assert_exits 0 "-h → exit 0"                             "${SCRIPT}" -h
assert_exits 2 "unknown flag → exit 2"                   "${SCRIPT}" --unknown-flag
assert_exits 1 "missing --release-dir value → non-zero"  "${SCRIPT}" --release-dir

# ---------------------------------------------------------------------------
# CLI: release dir validation (subprocess)
# ---------------------------------------------------------------------------

assert_exits 2 "nonexistent release dir → exit 2" \
  "${SCRIPT}" --release-dir "${TMP_DIR}/nonexistent" --skip-macos --skip-windows --skip-linux

# dir exists but no manifest
EMPTY_REL="${TMP_DIR}/empty-release"
mkdir -p "${EMPTY_REL}"
assert_exits 2 "dir without manifest.json → exit 2" \
  "${SCRIPT}" --release-dir "${EMPTY_REL}" --skip-macos --skip-windows --skip-linux

# manifest with invalid version
write_release_manifest "${EMPTY_REL}/manifest.json" "not-a-version"
assert_exits 2 "manifest with invalid version → exit 2" \
  "${SCRIPT}" --release-dir "${EMPTY_REL}" --skip-macos --skip-windows --skip-linux

# ---------------------------------------------------------------------------
# Linux: release dir missing expected artifact file → exit 2
# ---------------------------------------------------------------------------

VALID_REL="${TMP_DIR}/valid-release-no-bins"
mkdir -p "${VALID_REL}/linux"
write_release_manifest "${VALID_REL}/manifest.json" "20260328-a" "${ARTIFACT_LINUX_TRACE}"

assert_exits 2 "linux missing required artifact file → exit 2" \
  "${SCRIPT}" --release-dir "${VALID_REL}" --skip-macos --skip-windows

# ---------------------------------------------------------------------------
# Linux: manifest missing required artifact entry → exit 2
# ---------------------------------------------------------------------------

MISSING_ARTIFACT_REL="${TMP_DIR}/missing-artifact-entry"
mkdir -p "${MISSING_ARTIFACT_REL}/linux"
write_release_manifest "${MISSING_ARTIFACT_REL}/manifest.json" "20260328-a"
echo "#!/bin/sh\necho hello" > "${MISSING_ARTIFACT_REL}/linux/rtmify-trace"
chmod +x "${MISSING_ARTIFACT_REL}/linux/rtmify-trace"
assert_exits 2 "linux missing manifest artifact entry → exit 2" \
  "${SCRIPT}" --release-dir "${MISSING_ARTIFACT_REL}" --skip-macos --skip-windows

# ---------------------------------------------------------------------------
# Linux: tarball creation
# ---------------------------------------------------------------------------

LINUX_REL="${TMP_DIR}/valid-release-linux"
mkdir -p "${LINUX_REL}/linux"
write_release_manifest "${LINUX_REL}/manifest.json" "20260328-a" "${ARTIFACT_LINUX_TRACE}"
# Create a dummy binary
echo "#!/bin/sh\necho hello" > "${LINUX_REL}/linux/rtmify-trace"
chmod +x "${LINUX_REL}/linux/rtmify-trace"

"${SCRIPT}" --release-dir "${LINUX_REL}" --skip-macos --skip-windows

TARBALL="${LINUX_REL}/packages/linux/rtmify-trace-linux-x64-20260328-a.tar.gz"
assert_file_exists "${TARBALL}" "linux: tarball created"

# verify tarball contains the binary
TARBALL_CONTENTS="$(tar tzf "${TARBALL}")"
assert_contains "rtmify-trace" "${TARBALL_CONTENTS}" "linux: tarball contains the binary"

# checksums.txt updated
assert_file_exists "${LINUX_REL}/checksums.txt" "linux: checksums.txt created"
CHECKSUMS="$(cat "${LINUX_REL}/checksums.txt")"
assert_contains "packages/linux/rtmify-trace-linux-x64-20260328-a.tar.gz" \
  "${CHECKSUMS}" "linux: checksums.txt references tarball"

# package-manifest.json has correct linux entry
PKG_JSON="$(cat "${LINUX_REL}/package-manifest.json")"
assert_contains '"product":"trace"' "${PKG_JSON}" "linux: manifest has product trace"
assert_contains '"path":"packages/linux/rtmify-trace-linux-x64-20260328-a.tar.gz"' \
  "${PKG_JSON}" "linux: manifest has correct path"
assert_contains '"sha256"' "${PKG_JSON}" "linux: manifest has sha256 field"

# SHA in checksums matches SHA in manifest
CHECKSUMS_SHA="$(awk '{print $1}' "${LINUX_REL}/checksums.txt")"
assert_contains "${CHECKSUMS_SHA}" "${PKG_JSON}" "linux: manifest sha256 matches checksums.txt"

# ---------------------------------------------------------------------------
# Linux: multiple binaries
# ---------------------------------------------------------------------------

echo "#!/bin/sh\necho live" > "${LINUX_REL}/linux/rtmify-live"
chmod +x "${LINUX_REL}/linux/rtmify-live"

# Re-run (will overwrite previous outputs)
"${SCRIPT}" --release-dir "${LINUX_REL}" --skip-macos --skip-windows

assert_file_exists "${LINUX_REL}/packages/linux/rtmify-live-linux-x64-20260328-a.tar.gz" \
  "linux: second binary gets its own tarball"
LIVE_PKG_JSON="$(cat "${LINUX_REL}/package-manifest.json")"
assert_contains '"product":"live"' "${LIVE_PKG_JSON}" "linux: manifest has product live"

# ---------------------------------------------------------------------------
# macOS: missing credentials → exit 2
# ---------------------------------------------------------------------------

MACOS_REL="${TMP_DIR}/macos-creds-test"
mkdir -p "${MACOS_REL}"
mkdir -p "${MACOS_REL}/bin" "${MACOS_REL}/macos/RTMify Trace.app" "${MACOS_REL}/macos/RTMify Live.app"
touch "${MACOS_REL}/bin/rtmify-license-gen" "${MACOS_REL}/bin/rtmify-trace" "${MACOS_REL}/bin/rtmify-live"
write_release_manifest "${MACOS_REL}/manifest.json" "20260328-a" \
"${ARTIFACT_MACOS_LICENSE},
${ARTIFACT_MACOS_TRACE},
${ARTIFACT_MACOS_LIVE},
${ARTIFACT_MACOS_TRACE_APP},
${ARTIFACT_MACOS_LIVE_APP}"

# Unset any env vars that might be set in the caller's environment
assert_exits 2 "missing macOS creds → exit 2" \
  env -u APPLE_SIGNING_IDENTITY \
      -u RTMIFY_NOTARY_KEY_FILE -u RTMIFY_NOTARY_KEY_ID -u RTMIFY_NOTARY_ISSUER_UUID \
      "${SCRIPT}" --release-dir "${MACOS_REL}" --skip-windows --skip-linux

# ---------------------------------------------------------------------------
# Windows: missing credentials → exit 2
# ---------------------------------------------------------------------------

WIN_REL="${TMP_DIR}/win-creds-test"
mkdir -p "${WIN_REL}/windows"
touch "${WIN_REL}/windows/rtmify-trace.exe" "${WIN_REL}/windows/RTMify Live.exe" "${WIN_REL}/windows/rtmify-live.exe"
write_release_manifest "${WIN_REL}/manifest.json" "20260328-a" \
"${ARTIFACT_WINDOWS_TRACE},
${ARTIFACT_WINDOWS_LIVE_SHELL},
${ARTIFACT_WINDOWS_LIVE_SERVER}"

assert_exits 2 "missing Windows creds → exit 2" \
  env -u AZURE_TRUSTED_SIGNING_ENDPOINT -u AZURE_TRUSTED_SIGNING_ACCOUNT -u AZURE_TRUSTED_SIGNING_PROFILE \
      "${SCRIPT}" --release-dir "${WIN_REL}" --skip-macos --skip-linux

# ---------------------------------------------------------------------------
# Windows: stage payload zip + finalize installers
# ---------------------------------------------------------------------------

WIN_STAGE_REL="${TMP_DIR}/win-stage"
mkdir -p "${WIN_STAGE_REL}/windows"
printf 'trace exe' > "${WIN_STAGE_REL}/windows/rtmify-trace.exe"
printf 'live shell exe' > "${WIN_STAGE_REL}/windows/RTMify Live.exe"
printf 'live server exe' > "${WIN_STAGE_REL}/windows/rtmify-live.exe"
write_release_manifest "${WIN_STAGE_REL}/manifest.json" "20260328-a" \
"${ARTIFACT_WINDOWS_TRACE},
${ARTIFACT_WINDOWS_LIVE_SHELL},
${ARTIFACT_WINDOWS_LIVE_SERVER}"

env \
  AZURE_TRUSTED_SIGNING_ENDPOINT="https://eus.codesigning.azure.net/" \
  AZURE_TRUSTED_SIGNING_ACCOUNT="RTMify" \
  AZURE_TRUSTED_SIGNING_PROFILE="RTMify" \
  AZURE_ACCESS_TOKEN="test-token" \
  JSIGN_BIN="${FAKE_JSIGN}" \
  "${SCRIPT}" --release-dir "${WIN_STAGE_REL}" --skip-macos --skip-linux

WINDOWS_PAYLOAD_ZIP="${WIN_STAGE_REL}/packages/windows/RTMify_Windows_Payloads_20260328-a.zip"
assert_file_exists "${WINDOWS_PAYLOAD_ZIP}" "windows: payload zip created"

ZIP_LIST="$(python3 - "${WINDOWS_PAYLOAD_ZIP}" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    print("\n".join(sorted(archive.namelist())))
PY
)"
assert_contains "RTMify Live.exe" "${ZIP_LIST}" "windows: payload zip contains live shell"
assert_contains "rtmify-live.exe" "${ZIP_LIST}" "windows: payload zip contains live server"
assert_contains "rtmify-trace.exe" "${ZIP_LIST}" "windows: payload zip contains trace exe"
assert_contains "windows-installer-input.json" "${ZIP_LIST}" "windows: payload zip contains installer manifest"

WIN_STAGE_JSON="$(cat "${WIN_STAGE_REL}/package-manifest.json")"
assert_contains '"status":"payloads_signed"' "${WIN_STAGE_JSON}" "windows: stage manifest status is payloads_signed"
assert_contains '"payload_zip":{"path":"packages/windows/RTMify_Windows_Payloads_20260328-a.zip"' "${WIN_STAGE_JSON}" "windows: stage manifest records payload zip"
assert_contains '"installers":[]' "${WIN_STAGE_JSON}" "windows: stage manifest has no installers"

WIN_UNSIGNED_BAD="${TMP_DIR}/win-unsigned-bad"
mkdir -p "${WIN_UNSIGNED_BAD}"
printf 'wrong' > "${WIN_UNSIGNED_BAD}/wrong-name.exe"
assert_exits 2 "windows finalize rejects wrong unsigned filenames → exit 2" \
  env \
    AZURE_TRUSTED_SIGNING_ENDPOINT="https://eus.codesigning.azure.net/" \
    AZURE_TRUSTED_SIGNING_ACCOUNT="RTMify" \
    AZURE_TRUSTED_SIGNING_PROFILE="RTMify" \
    AZURE_ACCESS_TOKEN="test-token" \
    JSIGN_BIN="${FAKE_JSIGN}" \
    "${SCRIPT}" --release-dir "${WIN_STAGE_REL}" --windows-unsigned-dir "${WIN_UNSIGNED_BAD}"

WIN_UNSIGNED_GOOD="${TMP_DIR}/win-unsigned-good"
mkdir -p "${WIN_UNSIGNED_GOOD}"
printf 'trace installer unsigned' > "${WIN_UNSIGNED_GOOD}/RTMify_Trace_Installer_20260328-a_unsigned.exe"
printf 'live installer unsigned' > "${WIN_UNSIGNED_GOOD}/RTMify_Live_Installer_20260328-a_unsigned.exe"

env \
  AZURE_TRUSTED_SIGNING_ENDPOINT="https://eus.codesigning.azure.net/" \
  AZURE_TRUSTED_SIGNING_ACCOUNT="RTMify" \
  AZURE_TRUSTED_SIGNING_PROFILE="RTMify" \
  AZURE_ACCESS_TOKEN="test-token" \
  JSIGN_BIN="${FAKE_JSIGN}" \
  "${SCRIPT}" --release-dir "${WIN_STAGE_REL}" --windows-unsigned-dir "${WIN_UNSIGNED_GOOD}"

assert_file_exists "${WIN_STAGE_REL}/packages/windows/RTMify_Trace_Installer_20260328-a.exe" \
  "windows: finalized trace installer created"
assert_file_exists "${WIN_STAGE_REL}/packages/windows/RTMify_Live_Installer_20260328-a.exe" \
  "windows: finalized live installer created"

WIN_FINAL_JSON="$(cat "${WIN_STAGE_REL}/package-manifest.json")"
assert_contains '"status":"finalized"' "${WIN_FINAL_JSON}" "windows: finalize manifest status is finalized"
assert_contains '"path":"packages/windows/RTMify_Trace_Installer_20260328-a.exe"' "${WIN_FINAL_JSON}" \
  "windows: finalize manifest includes trace installer"
assert_contains '"path":"packages/windows/RTMify_Live_Installer_20260328-a.exe"' "${WIN_FINAL_JSON}" \
  "windows: finalize manifest includes live installer"

WIN_FINAL_CHECKSUMS="$(cat "${WIN_STAGE_REL}/checksums.txt")"
assert_contains 'packages/windows/RTMify_Windows_Payloads_20260328-a.zip' "${WIN_FINAL_CHECKSUMS}" \
  "windows: checksums retain payload zip after finalize"
assert_contains 'packages/windows/RTMify_Trace_Installer_20260328-a.exe' "${WIN_FINAL_CHECKSUMS}" \
  "windows: checksums include finalized trace installer"
assert_contains 'packages/windows/RTMify_Live_Installer_20260328-a.exe' "${WIN_FINAL_CHECKSUMS}" \
  "windows: checksums include finalized live installer"

# ---------------------------------------------------------------------------
# Positive platform selection flags (--macos, --windows, --linux)
# ---------------------------------------------------------------------------

# --linux alone skips macOS and Windows validation
ONLY_LINUX_REL="${TMP_DIR}/only-linux"
mkdir -p "${ONLY_LINUX_REL}/linux"
write_release_manifest "${ONLY_LINUX_REL}/manifest.json" "20260328-a" "${ARTIFACT_LINUX_TRACE}"
echo "#!/bin/sh\necho hello" > "${ONLY_LINUX_REL}/linux/rtmify-trace"
chmod +x "${ONLY_LINUX_REL}/linux/rtmify-trace"

"${SCRIPT}" --release-dir "${ONLY_LINUX_REL}" --linux
assert_file_exists "${ONLY_LINUX_REL}/packages/linux/rtmify-trace-linux-x64-20260328-a.tar.gz" \
  "--linux: tarball created"
ONLY_LINUX_JSON="$(cat "${ONLY_LINUX_REL}/package-manifest.json")"
assert_not_contains '"macos"' "${ONLY_LINUX_JSON}" "--linux: no macos section in manifest"
assert_not_contains '"windows"' "${ONLY_LINUX_JSON}" "--linux: no windows section in manifest"

# --windows alone skips macOS and Linux validation
ONLY_WIN_REL="${TMP_DIR}/only-win"
mkdir -p "${ONLY_WIN_REL}/windows"
printf 'trace' > "${ONLY_WIN_REL}/windows/rtmify-trace.exe"
printf 'live shell' > "${ONLY_WIN_REL}/windows/RTMify Live.exe"
printf 'live server' > "${ONLY_WIN_REL}/windows/rtmify-live.exe"
write_release_manifest "${ONLY_WIN_REL}/manifest.json" "20260328-a" \
"${ARTIFACT_WINDOWS_TRACE},
${ARTIFACT_WINDOWS_LIVE_SHELL},
${ARTIFACT_WINDOWS_LIVE_SERVER}"

env \
  AZURE_TRUSTED_SIGNING_ENDPOINT="https://eus.codesigning.azure.net/" \
  AZURE_TRUSTED_SIGNING_ACCOUNT="RTMify" \
  AZURE_TRUSTED_SIGNING_PROFILE="RTMify" \
  AZURE_ACCESS_TOKEN="test-token" \
  JSIGN_BIN="${FAKE_JSIGN}" \
  "${SCRIPT}" --release-dir "${ONLY_WIN_REL}" --windows

ONLY_WIN_JSON="$(cat "${ONLY_WIN_REL}/package-manifest.json")"
assert_contains '"windows"' "${ONLY_WIN_JSON}" "--windows: windows section present"
assert_not_contains '"macos"' "${ONLY_WIN_JSON}" "--windows: no macos section"
assert_not_contains '"linux"' "${ONLY_WIN_JSON}" "--windows: no linux section"

# --linux --windows together runs both, skips macOS
COMBO_REL="${TMP_DIR}/combo-linux-win"
mkdir -p "${COMBO_REL}/linux" "${COMBO_REL}/windows"
printf 'trace' > "${COMBO_REL}/windows/rtmify-trace.exe"
printf 'live shell' > "${COMBO_REL}/windows/RTMify Live.exe"
printf 'live server' > "${COMBO_REL}/windows/rtmify-live.exe"
echo "#!/bin/sh\necho hello" > "${COMBO_REL}/linux/rtmify-trace"
chmod +x "${COMBO_REL}/linux/rtmify-trace"
write_release_manifest "${COMBO_REL}/manifest.json" "20260328-a" \
"${ARTIFACT_LINUX_TRACE},
${ARTIFACT_WINDOWS_TRACE},
${ARTIFACT_WINDOWS_LIVE_SHELL},
${ARTIFACT_WINDOWS_LIVE_SERVER}"

env \
  AZURE_TRUSTED_SIGNING_ENDPOINT="https://eus.codesigning.azure.net/" \
  AZURE_TRUSTED_SIGNING_ACCOUNT="RTMify" \
  AZURE_TRUSTED_SIGNING_PROFILE="RTMify" \
  AZURE_ACCESS_TOKEN="test-token" \
  JSIGN_BIN="${FAKE_JSIGN}" \
  "${SCRIPT}" --release-dir "${COMBO_REL}" --linux --windows

COMBO_JSON="$(cat "${COMBO_REL}/package-manifest.json")"
assert_contains '"linux"' "${COMBO_JSON}" "--linux --windows: linux section present"
assert_contains '"windows"' "${COMBO_JSON}" "--linux --windows: windows section present"
assert_not_contains '"macos"' "${COMBO_JSON}" "--linux --windows: no macos section"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
