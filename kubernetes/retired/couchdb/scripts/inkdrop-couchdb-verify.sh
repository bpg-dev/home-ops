#!/usr/bin/env bash
set -Eeuo pipefail

# Quick verification for CouchDB + Inkdrop DB.
#
# This avoids printing secrets; it only checks that endpoints respond.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

function usage() {
  cat <<'USAGE'
Usage:
  ./scripts/inkdrop-couchdb-verify.sh

Required env:
  COUCHDB_BASE_URL
  INKDROP_DB_NAME         (default: my-inkdrop-notes)

Auth:
  Inkdrop user creds:
    INKDROP_USERNAME (default: inkdrop)
    INKDROP_PASSWORD (prompted if not set)

In-cluster example:
  COUCHDB_BASE_URL=http://couchdb-svc-couchdb.data:5984
USAGE
}

function main() {
  if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    usage
    exit 0
  fi

  check_cli curl
  check_env COUCHDB_BASE_URL

  local base="${COUCHDB_BASE_URL%/}"
  local db="${INKDROP_DB_NAME:-my-inkdrop-notes}"
  local user="${INKDROP_USERNAME:-inkdrop}"
  prompt_secret INKDROP_PASSWORD "INKDROP_PASSWORD"

  log info "Checking CouchDB is reachable" "url=${base}"
  curl -fsS "${base}/_up" >/dev/null

  log info "Checking DB exists and is accessible with Inkdrop user" "db=${db}"
  curl -fsS -u "${user}:${INKDROP_PASSWORD}" "${base}/${db}" >/dev/null

  log info "OK"
}

main "$@"


