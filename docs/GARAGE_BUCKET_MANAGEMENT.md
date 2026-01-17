# Garage S3 Bucket Management

This document describes how to manage Garage S3 buckets in the home-ops cluster.

## Overview

Garage is a self-hosted S3-compatible object storage service running in the cluster. It provides storage for:

- **Loki**: Log storage (bucket: `loki`)
- **PostgreSQL**: Database backups (bucket: `postgres-backups`)
- **Authentik**: Media files (bucket: `authentik-media`)
- **Thanos**: Metrics blocks (bucket: `thanos`, **deprecated/removed**)

Garage components:

- **S3 API**: `http://garage.storage:3900` (internal) or `https://s3.${SECRET_DOMAIN}` (external)
- **Admin API**: `http://garage.storage:3903` (internal only)
- **Web UI**: `https://garage.${SECRET_DOMAIN}` (internal access)

## Prerequisites

All operations require authentication. Garage uses bearer token authentication for admin operations.

**Admin credentials** are stored in 1Password and injected via External Secrets Operator:

- `GARAGE_ADMIN_TOKEN`: Used for admin API and Web UI access
- `GARAGE_RPC_SECRET`: Used for internal node communication
- `GARAGE_METRICS_TOKEN`: Used for metrics scraping

## Method 1: Web UI (Easiest)

The Garage Web UI provides a graphical interface for managing buckets.

### Access

1. Navigate to: `https://garage.${SECRET_DOMAIN}`
2. Login with the admin token (stored in 1Password under `garage` → `GARAGE_ADMIN_TOKEN`)

### Delete a Bucket via Web UI

1. Navigate to the **Buckets** section
2. Find the bucket you want to delete
3. Click the **Delete** button
4. Confirm the deletion

**Warning**: This operation is irreversible. All data in the bucket will be permanently deleted.

## Method 2: Garage CLI via Running Pod (Recommended)

**This is the most reliable method** for deleting buckets and managing Garage when the Web UI is unavailable or
doesn't support the required operations.

The Garage container image (`dxflrs/garage:v2.1.0`) includes the `/garage` CLI binary. You can exec into the running
Garage pod to execute management commands directly.

### Prerequisites (Method 2)

- `kubectl` configured with cluster access (`export KUBECONFIG=./kubeconfig`)
- Running Garage pod in the `storage` namespace

### Find the Garage Pod

```bash
export KUBECONFIG=./kubeconfig
kubectl get pods -n storage -l app.kubernetes.io/name=garage
```

### List All Buckets

```bash
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  bucket list
```

### Get Bucket Details

```bash
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  bucket info <bucket-name>
```

### Delete a Bucket via CLI

**Important**: Buckets must be empty before deletion. Garage will reject deletion if objects exist.

#### Step 1: Check Bucket Info

```bash
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  bucket info <bucket-name>
```

This shows:

- Bucket size and object count
- Access keys with permissions
- Whether the bucket is empty

#### Step 2: Empty the Bucket (if needed)

**WARNING**: This permanently deletes ALL objects.

If the bucket contains objects, you need S3 credentials to delete them. Create a temporary access key:

```bash
# Create temporary S3 key
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  key create temp-delete-key

# Note the Access Key ID and Secret Key from output

# Grant permissions to the bucket
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  bucket allow <bucket-name> --read --write --owner --key <ACCESS_KEY_ID>

# Delete all objects using AWS CLI
kubectl run aws-delete --image=amazon/aws-cli:latest --rm -i --restart=Never \
  --env="AWS_ACCESS_KEY_ID=<ACCESS_KEY_ID>" \
  --env="AWS_SECRET_ACCESS_KEY=<SECRET_KEY>" \
  -- s3 rm s3://<bucket-name>/ --recursive \
  --endpoint-url http://garage.storage:3900 \
  --region us-east-1

# Clean up temporary key
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  key delete --yes temp-delete-key
```

#### Step 3: Delete the Empty Bucket

```bash
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  bucket delete --yes <bucket-name>
```

#### Step 4: Delete Associated Access Keys (optional)

