# PVE: ZFS SLOG on the Intel P4600 (etcd fsync latency fix)

**Status:** DONE 2026-10-03. pve3 17:28-17:45, pve1 17:46-18:00, pve2 18:01-18:14 EDT, ~14 min
each including backfill, no client-visible impact. mclock profile reverted to `balanced`.

First 20 minutes after completion (all three SLOGs active, pve2 still backfilling for part
of the window):

| node | fsync p50 | fsync p99 | backend commit p99 |
| --- | --- | --- | --- |
| talos-prod-1 | 0.5 ms | 1.9 ms | 3.1 ms |
| talos-prod-2 | 0.9 ms | 6.0 ms | 18.5 ms |
| talos-prod-3 | 0.6 ms | 2.0 ms | 5.4 ms |

Re-check the 24 h numbers on 2026-10-04 and update this table.

## Why

etcd on every Talos node fsyncs its WAL into the VM disk `local-zfs:vm-100X-disk-2`,
a zvol on `rpool`. `rpool` is a mirror of two consumer 1 TB NVMe drives with no
power-loss protection, so every sync write pays a full NAND flush on the slower
mirror member. Guidance is fsync p99 < 10 ms; measured 2026-10-03 (24 h, Prometheus
`etcd_disk_wal_fsync_duration_seconds`):

| node | host | rpool mirror members | fsync p50 | fsync p99 | backend commit p99 |
| --- | --- | --- | --- | --- | --- |
| talos-prod-1 (.11) | pve1 | Kingston OM8PGP4 + Kingston NV3 | 2.5 ms | 18.9 ms | 37.8 ms |
| talos-prod-2 (.12) | pve2 | Kingston OM8PGP4 + Crucial P310 | 2.4 ms | 14.7 ms | 26.1 ms |
| talos-prod-3 (.13) | pve3 | Kingston OM8PGP4 + Kingston NV3 | 3.7 ms | 34.3 ms | 65.6 ms |

7-day p99 averages were 33-41 ms, with ~1 leader change/day and one 2 s fsync stall
(2026-10-03 14:53 UTC) that caused lease-loss restarts of kube-controller-manager and
several CSI/operator pods.

Each host also has one Intel DC P4600 3.2 TB (`SSDPE2KE032T7`, PLP, wearout 100 %)
fully consumed by its Ceph OSD, of which only ~345 GiB (11.5 %) is used. Carving a
32 GiB partition off it as a ZFS separate intent log (SLOG) moves every sync write on
`rpool` onto the enterprise drive. The OSD has to be destroyed and recreated on the
smaller partition because BlueStore cannot shrink.

Not considered: moving etcd/EPHEMERAL to Ceph RBD (adds network + 3x replication
latency and couples the control plane to Ceph health; past Ceph incidents would have
taken the API down).

## Current layout (2026-10-03)

| host | Intel P4600 dev | serial | OSD | rpool mirror partitions |
| --- | --- | --- | --- | --- |
| pve1 | /dev/nvme1n1 | PHLE746400BA3P2EGN | osd.0 | nvme0n1p3 (OM8PGP4) + nvme2n1p3 (NV3) |
| pve2 | /dev/nvme1n1 | PHLE746400EQ3P2EGN | osd.1 | nvme0n1p3 (OM8PGP4) + nvme2n1p3 (P310) |
| pve3 | /dev/nvme0n1 | PHLE746300173P2EGN | osd.2 | nvme1n1p3 (OM8PGP4) + nvme2n1p3 (NV3) |

- Ceph 19.2.6 on all mons/OSDs, 5 pools, all `size 3 / min_size 2`, 193 PGs.
- OSD LVM VG `ceph-<uuid>` spans the whole disk, 0 free. `gpt=0` on all three Intel drives.
- VM disks: `cache=none,iothread=1,discard=on,ssd=1` so guest flushes hit the zvol as
  sync writes and will land on the SLOG. `rpool/data` must keep `sync=standard`.
- Ceph toolbox pod in `rook-ceph-external` has a RADOS permission error; run all
  `ceph` commands on a PVE host (or read status via the PVE API).

## Target layout per Intel drive

