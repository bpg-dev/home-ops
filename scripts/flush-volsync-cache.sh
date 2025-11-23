#!/bin/bash
# Script to flush VolSync Kopia cache
# Note: Kopia automatically syncs to repository, but this can force cache refresh
# Usage: ./flush-volsync-cache.sh [APP_NAME] [NAMESPACE]

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

echo "=== VolSync Kopia Cache Flush ==="
echo "App: $APP_NAME"
echo "Namespace: $NAMESPACE"
echo ""

# Important note
echo -e "${YELLOW}Important:${NC}"
echo "  • Kopia snapshots are written DIRECTLY to repository"
echo "  • Cache is only for performance (frequently accessed data)"
echo "  • Clearing cache does NOT affect snapshots in repository"
echo "  • Cache will be rebuilt automatically on next access"
echo ""

# Check ReplicationSource
if ! kubectl get replicationsource "$APP_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: ReplicationSource '$APP_NAME' not found${NC}" >&2
    exit 1
fi

# Method 1: Delete cache PVC (if cleanupCachePVC is true, it will be recreated)
echo -e "${BLUE}Method 1: Checking cache PVC...${NC}"
CACHE_PVC=$(kubectl get pvc -n "$NAMESPACE" | grep "volsync-src-$APP_NAME.*cache" | awk '{print $1}' | head -1 || echo "")
if [ -n "$CACHE_PVC" ]; then
    echo "  Found cache PVC: $CACHE_PVC"
    echo -e "${YELLOW}  Note: Deleting cache PVC will force cache rebuild${NC}"
    read -p "  Delete cache PVC? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "  Deleting cache PVC..."
        kubectl delete pvc "$CACHE_PVC" -n "$NAMESPACE"
        echo -e "${GREEN}  ✓ Cache PVC deleted (will be recreated on next backup)${NC}"
    else
        echo "  Skipped"
    fi
else
    echo "  No cache PVC found (may be cleaned up or not created yet)"
fi

# Method 2: Trigger a new backup (this will use fresh cache)
echo ""
echo -e "${BLUE}Method 2: Trigger fresh backup (uses new cache)...${NC}"
read -p "  Trigger new backup to refresh cache? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "  Triggering backup..."
    TRIGGER_VALUE="flush-cache-$(date +%s)"
    kubectl patch replicationsource "$APP_NAME" -n "$NAMESPACE" --type=merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$TRIGGER_VALUE\"}}}"
    echo -e "${GREEN}  ✓ Backup triggered${NC}"
    echo "  This will create a fresh cache during backup"
else
    echo "  Skipped"
fi

# Method 3: Delete mover pods (they will be recreated with fresh cache)
echo ""
echo -e "${BLUE}Method 3: Restart mover pods (fresh cache on restart)...${NC}"
MOVERS=$(kubectl get pods -n "$NAMESPACE" | grep "volsync-src-$APP_NAME" | awk '{print $1}' || echo "")
if [ -n "$MOVERS" ]; then
    echo "  Found mover pods:"
    echo "$MOVERS" | while read pod; do
        echo "    - $pod"
    done
    read -p "  Delete mover pods to force cache refresh? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$MOVERS" | while read pod; do
            echo "  Deleting $pod..."
            kubectl delete pod "$pod" -n "$NAMESPACE" 2>/dev/null || true
        done
        echo -e "${GREEN}  ✓ Mover pods deleted (will be recreated with fresh cache)${NC}"
    else
        echo "  Skipped"
    fi
else
    echo "  No active mover pods found"
fi

echo ""
echo "=== Summary ==="
echo "Cache Flush Methods:"
echo "  1. Delete cache PVC - Forces complete cache rebuild"
echo "  2. Trigger new backup - Uses fresh cache during backup"
echo "  3. Restart mover pods - Fresh cache on pod restart"
echo ""
echo -e "${GREEN}Note: Snapshots in repository are NOT affected by cache operations${NC}"