```bash
# List keys
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  key list

# Delete specific key
kubectl exec -n storage deploy/garage -- \
  /garage -c /etc/garage.toml \
  key delete --yes <key-name>
```

## Method 3: Admin API (For Scripting)

The Garage Admin API can be used for automation and scripting.

**Important**: As of Garage v2.1.0, bucket deletion via the Admin API (`v0/` and `v1/` endpoints) is **no longer supported**.
The API returns: `"v1/ endpoint is no longer supported: DeleteBucket"`. Use the **Web UI (Method 1)** instead.

### Prerequisites (Method 3)

- `curl` or similar HTTP client
- Admin token (see Method 2)

### API Endpoint (Method 3)

- **Internal**: `http://garage.storage:3903`
- **Base path**: `/v1/` (read operations only)

### List Buckets

```bash
export KUBECONFIG=./kubeconfig
export GARAGE_ADMIN_TOKEN=$(kubectl get secret garage -n storage -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d)

# From within the cluster (using a temporary pod)
kubectl run curl-temp --image=curlimages/curl:latest --rm -i --restart=Never -- \
  curl -s -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
  http://garage.storage:3903/v1/bucket
```

**Example output**:

```json
[
  {
    "id": "4c163f1cbb7543276da080ba20642ab061403b7f1d4f4394f305748c87386d30",
    "created": "2025-12-19T15:39:56.500Z",
    "globalAliases": ["thanos"],
    "localAliases": []
  }
]
```

### Get Bucket Info

```bash
export BUCKET_ID="<bucket-id>"

kubectl run curl-temp --image=curlimages/curl:latest --rm -i --restart=Never -- \
  curl -s -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
  "http://garage.storage:3903/v1/bucket?id=${BUCKET_ID}"
```

### Delete Bucket

**Deprecated**: Bucket deletion via Admin API is no longer supported in Garage v2.1.0+.

```bash
# This will fail with: "v1/ endpoint is no longer supported: DeleteBucket"
export BUCKET_ID="<bucket-id>"

curl -X DELETE \
  -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
  "http://garage.storage:3903/v1/bucket?id=${BUCKET_ID}"
```

**Use the Web UI instead** (see Method 1).

## Method 4: Port-Forward + Local CLI

If you have the Garage CLI installed locally, you can port-forward to the admin API.

### Setup

```bash
export KUBECONFIG=./kubeconfig

# Port-forward admin API
kubectl port-forward -n storage svc/garage 3903:3903 &

# Export admin token
export GARAGE_ADMIN_TOKEN=$(kubectl get secret garage -n storage -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d)
```

### Use Local Garage CLI

```bash
# List buckets
garage -r http://localhost:3903 \
  -s "${GARAGE_ADMIN_TOKEN}" \
  bucket list

# Delete bucket
garage -r http://localhost:3903 \
  -s "${GARAGE_ADMIN_TOKEN}" \
  bucket delete --yes <bucket-name>
```

## Safety Checklist

Before deleting any bucket, verify:

- [ ] **Application is no longer using the bucket**
  - Check HelmRelease/Deployment manifests
  - Search for bucket references in GitOps repo
  - Confirm application is removed from cluster
- [ ] **Bucket is empty or data is backed up**
  - Use `aws s3 ls` or bucket info to check
  - If data is needed, copy it elsewhere first
- [ ] **No other applications depend on this bucket**
  - Review all ExternalSecrets and configurations
  - Check for shared buckets (multi-tenant)
- [ ] **Credentials are revoked** (if applicable)
  - Remove S3 access keys from 1Password
  - Delete ExternalSecret resources

## Example: Removing Thanos Bucket

Thanos was removed from the observability stack (commented out in `kubernetes/apps/observability/kustomization.yaml`).
The `thanos` bucket is now orphaned and safe to delete.

### Verification Steps

1. **Confirm Thanos is not running**

   ```bash
   export KUBECONFIG=./kubeconfig
   kubectl get pods -n observability -l app.kubernetes.io/name=thanos
   # Should return: No resources found
   ```

   **Result**: Verified - no Thanos pods are running.

