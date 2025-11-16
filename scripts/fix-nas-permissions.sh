#!/bin/bash
# Script to fix NFS permissions on TrueNAS SCALE for kopia
# Run this on the TrueNAS SCALE server (nas.internal) via SSH

set -euo pipefail

# Configuration
KOPIA_PATH="/mnt/tank/nfs/volsync-kopia"
KOPIA_UID=1000
KOPIA_GID=1000

echo "Fixing permissions for kopia NFS share..."

# Create directory if it doesn't exist
if [ ! -d "$KOPIA_PATH" ]; then
    echo "Creating directory: $KOPIA_PATH"
    mkdir -p "$KOPIA_PATH"
fi

# Set ownership to UID/GID 1000
echo "Setting ownership to UID $KOPIA_UID:GID $KOPIA_GID..."
chown -R "$KOPIA_UID:$KOPIA_GID" "$KOPIA_PATH"

# Set permissions (755 = rwxr-xr-x)
echo "Setting permissions to 755..."
chmod -R 755 "$KOPIA_PATH"

# Verify permissions
echo ""
echo "Verifying permissions:"
ls -ld "$KOPIA_PATH"
echo ""
echo "Contents (if any):"
ls -la "$KOPIA_PATH" | head -10

echo ""
echo "✅ Permissions fixed!"
echo ""
echo "Next steps:"
echo "1. Ensure the NFS share is configured in TrueNAS web UI:"
echo "   - Shares → Unix (NFS) Shares"
echo "   - Path: $KOPIA_PATH"
echo "   - Maproot User: root (or UID $KOPIA_UID)"
echo "   - Maproot Group: root (or GID $KOPIA_GID)"
echo "   - Authorized Networks: Your Kubernetes cluster subnet"
echo ""
echo "2. Restart the kopia pod in Kubernetes to pick up the changes"

