# Spegel High CPU/Network Investigation

## Date: January 2026

## Summary

Investigation into spegel (P2P container registry mirror) consuming excessive CPU and network bandwidth on `talos-prod-2`.

## Symptoms Observed

- One spegel pod (`spegel-xdqmv` on `talos-prod-2`) consuming **1.8+ CPU cores** vs ~250-300m on other nodes
- Sustained network TX of **~1.4 MB/s** from the problematic pod (vs <1 KB/s normally)
- Overall node network traffic elevated on all nodes due to P2P nature
- NAS traffic increase correlated with spegel CPU usage (network congestion affecting NFS)

## Root Cause

The node `talos-prod-2` had:
- **1,053 containerd content blobs** (vs ~772-817 on other nodes)
- **59 pods scheduled** (vs 44 and 22 on other nodes)
- **74% disk usage** on `/var` (vs 55-56% on other nodes)

The larger content store caused spegel to work harder tracking and advertising all the image digests via the libp2p DHT. This resulted in:
- Excessive memory allocation churn (~48GB allocated in minutes, 13,000+ GC cycles)
- High CPU from constant content scanning and P2P operations
- High network traffic from DHT advertisements and peer communication

## Metrics Before Fix

| Metric | talos-prod-1 | talos-prod-2 | talos-prod-3 |
|--------|-------------|--------------|--------------|
| Spegel CPU | 280m | **1800m+** | 250m |
| Spegel Network TX | ~0.8 MB/s | **1.4 MB/s** | ~0.8 MB/s |
| Content blobs | 817 | **1053** | 772 |
| Node disk usage | 56% | **74%** | 55% |
| Total node TX | ~1.5 MB/s | **~1.9 MB/s** | ~1.1 MB/s |

## Fix Applied

Added CPU resource limits to spegel HelmRelease:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## Results After Fix

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Spegel CPU (prod-2) | 1800m+ | 3-4m | **~99%** |
| Spegel Network TX | 1.4 MB/s | <2 KB/s | **~99%** |
| Node total TX (prod-1) | 1.5 MB/s | 0.43 MB/s | **71%** |
| Node total TX (prod-2) | 1.9 MB/s | 0.54 MB/s | **72%** |
| Node total TX (prod-3) | 1.1 MB/s | 0.26 MB/s | **76%** |

The fix reduced network traffic on **all nodes** because spegel is P2P - when one node churns, it causes increased traffic to/from all peers.

## Impact on NAS

The excessive spegel network traffic was:
1. Competing for bandwidth with NFS traffic to NAS (volsync backups)
2. Causing all spegel pods to respond with their own P2P traffic
3. Creating network congestion that affected NFS performance

After the fix, NAS-related traffic normalized as the network was no longer saturated by spegel P2P chatter.

## Key Learnings

1. **P2P amplification**: A single misbehaving P2P node affects all peers in the cluster
2. **Content store size matters**: More containerd blobs = more work for spegel
3. **CPU limits are essential**: Without limits, runaway processes can consume all available CPU
4. **Network follows CPU**: High CPU from network operations directly correlates with high bandwidth
5. **Monitor baseline traffic**: Unusual baseline (not just spikes) indicates issues

## Alerts Added

PrometheusRule alerts were added to catch this issue early:
- `SpegelHighCPU`: Sustained CPU usage >400m for 10 minutes
- `SpegelHighNetworkTX`: Sustained network TX >500 KB/s for 10 minutes
- `SpegelHighMemoryAllocation`: Memory allocation rate >1GB/min (leading indicator)

## Prevention

1. **Resource limits**: Always set CPU/memory limits on DaemonSets
2. **Monitor per-pod metrics**: Not just aggregate, but individual pod CPU/network
3. **Containerd garbage collection**: Periodically clean unused images
4. **Balanced pod distribution**: Avoid overloading single nodes with many pods

## Related Files

- HelmRelease: `kubernetes/apps/kube-system/spegel/app/helmrelease.yaml`
- Alerts: `kubernetes/apps/kube-system/spegel/app/prometheusrule.yaml`
