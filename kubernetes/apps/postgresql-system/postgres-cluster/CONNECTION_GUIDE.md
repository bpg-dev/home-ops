# PostgreSQL Connection Guide

## Current Configuration

- **Cluster**: `postgres` in namespace `postgresql-system`
- **Services**:
  - `postgres-rw`: Read-write access to primary (port 5432)
  - `postgres-r`: Read access to any instance (port 5432)
  - `postgres-ro`: Read-only access to replicas (port 5432)
- **TLS**: Required (TLSv1.3 minimum)
- **Superuser Access**: Enabled (`enableSuperuserAccess: true`)
- **Credentials**: Stored in secret `postgres-superuser`

## Connection Methods

### 1. From Within the Cluster

```bash
# Get credentials
USERNAME=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.username}' | base64 -d)
PASSWORD=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.password}' | base64 -d)

# Connect using psql
psql "host=postgres-rw.postgresql-system.svc port=5432 user=${USERNAME} dbname=postgres sslmode=require password=${PASSWORD}"
```

### 2. From Outside the Cluster (Port Forward)

```bash
# Forward the service port
kubectl port-forward -n postgresql-system svc/postgres-rw 15432:5432

# In another terminal, get credentials and connect
USERNAME=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.username}' | base64 -d)
PASSWORD=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.password}' | base64 -d)

psql "host=localhost port=15432 user=${USERNAME} dbname=postgres sslmode=require password=${PASSWORD}"
```

### 3. Using Connection String

```bash
# Get credentials
USERNAME=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.username}' | base64 -d)
PASSWORD=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.password}' | base64 -d)

# Connection string format
export PGPASSWORD="${PASSWORD}"
psql -h postgres-rw.postgresql-system.svc -p 5432 -U "${USERNAME}" -d postgres -c "SELECT version();"
```

### 4. Using Environment Variables

```bash
# Get credentials
export PGUSER=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.username}' | base64 -d)
export PGPASSWORD=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.password}' | base64 -d)
export PGHOST=postgres-rw.postgresql-system.svc
export PGPORT=5432
export PGDATABASE=postgres
export PGSSLMODE=require

# Connect
psql
```

## Important Notes

1. **TLS is Required**: All connections must use TLS (`sslmode=require` or higher)
2. **Service Discovery**: Use the service DNS name, not pod IPs
3. **Credentials**: Always retrieve credentials from the secret, don't hardcode
4. **Namespace**: All resources are in the `postgresql-system` namespace

## Troubleshooting

### Authentication Errors

If you get authentication errors:

1. **Verify superuser access is enabled**:
   ```bash
   kubectl get cluster postgres -n postgresql-system -o jsonpath='{.spec.enableSuperuserAccess}'
   ```
   Should return `true`

2. **Check if cluster has reconciled**:
   ```bash
   kubectl get cluster postgres -n postgresql-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
   ```
   Should return `True`

3. **Verify credentials**:
   ```bash
   kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.username}' | base64 -d
   kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.password}' | base64 -d
   ```

4. **Check PostgreSQL logs**:
   ```bash
   kubectl logs -n postgresql-system postgres-1 -c postgres --tail=50 | grep -i auth
   ```

### Common Issues

- **"password authentication failed"**: Check username/password from secret
- **"SSL connection required"**: Add `sslmode=require` to connection string
- **"connection refused"**: Check if service is accessible and pods are running
- **"no route to host"**: Check network policies and service endpoints

## Testing Connection

```bash
# Quick test from within cluster
kubectl run -it --rm postgres-test --image=postgres:18 --restart=Never -n postgresql-system -- \
  psql "host=postgres-rw.postgresql-system.svc port=5432 user=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.username}' | base64 -d) dbname=postgres sslmode=require password=$(kubectl get secret postgres-superuser -n postgresql-system -o jsonpath='{.data.password}' | base64 -d)" -c "SELECT version();"
```

