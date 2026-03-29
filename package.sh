#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT_DIR}/version.sh"

# ---------------------------------------------------------------------------
# Defaults — all overridable via flags or environment variables
# ---------------------------------------------------------------------------

RELEASE_DIR=""
SKIP_MACOS=0
SKIP_WINDOWS=0
SKIP_LINUX=0

# macOS signing credentials
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
INSTALLER_IDENTITY="${APPLE_INSTALLER_IDENTITY:-}"
NOTARY_KEY_FILE="${RTMIFY_NOTARY_KEY_FILE:-}"
NOTARY_KEY_ID="${RTMIFY_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${RTMIFY_NOTARY_ISSUER_UUID:-}"

# Windows signing credentials (Azure Trusted Signing)
AZURE_ENDPOINT="${AZURE_TRUSTED_SIGNING_ENDPOINT:-}"
AZURE_ACCOUNT="${AZURE_TRUSTED_SIGNING_ACCOUNT:-}"
AZURE_PROFILE="${AZURE_TRUSTED_SIGNING_PROFILE:-}"
# AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET read from environment directly

# Linux signing credentials (optional)
GPG_KEY="${GPG_SIGNING_KEY_ID:-}"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
./package.sh --release-dir <path> [options]

  --release-dir PATH         completed release dir from release.sh (required)
  --skip-macos               skip macOS signing and packaging
  --skip-windows             skip Windows signing
  --skip-linux               skip Linux tarball creation

macOS credentials (env vars preferred; flags for one-offs):
  --signing-identity STR     Developer ID Application identity
                             (or APPLE_SIGNING_IDENTITY)
  --installer-identity STR   Developer ID Installer identity
                             (or APPLE_INSTALLER_IDENTITY)
  --notary-key-file PATH     path to .p8 notarytool API key
                             (or RTMIFY_NOTARY_KEY_FILE)
  --notary-key-id STR        10-char notarytool key ID
                             (or RTMIFY_NOTARY_KEY_ID)
  --notary-issuer UUID       notarytool issuer UUID
                             (or RTMIFY_NOTARY_ISSUER_UUID)

Windows credentials (env vars only for secrets):
  --azure-endpoint URL       Azure Trusted Signing endpoint
                             (or AZURE_TRUSTED_SIGNING_ENDPOINT)
  --azure-account STR        Azure Trusted Signing account name
                             (or AZURE_TRUSTED_SIGNING_ACCOUNT)
  --azure-profile STR        certificate profile name
                             (or AZURE_TRUSTED_SIGNING_PROFILE)
  AZURE_TENANT_ID            Azure tenant ID (env var)
  AZURE_CLIENT_ID            Azure client ID (env var)
  AZURE_CLIENT_SECRET        Azure client secret (env var)

Linux credentials:
  --gpg-key STR              GPG key ID for tarball signing; optional
                             (or GPG_SIGNING_KEY_ID)
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Entitlements paths (in the repo, created alongside package.sh)
# ---------------------------------------------------------------------------

TRACE_ENTITLEMENTS="${ROOT_DIR}/trace/macos/RTMify Trace/RTMify Trace.entitlements"
LIVE_ENTITLEMENTS="${ROOT_DIR}/live/macos/RTMify Live/RTMify Live.entitlements"

# ---------------------------------------------------------------------------
# Shared helpers (same patterns as release.sh)
# ---------------------------------------------------------------------------

run_build() {
  echo "==> $*"
  "$@"
}

hash_path() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    tar -cf - -C "$(dirname "${path}")" "$(basename "${path}")" | shasum -a 256 | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

record_checksum() {
  local rel_path="$1"
  local abs_path="$2"
  local sha
  sha="$(hash_path "${abs_path}")"

  local filtered_file="${TMP_DIR}/checksums.filtered"
  if [[ -f "${CHECKSUMS_FILE}" ]]; then
    grep -vF "  ${rel_path}" "${CHECKSUMS_FILE}" > "${filtered_file}" || true
    mv "${filtered_file}" "${CHECKSUMS_FILE}"
  fi

  printf '%s  %s\n' "${sha}" "${rel_path}" >> "${CHECKSUMS_FILE}"
  printf '%s\n' "${sha}"
}

append_json_line() {
  local file="$1"
  local line="$2"
  if [[ -s "${file}" ]]; then
    printf ',\n' >> "${file}"
  fi
  printf '%s' "${line}" >> "${file}"
}

