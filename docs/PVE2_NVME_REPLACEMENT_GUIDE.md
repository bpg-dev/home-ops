# PVE2 NVMe Drive Replacement Guide

## Overview

This guide documents the process of replacing the failing Kingston OM8PGP41024Q-A0 NVMe drive (`/dev/nvme2`) on **pve2** (192.168.1.82) with a new Crucial P310 1TB drive.

> **⚠️ STATUS UPDATE (2026-01-18)**
>
> - The faulty Kingston OM8PGP41024Q-A0 has been **physically removed**
> - CPU core 4 showed crashes but is **currently enabled** for testing
> - See: [PVE2_CRASH_INVESTIGATION.md](PVE2_CRASH_INVESTIGATION.md) for full details
>
> **Before installing replacement drive**, remove the old udev rule:
>
> ```bash
> rm /etc/udev/rules.d/99-block-faulty-nvme.rules
> udevadm control --reload-rules
> ```

## Alert Silence

**IMPORTANT:** During this maintenance, the ZFS pool will be in a degraded state, triggering a critical alert.

**Before starting the replacement:**

```bash
# Silence the ZfsUnexpectedPoolState alert for 20 days
cd /path/to/home-ops
./scripts/silence-zfs-pve2.sh
```

**After completing the replacement:**

```bash
# Remove the silence once pool is back online
# See: docs/ALERTMANAGER_SILENCE_MANAGEMENT.md
```

For detailed silence management instructions, see: [`ALERTMANAGER_SILENCE_MANAGEMENT.md`](ALERTMANAGER_SILENCE_MANAGEMENT.md)

## GOOD NEWS - ZFS Mirror Configuration

The rpool is configured as a **ZFS mirror** across TWO drives:

- `/dev/nvme1n1p3` (Kingston SNV3S1000G) — **HEALTHY**
- `/dev/nvme2n1p3` (Kingston OM8PGP41024Q-A0) — **FAILING** ← Replace this one

**This means**: No data migration needed! Simply replace the failing drive and resilver.

## Current Configuration

### ZFS Pool Status

```text
pool: rpool
state: ONLINE
config:
    NAME                                                 STATE
    rpool                                                ONLINE
      mirror-0                                           ONLINE
        nvme-eui.00000000000000000026b7382f40aa55-part3  ONLINE  ← nvme2 (FAILING)
        nvme-eui.00000000000000000026b7686de852a5-part3  ONLINE  ← nvme1 (HEALTHY)
```

### Drive Mapping

| Device     | Model                    | EUI              | Status                       |
|------------|--------------------------|------------------|------------------------------|
| /dev/nvme0 | Intel SSDPE2KE032T7      | -                | HEALTHY (Ceph OSD)           |
| /dev/nvme1 | Kingston OM8PGP41024Q-A0 | 0026b7382f40aa55 | **FAILING - DRIVER UNBOUND** |
| /dev/nvme2 | Kingston SNV3S1000G      | 0026b7686de852a5 | HEALTHY (ZFS rpool)          |

> **Note**: Device numbering changed after driver unbind. The faulty drive is now at
> PCIe slot `59:00.0` but has no `/dev/nvme*` device since the driver is unbound.
> After physical replacement, the new drive will appear as `/dev/nvme1`.

### Partition Layout (Both Drives Identical)

| Partition | Size   | Type      | Purpose              |
|-----------|--------|-----------|----------------------|
| p1        | 1MB    | BIOS boot | Legacy boot (unused) |
| p2        | 1GB    | EFI (vfat)| Boot partition       |
| p3        | 930GB  | ZFS       | rpool mirror member  |

### Boot Configuration

Both EFI partitions are configured for boot:

- `28B9-A763` → /dev/nvme2n1p2 (failing drive)
- `28B9-E05F` → /dev/nvme1n1p2 (healthy drive)

## Prerequisites

### Hardware Required

- **New NVMe Drive**: Crucial P310 1TB (CT1000P310SSD801)
- M.2 2280 form factor
- PCIe 3.0/4.0 compatible

### Pre-Replacement Checklist

- [ ] Verify rpool is ONLINE: `zpool status rpool`
- [ ] Ensure no scrub is running: `zpool status rpool | grep scan`
- [ ] Kubernetes cluster healthy (can tolerate brief pve2 maintenance)
- [ ] Have Proxmox VE ISO ready (emergency only)

---

## Replacement Procedure (ZFS Mirror)

**Estimated downtime: 5-10 minutes** (just the reboot time)

