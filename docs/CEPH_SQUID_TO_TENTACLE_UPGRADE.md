# Ceph Squid (19.2.6) to Tentacle (20.2.4) upgrade on the PVE hosts

Written 2026-10-13, before the upgrade. Update the "Result" section at the end once it
has been run.

## Why

- Squid 19.2 is expected to reach upstream end of life around 2026-10-31. After that the
  Proxmox `ceph-squid` repo stops receiving security fixes; the cephx CVE-2025-30156
  hotfix (19.2.6) showed that this cluster does pull such fixes.
- Tentacle 20.2 shipped 2025-11-18 and is on its fifth point release (20.2.4, 2026-08-19).
  The Proxmox `ceph-tentacle` repo for trixie carries `20.2.4-pve5`.
- The hosts meet the Proxmox prerequisites (PVE >= 9.1.4, Ceph >= 19.2.3-pve3): all three
  run `pve-manager 9.2.21` with `ceph 19.2.6-pve4` (checked 2026-10-13).

## What this does NOT do

- **It does not clear the cephx "insecure key type" warnings.** Those come from the new
  aes256k key type introduced in 19.2.6 / 20.2.4 and are muted until 2026-11-01. Migrating
  the keys is a separate job that is gated on the Talos kernel: krbd / kcephfs need Linux
  7.0 for aes256k, and Talos 1.13.11 and 1.14.2 both ship 6.18. Do not combine the two
  changes in one window. See the memory note `ceph-19-2-6-aes256k-mixed-mon-incident` and
  the Proxmox thread linked at the end.
- It does not touch `require-min-compat-client` (currently `luminous`). The six "luminous"
  clients in `ceph features` are the three Talos nodes' krbd and kcephfs mounts; raising
  the floor can only hurt them.

## Topology reminder

| Host | IP | Ceph daemons | Notes |
| ---- | -- | ------------ | ----- |
| pve1 | 192.168.1.81 | mon, mgr (standby), mds (standby), osd.0 | kernel pinned to 7.0.14-8 after panics; pvestatd oops 2026-09-27; mon.pve1 ballooned to 62 GB on 2026-10-02. **Restart its mon last.** |
| pve2 | 192.168.1.82 | mon, mgr (active), mds, osd.1 | RMA replacement, fresh install 2026-10-02 |
| pve3 | 192.168.1.83 | mon, mgr (standby), mds (standby), osd.2 | |

- Pools: `.mgr`, `tank`, `cephfs_data`, `cephfs_metadata`, `talos`; all `size 3 min_size 2`,
  193 PGs, ~350 GiB stored, 12 % raw used.
- CephFS `cephfs`: `max_mds 1`, two standbys, `allow_standby_replay` not set.
- OSDs were recreated on 2026-10-03 (SLOG rebuild) so the Tentacle known issue about
  RocksDB sharding / META bloat on pre-Pacific OSDs does not apply.
- Talos VM disks live on each host's local ZFS, not on Ceph. Ceph serves Kubernetes PVCs
  (rook-ceph-external: RBD on `talos`, CephFS) and the PVE `tank` storage. A single OSD or
  mon restart is a short degraded window for PVC I/O, not an outage.
- Ceph admin commands run on any PVE host as root over SSH (`ssh root@192.168.1.8x`; the
  `.internal` names are dead).

## Pre-checks (abort on any failure)

Run on pve1:

```bash
pveversion                                   # 9.2.21 on all three (repeat per host)
ceph -s                                      # HEALTH_OK (only the AUTH_INSECURE_* mutes), 193 active+clean
ceph versions                                # every daemon 19.2.6
ceph mon dump | grep min_mon_release         # 19 (squid)
ceph osd dump | grep -c pg_upmap_primary     # 0  (kernel clients misroute on these)
ceph osd crush rule dump | grep -c msr       # 0  (kernel clients error on MSR rules)
ceph fs get cephfs | grep -E 'max_mds|allow_standby_replay'   # max_mds 1, no standby replay
ceph features                                # note the client list; expect luminous x6 + squid
ceph osd df                                  # all three OSDs up, ~12 % used
free -g                                      # pve1 needs headroom: mon RSS runaway killed VM 1003 last time
```

Kubernetes side, from the repo root:

```bash
export KUBECONFIG=./kubeconfig
flux get hr -n rook-ceph-external            # all Ready
kubectl -n rook-ceph-external get cephcluster rook-ceph-external -o jsonpath='{.status.ceph.health}{"\n"}'   # HEALTH_OK
kubectl get pvc -A | grep -c -E 'rook-ceph-(block|filesystem)'   # count of Ceph-backed PVCs, for the after check
```

