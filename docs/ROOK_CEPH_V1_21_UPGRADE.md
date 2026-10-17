# Rook-Ceph v1.20 -> v1.21 upgrade (external cluster)

Status: **prep merged 2026-10-16**. Renovate PRs #554 (operator chart) and #555 (cluster
chart) are open; the ceph-csi-drivers bump is a separate commit between them.
Companion to `docs/ROOK_CEPH_V1_20_UPGRADE.md`, which explains the three-chart layout.

## What changes in v1.21 and whether it matters here

Checked against the rook `release-1.21` sources, the ceph-csi-operator v1.1.0 sources, the
chart diffs and the live PVE cluster on 2026-10-16.

| Change | Effect on this cluster |
| --- | --- |
| OCI chart tags lose the `v` prefix (`1.21.0`) | Renovate already wrote the new tags into #554/#555. Nothing else references the chart by tag. |
| `rook-ceph` chart bundles ceph-csi-operator **1.1.0** (was 1.0.4) | `ceph-csi-drivers` must move 1.0.5 -> 1.1.0 in the same window. Renovate pin lifted to `<1.2`. Chart diff 1.0.5 -> 1.1.0 is additive only (optional `cephCsiSecrets`, StorageClass/VolumeAttributesClass generators, extra RBAC verbs, SELinux comments); the ClientProfile/CephConnection it can render stay off, rook keeps owning ours. |
| Rook stops filling `rook-csi-operator-image-set-configmap`; the chart renders empty values | Our drivers HR points at that ConfigMap by name. ceph-csi-operator copies only non-empty values (`utils.CopyNonEmptyValues`), so the operator's built-in defaults apply: cephcsi v3.18.1, provisioner v6.3.0, attacher v4.13.0, resizer v2.2.1, snapshotter v8.6.0, registrar v2.18.0. Drift detection on the operator HR will blank the rook-owned fields as it did in v1.20 (`06dce5bb`). |
| `cephClusterSpec.network.connections.requireMsgr2` defaults to **true** in the cluster chart | **Overridden to `false`** in `cluster/helmrelease.yaml`. For an external cluster the flag only rewrites the mon endpoints handed to the CSI drivers from 6789 to 3300 (`csi.MonEndpoints`) and defaults the CephFS kernel mount options to `ms_mode=prefer-crc` (already set). `configureMsgr2`, which sets `rbd_default_map_options=ms_mode=prefer-crc` on the mons, runs only in the internal-cluster branch, and ceph-csi 3.18 does not add `ms_mode` for krbd on its own. The PVE config has no `rbd_default_map_options`, so new RBD maps would talk msgr1 to the msgr2 port and fail. Existing mounts and CephFS would have kept working, which is exactly the kind of failure that shows up a day later on a pod restart. |
| msgr2 "secure mode" fix (1.20.9, rook#18324) | Internal-cluster only, and the `client.healthchecker` user rook uses has `mon allow r`, so rook cannot change PVE's Ceph config at all. The cephx `aes256k` migration stays a separate, PVE-side task. |
| New NFS installs need an explicit `.nfs` pool | NFS driver disabled here. |
| Ceph support: Squid >= 19.2.0, Tentacle >= 20.2.1 | PVE runs 20.2.4 on all 12 daemons; the client image is pinned to v20.2.4 in `cluster/helmrelease.yaml`. |
| Kubernetes >= 1.32, msgr2 needs kernel >= 5.11 | k8s 1.37.1, Talos kernel 6.18. |

## Order

Rook's documented Helm order (`rook-ceph` -> `ceph-csi-drivers` -> `rook-ceph-cluster`), mapped
to this repo:

1. **Prep commit** (this change): Renovate pin `<1.2`, `requireMsgr2: false`, this runbook.
   No cluster effect beyond a no-op HelmRelease reconcile of `rook-ceph-cluster`.
2. **Merge #554** (`rook-ceph` 1.21.0). Watch `rook-ceph-operator` and
   `ceph-csi-controller-manager` (expect `quay.io/cephcsi/ceph-csi-operator:v1.1.0`).
   `flux reconcile hr ceph-csi-drivers -n rook-ceph-external` right after, as in v1.20, in
   case the operator rewrites the Driver CRs.
3. **Commit** bumping `csi-drivers/helmrelease.yaml` to chart `1.1.0` (or merge the Renovate
   PR if it already opened). Watch the four CSI plugin deployments/daemonsets roll onto
   cephcsi v3.18.1; if they do not, nudge a Driver spec field (the operator does not watch
   the image-set ConfigMap, see the v1.20 runbook).
4. **Merge #555** (`rook-ceph-cluster` 1.21.0). CephCluster must stay `Connected` /
   `HEALTH_OK`; `kubectl get cephconnection -n rook-ceph-external -o yaml` must still list
   the mons on `:6789`.
5. Verify: `./scripts/trigger-volsync-backup.sh <ns> <app>` for one RBD app (new map +
   snapshot), restart one CephFS pod, `ceph -n client.healthchecker -s` from the toolbox.

Use `./scripts/merge-renovate-pr.sh <PR> 900` for steps 2 and 4.

## Moving to msgr2 later (optional)

Not part of this upgrade. If wanted: on a PVE host
`ceph config set global rbd_default_map_options ms_mode=prefer-crc` (also affects PVE's own
krbd maps, harmless on its kernel), then drop the `requireMsgr2: false` override. Existing
RBD mounts keep msgr1 until remounted; mons on PVE keep both ports bound.

## Related

- `docs/ROOK_CEPH_V1_20_UPGRADE.md` for the three-chart layout, release-name constraint and
  the image-set ConfigMap field-manager gotcha.
- Memory note `rook-ceph-v1-20-csi-sa-incident`.
- `docs/CEPH_SQUID_TO_TENTACLE_UPGRADE.md` for the PVE side.
