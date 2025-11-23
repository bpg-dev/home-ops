# Kopia UI Snapshot Visibility

## Issue

Snapshots created by VolSync are not visible in the Kopia UI at `https://kopia.boldyrev.me/snapshots`.

## Root Cause

The Kopia UI filters snapshots by `hostname` and `username` from the repository configuration:

- **Kopia UI Config**: `hostname: volsync.volsync-system.svc.cluster.local`, `username: volsync`
- **VolSync Snapshots**: Created with `userName: paperless-ngx`, `host: default`

The UI only shows snapshots matching its configured hostname/username, so VolSync snapshots are filtered out.

## Verification

Snapshots **DO exist** in the repository. Verify using:

```bash
kubectl exec -n volsync-system <kopia-pod> -- kopia snapshot list --all
```

You should see:
```
paperless-ngx@default:/data
  2025-11-23 10:47:20 EST k2f67f814e7687aab5562b76bd96d1270 1.9 GB ...
```

## Solutions

### Option 1: Use Kopia UI Filters (Recommended)

The Kopia UI should allow you to change filters in the web interface:

1. Open `https://kopia.boldyrev.me/snapshots`
2. Look for filter controls (user/host dropdowns or search)
3. Select "All" or search for `paperless-ngx@default`
4. Or modify the URL to include query parameters (if supported)

### Option 2: Access via Direct URL

Try accessing snapshots directly:
- `https://kopia.boldyrev.me/snapshots/single-source?userName=paperless-ngx&host=default&path=/data`

### Option 3: Use Kopia CLI

List all snapshots from the Kopia pod:

```bash
# Get Kopia pod
KOPIA_POD=$(kubectl get pods -n volsync-system | grep kopia | head -1 | awk '{print $1}')

# List all snapshots
kubectl exec -n volsync-system $KOPIA_POD -- kopia snapshot list --all

# List specific source
kubectl exec -n volsync-system $KOPIA_POD -- kopia snapshot list paperless-ngx@default:/data
```

### Option 4: Update Kopia UI Configuration (Not Recommended)

Changing the repository config hostname/username would affect all snapshots and is not recommended. The UI should support filtering instead.

## Summary

- ✅ Snapshots **are** in the repository
- ✅ Snapshots **are** accessible via CLI
- ⚠️ Snapshots **are filtered** in the UI by hostname/username
- 💡 **Solution**: Use UI filters or CLI to view VolSync snapshots

