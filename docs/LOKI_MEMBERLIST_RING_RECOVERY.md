# Loki Memberlist Ring Recovery - January 2026

## Summary

**Service**: Loki (log aggregation)
**Issue**: Pod stuck in restart loop due to stale memberlist ring entry
**Root Cause**: Abrupt node reboot (PVE2 outage) left stale instance in memberlist ring
**Resolution**: Full deployment restart to clear memberlist state

## Timeline

| Time (2026-01-18) | Event                                                        |
|-------------------|--------------------------------------------------------------|
| ~15:22:00         | Node `talos-prod-2` rebooted due to PVE2 outage              |
| ~15:22:02         | Loki pod on talos-prod-2 terminated without clean ring leave |
| ~11:49:05         | New pod `loki-7cf7c89cf4-c9m2g` created (before reboot)      |
| Ongoing           | Pod stuck in restart loop (23 restarts over ~4 hours)        |
| ~15:55:30         | Full restart applied (scale 0 → 3)                           |
| ~15:57:47         | Memberlist cluster formed with 3 healthy nodes               |

## Symptoms

- One Loki pod continuously restarting (0/1 Ready)
- Other 2 Loki pods healthy and running
- Startup probe failing with HTTP 503
- Log ingestion partially working (2/3 replicas)

### Error in Pod Logs

```text
level=warn caller=lifecycler.go:298 component=ingester
  msg="found an existing instance(s) with a problem in the ring,
  this instance cannot become ready until this problem is resolved.
  The /ring http endpoint on the distributor (or single binary) provides visibility into the ring."
  ring=ingester err="instance 10.224.2.94:9095 past heartbeat timeout"
```

### Key Observation

The stale IP `10.224.2.94` belonged to a Loki pod that was running on `talos-prod-2` before the node rebooted. The pod was terminated without cleanly leaving the memberlist ring.

## Root Cause Analysis

### Loki's Memberlist Ring

Loki uses [memberlist](https://github.com/hashicorp/memberlist) for distributed coordination in HA mode. Each Loki instance:

1. Joins the memberlist cluster on startup
2. Sends heartbeats to other members
3. Should gracefully leave the ring on shutdown (SIGTERM)
4. Gets evicted after `heartbeat_timeout` (30s) if no heartbeats received

### What Happened

1. **PVE2 hypervisor crashed** → Proxmox node unresponsive
2. **talos-prod-2 VM rebooted** → Kubernetes node went NotReady
3. **Loki pod terminated abruptly** → No graceful memberlist leave
4. **Stale entry persisted** → Other pods still had `10.224.2.94` in their ring state
5. **New pods blocked** → Can't become ready due to `heartbeat_timeout` check

### Why Rolling Restart Failed

A rolling restart doesn't work because:

1. New pod starts and joins memberlist
2. New pod discovers stale entry `10.224.2.94` in ring (from healthy pods)
3. New pod blocks waiting for stale entry to be resolved
4. Startup probe times out after 10 minutes (60 failures × 10s period)
5. Pod gets killed, cycle repeats
6. Healthy pods never get replaced (new pod can't become ready first)

### Configuration Context

```yaml
# From loki-configmap
common:
  replication_factor: 3
  ring:
    kvstore:
      store: memberlist
    heartbeat_timeout: 30s
    heartbeat_period: 5s
```

With `replication_factor: 3`, Loki requires **at least 2 live replicas** to accept writes. The stale entry in the ring confuses the health check.

## Resolution

### Fix Applied

**Full deployment restart** to clear memberlist state across all pods:

```bash
# Scale down to 0 (terminate all pods)
kubectl scale deployment loki -n observability --replicas=0

# Wait for all pods to terminate
kubectl get pods -n observability -l app.kubernetes.io/name=loki -w

# Scale back up to 3
kubectl scale deployment loki -n observability --replicas=3
```

### Result

```text
NAME                    READY   STATUS    RESTARTS   AGE   NODE
loki-74d9967857-4h7mh   1/1     Running   0          104s  talos-prod-1
loki-74d9967857-8dvk7   1/1     Running   0          104s  talos-prod-2
loki-74d9967857-gv6t2   1/1     Running   0          104s  talos-prod-3
```

All 3 pods started fresh, formed a new memberlist ring with correct entries, and became healthy.

## Mitigation Strategies

### 1. Already Configured: Reduced Heartbeat Timeout

The Loki config already has:

```yaml
ring:
  heartbeat_timeout: 30s  # Reduced from default 1m
  heartbeat_period: 5s    # More frequent heartbeats
```

This helps detect failed members faster, but doesn't prevent the issue entirely.

### 2. Consider: Increase Startup Probe Tolerance

Current startup probe gives 10 minutes (60 × 10s). For memberlist recovery, this may not be enough if the ring takes time to converge.

```yaml
# Current
startupProbe:
  failureThreshold: 60
  periodSeconds: 10
  # Total: 600s (10 min)

# Alternative: Give more time for ring to self-heal
startupProbe:
  failureThreshold: 90
  periodSeconds: 10
  # Total: 900s (15 min)
```

### 3. Alternative: Use DNS-Based Discovery

Instead of memberlist, Loki can use Consul, etcd, or multi-replica DNS. However, memberlist is simpler for small clusters and doesn't require additional infrastructure.

### 4. Runbook: When to Full Restart

**Trigger a full restart if:**

- One or more Loki pods stuck in restart loop
- Logs show "instance X past heartbeat timeout"
- The stale IP doesn't match any current pod IPs
- Waiting >15 minutes hasn't self-healed

**Command:**

```bash
kubectl rollout restart deployment loki -n observability
# If that doesn't work (pods can't become ready):
kubectl scale deployment loki -n observability --replicas=0
sleep 30
kubectl scale deployment loki -n observability --replicas=3
```

## Prevention

### Node Drain Before Maintenance

When possible, drain nodes gracefully before maintenance:

```bash
kubectl drain talos-prod-2 --ignore-daemonsets --delete-emptydir-data
```

This gives pods time to gracefully leave the memberlist ring.

### PodDisruptionBudget

The Loki deployment has `replicas: 3` and the PDB should allow gradual rollouts:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: loki
  namespace: observability
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: loki
```

**Note:** PDB doesn't help with unexpected node failures, only voluntary disruptions.

## Diagnostic Commands

```bash
# Check Loki pod status
kubectl get pods -n observability -l app.kubernetes.io/name=loki -o wide

# Check for ring issues in logs
kubectl logs -n observability -l app.kubernetes.io/name=loki --tail=50 | grep -i ring

# Check memberlist service endpoints
kubectl get endpoints loki-memberlist -n observability -o yaml

# Check deployment status
kubectl get deployment loki -n observability

# Force restart if needed
kubectl scale deployment loki -n observability --replicas=0
kubectl scale deployment loki -n observability --replicas=3
```

## Related Issues

- **PVE2 Crash Investigation**: [PVE2_CRASH_INVESTIGATION.md](PVE2_CRASH_INVESTIGATION.md)
- **PVE2 NVMe Replacement**: [PVE2_NVME_REPLACEMENT_GUIDE.md](PVE2_NVME_REPLACEMENT_GUIDE.md)

## Document History

- **Created**: 2026-01-18
- **Author**: Home-ops automation
- **Incident Duration**: ~4 hours (partial degradation, 2/3 replicas operational)
