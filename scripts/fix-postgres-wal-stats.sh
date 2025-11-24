#!/bin/bash
# Script to fix NULL stats_reset error in CloudNativePG metrics exporter
# This script resets WAL statistics on all PostgreSQL instances to prevent
# the "converting NULL to string is unsupported" error in the metrics exporter
# Usage: ./fix-postgres-wal-stats.sh [NAMESPACE] [KUBECONFIG]
# Example: ./fix-postgres-wal-stats.sh postgresql-system ./kubeconfig

set -euo pipefail

# Configuration
NAMESPACE="${1:-postgresql-system}"
KUBECONFIG="${2:-./kubeconfig}"
CONTAINER="postgres"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=== PostgreSQL WAL Statistics Reset ==="
echo "Namespace: $NAMESPACE"
echo "Kubeconfig: $KUBECONFIG"
echo ""

# Check if kubeconfig exists
if [ ! -f "$KUBECONFIG" ]; then
    echo -e "${RED}Error: Kubeconfig file not found: $KUBECONFIG${NC}" >&2
    exit 1
fi

# Export KUBECONFIG
export KUBECONFIG

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: Namespace '$NAMESPACE' not found${NC}" >&2
    exit 1
fi

# Get all PostgreSQL pods
echo -e "${BLUE}Finding PostgreSQL pods in namespace '$NAMESPACE'...${NC}"
PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$PODS" ]; then
    # Try alternative label selector
    PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=~"postgres-.*")].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "$PODS" ]; then
    echo -e "${RED}Error: No PostgreSQL pods found in namespace '$NAMESPACE'${NC}" >&2
    exit 1
fi

# Convert to array
read -ra POD_ARRAY <<< "$PODS"
TOTAL_PODS=${#POD_ARRAY[@]}

echo -e "${GREEN}Found $TOTAL_PODS PostgreSQL pod(s): ${POD_ARRAY[*]}${NC}"
echo ""

# Process each pod
SUCCESS_COUNT=0
FAILED_PODS=()

for pod in "${POD_ARRAY[@]}"; do
    echo -e "${BLUE}Processing pod: $pod${NC}"

    # Check if pod is running
    POD_STATUS=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$POD_STATUS" != "Running" ]; then
        echo -e "${YELLOW}  ⚠ Skipping pod '$pod' (status: $POD_STATUS)${NC}"
        continue
    fi

    # Check current stats_reset value
    echo "  Checking current stats_reset value..."
    CURRENT_VALUE=$(kubectl exec -n "$NAMESPACE" "$pod" -c "$CONTAINER" -- \
        psql -U postgres -d postgres -t -c "SELECT stats_reset FROM pg_stat_wal;" 2>/dev/null | tr -d '[:space:]' || echo "")

    if [ -z "$CURRENT_VALUE" ] || [ "$CURRENT_VALUE" = "" ]; then
        echo -e "${YELLOW}  ⚠ stats_reset is NULL (this is the issue we're fixing)${NC}"
    else
        echo -e "${GREEN}  ✓ Current stats_reset: $CURRENT_VALUE${NC}"
    fi

    # Reset WAL statistics
    echo "  Resetting WAL statistics..."
    if kubectl exec -n "$NAMESPACE" "$pod" -c "$CONTAINER" -- \
        psql -U postgres -d postgres -c "SELECT pg_stat_reset_shared('wal');" &>/dev/null; then
        echo -e "${GREEN}  ✓ WAL statistics reset successfully${NC}"

        # Verify the fix
        sleep 1
        NEW_VALUE=$(kubectl exec -n "$NAMESPACE" "$pod" -c "$CONTAINER" -- \
            psql -U postgres -d postgres -t -c "SELECT stats_reset FROM pg_stat_wal;" 2>/dev/null | tr -d '[:space:]' || echo "")

        if [ -n "$NEW_VALUE" ] && [ "$NEW_VALUE" != "" ]; then
            echo -e "${GREEN}  ✓ Verified: stats_reset is now set to: $NEW_VALUE${NC}"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo -e "${YELLOW}  ⚠ Warning: stats_reset is still NULL after reset${NC}"
            FAILED_PODS+=("$pod")
        fi
    else
        echo -e "${RED}  ✗ Failed to reset WAL statistics${NC}" >&2
        FAILED_PODS+=("$pod")
    fi

    echo ""
done

# Summary
echo "=== Summary ==="
echo -e "${GREEN}Successfully processed: $SUCCESS_COUNT/$TOTAL_PODS pod(s)${NC}"

if [ ${#FAILED_PODS[@]} -gt 0 ]; then
    echo -e "${RED}Failed pods: ${FAILED_PODS[*]}${NC}" >&2
    exit 1
else
    echo -e "${GREEN}✓ All pods processed successfully!${NC}"
    echo ""
    echo "The metrics exporter should no longer show errors about NULL stats_reset."
    echo "Note: This issue may recur on new replicas until CloudNativePG fixes the exporter."
    exit 0
fi


