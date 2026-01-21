# Garage Multi-Node Migration Plan

## Goal

Convert Garage from single-node NFS deployment to 3-node cluster with per-node storage for resilience.

## Current State

- Single Deployment with `replication_factor=1`
- NFS storage from `nas.internal` (single point of failure)
- Recent database corruption incident required full rebuild

## Target State

- 3-node StatefulSet (one pod per Kubernetes node)
- Per-node storage via `openebs-hostpath`
- `replication_factor=2` (survives single node failure)
- Headless service for RPC peer discovery

---

## Data Migration Strategy

### Existing Data (as of 2026-01-21)

| Bucket | Key | Data Impact |
|--------|-----|-------------|
| `loki` | loki | Logs will regenerate automatically |
| `postgres-backups` | postgres-backup | pgBackRest creates new backups on schedule |
| `authentik-media` | authentik | User uploads - manual re-upload if needed |

### Approach: Fresh Start

The migration uses a **fresh start** approach:

1. **Old NFS storage** remains untouched (can be cleaned up later)
2. **New StatefulSet** creates empty PVCs on `openebs-hostpath`
3. **Buckets and keys** are recreated after cluster initialization
4. **Services auto-recover**:
   - Loki: Writes new logs immediately
   - pgBackRest: Creates backups on next scheduled run
   - Authentik: Users re-upload media as needed

### Why Not Migrate Data?

- All buckets were created today (2026-01-21) after recent recovery
- Garage's internal format ties data to specific node IDs
- Fresh start is cleaner and avoids potential corruption carry-over

---

## Phase 1: Storage Benchmarking

- [x] Create benchmark PVCs and pod (`kubernetes/apps/storage/garage/test/benchmark.yaml`)
- [x] Create benchmark README with fio commands (`kubernetes/apps/storage/garage/test/README.md`)
- [x] Apply benchmark resources
- [x] Run LMDB-like workload test (random 4K I/O)
- [x] Run data blocks test (sequential I/O)
- [x] Document results and confirm storage choice
- [x] Cleanup benchmark resources

### Benchmark Results (2025-01-21)

#### Test 1: Metadata Workload (Random 4K I/O, 70% read)

| Metric | `openebs-hostpath` | `ceph-rbd` | Winner |
|--------|-------------------|------------|--------|
| Read IOPS | **25,512** | 7,605 | hostpath (3.4x faster) |
| Read Latency | **757 μs** | 2,198 μs | hostpath (2.9x lower) |
| Write IOPS | **10,945** | 3,263 | hostpath (3.4x faster) |
| Write Latency | **1,157 μs** | 4,678 μs | hostpath (4x lower) |

#### Test 2: Data Blocks (Sequential 1M Write)

| Metric | `openebs-hostpath` | `ceph-rbd` | Winner |
|--------|-------------------|------------|--------|
| Write Bandwidth | 75 MB/s | **216 MB/s** | ceph (2.9x faster) |

#### Conclusion

**`openebs-hostpath` selected** - Metadata (LMDB) performance is the critical path for Garage. The 3-4x improvement in random I/O outweighs ceph's sequential write advantage since Garage chunks large objects anyway.

### Commands

```bash
# Apply benchmark resources
kubectl apply -f kubernetes/apps/storage/garage/test/benchmark.yaml

# Wait for pod
kubectl wait --for=condition=Ready pod/storage-bench -n storage --timeout=120s

# Exec into pod
kubectl exec -it -n storage storage-bench -- sh

# Test 1: LMDB-like workload (metadata) - random 4K I/O
fio --name=meta-ceph --directory=/ceph --size=1G --bs=4k \
    --rw=randrw --rwmixread=70 --ioengine=libaio --direct=1 \
    --numjobs=4 --iodepth=32 --runtime=60 --time_based

fio --name=meta-hostpath --directory=/hostpath --size=1G --bs=4k \
    --rw=randrw --rwmixread=70 --ioengine=libaio --direct=1 \
    --numjobs=4 --iodepth=32 --runtime=60 --time_based

# Test 2: Data blocks - sequential I/O
fio --name=data-ceph --directory=/ceph --size=2G --bs=1M \
    --rw=write --ioengine=libaio --direct=1 --numjobs=2 --runtime=60

fio --name=data-hostpath --directory=/hostpath --size=2G --bs=1M \
    --rw=write --ioengine=libaio --direct=1 --numjobs=2 --runtime=60

# Cleanup
kubectl delete -f kubernetes/apps/storage/garage/test/benchmark.yaml
```