read_plist_key() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" 2>/dev/null || true
}

read_manifest_version() {
  local manifest_file="$1"
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${manifest_file}" | head -1
}

escape_ere() {
  printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\/]/\\&/g'
}

manifest_has_artifact_path() {
  local manifest_file="$1"
  local rel_path="$2"
  local escaped_path
  escaped_path="$(escape_ere "${rel_path}")"
  grep -Eq "\"path\"[[:space:]]*:[[:space:]]*\"${escaped_path}\"" "${manifest_file}"
}

validate_release_artifact() {
  local rel_path="$1"
  local description="$2"
  local errors_ref="$3"

  if ! manifest_has_artifact_path "${MANIFEST_FILE}" "${rel_path}"; then
    eval "${errors_ref}+=(\"manifest.json is missing ${description} (${rel_path})\")"
  fi

  if [[ ! -e "${RELEASE_DIR}/${rel_path}" ]]; then
    eval "${errors_ref}+=(\"release dir is missing ${description} (${rel_path})\")"
  fi
}

validate_release_prereqs() {
  local errors=()

  if [[ "${SKIP_MACOS}" -ne 1 ]]; then
    validate_release_artifact "bin/rtmify-license-gen" "macOS operator binary" errors
    validate_release_artifact "bin/rtmify-trace" "macOS trace CLI binary" errors
    validate_release_artifact "bin/rtmify-live" "macOS live CLI binary" errors
    validate_release_artifact "macos/RTMify Trace.app" "RTMify Trace.app bundle" errors
    validate_release_artifact "macos/RTMify Live.app" "RTMify Live.app bundle" errors
  fi

  if [[ "${SKIP_WINDOWS}" -ne 1 ]]; then
    validate_release_artifact "windows/rtmify-trace.exe" "Windows trace binary" errors
    validate_release_artifact "windows/rtmify-live.exe" "Windows live binary" errors
  fi

  if [[ "${SKIP_LINUX}" -ne 1 ]]; then
    validate_release_artifact "linux/rtmify-trace" "Linux trace binary" errors
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    echo "Error: release dir is missing required artifacts from release.sh:" >&2
    local error
    for error in "${errors[@]}"; do
      echo "  ${error}" >&2
    done
    exit 2
  fi
}

product_title() {
  case "$1" in
    trace) echo "Trace" ;;
    live)  echo "Live"  ;;
    *)     echo "$1"    ;;
  esac
}

# ===========================================================================
# macOS
# ===========================================================================

codesign_binary() {
  # codesign_binary <path> [entitlements]
  local bin="$1"
  local entitlements="${2:-}"
  if [[ ! -f "${bin}" ]]; then
    echo "Warning: binary not found, skipping: ${bin}" >&2
    return 0
  fi
  local args=(codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp)
  [[ -n "${entitlements}" ]] && args+=(--entitlements "${entitlements}")
  run_build "${args[@]}" "${bin}"
}

build_pkg() {
  # build_pkg <app_path> <bundle_id> <product> <pkg_name>
  # Produces a signed .pkg at ${MACOS_PKGS_DIR}/<pkg_name>.
  local app_path="$1"
  local bundle_id="$2"
  local product="$3"
  local pkg_name="$4"

  local component_pkg="${TMP_DIR}/${product}-component.pkg"
  local dist_xml="${TMP_DIR}/${product}-distribution.xml"
  local unsigned_pkg="${TMP_DIR}/${product}-unsigned.pkg"
  local signed_pkg="${MACOS_PKGS_DIR}/${pkg_name}"
  local title
  title="RTMify $(product_title "${product}")"

  # Component package — installs .app to /Applications
  run_build pkgbuild \
    --component "${app_path}" \
    --install-location /Applications \
    --identifier "${bundle_id}" \
    --version "${VERSION}" \
    "${component_pkg}"

  # Minimal distribution XML (no welcome/license screens required)
  cat > "${dist_xml}" <<DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>${title}</title>
    <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
    <pkg-ref id="${bundle_id}"/>
    <choices-outline>
        <line choice="default">
            <line choice="${bundle_id}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${bundle_id}" visible="false">
        <pkg-ref id="${bundle_id}"/>
    </choice>
    <pkg-ref id="${bundle_id}" version="${VERSION}" onConclusion="none">$(basename "${component_pkg}")</pkg-ref>
</installer-gui-script>
DISTXML

  # Wrap in a distribution package
  run_build productbuild \
    --distribution "${dist_xml}" \
    --package-path "${TMP_DIR}" \
    "${unsigned_pkg}"

  # Sign with Developer ID Installer
  run_build productsign \
    --sign "${INSTALLER_IDENTITY}" \
    --timestamp \
    "${unsigned_pkg}" \
    "${signed_pkg}"
}

