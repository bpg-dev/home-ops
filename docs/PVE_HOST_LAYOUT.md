# Proxmox Host Layout (reference)

Current state of the three Proxmox VE hosts that run the Talos cluster. Update this file
whenever hardware, disk layout, VM placement or VM sizing changes. Last verified
2026-10-03.

## Hosts

| Host | IP | Hardware | RAM | PVE / Ceph | Ceph roles | Talos VM |
| --- | --- | --- | --- | --- | --- | --- |
| pve1 | 192.168.1.81 | Minisforum MS-01, i9-13900H | 94 GiB usable | PVE 9.2, Ceph 19.2.6 | mon, mgr, mds, osd.0 | 1001 talos-prod-1 (192.168.1.11) |
| pve2 | 192.168.1.82 | Minisforum MS-01, i9-13900H (RMA replacement, 2026-10-02) | 94 GiB usable | PVE 9.2, Ceph 19.2.6 | mon, mgr, mds, osd.1 | 1002 talos-prod-2 (192.168.1.12) |
| pve3 | 192.168.1.83 | Minisforum MS-01, i9-13900H | 94 GiB usable | PVE 9.2, Ceph 19.2.6 | mon, mgr, mds, osd.2 | 1003 talos-prod-3 (192.168.1.13) |

One Talos VM per host. VM placement and sizing are managed by OpenTofu in
`~/code/home-ops-infra/tf` (module `k8s-prod`, bpg/proxmox provider); do not change
them in the PVE UI without updating that repo. pve1 has had CPU faults and kernel
panics on newer kernels (pinned to 7.0.14-8); see `PVE1_CPU_FAULT_INVESTIGATION.md`.

## Disks per host

Every host has the same three NVMe drives in different slot order:

| Role | Model | Notes |
| --- | --- | --- |
| Ceph OSD + ZFS SLOG | Intel DC P4600 3.2 TB (`SSDPE2KE032T7`), PLP | GPT since 2026-10-03: part1 32 GiB `slog`, part2 2.88 TiB `osd` |
| rpool mirror member | Kingston OM8PGP41024Q-A0 1 TB (OEM) | consumer, no PLP |
| rpool mirror member | Kingston NV3 1 TB (pve1, pve3) or Crucial P310 1 TB (pve2) | consumer, no PLP; NV3 is the slowest for sync writes |

| Host | Intel P4600 | by-id | OSD | rpool mirror |
| --- | --- | --- | --- | --- |
| pve1 | /dev/nvme1n1 | `nvme-INTEL_SSDPE2KE032T7_PHLE746400BA3P2EGN` | osd.0 on `-part2` | nvme0n1p3 (OM8PGP4) + nvme2n1p3 (NV3) |
| pve2 | /dev/nvme1n1 | `nvme-INTEL_SSDPE2KE032T7_PHLE746400EQ3P2EGN` | osd.1 on `-part2` | nvme0n1p3 (OM8PGP4) + nvme2n1p3 (P310) |
| pve3 | /dev/nvme0n1 | `nvme-INTEL_SSDPE2KE032T7_PHLE746300173P2EGN` | osd.2 on `-part2` | nvme1n1p3 (OM8PGP4) + nvme2n1p3 (NV3) |

The 1 TB drives are partitioned identically: p1 BIOS boot (1 MB), p2 EFI (1 GB), p3 ZFS.

### rpool

```text
rpool
  mirror-0
    <OM8PGP4>-part3
    <NV3 or P310>-part3
  logs
    nvme-INTEL_SSDPE2KE032T7_<serial>-part1     # 32 GiB SLOG, added 2026-10-03
```

- `rpool/data` holds the Talos VM disks (`vm-100X-disk-2`, 256 GiB zvols, `sync=standard`).
  The VMs use `cache=none`, so guest fsyncs (etcd WAL, containerd) are ZFS sync writes
  and land on the SLOG. This cut etcd fsync p99 from 15-34 ms to about 2 ms
  (`PVE_ZFS_SLOG_ON_P4600.md`).
- **Boot dependency:** rpool will not auto-import if the Intel drive is missing. From the
  initramfs prompt: `zpool import -m -N rpool; exit`, then `zpool remove rpool <log>`.
- Do not `zpool upgrade rpool` even though `zpool status` suggests it; the bootloader
  must keep reading the pool.
