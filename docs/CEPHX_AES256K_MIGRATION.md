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

## Phase 1b, done 2026-11-03: cluster-owned keys and client.admin

Same helper, dry run then apply (the classifier blocks the apply, pasha runs it):

```bash
$H --rotate-cluster-keys --rotate-admin-key              # dry run
$H --apply --assume-yes --rotate-cluster-keys --rotate-admin-key
```

- `mon.` key rotated, keyrings written on all three hosts, mons restarted one at
  a time (quorum back within seconds each).
- 7 `client.bootstrap-*` / `client.crash` keys replaced in place.
- `client.admin` STAGED next to the old key, PVE rewrote its copies
  (`/etc/pve/priv/ceph.client.admin.keyring`, `/etc/pve/priv/ceph/{talos,tank}.keyring`)
  and remounted the CephFS storage on every host. Both keys stay valid until
  confirmed. The holdouts were the librbd sessions of the pvelab VMs 9001/9002/9003
  (three `tank` disks each); their system disk is 128 GB on local ZFS, so instead
  of a live migration they were stopped and started one at a time (`qm shutdown`,
  9002 needed `qm stop`). The Talos VMs have no Ceph disks, Rook does not use the
  admin key (its sessions all come from the PVE hosts), nothing else to refresh.
- `$H` dry run then said "Ready for confirmation: client.admin", and
  `$H --apply --assume-yes --confirm-all-clients-refreshed` committed it. Only the
  1Password `rook-ceph` field `admin-secret` (unused copy) had to be updated.
- **Then fail the active mgr** (`ceph mgr fail <active>`). The helper restarts
  standby mgrs to hand them their new key but gives the active one its key in
  place. Its main monitor session is fine, but the Python modules (rbd_support,
  devicehealth, ...) keep separate librados handles with the OLD key. Once the
  confirm step invalidated that key (2026-11-03 21:54 EST) mgr.pve2 logged
  `monclient(hunting): handle_auth_bad_method ... Permission denied` every few
  minutes and `ceph rbd task list` hung. ceph-csi deletes RBD images and
  snapshots through `rbd task add trash remove`, so every VolSync cleanup hung:
  10 `volsync-*-src` snapshots and PVs stuck deleting, the RBD ctrlplugin
  crash-looping, 7 `VolSyncVolumeOutOfSync` alerts overnight. Creates do not
  touch the mgr, which is why the backups themselves kept succeeding. Fixed
  2026-11-04 08:38 EST with `ceph mgr fail pve2`; everything drained within
  two minutes. MDS, OSDs and mons were unaffected.

## Phase 2, done 2026-11-03: user-space Kubernetes keys

`client.healthchecker` (Rook operator, feeds `CephCluster.status`),
`client.csi-rbd-provisioner` and `client.csi-cephfs-provisioner` (ceph-csi
provisioner pods, librados, >= 3.17.1 required, we run 3.18.1) can move to
`aes256k`. `client.csi-rbd-node` / `client.csi-cephfs-node` are kernel clients
and stay `aes` (Phase 3).

The keys live in the 1Password item `rook-ceph` (vault HomeInfra, fields
`ceph-secret`, `csi-rbd-provisioner-userKey`, `csi-cephfs-provisioner-userKey`)
and reach the cluster via the ExternalSecrets in
`kubernetes/apps/rook-ceph-external/rook-ceph/app/externalsecrets.yaml` (refresh
2 h to 3 h). Never `kubectl` the Secrets directly.

Ceph has a pending (staged) key per entity:
`ceph auth get-or-create-pending <entity>` keeps the old key valid and promotes
the pending key on its first use (`auth commit-pending` / `auth clear-pending`
to force or abort). It takes NO `--key_type`: the cipher follows
`auth_preferred_cipher`, so flip that for the call and flip it back. The output
has two lines, `key = <old>` and `pending key = <new>`; take `$4` of the
`pending key` line (an `aes256k` key is 60 base64 chars, an `aes` key 40; the key
type is the first little-endian u16 of the decoded blob, 1 = aes, 2 = aes256k).

Done 2026-11-03 22:30 EST:

```bash
# on pve1, keys go to root-only files, never to the terminal
umask 077; mkdir -p /root/cephx-rotate
ceph mon set auth_preferred_cipher aes256k   # mon election
for e in client.healthchecker client.csi-rbd-provisioner \
         client.csi-cephfs-provisioner; do
  ceph auth get-or-create-pending $e > /root/cephx-rotate/$e.pending
  awk '/pending key = /{print $4}' /root/cephx-rotate/$e.pending \
    | tr -d '\n' > /root/cephx-rotate/$e.key
done
ceph mon set auth_preferred_cipher aes       # back: Talos keys must stay aes
```

Then the three `.key` files were written into the 1Password fields with
`op item edit rook-ceph 'ceph-secret=…'` (value read over ssh in a `$()`, output
to /dev/null, verified by comparing sha256 of `op item get --reveal` with the file;
the classifier blocks `op item edit`, pasha runs the script). `op whoami` says
"not signed in" while `op item get/edit` still work through the desktop-app
integration.

Then (22:05 EST) the three ExternalSecrets were force-synced on request
(`kubectl annotate externalsecret -n rook-ceph-external <name> force-sync=1
--overwrite`, use a timestamp as the value; the Secrets re-rendered within
seconds) and the two provisioner keys were promoted with
`ceph auth commit-pending`, which is safe because ceph-csi reads the provisioner
Secret on every CSI call.

`client.healthchecker` is different: the Rook operator writes
`/var/lib/rook/rook-ceph-external/client.healthchecker.keyring` from the Secret
ONCE at pod start and never refreshes it (checked: file mtime = pod start). A
`kubectl rollout restart deployment/rook-ceph-operator -n rook-ceph-external`
(approved by pasha, seconds, no effect on CSI or volumes) made it write the new
keyring, and its next health check promoted the pending key on its own, no
`commit-pending` needed. The toolbox pod, by contrast, re-generates
`/etc/ceph/keyring` from the mounted Secret within seconds, so it needs no
restart; but do not run `ceph` in the toolbox between the Secret refresh and the
operator restart, that would promote the key and break the operator.

Finished 22:20 EST: `ceph health detail` lists only `client.csi-rbd-node` and
`client.csi-cephfs-node`; `/root/cephx-rotate/` on pve1 shredded.

## Phase 3, blocked on Talos kernel >= 7.0

1. `client.csi-rbd-node` / `client.csi-cephfs-node`: same staged procedure, but
   the new keys only take effect for new mounts; drain and reboot each node
   afterwards.
2. Last: `--apply --confirm-all-clients-refreshed --restrict-ciphers`, which
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
- After any key rotation that touches the mgr key, check
  `journalctl -u ceph-mgr@<active> | grep handle_auth_bad_method` and time
  `ceph rbd task list`; a silent hang there means the active mgr still holds
  the old key in its module handles. `ceph mgr fail <active>` fixes it.
