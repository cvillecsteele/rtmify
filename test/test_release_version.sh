#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT_DIR}/version.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "assertion failed: ${message}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

assert_true() {
  local message="$1"
  shift
  if ! "$@"; then
    echo "assertion failed: ${message}" >&2
    exit 1
  fi
}

assert_false() {
  local message="$1"
  shift
  if "$@"; then
    echo "assertion failed: ${message}" >&2
    exit 1
  fi
}

assert_eq "20260308-b" "$(next_release_version "20260308-a" "20260308")" "same-day release increments suffix"
assert_eq "20260308-aa" "$(next_release_version "20260308-z" "20260308")" "suffix rolls over after z"
assert_eq "20260308-ba" "$(next_release_version "20260308-az" "20260308")" "suffix increment carries across multiple letters"
assert_eq "20260314-a" "$(next_release_version "20260308-c" "20260314")" "new day resets suffix to a"
assert_eq "20260320-c" "$(next_release_version "20260320-b" "20260314")" "clock skew does not move release version backwards"

assert_true "valid release version accepted" is_valid_release_version "20260314-a"
assert_false "missing suffix rejected" is_valid_release_version "20260314"
assert_false "uppercase suffix rejected" is_valid_release_version "20260314-A"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtmify-release-version-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
BUILD_FILE="${TMP_DIR}/build.zig"
cat > "${BUILD_FILE}" <<'EOF'
pub fn build() void {
    const default_version = "20260308-a";
    const version = default_version;
}
EOF

assert_eq "20260308-a" "$(read_release_version "${BUILD_FILE}")" "read_release_version extracts the tracked version"
write_release_version "${BUILD_FILE}" "20260314-a"
assert_eq "20260314-a" "$(read_release_version "${BUILD_FILE}")" "write_release_version updates the tracked version"

grep -q 'const default_version = "20260314-a";' "${BUILD_FILE}"