notarize_and_staple() {
  # notarize_and_staple <pkg_path> <pkg_name>
  local pkg_path="$1"
  local pkg_name="$2"
  local notarize_log="${TMP_DIR}/${pkg_name%.pkg}-notarize.json"

  echo "==> macOS: notarizing ${pkg_name}"
  run_build xcrun notarytool submit "${pkg_path}" \
    --key "${NOTARY_KEY_FILE}" \
    --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER}" \
    --wait \
    --output-format json \
    > "${notarize_log}"

  local request_id status
  request_id="$(grep -o '"id":"[^"]*"' "${notarize_log}" | head -1 | sed 's/"id":"\([^"]*\)"/\1/')"
  status="$(grep -o '"status":"[^"]*"' "${notarize_log}" | head -1 | sed 's/"status":"\([^"]*\)"/\1/')"

  if [[ "${status}" != "Accepted" ]]; then
    echo "Error: notarization failed for ${pkg_name} (status=${status}, id=${request_id})" >&2
    cat "${notarize_log}" >&2
    exit 2
  fi

  printf '%s:%s\n' "${pkg_name}" "${request_id}" >> "${MACOS_NOTARY_IDS_FILE}"

  echo "==> macOS: stapling ${pkg_name}"
  run_build xcrun stapler staple "${pkg_path}"
  run_build xcrun stapler validate "${pkg_path}"
}

package_one_macos_product() {
  # package_one_macos_product <product> <app_path> <entitlements>
  local product="$1"
  local app_path="$2"
  local entitlements="$3"

  [[ -d "${app_path}" ]] || { echo "Error: app bundle not found: ${app_path}" >&2; exit 2; }

  local bundle_id
  bundle_id="$(read_plist_key "${app_path}/Contents/Info.plist" "CFBundleIdentifier")"
  if [[ -z "${bundle_id}" ]]; then
    echo "Error: could not read CFBundleIdentifier from ${app_path}/Contents/Info.plist" >&2
    exit 2
  fi

  local pkg_name="RTMify_$(product_title "${product}")_${VERSION}.pkg"

  echo "==> macOS: building ${pkg_name} (bundle id: ${bundle_id})"
  build_pkg "${app_path}" "${bundle_id}" "${product}" "${pkg_name}"
  notarize_and_staple "${MACOS_PKGS_DIR}/${pkg_name}" "${pkg_name}"

  local rel_path="packages/macos/${pkg_name}"
  local sha
  sha="$(record_checksum "${rel_path}" "${MACOS_PKGS_DIR}/${pkg_name}")"
  append_json_line "${MACOS_PKGS_JSONL}" \
    "{\"product\":\"${product}\",\"path\":\"${rel_path}\",\"sha256\":\"${sha}\"}"
}