```text
GPT
  part1  32 GiB   "slog"   -> zpool add rpool log <part1>
  part2  rest     "osd"    -> pveceph osd create <part2>   (ceph-volume LVM on the partition)
```

32 GiB is far more than ZFS will ever use (the ZIL holds at most a few seconds of
sync writes before the txg commits) and leaves the OSD at ~2.95 TiB.

## Risks and gotchas

- **Redundancy window.** With 3 OSDs and `size 3`, taking one OSD out leaves every PG
  `active+undersized+degraded` on 2 copies until the new OSD is backfilled. There is
  nowhere to rebalance to, so do not "wait for rebalancing" after `ceph osd out`.
  Any failure of the other two OSDs during that window (~20-40 min per host) stalls
  all Ceph I/O (`min_size 2`). Do one host at a time, never overlap, pick a quiet time,
  and make sure Ceph is `HEALTH_OK` with all PGs `active+clean` before starting the
  next host.
- **Single, unmirrored SLOG.** If the P4600 dies, ZFS keeps running (log falls back to
  the main pool) but the next boot will refuse to import `rpool` without the log
  device. Recovery from the initramfs prompt: `zpool import -m -N rpool; exit`.
  Then `zpool remove rpool <log>` once booted. The OSD already depends on the same
  drive, so this adds no new single point of failure, only a new boot dependency.
- **Do not `zpool upgrade rpool`** even though `zpool status` suggests it (pve1/pve3
  report disabled features); the bootloader must keep being able to read the pool.
- **Backfill load.** Backfill of ~345 GiB onto a fresh OSD competes with client I/O
  (Talos RBD volumes live in the `talos` pool). Temporarily switch mclock to
  `high_recovery_ops` to shorten the window, and switch it back afterwards.
- **OSD id reuse.** `pveceph osd destroy` frees the id; `pveceph osd create` reuses the
  lowest free id, so the host gets the same osd number back. The old per-OSD
  `osd_mclock_max_capacity_iops_ssd` entry is removed so the new OSD re-benchmarks.
- `pveceph osd create <part2>` refuses with `device '/dev/nvmeXn1p2' is already in use`
  once part1 belongs to rpool (it judges the parent disk, not the partition). Use
  `ceph-volume lvm create` directly (step 5); the bootstrap-osd keyring already exists
  on each host. The OSD it creates is fully visible to PVE afterwards.
- Talos VMs are not touched. No VM restart, no drain. The pending memory bumps for
  talos-prod-2/3 are independent and can be done before or after.
- Version lesson from the pve2 RMA: all daemons must be on the same Ceph point release
  before creating an OSD (they are: 19.2.6 everywhere).

## Pre-flight (once, from any PVE host)

```bash
ceph -s                                   # HEALTH_OK (only the muted cephx warnings), 193 active+clean
ceph versions                             # everything 19.2.6
ceph osd df tree                          # ~11.5 % used on each OSD
ceph osd dump | grep -E '^flags'          # no noout/norebalance/nobackfill set
ceph config get osd osd_mclock_profile    # expect balanced
zpool status rpool                        # ONLINE, no scrub/resilver in progress (on EVERY host)
zfs get -r sync rpool/data | grep -v standard   # must print only the header
```

Speed up backfill for the whole exercise (revert at the end):

```bash
ceph config set osd osd_mclock_profile high_recovery_ops
```

## Per-host procedure

Order: **pve3** (worst fsync, osd.2) -> **pve1** (osd.0) -> **pve2** (osd.1).
Run everything on the host being worked on. Set the variables first:

```bash
# pve3
OSD=2; SERIAL=PHLE746300173P2EGN
# pve1
OSD=0; SERIAL=PHLE746400BA3P2EGN
# pve2
OSD=1; SERIAL=PHLE746400EQ3P2EGN

DISK=/dev/disk/by-id/nvme-INTEL_SSDPE2KE032T7_${SERIAL}
ls -l "$DISK" && readlink -f "$DISK"      # confirm it resolves to the Intel drive and matches `ceph-volume lvm list`
ceph-volume lvm list | grep -B2 -A12 "osd id *$OSD" | grep -E 'osd id|devices'
```

### 1. Take the OSD out and stop it

