#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="info"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Delete Dragonfly operator from dragonflydb/dragonfly-operator
function delete_dragonfly_operator() {
    log info "Deleting Dragonfly operator"

    local -r operator_version="main"
    local -r operator_url="https://raw.githubusercontent.com/dragonflydb/dragonfly-operator/${operator_version}/manifests/dragonfly-operator.yaml"

    log info "Downloading Dragonfly operator manifest" "url=${operator_url}"

    if ! operator_content=$(curl --fail --silent --location "${operator_url}"); then
        log error "Failed to download Dragonfly operator manifest" "url=${operator_url}"
        return 1
    fi

    log info "Deleting Dragonfly operator manifest"

    if ! echo "${operator_content}" | kubectl delete --filename - --ignore-not-found=true; then
        log error "Failed to delete Dragonfly operator manifest"
        return 1
    fi

    log info "Dragonfly operator manifest deleted successfully"
}

# Verify the operator is removed
function verify_dragonfly_operator_removed() {
    log info "Verifying Dragonfly operator removal"

    # Wait a moment for resources to be deleted
    sleep 2

    # Check if the CRD is still present
    if kubectl get crd dragonflies.dragonflydb.io &>/dev/null; then
        log warn "Dragonfly CRD still exists: dragonflies.dragonflydb.io"
        log info "CRDs may take time to be fully removed"
    else
        log info "Dragonfly CRD removed: dragonflies.dragonflydb.io"
    fi

    # Check if the operator namespace still exists
    if kubectl get namespace dragonfly-operator-system &>/dev/null; then
        log warn "Dragonfly operator namespace still exists: dragonfly-operator-system"
        log info "Attempting to delete namespace..."
        if kubectl delete namespace dragonfly-operator-system --timeout=60s &>/dev/null; then
            log info "Dragonfly operator namespace deleted"
        else
            log warn "Failed to delete namespace (may still be terminating)"
        fi
    else
        log info "Dragonfly operator namespace removed"
    fi

    log info "Dragonfly operator removal verification complete"
}

function main() {
    check_env KUBECONFIG
    check_cli kubectl curl

    delete_dragonfly_operator
    verify_dragonfly_operator_removed

    log info "Dragonfly operator uninstallation complete"
}

main "$@"