### Step 1: Verify Current Pool Status

```bash
ssh root@192.168.1.82

# Check pool is healthy
zpool status rpool

# Identify the failing drive's partition
# Look for: nvme-eui.00000000000000000026b7382f40aa55-part3
```

### Step 2: Offline the Failing Drive (Optional but Recommended)

```bash
# Mark the failing drive offline in ZFS
# This is optional - ZFS will handle it automatically during shutdown
zpool offline rpool nvme-eui.00000000000000000026b7382f40aa55-part3

# Verify it's offline
zpool status rpool
```

### Step 3: Shutdown and Replace Drive

```bash
# Stop VM first (optional, will stop on shutdown anyway)
qm stop 1002

# Shutdown the system
shutdown -h now
```

**Physical replacement:**

1. Power off pve2 completely (wait for all lights to go off)
2. Open the case
3. Locate the failing NVMe drive in slot **59:00.0** (check motherboard markings)
4. Remove the Kingston OM8PGP41024Q-A0 (the failing drive)
5. Install the new Crucial P310 in the **same slot**
6. Close case and power on

### Step 4: Boot and Verify (System Will Boot from Healthy Drive)

The system should boot normally from the healthy mirror member (nvme1).

```bash
ssh root@192.168.1.82

# Check pool status - will show DEGRADED with missing drive
zpool status rpool
```

Expected output:

```text
pool: rpool
state: DEGRADED
status: One or more devices has been removed by the administrator.
config:
    NAME                                                 STATE
    rpool                                                DEGRADED
      mirror-0                                           DEGRADED
        nvme-eui.00000000000000000026b7382f40aa55-part3  REMOVED
        nvme-eui.00000000000000000026b7686de852a5-part3  ONLINE
```

### Step 5: Partition the New Drive

**IMPORTANT**: The `sgdisk -R` command syntax is `sgdisk -R <destination> <source>`.
This copies the partition table FROM the source (healthy drive) TO the destination (new drive).

> **Note**: After physical replacement and udev rule removal, identify the actual device
> names with `nvme list`. The healthy drive (Kingston SNV3S1000G) is currently `/dev/nvme2`.
> The new drive will likely appear as `/dev/nvme1`.

```bash
# 1. Identify the new drive and healthy drive
lsblk -d -o NAME,SIZE,MODEL
nvme list

# Expected after replacement:
# - Crucial P310 shows as /dev/nvme1n1 (NEW - in slot 59:00.0)
# - Kingston SNV3S1000G as /dev/nvme2n1 (HEALTHY)

# 2. Verify the healthy drive's partition layout (this is what we're copying)
# ADJUST DEVICE NAME based on nvme list output!
sgdisk -p /dev/nvme2n1   # Healthy drive

# Expected output:
# Number  Start (sector)    End (sector)  Size       Code  Name
#    1              34            2047   1007.0 KiB  EF02
#    2            2048         2099199   1024.0 MiB  EF00
#    3         2099200      1952448512   930.0 GiB   BF01

# 3. Wipe any existing partition data on new drive
wipefs -a /dev/nvme1n1   # New drive
sgdisk -Z /dev/nvme1n1

# 4. Copy partition table FROM healthy drive TO new drive
# Syntax: sgdisk -R <destination> <source>
sgdisk -R /dev/nvme1n1 /dev/nvme2n1

# 5. Randomize GUIDs to avoid conflicts (REQUIRED for ZFS)
sgdisk -G /dev/nvme1n1

# 6. Re-read partition table
partprobe /dev/nvme1n1

# 7. VERIFY partitions match the healthy drive
sgdisk -p /dev/nvme1n1

# Expected: Same layout as healthy drive
```

**Verification checklist:**

- [ ] Partition 1: ~1MB, type EF02 (BIOS boot)
- [ ] Partition 2: ~1GB, type EF00 (EFI System)
- [ ] Partition 3: ~930GB, type BF01 (ZFS)

### Step 6: Format EFI Partition

```bash
# Format the EFI partition as FAT32 (adjust device name as needed)
mkfs.vfat -F 32 /dev/nvme1n1p2

# Verify it was formatted
blkid /dev/nvme1n1p2
# Expected: TYPE="vfat"
```

### Step 7: Replace Drive in ZFS Mirror

