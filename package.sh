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
ONLY_MACOS=0
ONLY_WINDOWS=0
ONLY_LINUX=0
WINDOWS_UNSIGNED_DIR=""

# macOS signing credentials
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
NOTARY_KEY_FILE="${RTMIFY_NOTARY_KEY_FILE:-}"
NOTARY_KEY_ID="${RTMIFY_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${RTMIFY_NOTARY_ISSUER_UUID:-}"

# Windows signing
AZURE_ENDPOINT="${AZURE_TRUSTED_SIGNING_ENDPOINT:-}"
AZURE_ACCOUNT="${AZURE_TRUSTED_SIGNING_ACCOUNT:-}"
AZURE_PROFILE="${AZURE_TRUSTED_SIGNING_PROFILE:-}"
AZURE_ACCESS_TOKEN="${AZURE_ACCESS_TOKEN:-}"
JSIGN_BIN="${JSIGN_BIN:-}"
JSIGN_JAR="${JSIGN_JAR:-}"

# Linux signing credentials (optional)
GPG_KEY="${GPG_SIGNING_KEY_ID:-}"

# ---------------------------------------------------------------------------
# Static paths and IDs
# ---------------------------------------------------------------------------

TRACE_ENTITLEMENTS="${ROOT_DIR}/trace/macos/RTMify Trace/RTMify Trace.entitlements"
LIVE_ENTITLEMENTS="${ROOT_DIR}/live/macos/RTMify Live/RTMify Live.entitlements"

WINDOWS_TRACE_APP_ID="{{2FA112AB-513E-4CA5-86B1-711FE8C2EBC2}"
WINDOWS_LIVE_APP_ID="{{8F637197-D3C8-4C0E-A62A-EB682EC82F6E}"
WINDOWS_PUBLISHER="Iron Brothers Ventures LLC"
WINDOWS_PUBLISHER_URL="https://rtmify.io"
AZURE_SIGNING_RESOURCE="https://codesigning.azure.net"

WINDOWS_PAYLOAD_ZIP_NAME_TEMPLATE="RTMify_Windows_Payloads_%s.zip"
WINDOWS_TRACE_UNSIGNED_TEMPLATE="RTMify_Trace_Installer_%s_unsigned.exe"
WINDOWS_LIVE_UNSIGNED_TEMPLATE="RTMify_Live_Installer_%s_unsigned.exe"
WINDOWS_TRACE_FINAL_TEMPLATE="RTMify_Trace_Installer_%s.exe"
WINDOWS_LIVE_FINAL_TEMPLATE="RTMify_Live_Installer_%s.exe"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
./package.sh --release-dir <path> [options]

  --release-dir PATH            completed release dir from release.sh (required)
  --macos                       package macOS only (combine with --linux, --windows)
  --windows                     package Windows only (combine with --macos, --linux)
  --linux                       package Linux only (combine with --macos, --windows)
                                (default: all platforms when none specified)
  --skip-macos                  skip macOS signing and packaging
  --skip-windows                skip Windows signing and packaging
  --skip-linux                  skip Linux tarball creation
  --windows-unsigned-dir PATH   directory containing unsigned Windows installers
                                from the GitHub Actions packaging workflow;
                                when set, package.sh signs those installers
                                locally and skips macOS/Linux packaging

macOS credentials:
  --signing-identity STR        Developer ID Application identity
                                (or APPLE_SIGNING_IDENTITY)
  --notary-key-file PATH        path to .p8 notarytool API key
                                (or RTMIFY_NOTARY_KEY_FILE)
  --notary-key-id STR           10-char notarytool key ID
                                (or RTMIFY_NOTARY_KEY_ID)
  --notary-issuer UUID          notarytool issuer UUID
                                (or RTMIFY_NOTARY_ISSUER_UUID)

Windows signing:
  --azure-endpoint URL          Azure Trusted Signing endpoint URI
                                (or AZURE_TRUSTED_SIGNING_ENDPOINT)
  --azure-account STR           Azure Trusted Signing account name
                                (or AZURE_TRUSTED_SIGNING_ACCOUNT)
  --azure-profile STR           Azure Trusted Signing certificate profile
                                (or AZURE_TRUSTED_SIGNING_PROFILE)
  --jsign-bin PATH              jsign executable path (or JSIGN_BIN)
  --jsign-jar PATH              jsign jar path, used when no jsign executable is
                                available (or JSIGN_JAR)
  AZURE_ACCESS_TOKEN            optional bearer token for Azure Trusted Signing
                                If omitted, package.sh runs:
                                  az account get-access-token \
                                    --resource https://codesigning.azure.net

Linux credentials:
  --gpg-key STR                 GPG key ID for tarball signing; optional
                                (or GPG_SIGNING_KEY_ID)
EOF
}

# ---------------------------------------------------------------------------
# Shared helpers
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
    validate_release_artifact "windows/RTMify Live.exe" "Windows live shell binary" errors
    validate_release_artifact "windows/rtmify-live.exe" "Windows live server binary" errors
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
    live)  echo "Live" ;;
    *)     echo "$1" ;;
  esac
}

json_quote() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