- Replacing a mirror member: `PVE2_NVME_REPLACEMENT_GUIDE.md`. The log vdev is not part
  of the mirror; leave it alone during that procedure.

### Ceph OSDs

- One BlueStore OSD per host on the Intel P4600 `-part2`, created with
  `ceph-volume lvm create --bluestore --data /dev/nvmeXn1p2` (LVM VG `ceph-<uuid>` on
  the partition). `pveceph osd create` refuses the partition ("device is already in
  use") because part1 belongs to rpool; use ceph-volume directly. PVE manages the
  resulting OSD normally.
- Recreating an OSD: `ceph osd out N; pveceph stop --service osd.N;
  pveceph osd destroy N --cleanup` zaps only the OSD LVM, then re-run ceph-volume on
  `-part2`. Do NOT `wipefs`/`sgdisk --zap-all` the whole disk unless you also intend to
  re-add the SLOG. Full procedure with timings in `PVE_ZFS_SLOG_ON_P4600.md`.
- With 3 OSDs and `size 3 / min_size 2`, any single OSD rebuild runs the cluster on two
  copies for ~15 minutes (345 GiB backfill). Never take two OSDs down at once.

## Ceph pools (all replicated size 3, min_size 2, 193 PGs total)

| Pool | Use | Data (2026-10-03) |
| --- | --- | --- |
| talos | RBD for Kubernetes `rook-ceph-block` (external Rook) | ~325 GiB |
| tank | RBD for PVE VM disks (`tank` storage) | ~12 GiB |
| cephfs_data / cephfs_metadata | CephFS for `rook-ceph-filesystem` and PVE `cephfs` storage | ~8 GiB |
| .mgr | Ceph mgr | - |

Public/cluster network is the 10 GbE LAN. The Rook toolbox pod in `rook-ceph-external`
cannot run `ceph` commands (RADOS permission error); use SSH to a PVE host, or the PVE
API (`/cluster/ceph/status`, `/nodes/<n>/disks/*`, `/nodes/<n>/ceph/osd`).

## Talos VMs

| Setting | Value |
| --- | --- |
| CPU | 8 cores, `cpu: host` |
| Memory | **48 GiB** (`memory: 49152`), raised from 32 GiB on 2026-10-03 because requests sat at 62-81 % and the hosts have the headroom |
| Disk | `scsi0: local-zfs:vm-100X-disk-2`, 256 GiB, `cache=none,discard=on,iothread=1,ssd=1`, virtio-scsi-single |
| Boot | UEFI (`efidisk0`), `onboot: 1`, QEMU guest agent enabled |
| Talos | v1.13.11 with Kubernetes v1.36.3 (upgraded 2026-10-04 via `task talos:upgrade-node` per node, then `talosctl upgrade-k8s`). EPHEMERAL (incl. etcd) lives on the single VM disk |

Memory changes via `qm set` or OpenTofu are only applied on a cold start. Procedure per
node, one at a time: `talosctl shutdown --nodes <ip> --wait` (cordons and drains),
`qm set <vmid> --memory 49152`, `qm start <vmid>`. Before touching talos-prod-3 move the
CNPG primary off it (`kubectl cnpg promote postgres postgres-2 -n postgresql-system`),
and after any node restart check the Loki ring (`LOKI_MEMBERLIST_RING_RECOVERY.md`).

Status 2026-10-03 19:10 EDT: all three VMs restarted with 48 GiB (node capacity
49240948Ki each); `tofu plan` reports no changes. Each restart took about 3 minutes from
`talosctl shutdown` to the node being Ready again; the only follow-up needed was a Loki ring
`forget` for the pod that had lived on the restarted node.

## Related documents

- `PVE_ZFS_SLOG_ON_P4600.md` - SLOG + OSD rebuild runbook and etcd latency numbers
- `PVE2_RMA_GUIDE.md` - full node replacement, Ceph version ordering lessons
- `PVE2_NVME_REPLACEMENT_GUIDE.md` - replacing an rpool mirror member
- `CLUSTER_SHUTDOWN_STARTUP_RUNBOOK.md` - full power-down and power-up
- `PVE_WATCHDOG_SETUP.md`, `PVE_LOG_FORWARDING.md` - per-host services
