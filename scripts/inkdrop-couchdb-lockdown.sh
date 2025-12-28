#!/usr/bin/env bash
set -Eeuo pipefail

# Lock down an existing Inkdrop CouchDB database so it's not readable without auth.
#
# It sets:
# - admins.names:  ["$INKDROP_USERNAME"]
# - members.names: ["$INKDROP_USERNAME"]
#
# This prevents unauthenticated reads of DB metadata like GET /<db>.
#
# Ref: https://docs.inkdrop.app/reference/note-synchronization

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

function usage() {
  cat <<'USAGE'
Usage:
  ./scripts/inkdrop-couchdb-lockdown.sh

Required env:
  COUCHDB_BASE_URL
  INKDROP_DB_NAME
  INKDROP_USERNAME
  # In-cluster example:
  #   COUCHDB_BASE_URL=http://couchdb-svc-couchdb.data:5984

Admin credentials source (choose one):
  1) 1Password CLI (preferred):
       OP_VAULT, OP_ITEM
       OP_FIELD_USER     (default: admin-username)
       OP_FIELD_PASSWORD (default: admin-password)
  2) Direct env vars:
       COUCHDB_ADMIN_USER
       COUCHDB_ADMIN_PASSWORD
USAGE
}

function require_one_of_admin_sources() {
  if [[ -n "${COUCHDB_ADMIN_USER-}" && -n "${COUCHDB_ADMIN_PASSWORD-}" ]]; then
    return 0
  fi
  if [[ -n "${OP_VAULT-}" && -n "${OP_ITEM-}" ]]; then
    return 0
  fi
  log error "Missing CouchDB admin credentials source" \
    "set=COUCHDB_ADMIN_USER+COUCHDB_ADMIN_PASSWORD or OP_VAULT+OP_ITEM"
}

function op_read_field() {
  local field="$1"
  local path="op://${OP_VAULT}/${OP_ITEM}/${field}"
  op read "${path}"
}

function get_admin_creds() {
  if [[ -n "${COUCHDB_ADMIN_USER-}" && -n "${COUCHDB_ADMIN_PASSWORD-}" ]]; then
    return 0
  fi

  check_cli op
  check_env OP_VAULT OP_ITEM

  local user_field="${OP_FIELD_USER:-admin-username}"
  local pass_field="${OP_FIELD_PASSWORD:-admin-password}"

  COUCHDB_ADMIN_USER="$(op_read_field "${user_field}")"
  COUCHDB_ADMIN_PASSWORD="$(op_read_field "${pass_field}")"
  export COUCHDB_ADMIN_USER COUCHDB_ADMIN_PASSWORD
}

function main() {
  if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    usage
    exit 0
  fi

  check_cli curl
  check_env COUCHDB_BASE_URL INKDROP_DB_NAME INKDROP_USERNAME
  require_one_of_admin_sources
  get_admin_creds

  local base="${COUCHDB_BASE_URL%/}"
  local db="${INKDROP_DB_NAME}"
  local ink_user="${INKDROP_USERNAME}"
  local admin_auth=(-u "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}")

  log info "Locking down database security" "db=${db}" "user=${ink_user}"

  curl -fsS "${admin_auth[@]}" -X PUT \
    -H 'Content-Type: application/json' \
    --data-binary "{\"admins\":{\"names\":[\"${ink_user}\"],\"roles\":[]},\"members\":{\"names\":[\"${ink_user}\"],\"roles\":[]}}" \
    "${base}/${db}/_security" \
    >/dev/null

  log info "Done"
}

main "$@"


