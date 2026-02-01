# Garage Object Storage

S3-compatible object storage using the garage-operator.

## Architecture

| Component | Details |
|-----------|---------|
| Operator | `garage-operator` in `storage` namespace |
| Cluster | 3 replicas, `replication_factor=2` |
| Storage | `openebs-hostpath` (10Gi metadata + 100Gi data per pod) |
| Database | LMDB engine |

### Endpoints

| Service | URL |
|---------|-----|
| S3 API | `http://garage.storage:3900` |
| Admin API | `http://garage.storage:3903` |
| Web UI | `https://garage.${SECRET_DOMAIN}` |

### Buckets

| Bucket | Consumer |
|--------|----------|
| loki | Loki log storage |
| postgres-backups | CloudNative-PG Barman |
| authentik-media | Authentik media files |

## CLI Reference

Config path: `/etc/garage/garage.toml`

```bash
# Cluster status
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml status

# List buckets
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket list

# Bucket info
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket info <name-or-id>

# Delete bucket (must be empty)
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket delete --yes <id>

# List keys
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml key list

# Import key
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml key import -n <name> <access-key> <secret-key>

# Grant bucket access
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket allow --read --write <bucket> --key <key>
```

## GarageCluster CRD

Field naming differs from Garage documentation:

| Correct | Incorrect |
|---------|-----------|
| `s3Api` | `s3API` |
| `network.rpcSecretRef` | `rpcSecretRef` (top-level) |
| `admin.adminTokenSecretRef` | `adminTokenSecretRef` (top-level) |
| `admin.metricsTokenSecretRef` | `metricsToken.secretRef` |

### Secret Permissions

Kubernetes mounts secrets with mode 0640 when `fsGroup` is set. Garage expects 0600.

```yaml
security:
  allowWorldReadableSecrets: true
```

## Recreating Buckets and Keys

After fresh cluster initialization:

```bash
# Get credentials from existing secrets
kubectl get secret -n observability loki-secret -o jsonpath='{.data.S3_ACCESS_KEY_ID}' | base64 -d
kubectl get secret -n observability loki-secret -o jsonpath='{.data.S3_SECRET_ACCESS_KEY}' | base64 -d

# Import key
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml key import -n loki <access-key> <secret-key>

# Create bucket
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket create loki

# Grant access
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket allow --read --write loki --key loki
```

## Troubleshooting

### Web UI "localeCompare" Error

**Cause**: Orphan buckets without aliases

```bash
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket list
kubectl exec -n storage garage-0 -- /garage -c /etc/garage/garage.toml bucket delete --yes <orphan-id>
```

### Secret Permission Denied

**Error**: `File /secrets/rpc/rpc-secret is world-readable!`

**Fix**: Set `security.allowWorldReadableSecrets: true` in GarageCluster spec

## Dependencies

Applications using Garage:

```yaml
spec:
  dependsOn:
    - name: garage-cluster
      namespace: storage
```

## References

- [Garage Documentation](https://garagehq.deuxfleurs.fr/documentation/)
- [Garage Operator](https://github.com/rajsinghtech/garage-operator)
