# CephX aes256k key migration (PVE Ceph, Tentacle 20.2.4)

Ceph 19.2.6 / 20.2.4 (CVE-2025-30156) flag every cephx key on the old `aes`
cipher with six `AUTH_INSECURE_*` health checks. Two of them are `HEALTH_ERR`
(`AUTH_INSECURE_SERVICE_KEY_TYPE`, `AUTH_INSECURE_SERVICE_TICKETS`), the other
four are `HEALTH_WARN`. The Flux `rook-ceph-cluster` Kustomization has a
`healthCheckExprs` rule that marks the `CephCluster` failed on `HEALTH_ERR`
only, so `HEALTH_WARN` is fine for GitOps; `HEALTH_ERR` blocks nine dependent
Kustomizations and sends an Alertmanager notification every hour (that is what
happened when the 30-day mutes expired on 2026-11-01 21:30 EST).

## The constraint

The Linux kernel RBD/CephFS client only understands `aes256k` keys from Linux
7.0. Talos v1.14 runs kernel 6.18.x (v1.15 too), so `client.csi-rbd-node` and
`client.csi-cephfs-node` MUST stay `aes`, `aes` must stay in
`auth_allowed_ciphers`, and `auth_preferred_cipher` must stay `aes` so that any
key created for Talos later is usable. Check with `kubectl get nodes -o
custom-columns=NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion`.

A legacy `aes` client keeps working after the service-ticket cipher is switched:
the mon picks the session-key cipher as `min(client key type, service rotating
key type)` (`KeyServer::_build_session_auth_info`,
src/auth/cephx/CephxKeyServer.cc), so an `aes` kernel client still receives
`aes` session keys. Verified 2026-11-03: Talos mapped new RBD volumes right
after the switch with no `libceph` errors.

## Phase 1, done 2026-11-03 (clears both HEALTH_ERR checks)

Proxmox ships a helper (pve-manager >= 9.2.19; we ran 9.2.25). Dry run first,
then apply from ONE node; it drives the other nodes over SSH:

```bash
ssh root@pve1.bpghome.net
H=/usr/share/pve-manager/migrations/pve-cephx-rotate-service-keys
$H                        # dry run, prints the plan
$H --apply --assume-yes
```

What it did, ~2 minutes, no client impact:

- rotated `mgr.pve{1,2,3}` and `mds.pve{1,2,3}` keys to `aes256k` (standby mgrs
  were restarted, active mgr and the mds took the new key live); OSD keys were
  already `aes256k`
- `ceph mon set auth_service_cipher aes256k` (brief mon election)
- set `auth_preferred_cipher` to `aes256k` for the run and put it back to `aes`
- journaled the old keys in `/etc/pve/priv/cephx-key-migration.json` (keep it,
  protect it)

Result: `HEALTH_WARN` with 4 checks left, Flux green, no mutes needed.
`AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE` clears by itself as the rotating keys
expire (`auth_mon_ticket_ttl` 72 h). Do NOT use `--wipe-rotating-keys`: that
invalidates every ticket and relies on every client re-authenticating cleanly.

Status at any time: `pveceph auth status` and `ceph health detail`.

## Phase 2, open: user-space Kubernetes keys

`client.healthchecker` (Rook operator, feeds `CephCluster.status`),
`client.csi-rbd-provisioner` and `client.csi-cephfs-provisioner` (ceph-csi
provisioner pods, librados, >= 3.17.1 required, we run 3.18.1) can move to
`aes256k`. They only reduce the `AUTH_INSECURE_CLIENT_KEY_TYPE` count from 13 to
10; the check itself stays until Talos has kernel 7.0.

The keys live in the 1Password item `rook-ceph` (fields `ceph-secret`,
`csi-rbd-provisioner-userKey`, `csi-cephfs-provisioner-userKey`) and reach the
cluster via the ExternalSecrets in
`kubernetes/apps/rook-ceph-external/rook-ceph/app/externalsecrets.yaml` (refresh
2 h to 3 h). Never `kubectl` the Secrets directly.

Ceph supports a pending (staged) key per entity:
`ceph auth get-or-create-pending <entity>` keeps the old key valid and promotes
the pending key on its first use (`auth commit-pending` / `auth clear-pending`
to force or abort). It takes no `--key_type`; the cipher follows
`auth_preferred_cipher`.

```bash
# on pve1, keys go to root-only files, never to the terminal
umask 077; mkdir -p /root/cephx-rotate
ceph mon set auth_preferred_cipher aes256k   # mon election
for e in client.healthchecker client.csi-rbd-provisioner \
         client.csi-cephfs-provisioner; do
  ceph auth get-or-create-pending $e > /root/cephx-rotate/$e.pending
done
ceph mon set auth_preferred_cipher aes       # back: Talos keys must stay aes
pveceph auth status                          # shows "pending aes256k" per entity
```

Then: put the three pending keys into the 1Password fields (`op item edit
rook-ceph 'ceph-secret=…'` with the value read from the file, not pasted), wait
for the ExternalSecrets to refresh (`kubectl get es -n rook-ceph-external`
refreshTime, Secret resourceVersion), watch `pveceph auth status` flip each
entity to `aes256k` on first use, confirm `CephCluster` stays `Connected` and a
test PVC provisions. If the Rook operator keeps using a cached old key after the
Secret changed, it needs a pod restart. Finish with `ceph auth commit-pending
<entity>` for anything still pending, and `shred` the files.

## Phase 3, blocked on Talos kernel >= 7.0

1. `client.csi-rbd-node` / `client.csi-cephfs-node`: same staged procedure, but
   the new keys only take effect for new mounts; drain and reboot each node
   afterwards.
2. `pve-cephx-rotate-service-keys --apply --rotate-cluster-keys` (bootstrap,
   crash, mon key, restarts one mon at a time) and `--rotate-admin-key` (staged,
   rewrites PVE's copies and the CephFS mount; PVE kernels are 7.0.14 so fine).
   These two could also be done earlier; they are independent of Talos.
3. Last: `--apply --confirm-all-clients-refreshed --restrict-ciphers`, which
   removes `aes` from `auth_allowed_ciphers`. Refused while any key or live
   client still uses `aes`.

## Gotchas

- `pve1.internal` style names no longer resolve from the workstation; use
  `pveN.bpghome.net`.
- The Prometheus rules `CephHealthError` / `CephHealthWarning` exclude
  `AUTH_INSECURE_.*` (`prometheusrule-ceph.yaml`), so none of this pages; Flux
  was the only thing that noticed.
- `ceph health mute <CHECK> --sticky` is the fallback if HEALTH_ERR ever has to
  be hidden again; a plain TTL mute expires silently and recreates the Flux
  failure.
