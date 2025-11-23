# VolSync Restore Using Volume Populator

## Overview

This guide explains how to restore VolSync-backed workloads using the **Volume Populator pattern** - the simplest and most straightforward restore method.

## What is Volume Populator?

Volume Populator is a Kubernetes feature that automatically populates a PVC when you create it with a `dataSourceRef` pointing to a data source. With VolSync, you create a PVC that references a `ReplicationDestination`, and Kubernetes automatically triggers the restore and populates the PVC.

**No manual restore triggers needed. No waiting for VolumeSnapshots. Just create the PVC and it happens automatically.**

## Prerequisites

- Kubernetes 1.22+ with `AnyVolumeDataSource` feature gate enabled (enabled by default in 1.24+)
- VolSync operator installed
- ReplicationDestination configured for your workload
- Backups exist (check with `kubectl get replicationsource <app-name> -n <namespace>`)

## Quick Start

### Restore from Latest Snapshot

```bash
APP_NAME=paperless-ngx ./scripts/restore-volsync-populator.sh
```

### Restore from Specific Timestamp

```bash
APP_NAME=paperless-ngx DATA_PATH=/library/data \
  ./scripts/restore-volsync-populator.sh --timestamp 2025-11-22T21:12:06Z
```

### Restore from Previous Snapshot

```bash
APP_NAME=paperless-ngx \
  ./scripts/restore-volsync-populator.sh --previous 1
```

## How It Works

The restore process is simple:

1. **Scale down** - Stops the application
2. **Delete PVC** - Removes the existing volume
3. **Configure snapshot selection** (optional) - If you want a specific snapshot
4. **Create PVC with dataSourceRef** - Points to ReplicationDestination
5. **Automatic restore** - Kubernetes detects `dataSourceRef` and VolSync automatically restores
6. **Wait for bound** - PVC becomes ready when restore completes
7. **Scale up** - Application starts with restored data
8. **Verify** (optional) - Checks data and logs

## Step-by-Step Example

### 1. Check Available Backups

```bash
kubectl get replicationsource paperless-ngx -n default -o jsonpath='{.status.lastSyncTime}'
```

### 2. Run Restore

```bash
APP_NAME=paperless-ngx \
  DATA_PATH=/library/data \
  ./scripts/restore-volsync-populator.sh --timestamp 2025-11-22T21:12:06Z
```

### 3. Monitor Progress

The script will:
- Scale down the application
- Delete the PVC
- Create a new PVC with `dataSourceRef`
- Wait for the PVC to be bound (restore happens automatically)
- Scale up the application
- Verify the restore

### 4. Verify Results

```bash
# Check PVC status
kubectl get pvc paperless-ngx -n default

# Check pod status
kubectl get pod paperless-ngx-0 -n default

# Check data
kubectl exec -n default paperless-ngx-0 -c main -- ls -la /library/data
```

## Manual Method (Without Script)

If you prefer to do it manually:

### 1. Scale Down

```bash
kubectl scale statefulset paperless-ngx -n default --replicas=0
kubectl wait --for=delete pod/paperless-ngx-0 -n default --timeout=5m
```

### 2. Configure Snapshot Selection (Optional)

```bash
# For specific timestamp
kubectl patch replicationdestination paperless-ngx-dst -n default \
  --type=merge -p '{"spec":{"kopia":{"restoreAsOf":"2025-11-22T21:12:06Z"}}}'

# OR for previous snapshot
kubectl patch replicationdestination paperless-ngx-dst -n default \
  --type=merge -p '{"spec":{"kopia":{"previous":1}}}'
```

### 3. Delete PVC

```bash
kubectl delete pvc paperless-ngx -n default
```

### 4. Create PVC with Volume Populator

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-ngx
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  dataSourceRef:
    kind: ReplicationDestination
    apiGroup: volsync.backube
    name: paperless-ngx-dst
  resources:
    requests:
      storage: 100Gi
  storageClassName: ceph-rbd
EOF
```

### 5. Wait for PVC to be Bound

```bash
kubectl wait --for=condition=bound pvc/paperless-ngx -n default --timeout=15m
```

### 6. Scale Up

```bash
kubectl scale statefulset paperless-ngx -n default --replicas=1
kubectl wait --for=condition=ready pod/paperless-ngx-0 -n default --timeout=10m
```

### 7. Clear Snapshot Selection (If Set)

```bash
kubectl patch replicationdestination paperless-ngx-dst -n default \
  --type=json -p='[
    {"op":"remove","path":"/spec/kopia/restoreAsOf"},
    {"op":"remove","path":"/spec/kopia/previous"}
  ]'
