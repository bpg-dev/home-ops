# PVE2 Crash Investigation - January 2026

## Summary

**Node**: pve2 (192.168.1.82)
**Issue**: Repeated system hangs requiring manual power cycle
**Root Cause**: Faulty Kingston OM8PGP41024Q-A0 NVMe causing PCIe bus freeze
**Resolution**: Driver unbound pending physical drive replacement

## Timeline

| Date           | Event                                                     |
|----------------|-----------------------------------------------------------|
| Jan 4, 2026    | First crashes observed                                    |
| Jan 4-7, 2026  | Multiple crashes (4+ incidents)                           |
| Jan 7, 2026    | NVMe identified as failing (717+ errors), offlined in ZFS |
| Jan 15, 2026   | Crashes continued despite ZFS offline                     |
| Jan 16, 2026   | Investigation revealed PCIe-level issues; driver unbound  |

## Crash Analysis

### Symptoms

- System completely unresponsive (keyboard dead, network unreachable)
- Hardware watchdog (iTCO_wdt, 10s timeout) failed to trigger reboot
- Required manual power cycle to recover
- `pvestatd` segfault visible on console before hang

### Console Output Before Crash

```text
perf: interrupt took too long (2501 > 2500), lowering kernel.perf_event_max_sample_rate to 79000
hrtimer: interrupt took 28038 ns
perf: interrupt took too long (3129 > 3126), lowering kernel.perf_event_max_sample_rate to 63000
perf: interrupt took too long (3913 > 3911), lowering kernel.perf_event_max_sample_rate to 51000
pvestatd[17411]: segfault at 11 ip 0000061b4a78e3aa0 sp 00007ffdda275750 error 6 in perl[...] likely on CPU 3 (core 4, socket 0)
```

### Key Findings

1. **NVMe Error Log**: 726 errors (up from initial 717)
2. **PCIe Link Degraded**: Running at 8GT/s x2 instead of rated 16GT/s x4
3. **PCIe Device Status**: `CorrErr+` and `UnsupReq+` flags set
4. **42 Unsafe Shutdowns** recorded on the drive
5. **No EDAC memory errors**: RAM is healthy (0 correctable, 0 uncorrectable)

### PCIe Status (Before Fix)

```text
59:00.0 Non-Volatile memory controller: Kingston Technology Company, Inc. OM8PGP4 NVMe PCIe SSD
    LnkSta: Speed 8GT/s (downgraded), Width x2 (downgraded)
    DevSta: CorrErr+ NonFatalErr- FatalErr- UnsupReq+ AuxPwr- TransPend-
```

### Why Watchdog Failed

The hang occurred at the **hardware/PCIe level**, not software:

1. Faulty NVMe held the PCIe bus in an invalid state
2. All PCIe traffic blocked (USB keyboard, network NIC)
3. CPU couldn't execute any code, including watchdog reset handling
4. Even hardware watchdog reset couldn't propagate through frozen chipset

## Root Cause

The Kingston OM8PGP41024Q-A0 NVMe drive, even when **offlined in ZFS**, was still:

1. Active on the PCIe bus and generating hardware errors
2. Operating on a degraded PCIe link (signal integrity issues)
3. Sending interrupts and consuming CPU cycles
4. Occasionally freezing the PCIe fabric, causing complete system hangs

**Important**: Offlining a drive in ZFS only stops ZFS from using it. The kernel NVMe driver still communicates with the device for health monitoring, SMART data, etc. This communication was triggering the PCIe freezes.

## Resolution

### Immediate Fix (Applied 2026-01-16)

1. **Unbound NVMe driver** from the faulty device:

   ```bash
   echo "0000:59:00.0" > /sys/bus/pci/drivers/nvme/unbind
   ```

2. **Set driver override** to prevent rebinding:

   ```bash
   echo 'none' > /sys/bus/pci/devices/0000:59:00.0/driver_override
   ```

3. **Created udev rule** for persistence across reboots:

   ```bash
   # /etc/udev/rules.d/99-block-faulty-nvme.rules
   ACTION=="add", SUBSYSTEM=="pci", KERNEL=="0000:59:00.0", ATTR{driver_override}="none"
   ```

### Permanent Fix

Physical replacement of the faulty NVMe drive with Crucial P310 1TB.
See: [PVE2_NVME_REPLACEMENT_GUIDE.md](PVE2_NVME_REPLACEMENT_GUIDE.md)

