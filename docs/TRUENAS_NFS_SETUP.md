# TrueNAS SCALE NFS Configuration for Kopia

This guide helps you configure TrueNAS SCALE (Fangtooth 25.04) to provide NFS access for the kopia pod running in Kubernetes.

## Problem

The kopia pod runs as UID/GID 1000 and needs write access to `/mnt/tank/nfs/volsync-kopia` on the NFS server.

## Solution

### Method 1: Web UI (Recommended)

#### Step 1: Create/Verify Dataset

1. Log into TrueNAS SCALE web UI
2. Navigate to **Storage** → **Pools** → Select your pool (`tank`)
3. Click **Datasets** tab
4. If `nfs/volsync-kopia` doesn't exist:
   - Click **Add Dataset** → **Add Filesystem**
   - **Name**: `volsync-kopia` (create under `nfs` dataset if it exists)
   - **ACL Type**: `POSIX` (or `OpenZFS` if you prefer ACLs)
   - **Case Sensitivity**: `Sensitive`
   - Click **Save**

#### Step 2: Set Permissions

1. Find the `volsync-kopia` dataset in the list
2. Click the **⋮** (three dots) menu → **Edit Permissions**
3. Configure:
   - **User**: `root` (or find/create user with UID 1000)
   - **Group**: `root` (or find/create group with GID 1000)
   - **Mode**: `755` (or `775` for group-writable)
4. Check **Apply Permissions Recursively** if the dataset has existing files
5. Click **Save**

#### Step 3: Configure NFS Share

1. Navigate to **Shares** → **Unix (NFS) Shares**
2. Click **Add** (or edit existing share for this path)
3. Configure:
   - **Path**: `/mnt/tank/nfs/volsync-kopia`
   - **Description**: `Kopia repository for VolSync`
   - **Network**: Add your Kubernetes cluster network
     - Example: `192.168.0.0/16` or `10.224.0.0/16` (based on your cluster CIDR)
   - **Authorized Networks**: Your cluster subnet (e.g., `192.168.0.0/16`)
   - **Maproot User**: `root` (maps root user from client to root on server)
   - **Maproot Group**: `root` (maps root group from client to root on server)
   - **Enable**: ✓ (checked)
4. Click **Save**
5. If the NFS service isn't running, go to **Services** → **NFS** → **Start**

### Method 2: CLI (SSH)

If you have SSH access to TrueNAS SCALE:

```bash
# SSH into TrueNAS SCALE
ssh root@nas.internal

# Create directory if needed
mkdir -p /mnt/tank/nfs/volsync-kopia

# Set ownership to UID/GID 1000
chown -R 1000:1000 /mnt/tank/nfs/volsync-kopia

# Set permissions
chmod -R 755 /mnt/tank/nfs/volsync-kopia

# Verify
ls -ld /mnt/tank/nfs/volsync-kopia
```

Then configure the NFS share via the web UI (Step 3 above).

## Alternative: Use Maproot for NFS

If you can't change file ownership, you can use NFS Maproot feature:

1. In the NFS share configuration:
   - **Maproot User**: `root`
   - **Maproot Group**: `root`
   - This maps all NFS clients' root user to root on the server

2. Ensure the directory is owned by root and has appropriate permissions:

   ```bash
   chown -R root:root /mnt/tank/nfs/volsync-kopia
   chmod -R 755 /mnt/tank/nfs/volsync-kopia
   ```

## Verify Configuration

After configuration, verify from a Kubernetes node:

```bash
# Test NFS mount (from a Kubernetes node)
sudo mount -t nfs4 nas.internal:/mnt/tank/nfs/volsync-kopia /mnt/test
sudo touch /mnt/test/test-file
sudo rm /mnt/test/test-file
sudo umount /mnt/test
```

## Troubleshooting

### Check NFS Service Status

In TrueNAS web UI:

- **Services** → **NFS** → Ensure it's **Running**

### Check NFS Exports

From TrueNAS CLI:

```bash
exportfs -v
```

Should show your share with proper options.

### Check Permissions

```bash
ls -ld /mnt/tank/nfs/volsync-kopia
```

Should show ownership matching your configuration.

### Check Kubernetes Pod

After fixing permissions, the kopia pod should automatically restart and initialize the repository:

```bash
kubectl get pods -n volsync-system -w
kubectl logs -n volsync-system -l app.kubernetes.io/name=kopia --tail=50
```

## Network Configuration

Ensure your Kubernetes cluster nodes can reach `nas.internal`:

- **Firewall**: Allow NFS (port 2049 TCP/UDP) and related ports (111, 20048)
- **DNS**: Ensure `nas.internal` resolves correctly from cluster nodes
- **Network**: Kubernetes nodes should be in the authorized networks list

## References

- [TrueNAS SCALE NFS Documentation](https://www.truenas.com/docs/scale/scaletutorials/shares/nfs/nfsscale/)
- Kubernetes NFS volume documentation
