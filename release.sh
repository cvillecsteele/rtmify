#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT_DIR}/version.sh"
cd "${ROOT_DIR}"

DEFAULT_KEY_FILE="${HOME}/.rtmify/secrets/license-hmac-key.txt"
KEY_FILE="${RTMIFY_LICENSE_HMAC_KEY_FILE:-}"
OUT_DIR=""
VERSION=""
SKIP_TESTS=0
SKIP_VALIDATION=0
PYTHON_BIN="${PYTHON_BIN:-}"
BUILD_FILE="${ROOT_DIR}/build.zig"
TRACKED_VERSION=""
EXPLICIT_VERSION=0

usage() {
  cat <<'EOF'
./release.sh [--key-file <path>] [--out-dir <path>] [--version <value>] [--skip-tests] [--skip-validation]
  Without --version, release.sh computes the next tracked release version,
  builds with it, and writes it back to build.zig after a successful release.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-file)
      KEY_FILE="${2:?missing value for --key-file}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --version)
      VERSION="${2:?missing value for --version}"
      EXPLICIT_VERSION=1
      shift 2
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

TRACKED_VERSION="$(read_release_version "${BUILD_FILE}")"
if [[ -z "${TRACKED_VERSION}" ]]; then
  echo "Failed to determine version from ${BUILD_FILE}" >&2
  exit 2
fi
if ! is_valid_release_version "${TRACKED_VERSION}"; then
  echo "Tracked release version has invalid format: ${TRACKED_VERSION}" >&2
  echo "Expected YYYYMMDD-suffix, for example 20260314-a" >&2
  exit 2
fi

if [[ -z "${VERSION}" ]]; then
  VERSION="$(next_release_version "${TRACKED_VERSION}")"
elif ! is_valid_release_version "${VERSION}"; then
  echo "Explicit release version has invalid format: ${VERSION}" >&2
  echo "Expected YYYYMMDD-suffix, for example 20260314-a" >&2
  exit 2
fi

if [[ -z "${KEY_FILE}" ]]; then
  KEY_FILE="${DEFAULT_KEY_FILE}"
fi

if [[ ! -f "${KEY_FILE}" ]]; then
  echo "Missing signing key file: ${KEY_FILE}" >&2
  echo "Checked: --key-file, RTMIFY_LICENSE_HMAC_KEY_FILE, ${DEFAULT_KEY_FILE}" >&2
  echo >&2
  echo "To create the default key file:" >&2
  echo "  mkdir -p ~/.rtmify/secrets" >&2
  echo "  openssl rand -hex 32 > ~/.rtmify/secrets/license-hmac-key.txt" >&2
  echo "  chmod 600 ~/.rtmify/secrets/license-hmac-key.txt" >&2
  exit 2
fi

KEY_HEX="$(tr -d ' \t\r\n' < "${KEY_FILE}")"
if [[ ! "${KEY_HEX}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Signing key file must contain exactly 64 lowercase hex characters." >&2
  exit 2
fi

KEY_FINGERPRINT="$(printf '%s' "${KEY_HEX}" | xxd -r -p | shasum -a 256 | awk '{print $1}')"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist/${VERSION}}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtmify-release.XXXXXX")"
MANIFEST_ARTIFACTS="${TMP_DIR}/artifacts.jsonl"
MANIFEST_SMOKES="${TMP_DIR}/smokes.jsonl"
CHECKSUMS_FILE="${OUT_DIR}/checksums.txt"
SMOKE_HOME="${TMP_DIR}/home"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-cache}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/Library/Caches/ms-playwright}"
mkdir -p "${SMOKE_HOME}"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"
touch "${MANIFEST_ARTIFACTS}" "${MANIFEST_SMOKES}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

append_json_line() {
  local file="$1"
  local line="$2"
  if [[ -s "${file}" ]]; then
    printf ',\n' >> "${file}"
  fi
  printf '%s' "${line}" >> "${file}"
}

hash_path() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    tar -cf - -C "$(dirname "${path}")" "$(basename "${path}")" | shasum -a 256 | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

copy_artifact() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "${dest}")"
  if [[ -d "${src}" ]]; then
    rm -rf "${dest}"
    cp -R "${src}" "${dest}"
  else
    cp "${src}" "${dest}"
  fi
}

record_artifact() {
  local product="$1"
  local platform="$2"
  local kind="$3"
  local rel_path="$4"
  local abs_path="${OUT_DIR}/${rel_path}"
  local sha
  sha="$(hash_path "${abs_path}")"
  printf '%s  %s\n' "${sha}" "${rel_path}" >> "${CHECKSUMS_FILE}"
  append_json_line "${MANIFEST_ARTIFACTS}" \
    "{\"product\":\"${product}\",\"platform\":\"${platform}\",\"kind\":\"${kind}\",\"path\":\"${rel_path}\",\"sha256\":\"${sha}\"}"
}