load_previous_package_manifest_state() {
  PREVIOUS_HAS_MACOS=0
  PREVIOUS_HAS_WINDOWS=0
  PREVIOUS_HAS_LINUX=0
  PREVIOUS_MACOS_SIGNING_IDENTITY=""
  PREVIOUS_MACOS_NOTARIZATION_IDS_JSON="{}"

  if [[ ! -f "${PKG_MANIFEST}" ]]; then
    return 0
  fi

  eval "$(
    python3 - "${PKG_MANIFEST}" <<'PY'
import json
import shlex
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"PREVIOUS_HAS_MACOS={1 if 'macos' in data else 0}")
print(f"PREVIOUS_HAS_WINDOWS={1 if 'windows' in data else 0}")
print(f"PREVIOUS_HAS_LINUX={1 if 'linux' in data else 0}")
print("PREVIOUS_MACOS_SIGNING_IDENTITY=" + shlex.quote(data.get("macos", {}).get("signing_identity", "")))
print(
    "PREVIOUS_MACOS_NOTARIZATION_IDS_JSON="
    + shlex.quote(json.dumps(data.get("macos", {}).get("notarization_ids", {}), separators=(",", ":")))
)
PY
  )"
}

resolve_jsign_cmd() {
  if [[ -n "${JSIGN_BIN}" ]]; then
    if [[ ! -x "${JSIGN_BIN}" ]] && ! command -v "${JSIGN_BIN}" >/dev/null 2>&1; then
      echo "Error: jsign executable not found: ${JSIGN_BIN}" >&2
      exit 2
    fi
    JSIGN_CMD=("${JSIGN_BIN}")
    return 0
  fi

  if command -v jsign >/dev/null 2>&1; then
    JSIGN_CMD=("jsign")
    return 0
  fi

  if [[ -n "${JSIGN_JAR}" ]]; then
    if [[ ! -f "${JSIGN_JAR}" ]]; then
      echo "Error: jsign jar not found: ${JSIGN_JAR}" >&2
      exit 2
    fi
    if ! command -v java >/dev/null 2>&1; then
      echo "Error: java is required to run jsign from ${JSIGN_JAR}" >&2
      exit 2
    fi
    JSIGN_CMD=("java" "-jar" "${JSIGN_JAR}")
    return 0
  fi

  echo "Error: jsign is not available." >&2
  echo "Install jsign or pass --jsign-bin/--jsign-jar." >&2
  exit 2
}

resolve_azure_access_token() {
  if [[ -n "${AZURE_ACCESS_TOKEN}" ]]; then
    printf '%s' "${AZURE_ACCESS_TOKEN}"
    return 0
  fi

  if ! command -v az >/dev/null 2>&1; then
    echo "Error: az CLI is required to acquire an Azure Trusted Signing access token." >&2
    echo "Either run 'az login' and install the CLI, or set AZURE_ACCESS_TOKEN." >&2
    exit 2
  fi

  local token
  token="$(az account get-access-token --resource "${AZURE_SIGNING_RESOURCE}" --query accessToken -o tsv)"
  if [[ -z "${token}" ]]; then
    echo "Error: failed to acquire Azure Trusted Signing access token via az CLI." >&2
    exit 2
  fi
  printf '%s' "${token}"
}

sign_with_jsign() {
  local access_token="$1"
  shift
  run_build "${JSIGN_CMD[@]}" \
    --storetype TRUSTEDSIGNING \
    --keystore "${AZURE_ENDPOINT}" \
    --storepass "${access_token}" \
    --alias "${AZURE_ACCOUNT}/${AZURE_PROFILE}" \
    "$@"
}