2. **List buckets to confirm Thanos bucket exists**

   ```bash
   export KUBECONFIG=./kubeconfig
   export GARAGE_ADMIN_TOKEN=$(kubectl get secret garage -n storage -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d)

   kubectl run curl-temp --image=curlimages/curl:latest --rm -i --restart=Never -- \
     curl -s -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" \
     http://garage.storage:3903/v1/bucket
   ```

   **Result**: Confirmed - Thanos bucket exists with ID `4c163f1cbb7543276da080ba20642ab061403b7f1d4f4394f305748c87386d30`.

3. **Delete the bucket using Garage CLI (Method 2)**

   Use the Garage CLI via the running pod:

   ```bash
   # Check bucket info first
   kubectl exec -n storage deploy/garage -- \
     /garage -c /etc/garage.toml bucket info thanos
   ```

   **Result**: Bucket contains 129.4 GiB of data with 5,098 objects - must be emptied first.

   ```bash
   # Create temporary S3 key
   kubectl exec -n storage deploy/garage -- \
     /garage -c /etc/garage.toml key create temp-thanos-delete
   # Output shows: Access Key ID and Secret Key

   # Grant permissions (replace ACCESS_KEY_ID with actual key from output)
   kubectl exec -n storage deploy/garage -- \
     /garage -c /etc/garage.toml \
     bucket allow thanos --read --write --owner --key <ACCESS_KEY_ID>

   # Delete all objects (replace credentials with actual values)
   kubectl run aws-delete-thanos --image=amazon/aws-cli:latest --rm -i --restart=Never \
     --env="AWS_ACCESS_KEY_ID=<ACCESS_KEY_ID>" \
     --env="AWS_SECRET_ACCESS_KEY=<SECRET_ACCESS_KEY>" \
     -- s3 rm s3://thanos/ --recursive \
     --endpoint-url http://garage.storage:3900 \
     --region us-east-1

   # Delete the empty bucket
   kubectl exec -n storage deploy/garage -- \
     /garage -c /etc/garage.toml bucket delete --yes thanos

   # Clean up temporary key
   kubectl exec -n storage deploy/garage -- \
     /garage -c /etc/garage.toml key delete --yes temp-thanos-delete

   # Delete old Thanos key
   kubectl exec -n storage deploy/garage -- \
     /garage -c /etc/garage.toml key delete --yes thanos

   # Verify deletion
   kubectl exec -n storage deploy/garage -- \
     /garage -c /etc/garage.toml bucket list
   ```

   **Result**: Thanos bucket successfully deleted (verified - no longer in bucket list).

4. **Clean up credentials** (optional)

   ```bash
   # Remove Thanos S3 credentials from 1Password (manual step)
   # Delete ExternalSecret if it exists (already removed from GitOps)
   kubectl delete externalsecret thanos -n observability --ignore-not-found
   ```

## Troubleshooting

### Bucket Not Empty Error

```text
Error: Bucket is not empty
```

**Solution**: Empty the bucket first using `aws s3 rm --recursive` or wait for retention policies to clean up.

### Permission Denied

```text
Error: 403 Forbidden
```

**Solution**: Verify admin token is correct and not expired. Re-fetch from Kubernetes secret.

### Bucket Not Found

```text
Error: Bucket does not exist
```

**Solution**: Bucket may have been already deleted. Verify with `bucket list`.

### CLI Not Available

If `garage` CLI is not in the container image:

1. Use the Web UI (Method 1)
2. Use the Admin API directly (Method 3)
3. Build a custom container with Garage CLI installed

## References

- [Garage Documentation](https://garagehq.deuxfleurs.fr/documentation/)
- [Garage Admin API Reference](https://garagehq.deuxfleurs.fr/documentation/reference-manual/admin-api/)
- Project: `kubernetes/apps/storage/garage/`

## Related Documentation

- `docs/OBSERVABILITY_MIGRATION_LOKI_THANOS_90D.md` - Thanos migration and removal
- `docs/TRUENAS_NFS_SETUP.md` - NFS storage setup (Garage data/meta persistence)