```bash
# 1. Get the new drive's by-id path (more reliable than /dev/nvmeXn1p3)
ls -la /dev/disk/by-id/ | grep nvme1n1p3   # Adjust device name as needed

# Example output might look like:
# nvme-CT1000P310SSD8_XXXXXXXXXXXX-part3 -> ../../nvme1n1p3
# or
# nvme-eui.XXXXXXXXXXXXXXXX-part3 -> ../../nvme1n1p3

# 2. Store the new drive's partition path
# Option A: Use the by-id path (preferred)
NEW_PART3="/dev/disk/by-id/nvme-CT1000P310SSD8_XXXXXXXXXXXX-part3"  # Replace with actual

# Option B: Use the device path directly (simpler but less portable)
NEW_PART3="/dev/nvme1n1p3"   # Adjust as needed

# 3. Replace the old drive in the mirror
# The old drive ID: nvme-eui.00000000000000000026b7382f40aa55-part3
zpool replace rpool nvme-eui.00000000000000000026b7382f40aa55-part3 ${NEW_PART3}

# If you get an error about the device not being found, the old drive
# may have been automatically removed. In that case, use attach:
# zpool attach rpool nvme-eui.00000000000000000026b7686de852a5-part3 ${NEW_PART3}
```

### Step 8: Monitor Resilver Progress

```bash
# Watch the resilver progress
watch -n 5 'zpool status rpool'

# Or check once
zpool status rpool
```

Expected output during resilver:

```text
pool: rpool
state: DEGRADED
status: One or more devices is currently being resilvered.
scan: resilver in progress since Wed Jan  7 20:00:00 2026
    15.2G scanned at 1.52G/s, 8.1G issued at 810M/s, 43.2G total
    8.15G resilvered, 18.76% done, 0 days 00:00:43 to go
config:
    NAME                                     STATE     READ WRITE CKSUM
    rpool                                    DEGRADED     0     0     0
      mirror-0                               DEGRADED     0     0     0
        nvme-CRUCIAL_CT1000P310SSD8-part3    ONLINE       0     0     0  (resilvering)
        nvme-eui.00000000000000000026b7686de852a5-part3  ONLINE       0     0     0
```

**Resilver time estimate**: 5-15 minutes for ~43GB of data

### Step 9: Configure Boot Partition

After resilver completes:

```bash
# Initialize the new EFI partition for Proxmox boot (adjust device as needed)
proxmox-boot-tool init /dev/nvme1n1p2

# Verify boot configuration
proxmox-boot-tool status
```

Expected output:

```text
System currently booted with uefi
XXXX-XXXX is configured with: uefi (versions: 6.17.4-2-pve, ...)
28B9-E05F is configured with: uefi (versions: 6.17.4-2-pve, ...)
```

### Step 10: Final Verification

```bash
# Verify pool is healthy
zpool status rpool

# Check for errors
zpool status -v rpool

# Verify new drive health (adjust device as needed)
smartctl -a /dev/nvme1

# Start VM
qm start 1002

# Verify VM is running
qm status 1002
```

Expected final pool status:

```text
pool: rpool
state: ONLINE
scan: resilvered 43.2G in 0 days 00:05:30 with 0 errors
config:
    NAME                                     STATE     READ WRITE CKSUM
    rpool                                    ONLINE       0     0     0
      mirror-0                               ONLINE       0     0     0
        nvme-CRUCIAL_CT1000P310SSD8-part3    ONLINE       0     0     0
        nvme-eui.00000000000000000026b7686de852a5-part3  ONLINE       0     0     0
```

---

## Post-Replacement Verification

### Remove Driver Unbind Workaround

**IMPORTANT**: After physical replacement, remove the udev rule that was blocking the old faulty drive:

```bash
# Remove the udev rule
rm /etc/udev/rules.d/99-block-faulty-nvme.rules

# Reload udev rules
udevadm control --reload-rules

# Verify the new drive is detected
nvme list
```

The new Crucial P310 should now appear as `/dev/nvme1` or `/dev/nvme2` depending on enumeration order.

### System Health Checks

```bash
# ZFS pool status
zpool status rpool
zpool list rpool

# New NVMe health (should show 0 errors)
smartctl -a /dev/nvme2

# Check system logs for errors
dmesg | grep -i error
journalctl -p err -b | head -20

# Verify VM is running
qm status 1002
```

### Kubernetes Cluster Health

```bash
# From your workstation
export KUBECONFIG=./kubeconfig
kubectl get nodes
kubectl get pods -A | grep -v Running
```

### Proxmox Cluster Status

```bash
# On pve2
pvecm status
```

---

## Emergency Recovery

### If System Won't Boot After Replacement

