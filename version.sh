#!/usr/bin/env bash

set -euo pipefail

read_release_version() {
  local build_file="$1"
  sed -n \
    -e 's/^[[:space:]]*const default_version = "\(.*\)";/\1/p' \
    -e 's/^[[:space:]]*const version = "\(.*\)";/\1/p' \
    "${build_file}" | head -n 1
}

is_valid_release_version() {
  local version="$1"
  [[ "${version}" =~ ^[0-9]{8}-[a-z]+$ ]]
}

increment_release_suffix() {
  local suffix="$1"
  local carry=1
  local result=""
  local i ord next_ord next_char char

  [[ "${suffix}" =~ ^[a-z]+$ ]] || return 1

  for (( i=${#suffix}-1; i>=0; i-- )); do
    char="${suffix:i:1}"
    ord=$(printf '%d' "'${char}")
    if (( carry == 0 )); then
      result="${char}${result}"
      continue
    fi
    if (( ord == 122 )); then
      next_char="a"
    else
      next_ord=$((ord + 1))
      printf -v next_char '\\%03o' "${next_ord}"
      next_char=$(printf '%b' "${next_char}")
      carry=0
    fi
    result="${next_char}${result}"
  done

  if (( carry == 1 )); then
    result="a${result}"
  fi

  printf '%s\n' "${result}"
}

next_release_version() {
  local current_version="$1"
  local today="${2:-$(date +%Y%m%d)}"
  local current_date suffix

  is_valid_release_version "${current_version}" || return 1
  [[ "${today}" =~ ^[0-9]{8}$ ]] || return 1

  current_date="${current_version%%-*}"
  suffix="${current_version#*-}"

  if [[ "${current_date}" < "${today}" ]]; then
    printf '%s-a\n' "${today}"
    return 0
  fi

  printf '%s-%s\n' "${current_date}" "$(increment_release_suffix "${suffix}")"
}

write_release_version() {
  local build_file="$1"
  local version="$2"
  local tmp_file

  is_valid_release_version "${version}" || return 1
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/rtmify-build-zig.XXXXXX")"
  awk -v version="${version}" '
    BEGIN { updated = 0 }
    !updated && $0 ~ /^[[:space:]]*const default_version = "[^"]*";/ {
      sub(/"[^"]*"/, "\"" version "\"")
      updated = 1
    }
    { print }
    END {
      if (!updated) {
        exit 1
      }
    }
  ' "${build_file}" > "${tmp_file}" || {
    rm -f "${tmp_file}"
    return 1
  }

  mv "${tmp_file}" "${build_file}"
}
