# Proxmox Host Thermals and CPU Frequency Tuning

Why the MS-01 hosts (`pve1`/`pve2`/`pve3`, i9-13900H) ran their CPU package at
78-85 C while idle and touched the 100 C Tjmax several times a day, what was
measured on 2026-11-07/08, and the fix that is now persisted on every host.

> **Goal**: keep the package at 40-50 C idle with no Tjmax excursions, without
> changing etcd or VM latency. Re-apply the unit in section 4 after any host
> reinstall; it is not managed by anything in Git.

## 1. Symptoms (2026-11-07)

Host node-exporter data (`job="pve-node-exporter"`, `node_hwmon_temp_celsius`,
`chip=~".*coretemp.*"`, `sensor="temp1"` is the package sensor):

| Host | 24 h avg | 24 h max | minutes above 95 C per day | package power |
| --- | --- | --- | --- | --- |
| pve1 | 84 C | 100 C | 4 | 35 W |
| pve2 | 66 C | 95 C | 0 | 39 W |
| pve3 | 78 C | 100 C | 22 | 31 W |

All at 5-7 % CPU and load around 1. Package throttle counters
(`/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count`) grew
by 0.4-0.9 million events per day. Nothing alerted.

## 2. Diagnosis

### 2.1 Two separate problems

- **Baseline (cooling hardware).** pve3 drew the least power yet ran hottest;
  pve2, the replacement chassis, drew the most and ran coolest. Identical BIOS
  (1.27), power limits (PL1 60 W / PL2 80 W) and governor on all three. The
  user cleaned pve3's cooler and moved pve1 on the rack on 2026-11-08; both
  idled around 58 C afterwards, matching pve2.
- **Spikes (frequency).** 1-second sampling of `thermal_zone1` showed the
  package jumping 64 -> 96 -> 78 C between consecutive samples while the host
  was 5-8 % busy. Every excursion above 95 C in Prometheus lasted one 30 s
  scrape, never two minutes, spread randomly over the hour and the day. The
  `performance` governor with `performance` EPP kept every core at 3.9 GHz
  when idle and let any wake-up turbo to 5.2 GHz; one core at that voltage
  heats its spot on the die to Tjmax in milliseconds, far faster than a fan can
  react. 2-minute CPU rates cannot see work that short, so the 24 h
  correlation between hot minutes and CPU busy was flat.

### 2.2 What is not available

- No fan sensor or PWM control is exposed to Linux on the MS-01: hwmon shows
  only `acpitz`, `coretemp` and the three NVMe drives, and the ACPI `Fan`
  cooling device is an on/off stub. The fan curve lives in the BIOS only.
- `platform_profile` does not exist; `thermald` and `fancontrol` are not
  installed and would have nothing to drive.

### 2.3 Useful commands

```bash
# package temperature once per second, with the fastest core and host busy
prev=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8}' /proc/stat)
for i in $(seq 1 30); do
  t=$(( $(cat /sys/class/thermal/thermal_zone1/temp)/1000 ))
  mhz=$(awk '/MHz/{print int($4)}' /proc/cpuinfo | sort -n | tail -1)
  cur=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8}' /proc/stat)
  echo "pkg=${t}C maxMHz=$mhz busy_jiffies=$((cur-prev))"; prev=$cur; sleep 1
done

# package power over 10 s (RAPL, root only)
e1=$(cat /sys/class/powercap/intel-rapl:0/energy_uj); sleep 10
e2=$(cat /sys/class/powercap/intel-rapl:0/energy_uj)
echo "$(( (e2-e1)/10000000 )) W"
```

Compare hosts by package power against temperature: same power and a hotter
package means a cooling problem; same temperature at lower power means the
cooler is fine and the heat is electrical.

## 3. Fix: intel_pstate tuning (applied 2026-11-08)

Three settings, applied at runtime first and trialled on pve3:

- `scaling_governor` = `powersave`. On intel_pstate with HWP this means
  hardware-managed p-states. The `performance` governor also locks EPP, so
  writes to it return `EBUSY`; set the governor first.
- `energy_performance_preference` = `balance_performance`. Cores idle low and
  turbo only for real work.