---

## Phase 2: Implementation

- [x] Create headless service (`kubernetes/apps/storage/garage/app/service-headless.yaml`)
- [x] Update HelmRelease for StatefulSet with volumeClaimTemplates
- [x] Update kustomization.yaml to include headless service
- [x] Configure `replication_factor=2`
- [x] Configure bootstrap_peers for cluster discovery
- [x] Add podAntiAffinity to spread pods across nodes

### Files Modified

| File | Status |
|------|--------|
| `kubernetes/apps/storage/garage/app/helmrelease.yaml` | Done |
| `kubernetes/apps/storage/garage/app/service-headless.yaml` | Created |
| `kubernetes/apps/storage/garage/app/kustomization.yaml` | Done |

---

## Phase 3: Deployment

- [ ] Document current bucket/key configuration (backup)
- [ ] Suspend Flux kustomization
- [ ] Commit and push changes
- [ ] Resume Flux kustomization
- [ ] Wait for StatefulSet pods to be ready
- [ ] Initialize cluster layout

### Pre-Deployment Backup

```bash
# Export current bucket configuration
kubectl exec -n storage garage-0 -- garage bucket list
kubectl exec -n storage garage-0 -- garage key list

# Or via admin API (if old deployment still running)
kubectl run -n storage garage-export --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -H "Authorization: Bearer <ADMIN_TOKEN>" http://garage:3903/v1/bucket
```

### Deploy Commands

```bash
# Suspend Flux to prevent auto-reconciliation during changes
flux suspend kustomization garage

# Commit and push changes
git add -A && git commit -m "feat(garage): convert to multi-node StatefulSet"
git push

# Resume Flux
flux resume kustomization garage

# Watch deployment
kubectl get pods -n storage -l app.kubernetes.io/name=garage -w
```

### Initialize Cluster Layout

```bash
# Check node IDs (run after pods are ready)
kubectl exec -n storage garage-0 -- garage status

# Assign capacity to each node (100GB)
kubectl exec -n storage garage-0 -- garage layout assign -z dc1 -c 100G <node-0-id>
kubectl exec -n storage garage-0 -- garage layout assign -z dc1 -c 100G <node-1-id>
kubectl exec -n storage garage-0 -- garage layout assign -z dc1 -c 100G <node-2-id>

# Apply layout
kubectl exec -n storage garage-0 -- garage layout apply --version 1
```

---

## Phase 4: Bucket Recreation and Verification

- [ ] Recreate API keys (import from secrets)
- [ ] Recreate buckets
- [ ] Grant key permissions to buckets
- [ ] Check cluster health
- [ ] Verify all nodes connected
- [ ] Test S3 operations
- [ ] Restart dependent services

### 4.1 Get Admin Token

```bash
ADMIN_TOKEN=$(kubectl get secret -n storage garage -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d)
echo $ADMIN_TOKEN
```

### 4.2 Get Existing Credentials from Secrets

```bash
# Loki credentials
LOKI_KEY=$(kubectl get secret -n observability loki-secret -o jsonpath='{.data.S3_ACCESS_KEY_ID}' | base64 -d)
LOKI_SECRET=$(kubectl get secret -n observability loki-secret -o jsonpath='{.data.S3_SECRET_ACCESS_KEY}' | base64 -d)
echo "Loki: $LOKI_KEY"

# Postgres backup credentials
PG_KEY=$(kubectl get secret -n postgresql-system postgres-backup-credentials -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
PG_SECRET=$(kubectl get secret -n postgresql-system postgres-backup-credentials -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)
echo "Postgres: $PG_KEY"

# Authentik credentials
AUTH_KEY=$(kubectl get secret -n security authentik-config -o jsonpath='{.data.AUTHENTIK_STORAGE__MEDIA__S3__ACCESS_KEY}' | base64 -d)
AUTH_SECRET=$(kubectl get secret -n security authentik-config -o jsonpath='{.data.AUTHENTIK_STORAGE__MEDIA__S3__SECRET_KEY}' | base64 -d)
echo "Authentik: $AUTH_KEY"
```