1. The system should boot from the healthy drive (nvme2/Kingston SNV3S1000G) automatically
2. If not, enter BIOS/UEFI and select the Kingston SNV3S1000G as boot device
3. Boot from Proxmox VE ISO in rescue mode if needed

### If ZFS Pool Shows Errors

```bash
# Clear transient errors
zpool clear rpool

# If resilver fails, try again (adjust device names as needed)
zpool detach rpool /dev/nvme1n1p3
zpool attach rpool nvme-eui.00000000000000000026b7686de852a5-part3 /dev/nvme1n1p3
```

### If New Drive Won't Partition

```bash
# Ensure drive is detected
nvme list
lsblk

# Wipe any existing data thoroughly (adjust device name as needed)
wipefs -a /dev/nvme1n1
dd if=/dev/zero of=/dev/nvme1n1 bs=1M count=100  # Clear first 100MB

# Try partitioning again
sgdisk -Z /dev/nvme1n1
sgdisk -R /dev/nvme1n1 /dev/nvme2n1  # Syntax: -R <dest> <source>
sgdisk -G /dev/nvme1n1
partprobe /dev/nvme1n1

# Verify
sgdisk -p /dev/nvme1n1
```

---

## Appendix

### Drive Specifications

| Property    | Old Drive (Failing)      | New Drive (Replacement) |
|-------------|--------------------------|-------------------------|
| Model       | Kingston OM8PGP41024Q-A0 | Crucial P310            |
| Capacity    | 1TB                      | 1TB                     |
| Interface   | PCIe 4.0 x4              | PCIe 4.0 x4             |
| Form Factor | M.2 2280                 | M.2 2280                |
| PCIe Slot   | 59:00.0                  | 59:00.0                 |

### Current System Info

- **Node**: pve2 (192.168.1.82)
- **Proxmox Version**: 8.x
- **Kernel**: 6.17.4-2-pve
- **Boot Mode**: UEFI with systemd-boot
- **Root Pool**: rpool (ZFS mirror)
- **Pool Size**: 43.2GB used / 928GB total

### Time Estimates

| Step                 | Duration          |
|----------------------|-------------------|
| Shutdown + Replace   | 5-10 minutes      |
| Boot + Partition     | 5 minutes         |
| ZFS Resilver         | 5-15 minutes      |
| Boot Config + Verify | 5 minutes         |
| **Total**            | **20-35 minutes** |

---

## Quick Reference Commands

> **Note**: Device names below assume new drive is `/dev/nvme1` and healthy drive is `/dev/nvme2`.
> **Always verify with `nvme list` first!**

```bash
# 0. FIRST: Remove driver unbind workaround
rm /etc/udev/rules.d/99-block-faulty-nvme.rules
udevadm control --reload-rules

# 1. Check pool status (before and after)
zpool status rpool

# 2. Identify drives (verify device names!)
nvme list

# 3. Partition new drive (copy layout from healthy nvme2n1 to new nvme1n1)
wipefs -a /dev/nvme1n1           # Clear any existing signatures
sgdisk -Z /dev/nvme1n1           # Zap GPT/MBR
sgdisk -R /dev/nvme1n1 /dev/nvme2n1  # Copy partition table: -R <dest> <source>
sgdisk -G /dev/nvme1n1           # Randomize GUIDs
partprobe /dev/nvme1n1           # Re-read partition table
sgdisk -p /dev/nvme1n1           # Verify partitions

# 4. Format EFI partition
mkfs.vfat -F 32 /dev/nvme1n1p2

# 5. Replace failed drive in ZFS mirror
zpool replace rpool nvme-eui.00000000000000000026b7382f40aa55-part3 /dev/nvme1n1p3

# 6. Watch resilver progress
watch -n 5 'zpool status rpool'

# 7. Initialize boot partition (after resilver completes)
proxmox-boot-tool init /dev/nvme1n1p2
proxmox-boot-tool status

# 8. Final verification
smartctl -a /dev/nvme1
zpool status rpool
qm start 1002
```

---

## Document History

- **Created**: 2026-01-07
- **Updated**: 2026-01-07 (Corrected: rpool is ZFS mirror, not single drive)
- **Updated**: 2026-01-16 (Added driver unbind workaround notes, updated drive mapping)
- **Author**: Home-ops automation
- **Reason**: Kingston OM8PGP41024Q-A0 causing system crashes (726+ NVMe errors, PCIe bus freezes)
- **Related**: [PVE2_CRASH_INVESTIGATION.md](PVE2_CRASH_INVESTIGATION.md)
