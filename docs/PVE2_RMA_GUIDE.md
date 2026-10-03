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

This section was rewritten after the actual restoration on **2026-10-02** (replacement MS-01,
i9-13900H). Follow it in order. The ordering in 7.4 is not optional.

### 7.0 Before touching the new box: compare versions

The remaining nodes were upgraded several times while pve2 was away. A fresh install lands on
whatever the repos serve *today*, which is normally **newer** than pve1/pve3.

```bash
# On pve1 and pve3
pveversion; uname -r; ceph --version
apt update >/dev/null; apt-cache policy pve-manager proxmox-kernel-7.0 ceph | grep -E "^[a-z]|Installed|Candidate"
```

If the Ceph candidate is a newer point release than what is running, plan to upgrade the existing
nodes' Ceph packages **and restart their mons/mgrs before** creating any Ceph daemon on the new node
(see 7.4). Ceph 19.2.6 (CVE-2025-30156 hotfix) introduced the `aes256k` cephx key type; a 19.2.6 mon
joining 19.2.5 mons made `mon.pve1` balloon to 62 GB, OOM-killed VM 1003 and crash-looped quorum.
`pveceph osd create` from a newer node also fails against older mons with
`Error EINVAL: invalid cephx secret`.

### 7.1 Clean up what the old node left behind (on pve1)

`pvecm delnode` and the OSD removal in Part 3 leave the monitor and the node directory in place.
If the old drives are transplanted into the new unit, the old install will boot and its stale
`mon.pve2` **re-joins the Ceph quorum** — stop it before anything else.

```bash
# If the old install booted: on the old pve2
systemctl stop ceph-mon@pve2 ceph-mgr@pve2 ceph-mds@pve2 ceph-osd@1 corosync pve-cluster
# NEVER start VM 1002 from a stale local copy; the live VM is on another node.

# On pve1
ceph mon remove pve2
ceph mon stat                       # expect 2 mons, quorum pve1,pve3
rm -rf /etc/pve/nodes/pve2

# On your workstation: the host key will change
ssh-keygen -R pve2; ssh-keygen -R 192.168.1.82; ssh-keygen -R pve2.bpghome.net
```

### 7.2 Proxmox installation

- Boot the current PVE 9.x ISO. ZFS RAID1 across the two 1 TB NVMe drives only; leave the Intel
  SSDPE2KE032T7 (OSD) untouched.
- Hostname `pve2.bpghome.net`, 192.168.1.82/24, gateway/DNS 192.168.1.1. The installer may come up
  on a different NIC/DHCP address — check the OPNsense lease table for the MS-01 MAC `38:05:25:37:95:1d`.
- Install your SSH key, then switch repos (deb822 format, Debian **trixie**) and bring the box to the
  current package set **before** joining:

```bash
sed -i 's/^Enabled: true/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
cat > /etc/apt/sources.list.d/ceph.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: trixie
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update && apt full-upgrade -y && reboot
```

### 7.3 Network: three subnets, pinned NIC names

PVE 9 pins interfaces as `nic0..nic3`. Mapping on the MS-01 (by MAC suffix):

| Name | MAC suffix | Old name | Role | Address |
|------|-----------|----------|------|---------|
| nic0 | :1e | enp87s0 | Corosync link0 | 10.0.0.82/16 |
| nic1 | :1f | enp90s0 | unused | — |
| nic2 | :1c | enp2s0f0np0 | Ceph cluster, MTU 9000 | 10.1.0.82/16 |
| nic3 | :1d | enp2s0f1np1 | LAN trunk → vmbr0 (VLAN-aware, vids 116) + vmbr116 | 192.168.1.82/24 |

The old `/etc/network/interfaces` is in `/root/pve2-config-backup.tar.gz` on pve1; substitute the
NIC names. Add `192.168.1.82 pve2.bpghome.net pve2` and `192.168.1.10 nas.bpghome.net nas` to
`/etc/hosts`, then `ifreload -a`. Verify all three subnets and jumbo frames:

```bash
for h in 192.168.1.81 10.0.0.81 10.1.0.81 192.168.1.83 10.0.0.83 10.1.0.83; do ping -c1 -W1 $h >/dev/null && echo "$h ok" || echo "$h FAIL"; done
ping -c1 -M do -s 8972 10.1.0.81    # MTU 9000 on the Ceph network
```

The 2.5G corosync port can take ~30 s to negotiate link after `ifreload`; re-test before worrying.

### 7.4 Join the cluster (three corosync links)

```bash
# On pve2 — no password needed if you ssh in with agent forwarding (ssh -A) and your key is on pve1
pvecm add 192.168.1.81 --use_ssh --link0 10.0.0.82 --link1 192.168.1.82 --link2 10.1.0.82
pvecm status            # 3 nodes, 3 votes, quorate

# On pve1
pvecm updatecerts
# Verify the exact ssh invocation PVE uses for migration works from every node to every node:
perl -e 'use PVE::SSHInfo; print join(" ", @{PVE::SSHInfo::ssh_info_to_command(PVE::SSHInfo::get_ssh_info("pve2"))})' | xargs -I{} sh -c '{} hostname'
```

Also drop stale `pve2` lines from `/root/.ssh/known_hosts` on pve1 and pve3 (only affects manual ssh).

### 7.5 Ceph — order matters

1. **If the new node's Ceph is a newer point release than pve1/pve3: upgrade pve3 then pve1 first.**

   ```bash
   # On pve3, then pve1 (only Ceph packages; no kernel reboot needed)
   apt install -y --only-upgrade ceph ceph-base ceph-common ceph-fuse ceph-mds ceph-mgr ceph-mgr-modules-core ceph-mon ceph-osd ceph-volume
   systemctl restart ceph-mon@$(hostname); sleep 10; ceph quorum_status | jq .quorum_names
   systemctl restart ceph-mgr@$(hostname)
   ```

   Each mon restart is a ~10 s outage while only two mons exist. OSDs can stay on the older point
   release until there are three of them (restart with `noout` later).

