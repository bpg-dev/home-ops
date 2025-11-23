# Emergency Restore Runbook

**Time:** 10-20 minutes | **Method:** Volume Populator (automatic)

---

## 🚀 Quick Restore (Latest Snapshot)

**Copy and paste - replace `<workload-name>`:**

```bash
export KUBECONFIG=./kubeconfig
export APP_NAME=<workload-name>
./scripts/restore-volsync-populator.sh
```

**Example:**
```bash
export KUBECONFIG=./kubeconfig
export APP_NAME=paperless-ngx
./scripts/restore-volsync-populator.sh
```

**Wait 10-20 minutes** (script shows progress). Done.

---

## ⏰ Restore from Specific Time

**If you need data from before a specific time:**

```bash
export KUBECONFIG=./kubeconfig
export APP_NAME=<workload-name>
./scripts/restore-volsync-populator.sh --timestamp 2025-11-22T21:12:06Z
```

**Find available snapshots:**
```bash
kubectl get volumesnapshot -n <namespace> \
  -l volsync.backube/replicationsource=<app-name> \
  --sort-by=.metadata.creationTimestamp
```

---

## What Happens

1. Stops application
2. Deletes current PVC (⚠️ destructive)
3. Creates new PVC → **restore happens automatically** (5-15 min)
4. Starts application with restored data

**Just wait. Script handles everything.**

---

## ✅ Verify Restore

```bash
kubectl get pvc <app-name> -n <namespace>    # Should show "Bound"
kubectl get pod <app-name>-0 -n <namespace>  # Should show "Running"
```

**Check backup exists first:**
```bash
kubectl get replicationsource <app-name> -n <namespace>
```

---

## 🔧 Troubleshooting

**Script stuck? Check status:**
```bash
kubectl get pvc <app-name> -n <namespace>
kubectl describe pvc <app-name> -n <namespace>
kubectl logs -n <namespace> -l volsync.backube/replicationdestination=<app-name>-dst
```

**Need to abort? (Ctrl+C, then):**
```bash
kubectl scale statefulset <app-name> -n <namespace> --replicas=1
kubectl delete pvc <app-name> -n <namespace>  # If restore failed
```

---

## Common Workloads

**paperless-ngx:**
```bash
export KUBECONFIG=./kubeconfig
export APP_NAME=paperless-ngx
./scripts/restore-volsync-populator.sh
```

**PostgreSQL (postgres-1):**
```bash
export KUBECONFIG=./kubeconfig
export APP_NAME=postgres-1
export NAMESPACE=postgresql-system
./scripts/restore-volsync-populator.sh
```

---

## ⚠️ Important

- **DESTRUCTIVE:** Current data will be replaced with backup
- **Downtime:** Application down for 10-20 minutes
- **Safe:** Backup data is not affected
- **Repeatable:** Can run script again if it fails

---

## ✅ Quick Checklist

Before running:
- [ ] Backup exists: `kubectl get replicationsource <app-name> -n <namespace>`
- [ ] Correct `APP_NAME` and `NAMESPACE`
- [ ] `kubeconfig` in project root

After restore:
- [ ] Check pod: `kubectl get pod <app-name>-0 -n <namespace>`
- [ ] Test application functionality

---

## 📚 More Help

- [Volume Populator Restore Guide](./VOLSYNC_POPULATOR_RESTORE.md) - Complete documentation