preflight_azure_signing() {
  echo "==> Windows: pre-flight checks"

  # 1. Required env/flags
  local missing=()
  [[ -z "${AZURE_ENDPOINT}" ]] && missing+=("AZURE_TRUSTED_SIGNING_ENDPOINT (or --azure-endpoint)")
  [[ -z "${AZURE_ACCOUNT}" ]]  && missing+=("AZURE_TRUSTED_SIGNING_ACCOUNT (or --azure-account)")
  [[ -z "${AZURE_PROFILE}" ]]  && missing+=("AZURE_TRUSTED_SIGNING_PROFILE (or --azure-profile)")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing Windows signing credentials:" >&2
    local m
    for m in "${missing[@]}"; do
      echo "  ${m}" >&2
    done
    exit 2
  fi

  # Strip trailing slashes — jsign appends /codesigningaccounts/… directly
  AZURE_ENDPOINT="${AZURE_ENDPOINT%/}"

  # 2. jsign
  resolve_jsign_cmd

  # 3. If AZURE_ACCESS_TOKEN is set, skip az CLI probes — caller owns auth
  if [[ -n "${AZURE_ACCESS_TOKEN}" ]]; then
    WINDOWS_ACCESS_TOKEN="${AZURE_ACCESS_TOKEN}"
    echo "==> Windows: pre-flight OK (using explicit AZURE_ACCESS_TOKEN)"
    return 0
  fi

  # 4. az CLI
  if ! command -v az >/dev/null 2>&1; then
    echo "Error: az CLI is required to acquire an Azure Trusted Signing access token." >&2
    echo "  Install it (https://aka.ms/installazureclimacos) or set AZURE_ACCESS_TOKEN." >&2
    exit 2
  fi

  # 5. Logged-in session
  if ! az account show >/dev/null 2>&1; then
    echo "Error: az CLI is not logged in." >&2
    echo "  Fix: az login" >&2
    exit 2
  fi

  # 6. trustedsigning extension
  if ! az trustedsigning --help >/dev/null 2>&1; then
    echo "Error: az CLI 'trustedsigning' extension is not installed." >&2
    echo "  Fix: az extension add --name trustedsigning" >&2
    exit 2
  fi

  # 7. Certificate profile exists and is Active
  local profile_json
  profile_json="$(az trustedsigning certificate-profile show \
    --account-name "${AZURE_ACCOUNT}" \
    --profile-name "${AZURE_PROFILE}" \
    --resource-group "${AZURE_ACCOUNT}" \
    -o json 2>/dev/null)" || true

  if [[ -z "${profile_json}" ]]; then
    echo "Error: certificate profile '${AZURE_PROFILE}' not found in account '${AZURE_ACCOUNT}'." >&2
    echo "  List profiles: az trustedsigning certificate-profile list --account-name ${AZURE_ACCOUNT} --resource-group ${AZURE_ACCOUNT}" >&2
    exit 2
  fi

  local profile_status
  profile_status="$(printf '%s' "${profile_json}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))")"
  if [[ "${profile_status}" != "Active" ]]; then
    echo "Error: certificate profile '${AZURE_PROFILE}' status is '${profile_status}', expected 'Active'." >&2
    exit 2
  fi

  # 8. RBAC — check for Artifact Signing Certificate Profile Signer role
  #    Use object ID (not UPN) — personal Microsoft accounts don't resolve by email
  local signer_role="Artifact Signing Certificate Profile Signer"
  local sub_id scope user_oid user_display
  sub_id="$(az account show --query id -o tsv)"
  scope="/subscriptions/${sub_id}/resourceGroups/${AZURE_ACCOUNT}/providers/Microsoft.CodeSigning/codeSigningAccounts/${AZURE_ACCOUNT}"
  user_oid="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)" || true
  user_display="$(az account show --query user.name -o tsv 2>/dev/null)"

  if [[ -n "${user_oid}" ]]; then
    local role_count
    role_count="$(az role assignment list \
      --assignee "${user_oid}" \
      --scope "${scope}" \
      --role "${signer_role}" \
      --query "length(@)" \
      -o tsv 2>/dev/null)" || true

    if [[ "${role_count}" == "0" || -z "${role_count}" ]]; then
      echo "Error: '${user_display}' lacks the '${signer_role}' role on the signing account." >&2
      echo "  Fix: az role assignment create --assignee-object-id ${user_oid} --assignee-principal-type User --role \"${signer_role}\" --scope ${scope}" >&2
      exit 2
    fi
  fi

  # 9. Access token
  WINDOWS_ACCESS_TOKEN="$(resolve_azure_access_token)"
  echo "==> Windows: pre-flight OK"
}

ensure_windows_signing_ready() {
  preflight_azure_signing
}

windows_payload_zip_name() {
  printf "${WINDOWS_PAYLOAD_ZIP_NAME_TEMPLATE}" "${VERSION}"
}

windows_trace_unsigned_name() {
  printf "${WINDOWS_TRACE_UNSIGNED_TEMPLATE}" "${VERSION}"
}

windows_live_unsigned_name() {
  printf "${WINDOWS_LIVE_UNSIGNED_TEMPLATE}" "${VERSION}"
}

windows_trace_final_name() {
  printf "${WINDOWS_TRACE_FINAL_TEMPLATE}" "${VERSION}"
}

windows_live_final_name() {
  printf "${WINDOWS_LIVE_FINAL_TEMPLATE}" "${VERSION}"
}

write_windows_payload_input_manifest() {
  local path="$1"
  cat > "${path}" <<EOF
{
  "version": "${VERSION}",
  "unsigned_installers": [
    "$(windows_trace_unsigned_name)",
    "$(windows_live_unsigned_name)"
  ],
  "final_installers": [
    "$(windows_trace_final_name)",
    "$(windows_live_final_name)"
  ]
}
EOF
}

create_deterministic_zip() {
  local source_dir="$1"
  local output_path="$2"

  python3 - "${source_dir}" "${output_path}" <<'PY'
import os
import stat
import sys
import zipfile
from pathlib import Path

source_dir = Path(sys.argv[1])
output_path = Path(sys.argv[2])

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
PY
}

reset_windows_package_outputs() {
  mkdir -p "${WINDOWS_PKGS_DIR}"
  rm -f \
    "${WINDOWS_PKGS_DIR}/$(windows_payload_zip_name)" \
    "${WINDOWS_PKGS_DIR}/$(windows_trace_final_name)" \
    "${WINDOWS_PKGS_DIR}/$(windows_live_final_name)" \
    "${WINDOWS_PKGS_DIR}/$(windows_trace_unsigned_name)" \
    "${WINDOWS_PKGS_DIR}/$(windows_live_unsigned_name)"
}

