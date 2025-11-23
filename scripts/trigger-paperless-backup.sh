#!/bin/bash
# Script to trigger paperless-ngx backup on-demand
# Usage: ./trigger-paperless-backup.sh [NAMESPACE]
# Example: ./trigger-paperless-backup.sh default

set -euo pipefail

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$PROJECT_ROOT/kubeconfig}"

# Configuration
NAMESPACE="${1:-default}"
APP_NAME="paperless-ngx"
CONTAINER_NAME="backup"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Paperless-ngx On-Demand Backup ==="
echo "Namespace: $NAMESPACE"
echo "App: $APP_NAME"
echo ""

# Find the paperless-ngx pod
POD=$(kubectl --kubeconfig="$KUBECONFIG" get pods -n "$NAMESPACE" -l app.kubernetes.io/name=paperless-ngx -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD" ]; then
    echo -e "${RED}Error: Paperless-ngx pod not found in namespace '$NAMESPACE'${NC}" >&2
    exit 1
fi

# Check if pod is running
POD_STATUS=$(kubectl --kubeconfig="$KUBECONFIG" get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [ "$POD_STATUS" != "Running" ]; then
    echo -e "${YELLOW}Warning: Pod '$POD' is not in Running state (current: $POD_STATUS)${NC}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if backup container exists
if ! kubectl --kubeconfig="$KUBECONFIG" get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' | grep -q "$CONTAINER_NAME"; then
    echo -e "${RED}Error: Backup container '$CONTAINER_NAME' not found in pod '$POD'${NC}" >&2
    echo "Available containers:"
    kubectl --kubeconfig="$KUBECONFIG" get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | sed 's/^/  - /'
    exit 1
fi

echo -e "${GREEN}✓ Found pod: $POD${NC}"
echo ""

# Run the backup command
echo "Executing backup command in backup container..."
echo "---"
echo ""

kubectl --kubeconfig="$KUBECONFIG" exec "$POD" -n "$NAMESPACE" -c "$CONTAINER_NAME" -- \
    /bin/bash -c '
    cd /usr/src/paperless/src
    python3 manage.py document_exporter --use-folder-prefix --compare-checksums --no-color --skip-checks /backup
    '

EXIT_CODE=$?

echo ""
echo "---"
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Backup completed successfully!${NC}"
else
    echo -e "${RED}✗ Backup failed with exit code: $EXIT_CODE${NC}" >&2
fi

exit $EXIT_CODE