Pick a time with no Volsync or CNPG backup window running (`kubectl get replicationsource -A`
shows next sync times) and no players on the Minecraft servers.

## Procedure

Daemons keep running the Squid binaries after `apt full-upgrade`; nothing changes until
each daemon is restarted, so the package step is safe to do on all hosts up front.

### 1. Set noout

```bash
ceph osd set noout
```

### 2. Switch the repo and upgrade packages, on every host

```bash
sed -i 's/ceph-squid/ceph-tentacle/' /etc/apt/sources.list.d/ceph.sources
apt update
apt full-upgrade          # expect ceph* 20.2.4-pve5; review the list, no kernel surprises
ceph versions             # still 19.2.6 everywhere, that is expected
```

Do not reboot. The pinned kernel on pve1 (`7.0.14-8-pve`) must stay pinned; check
`proxmox-boot-tool kernel list` shows the pin is still there after the upgrade.

### 3. Restart the monitors, one at a time, pve1 last

```bash
# on pve2
systemctl restart ceph-mon.target
ceph -s                  # wait for quorum with all 3 mons, HEALTH_OK (plus noout)
# on pve3
systemctl restart ceph-mon.target
ceph -s
# on pve1 — watch memory while it joins
systemctl restart ceph-mon.target
watch -n2 'ceph -s | head -12; ps -o rss= -C ceph-mon'
```

If mon.pve1 starts eating memory the way it did on 2026-10-02 (62 GB in 40 s), stop it
(`systemctl stop ceph-mon@pve1`) immediately: pve2 + pve3 keep quorum. Investigate before
retrying; the VM 1003 OOM kill is the thing to avoid.

Confirm the mon release floor moved:

```bash
ceph mon dump | grep min_mon_release        # 20 (tentacle)
```

### 4. Restart the managers

Proxmox normally restarts them with the package upgrade; check `ceph versions` and restart
if any mgr still reports 19.2.6:

```bash
systemctl restart ceph-mgr.target           # on each host that still shows 19.2.6
ceph -s                                     # mgr: one active, two standbys
```

### 5. Restart the OSDs, one host at a time

```bash
# on pve2
systemctl restart ceph-osd.target
watch -n5 'ceph -s | sed -n "/health/,/pgs/p"'   # wait for 193 active+clean (noout is the only warning)
# then pve3, then pve1, same thing
```

With `size 3 min_size 2`, one OSD down leaves every PG writable; do not start the next host
until the previous one is back to active+clean. Each restart takes about a minute here.

### 6. CephFS MDS

`max_mds` is already 1 and standby replay is off, so the Proxmox sequence reduces to:

```bash
ceph fs status cephfs                        # note which host is active
systemctl stop ceph-mds.target               # on the two STANDBY hosts
systemctl restart ceph-mds.target            # on the ACTIVE host
systemctl start ceph-mds.target              # on the two standby hosts
ceph fs status cephfs                        # 1 active, 2 standby, all 20.2.4
```

The failover takes a few seconds; CephFS PVCs (RWX) block briefly, they do not error.

### 7. Finalize

```bash
ceph versions                                # everything 20.2.4
ceph osd require-osd-release tentacle        # only after every OSD reports 20.2.4
ceph osd unset noout
ceph -s                                      # HEALTH_OK apart from the muted AUTH_INSECURE_* checks
```

Do **not** run `ceph osd set-require-min-compat-client` and do **not** enable
`allow_ec_optimizations` on any pool (OSDs crashed on it in 20.2.0; no EC pools here anyway).

### 8. Kubernetes follow-up (already staged in Git, merge after step 7)

Rook only uses the `cephImage` for its own Ceph CLI clients (toolbox, cmd-reporter) on an
external cluster, but it is kept on the same release as the servers on purpose. The staged
change:

- `kubernetes/apps/rook-ceph-external/rook-ceph/cluster/helmrelease.yaml`: `cephImage.tag`
  `v19.2.6` -> `v20.2.4` (this is also the rook v1.20 chart default).
- `.renovaterc.json5`: the `quay.io/ceph/ceph` rule moves from `allowedVersions: "<20"` to
  `"<21"`, so Renovate offers 20.2.x patches but not Umbrella (v21) until the hosts move
  again.
- `docs/PVE_HOST_LAYOUT.md`: Ceph column 19.2.6 -> 20.2.4.

Then:

```bash
flux reconcile ks rook-ceph-cluster -n rook-ceph-external
flux get hr -n rook-ceph-external
kubectl -n rook-ceph-external get pods -l app=rook-ceph-tools -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'   # quay.io/ceph/ceph:v20.2.4
kubectl -n rook-ceph-external exec deploy/rook-ceph-tools -- ceph -s     # talks to the Tentacle mons
kubectl -n rook-ceph-external get cephcluster rook-ceph-external -o jsonpath='{.status.ceph.health}{"\n"}'
```