stage_windows_payloads() {
  echo "==> Windows: signing payload binaries for CI packaging"
  ensure_windows_signing_ready
  reset_windows_package_outputs

  local trace_exe="${RELEASE_DIR}/windows/rtmify-trace.exe"
  local live_shell="${RELEASE_DIR}/windows/RTMify Live.exe"
  local live_server="${RELEASE_DIR}/windows/rtmify-live.exe"

  sign_with_jsign "${WINDOWS_ACCESS_TOKEN}" "${trace_exe}" "${live_shell}" "${live_server}"

  local payload_dir="${TMP_DIR}/windows-payloads"
  mkdir -p "${payload_dir}"
  cp "${trace_exe}" "${payload_dir}/rtmify-trace.exe"
  cp "${live_shell}" "${payload_dir}/RTMify Live.exe"
  cp "${live_server}" "${payload_dir}/rtmify-live.exe"
  write_windows_payload_input_manifest "${payload_dir}/windows-installer-input.json"

  create_deterministic_zip "${payload_dir}" "${WINDOWS_PKGS_DIR}/$(windows_payload_zip_name)"
  WINDOWS_PACKAGE_MODE="stage"
}

validate_windows_unsigned_dir() {
  local unsigned_dir="$1"
  [[ -d "${unsigned_dir}" ]] || { echo "Error: unsigned Windows installer dir not found: ${unsigned_dir}" >&2; exit 2; }

  local expected_trace expected_live
  expected_trace="$(windows_trace_unsigned_name)"
  expected_live="$(windows_live_unsigned_name)"
  [[ -f "${unsigned_dir}/${expected_trace}" ]] || { echo "Error: missing unsigned Windows installer: ${expected_trace}" >&2; exit 2; }
  [[ -f "${unsigned_dir}/${expected_live}" ]] || { echo "Error: missing unsigned Windows installer: ${expected_live}" >&2; exit 2; }

  local unexpected=0
  local file
  while IFS= read -r file; do
    case "$(basename "${file}")" in
      "${expected_trace}"|"${expected_live}") ;;
      *)
        echo "Error: unexpected unsigned Windows installer file: $(basename "${file}")" >&2
        unexpected=1
        ;;
    esac
  done < <(find "${unsigned_dir}" -maxdepth 1 -type f -name '*.exe' | sort)

  [[ "${unexpected}" -eq 0 ]] || exit 2
}

finalize_windows_installers() {
  echo "==> Windows: signing final installers from CI output"
  ensure_windows_signing_ready

  local payload_zip="${WINDOWS_PKGS_DIR}/$(windows_payload_zip_name)"
  [[ -f "${payload_zip}" ]] || {
    echo "Error: payload zip not found: ${payload_zip}" >&2
    echo "Run package.sh once without --windows-unsigned-dir before finalizing Windows installers." >&2
    exit 2
  }

  validate_windows_unsigned_dir "${WINDOWS_UNSIGNED_DIR}"
  mkdir -p "${WINDOWS_PKGS_DIR}"
  rm -f "${WINDOWS_PKGS_DIR}/$(windows_trace_final_name)" "${WINDOWS_PKGS_DIR}/$(windows_live_final_name)"

  local trace_src="${WINDOWS_UNSIGNED_DIR}/$(windows_trace_unsigned_name)"
  local live_src="${WINDOWS_UNSIGNED_DIR}/$(windows_live_unsigned_name)"
  local trace_dest="${WINDOWS_PKGS_DIR}/$(windows_trace_final_name)"
  local live_dest="${WINDOWS_PKGS_DIR}/$(windows_live_final_name)"

  cp "${trace_src}" "${trace_dest}"
  cp "${live_src}" "${live_dest}"

  sign_with_jsign "${WINDOWS_ACCESS_TOKEN}" "${trace_dest}" "${live_dest}"
  WINDOWS_PACKAGE_MODE="finalize"
}

# ===========================================================================
# macOS
# ===========================================================================