package_macos() {
  echo "==> macOS: validating credentials"

  local missing=()
  [[ -z "${SIGNING_IDENTITY}" ]]   && missing+=("APPLE_SIGNING_IDENTITY (or --signing-identity)")
  [[ -z "${INSTALLER_IDENTITY}" ]] && missing+=("APPLE_INSTALLER_IDENTITY (or --installer-identity)")
  [[ -z "${NOTARY_KEY_FILE}" ]]    && missing+=("RTMIFY_NOTARY_KEY_FILE (or --notary-key-file)")
  [[ -z "${NOTARY_KEY_ID}" ]]      && missing+=("RTMIFY_NOTARY_KEY_ID (or --notary-key-id)")
  [[ -z "${NOTARY_ISSUER}" ]]      && missing+=("RTMIFY_NOTARY_ISSUER_UUID (or --notary-issuer)")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing macOS signing credentials:" >&2
    for m in "${missing[@]}"; do echo "  ${m}" >&2; done
    exit 2
  fi

  [[ -f "${NOTARY_KEY_FILE}" ]] \
    || { echo "Error: notary key file not found: ${NOTARY_KEY_FILE}" >&2; exit 2; }
  [[ -f "${TRACE_ENTITLEMENTS}" ]] \
    || { echo "Error: missing entitlements file: ${TRACE_ENTITLEMENTS}" >&2; exit 2; }
  [[ -f "${LIVE_ENTITLEMENTS}" ]] \
    || { echo "Error: missing entitlements file: ${LIVE_ENTITLEMENTS}" >&2; exit 2; }

  if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "${SIGNING_IDENTITY}"; then
    echo "Error: signing identity not found in Keychain: ${SIGNING_IDENTITY}" >&2
    echo "Run: security find-identity -v -p codesigning" >&2
    exit 2
  fi

  local bin_dir="${RELEASE_DIR}/bin"
  local trace_app="${RELEASE_DIR}/macos/RTMify Trace.app"
  local live_app="${RELEASE_DIR}/macos/RTMify Live.app"
  local live_embedded="${live_app}/Contents/Resources/rtmify-live"

  # Sign standalone CLI binaries
  echo "==> macOS: signing CLI binaries"
  codesign_binary "${bin_dir}/rtmify-trace"
  codesign_binary "${bin_dir}/rtmify-live"
  codesign_binary "${bin_dir}/rtmify-license-gen"

  # Sign embedded Zig binary before signing the Live.app wrapper
  echo "==> macOS: signing embedded binary in RTMify Live.app"
  codesign_binary "${live_embedded}" "${LIVE_ENTITLEMENTS}"

  # Sign .app bundles
  echo "==> macOS: signing RTMify Trace.app"
  run_build codesign --force --deep --sign "${SIGNING_IDENTITY}" \
    --options runtime --timestamp \
    --entitlements "${TRACE_ENTITLEMENTS}" \
    "${trace_app}"

  echo "==> macOS: signing RTMify Live.app"
  run_build codesign --force --deep --sign "${SIGNING_IDENTITY}" \
    --options runtime --timestamp \
    --entitlements "${LIVE_ENTITLEMENTS}" \
    "${live_app}"

  # Verify
  echo "==> macOS: verifying signatures"
  run_build codesign --verify --deep --strict "${trace_app}"
  run_build codesign --verify --deep --strict "${live_app}"

  mkdir -p "${MACOS_PKGS_DIR}"

  package_one_macos_product "trace" "${trace_app}" "${TRACE_ENTITLEMENTS}"
  package_one_macos_product "live"  "${live_app}"  "${LIVE_ENTITLEMENTS}"
}

# ===========================================================================
# Windows
# ===========================================================================