record_smoke() {
  local product="$1"
  local binary_rel="$2"
  local license_id="$3"
  append_json_line "${MANIFEST_SMOKES}" \
    "{\"product\":\"${product}\",\"binary\":\"${binary_rel}\",\"result\":\"ok\",\"license_id\":\"${license_id}\"}"
}

extract_license_id() {
  sed -n 's/.*"license_id":"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

run_build() {
  echo "==> $*"
  "$@"
}

python_supports_openpyxl() {
  local candidate="$1"
  [[ -n "${candidate}" ]] || return 1
  [[ -x "${candidate}" ]] || return 1
  "${candidate}" - <<'PY' >/dev/null 2>&1
import openpyxl
PY
}

resolve_python() {
  local candidates=()
  if [[ -n "${PYTHON_BIN}" ]]; then
    candidates+=("${PYTHON_BIN}")
  fi
  if command -v python3 >/dev/null 2>&1; then
    candidates+=("$(command -v python3)")
  fi
  if [[ -x "${HOME}/.pyenv/shims/python3" ]]; then
    candidates+=("${HOME}/.pyenv/shims/python3")
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if python_supports_openpyxl "${candidate}"; then
      PYTHON_BIN="${candidate}"
      export PYTHON_BIN
      return 0
    fi
  done

  echo "Unable to find a Python interpreter with openpyxl available." >&2
  echo "Set PYTHON_BIN=/abs/path/to/python3 or install openpyxl into the python3 on your PATH." >&2
  exit 2
}

resolve_python

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/bin" "${OUT_DIR}/macos" "${OUT_DIR}/windows" "${OUT_DIR}/linux" "${OUT_DIR}/validation"
: > "${CHECKSUMS_FILE}"

BUILD_VERSION_FLAG=(-Drelease-version="${VERSION}")

if [[ "${SKIP_TESTS}" -ne 1 ]]; then
  run_build bash "${ROOT_DIR}/test/test_release_version.sh"
  run_build zig build test -Dlicense-hmac-key-file="${KEY_FILE}" >/dev/null
  run_build swift test --package-path "${ROOT_DIR}/live/macos"
  run_build swift test --package-path "${ROOT_DIR}/trace/macos"
  run_build "${PYTHON_BIN}" "${ROOT_DIR}/validation/test_package_validation.py"
fi

echo "Tracked release version: ${TRACKED_VERSION}"
if [[ "${EXPLICIT_VERSION}" -eq 1 ]]; then
  echo "Using explicit release version: ${VERSION}"
else
  echo "Bumping release version: ${TRACKED_VERSION} -> ${VERSION}"
fi

run_build zig build license-gen -Doptimize=ReleaseSafe -Dlicense-hmac-key-file="${KEY_FILE}" "${BUILD_VERSION_FLAG[@]}"
copy_artifact "${ROOT_DIR}/zig-out/bin/rtmify-license-gen" "${OUT_DIR}/bin/rtmify-license-gen"
record_artifact "operator" "macos" "binary" "bin/rtmify-license-gen"

run_build zig build trace -Doptimize=ReleaseSafe -Dlicense-hmac-key-file="${KEY_FILE}" "${BUILD_VERSION_FLAG[@]}"
copy_artifact "${ROOT_DIR}/zig-out/bin/rtmify-trace" "${OUT_DIR}/bin/rtmify-trace"
record_artifact "trace" "macos" "binary" "bin/rtmify-trace"

run_build zig build trace -Dtarget=x86_64-linux-gnu.2.31 -Doptimize=ReleaseSafe -Dlicense-hmac-key-file="${KEY_FILE}" "${BUILD_VERSION_FLAG[@]}"
copy_artifact "${ROOT_DIR}/zig-out/bin/rtmify-trace" "${OUT_DIR}/linux/rtmify-trace"
record_artifact "trace" "linux" "binary" "linux/rtmify-trace"

run_build zig build live -Doptimize=ReleaseSafe -Dlicense-hmac-key-file="${KEY_FILE}" "${BUILD_VERSION_FLAG[@]}"
copy_artifact "${ROOT_DIR}/zig-out/bin/rtmify-live" "${OUT_DIR}/bin/rtmify-live"
record_artifact "live" "macos" "binary" "bin/rtmify-live"

run_build zig build win-gui -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Dlicense-hmac-key-file="${KEY_FILE}" "${BUILD_VERSION_FLAG[@]}"
copy_artifact "${ROOT_DIR}/zig-out/bin/rtmify-trace.exe" "${OUT_DIR}/windows/rtmify-trace.exe"
record_artifact "trace" "windows" "binary" "windows/rtmify-trace.exe"

run_build zig build win-gui-live -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -Dlicense-hmac-key-file="${KEY_FILE}" "${BUILD_VERSION_FLAG[@]}"
copy_artifact "${ROOT_DIR}/zig-out/bin/rtmify-live.exe" "${OUT_DIR}/windows/rtmify-live.exe"
record_artifact "live" "windows" "binary" "windows/rtmify-live.exe"

run_build make -C "${ROOT_DIR}/trace/macos" build ZIG_OPTIMIZE=ReleaseSafe XCODE_CONFIGURATION=Release LICENSE_HMAC_KEY_FILE="${KEY_FILE}" RELEASE_VERSION="${VERSION}"
copy_artifact "${ROOT_DIR}/trace/macos/.build/Build/Products/Release/RTMify Trace.app" "${OUT_DIR}/macos/RTMify Trace.app"
record_artifact "trace" "macos" "app" "macos/RTMify Trace.app"

run_build make -C "${ROOT_DIR}/live/macos" app LICENSE_HMAC_KEY_FILE="${KEY_FILE}" RELEASE_VERSION="${VERSION}"
copy_artifact "${ROOT_DIR}/live/macos/.build/Build/Products/Release/RTMify Live.app" "${OUT_DIR}/macos/RTMify Live.app"
record_artifact "live" "macos" "app" "macos/RTMify Live.app"

LIVE_LICENSE="${TMP_DIR}/live-license.json"
TRACE_LICENSE="${TMP_DIR}/trace-license.json"

run_build env HOME="${SMOKE_HOME}" RTMIFY_LICENSE_HMAC_KEY_FILE="${KEY_FILE}" \
  "${ROOT_DIR}/zig-out/bin/rtmify-license-gen" \
  --product live --tier site --to operator@rtmify.io --org "RTMify Smoke" --perpetual --out "${LIVE_LICENSE}"

run_build env HOME="${SMOKE_HOME}" RTMIFY_LICENSE_HMAC_KEY_FILE="${KEY_FILE}" \
  "${ROOT_DIR}/zig-out/bin/rtmify-license-gen" \
  --product trace --tier individual --to operator@rtmify.io --org "RTMify Smoke" --perpetual --out "${TRACE_LICENSE}"

LIVE_LICENSE_ID="$(extract_license_id "${LIVE_LICENSE}")"
TRACE_LICENSE_ID="$(extract_license_id "${TRACE_LICENSE}")"

run_build "${OUT_DIR}/bin/rtmify-live" license info --license "${LIVE_LICENSE}" --json >/dev/null
record_smoke "live" "bin/rtmify-live" "${LIVE_LICENSE_ID}"

run_build "${OUT_DIR}/bin/rtmify-trace" license info --license "${TRACE_LICENSE}" --json >/dev/null
record_smoke "trace" "bin/rtmify-trace" "${TRACE_LICENSE_ID}"

if [[ "${SKIP_VALIDATION}" -ne 1 ]]; then
  VALIDATION_PACKAGE_DIR="${OUT_DIR}/validation/package"
  VALIDATION_CHECKSUMS="${VALIDATION_PACKAGE_DIR}/checksums.txt"
  run_build env HOME="${SMOKE_HOME}" RTMIFY_LICENSE="${TRACE_LICENSE}" "${PYTHON_BIN}" "${ROOT_DIR}/validation/package_validation.py" \
    --version "${VERSION}" \
    --trace-binary "${OUT_DIR}/bin/rtmify-trace" \
    --trace-binary-windows "${OUT_DIR}/windows/rtmify-trace.exe" \
    --trace-binary-linux "${OUT_DIR}/linux/rtmify-trace" \
    --out-dir "${VALIDATION_PACKAGE_DIR}" \
    --checksums-file "${VALIDATION_CHECKSUMS}"
  record_artifact "trace-validation" "any" "directory" "validation/package"
  record_artifact "trace-validation" "any" "zip" "validation/RTMify_Trace_Validation_Package_v${VERSION}.zip"
  record_artifact "trace-validation" "any" "pdf" "validation/package/RTMify_Trace_IQOQ_Protocol_v${VERSION}.pdf"
  record_artifact "trace-validation" "any" "pdf" "validation/package/RTMify_Trace_IQOQ_Evidence_v${VERSION}.pdf"
fi

cat > "${OUT_DIR}/manifest.json" <<EOF
{
  "version": "${VERSION}",
  "built_at": $(date +%s),
  "key_fingerprint": "${KEY_FINGERPRINT}",
  "artifacts": [
$(cat "${MANIFEST_ARTIFACTS}")
  ],
  "smoke_checks": [
$(cat "${MANIFEST_SMOKES}")
  ]
}
EOF

if [[ "${TRACKED_VERSION}" != "${VERSION}" ]]; then
  write_release_version "${BUILD_FILE}" "${VERSION}"
  echo "Updated tracked release version in ${BUILD_FILE}: ${TRACKED_VERSION} -> ${VERSION}"
fi

echo "Release artifacts written to ${OUT_DIR}"
echo "Key fingerprint: ${KEY_FINGERPRINT}"