- `intel_pstate/min_perf_pct` = `40`. Without a floor the cores idled at
  400 MHz and etcd on that node went from fsync p50 0.58 ms / p99 3.5 ms to
  2.3 ms / 7.8 ms, VM steal from 0.3 % to 1.8 %. With the 40 % floor (about
  2 GHz) all three numbers are back at baseline.

Result, 4-minute averages on all three hosts: package 42-43 C average, 44-45 C
peak, 13-16 W. No Tjmax excursions since. etcd fsync p50 0.6 ms and p99 3.7 ms
on every node, apiserver p99 unchanged, nothing alerting.

Writes to cpufreq files of offlined CPUs (pve1 `4-7`, pve2 `4-5`, see
`PVE1_CPU_FAULT_INVESTIGATION.md`) fail with `Device or resource busy`; that is
expected and harmless.

## 4. Persistence

Install on **each** host (the repo copy is the text below; nothing in Git
applies it):

```bash
cat <<'EOF' >/etc/systemd/system/cpu-epp.service
[Unit]
Description=intel_pstate tuning (docs/PVE_THERMALS_AND_CPU_TUNING.md)
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'd=/sys/devices/system/cpu; \
  for f in $d/cpu*/cpufreq/scaling_governor; do \
    echo powersave > "$f"; done; \
  for f in $d/cpu*/cpufreq/energy_performance_preference; do \
    echo balance_performance > "$f"; done; \
  echo 40 > $d/intel_pstate/min_perf_pct'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cpu-epp.service
```

The first copy installed on 2026-11-08 predated the `min_perf_pct` line, so a
reboot would have brought the etcd fsync regression back while the unit
reported `active`. Always check the installed file for all three writes:

```bash
grep -c -E 'powersave|balance_performance|min_perf_pct' \
  /etc/systemd/system/cpu-epp.service   # 3 on a correct unit
```

Verify after a reboot:

```bash
systemctl is-active cpu-epp.service
cat /sys/devices/system/cpu/intel_pstate/min_perf_pct          # 40
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor      # powersave
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
```

To revert at runtime: write `performance` to every `scaling_governor` and `8`
to `min_perf_pct` (the EPP follows the governor).

## 5. Alerting

`kubernetes/apps/observability/kube-prometheus-stack/app/prometheusrule-pve-hosts.yaml`
(commit 9e1b02e9) adds:

- `PveHostCpuTemperatureHigh` (warning): package above 90 C for 15 min.
- `PveHostCpuTemperatureCritical` (critical): within 3 C of the reported
  critical temperature for 5 min, meaning sustained throttling.
- `PveHostNvmeTemperatureHigh` (warning): any NVMe composite sensor above
  70 C for 15 min. pve3's `nvme2` idles hottest (65 C, 78 C peak in a week).

None of them fired in a 7-day backtest before the tuning, and none since.

## 6. Related findings

- pve3 was shut down for the cooler work with the one-host procedure: `ceph
  osd set noout`, `kubectl cordon` + `drain`, `talosctl shutdown`, `qm
  shutdown` of the lab VM, `systemctl poweroff`. Pods pinned to the node's
  local storage (`postgres-N`, `dragonfly-N`, `garage-storage-N`) stay Pending
  until the node is back; `kubectl uncordon` and `ceph osd unset noout` once
  the PGs are `active+clean` again. 20 minutes end to end, no workload impact.
  pve3 had no kernel pin and came back on 7.0.14-28 (was 7.0.14-20).
- pve1, on kernel 7.0.14-8, inflates `node_disk_write_time_seconds_total` for
  `nvme0n1` (the Intel P4600 OSD/SLOG drive) by about 25,000 s in 25-39
  ten-minute windows per day, since at least 2026-10-19. Raw `/proc/diskstats`
  deltas, `io_time` (under 1 % busy) and the OSD's `op_w_latency` (1.2 ms)
  show real latency of 0.1-0.3 ms. It is a kernel accounting artifact; pve2
  (7.0.14-20) and pve3 (7.0.14-28) never show it. Ignore pve1 disk-latency
  panels built on that metric until pve1 leaves 7.0.14-8.

## Related documents

- `PVE_HOST_LAYOUT.md` - host-level settings table
- `PVE1_CPU_FAULT_INVESTIGATION.md` - offlined cores and the kernel pin
- `PVE_ZFS_SLOG_ON_P4600.md` - the etcd fsync baseline the floor protects