package_windows() {
  echo "==> Windows: validating credentials"

  if ! dotnet tool list -g 2>/dev/null | grep -qi "azuresigntool"; then
    echo "Error: AzureSignTool is not installed." >&2
    echo "Install it with: dotnet tool install --global AzureSignTool" >&2
    exit 2
  fi

  local missing=()
  [[ -z "${AZURE_TENANT_ID:-}" ]]     && missing+=("AZURE_TENANT_ID")
  [[ -z "${AZURE_CLIENT_ID:-}" ]]     && missing+=("AZURE_CLIENT_ID")
  [[ -z "${AZURE_CLIENT_SECRET:-}" ]] && missing+=("AZURE_CLIENT_SECRET")
  [[ -z "${AZURE_ENDPOINT}" ]]        && missing+=("AZURE_TRUSTED_SIGNING_ENDPOINT (or --azure-endpoint)")
  [[ -z "${AZURE_ACCOUNT}" ]]         && missing+=("AZURE_TRUSTED_SIGNING_ACCOUNT (or --azure-account)")
  [[ -z "${AZURE_PROFILE}" ]]         && missing+=("AZURE_TRUSTED_SIGNING_PROFILE (or --azure-profile)")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing Windows signing credentials:" >&2
    for m in "${missing[@]}"; do echo "  ${m}" >&2; done
    exit 2
  fi

  local win_dir="${RELEASE_DIR}/windows"
  local exes=()
  for exe in "${win_dir}/rtmify-trace.exe" "${win_dir}/rtmify-live.exe"; do
    if [[ -f "${exe}" ]]; then
      exes+=("${exe}")
    else
      echo "Warning: Windows binary not found, skipping: ${exe}" >&2
    fi
  done
  [[ ${#exes[@]} -gt 0 ]] || { echo "Error: no Windows binaries found in ${win_dir}" >&2; exit 2; }

  echo "==> Windows: signing executables"
  run_build AzureSignTool sign \
    --azure-key-vault-url "${AZURE_ENDPOINT}" \
    --azure-key-vault-tenant-id "${AZURE_TENANT_ID}" \
    --azure-key-vault-client-id "${AZURE_CLIENT_ID}" \
    --azure-key-vault-client-secret "${AZURE_CLIENT_SECRET}" \
    --trusted-signing-account "${AZURE_ACCOUNT}" \
    --trusted-signing-certificate-profile "${AZURE_PROFILE}" \
    --timestamp-rfc3161 "http://timestamp.acs.microsoft.com" \
    --timestamp-digest sha256 \
    --file-digest sha256 \
    "${exes[@]}"

  for exe in "${exes[@]}"; do
    local rel_path="windows/$(basename "${exe}")"
    record_checksum "${rel_path}" "${exe}" >/dev/null
    printf '%s\n' "${rel_path}" >> "${WINDOWS_SIGNED_FILE}"
  done
}

# ===========================================================================
# Linux
# ===========================================================================

package_linux() {
  echo "==> Linux: creating tarballs"
  mkdir -p "${LINUX_PKGS_DIR}"

  local linux_dir="${RELEASE_DIR}/linux"
  if [[ ! -d "${linux_dir}" ]]; then
    echo "Warning: no linux/ dir in release dir, skipping Linux packaging." >&2
    return 0
  fi

  local found=0
  for binary in "${linux_dir}"/rtmify-*; do
    [[ -f "${binary}" ]] || continue
    found=1

    local bin_name
    bin_name="$(basename "${binary}")"
    local tarball_name="${bin_name}-linux-x64-${VERSION}.tar.gz"
    local tarball_path="${LINUX_PKGS_DIR}/${tarball_name}"
    local rel_path="packages/linux/${tarball_name}"

    run_build tar czf "${tarball_path}" -C "${linux_dir}" "${bin_name}"

    if [[ -n "${GPG_KEY}" ]]; then
      echo "==> Linux: GPG signing ${tarball_name}"
      run_build gpg --batch --yes --detach-sign --armor \
        --local-user "${GPG_KEY}" "${tarball_path}"
    fi

    local sha
    sha="$(record_checksum "${rel_path}" "${tarball_path}")"

    local product="${bin_name#rtmify-}"
    append_json_line "${LINUX_PKGS_JSONL}" \
      "{\"product\":\"${product}\",\"path\":\"${rel_path}\",\"sha256\":\"${sha}\"}"
  done

  [[ "${found}" -eq 1 ]] || echo "Warning: no binaries found in ${linux_dir}" >&2
}

# ===========================================================================
# Assemble package-manifest.json
# ===========================================================================

write_package_manifest() {
  {
    printf '{\n'
    printf '  "version": "%s",\n' "${VERSION}"
    printf '  "packaged_at": %s' "$(date +%s)"

    if [[ "${SKIP_MACOS}" -ne 1 ]]; then
      # Build notarization_ids object from accumulator lines "pkg_name:uuid"
      local notary_ids=""
      while IFS=: read -r pkg_name uuid; do
        [[ -n "${pkg_name}" ]] || continue
        if [[ -n "${notary_ids}" ]]; then notary_ids+=","; fi
        notary_ids+="\"${pkg_name}\":\"${uuid}\""
      done < "${MACOS_NOTARY_IDS_FILE}"

      printf ',\n  "macos": {\n'
      printf '    "signing_identity": "%s",\n' "${SIGNING_IDENTITY}"
      printf '    "notarization_ids": {%s},\n' "${notary_ids}"
      printf '    "packages": ['
      [[ -s "${MACOS_PKGS_JSONL}" ]] && cat "${MACOS_PKGS_JSONL}"
      printf ']\n  }'
    fi

    if [[ "${SKIP_WINDOWS}" -ne 1 ]]; then
      printf ',\n  "windows": {\n'
      printf '    "signed": ['
      local first=1
      while IFS= read -r rel_path; do
        [[ -n "${rel_path}" ]] || continue
        [[ "${first}" -eq 1 ]] || printf ','
        printf '"%s"' "${rel_path}"
        first=0
      done < "${WINDOWS_SIGNED_FILE}"
      printf ']\n  }'
    fi

    if [[ "${SKIP_LINUX}" -ne 1 ]]; then
      printf ',\n  "linux": {\n'
      printf '    "packages": ['
      [[ -s "${LINUX_PKGS_JSONL}" ]] && cat "${LINUX_PKGS_JSONL}"
      printf ']\n  }'
    fi

    printf '\n}\n'
  } > "${PKG_MANIFEST}"
}

# ===========================================================================
# Main — arg parsing, setup, execution
# ===========================================================================

main() {

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-dir)        RELEASE_DIR="${2:?missing value for --release-dir}"; shift 2 ;;
    --skip-macos)         SKIP_MACOS=1; shift ;;
    --skip-windows)       SKIP_WINDOWS=1; shift ;;
    --skip-linux)         SKIP_LINUX=1; shift ;;
    --signing-identity)   SIGNING_IDENTITY="${2:?}"; shift 2 ;;
    --installer-identity) INSTALLER_IDENTITY="${2:?}"; shift 2 ;;
    --notary-key-file)    NOTARY_KEY_FILE="${2:?}"; shift 2 ;;
    --notary-key-id)      NOTARY_KEY_ID="${2:?}"; shift 2 ;;
    --notary-issuer)      NOTARY_ISSUER="${2:?}"; shift 2 ;;
    --azure-endpoint)     AZURE_ENDPOINT="${2:?}"; shift 2 ;;
    --azure-account)      AZURE_ACCOUNT="${2:?}"; shift 2 ;;
    --azure-profile)      AZURE_PROFILE="${2:?}"; shift 2 ;;
    --gpg-key)            GPG_KEY="${2:?}"; shift 2 ;;
    --help|-h)            usage; exit 0 ;;
    *)                    echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate release dir and resolve version
