#!/usr/bin/env bash
# VolSync Restore using Volume Populator Pattern
# This script ONLY uses the Volume Populator approach - the simplest restore method

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Logging
log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Configuration
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APP_NAME="${APP_NAME:-}"
readonly NAMESPACE="${NAMESPACE:-default}"
readonly KUBECONFIG="${KUBECONFIG:-${PROJECT_ROOT}/kubeconfig}"
readonly DATA_PATH="${DATA_PATH:-}"

# Auto-detected values
PVC_NAME=""
REPLICATION_DEST=""
WORKLOAD_TYPE=""
CONTAINER_NAME=""

# Snapshot selection
TIMESTAMP=""
PREVIOUS=""

# Show help
show_help() {
    cat <<EOF
VolSync Restore using Volume Populator Pattern

This script uses ONLY the Volume Populator approach - the simplest restore method.
When you create a PVC with dataSourceRef pointing to ReplicationDestination,
Kubernetes automatically triggers the restore and populates the PVC.

Usage: $0 [options]

Options:
    --timestamp TS    Restore from snapshot at/after timestamp (RFC3339 format)
                      Example: 2025-11-22T21:12:06Z
    --previous N      Restore from N-th previous snapshot (0=latest, 1=previous)
    --skip-verify     Skip verification step after restore
    --dry-run         Show what would be done without executing
    --help            Show this help

Environment Variables:
    APP_NAME          Application/workload name (required)
    NAMESPACE         Kubernetes namespace (default: default)
    DATA_PATH         Data directory path for verification (optional)
    KUBECONFIG        Path to kubeconfig (default: ./kubeconfig)

Examples:
    # Restore from latest snapshot
    APP_NAME=paperless-ngx ./scripts/restore-volsync-populator.sh

    # Restore from specific timestamp
    APP_NAME=paperless-ngx DATA_PATH=/library/data \\
      ./scripts/restore-volsync-populator.sh --timestamp 2025-11-22T21:12:06Z

    # Restore from previous snapshot
    APP_NAME=paperless-ngx \\
      ./scripts/restore-volsync-populator.sh --previous 1

How It Works:
    1. Scale down application
    2. Delete existing PVC
    3. Configure ReplicationDestination for snapshot selection (if specified)
    4. Create PVC with dataSourceRef pointing to ReplicationDestination
    5. Kubernetes automatically triggers restore and populates PVC
    6. Wait for PVC to be bound
    7. Scale up application
    8. Verify restore (if DATA_PATH is set)
EOF
}

