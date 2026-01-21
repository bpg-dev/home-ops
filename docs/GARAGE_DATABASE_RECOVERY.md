# Garage Database Recovery - January 2026

## Summary

**Service**: Garage (S3-compatible object storage)
**Issue**: Database corruption causing panic during merkle tree GC operations
**Root Cause**: Likely corrupted during PVE2 node crashes (abrupt power cycles)
**Resolution**: Fresh database initialization with bucket/key reconfiguration

## Symptoms

- Garage pod in CrashLoopBackOff (128+ restarts over 6 days)
- Panic in merkle tree code:
  ```
  panicked at /build/source/src/table/merkle.rs:219:10:
  called `Option::unwrap()` on a `None` value
  ```
- Downstream services failing (Loki, Postgres backups) due to S3 unavailability

## Investigation

### Initial Error

```text
======== PANIC (internal Garage error) ========
panicked at /build/source/src/table/merkle.rs:219:10:
called `Option::unwrap()` on a `None` value
```

This occurred during garbage collection of the merkle tree (used for data synchronization/repair).

### Storage Architecture

Garage stores data in two locations on NFS (`nas.internal`):

| Path | Purpose |
|------|---------|
| `/mnt/tank/nfs/garage/meta/` | Metadata database (lmdb), snapshots, node keys |
| `/mnt/tank/nfs/garage/data/` | Content-addressed data blocks |

The metadata database maps object names to block hashes. Without working metadata, data blocks are orphaned.

### Recovery Attempts

1. **Snapshot restore (Jan 14)** - Failed during "Initialize block manager..."
2. **Snapshot restore (Jan 20)** - Same failure
3. **Fresh database** - Success

Snapshots failed because the merkle tree corruption may have been present in snapshots, or there was a mismatch between old metadata and newer data blocks.

## Resolution

### Step 1: Scale Down Garage

```bash
kubectl scale deployment -n storage garage --replicas=0
```

### Step 2: Reset Database

```bash
ssh root@192.168.1.10
cd /mnt/tank/nfs/garage/meta

# Backup corrupt database
mv db.lmdb db.lmdb.corrupt.$(date +%Y%m%d-%H%M%S)

# Create fresh database directory
mkdir -p db.lmdb
chown -R 1000:1000 db.lmdb
chmod 700 db.lmdb
```

### Step 3: Scale Up Garage

```bash
kubectl scale deployment -n storage garage --replicas=1
```

### Step 4: Reconfigure Buckets and Keys

Garage starts with an empty database. Must recreate:

1. **API Keys** (import with exact IDs from 1Password/ExternalSecrets)
2. **Buckets**
3. **Key-to-bucket permissions**

#### Get Admin Token

```bash
kubectl get secret -n storage garage -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d
```

#### Get Credentials from Secrets

```bash
# Loki
kubectl get secret -n observability loki-secret -o jsonpath='{.data.S3_ACCESS_KEY_ID}' | base64 -d
kubectl get secret -n observability loki-secret -o jsonpath='{.data.S3_SECRET_ACCESS_KEY}' | base64 -d

# Postgres backups
kubectl get secret -n postgresql-system postgres-backup-credentials -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d
kubectl get secret -n postgresql-system postgres-backup-credentials -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d

# Authentik
kubectl get secret -n security authentik-config -o jsonpath='{.data.AUTHENTIK_STORAGE__MEDIA__S3__ACCESS_KEY}' | base64 -d
kubectl get secret -n security authentik-config -o jsonpath='{.data.AUTHENTIK_STORAGE__MEDIA__S3__SECRET_KEY}' | base64 -d
```

#### Create Keys via Admin API

```bash
ADMIN_TOKEN="<token>"

# Import key (example for loki)
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "loki", "accessKeyId": "<key_id>", "secretAccessKey": "<secret>"}' \
  http://garage:3903/v1/key/import
```

#### Create Buckets

```bash
kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"globalAlias": "loki"}' \
  http://garage:3903/v1/bucket
```

#### Grant Key Access to Bucket

```bash
BUCKET_ID="<from bucket creation response>"

kubectl run -n storage garage-admin --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"bucketId\": \"$BUCKET_ID\", \"accessKeyId\": \"<key_id>\", \"permissions\": {\"read\": true, \"write\": true, \"owner\": true}}" \
  http://garage:3903/v1/bucket/allow
```

### Step 5: Restart Dependent Services

Loki requires full restart to clear stale memberlist ring entries:

```bash
kubectl scale deployment loki -n observability --replicas=0
sleep 30
kubectl scale deployment loki -n observability --replicas=3
```

### Step 6: Verify Data Flow

```bash
# Check bucket stats
kubectl run -n storage garage-check --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -H "Authorization: Bearer $ADMIN_TOKEN" "http://garage:3903/v1/bucket?id=<bucket_id>"

# Look for objects count > 0 and bytes increasing
```

### Step 7: Cleanup Orphaned Data

After confirming new data is flowing:

```bash
ssh root@192.168.1.10

# Remove corrupt database backup
rm -rf /mnt/tank/nfs/garage/meta/db.lmdb.corrupt.*

# Remove old snapshots (reference old corrupt state)
rm -rf /mnt/tank/nfs/garage/meta/snapshots/*

# Remove orphaned data blocks (no longer referenced)
rm -rf /mnt/tank/nfs/garage/data/*

# Remove unused sqlite files (using lmdb engine)
rm -f /mnt/tank/nfs/garage/meta/db.sqlite*
```

## Buckets Configuration Reference

| Bucket | Key Name | Secret Source |
|--------|----------|---------------|
| `loki` | loki | `observability/loki-secret` |
| `postgres-backups` | postgres-backup | `postgresql-system/postgres-backup-credentials` |
| `authentik-media` | authentik | `security/authentik-config` |

## Data Loss Impact

- **Loki logs**: Historical logs lost; new logs ingesting normally
- **Postgres WAL archives**: Old archives lost; continuous archiving resumed
- **Authentik media**: Old uploads lost; new uploads working

## Prevention

1. **Regular backups**: Garage snapshots alone are insufficient if corruption spreads
2. **Multi-node setup**: `replication_factor > 1` provides redundancy
3. **Graceful shutdowns**: Drain nodes before maintenance to avoid abrupt termination
4. **Monitor for PCIe/hardware errors**: Root cause was PVE2 hardware issues

## Related Documentation

- [PVE2_CRASH_INVESTIGATION.md](PVE2_CRASH_INVESTIGATION.md) - Hardware root cause
- [LOKI_MEMBERLIST_RING_RECOVERY.md](LOKI_MEMBERLIST_RING_RECOVERY.md) - Loki ring issues

## Document History

- **Created**: 2026-01-21
- **Author**: Home-ops automation
- **Incident Duration**: ~6 days (Garage), resolved in ~30 minutes once diagnosed
