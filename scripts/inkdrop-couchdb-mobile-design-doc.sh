#!/usr/bin/env bash
set -Eeuo pipefail

# Optional helper: create Inkdrop mobile sync design document.
#
# Ref: https://docs.inkdrop.app/reference/note-synchronization#support-mobile-sync

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

function usage() {
  cat <<'USAGE'
Usage:
  ./scripts/inkdrop-couchdb-mobile-design-doc.sh

Required env:
  One of:
    1) INKDROP_DB_URL
       Example: https://inkdrop:<PASSWORD>@couchdb.<domain>/my-inkdrop-notes
    2) COUCHDB_BASE_URL + INKDROP_DB_NAME (+ optional INKDROP_USERNAME)
       - In this mode, the script will prompt for INKDROP_PASSWORD and use curl -u.

Notes:
  - This script writes a design doc at /_design/mobile with a filter named "sync".
USAGE
}

function json_extract_field() {
  local json="$1"
  local field="$2"
  local re="\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\""
  if [[ "${json}" =~ ${re} ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

function main() {
  if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    usage
    exit 0
  fi

  check_cli curl
  if [[ -n "${INKDROP_DB_URL-}" ]]; then
    : # ok
  else
    check_env COUCHDB_BASE_URL INKDROP_DB_NAME
    prompt_secret INKDROP_PASSWORD "INKDROP_PASSWORD"
  fi

  local url=""
  local curl_auth=()
  if [[ -n "${INKDROP_DB_URL-}" ]]; then
    url="${INKDROP_DB_URL%/}"
  else
    local base="${COUCHDB_BASE_URL%/}"
    local db="${INKDROP_DB_NAME}"
    local user="${INKDROP_USERNAME:-inkdrop}"
    url="${base}/${db}"
    curl_auth=(-u "${user}:${INKDROP_PASSWORD}")
  fi

  log info "Creating design doc for mobile sync"

  local doc_url="${url}/_design/mobile"
  local payload='{"_id":"_design/mobile","filters":{"sync":"function (doc) { return doc._id.indexOf(\"file:\") === -1 }"}}'

  # Make it safe to re-run: if the design doc exists, include _rev.
  if existing="$(curl -fsS "${curl_auth[@]}" "${doc_url}" 2>/dev/null)"; then
    if rev="$(json_extract_field "${existing}" "_rev")"; then
      payload="{\"_id\":\"_design/mobile\",\"_rev\":\"${rev}\",\"filters\":{\"sync\":\"function (doc) { return doc._id.indexOf(\\\"file:\\\") === -1 }\"}}"
    fi
  fi

  curl -fsS "${curl_auth[@]}" -X PUT "${doc_url}" \
    -H 'Content-Type: application/json' \
    --data-binary "${payload}" \
    >/dev/null

  log info "Done"
}

main "$@"


