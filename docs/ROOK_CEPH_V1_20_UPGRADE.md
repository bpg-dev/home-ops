# Rook-Ceph v1.19 -> v1.20 upgrade (external cluster)

Status: **prep merged, upgrade pending** (2026-10-05). Renovate PRs #452 (operator) and
#453 (cluster chart) are intentionally left open until the steps below are done.

## Why this needs a runbook

Rook v1.20 stops managing the Ceph-CSI drivers itself. The driver CRs, their
ServiceAccounts and RBAC now come from a separate `ceph-csi-drivers` Helm chart
(from the ceph-csi-operator repo), while the `rook-ceph` chart only bundles the
`ceph-csi-operator` subchart (CRDs + controller). Merging #437/#438 on 2026-06-27
without that chart broke both `*-ctrlplugin` deployments with
`serviceaccount "...-ctrlplugin-sa" not found` and had to be rolled back
(see memory note `rook-ceph-v1-20-csi-sa-incident`, upstream rook#17644 and rook#18040).

Rook's documented Helm order is: `rook-ceph` -> `ceph-csi-drivers` -> `rook-ceph-cluster`
(<https://rook.io/docs/rook/latest-release/Upgrade/rook-upgrade/#helm>).

## What the prep commit does

`kubernetes/apps/rook-ceph-external/rook-ceph/csi-drivers/` adds a HelmRepository
(`https://ceph.github.io/ceph-csi-operator`, HTTP only, no OCI copy) and the HelmRelease
`ceph-csi-drivers` (chart 1.0.4), plus Flux Kustomization `rook-ceph-csi-drivers`
between `rook-ceph` and `rook-ceph-cluster`.

Facts the manifests rely on (verified against rook v1.19.5 / v1.20.8 sources and the
live cluster on 2026-10-05):

- rook v1.19.5 already labels the `Driver` and `OperatorConfig` CRs it creates with
  `meta.helm.sh/release-name: ceph-csi-drivers` (rook#17289, "critical update that
  enables helm upgrades to v1.20"). Helm therefore **adopts** the existing CRs on install
  instead of failing. The release name and namespace are not negotiable.
- rook v1.19.5 rewrites the Driver CR spec on every CSI reconcile (operator restart,
  CephCluster or `rook-ceph-operator-config` change; it does not watch the Driver CRs).
  It does not happen often (twice in the 24 h before the prep, both at the node upgrade),
  but it strips the `serviceAccountName` fields the chart sets. The HelmRelease has
  `driftDetection: enabled` so Flux puts the chart's spec back.
- ceph-csi-operator picks the ServiceAccount as `spec.*.serviceAccountName` if set, else
  `$CSI_SERVICE_ACCOUNT_PREFIX<rbd|cephfs>-ctrlplugin-sa`. rook v1.19 sets the prefix to
  `ceph-csi-` (SAs `ceph-csi-rbd-ctrlplugin-sa` from the 0.6.0 subchart); rook v1.20 sets it
  to `""` and the subchart no longer ships SAs, so **after the upgrade the Driver CR must
  carry `serviceAccountName`** or the fallback `rbd-ctrlplugin-sa` does not exist (that is
  exactly rook#18040). The chart names them
  `rook-ceph-external-<type>-csi-ceph-com-{ctrlplugin,nodeplugin}-sa`.
- The 0.6.0 operator already honours `serviceAccountName`, so right after the prep merge
  the CSI pods move to the chart's ServiceAccounts while still on rook v1.19.5. That
  validates the new RBAC before the operator upgrade. Expect one `Recreate` restart of each
  ctrlplugin deployment and a rolling restart of the nodeplugin DaemonSets.
- Chart defaults that differ from what rook configured and are overridden in the
  HelmRelease values: `snapshotPolicy: none` for RBD (would drop the csi-snapshotter and
  break volsync), `grpcTimeout: 30`, `controllerPlugin.replicas: 1` at driver level,
  log rotation on (adds a sidecar + hostPath), nfs/nvmeof drivers enabled.
- rook v1.20 no longer reads `CSI_CEPHFS_KERNEL_MOUNT_OPTIONS` from the operator chart
  (the whole `csi.*` block except images/serviceMonitor is gone). The ClientProfile's
  `ms_mode=prefer-crc` therefore now comes from
  `cephClusterSpec.csi.cephfs.kernelMountOptions` in the cluster HelmRelease (added in the
  prep; identical effect on v1.19.5).

### Verify after the prep merge

```bash
export KUBECONFIG=./kubeconfig
flux get ks -n rook-ceph-external            # rook-ceph-csi-drivers Ready, rook-ceph-cluster Ready
flux get hr -n rook-ceph-external            # ceph-csi-drivers 1.0.4 Ready
helm list -n rook-ceph-external              # three releases now
kubectl get sa -n rook-ceph-external | grep rook-ceph-external-   # 4 new SAs
kubectl get drivers.csi.ceph.io -n rook-ceph-external -o yaml | grep serviceAccountName   # 4 lines
kubectl get pods -n rook-ceph-external -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName | grep csi
kubectl get clientprofile -n rook-ceph-external rook-ceph-external -o yaml | grep -A2 kernelMountOptions
```

Every CSI pod should run 5/5 (ctrlplugin) or 2/2 (nodeplugin) with the new SAs and the
same images as before (cephcsi v3.16.2). Then run a quick storage smoke test:
`./scripts/trigger-volsync-backup.sh default <app>` for one app and confirm the
ReplicationSource goes `Successful` (exercises RBD snapshot + attach).

## Step 1: operator (PR #452, rook-ceph v1.19.5 -> v1.20.8)

Pre-flight: Ceph `HEALTH_OK` (PVE API `/cluster/ceph/status` or `ssh root@pve1 ceph -s`),
no volsync jobs running, `flux get hr -A` all Ready, prep verification above still true.

Do **not** merge the Renovate PR as-is. Check out its branch (or edit `main` after
merging it, same commit) and replace the `csi:` block in
`kubernetes/apps/rook-ceph-external/rook-ceph/app/helmrelease.yaml`, because every key in
it except `serviceMonitor` was removed from the chart in v1.20 (no values schema, so they
would be silently ignored, which is confusing later):

```yaml
  values:
    csi:
      # Everything else that used to live here (driver enables, replicas, affinity,
      # kernel mount options, krbd) is configured by the ceph-csi-drivers chart now.
      serviceMonitor:
        enabled: true
    enableDiscoveryDaemon: true
    image:
      repository: ghcr.io/rook/ceph
    monitoring:
      enabled: true
    resources:
      requests:
        memory: 128Mi # unchangeable
        cpu: 100m # unchangeable
      limits: {}
```

The subchart value `ceph-csi-operator.controllerManager.manager.env.csiServiceAccountPrefix`
must stay at the chart default `""`.

After the merge:

```bash
flux reconcile ks flux-system --with-source
flux reconcile ks rook-ceph -n rook-ceph-external
flux get hr rook-ceph-operator -n rook-ceph-external --watch     # until v1.20.8 Ready
# Close the race described above: re-assert the chart's Driver spec right away.
flux reconcile hr ceph-csi-drivers -n rook-ceph-external
kubectl get drivers.csi.ceph.io -n rook-ceph-external -o yaml | grep serviceAccountName
kubectl get pods -n rook-ceph-external -w
```

Expected: `rook-ceph-operator` and `ceph-csi-controller-manager` restart with new images,
the old `ceph-csi-*` and `rook-csi-*` ServiceAccounts disappear (owned by the old
subchart), the CSI pods roll once more onto cephcsi v3.17.1 / registrar v2.17.0 /
provisioner v6.2.0 / attacher v4.12.0 and keep the `rook-ceph-external-*` SAs.
`rook-ceph-cluster` HR stays Ready (same chart version until step 2).

Failure signature: `FailedCreate ... serviceaccount "rbd-ctrlplugin-sa" not found` on a
ctrlplugin ReplicaSet or nodeplugin DaemonSet. Cause: rook v1.19.5 rewrote the Driver CRs
after Flux last applied them and before it died. Fix: the `flux reconcile hr
ceph-csi-drivers` above (drift correction re-adds `serviceAccountName`); the operator then
recreates the pods within a minute. Existing mounts are unaffected either way.

Rollback: revert the merge commit. rook v1.19.5's subchart recreates the `ceph-csi-*`
SAs, the Driver CRs get rewritten by rook and the ceph-csi-drivers release can stay
installed.

## Step 2: cluster chart (PR #453, rook-ceph-cluster v1.19.5 -> v1.20.8)

Merge as-is after step 1 is verified. Chart changes relevant to this external cluster:

- New default `cephClusterSpec.security.cephx.csi.keyType: aes` ("required when
  Kubernetes nodes don't run Linux kernel 7.0+"). Talos v1.13 nodes run 6.18, so keep it.
  This is the same reason the PVE Ceph `insecure key types` health check is muted until
  ~2026-11-01 (see `docs/PVE2_RMA_GUIDE.md`).
- `mgr.modules` now disables the `rook` mgr module by default (recommended upstream);
  harmless for an external cluster where rook does not manage the mgr.
- `cephVersion.image` default moves to `quay.io/ceph/ceph:v20.2.4`. For an external
  cluster rook only uses it for the toolbox / cmd-reporter client; the PVE cluster runs
  Ceph 19.2.6. Consider pinning `cephClusterSpec.cephVersion.image: quay.io/ceph/ceph:v19.2.6`
  in the cluster HelmRelease to keep the client in step with the servers.
- Chart templates now also render `security.cephx` and cmd-reporter resources; no action.

Verify: `flux get ks -n rook-ceph-external`, CephCluster `status.ceph.health` back to
`HEALTH_OK` and `status.phase: Connected`, toolbox pod Running, Grafana Ceph dashboards
still populated, one more volsync smoke test.

## Afterwards

- Renovate: `.renovaterc.json5` pins `ceph-csi-drivers` to `<1.1` so the drivers chart
  stays in step with the ceph-csi-operator subchart bundled by rook (v1.20.x -> 1.0.4).
  When a rook minor bumps that dependency (`helm show chart oci://ghcr.io/rook/rook-ceph
  --version <tag>`), raise the drivers chart in the same change and move the pin.
- Update memory note `rook-ceph-v1-20-csi-sa-incident` and this file's status line.
- Chart docs for further CSI tuning:
  <https://github.com/ceph/ceph-csi-operator/blob/main/docs/helm-charts/drivers-chart.md>
