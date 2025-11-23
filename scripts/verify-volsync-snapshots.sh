#!/bin/bash
# Script to verify VolSync snapshots are synced to Kopia repository
# Usage: ./verify-volsync-snapshots.sh [APP_NAME] [NAMESPACE]

set -euo pipefail

# Configuration
APP_NAME="${1:-paperless-ngx}"
NAMESPACE="${2:-default}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=== VolSync Snapshot Verification ==="
echo "App: $APP_NAME"
echo "Namespace: $NAMESPACE"
echo ""

# Check ReplicationSource
echo -e "${BLUE}1. Checking ReplicationSource...${NC}"
if ! kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: ReplicationSource '$APP_NAME' not found${NC}" >&2
    exit 1
fi

LAST_SYNC=$(kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "None")
echo "  Last sync: $LAST_SYNC"

# Check ReplicationDestination (this reads from repository)
echo ""
echo -e "${BLUE}2. Checking ReplicationDestination (reads from repository)...${NC}"
if ! kubectl get replicationdestination "${APP_NAME}-dst" -n "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}Warning: ReplicationDestination '${APP_NAME}-dst' not found${NC}"
    echo "  This means we can't verify snapshots from repository"
else
    LATEST_IMAGE=$(kubectl get replicationdestination "${APP_NAME}-dst" -n "$NAMESPACE" -o jsonpath='{.status.latestImage}' 2>/dev/null || echo "")
    if [ -n "$LATEST_IMAGE" ] && [ "$LATEST_IMAGE" != "null" ]; then
        echo -e "${GREEN}  ✓ Latest snapshot in repository: $LATEST_IMAGE${NC}"
        echo -e "${GREEN}  ✓ Snapshots are synced to repository!${NC}"
    else
        echo -e "${YELLOW}  ⚠ No latestImage found (may need to sync ReplicationDestination)${NC}"
        echo "  Triggering ReplicationDestination sync to refresh snapshot list..."
        kubectl patch replicationdestination "${APP_NAME}-dst" -n "$NAMESPACE" --type=merge -p '{"spec":{"trigger":{"manual":"verify-'"$(date +%s)"'"}}}'
        echo "  Waiting 30s for sync..."
        sleep 30
        LATEST_IMAGE=$(kubectl get replicationdestination "${APP_NAME}-dst" -n "$NAMESPACE" -o jsonpath='{.status.latestImage}' 2>/dev/null || echo "")
        if [ -n "$LATEST_IMAGE" ] && [ "$LATEST_IMAGE" != "null" ]; then
            echo -e "${GREEN}  ✓ Latest snapshot in repository: $LATEST_IMAGE${NC}"
            echo -e "${GREEN}  ✓ Snapshots are synced to repository!${NC}"
        else
            echo -e "${YELLOW}  ⚠ Still no snapshots found (may be empty or sync in progress)${NC}"
        fi
    fi
fi

# Check VolumeSnapshots (these are created during backup)
echo ""
echo -e "${BLUE}3. Checking VolumeSnapshots (created during backup)...${NC}"
SNAPSHOTS=$(kubectl get volumesnapshot -n "$NAMESPACE" | grep "volsync-$APP_NAME" | wc -l | tr -d ' ')
if [ "$SNAPSHOTS" -gt 0 ]; then
    echo -e "${GREEN}  ✓ Found $SNAPSHOTS VolumeSnapshot(s)${NC}"
    echo "  Recent snapshots:"
    kubectl get volumesnapshot -n "$NAMESPACE" | grep "volsync-$APP_NAME" | tail -3 | awk '{print "    " $1 " - " $2}'
else
    echo -e "${YELLOW}  ⚠ No VolumeSnapshots found${NC}"
fi

# Check repository secret
echo ""
echo -e "${BLUE}4. Checking repository configuration...${NC}"
REPO_SECRET="${APP_NAME}-volsync-secret"
if kubectl get secret "$REPO_SECRET" -n "$NAMESPACE" &>/dev/null; then
    REPO_TYPE=$(kubectl get secret "$REPO_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.KOPIA_REPOSITORY}' 2>/dev/null | base64 -d 2>/dev/null | cut -d: -f1 || echo "Unknown")
    echo "  Repository type: $REPO_TYPE"
    if [ "$REPO_TYPE" = "filesystem" ]; then
        REPO_PATH=$(kubectl get secret "$REPO_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.KOPIA_FS_PATH}' 2>/dev/null | base64 -d 2>/dev/null || echo "Unknown")
        echo "  Repository path: $REPO_PATH"
        echo -e "${GREEN}  ✓ Repository is filesystem-based (snapshots are persisted)${NC}"
    else
        echo "  Repository: $REPO_TYPE"
    fi
else
    echo -e "${RED}  ✗ Repository secret not found${NC}"
fi

# Summary
echo ""
echo "=== Summary ==="
echo "Kopia Architecture:"
echo "  • Snapshots are written DIRECTLY to repository (not just cache)"
echo "  • Cache is for performance only"
echo "  • Repository is the source of truth"
echo ""
echo "Verification:"
if [ -n "${LATEST_IMAGE:-}" ] && [ "${LATEST_IMAGE:-}" != "null" ] && [ -n "${LATEST_IMAGE:-}" ]; then
    echo -e "${GREEN}✓ Snapshots are confirmed in repository${NC}"
    echo "  Latest snapshot: $LATEST_IMAGE"
else
    echo -e "${YELLOW}⚠ Could not verify snapshots in repository${NC}"
    echo "  This may be normal if:"
    echo "    - No backups have run yet"
    echo "    - ReplicationDestination needs to sync"
    echo "    - Repository is empty"
fi