2. On pve2:

   ```bash
   yes | pveceph install --repository no-subscription --version squid   # non-interactive
   # Remove stale [mon.pve2] / [mds.pve2] sections and the .82 mon_host entry from /etc/pve/ceph.conf,
   # otherwise: "monitor address '192.168.1.82' already in use"
   pveceph mon create
   pveceph mgr create
   pveceph mds create
   DEV=$(readlink -f /dev/disk/by-id/nvme-INTEL_SSDPE2KE032T7_PHLE746400EQ3P2EGN)
   ceph-volume lvm zap $DEV --destroy        # old osd.1 LVM is still on it
   pveceph osd create $DEV
   ceph osd tree; ceph -s
   ```

   Backfill of ~520 GiB runs at roughly 350 MiB/s, one PG at a time. Expect it to take a while; the
   snaptrim backlog from the degraded months drains afterwards.

3. After the mon upgrade to 19.2.6, `ceph -s` reports **HEALTH_ERR "insecure key types"**. This is
   expected. **Do not rotate keys or restrict `auth_allowed_ciphers`**: Talos' kernel RBD/CephFS clients
   need kernel 7.0 for `aes256k` (Talos v1.13.7 runs 6.18). Leave it until Talos ships a 7.0 kernel.

4. `ceph crash archive-all` once HEALTH_OK (mon.pve1 logs an assert crash during the mon remove).

### 7.6 Per-node services (fresh PVE 9 has none of these)

```bash
apt install -y prometheus-node-exporter rsyslog          # rsyslog is NOT installed by default on PVE 9
# rsyslog forward: copy /etc/rsyslog.d/99-fluent-bit.conf from pve1 (target 192.168.1.11:30514), restart rsyslog
# watchdog: see docs/PVE_WATCHDOG_SETUP.md (modules-load iTCO_wdt, udev rule, /etc/default/pve-ha-manager)
```

Do **not** recreate `disable-cpu-core4.service`; that was for the defective CPU.

### 7.7 Restore Kubernetes configuration (Git, then Flux)

Reverse of commit `ca0fe9a0`:

- `kubernetes/apps/rook-ceph-external/rook-ceph/app/configmaps.yaml` — add `pve2=192.168.1.82:6789`
- `kubernetes/apps/observability/kube-prometheus-stack/app/scrapeconfig.yaml` — add `192.168.1.82` to
  `ceph-metrics-exporter` (:9283), `pve-node-exporter` (:9100), `prometheus-pve-exporter`

Validate (`kubectl kustomize`, `kubectl apply --dry-run=server`), commit, let Flux apply, then
`kubectl rollout restart deployment -n rook-ceph-external rook-ceph-operator`.

### 7.8 Move a Talos VM back and finish the rolling upgrade

```bash
qm migrate 1002 pve2 --online       # from pve3; one VM per host again
kubectl get nodes
```

Only after Ceph is HEALTH_OK with 3 OSDs: `apt full-upgrade` + reboot pve3, then pve1, one at a time
(`ceph osd set noout`, migrate/shut down that node's VM, reboot, wait, `unset noout`). This also
restarts the remaining OSDs onto the new Ceph point release.

### 7.9 Final verification

```bash
pvecm status; pvecm nodes
ceph -s; ceph osd tree; ceph versions
kubectl get nodes; kubectl get pods -A | grep -vE "Running|Completed"
kubectl get pods -n rook-ceph-external
```

### Lessons from 2026-10-02

- Transplanted drives boot the old install; it re-joins Ceph silently. Expect it.
- Never introduce a newer-point-release Ceph daemon into an older cluster. Upgrade mons first.
- pve1 (94 GB) hosts two 32 GB VMs on local ZFS; a runaway daemon kills a VM first because kvm has the
  largest RSS. Watch `journalctl -k | grep -i "out of memory"` after any Ceph change.
- After any node outage: Loki needs a ring `forget` per dead replica (see
  `docs/LOKI_MEMBERLIST_RING_RECOVERY.md`), CNPG re-syncs on its own.
- A rebooting node that answers ping on every link but listens on nothing is not "slow": it either
  panicked (kernel is up, userspace never started) or is still shutting down. pve1 took 6 minutes
  to shut down because `pvestatd` ignored SIGTERM and SIGKILL, then kernel-panicked repeatedly on
  7.0.14-20 while pve3 (identical hardware) booted it in 25 seconds. Panics on boot leave nothing
  in the journal or pstore; the HDMI console is the only record. Recovery: hard reset, pick the
  previous kernel under "Advanced options", then
  `proxmox-boot-tool kernel pin <ver> && proxmox-boot-tool refresh` (check `loader/loader.conf` on
  the ESP shows `default proxmox-<ver>.conf`). Keep the previous kernel installed before every
  reboot.
- Ceph 19.2.6 reports `HEALTH_ERR` purely from the six `AUTH_INSECURE_*` cephx checks while Talos
  lacks kernel 7.0. `ceph health mute <CHECK> 30d` for each keeps the dashboard honest; the mutes
  expire on their own, so re-mute or finish the key migration by then.

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
- **Updated**: 2026-10-02 — Part 7 rewritten after the actual restoration (PVE 9.2.21, Ceph 19.2.6); rolling-upgrade lessons (pve1 panic on 7.0.14-20, kernel pin, cephx mutes)
- **Author**: Home-ops automation
- **Related Issues**: CPU hardware defects requiring RMA
