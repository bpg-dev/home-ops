# Talos and Kubernetes upgrade runbook

Last run: 2026-10-04, Talos v1.13.7 -> v1.13.11 (about 3 min per node) and Kubernetes
v1.35.3 -> v1.36.3 (about 10 min), all clean. Versions come in through Renovate PRs on
`talos/talconfig.yaml` (`ghcr.io/siderolabs/installer` for Talos, `ghcr.io/siderolabs/kubelet`
for Kubernetes); merging the PR changes nothing on the nodes, the steps below do.

## Before you start

```bash
export KUBECONFIG=./kubeconfig
# MUST be absolute: task talos:upgrade-node runs its precondition from talos/ and
# aborts with "precondition not met" on a relative path.
export TALOSCONFIG=/Users/pasha/code/home-ops/talos/clusterconfig/talosconfig
```

- `flux get ks -A` / `flux get hr -A` all Ready, no volsync mover running, CephCluster
  HEALTH_OK (`kubectl get cephcluster -n rook-ceph-external`).
- Check the Talos release notes for the target version (kernel, removed config fields)
  and the Kubernetes skew: kubelet may not be newer than the API server, so upgrade Talos
  first if the PR pair arrives together. Hold a brand-new Kubernetes minor for a week or
  two (see PR #512).
- Do NOT run `task talos:apply-node`. `task talos:generate-config` now emits the
  multi-document config format; its output differs from what the nodes run (networking
  split into HostnameConfig/LinkAliasConfig/Layer2VIPConfig/LinkConfig, deprecated fields
  dropped) and `apply-config --dry-run` wants a reboot on every node. That migration is a
  separate, deliberate change. Upgrades do not need the generated files
  (`talos/patches/README.md`, notes 2026-10-04).

## Talos, one node at a time (prod-1, prod-2, prod-3)

1. If the node hosts the CNPG primary, move it first:
   `kubectl cnpg status postgres -n postgresql-system`, then
   `kubectl cnpg promote postgres postgres-<n> -n postgresql-system` to an instance on
   another node and wait for the switchover to finish.
2. `task talos:upgrade-node IP=192.168.1.1<n>` (talhelper renders the installer image
   from talconfig). talosctl drains the node itself; never run a manual drain around it.
3. Watch: `talosctl -n <ip> dmesg -f` or `talosctl -n <ip> dashboard`; the node reboots,
   rejoins, and uncordons. Then verify, because `talosctl upgrade` can exit 0 without
   upgrading when the drain fails:

   ```bash
   talosctl -n <ip> version | grep Tag                 # new Talos version
   kubectl get nodes -o wide                            # Ready, OS image updated
   kubectl get pods -A -o wide --field-selector spec.nodeName=talos-prod-<n> | grep -vE 'Running|Completed'
   ```

4. Only then move to the next node.

Drain gotchas seen in past runs:

- **Loki**: 3 replicas, PDB `minAvailable: 2`, memberlist ring. A replica that left the
  ring unclean stays UNHEALTHY and blocks the next replica from becoming ready, so the
  drain times out and the upgrade aborts with the node cordoned but not upgraded.
  Durable fix in Git since 2026-10-04: `ingester.autoforget_unhealthy: true`
  (`kubernetes/apps/observability/loki/app/config/loki.yaml`). If it recurs,
  `docs/LOKI_MEMBERLIST_RING_RECOVERY.md` has the manual `forget`.
- **csi-nfs-controller** PDB can block the drain; deleting that pod (not evicting) lets
  the drain continue.
- Stale DaemonSet pods (Cilium, cilium-envoy, csi-nfs-node, rook-ceph nodeplugins) in
  Error/CrashLoopBackOff after the reboot: delete them, the DaemonSet recreates them.
  Cilium must be Ready before anything else schedules on the node.
- kubelet PLEG unhealthy after the reboot: `talosctl -n <ip> service kubelet restart`;
  if that sticks in Stopping, `talosctl -n <ip> reboot`.
- Control-plane VIP unreachable from the workstation after a node change: stale ARP,
  `sudo arp -d <VIP>`.
- Hard power control, if ever needed: `ssh root@pve<n>` and `qm stop/start 100<n>`
  (`docs/PVE_HOST_LAYOUT.md`).

## Kubernetes (all control planes in one go)

```bash
talosctl --nodes 192.168.1.11 upgrade-k8s --to v1.36.3 --dry-run   # version/flag/API checks
talosctl --nodes 192.168.1.11 upgrade-k8s --to v1.36.3
# or: task talos:upgrade-k8s (same command via talhelper gencommand)
```

The upgrade rolls kube-apiserver, controller-manager, scheduler, kube-proxy and the
kubelet on each node in turn, no reboot. Afterwards:

```bash
kubectl get nodes                                 # all kubelets on the new version
kubectl get pods -n kube-system | grep -E 'kube-(apiserver|controller|scheduler)'
flux get ks -A | grep -v True ; flux get hr -A | grep -v True
```

## After the upgrade

- Update the Talos row in `docs/PVE_HOST_LAYOUT.md`.
- Check `EtcdFsyncLatencyDegraded` / `EtcdBackendCommitLatencyDegraded` stay inactive
  (`docs/PVE_ZFS_SLOG_ON_P4600.md`).
- Trigger one volsync backup (`./scripts/trigger-volsync-backup.sh <app> <ns>`) to
  exercise CSI on the upgraded nodes.

## Odds and ends

- `talosctl apply-config --dry-run` prints the whole machineconfig diff including
  private keys and tokens. Filter before pasting anywhere:
  `grep -viE 'key:|crt:|secret|token|password|[A-Za-z0-9+/]{60,}'`.
- The Claude Code auto-mode classifier blocks `talosctl upgrade-k8s`, `talosctl shutdown`
  and host-level `systemctl` changes until explicitly allowed in the conversation.
