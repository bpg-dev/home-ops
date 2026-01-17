#!/usr/bin/env bash
# Silence ZFS pool degradation alert on pve2 during NVMe replacement
#
# Purpose: Suppress ZfsUnexpectedPoolState alerts while the ZFS mirror is degraded
#          during planned NVMe drive replacement on pve2 (192.168.1.82)
#
# Drive Being Replaced:
#   - Failing:     Kingston OM8PGP41024Q-A0 (/dev/nvme2n1p3)
#   - Replacement: Crucial P310 1TB
#
# When to Run:
#   - BEFORE starting physical drive replacement
#   - After running, the pool will be in degraded state without alerting
#
# When to Remove Silence:
#   - AFTER replacement is complete and pool has resilvered
#   - Use the "expire" command shown at the end of this script
#
# Related Documentation:
#   - docs/PVE2_NVME_REPLACEMENT_GUIDE.md    - Full replacement procedure
#   - docs/ALERTMANAGER_SILENCE_MANAGEMENT.md - Silence management guide
#
# Cleanup After Maintenance:
#   - Remove this script once replacement is complete
#   - Remove kubernetes/apps/observability/kube-prometheus-stack/app/silence-zfs-pve2.yaml
#   - Remove udev rule on pve2: rm /etc/udev/rules.d/99-block-faulty-nvme.rules

set -euo pipefail

KUBECONFIG="${KUBECONFIG:-./kubeconfig}"
DURATION="480h"  # 20 days
COMMENT="ZFS pool degradation on pve2 expected during NVMe replacement - silenced for 20 days"

echo "Creating Alertmanager silence for ZfsUnexpectedPoolState on pve2..."
echo "Duration: ${DURATION} (20 days)"
echo ""

kubectl --kubeconfig="${KUBECONFIG}" exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence add \
    alertname=ZfsUnexpectedPoolState \
    instance=192.168.1.82:9100 \
    --comment="${COMMENT}" \
    --duration="${DURATION}" \
    --alertmanager.url=http://localhost:9093

echo ""
echo "✅ Silence created successfully!"
echo ""
echo "To view all active silences:"
echo "  kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \\"
echo "    amtool silence query --alertmanager.url=http://localhost:9093"
echo ""
echo "To remove this silence early (get SILENCE_ID from query above):"
echo "  kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \\"
echo "    amtool silence expire <SILENCE_ID> --alertmanager.url=http://localhost:9093"
