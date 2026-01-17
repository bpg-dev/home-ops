# Alertmanager Silence Management

## Overview

This document describes how to manage Alertmanager silences in the Kubernetes cluster, including creating, viewing, and expiring silences for expected maintenance windows or known issues.

## ZFS Pool Degradation Silence (pve2)

### Background

During NVMe disk replacement on Proxmox host `pve2.internal` (192.168.1.82), the ZFS pool `rpool` enters a degraded state. This triggers a critical alert `ZfsUnexpectedPoolState` which is expected and safe during the maintenance window.

**Alert Details:**

- **Alert Name:** `ZfsUnexpectedPoolState`
- **Instance:** `192.168.1.82:9100` (pve2)
- **Severity:** Critical
- **Condition:** `node_zfs_zpool_state{state!="online"} > 0`

### Creating the Silence

**Duration:** 20 days (480 hours)
**Created:** 2026-01-08
**Expires:** ~2026-01-28

**Method 1: Using the provided script (recommended)**

```bash
cd /path/to/home-ops
./scripts/silence-zfs-pve2.sh
```

**Method 2: Manual execution**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence add \
    alertname=ZfsUnexpectedPoolState \
    instance=192.168.1.82:9100 \
    --comment="ZFS pool degradation on pve2 expected during NVMe replacement - silenced for 20 days" \
    --duration=480h \
    --alertmanager.url=http://localhost:9093
```

### Viewing Active Silences

**List all active silences:**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query \
  --alertmanager.url=http://localhost:9093
```

**View specific silence by ID:**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query <SILENCE_ID> \
  --alertmanager.url=http://localhost:9093
```

**Filter by alert name:**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query \
  --filter alertname=ZfsUnexpectedPoolState \
  --alertmanager.url=http://localhost:9093
```

### Removing the Silence

Once the NVMe replacement is complete and the ZFS pool is back online, expire the silence:

**Step 1: Get the silence ID**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query \
  --filter alertname=ZfsUnexpectedPoolState \
  --alertmanager.url=http://localhost:9093
```

**Step 2: Expire the silence**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence expire <SILENCE_ID> \
  --alertmanager.url=http://localhost:9093
```

### Verification

**Check if the alert is still firing (should return empty after silence):**

```bash
kubectl exec -n observability prometheus-kube-prometheus-stack-0 -c prometheus -- \
  curl -s "http://localhost:9090/api/v1/alerts" | \
  jq -r '.data.alerts[] | select(.labels.alertname == "ZfsUnexpectedPoolState" and .state == "firing")'
```

**Check ZFS pool status on pve2:**

```bash
ssh root@192.168.1.82 zpool status rpool
```

Expected output after replacement:

```
  pool: rpool
 state: ONLINE
  scan: scrub repaired 0B in ... with 0 errors
```

---

## General Alertmanager Silence Commands

### Creating Silences

**Basic syntax:**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence add \
    <matcher1=value1> \
    <matcher2=value2> \
    --comment="Reason for silence" \
    --duration=<duration> \
    --alertmanager.url=http://localhost:9093
```

**Duration examples:**

- `1h` - 1 hour
- `24h` - 1 day
- `168h` - 1 week
- `480h` - 20 days
- `720h` - 30 days

**Matcher examples:**

- `alertname=KubePodCrashLooping`
- `namespace=default`
- `pod=paperless-ngx-0`
- `severity=warning`
- `instance=192.168.1.82:9100`

**Using regex matchers:**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence add \
    'alertname=~"Kube.*"' \
    namespace=default \
    --comment="Silence all Kube* alerts in default namespace" \
    --duration=2h \
    --alertmanager.url=http://localhost:9093
```

### Managing Silences

**List all silences (active and expired):**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query \
  --expired \
  --alertmanager.url=http://localhost:9093
```

**Update a silence (extend duration):**

Silences cannot be modified. You must expire the old one and create a new one:

```bash
# Expire old silence
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence expire <OLD_SILENCE_ID> \
  --alertmanager.url=http://localhost:9093

# Create new silence with updated duration
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence add ... --duration=<new_duration>
```

### Web UI Access

Alertmanager has a web UI for managing silences:

**Port-forward to access locally:**

```bash
kubectl port-forward -n observability svc/alertmanager-operated 9093:9093
```

Then access: <http://localhost:9093>

**Create silence via UI:**

1. Navigate to <http://localhost:9093/#/silences>
2. Click "New Silence"
3. Fill in matchers, duration, and comment
4. Click "Create"

---

## Best Practices

### When to Use Silences

✅ **Good use cases:**

- Planned maintenance windows
- Known degraded states during repairs
- Testing or deployment activities
- Investigating alerts that are known issues

❌ **Avoid silencing:**

- Alerts you don't understand
- Persistent issues that should be fixed
- Critical alerts without a specific reason
- Indefinite/very long silences (>30 days)

### Silence Documentation

**Always include:**

1. Clear comment explaining why the silence was created
2. Expected duration
3. Reference to related issue/maintenance ticket if applicable
4. Name/contact of person who created it

**Example good comment:**

```
"ZFS pool degradation on pve2 expected during NVMe replacement -
silenced for 20 days. See docs/PVE2_NVME_REPLACEMENT_GUIDE.md.
Contact: ops-team, Created: 2026-01-08"
```

### Silence Lifecycle

1. **Create:** Use specific matchers, reasonable duration
2. **Document:** Update runbooks/docs with silence details
3. **Monitor:** Verify the underlying issue is being addressed
4. **Review:** Check active silences weekly
5. **Expire:** Remove silence once issue is resolved
6. **Clean up:** Remove expired silences older than 30 days

### Regular Maintenance

**Weekly review of active silences:**

```bash
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query \
  --alertmanager.url=http://localhost:9093 | \
  grep -E "Expires|Comment"
```

Check for:

- Silences that should have been expired
- Silences approaching expiration that need extension
- Silences with unclear comments

---

## Troubleshooting

### Silence Not Working

**Check if silence matches the alert:**

```bash
# Get alert labels
kubectl exec -n observability prometheus-kube-prometheus-stack-0 -c prometheus -- \
  curl -s "http://localhost:9090/api/v1/alerts" | \
  jq '.data.alerts[] | select(.labels.alertname == "YourAlertName")'

# Compare with silence matchers
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query <SILENCE_ID>
```

All silence matchers must match the alert labels exactly.

### Alert Still Showing in Prometheus

Silences are managed by Alertmanager, not Prometheus. The alert will still show as "firing" in Prometheus but will be suppressed in Alertmanager and won't send notifications.

### Cannot Connect to Alertmanager

**Verify Alertmanager is running:**

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=alertmanager
```

**Check Alertmanager service:**

```bash
kubectl get svc -n observability alertmanager-operated
```

---

## Files

- **Silence script:** `scripts/silence-zfs-pve2.sh`
- **ConfigMap documentation:** `kubernetes/apps/observability/kube-prometheus-stack/app/silence-zfs-pve2.yaml`
- **This guide:** `docs/ALERTMANAGER_SILENCE_MANAGEMENT.md`
- **Related:** `docs/PVE2_NVME_REPLACEMENT_GUIDE.md`

---

## References

- [Alertmanager Documentation](https://prometheus.io/docs/alerting/latest/alertmanager/)
- [amtool Documentation](https://github.com/prometheus/alertmanager#amtool)
- [Silence Configuration](https://prometheus.io/docs/alerting/latest/configuration/#silence-config)
