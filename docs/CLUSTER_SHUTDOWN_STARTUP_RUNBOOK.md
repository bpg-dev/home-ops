# Cluster Shutdown / Startup Runbook (Physical Move)

Written 2026-08-19 for the move to the new location. Reusable for any planned
full power-down.

## Topology snapshot (2026-08-19)

| Host | IP | Role | Notes |
|------|-----|------|-------|
| pve1 | 192.168.1.81 | Proxmox, Ceph mon+mgr(active)+OSD | Hosts VMs 1001 (talos-prod-1), 1003 (talos-prod-3) |
| pve2 | 192.168.1.82 | Proxmox, Ceph mon+OSD | **OUT FOR RMA — powered off**, see PVE2_RMA_GUIDE.md |
| pve3 | 192.168.1.83 | Proxmox, Ceph mon+mgr(standby)+OSD | Hosts VMs 1002 (talos-prod-2), 9000 (pve utility VM) |
| nas  | 192.168.1.10 | TrueNAS Scale | NFS for volsync/csi-driver-nfs |
| opnsense | — | Router/firewall | Shut down last, physically |
| talos-prod-1/2/3 | 192.168.1.11/12/13 | K8s control plane (all schedulable) | All VMs have `onboot: 1` → autostart with PVE |

Ceph state at shutdown: HEALTH_WARN — pve2 mon out of quorum, 2/2 OSDs up,
all 193 PGs `active+undersized+degraded` (expected while pve2 is out).
Postgres (CNPG) healthy, primary postgres-2. All volsync backups Successful
(last runs 2026-08-19 00:00–04:00 UTC).

**2026-08-19 move notes:** TrueNAS was already powered off before shutdown
began, so the in-flight `booklore` volsync sync (started 04:05 UTC) could
not complete — its last good backup is 03:10 UTC. **At the new location,
after startup, re-trigger it**: `./scripts/trigger-volsync-backup.sh
default booklore`, and verify the others with
`./scripts/verify-volsync-snapshots.sh`.

## Shutdown sequence

Run from the repo root with:

```bash
export KUBECONFIG=./kubeconfig
export TALOSCONFIG=./talos/clusterconfig/talosconfig
```

### 1. Preflight

```bash
kubectl get nodes
kubectl get cluster.postgresql.cnpg.io -A          # healthy
kubectl get replicationsources -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,LAST:.status.lastSyncTime,RESULT:.status.latestMoverStatus.result'
ssh root@192.168.1.81 "ceph status"                # all PGs active+*
```

Make sure no volsync sync or CNPG backup is mid-flight (no `volsync-src-*`
pods running).

### 2. Shut down Talos nodes (all at once)

Graceful shutdown: kubelet terminates pods with their grace periods
(Minecraft saves worlds on SIGTERM, CNPG does a fast Postgres shutdown),
then etcd stops. Shutting all 3 etcd members simultaneously is safe —
quorum re-forms on boot.

```bash
talosctl shutdown -n 192.168.1.11,192.168.1.12,192.168.1.13
```

Wait until the VMs are actually off:

```bash
ssh root@192.168.1.81 "qm list"    # 1001, 1003 stopped
ssh root@192.168.1.83 "qm list"    # 1002 stopped
```

### 3. Set Ceph maintenance flags

Only after all K8s clients are down:

```bash
ssh root@192.168.1.81 "ceph osd set noout; ceph osd set norecover; ceph osd set norebalance; ceph osd set nobackfill"
```

**Deliberately NOT set: `pause` and `nodown`.** The Talos VMs autostart
(`onboot: 1`) when the PVE hosts power on; `pause` blocks all client IO
and would wedge the auto-booting cluster before anyone unsets it. The four
flags above are sufficient for a full power-down where no rebalance can
happen anyway.

### 4. Shut down TrueNAS

After Talos is down (no NFS clients left):

```bash
ssh root@192.168.1.10 "shutdown -h now"
```

(2026-08-19: skipped — NAS was already powered off. **Lesson learned: shut
the NAS down last.** With the NAS gone first, every host with an NFS mount
wedged at shutdown on the dead mounts: all three Talos nodes hung in
`unmountPodMounts` (booklore `books`, volsync `backup`, kopia `repository`)
and had to be force-stopped with `qm stop <vmid>` — safe because
`talosctl dmesg` confirmed pods were drained and etcd/containerd had
already stopped cleanly. pve1 likewise stalled several minutes at the end
of its own shutdown (sshd already dead, still pinging) on its NAS mount.
If a VM sits in `running` long after pods have terminated, or a PVE host
keeps answering ping long after sshd is gone, it is the NFS hang — force
power-off is safe at that stage since Ceph daemons and all data services
stop before the unmount phase.)

### 5. Shut down Proxmox nodes

pve3 first, pve1 (active mgr, SSH anchor) last. PVE gracefully stops its
remaining local VMs (the 9000 utility VM on pve3) and Ceph daemons on the
way down.

```bash
ssh root@192.168.1.83 "shutdown -h now"
ssh root@192.168.1.81 "shutdown -h now"
```

### 6. OPNsense

Power off physically (or Dashboard → Power → Power off) when unplugging.
Do this last — it kills DNS/routing for everything else.

## Startup sequence (new location)

1. **Network first**: OPNsense up, LAN live. Everything uses static IPs on
   192.168.1.0/24 — no DHCP dependency for infra.
2. **TrueNAS** (192.168.1.10): power on, verify NFS exports come up.
3. **pve1 and pve3**: power both on (roughly together — Ceph mon quorum
   needs both since pve2 is absent). Talos VMs autostart.
4. **Unset Ceph flags** once mons have quorum:

   ```bash
   ssh root@192.168.1.81 "ceph osd unset noout; ceph osd unset norecover; ceph osd unset norebalance; ceph osd unset nobackfill"
   ssh root@192.168.1.81 "ceph status"   # expect the usual pve2-degraded HEALTH_WARN, PGs active+undersized+degraded
   ```

5. **Verify Kubernetes**:

   ```bash
   export KUBECONFIG=./kubeconfig
   kubectl get nodes                      # 3x Ready
   flux get ks -A --status-selector ready=false
   flux get hr -A --status-selector ready=false
   kubectl get cluster.postgresql.cnpg.io -A
   kubectl get pods -A | grep -vE 'Running|Completed'
   ```

6. **If things are stuck**, known failure modes from past incidents:
   - Pods stuck `Completed`/not restarting → stale CRI state, delete the pod
     (see memory: talos-prod-1 containerd panic).
   - CNPG replica won't rejoin → delete PVC+pod to re-clone (see
     CNPG WAL slot retention incident).
   - Paperless celery wedge after broker restart → SIGKILL worker pgid via
     exec, never pod-restart (see memory note).
   - Loki ring stuck → docs/LOKI_MEMBERLIST_RING_RECOVERY.md.
   - Give Volsync/Gatus ~15 min to settle before chasing alerts.

7. **Note**: IP addressing assumes the new location keeps 192.168.1.0/24
   (OPNsense moves with the network, so it should). If the upstream WAN
   changes, only OPNsense WAN config needs touching.