```

## Snapshot Selection

### By Timestamp

Restore from a snapshot at or after a specific time:

```bash
--timestamp 2025-11-22T21:12:06Z
```

Format: RFC3339 (e.g., `2025-11-22T21:12:06Z`)

### By Previous Offset

Restore from the N-th previous snapshot:

```bash
--previous 0  # Latest snapshot
--previous 1  # Previous snapshot
--previous 2  # Two snapshots ago
```

## Script Options

```bash
./scripts/restore-volsync-populator.sh [options]

Options:
    --timestamp TS    Restore from snapshot at/after timestamp (RFC3339 format)
    --previous N      Restore from N-th previous snapshot (0=latest, 1=previous)
    --skip-verify     Skip verification step after restore
    --dry-run         Show what would be done without executing
    --help            Show this help

Environment Variables:
    APP_NAME          Application/workload name (required)
    NAMESPACE         Kubernetes namespace (default: default)
    DATA_PATH         Data directory path for verification (optional)
    KUBECONFIG        Path to kubeconfig (default: ./kubeconfig)
```

## Troubleshooting

### PVC Stuck in Pending

If the PVC remains in `Pending` state:

```bash
# Check PVC events
kubectl describe pvc paperless-ngx -n default

# Check ReplicationDestination status
kubectl get replicationdestination paperless-ngx-dst -n default -o yaml

# Check restore pod logs
kubectl logs -n default -l volsync.backube/replicationdestination=paperless-ngx-dst
```

### Restore Not Triggering

Ensure:
- ReplicationDestination exists: `kubectl get replicationdestination <app-name>-dst -n <namespace>`
- `dataSourceRef` correctly references the ReplicationDestination
- VolSync operator is running: `kubectl get pods -n volsync-system`

### Wrong Snapshot Restored

Clear the ReplicationDestination configuration and recreate PVC:

```bash
# Clear snapshot selection
kubectl patch replicationdestination paperless-ngx-dst -n default \
  --type=json -p='[
    {"op":"remove","path":"/spec/kopia/restoreAsOf"},
    {"op":"remove","path":"/spec/kopia/previous"}
  ]'

# Delete and recreate PVC
kubectl delete pvc paperless-ngx -n default
# Then create PVC again with Volume Populator
```

### PVC Creation Fails

Check:
- Storage class exists: `kubectl get storageclass ceph-rbd`
- PVC size matches workload requirements
- Namespace is correct

## Benefits

✅ **Simplest method** - Just create a PVC, restore happens automatically
✅ **No manual triggers** - No need to manually trigger restore
✅ **No VolumeSnapshot management** - Kubernetes handles everything
✅ **Atomic operation** - PVC creation and restore happen together
✅ **Native Kubernetes** - Uses built-in Volume Populator mechanism
✅ **Less error-prone** - Fewer manual steps means fewer mistakes


## Important Notes

1. **Snapshot Selection**: Configure ReplicationDestination's `restoreAsOf` or `previous` **before** creating the PVC. The restore will use whatever is configured at PVC creation time.

2. **PVC Creation Blocks**: The PVC will remain in `Pending` state until the restore completes. This can take 5-15 minutes depending on data size.

3. **Cleanup**: After restore, remember to clear the `restoreAsOf`/`previous` fields from ReplicationDestination to avoid using the same snapshot for future restores.

4. **Monitoring**: You can monitor the restore progress by watching the PVC status:
   ```bash
   kubectl get pvc paperless-ngx -n default -w
   ```

## Examples for Different Workloads

### StatefulSet (paperless-ngx)

```bash
APP_NAME=paperless-ngx \
  DATA_PATH=/library/data \
  ./scripts/restore-volsync-populator.sh --timestamp 2025-11-22T21:12:06Z
```

### Deployment

```bash
APP_NAME=my-app \
  NAMESPACE=my-namespace \
  DATA_PATH=/app/data \
  ./scripts/restore-volsync-populator.sh
```

### PostgreSQL (StatefulSet)

```bash
APP_NAME=postgres-1 \
  NAMESPACE=postgresql-system \
  ./scripts/restore-volsync-populator.sh --previous 1
```

## See Also

- [Emergency Restore Runbook](./EMERGENCY_RESTORE_RUNBOOK.md) - Quick reference for critical situations

