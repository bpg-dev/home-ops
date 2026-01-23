# PVE2 RMA Guide - Node Removal and Restoration

## Overview

This document outlines the procedure for temporarily removing **pve2** (192.168.1.82) from the infrastructure for RMA replacement and restoring it upon return.

**Node Details:**

- Hostname: pve2
- IP Address: 192.168.1.82
- Hardware: MS-01 (Intel Core i9-12900H)
- Issue: CPU defects (core 4 confirmed faulty, suspected additional defects in shared components)

**Related Documentation:**

- [PVE2_CRASH_INVESTIGATION.md](PVE2_CRASH_INVESTIGATION.md) - Root cause analysis
- [PVE2_NVME_REPLACEMENT_GUIDE.md](PVE2_NVME_REPLACEMENT_GUIDE.md) - NVMe replacement history

---

## Impact Assessment

### Services Affected

| Service | Impact | Mitigation |
|---------|--------|------------|
| Proxmox Cluster | Reduced from 3 to 2 nodes | Quorum maintained (2/3) |
| Ceph Storage | One OSD offline | Data remains available (replicated) |
| Kubernetes | One control plane node VM | Quorum maintained (2/3) |
| Monitoring | pve2 metrics unavailable | Update scrape configs |

### What Remains Operational

- **Kubernetes cluster**: 2/3 control plane nodes maintain quorum
- **Ceph storage**: All data accessible (replication factor protects against single node loss)
- **Proxmox HA**: Continues functioning with 2 nodes
- **VMs**: Migrate off pve2 before removal

---

## Part 1: Pre-Removal Preparation

### 1.1 Verify Current State

```bash
# Check Proxmox cluster status
pvecm status

# Check Ceph cluster health
ceph status
ceph osd tree

# List VMs on pve2
qm list | grep -E "^[0-9]+ " # Run on pve2
```

### 1.2 Document pve2's Ceph OSD

```bash
# Find OSD ID for pve2
ceph osd tree | grep -A1 pve2

# Note the OSD ID (e.g., osd.1) for later steps
# Record OSD weight and CRUSH location
```

### 1.3 Backup Important Data

```bash
# On pve2: Backup any local configurations
tar -czvf /tmp/pve2-config-backup.tar.gz \
  /etc/pve \
  /etc/network/interfaces \
  /etc/systemd/system/disable-cpu-core4.service \
  /etc/sysctl.d/99-watchdog.conf

# Copy backup to another node
scp /tmp/pve2-config-backup.tar.gz pve1:/root/
```

---

## Part 2: VM Migration

### 2.1 Identify VMs on pve2

The following VM typically runs on pve2:

- **VM 1002**: talos-prod-2 (Kubernetes control plane node)

```bash
# List all VMs on pve2
qm list
```

### 2.2 Migrate VMs to Other Nodes

**Option A: Live Migration (Recommended)**

```bash
# From any Proxmox node - migrate VM 1002 to pve1
qm migrate 1002 pve1 --online

# Verify migration
qm status 1002
```

**Option B: Shutdown and Migrate**

```bash
# If live migration fails
qm shutdown 1002
qm migrate 1002 pve1
qm start 1002
```

### 2.3 Verify Kubernetes Health

```bash
# Check all nodes are ready
kubectl get nodes

# Verify control plane health
kubectl get pods -n kube-system
```

---

## Part 3: Ceph OSD Removal

### 3.1 Mark OSD Out

This tells Ceph to start rebalancing data away from this OSD.

```bash
# Replace X with your OSD ID (found in step 1.2)
ceph osd out osd.X

# Monitor rebalancing progress
ceph -w
# Wait until "HEALTH_OK" or "HEALTH_WARN" (not related to pve2)
```

### 3.2 Stop OSD Service

```bash
# On pve2
systemctl stop ceph-osd@X

# Verify stopped
systemctl status ceph-osd@X
```

### 3.3 Remove OSD from Cluster

```bash
# Remove from CRUSH map
ceph osd crush remove osd.X

# Delete authentication key
ceph auth del osd.X

# Remove OSD
ceph osd rm osd.X

# Verify removal
ceph osd tree
```

### 3.4 Verify Ceph Health

```bash
ceph status
# Should show HEALTH_OK or only warnings unrelated to pve2
```

---

## Part 4: Proxmox Cluster Node Removal

### 4.1 Shutdown pve2

```bash
# On pve2
shutdown -h now
```

### 4.2 Remove Node from Cluster

```bash
# From pve1 or pve3 (after pve2 is offline)
pvecm delnode pve2

# If the above fails (node already offline):
pvecm delnode pve2 --force
```

### 4.3 Clean Up Cluster Configuration

```bash
# On remaining nodes - remove pve2 from known hosts
pvecm updatecerts

# Verify cluster status
pvecm status
# Should show 2 nodes with quorum
```

---

## Part 5: Kubernetes Configuration Updates

### 5.1 Update Ceph MON Endpoints

Edit `kubernetes/apps/rook-ceph-external/rook-ceph/app/configmaps.yaml`:

```yaml
# Before:
data: "pve1=192.168.1.81:6789,pve2=192.168.1.82:6789,pve3=192.168.1.83:6789"

# After:
data: "pve1=192.168.1.81:6789,pve3=192.168.1.83:6789"
```