### 4.3 Import API Keys

```bash
# Import Loki key
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"loki\", \"accessKeyId\": \"$LOKI_KEY\", \"secretAccessKey\": \"$LOKI_SECRET\"}" \
  http://garage:3903/v1/key/import

# Import Postgres backup key
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"postgres-backup\", \"accessKeyId\": \"$PG_KEY\", \"secretAccessKey\": \"$PG_SECRET\"}" \
  http://garage:3903/v1/key/import

# Import Authentik key
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"authentik\", \"accessKeyId\": \"$AUTH_KEY\", \"secretAccessKey\": \"$AUTH_SECRET\"}" \
  http://garage:3903/v1/key/import
```

### 4.4 Create Buckets

```bash
# Create loki bucket
LOKI_BUCKET=$(kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"globalAlias": "loki"}' \
  http://garage:3903/v1/bucket | jq -r '.id')
echo "Loki bucket: $LOKI_BUCKET"

# Create postgres-backups bucket
PG_BUCKET=$(kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"globalAlias": "postgres-backups"}' \
  http://garage:3903/v1/bucket | jq -r '.id')
echo "Postgres bucket: $PG_BUCKET"

# Create authentik-media bucket
AUTH_BUCKET=$(kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"globalAlias": "authentik-media"}' \
  http://garage:3903/v1/bucket | jq -r '.id')
echo "Authentik bucket: $AUTH_BUCKET"
```

### 4.5 Grant Key Permissions

```bash
# Grant loki key access to loki bucket
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"bucketId\": \"$LOKI_BUCKET\", \"accessKeyId\": \"$LOKI_KEY\", \"permissions\": {\"read\": true, \"write\": true, \"owner\": true}}" \
  http://garage:3903/v1/bucket/allow

# Grant postgres-backup key access to postgres-backups bucket
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"bucketId\": \"$PG_BUCKET\", \"accessKeyId\": \"$PG_KEY\", \"permissions\": {\"read\": true, \"write\": true, \"owner\": true}}" \
  http://garage:3903/v1/bucket/allow

# Grant authentik key access to authentik-media bucket
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"bucketId\": \"$AUTH_BUCKET\", \"accessKeyId\": \"$AUTH_KEY\", \"permissions\": {\"read\": true, \"write\": true, \"owner\": true}}" \
  http://garage:3903/v1/bucket/allow
```

### 4.6 Verify Cluster Health

```bash
# Check cluster health
kubectl run -n storage garage-check --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -H "Authorization: Bearer $ADMIN_TOKEN" http://garage:3903/v2/GetClusterHealth

# List buckets
kubectl run -n storage garage-check --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -H "Authorization: Bearer $ADMIN_TOKEN" http://garage:3903/v1/bucket

# List keys
kubectl run -n storage garage-check --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -H "Authorization: Bearer $ADMIN_TOKEN" http://garage:3903/v1/key
```

### 4.7 Restart Dependent Services

```bash
# Restart Loki to reconnect to new Garage
kubectl rollout restart deployment -n observability loki

# Verify Loki is writing
kubectl logs -n observability -l app.kubernetes.io/name=loki --tail=50 | grep -i "garage\|s3"
```

---

## Rollback

If issues occur:

```bash
# Revert git changes
git revert HEAD
git push

# Force reconcile
flux reconcile kustomization garage --with-source

# StatefulSet PVCs are retained - data preserved for debugging
```

---

## Storage Decision Summary

| Option | Pros | Cons |
|--------|------|------|
| `ceph-rbd` | Ceph-level replication, pod mobility | Network latency |
| `openebs-hostpath` | Lowest latency, local disk | Pod tied to node, no storage-level replication |

**Decision**: Using `openebs-hostpath` - With Garage's `replication_factor=2`, data is replicated at application level. Local storage provides better latency for LMDB metadata operations.

---

## Reference Documentation

- `docs/GARAGE_DATABASE_RECOVERY.md` - Bucket/key recreation procedures
- `docs/GARAGE_BUCKET_MANAGEMENT.md` - Bucket management guide
- `kubernetes/apps/storage/garage/test/README.md` - Benchmark instructions
