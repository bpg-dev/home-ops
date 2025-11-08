#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="info"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Apply VolumeSnapshot CRDs from kubernetes-csi/external-snapshotter
function apply_volumesnapshot_crds() {
    log info "Applying VolumeSnapshot CRDs"

    local -r snapshotter_version="v8.2.1"
    local -r crd_base_url="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${snapshotter_version}/client/config/crd"

    local -r crds=(
        "snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
        "snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
        "snapshot.storage.k8s.io_volumesnapshots.yaml"
    )

    for crd in "${crds[@]}"; do
        local crd_url="${crd_base_url}/${crd}"

        log info "Downloading CRD" "crd=${crd}"

        if ! crd_content=$(curl --fail --silent --location "${crd_url}"); then
            log error "Failed to download CRD" "crd=${crd}" "url=${crd_url}"
            continue
        fi

        log info "Applying CRD" "crd=${crd}"

        if ! echo "${crd_content}" | kubectl apply --server-side --filename -; then
            log error "Failed to apply CRD" "crd=${crd}"
            continue
        fi

        log info "CRD applied successfully" "crd=${crd}"
    done

    log info "Verifying CRDs are installed"

    # Wait a moment for CRDs to be registered
    sleep 2

    # Verify all three required CRDs are present
    local required_crds=(
        "volumesnapshotcontents.snapshot.storage.k8s.io"
        "volumesnapshotclasses.snapshot.storage.k8s.io"
        "volumesnapshots.snapshot.storage.k8s.io"
    )

    local missing_crds=()
    local found_crds=()

    for required_crd in "${required_crds[@]}"; do
        if kubectl get crd "${required_crd}" &>/dev/null; then
            found_crds+=("${required_crd}")
        else
            missing_crds+=("${required_crd}")
        fi
    done

    if [[ ${#found_crds[@]} -gt 0 ]]; then
        log info "Found VolumeSnapshot CRDs:"
        for crd in "${found_crds[@]}"; do
            kubectl get crd "${crd}" -o jsonpath='{.metadata.name}{"\n"}' 2>/dev/null || true
        done
    fi

    if [[ ${#missing_crds[@]} -gt 0 ]]; then
        log error "Missing required CRDs:" "missing=${missing_crds[*]}"
        log info "Checking all snapshot-related CRDs:"
        kubectl get crd 2>/dev/null | grep -i snapshot || log warn "No snapshot CRDs found"
        return 1
    fi

    log info "All required VolumeSnapshot CRDs are installed"
}

function main() {
    check_env KUBECONFIG
    check_cli kubectl curl

    apply_volumesnapshot_crds

    log info "VolumeSnapshot CRDs installation complete"
}

main "$@"

