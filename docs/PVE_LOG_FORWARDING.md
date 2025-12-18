# Proxmox → Fluent Bit Log Forwarding

The goal: ship host logs from the Proxmox (MS-01) nodes into Victoria Logs by
forwarding syslog traffic to the Fluent Bit `syslog` input that now runs in the
cluster.

## 1. Fluent Bit listener details

- Service: `fluent-bit-syslog` (namespace `observability`)
- Type: `NodePort`
- NodePort: `30514/UDP`
- Service Port: `5514/UDP`

Any Kubernetes node IP will accept UDP syslog on port `30514` and forward it to
Fluent Bit.

## 2. Configure rsyslog on each Proxmox node

1. Create `/etc/rsyslog.d/99-fluent-bit.conf`:

   ```conf
   # Forward everything, keep local logging as well
   *.* @<cluster-node-ip>:30514;RSYSLOG_SyslogProtocol23Format
   ```

   - Replace `<cluster-node-ip>` with a Kubernetes node IP (e.g. `192.168.1.51`).
     Add multiple lines if you want redundancy.
   - The single `@` sends UDP syslog, matching the Fluent Bit listener. Use `@@`
     only if you later expose a TCP endpoint.

2. Restart rsyslog:

   ```bash
   systemctl restart rsyslog
   ```

3. Send a test message:

   ```bash
   logger -n <cluster-node-ip> -P 30514 "test message from $(hostname)"
   ```

4. Verify in Victoria Logs: search for the string above, it should arrive in the
   `proxmox.*` stream.

## 3. Journald persistence (optional)

Rsyslog already reads from systemd‑journald (`imjournal`). To make sure logs are
available after reboots, enable persistent journals once:

```bash
mkdir -p /var/log/journal
systemctl restart systemd-journald
```

No further changes are needed; rsyslog will continue forwarding everything.
