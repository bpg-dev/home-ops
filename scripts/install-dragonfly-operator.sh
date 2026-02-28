#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="info"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Apply Dragonfly operator from dragonflydb/dragonfly-operator
function apply_dragonfly_operator() {
    log info "Applying Dragonfly operator"

    local -r operator_version="v1.4.0"
    local -r operator_url="https://raw.githubusercontent.com/dragonflydb/dragonfly-operator/${operator_version}/manifests/dragonfly-operator.yaml"

    log info "Downloading Dragonfly operator manifest" "url=${operator_url}"

    if ! operator_content=$(curl --fail --silent --location "${operator_url}"); then
        log error "Failed to download Dragonfly operator manifest" "url=${operator_url}"
        return 1
    fi

    log info "Applying Dragonfly operator manifest"

    # Check if the operator is up-to-date
    if echo "${operator_content}" | kubectl diff --filename - &>/dev/null; then
        log info "Dragonfly operator is up-to-date"
        return 0
    fi

    if ! echo "${operator_content}" | kubectl apply --server-side --filename -; then
        log error "Failed to apply Dragonfly operator manifest"
        return 1
    fi

    log info "Dragonfly operator manifest applied successfully"
}

# Verify the operator is installed
function verify_dragonfly_operator() {
    log info "Verifying Dragonfly operator installation"

    # Wait a moment for resources to be registered
    sleep 2

    # Check if the CRD is present
    if kubectl get crd dragonflies.dragonflydb.io &>/dev/null; then
        log info "Dragonfly CRD found: dragonflies.dragonflydb.io"
    else
        log error "Dragonfly CRD not found: dragonflies.dragonflydb.io"
        return 1
    fi

    # Check if the operator deployment is running
    if kubectl get deployment dragonfly-operator-controller-manager -n dragonfly-operator-system &>/dev/null; then
        log info "Dragonfly operator deployment found"

        # Wait for the deployment to be ready
        if kubectl wait deployment dragonfly-operator-controller-manager \
            -n dragonfly-operator-system \
            --for=condition=Available \
            --timeout=300s &>/dev/null; then
            log info "Dragonfly operator deployment is ready"
        else
            log warn "Dragonfly operator deployment is not ready yet"
        fi
    else
        log warn "Dragonfly operator deployment not found (may still be creating)"
    fi

    log info "Dragonfly operator verification complete"
}

function main() {
    check_env KUBECONFIG
    check_cli kubectl curl

    apply_dragonfly_operator
    verify_dragonfly_operator

    log info "Dragonfly operator installation complete"
}

main "$@"

