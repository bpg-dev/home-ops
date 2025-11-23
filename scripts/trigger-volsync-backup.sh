#!/bin/bash
# Script to trigger and monitor VolSync backup
# Usage: ./trigger-volsync-backup.sh [APP_NAME] [NAMESPACE]
# Example: ./trigger-volsync-backup.sh paperless-ngx default

set -euo pipefail

# Configuration
APP_NAME="${1:-paperless-ngx}"
NAMESPACE="${2:-default}"
TIMEOUT="${3:-600}"  # 10 minutes default timeout
INTERVAL=10  # Check every 10 seconds

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== VolSync Backup Trigger and Monitor ==="
echo "App: $APP_NAME"
echo "Namespace: $NAMESPACE"
echo "Timeout: ${TIMEOUT}s"
echo ""

# Check if ReplicationSource exists
if ! kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: ReplicationSource '$APP_NAME' not found in namespace '$NAMESPACE'${NC}" >&2
    exit 1
fi

# Trigger manual backup
echo "Triggering manual backup..."
TRIGGER_VALUE="backup-$(date +%s)"
kubectl patch replicationsource "$APP_NAME" -n "$NAMESPACE" --type=merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$TRIGGER_VALUE\"}}}"
echo -e "${GREEN}✓ Backup triggered with value: $TRIGGER_VALUE${NC}"
echo ""

# Wait a moment for the trigger to be processed
sleep 5

# Monitor backup progress
echo "Monitoring backup progress..."
MAX_ITERATIONS=$((TIMEOUT / INTERVAL))
ITERATION=0
LAST_STATUS=""

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    # Get current status
    SYNCHRONIZING=$(kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Synchronizing")].status}' 2>/dev/null || echo "Unknown")
    LAST_MANUAL_SYNC=$(kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastManualSync}' 2>/dev/null || echo "")
    LAST_SYNC_TIME=$(kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "")
    NEXT_SYNC_TIME=$(kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nextSyncTime}' 2>/dev/null || echo "")

    # Check if backup completed
    if [ -n "$LAST_MANUAL_SYNC" ] && [ "$SYNCHRONIZING" != "True" ]; then
        echo ""
        echo -e "${GREEN}✓ Backup completed successfully!${NC}"
        echo "  Last manual sync: $LAST_MANUAL_SYNC"
        echo "  Last sync time: $LAST_SYNC_TIME"
        echo "  Next sync time: $NEXT_SYNC_TIME"

        # Get latest snapshot info
        LATEST_IMAGE=$(kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.latestImage}' 2>/dev/null || echo "N/A")
        if [ "$LATEST_IMAGE" != "N/A" ] && [ -n "$LATEST_IMAGE" ]; then
            echo "  Latest snapshot: $LATEST_IMAGE"
        fi

        # Show recent snapshots
        echo ""
        echo "Recent snapshots:"
        kubectl get volumesnapshot -n "$NAMESPACE" | grep "volsync-$APP_NAME" | tail -3 || echo "  No snapshots found"

        exit 0
    fi

    # Show progress
    STATUS_MSG="Synchronizing: $SYNCHRONIZING"
    if [ "$STATUS_MSG" != "$LAST_STATUS" ]; then
        if [ "$SYNCHRONIZING" = "True" ]; then
            echo -e "${YELLOW}[$ITERATION/$MAX_ITERATIONS] $STATUS_MSG${NC}"
        else
            echo "[$ITERATION/$MAX_ITERATIONS] $STATUS_MSG"
        fi

        # Check for mover pod
        MOVER_POD=$(kubectl get pods -n "$NAMESPACE" | grep "volsync-src-$APP_NAME" | head -1 | awk '{print $1}' || echo "")
        if [ -n "$MOVER_POD" ]; then
            POD_STATUS=$(kubectl get pod "$MOVER_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo "  Mover pod: $MOVER_POD ($POD_STATUS)"
        fi

        LAST_STATUS="$STATUS_MSG"
    fi

    sleep $INTERVAL
done

# Timeout reached
echo ""
echo -e "${RED}✗ Backup monitoring timed out after ${TIMEOUT}s${NC}" >&2
echo "Current status:"
kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" -o yaml | grep -A 20 "status:" | head -25
exit 1

