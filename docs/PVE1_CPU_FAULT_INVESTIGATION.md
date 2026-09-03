# PVE1 CPU Fault Investigation (2026-09)

## Summary

pve1 (Minisforum MS-01, Intel Core i9-13900H, no ECC) produces random userland
segfaults and general protection faults in unrelated processes, concentrated on
logical CPUs 6 and 7 (one physical core, kernel `core 12`, `lscpu` core 3). The
fault rate has been accelerating since August 2026. pve3 is the identical model
on the same kernel and microcode and has never logged a single fault. This is
the same signature that led to the pve2 core-disable and RMA
(`docs/PVE2_CRASH_INVESTIGATION.md`).

On 2026-09-02 the kubelet on talos-prod-1 (hosted on pve1) livelocked with no
software precursor, taking the node NotReady for ~16 hours.

## Host evidence

Strict pattern: `segfault at|general protection fault|invalid opcode|Oops:|BUG: unable`
over `journalctl -k`, per boot. "CPU 6" attribution comes from the kernel's
`likely on CPU N` hint, which segfaults carry and GPF traps do not.

| Boot window        | Faults | Attributed to CPU 6 | Other |
|--------------------|-------:|--------------------:|-------|
| 2026-01-15 → 03-02 | 0      |                     |       |
| 2026-03-02 → 06-27 | 1      |                     |       |
| 2026-06-27 → 08-02 | 1      |                     | ksmd GPF panic (see pve1 KSM note) |
| 2026-08-02 (1h)    | 3      | 1                   |       |
| 2026-08-02 → 08-19 | 10     | 7                   | 1 on CPU 4 |
| 2026-09-01 → 09-02 | 5 in 22h | 3                 | 2 GPFs, no attribution |

Victims on 2026-09-01/02: `pveproxy` (perl), `pvecm` (perl), `ceph-osd` (libc),
`ceph` (python3.13 GPF), `rocksdb:low` (GPF inside libtcmalloc), and a
`mon.pve1` crash at 05:56 UTC with the backtrace inside tcmalloc.

Guest side on pve1: `envoy` segfault inside talos-prod-3 (2026-09-02 04:38 UTC),
containerd panic and kubelet cadvisor panic on talos-prod-1 (August 2026).

Not the cause: no MCE, no EDAC errors, ZFS pool healthy, kernel 7.0.14-8-pve is
shared with fault-free pve3, microcode 0x6133 on both.

CPU topology (`lscpu -e`): CPUs 6,7 → core 3 (P-core), `core_id` 12.
Both VMs (1001 talos-prod-1, 1003 talos-prod-3) use 8 vCPUs, `cpu: host`,
no affinity, so 18 remaining threads are sufficient.

## kubelet livelock on talos-prod-1 (2026-09-02)

- ~03:55 EDT: last healthy Prometheus scrape of kubelet (goroutines ~372,
  CPU 0.03 cores, PLEG p99 10 ms). 04:00: all kubelet targets down.
- Talos: `kubelet` service Running / health Fail,
  `Get "http://127.0.0.1:10248/healthz": context deadline exceeded`; even TCP
  connect to 10250 timed out. etcd, containerd, apid stayed healthy.
- All 19 kubelet threads parked in `futex_wait`, `inotify_read`, `nanosleep`.
  No D-state, no `pipe_write`. CPU time still climbing ~13% of a core →
  Go-level livelock, not I/O.
- No goroutine dump obtainable: no pod can start on a NotReady node and
  `talosctl` cannot send SIGQUIT. Internal trigger unknown.
- Recovery: VM power-cycled from pve1 at 20:13 EDT (`qm stop`/`qm start`).
  Node Ready within minutes, all pods recovered.

Red herrings ruled out during the investigation:

- `read-only file system` chown/lchown flood in kubelet logs: benign fsGroup
  ownership pass over volsync kopia cache PVCs, present on all three nodes.
  It emits ~15k lines in <100 ms and rotates Talos' 2×5 MB kubelet log window,
  destroying history. Fix separately.
- containerd `container event discarded`: normal without EventedPLEG.

## Mitigation: offline core 12 (CPUs 6,7)

Immediate (live, safe with VMs running; the scheduler migrates vCPU threads):

```bash
ssh root@192.168.1.81 'echo 0 > /sys/devices/system/cpu/cpu7/online; echo 0 > /sys/devices/system/cpu/cpu6/online; cat /sys/devices/system/cpu/offline; nproc'
```

Persistent:

```bash
ssh root@192.168.1.81 'cat > /etc/systemd/system/disable-cpu-core12.service <<EOT
[Unit]
Description=Disable CPU core 12 (logical CPUs 6,7; lscpu core 3) due to suspected hardware fault - see docs/PVE1_CPU_FAULT_INVESTIGATION.md
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo 0 > /sys/devices/system/cpu/cpu7/online; echo 0 > /sys/devices/system/cpu/cpu6/online"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload && systemctl enable --now disable-cpu-core12.service && systemctl is-active disable-cpu-core12.service'
```

Verify:

```bash
ssh root@192.168.1.81 'cat /sys/devices/system/cpu/offline; nproc; dmesg -T | grep -E "CPU [67] is now offline"; qm list'
```

Expected: offline `6-7`, nproc `18`, both VMs still `running`.

To revert: `systemctl disable --now disable-cpu-core12.service; echo 1 > /sys/devices/system/cpu/cpu6/online; echo 1 > /sys/devices/system/cpu/cpu7/online`.

## Monitoring after the change

```bash
# Any new fault since the core was disabled?
ssh root@192.168.1.81 'journalctl -k --since "2026-09-02 20:00" --no-pager | grep -E "segfault at|general protection fault|invalid opcode|Oops:"'

# Which CPU, if any
ssh root@192.168.1.81 'journalctl -k --no-pager | grep "segfault at" | grep -oE "on CPU [0-9]+" | sort | uniq -c'

# Guests on pve1
talosctl -n 192.168.1.11,192.168.1.13 dmesg | grep -iE "segfault|general protection|traps:"
```

Decision rule:

- No faults for several weeks → keep the core offline, plan RMA at leisure.
- Faults continue on other CPUs → shared-component defect (L3, ring, memory
  controller), same as pve2's second crash. Treat pve1 as needing RMA and
  move talos-prod-3 off it as soon as pve2 is back.

## Long-term options

1. Keep running with core 12 offline (~10% peak CPU loss).
2. BIOS/microcode update check for the MS-01 (Intel 13th-gen Vmin-shift
   guidance officially targets desktop parts; treat mobile as unproven).
3. RMA pve1 (CPU is soldered on the MS-01 → whole-unit RMA, as with pve2).
4. Optional: `memtest86+` overnight to rule out the DDR5 SODIMMs (Crucial
   2×48 GB, no ECC), since faults were not 100% on one core.

## Related

- `docs/PVE2_CRASH_INVESTIGATION.md`, `docs/PVE2_RMA_GUIDE.md`
- `docs/CLUSTER_SHUTDOWN_STARTUP_RUNBOOK.md` (2026-09-01 startup, osd.0 segfaults on pve1)
- Talos note: `talosctl -n <ip> service kubelet restart` or `talosctl reboot`
  for a wedged kubelet; prefer a full VM power cycle when host memory
  corruption is suspected.
