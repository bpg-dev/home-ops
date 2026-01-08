#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap CouchDB for Inkdrop sync.
#
# This script:
# - Fetches CouchDB admin credentials from 1Password (via `op`) OR env vars
# - Creates system databases required by CouchDB
# - Creates the Inkdrop database
# - Creates a dedicated Inkdrop CouchDB user
# - Locks down the Inkdrop database security (_security) to that user
#
# References:
# - Inkdrop docs: https://docs.inkdrop.app/reference/note-synchronization

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

function usage() {
  cat <<'USAGE'
Usage:
  ./scripts/inkdrop-couchdb-bootstrap.sh

Required env:
  COUCHDB_BASE_URL
    - Example: https://couchdb.${SECRET_DOMAIN}
    - Must be reachable from where you run this script (LAN/VPN).
    - In-cluster alternative: http://couchdb-svc-couchdb.data:5984

Optional env:
  INKDROP_DB_NAME         (default: my-inkdrop-notes)
  INKDROP_USERNAME        (default: inkdrop)
  INKDROP_PASSWORD        (default: prompted; leave blank to auto-generate)

Admin credentials source (choose one):
  1) 1Password CLI (preferred):
     OP_VAULT and OP_ITEM must be set and `op` must be signed in.
       OP_VAULT          e.g. "Home"
       OP_ITEM           e.g. "couchdb"
       OP_FIELD_USER     (default: admin-username)
       OP_FIELD_PASSWORD (default: admin-password)

  2) Direct env vars:
       COUCHDB_ADMIN_USER
       COUCHDB_ADMIN_PASSWORD

Output:
  - Prints the Inkdrop database URL to use (includes Inkdrop user + password).
    Store it in 1Password and paste into Inkdrop -> Advanced (CouchDB) sync.
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

  # Avoid logging secrets
  COUCHDB_ADMIN_USER="$(op_read_field "${user_field}")"
  COUCHDB_ADMIN_PASSWORD="$(op_read_field "${pass_field}")"
  export COUCHDB_ADMIN_USER COUCHDB_ADMIN_PASSWORD
}

function generate_password() {
  # 32 random bytes -> base64 (URL-safe enough for our usage)
  openssl rand -base64 32
}

function url_encode() {
  # Percent-encode a string for use in URL userinfo (username/password).
  # This is important because generated passwords often contain '+', '/', '='.
  local s="$1"
  local out=""
  local i c

  # Force byte-wise iteration.
  LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "${c}" in
      [a-zA-Z0-9.~_-]) out+="${c}" ;;
      *) printf -v hex '%%%02X' "'${c}"; out+="${hex}" ;;
    esac
  done

  printf "%s" "${out}"
}

function curl_json() {
  local method="$1"
  local url="$2"
  local data="${3-}"

  if [[ -n "${data}" ]]; then
    curl -fsS -X "${method}" \
      -H 'Content-Type: application/json' \
      --data-binary "${data}" \
      "${url}"
  else
    curl -fsS -X "${method}" "${url}"
  fi
}

function curl_get_json_auth() {
  local url="$1"
  shift
  curl -fsS "$@" "${url}"
}

function curl_json_auth() {
  local method="$1"
  local url="$2"
  local data="$3"
  shift 3

  curl -fsS "$@" -X "${method}" \
    -H 'Content-Type: application/json' \
    --data-binary "${data}" \
    "${url}"
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

function ensure_user_doc() {
  local base="$1"
  local username="$2"
  local password="$3"
  shift 3

  local admin_auth=("$@")
  local user_doc_url="${base}/_users/org.couchdb.user:${username}"

  # If it exists, update password (requires _rev).
  if existing="$(curl_get_json_auth "${user_doc_url}" "${admin_auth[@]}" 2>/dev/null)"; then
    if rev="$(json_extract_field "${existing}" "_rev")"; then
      log info "Inkdrop user already exists; updating password" "user=${username}"
      curl_json_auth PUT "${user_doc_url}" \
        "{\"_id\":\"org.couchdb.user:${username}\",\"_rev\":\"${rev}\",\"name\":\"${username}\",\"password\":\"${password}\",\"roles\":[],\"type\":\"user\"}" \
        "${admin_auth[@]}" \
        >/dev/null
      return 0
    fi
  fi

  log info "Creating Inkdrop CouchDB user" "user=${username}"
  curl_json_auth PUT "${user_doc_url}" \
    "{\"name\":\"${username}\",\"password\":\"${password}\",\"roles\":[],\"type\":\"user\"}" \
    "${admin_auth[@]}" \
    >/dev/null
}

function main() {
  if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    usage
    exit 0
  fi

  check_cli curl openssl
  check_env COUCHDB_BASE_URL
  require_one_of_admin_sources
  get_admin_creds

  local base="${COUCHDB_BASE_URL%/}"
  local db="${INKDROP_DB_NAME:-my-inkdrop-notes}"
  local ink_user="${INKDROP_USERNAME:-inkdrop}"
  local ink_pass="${INKDROP_PASSWORD:-}"

  if [[ -z "${ink_pass}" ]]; then
    # Prompt interactively; allow blank to fall back to auto-generate.
    prompt_secret INKDROP_PASSWORD "INKDROP_PASSWORD (leave blank to auto-generate)" true
    ink_pass="${INKDROP_PASSWORD}"
    if [[ -z "${ink_pass}" ]]; then
      ink_pass="$(generate_password)"
      log warn "Generated INKDROP_PASSWORD (store it in 1Password); it will be shown once at the end"
    fi
  fi

  # Use curl's -u to avoid embedding creds in URLs.
  local admin_auth=(-u "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}")

  log info "Creating CouchDB system databases (safe if they already exist)"
  for sysdb in _users _replicator _global_changes; do
    curl -fsS "${admin_auth[@]}" -X PUT "${base}/${sysdb}" >/dev/null || true
  done

  log info "Creating Inkdrop database" "db=${db}"
  curl -fsS "${admin_auth[@]}" -X PUT "${base}/${db}" >/dev/null || true

  log info "Creating Inkdrop CouchDB user" "user=${ink_user}"
  # NOTE: create user doc as admin (recommended by CouchDB). If it already exists, update its password.
  ensure_user_doc "${base}" "${ink_user}" "${ink_pass}" "${admin_auth[@]}"

  log info "Locking down Inkdrop DB security (_security) to the Inkdrop user"
  curl_json_auth PUT "${base}/${db}/_security" \
    "{\"admins\":{\"names\":[\"${ink_user}\"],\"roles\":[]},\"members\":{\"names\":[\"${ink_user}\"],\"roles\":[]}}" \
    "${admin_auth[@]}" \
    >/dev/null

  log info "Done"
  # Inkdrop requires credentials embedded in the URL (userinfo). Those MUST be percent-encoded
  # if they contain reserved characters (common in generated passwords).
  local proto="${base%%://*}"
  local hostpath="${base#*://}"
  local user_enc pass_enc
  user_enc="$(url_encode "${ink_user}")"
  pass_enc="$(url_encode "${ink_pass}")"

  printf "\nInkdrop CouchDB URL (paste into Inkdrop -> Advanced (CouchDB) -> Address):\n"
  printf "%s\n\n" "${proto}://${user_enc}:${pass_enc}@${hostpath}/${db}"
  printf "Credentials:\n"
  printf "  INKDROP_USERNAME=%s\n" "${ink_user}"
  printf "  INKDROP_PASSWORD=%s\n" "${ink_pass}"
}

main "$@"