# Auto-detect workload configuration
detect_workload() {
    log "Detecting workload configuration..."

    export KUBECONFIG

    # Detect workload type
    if kubectl get statefulset "$APP_NAME" -n "$NAMESPACE" &> /dev/null; then
        WORKLOAD_TYPE="statefulset"
        PVC_NAME=$(kubectl get statefulset "$APP_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.volumeClaimTemplates[0].metadata.name // empty' 2>/dev/null || echo "")
        [ -z "$PVC_NAME" ] && PVC_NAME="$APP_NAME"
        CONTAINER_NAME=$(kubectl get statefulset "$APP_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.template.spec.containers[0].name // "main"' 2>/dev/null || echo "main")
    elif kubectl get deployment "$APP_NAME" -n "$NAMESPACE" &> /dev/null; then
        WORKLOAD_TYPE="deployment"
        PVC_NAME=$(kubectl get deployment "$APP_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.template.spec.volumes[]? | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName' 2>/dev/null | head -1 || echo "")
        [ -z "$PVC_NAME" ] && PVC_NAME="$APP_NAME"
        CONTAINER_NAME=$(kubectl get deployment "$APP_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.template.spec.containers[0].name // "main"' 2>/dev/null || echo "main")
    else
        error "Cannot detect workload type for $APP_NAME. Ensure workload exists."
    fi

    REPLICATION_DEST="${APP_NAME}-dst"

    log "Detected: workload=$WORKLOAD_TYPE, pvc=$PVC_NAME, replicationDest=$REPLICATION_DEST, container=$CONTAINER_NAME"
}

# Check prerequisites
check_prereqs() {
    log "Checking prerequisites..."

    command -v kubectl > /dev/null || error "kubectl not found"
    command -v jq > /dev/null || error "jq not found"

    export KUBECONFIG
    kubectl cluster-info &> /dev/null || error "Cannot connect to cluster"

    kubectl get replicationdestination "$REPLICATION_DEST" -n "$NAMESPACE" &> /dev/null || \
        error "ReplicationDestination $REPLICATION_DEST not found in namespace $NAMESPACE"

    log "Prerequisites OK"
}

# Check backup exists
check_backup() {
    local source_name="$APP_NAME"
    local last_sync=$(kubectl get replicationsource "$source_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "")

    if [ -n "$last_sync" ]; then
        log "Latest backup: $last_sync"
    else
        warn "No backup found - restore may fail"
    fi
}

# Scale application
scale_app() {
    local replicas="$1"
    log "Scaling $WORKLOAD_TYPE to $replicas replicas..."

    kubectl scale "$WORKLOAD_TYPE" "$APP_NAME" -n "$NAMESPACE" --replicas="$replicas" > /dev/null

    if [ "$replicas" -eq 0 ]; then
        if [ "$WORKLOAD_TYPE" == "statefulset" ]; then
            kubectl wait --for=delete "pod/${APP_NAME}-0" -n "$NAMESPACE" --timeout=5m 2>/dev/null || true
        else
            kubectl wait --for=delete "pod" -l app="$APP_NAME" -n "$NAMESPACE" --timeout=5m 2>/dev/null || true
        fi
    else
        if [ "$WORKLOAD_TYPE" == "statefulset" ]; then
            kubectl wait --for=condition=ready "pod/${APP_NAME}-0" -n "$NAMESPACE" --timeout=10m 2>/dev/null || \
                error "Pod not ready"
        else
            kubectl wait --for=condition=ready "pod" -l app="$APP_NAME" -n "$NAMESPACE" --timeout=10m 2>/dev/null || \
                error "Pods not ready"
        fi
    fi

    log "Application scaled"
}

# Delete PVC
delete_pvc() {
    warn "Deleting PVC (DESTRUCTIVE)..."
    kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE" --timeout=30s 2>/dev/null || \
        warn "PVC may not exist or already deleted"
    log "PVC deleted"
}

# Configure ReplicationDestination for snapshot selection
configure_replication_dest() {
    local timestamp="$1"
    local previous="$2"

    if [ -n "$timestamp" ]; then
        log "Configuring ReplicationDestination for timestamp: $timestamp"
        kubectl patch replicationdestination "$REPLICATION_DEST" -n "$NAMESPACE" \
            --type=merge -p "{\"spec\":{\"kopia\":{\"restoreAsOf\":\"$timestamp\"}}}" > /dev/null
    elif [ -n "$previous" ]; then
        log "Configuring ReplicationDestination for previous offset: $previous"
        kubectl patch replicationdestination "$REPLICATION_DEST" -n "$NAMESPACE" \
            --type=merge -p "{\"spec\":{\"kopia\":{\"previous\":$previous}}}" > /dev/null
    else
        log "Using latest snapshot (no selection configured)"
    fi
}

# Get PVC size from workload
get_pvc_size() {
    local size=""

    if [ "$WORKLOAD_TYPE" == "statefulset" ]; then
        size=$(kubectl get statefulset "$APP_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.volumeClaimTemplates[0].spec.resources.requests.storage // empty' 2>/dev/null || echo "")
    else
        # For deployments, try to get from existing PVC if it exists
        size=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "")
    fi

    [ -z "$size" ] || [ "$size" == "null" ] && size="100Gi"
    echo "$size"
}

# Get access modes from workload
get_access_modes() {
    local modes="ReadWriteOnce"

    if [ "$WORKLOAD_TYPE" == "statefulset" ]; then
        local detected=$(kubectl get statefulset "$APP_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.volumeClaimTemplates[0].spec.accessModes[0] // "ReadWriteOnce"' 2>/dev/null || echo "ReadWriteOnce")
        [ -n "$detected" ] && modes="$detected"
    fi

    echo "$modes"
}

# Get storage class from workload
get_storage_class() {
    local storage_class="ceph-rbd"

    if [ "$WORKLOAD_TYPE" == "statefulset" ]; then
        local detected=$(kubectl get statefulset "$APP_NAME" -n "$NAMESPACE" -o json 2>/dev/null | \
            jq -r '.spec.volumeClaimTemplates[0].spec.storageClassName // "ceph-rbd"' 2>/dev/null || echo "ceph-rbd")
        [ -n "$detected" ] && [ "$detected" != "null" ] && storage_class="$detected"
    else
        local detected=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "ceph-rbd")
        [ -n "$detected" ] && [ "$detected" != "null" ] && storage_class="$detected"
    fi

    echo "$storage_class"
}

# Create PVC with Volume Populator
create_pvc_populator() {
    log "Creating PVC with Volume Populator pattern..."

    local size=$(get_pvc_size)
    local access_modes=$(get_access_modes)
    local storage_class=$(get_storage_class)

    log "PVC configuration: size=$size, accessModes=$access_modes, storageClass=$storage_class"

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
spec:
  accessModes: [$access_modes]
  dataSourceRef:
    kind: ReplicationDestination
    apiGroup: volsync.backube
    name: $REPLICATION_DEST
  resources:
    requests:
      storage: $size
  storageClassName: $storage_class
EOF

    log "PVC created - Volume Populator will automatically trigger restore"
    log "Waiting for PVC to be populated (5-15 min)..."

    # Wait for PVC to be bound
    local timeout=900 elapsed=0  # 15 minutes
    while [ $elapsed -lt $timeout ]; do
        sleep 5
        elapsed=$((elapsed + 5))

        local phase=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$phase" == "Bound" ]; then
            log "PVC bound and populated"
            return 0
        fi

        [ $((elapsed % 30)) -eq 0 ] && echo "  Waiting... ($((elapsed/60))m/15m) - Phase: $phase"
    done

    local phase=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$phase" == "Bound" ]; then
        log "PVC bound"
    else
        warn "PVC bind timeout - status: $phase"
        kubectl get pvc "$PVC_NAME" -n "$NAMESPACE"
        warn "Continuing anyway..."
    fi
}

# Clear snapshot selection
clear_snapshot_selection() {
    if [ -n "$TIMESTAMP" ] || [ -n "$PREVIOUS" ]; then
        log "Clearing snapshot selection from ReplicationDestination"
        kubectl patch replicationdestination "$REPLICATION_DEST" -n "$NAMESPACE" \
            --type=json -p='[
                {"op":"remove","path":"/spec/kopia/restoreAsOf"},
                {"op":"remove","path":"/spec/kopia/previous"}
            ]' 2>/dev/null || true
    fi
}

# Get pod name
get_pod_name() {
    if [ "$WORKLOAD_TYPE" == "statefulset" ]; then
        echo "${APP_NAME}-0"
    else
        kubectl get pods -n "$NAMESPACE" -l app="$APP_NAME" --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "${APP_NAME}-0"
    fi
}

# Verify restore
verify() {
    log "Verifying restore..."
    sleep 10

    local pod=$(get_pod_name)

    # If data path is specified, check it
    if [ -n "$DATA_PATH" ]; then
        kubectl exec -n "$NAMESPACE" "$pod" -c "$CONTAINER_NAME" -- test -d "$DATA_PATH" 2>/dev/null || \
            error "Data directory missing: $DATA_PATH"

        local files=$(kubectl exec -n "$NAMESPACE" "$pod" -c "$CONTAINER_NAME" -- find "$DATA_PATH" -type f 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        log "Files restored: $files"
    else
        log "Skipping data verification (DATA_PATH not set)"
    fi

    # Check logs for errors
    local error_count=$(kubectl logs -n "$NAMESPACE" "$pod" -c "$CONTAINER_NAME" --tail=50 2>/dev/null | grep -i error | wc -l | tr -d ' \n' || echo "0")
    error_count="${error_count:-0}"
    if [ "$error_count" -eq 0 ] 2>/dev/null; then
        log "No errors in logs"
    else
        warn "Found $error_count error(s) in logs"
    fi
}

# Main
main() {
    cd "$PROJECT_ROOT"

    local skip_verify=false dry_run=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --timestamp) [ -z "${2:-}" ] && error "--timestamp requires value"; TIMESTAMP="$2"; shift 2 ;;
            --previous) [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]] && error "--previous requires number"; PREVIOUS="$2"; shift 2 ;;
            --skip-verify) skip_verify=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *) error "Unknown option: $1 (see --help)" ;;
        esac
    done

    [ -z "$APP_NAME" ] && error "APP_NAME must be set (see --help)"
    [ -n "$TIMESTAMP" ] && [ -n "$PREVIOUS" ] && error "Use only --timestamp or --previous"

    detect_workload

    if [ "$dry_run" == "true" ]; then
        log "DRY RUN - Would execute:"
        echo "  1. Check prerequisites"
        echo "  2. Verify backup"
        echo "  3. Scale down $WORKLOAD_TYPE $APP_NAME"
        echo "  4. Delete PVC: $PVC_NAME"
        [ -n "$TIMESTAMP" ] && echo "  5. Configure ReplicationDestination for timestamp: $TIMESTAMP" || \
        [ -n "$PREVIOUS" ] && echo "  5. Configure ReplicationDestination for previous: $PREVIOUS" || \
        echo "  5. Use latest snapshot"
        echo "  6. Create PVC with dataSourceRef (Volume Populator)"
        echo "     - Restore happens automatically"
        echo "  7. Wait for PVC to be bound"
        echo "  8. Scale up $WORKLOAD_TYPE $APP_NAME"
        [ "$skip_verify" != "true" ] && echo "  9. Verify restore"
        exit 0
    fi

    log "=== Starting Restore (Volume Populator) ==="

    check_prereqs
    check_backup
    scale_app 0
    delete_pvc
    configure_replication_dest "$TIMESTAMP" "$PREVIOUS"
    create_pvc_populator
    clear_snapshot_selection
    scale_app 1
    [ "$skip_verify" != "true" ] && verify

    log "=== Restore Complete ==="
}

main "$@"