## Post-Fix Status (Updated 2026-01-18)

### NVMe Status

The faulty Kingston OM8PGP41024Q-A0 was **physically removed** on 2026-01-17.

```text
Node        Model                    Status
nvme0       Intel SSDPE2KE032T7      ✓ Healthy (Ceph OSD)
nvme1       Kingston SNV3S1000G      ✓ Healthy (ZFS rpool)
```

ZFS pool running in degraded mode on single healthy drive.

### CPU Core 4 Investigation

**Observation**: Crashes occurred on CPU 3 (core 4) even with NVMe driver unbound
(but drive still physically present).

```text
pveproxy worker[23030]: segfault ... error 6 in perl... likely on CPU 3 (core 4, socket 0)
pvestatd[1750]: segfault ... error 6 in perl... likely on CPU 3 (core 4, socket 0)
pvestatd[348299]: segfault ... error 7 in perl... likely on CPU 3 (core 4, socket 0)
```

**Timeline**:

1. NVMe driver unbound to stop crashes
2. System crashed again (NVMe physically present, driver unbound)
3. NVMe **physically removed** after that crash
4. Now monitoring to see if crashes were caused by NVMe or CPU

**Current status (2026-01-18)**:

- Faulty NVMe: **Physically removed**
- CPU core 4: **Enabled** (monitoring for crashes)
- Online CPUs: `0-19` (all 20 threads active)

**If crashes return on core 4**, disable it with:

```bash
# Immediate disable
echo 0 > /sys/devices/system/cpu/cpu2/online
echo 0 > /sys/devices/system/cpu/cpu3/online

# To make persistent, create systemd service (see below)
```

## Cleanup After NVMe Replacement

After installing the replacement Crucial P310 drive:

```bash
# Remove the udev rule (no longer needed since drive was removed)
rm /etc/udev/rules.d/99-block-faulty-nvme.rules
udevadm control --reload-rules
```

## CPU Core 4 - Contingency Plan

If crashes return on CPU core 4 after NVMe removal:

### Disable Core 4 (Immediate)

```bash
echo 0 > /sys/devices/system/cpu/cpu2/online
echo 0 > /sys/devices/system/cpu/cpu3/online
```

### Disable Core 4 (Persistent)

Create systemd service:

```bash
cat > /etc/systemd/system/disable-cpu-core4.service << 'EOF'
[Unit]
Description=Disable CPU Core 4 (CPUs 2,3) due to suspected hardware fault
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > /sys/devices/system/cpu/cpu3/online; echo 0 > /sys/devices/system/cpu/cpu2/online'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable disable-cpu-core4.service
```

### Long-term Options

1. **Keep running with core disabled** - Minor performance loss (~10%)
2. **Check for BIOS/microcode updates** - May address CPU errata
3. **RMA the CPU** - If under warranty, this is a hardware defect
4. **Run memtest86+** - If crashes appear on other cores, suspect RAM

## Lessons Learned

1. **Offlining a drive in ZFS is not enough** - The kernel driver still interacts with the hardware
2. **Faulty NVMe can cause system-wide hangs** - PCIe bus freeze affects all devices
3. **Hardware watchdog can fail** - When the hang is at the PCIe/chipset level
4. **PCIe link degradation is a warning sign** - Check `lspci -vvs` for link status
5. **Driver unbind is an effective workaround** - Stops all kernel interaction with faulty hardware

## Diagnostic Commands Reference

```bash
# Check for PCIe errors
lspci -vvs 59:00.0 | grep -E 'LnkSta|DevSta'

# Check NVMe error log
nvme error-log /dev/nvme1 | head -20
smartctl -a /dev/nvme1

# Check memory errors (EDAC)
cat /sys/devices/system/edac/mc/mc*/ce_count
cat /sys/devices/system/edac/mc/mc*/ue_count

# Check crash history
last reboot | head -10

# Check for segfaults
journalctl --since '7 days ago' | grep -i segfault

# Verify driver binding
ls /sys/bus/pci/devices/0000:59:00.0/driver 2>/dev/null || echo "No driver bound"
```

## Document History

- **Created**: 2026-01-16
- **Updated**: 2026-01-18 (NVMe physically removed; CPU core 4 re-enabled for testing)
- **Author**: Home-ops automation
- **Related**: [PVE2_NVME_REPLACEMENT_GUIDE.md](PVE2_NVME_REPLACEMENT_GUIDE.md)