```bash
ceph osd out osd.$OSD
ceph -s                                   # PGs go active+undersized+degraded immediately; expected
pveceph stop --service osd.$OSD
systemctl status ceph-osd@$OSD --no-pager | head -5    # inactive
```

### 2. Destroy the OSD and wipe the drive

```bash
pveceph osd destroy $OSD --cleanup        # removes crush/auth/osd entry, zaps LVM, pvremove
ceph osd tree                             # osd.$OSD gone, 2 OSDs up/in
ceph config rm osd.$OSD osd_mclock_max_capacity_iops_ssd 2>/dev/null || true
wipefs -a "$DISK"
lsblk "$DISK"                             # no partitions, no holders
```

### 3. Partition

```bash
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+32G -t1:BF01 -c1:slog "$DISK"
sgdisk -n2:0:0    -t2:8E00 -c2:osd  "$DISK"
partprobe "$DISK"; udevadm settle
sgdisk -p "$DISK"
ls -l "${DISK}-part1" "${DISK}-part2"
```

### 4. Add the SLOG (online, instant)

```bash
zpool add -o ashift=12 rpool log "${DISK}-part1"
zpool status rpool                        # new "logs" section with the part1 device ONLINE
```

### 5. Recreate the OSD on part2

```bash
test -s /var/lib/ceph/bootstrap-osd/ceph.keyring || ceph auth get client.bootstrap-osd -o /var/lib/ceph/bootstrap-osd/ceph.keyring
ceph-volume lvm create --bluestore --data "$(readlink -f "${DISK}-part2")"
```

(`pveceph osd create` does not work here, see gotchas. The `--> Cannot use None (None)
with --bluestore` and `Incompatible flags` lines ceph-volume prints are harmless.)

Then:

```bash
ceph osd tree                             # osd.$OSD back under this host, up/in, crush weight ~2.88
watch -n 10 'ceph -s | sed -n "/pgs:/,/^$/p"; ceph osd df tree | tail -5'
```

Wait until all 193 PGs are `active+clean` and the new OSD shows ~11 % used. Observed:
~14 minutes per host for 345 GiB with the `high_recovery_ops` profile.

### 6. Verify this host before moving on

```bash
ceph -s                                   # HEALTH_OK, 193 active+clean, 3 up / 3 in
zpool status rpool                        # mirror + logs, ONLINE, 0 errors
zpool iostat -v rpool 5 3                 # log device shows write activity under sync load
```

Optional synthetic check of sync write latency on the host (needs `apt install fio`):

```bash
fio --name=sync4k --filename=/rpool/data/fio.tmp --rw=write --bs=4k --size=256M \
    --direct=1 --fsync=1 --runtime=20 --time_based --group_reporting; rm -f /rpool/data/fio.tmp
```

Before: fsync-bound, ~1-3 ms avg with long tails. After: well under 1 ms.

## After all three hosts

```bash
ceph config rm osd osd_mclock_profile     # back to balanced
ceph -s; ceph osd df tree; zpool status   # on each host
```

Confirm in Prometheus after 24 h (query via `kubectl exec -n default paperless-ngx-0 -c main -- curl ...`,
no port-forward):

```promql
histogram_quantile(0.99, sum by (instance, le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket[1d])))
histogram_quantile(0.99, sum by (instance, le) (rate(etcd_disk_backend_commit_duration_seconds_bucket[1d])))
sum by (instance) (increase(etcd_server_leader_changes_seen_total[1d]))
```

Target: fsync p99 < 10 ms on all three nodes, leader changes ~0/day. Then update the
table at the top of this document.

## Rollback

- SLOG only: `zpool remove rpool <part1 by-id>` (online; sync writes return to the
  mirror). The OSD stays on part2, which is fine permanently.
- OSD: it is just a smaller OSD. No rollback needed; to reclaim the 32 GiB, repeat the
  destroy/create cycle on the whole disk.

## Related

- `docs/PVE2_RMA_GUIDE.md` Part 3 / 7.4 (OSD removal and recreation, Ceph version lesson)
- `docs/PVE2_NVME_REPLACEMENT_GUIDE.md` (rpool mirror member replacement)
- `talos/patches/controller/cluster.yaml` (etcd extraArgs; heartbeat 250 ms / election 2500 ms
  tuning is a separate, optional change)