# ---------------------------------------------------------------------------

if [[ -z "${RELEASE_DIR}" ]]; then
  echo "Error: --release-dir is required." >&2
  usage >&2
  exit 2
fi

[[ -d "${RELEASE_DIR}" ]] || { echo "Error: release dir not found: ${RELEASE_DIR}" >&2; exit 2; }
RELEASE_DIR="$(cd "${RELEASE_DIR}" && pwd)"
MANIFEST_FILE="${RELEASE_DIR}/manifest.json"
[[ -f "${MANIFEST_FILE}" ]] || { echo "Error: manifest.json not found — is this a valid release dir?" >&2; exit 2; }

VERSION="$(read_manifest_version "${MANIFEST_FILE}")"
if [[ -z "${VERSION}" ]] || ! is_valid_release_version "${VERSION}"; then
  echo "Error: could not determine valid version from ${MANIFEST_FILE}" >&2
  exit 2
fi

validate_release_prereqs

# ---------------------------------------------------------------------------
# Output paths
# ---------------------------------------------------------------------------

PACKAGES_DIR="${RELEASE_DIR}/packages"
MACOS_PKGS_DIR="${PACKAGES_DIR}/macos"
LINUX_PKGS_DIR="${PACKAGES_DIR}/linux"
CHECKSUMS_FILE="${RELEASE_DIR}/checksums.txt"
PKG_MANIFEST="${RELEASE_DIR}/package-manifest.json"

mkdir -p "${PACKAGES_DIR}"

# ---------------------------------------------------------------------------
# Temp dir + cleanup
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtmify-package.XXXXXX")"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

# Accumulator files for package-manifest.json assembly
MACOS_NOTARY_IDS_FILE="${TMP_DIR}/macos-notary-ids.txt"  # lines: "pkg_name:uuid"
MACOS_PKGS_JSONL="${TMP_DIR}/macos-pkgs.jsonl"
WINDOWS_SIGNED_FILE="${TMP_DIR}/windows-signed.txt"       # lines: rel_path
LINUX_PKGS_JSONL="${TMP_DIR}/linux-pkgs.jsonl"
touch "${MACOS_NOTARY_IDS_FILE}" "${MACOS_PKGS_JSONL}" \
      "${WINDOWS_SIGNED_FILE}" "${LINUX_PKGS_JSONL}"



# ===========================================================================
# Main
# ===========================================================================

echo "RTMify package.sh — version ${VERSION}"
echo "Release dir: ${RELEASE_DIR}"

[[ "${SKIP_MACOS}" -ne 1 ]]   && package_macos
[[ "${SKIP_WINDOWS}" -ne 1 ]] && package_windows
[[ "${SKIP_LINUX}" -ne 1 ]]   && package_linux

write_package_manifest

echo "Package artifacts written to ${PACKAGES_DIR}"
echo "Package manifest: ${PKG_MANIFEST}"

} # end main()

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
