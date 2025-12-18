# Proxmox Hardware Watchdog Setup

This runbook captures the exact steps we used to switch the MS-01 based Proxmox
cluster (nodes `pve1`/`pve2`/`pve3`) to the Intel TCO hardware watchdog. Follow
it any time the cluster is rebuilt from scratch.

> **Goal**: have `watchdog-mux` + `pve-ha-lrm` using the on-board Intel iTCO
> watchdog so that hung nodes automatically reboot instead of freezing
> indefinitely.

## 1. Load the Intel TCO driver on boot

Perform the following on **each** Proxmox node:

```bash
cat <<'EOF' >/etc/modules-load.d/watchdog.conf
iTCO_wdt
EOF

modprobe iTCO_wdt
```

This ensures the hardware module is available immediately after boot. (If
`softdog` autoloads, we will unload it in a later step.)

## 2. Provide a stable watchdog device path

Create a udev rule so `/dev/watchdog` always points at the active device
(`watchdog1` on MS-01 hardware):

```bash
cat <<'EOF' >/etc/udev/rules.d/99-watchdog.rules
KERNEL=="watchdog*", MODE="0600", SYMLINK+="watchdog"
EOF

udevadm control --reload
udevadm trigger --subsystem-match=watchdog
```

After the trigger, you should see the symlink:

```bash
ls -l /dev/watchdog*
# lrwxrwxrwx 1 root root 9 ... /dev/watchdog -> watchdog1
# crw------- 1 root root 243,1 ... /dev/watchdog1
```

## 3. Configure the HA stack to use the hardware watchdog

Set the driver and timeout for the HA manager (`/etc/default/pve-ha-manager`):

```bash
cat <<'EOF' >/etc/default/pve-ha-manager
WATCHDOG_MODULE=iTCO_wdt
WATCHDOG_TIMEOUT=60
EOF
```

This file is read by both `watchdog-mux` and the HA daemons.

## 4. Restart services and drop the software watchdog

Disable the software watchdog (`softdog`) so only the hardware driver is left,
then restart the relevant services:

```bash
systemctl stop pve-ha-lrm watchdog-mux
modprobe -r softdog || true            # ignore error if not loaded
modprobe iTCO_wdt                      # re-load to ensure device exists
systemctl start watchdog-mux pve-ha-lrm
```

Repeat this block on each node. If `softdog` refuses to unload, double-check that
`watchdog-mux` and `pve-ha-lrm` are stopped before retrying `modprobe -r`.

## 5. Verify everything is healthy

Run the following on every node:

```bash
# Confirm only iTCO modules are present
lsmod | grep -E 'iTCO|softdog'

# Ensure the watchdog service latched onto the hardware driver
journalctl -u watchdog-mux -n 5
```

Expected output snippets:

```
iTCO_wdt               16384  2
intel_pmc_bxt          16384  1 iTCO_wdt
iTCO_vendor_support    12288  1 iTCO_wdt

watchdog-mux[...] Watchdog driver 'iTCO_wdt', version 6
```

If you see `softdog` still listed, repeat step 4. If `watchdog-mux` reports
"watchdog open: No such file or directory", the `/dev/watchdog` symlink wasn’t
created—rerun step 2.

## 6. Optional sanity check

Use `wdctl` (install with `apt install watchdog`) or a short timeout test to
confirm the watchdog resets the node if `watchdog-mux` is stopped:

```bash
systemctl stop watchdog-mux
sleep 90   # node should automatically reboot before this finishes
```

Only run this after migrating critical workloads elsewhere.

---

Following the steps above after a fresh install guarantees the HA stack always
has a functioning hardware watchdog, preventing the recurring hangs that happen
when nodes get stuck waiting on storage.