Apply the change:

```bash
kubectl apply -f kubernetes/apps/rook-ceph-external/rook-ceph/app/configmaps.yaml

# Restart rook-ceph-external operator to pick up changes
kubectl rollout restart deployment -n rook-ceph-external rook-ceph-operator
```

### 5.2 Update Prometheus Scrape Configs

Edit `kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml`:

**Remove pve2 from all three scrape configs:**

```yaml
# ceph-metrics-exporter - remove 192.168.1.82:9283
# pve-node-exporter - remove 192.168.1.82:9100
# prometheus-pve-exporter - remove 192.168.1.82
```

Apply the change:

```bash
kubectl apply -f kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml
```

### 5.3 Remove ZFS Silence (Optional)

The ZFS degradation silence for pve2 is no longer needed:

```bash
# Delete the silence ConfigMap documentation
kubectl delete configmap -n observability alertmanager-silence-zfs-pve2

# Expire any active silences in Alertmanager
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query --alertmanager.url=http://localhost:9093

# Note the silence ID and expire it
kubectl exec -n observability alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence expire <SILENCE_ID> --alertmanager.url=http://localhost:9093
```

---

## Part 6: Verification Checklist

### After Node Removal

- [ ] Proxmox cluster shows 2 nodes with quorum (`pvecm status`)
- [ ] Ceph cluster is healthy (`ceph status`)
- [ ] All Kubernetes nodes are Ready (`kubectl get nodes`)
- [ ] Kubernetes workloads are running (`kubectl get pods -A`)
- [ ] No Prometheus scrape errors for pve2 targets
- [ ] Ceph storage is accessible from Kubernetes

### Test Commands

```bash
# Proxmox
pvecm status
pvecm nodes

# Ceph
ceph status
ceph osd tree
ceph df

# Kubernetes
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl get pvc -A

# Storage test - create and delete a test PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-rbd
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-ceph-pvc
kubectl delete pvc test-ceph-pvc
```

---

## Part 7: Node Restoration (After RMA Return)

### 7.1 Physical Setup

1. Install the returned/replacement node in the rack
2. Connect network and power
3. Boot and access IPMI/BIOS if needed

### 7.2 Proxmox Installation

1. Install Proxmox VE (same version as other nodes)
2. Configure network:
   - IP: 192.168.1.82
   - Gateway: 192.168.1.1
   - DNS: 192.168.1.1
3. Set hostname: `pve2`

### 7.3 Join Proxmox Cluster

```bash
# On pve2 (new installation)
pvecm add 192.168.1.81

# Verify
pvecm status
```

### 7.4 Configure Ceph OSD

```bash
# On pve2 - identify the NVMe drive for Ceph
lsblk

# Create OSD (adjust device path as needed)
ceph-volume lvm create --data /dev/nvmeXnY

# Verify OSD is up
ceph osd tree
```

### 7.5 Restore Kubernetes Configuration

**Revert Ceph MON endpoints:**

```yaml
# kubernetes/apps/rook-ceph-external/rook-ceph/app/configmaps.yaml
data: "pve1=192.168.1.81:6789,pve2=192.168.1.82:6789,pve3=192.168.1.83:6789"
```

**Revert Prometheus scrape configs:**

```yaml
# Add back to all three scrape configs:
# ceph-metrics-exporter: 192.168.1.82:9283
# pve-node-exporter: 192.168.1.82:9100
# prometheus-pve-exporter: 192.168.1.82
```

### 7.6 Restore Talos VM (Optional)

If you want to migrate talos-prod-2 back to pve2:

```bash
# From any Proxmox node
qm migrate 1002 pve2 --online
```

### 7.7 Configure Monitoring Services

```bash
# On pve2 - install node_exporter
apt install prometheus-node-exporter

# Install ceph-exporter (if not automatic)
# The ceph-mgr prometheus module should auto-enable

# Verify metrics endpoints
curl -s http://localhost:9100/metrics | head
curl -s http://localhost:9283/metrics | head
```

### 7.8 Final Verification

Run all verification commands from Part 6 to ensure full restoration.

---

## Quick Reference: Files to Modify

| File | Change for Removal | Change for Restoration |
|------|-------------------|----------------------|
| `kubernetes/apps/rook-ceph-external/rook-ceph/app/configmaps.yaml` | Remove pve2 from MON endpoints | Add pve2 back |
| `kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml` | Remove 192.168.1.82 from all targets | Add 192.168.1.82 back |
| `kubernetes/apps/observability/kube-prometheus-stack/app/silence-zfs-pve2.yaml` | Delete (optional) | Not needed if drive is healthy |

---

## Rollback Procedure

If issues occur during removal, you can abort and restore:

### If Ceph OSD Was Marked Out

```bash
# Mark OSD back in
ceph osd in osd.X
```

### If Node Was Removed from Cluster

You'll need to re-add the node:

```bash
# On pve2
pvecm add 192.168.1.81
```

---

## Document History

- **Created**: 2026-01-21
- **Author**: Home-ops automation
- **Related Issues**: CPU hardware defects requiring RMA