codesign_binary() {
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

create_signed_dmg() {
  local product="$1"
  local app_path="$2"
  local dmg_name="$3"
  local volume_name="RTMify $(product_title "${product}")"
  local staging_dir="${TMP_DIR}/dmg-${product}"
  local dmg_path="${MACOS_PKGS_DIR}/${dmg_name}"

  rm -rf "${staging_dir}"
  mkdir -p "${staging_dir}"
  cp -R "${app_path}" "${staging_dir}/"
  ln -s /Applications "${staging_dir}/Applications"

  run_build hdiutil create \
    -fs HFS+ \
    -format UDZO \
    -volname "${volume_name}" \
    -srcfolder "${staging_dir}" \
    "${dmg_path}"

  run_build codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${dmg_path}"
  run_build codesign --verify --verbose "${dmg_path}"
}

notarize_and_staple() {
  local artifact_path="$1"
  local artifact_name="$2"
  local notarize_log="${TMP_DIR}/${artifact_name}.notarize.json"

  echo "==> macOS: notarizing ${artifact_name}"
  run_build xcrun notarytool submit "${artifact_path}" \
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
    echo "Error: notarization failed for ${artifact_name} (status=${status}, id=${request_id})" >&2
    cat "${notarize_log}" >&2
    exit 2
  fi

  printf '%s:%s\n' "${artifact_name}" "${request_id}" >> "${MACOS_NOTARY_IDS_FILE}"

  echo "==> macOS: stapling ${artifact_name}"
  run_build xcrun stapler staple "${artifact_path}"
  run_build xcrun stapler validate "${artifact_path}"
}

package_one_macos_product() {
  local product="$1"
  local app_path="$2"

  [[ -d "${app_path}" ]] || { echo "Error: app bundle not found: ${app_path}" >&2; exit 2; }

  local bundle_id
  bundle_id="$(read_plist_key "${app_path}/Contents/Info.plist" "CFBundleIdentifier")"
  if [[ -z "${bundle_id}" ]]; then
    echo "Error: could not read CFBundleIdentifier from ${app_path}/Contents/Info.plist" >&2
    exit 2
  fi

  local dmg_name="RTMify_$(product_title "${product}")_${VERSION}.dmg"
  echo "==> macOS: building ${dmg_name} (bundle id: ${bundle_id})"
  create_signed_dmg "${product}" "${app_path}" "${dmg_name}"
  notarize_and_staple "${MACOS_PKGS_DIR}/${dmg_name}" "${dmg_name}"
}

package_macos() {
  echo "==> macOS: pre-flight checks"

  # 1. Required tools
  local missing_tools=()
  command -v codesign >/dev/null 2>&1  || missing_tools+=("codesign")
  command -v hdiutil >/dev/null 2>&1   || missing_tools+=("hdiutil")
  command -v xcrun >/dev/null 2>&1     || missing_tools+=("xcrun")
  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "Error: missing required macOS tools: ${missing_tools[*]}" >&2
    echo "  Fix: xcode-select --install" >&2
    exit 2
  fi

  # 2. Required credentials
  local missing=()
  [[ -z "${SIGNING_IDENTITY}" ]] && missing+=("APPLE_SIGNING_IDENTITY (or --signing-identity)")
  [[ -z "${NOTARY_KEY_FILE}" ]]  && missing+=("RTMIFY_NOTARY_KEY_FILE (or --notary-key-file)")
  [[ -z "${NOTARY_KEY_ID}" ]]    && missing+=("RTMIFY_NOTARY_KEY_ID (or --notary-key-id)")
  [[ -z "${NOTARY_ISSUER}" ]]    && missing+=("RTMIFY_NOTARY_ISSUER_UUID (or --notary-issuer)")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing macOS signing credentials:" >&2
    local m
    for m in "${missing[@]}"; do
      echo "  ${m}" >&2
    done
    exit 2
  fi

  # 3. Files exist
  [[ -f "${NOTARY_KEY_FILE}" ]] || { echo "Error: notary key file not found: ${NOTARY_KEY_FILE}" >&2; exit 2; }
  [[ -f "${TRACE_ENTITLEMENTS}" ]] || { echo "Error: missing entitlements file: ${TRACE_ENTITLEMENTS}" >&2; exit 2; }
  [[ -f "${LIVE_ENTITLEMENTS}" ]] || { echo "Error: missing entitlements file: ${LIVE_ENTITLEMENTS}" >&2; exit 2; }

  # 4. Signing identity in Keychain
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "${SIGNING_IDENTITY}"; then
    echo "Error: signing identity not found in Keychain: ${SIGNING_IDENTITY}" >&2
    echo "  Available identities:" >&2
    security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' >&2
    exit 2
  fi

  # 5. notarytool can authenticate
  if ! xcrun notarytool history \
    --key "${NOTARY_KEY_FILE}" \
    --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER}" \
    --page-size 1 >/dev/null 2>&1; then
    echo "Error: notarytool authentication failed." >&2
    echo "  Check that RTMIFY_NOTARY_KEY_FILE, RTMIFY_NOTARY_KEY_ID, and RTMIFY_NOTARY_ISSUER_UUID are correct." >&2
    exit 2
  fi

  echo "==> macOS: pre-flight OK"

  local bin_dir="${RELEASE_DIR}/bin"
  local trace_app="${RELEASE_DIR}/macos/RTMify Trace.app"
  local live_app="${RELEASE_DIR}/macos/RTMify Live.app"
  local live_embedded="${live_app}/Contents/Resources/rtmify-live"

  mkdir -p "${MACOS_PKGS_DIR}"
  rm -f "${MACOS_PKGS_DIR}/RTMify_Trace_${VERSION}.dmg" "${MACOS_PKGS_DIR}/RTMify_Live_${VERSION}.dmg"

  echo "==> macOS: signing CLI binaries"
  codesign_binary "${bin_dir}/rtmify-trace"
  codesign_binary "${bin_dir}/rtmify-live"
  codesign_binary "${bin_dir}/rtmify-license-gen"

  echo "==> macOS: signing embedded binary in RTMify Live.app"
  codesign_binary "${live_embedded}" "${LIVE_ENTITLEMENTS}"

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

  echo "==> macOS: verifying signatures"
  run_build codesign --verify --deep --strict "${trace_app}"
  run_build codesign --verify --deep --strict "${live_app}"

  package_one_macos_product "trace" "${trace_app}"
  package_one_macos_product "live" "${live_app}"
  MACOS_PACKAGED_THIS_RUN=1
}

# ===========================================================================
# Linux
# ===========================================================================