If Renovate had already opened a PR for `quay.io/ceph/ceph` to v21 (it did: #560), close it;
the Renovate rule stops it from reopening.

## Verification

- `ceph -s`: HEALTH_OK, 193 active+clean, 3 mons in quorum, 3 OSDs up/in, 1/1 MDS.
- `ceph versions`: all 12 daemons `20.2.4`.
- `ceph features`: the same client list as before (luminous x6 + squid); nothing dropped.
- Kubernetes: every Ceph-backed PVC still bound, a fresh `kubectl -n <ns> exec` write on an
  RBD and a CephFS volume works, `flux get hr -A --status-selector ready=false` is empty.
- PVE: `tank` storage shows Active on all three hosts in the PVE UI.
- Grafana Ceph dashboard still receives metrics (the mgr prometheus module restarted).

## Rollback

There is no downgrade path once `min_mon_release` is 20. If a daemon misbehaves after its
restart, the mitigation is to stop that daemon (the cluster tolerates one of each) and fix
forward. Keep the window short and do not start the OSD step unless the mon step was clean.

## Known Tentacle issues (checked, not applicable here)

- META bloat on OSDs created before Pacific (ours are from 2026-10-03).
- OSD crash with `allow_ec_optimizations` on EC pools in 20.2.0 (no EC pools, and 20.2.4).
- NVMe-oF mgr module is not auto-enabled on upgrade (unused).
- RGW `LastModified` truncation to seconds (no RGW; S3 is Garage).

## References

- Proxmox wiki, Ceph Squid to Tentacle: <https://pve.proxmox.com/wiki/Ceph_Squid_to_Tentacle>
- Ceph Tentacle release notes: <https://docs.ceph.com/en/latest/releases/tentacle/>
- Kernel clients vs. `require-min-compat-client`:
  <https://docs.ceph.com/en/latest/rados/operations/require-min-compat-client/>
- cephx aes256k migration and Squid EOL (Proxmox forum):
  <https://forum.proxmox.com/threads/cephx-key-migration-procedure-and-ceph-19-2-squid-going-eol-soon.186276/>
- Related runbooks: [PVE2_RMA_GUIDE.md](PVE2_RMA_GUIDE.md) (the 19.2.5/19.2.6 mixed-mon
  incident), [ROOK_CEPH_V1_20_UPGRADE.md](ROOK_CEPH_V1_20_UPGRADE.md) (why the client image
  is pinned), [PVE_HOST_LAYOUT.md](PVE_HOST_LAYOUT.md).

## Result

Run 2026-10-13, 06:05 to 06:35 EDT. Every step went as written; no I/O errors, no VM impact,
no kernel errors on pve1. All 12 daemons on 20.2.4-pve5, `require_osd_release tentacle`,
`min_mon_release 20`, HEALTH_OK (plus the AUTH_INSECURE mutes), 193 active+clean.

- Packages: `apt full-upgrade` also pulled proxmox-kernel 7.0.14-23, qemu-server 9.2.11,
  libpve-storage-perl 9.1.13, pve-firmware 3.18-7. The new kernel is installed but not
  booted; pve1's pin on 7.0.14-8 survived.
- Mons: each rejoined quorum within 3-6 s. mon.pve1 sat at ~60 MiB RSS the whole time; the
  2026-10-02 runaway did not recur. Mgrs were restarted by the package upgrade itself.
- OSDs: 65 s / 110 s / 165 s to active+clean for osd.1 / osd.2 / osd.0 (the last one
  includes a deep scrub finishing). Volsync syncs for booklore (06:10) and world (06:15)
  ran during the OSD window and both reported Successful; with `min_size 2` nothing noticed.
- MDS: because the local shell is zsh, an unquoted `$standbys` list did not word-split and
  the first pass only restarted the active MDS; pve3 (still Squid) took over. Fixed by
  restarting the remaining daemons explicitly. CephFS stayed mounted throughout. Use
  explicit hostnames, not shell loops, when driving this from macOS.
- `ceph features` afterwards: luminous x6 (Talos kernel mounts) plus squid clients; nothing
  dropped. `require_min_compat_client` left at luminous on purpose.
- Rook: CephCluster `Connected`, `status.ceph.health` back to HEALTH_OK within a minute of
  unsetting noout (its view of the mons is the real connectivity check); CSI pods untouched;
  RBD write probe on a PVC OK. The toolbox pod's own `ceph -s` returns "RADOS permission
  error" both before and after the upgrade (pre-existing, tracked in the ceph-watch-items
  memory note), so it is not a usable verification step here.
