#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
    log debug "Waiting for nodes to be available"

    # Skip waiting if all nodes are 'Ready=True'
    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are available and ready, skipping wait for nodes"
        return
    fi

    # Wait for all nodes to be 'Ready=False'
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
        sleep 10
    done
}

# Namespaces to be applied before the SOPS secrets are installed
function apply_namespaces() {
    log debug "Applying namespaces"

    local -r apps_dir="${ROOT_DIR}/kubernetes/apps"

    if [[ ! -d "${apps_dir}" ]]; then
        log error "Directory does not exist" "directory=${apps_dir}"
    fi

    for app in "${apps_dir}"/*/; do
        namespace=$(basename "${app}")

        # Check if the namespace resources are up-to-date
        if kubectl get namespace "${namespace}" &>/dev/null; then
            log info "Namespace resource is up-to-date" "resource=${namespace}"
            continue
        fi

        # Apply the namespace resources
        if kubectl create namespace "${namespace}" --dry-run=client --output=yaml \
            | kubectl apply --server-side --filename - &>/dev/null;
        then
            log info "Namespace resource applied" "resource=${namespace}"
        else
            log error "Failed to apply namespace resource" "resource=${namespace}"
        fi
    done
}

# SOPS secrets to be applied before the helmfile charts are installed
function apply_sops_secrets() {
    log debug "Applying secrets"

    local -r secrets=(
        "${ROOT_DIR}/bootstrap/github-deploy-key.sops.yaml"
        "${ROOT_DIR}/bootstrap/sops-age.sops.yaml"
        "${ROOT_DIR}/kubernetes/components/sops/cluster-secrets.sops.yaml"
    )

    for secret in "${secrets[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace flux-system diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace flux-system apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done
}

# Apply VolumeSnapshot CRDs from kubernetes-csi/external-snapshotter
function apply_volumesnapshot_crds() {
    log debug "Applying VolumeSnapshot CRDs"

    local -r snapshotter_version="v8.2.1"
    local -r crd_base_url="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${snapshotter_version}/client/config/crd"

    local -r crds=(
        "snapshot.storage.k8s.io_volumesnapshotcontents.yaml"
        "snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
        "snapshot.storage.k8s.io_volumesnapshots.yaml"
    )

    for crd in "${crds[@]}"; do
        local crd_url="${crd_base_url}/${crd}"

        log debug "Applying CRD" "crd=${crd}" "url=${crd_url}"

        if ! crd_content=$(curl --fail --silent --location "${crd_url}"); then
            log error "Failed to download CRD" "crd=${crd}" "url=${crd_url}"
            continue
        fi

        if echo "${crd_content}" | kubectl diff --filename - &>/dev/null; then
            log debug "CRD is up-to-date" "crd=${crd}"
            continue
        fi

        if ! echo "${crd_content}" | kubectl apply --server-side --filename - &>/dev/null; then
            log error "Failed to apply CRD" "crd=${crd}"
            continue
        fi

        log info "CRD applied successfully" "crd=${crd}"
    done
}

# Apply Dragonfly operator from dragonflydb/dragonfly-operator
function apply_dragonfly_operator() {
    log debug "Applying Dragonfly operator"

    local -r operator_version="main"
    local -r operator_url="https://raw.githubusercontent.com/dragonflydb/dragonfly-operator/${operator_version}/manifests/dragonfly-operator.yaml"

    log debug "Downloading Dragonfly operator manifest" "url=${operator_url}"

    if ! operator_content=$(curl --fail --silent --location "${operator_url}"); then
        log error "Failed to download Dragonfly operator manifest" "url=${operator_url}"
        return 1
    fi

    log debug "Applying Dragonfly operator manifest"

    # Check if the operator is up-to-date
    if echo "${operator_content}" | kubectl diff --filename - &>/dev/null; then
        log debug "Dragonfly operator is up-to-date"
        return 0
    fi

    if ! echo "${operator_content}" | kubectl apply --server-side --filename - &>/dev/null; then
        log error "Failed to apply Dragonfly operator manifest"
        return 1
    fi

    log info "Dragonfly operator applied successfully"
}

# CRDs to be applied before the helmfile charts are installed
function apply_crds() {
    log debug "Applying CRDs"

    # Apply VolumeSnapshot CRDs first (required by CSI snapshotter)
    apply_volumesnapshot_crds

    # Apply Dragonfly operator
    apply_dragonfly_operator

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.d/00-crds.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log fatal "File does not exist" "file" "${helmfile_file}"
    fi

    local helmfile_crds
    if ! helmfile_crds=$(helmfile --file "${helmfile_file}" template --quiet) || [[ -z "${helmfile_crds}" ]]; then
        log fatal "Failed to render CRDs from Helmfile" "file" "${helmfile_file}"
    fi

    if echo "${helmfile_crds}" | kubectl diff --filename - &>/dev/null; then
        log info "CRDs are up-to-date"
        return
    fi

    if ! echo "${helmfile_crds}" | kubectl apply --server-side --filename - &>/dev/null; then
        log fatal "Failed to apply crds from Helmfile" "file" "${helmfile_file}"
    fi

    log info "CRDs applied successfully"
}

# Sync Helm releases
function sync_helm_releases() {
    log debug "Syncing Helm releases"

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.d/01-apps.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log error "File does not exist" "file=${helmfile_file}"
    fi

    if ! helmfile --file "${helmfile_file}" sync --hide-notes; then
        log error "Failed to sync Helm releases"
    fi

    log info "Helm releases synced successfully"
}

function main() {
    check_env KUBECONFIG TALOSCONFIG
    check_cli helmfile kubectl kustomize sops talhelper yq

    # Apply resources and Helm releases
    wait_for_nodes
    apply_namespaces
    apply_sops_secrets
    apply_crds
    sync_helm_releases

    log info "Congrats! The cluster is bootstrapped and Flux is syncing the Git repository"
}

main "$@"