package_linux() {
  echo "==> Linux: pre-flight checks"
  command -v tar >/dev/null 2>&1 || { echo "Error: tar is required." >&2; exit 2; }
  if [[ -n "${GPG_KEY}" ]]; then
    command -v gpg >/dev/null 2>&1 || { echo "Error: gpg is required for tarball signing." >&2; echo "  Fix: brew install gnupg" >&2; exit 2; }
    if ! gpg --batch --list-keys "${GPG_KEY}" >/dev/null 2>&1; then
      echo "Error: GPG key '${GPG_KEY}' not found in keyring." >&2
      echo "  Fix: gpg --list-keys" >&2
      exit 2
    fi
  fi
  echo "==> Linux: pre-flight OK"

  echo "==> Linux: creating tarballs"
  mkdir -p "${LINUX_PKGS_DIR}"

  local linux_dir="${RELEASE_DIR}/linux"
  if [[ ! -d "${linux_dir}" ]]; then
    echo "Warning: no linux/ dir in release dir, skipping Linux packaging." >&2
    return 0
  fi

  rm -f "${LINUX_PKGS_DIR}"/*"-linux-x64-${VERSION}.tar.gz"

  local found=0
  local binary
  for binary in "${linux_dir}"/rtmify-*; do
    [[ -f "${binary}" ]] || continue
    found=1

    local bin_name
    bin_name="$(basename "${binary}")"
    local tarball_name="${bin_name}-linux-x64-${VERSION}.tar.gz"
    local tarball_path="${LINUX_PKGS_DIR}/${tarball_name}"

    run_build tar czf "${tarball_path}" -C "${linux_dir}" "${bin_name}"

    if [[ -n "${GPG_KEY}" ]]; then
      echo "==> Linux: GPG signing ${tarball_name}"
      run_build gpg --batch --yes --detach-sign --armor \
        --local-user "${GPG_KEY}" "${tarball_path}"
    fi
  done

  [[ "${found}" -eq 1 ]] || echo "Warning: no binaries found in ${linux_dir}" >&2
  LINUX_PACKAGED_THIS_RUN=1
}

# ===========================================================================
# Manifest + checksums from disk
# ===========================================================================

checksum_append() {
  local rel_path="$1"
  local abs_path="$2"
  printf '%s  %s\n' "$(hash_path "${abs_path}")" "${rel_path}" >> "${CHECKSUMS_FILE}"
}

collect_validation_checksums() {
  while IFS= read -r rel_path; do
    [[ -n "${rel_path}" ]] || continue
    [[ -f "${RELEASE_DIR}/${rel_path}" ]] || continue
    checksum_append "${rel_path}" "${RELEASE_DIR}/${rel_path}"
  done < <(
    python3 - "${MANIFEST_FILE}" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for artifact in data.get("artifacts", []):
    rel_path = artifact.get("path")
    if isinstance(rel_path, str) and rel_path.startswith("validation/"):
        print(rel_path)
PY
  )
}

collect_macos_state() {
  local previous_notary_json="${PREVIOUS_MACOS_NOTARIZATION_IDS_JSON}"
  local notary_json="{}"
  if [[ "${MACOS_PACKAGED_THIS_RUN}" -eq 1 ]]; then
    notary_json="$(
      python3 - "${MACOS_NOTARY_IDS_FILE}" <<'PY'
import json
import sys

result = {}
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        name, request_id = line.split(":", 1)
        result[name] = request_id
print(json.dumps(result, separators=(",", ":")))
PY
    )"
  else
    notary_json="${previous_notary_json}"
  fi

  local disk_images_file="${TMP_DIR}/manifest-macos.jsonl"
  : > "${disk_images_file}"

  local product dmg_name rel_path abs_path sha
  for product in trace live; do
    dmg_name="RTMify_$(product_title "${product}")_${VERSION}.dmg"
    rel_path="packages/macos/${dmg_name}"
    abs_path="${RELEASE_DIR}/${rel_path}"
    [[ -f "${abs_path}" ]] || continue
    sha="$(hash_path "${abs_path}")"
    append_json_line "${disk_images_file}" \
      "{\"product\":\"${product}\",\"path\":\"${rel_path}\",\"sha256\":\"${sha}\"}"
    checksum_append "${rel_path}" "${abs_path}"
  done

  if [[ -s "${disk_images_file}" ]]; then
    MACOS_SECTION_PRESENT=1
    local bin_rel
    for bin_rel in "bin/rtmify-license-gen" "bin/rtmify-trace" "bin/rtmify-live"; do
      [[ -f "${RELEASE_DIR}/${bin_rel}" ]] || continue
      checksum_append "${bin_rel}" "${RELEASE_DIR}/${bin_rel}"
    done

    local signing_identity="${SIGNING_IDENTITY}"
    if [[ "${MACOS_PACKAGED_THIS_RUN}" -ne 1 ]]; then
      signing_identity="${PREVIOUS_MACOS_SIGNING_IDENTITY}"
    fi

    MACOS_SECTION_JSON=$(
      python3 - "${disk_images_file}" "${signing_identity}" "${notary_json}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    content = handle.read().strip()
disk_images = json.loads(f"[{content}]") if content else []
section = {
    "signing_identity": sys.argv[2],
    "notarization_ids": json.loads(sys.argv[3]),
    "disk_images": disk_images,
}
print(json.dumps(section, separators=(",", ":")))
PY
    )
  fi
}

collect_windows_state() {
  local signed_binaries_file="${TMP_DIR}/manifest-windows-signed.txt"
  local installers_file="${TMP_DIR}/manifest-windows-installers.jsonl"
  : > "${signed_binaries_file}"
  : > "${installers_file}"

  local rel_path
  for rel_path in \
    "windows/rtmify-trace.exe" \
    "windows/RTMify Live.exe" \
    "windows/rtmify-live.exe"; do
    if [[ -f "${RELEASE_DIR}/${rel_path}" ]]; then
      printf '%s\n' "${rel_path}" >> "${signed_binaries_file}"
    fi
  done

  local payload_zip_rel="packages/windows/$(windows_payload_zip_name)"
  local payload_zip_abs="${RELEASE_DIR}/${payload_zip_rel}"
  local payload_zip_json="null"
  if [[ -f "${payload_zip_abs}" ]]; then
    local payload_zip_sha
    payload_zip_sha="$(hash_path "${payload_zip_abs}")"
    payload_zip_json="{\"path\":\"${payload_zip_rel}\",\"sha256\":\"${payload_zip_sha}\"}"
    checksum_append "${payload_zip_rel}" "${payload_zip_abs}"
  fi

  local product installer_name installer_rel installer_abs sha
  for product in trace live; do
    installer_name="RTMify_$(product_title "${product}")_Installer_${VERSION}.exe"
    installer_rel="packages/windows/${installer_name}"
    installer_abs="${RELEASE_DIR}/${installer_rel}"
    [[ -f "${installer_abs}" ]] || continue
    sha="$(hash_path "${installer_abs}")"
    append_json_line "${installers_file}" \
      "{\"product\":\"${product}\",\"path\":\"${installer_rel}\",\"sha256\":\"${sha}\"}"
    checksum_append "${installer_rel}" "${installer_abs}"
  done

  if [[ -s "${signed_binaries_file}" || -f "${payload_zip_abs}" || -s "${installers_file}" || "${PREVIOUS_HAS_WINDOWS}" -eq 1 ]]; then
    WINDOWS_SECTION_PRESENT=1

    if [[ -s "${signed_binaries_file}" ]]; then
      while IFS= read -r rel_path; do
        [[ -n "${rel_path}" ]] || continue
        checksum_append "${rel_path}" "${RELEASE_DIR}/${rel_path}"
      done < "${signed_binaries_file}"
    fi

    local windows_status="payloads_signed"
    if [[ -s "${installers_file}" ]]; then
      windows_status="finalized"
    fi

    WINDOWS_SECTION_JSON=$(
      python3 - "${signed_binaries_file}" "${installers_file}" "${windows_status}" "${payload_zip_json}" <<'PY'
import json
import sys
from pathlib import Path

signed = []
signed_path = Path(sys.argv[1])
if signed_path.exists():
    for line in signed_path.read_text(encoding="utf-8").splitlines():
        if line:
            signed.append(line)

installers_content = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
installers = json.loads(f"[{installers_content}]") if installers_content else []

section = {
    "status": sys.argv[3],
    "signed_binaries": signed,
    "payload_zip": json.loads(sys.argv[4]),
    "installers": installers,
}
print(json.dumps(section, separators=(",", ":")))
PY
    )
  fi
}

collect_linux_state() {
  local packages_file="${TMP_DIR}/manifest-linux.jsonl"
  : > "${packages_file}"

  local tarball
  while IFS= read -r tarball; do
    [[ -n "${tarball}" ]] || continue
    local rel_path sha product
    rel_path="${tarball#${RELEASE_DIR}/}"
    sha="$(hash_path "${tarball}")"
    product="$(basename "${tarball}")"
    product="${product%-linux-x64-${VERSION}.tar.gz}"
    product="${product#rtmify-}"
    append_json_line "${packages_file}" \
      "{\"product\":\"${product}\",\"path\":\"${rel_path}\",\"sha256\":\"${sha}\"}"
    checksum_append "${rel_path}" "${tarball}"
  done < <(find "${LINUX_PKGS_DIR}" -maxdepth 1 -type f -name "*-linux-x64-${VERSION}.tar.gz" | sort)

  if [[ -s "${packages_file}" ]]; then
    LINUX_SECTION_PRESENT=1
    LINUX_SECTION_JSON=$(
      python3 - "${packages_file}" <<'PY'
import json
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
packages = json.loads(f"[{content}]") if content else []
print(json.dumps({"packages": packages}, separators=(",", ":")))
PY
    )
  fi
}

write_checksums_and_package_manifest() {
  : > "${CHECKSUMS_FILE}"
  MACOS_SECTION_PRESENT=0
  WINDOWS_SECTION_PRESENT=0
  LINUX_SECTION_PRESENT=0
  MACOS_SECTION_JSON=""
  WINDOWS_SECTION_JSON=""
  LINUX_SECTION_JSON=""

  collect_validation_checksums
  collect_macos_state
  collect_windows_state
  collect_linux_state

  {
    printf '{\n'
    printf '  "version": "%s",\n' "${VERSION}"
    printf '  "packaged_at": %s' "$(date +%s)"

    if [[ "${MACOS_SECTION_PRESENT}" -eq 1 ]]; then
      printf ',\n  "macos": %s' "${MACOS_SECTION_JSON}"
    fi
    if [[ "${WINDOWS_SECTION_PRESENT}" -eq 1 ]]; then
      printf ',\n  "windows": %s' "${WINDOWS_SECTION_JSON}"
    fi
    if [[ "${LINUX_SECTION_PRESENT}" -eq 1 ]]; then
      printf ',\n  "linux": %s' "${LINUX_SECTION_JSON}"
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
      --release-dir)           RELEASE_DIR="${2:?missing value for --release-dir}"; shift 2 ;;
      --macos)                 ONLY_MACOS=1; shift ;;
      --windows)               ONLY_WINDOWS=1; shift ;;
      --linux)                 ONLY_LINUX=1; shift ;;
      --skip-macos)            SKIP_MACOS=1; shift ;;
      --skip-windows)          SKIP_WINDOWS=1; shift ;;
      --skip-linux)            SKIP_LINUX=1; shift ;;
      --windows-unsigned-dir)  WINDOWS_UNSIGNED_DIR="${2:?missing value for --windows-unsigned-dir}"; shift 2 ;;
      --signing-identity)      SIGNING_IDENTITY="${2:?}"; shift 2 ;;
      --notary-key-file)       NOTARY_KEY_FILE="${2:?}"; shift 2 ;;
      --notary-key-id)         NOTARY_KEY_ID="${2:?}"; shift 2 ;;
      --notary-issuer)         NOTARY_ISSUER="${2:?}"; shift 2 ;;
      --azure-endpoint)        AZURE_ENDPOINT="${2:?}"; shift 2 ;;
      --azure-account)         AZURE_ACCOUNT="${2:?}"; shift 2 ;;
      --azure-profile)         AZURE_PROFILE="${2:?}"; shift 2 ;;
      --jsign-bin)             JSIGN_BIN="${2:?}"; shift 2 ;;
      --jsign-jar)             JSIGN_JAR="${2:?}"; shift 2 ;;
      --gpg-key)               GPG_KEY="${2:?}"; shift 2 ;;
      --help|-h)               usage; exit 0 ;;
      *)                       echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  # --macos/--windows/--linux: if any positive flag is set, skip the rest
  if [[ "${ONLY_MACOS}" -eq 1 || "${ONLY_WINDOWS}" -eq 1 || "${ONLY_LINUX}" -eq 1 ]]; then
    [[ "${ONLY_MACOS}" -eq 1 ]]   || SKIP_MACOS=1
    [[ "${ONLY_WINDOWS}" -eq 1 ]] || SKIP_WINDOWS=1
    [[ "${ONLY_LINUX}" -eq 1 ]]   || SKIP_LINUX=1
  fi

  if [[ -z "${RELEASE_DIR}" ]]; then
    echo "Error: --release-dir is required." >&2
    usage >&2
    exit 2
  fi

  if [[ -n "${WINDOWS_UNSIGNED_DIR}" && "${SKIP_WINDOWS}" -eq 1 ]]; then
    echo "Error: --windows-unsigned-dir cannot be combined with --skip-windows." >&2
    exit 2
  fi

  if [[ -n "${WINDOWS_UNSIGNED_DIR}" ]]; then
    SKIP_MACOS=1
    SKIP_LINUX=1
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

  PACKAGES_DIR="${RELEASE_DIR}/packages"
  MACOS_PKGS_DIR="${PACKAGES_DIR}/macos"
  WINDOWS_PKGS_DIR="${PACKAGES_DIR}/windows"
  LINUX_PKGS_DIR="${PACKAGES_DIR}/linux"
  CHECKSUMS_FILE="${RELEASE_DIR}/checksums.txt"
  PKG_MANIFEST="${RELEASE_DIR}/package-manifest.json"

  mkdir -p "${PACKAGES_DIR}" "${MACOS_PKGS_DIR}" "${WINDOWS_PKGS_DIR}" "${LINUX_PKGS_DIR}"

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rtmify-package.XXXXXX")"
  cleanup() { rm -rf "${TMP_DIR}"; }
  trap cleanup EXIT

  MACOS_NOTARY_IDS_FILE="${TMP_DIR}/macos-notary-ids.txt"
  touch "${MACOS_NOTARY_IDS_FILE}"
  MACOS_PACKAGED_THIS_RUN=0
  LINUX_PACKAGED_THIS_RUN=0
  WINDOWS_PACKAGE_MODE="skipped"

  load_previous_package_manifest_state

  echo "RTMify package.sh — version ${VERSION}"
  echo "Release dir: ${RELEASE_DIR}"

  [[ "${SKIP_MACOS}" -ne 1 ]] && package_macos

  if [[ "${SKIP_WINDOWS}" -ne 1 ]]; then
    if [[ -n "${WINDOWS_UNSIGNED_DIR}" ]]; then
      finalize_windows_installers
    else
      stage_windows_payloads
    fi
  fi

  [[ "${SKIP_LINUX}" -ne 1 ]] && package_linux

  write_checksums_and_package_manifest

  echo "Package artifacts written to ${PACKAGES_DIR}"
  echo "Package manifest: ${PKG_MANIFEST}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
