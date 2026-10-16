# BookLore to BookOrbit migration

Date: 2026-10-14
Status: design approved, grilled twice 2026-10-14/15, awaiting implementation plan

## Goal

Replace the BookLore deployment (`kubernetes/apps/default/booklore`) with BookOrbit,
its official successor, without losing library metadata, reading progress,
bookmarks, collections, users, or custom covers. BookLore is in maintenance
mode upstream; BookOrbit is where development continues.

## Current state (verified 2026-10-14)

- BookLore v2.4.0 via bjw-s app-template 5.3.0, one Deployment with a
  `lscr.io/linuxserver/mariadb` 11.8.8 sidecar.
- Data: 10Gi `ceph-rbd` PVC `booklore` (Volsync, Kopia, hourly at :10).
  `/app/data` holds 33 MB (32 MB of covers under `images/`), the MariaDB
  sidecar holds 184 MB under `/config/databases` on the same PVC.
- Library: NFS `nas.internal:/mnt/tank/nfs/booklore/library` at `/books`,
  one BookLore library with a single path `/books`, 270 books / 270 files.
  Drop folder: NFS `.../booklore/incoming` at `/bookdrop`.
- Users: admin (booklore@, 4 shelves, no progress), pasha (7 progress rows,
  4 shelves), valia (1 shelf). 9 shelves, 5 magic (dynamic) shelves, 6 bookmarks.
- OIDC enabled against Authentik (issuer `sso.${SECRET_DOMAIN}/application/o/booklore/`,
  auto-provisioning on). The Authentik provider is configured in Authentik,
  not in Git.
- OPDS server enabled, one OPDS user, in active use.
- Kobo sync configured for two users but disabled, zero reading states.
- Metadata write-back into the original epub/pdf files is enabled.
- Drop folder holds 22 epubs from January 2026 that were never imported.
- Hostname `booklore.${SECRET_DOMAIN}` on `envoy-internal`.
- Shared CNPG cluster `postgres` (Postgres 18.0, image
  `ghcr.io/cloudnative-pg/postgresql:18.0-system-trixie`) already contains an
  empty `booklore` database and role left over from the original deployment
  (commit f3f7e7a2 moved BookLore to MariaDB).

## BookOrbit facts that drive the design

- Image `ghcr.io/bookorbit/bookorbit`, tags without a `v` prefix. Latest
  `3.4.0` (2026-10-13), digest
  `sha256:99539be044c94f10fa5fba616cb08e1b128deb4996c975d181a950818a8632e4`.
- Needs Postgres 16+ with extensions `uuid-ossp`, `pg_trgm`, `unaccent`,
  `vector`. The shared cluster ships all four (pgvector 0.8.1). `vector` is
  not a trusted extension, so only a superuser can create it; the app's
  startup migration runs `CREATE EXTENSION IF NOT EXISTS` as the app user and
  would fail on `vector` unless it already exists.
- Listens on 3000, health endpoint `GET /api/v1/health`.
- Entrypoint: when the container runs as a non-root UID it skips chown and
  `su-exec`, checks that `/data`, `/data/covers`, `/data/book-bucket` are
  writable, runs `migrate.js`, then starts Node. `HOME` defaults to `/tmp`.
  The image needs a writable `/tmp`.
- Required env: `APP_URL`, `JWT_SECRET`, `SETUP_BOOTSTRAP_TOKEN`, and either
  `DATABASE_URL` or the `POSTGRES_*` set. Recommended: `PODCAST_ENCRYPTION_KEY`,
  `EMAIL_ENCRYPTION_KEY`, `MIGRATION_ENCRYPTION_KEY`.
- Guided migration (Settings > Maintenance > Import from Booklore) connects
  over the network to BookLore's MariaDB, needs a "media root path" readable
  by BookOrbit for BookLore's cover images, maps source users to BookOrbit
  accounts and source path prefixes to BookOrbit library folders, and overlays
  metadata onto books BookOrbit has already scanned. It never creates books.
  Tested upstream against BookLore v2.2.2. The media root is any absolute
  path readable by the process; the adapter expects an `images/` directory
  under it (BookLore's `/app/data/images`). It is not restricted to
  `MIGRATION_IMPORT_ROOT`, which only matters for Audiobookshelf and
  Calibre-Web Automated file imports.
- Magic (dynamic) shelves are not migrated; only regular shelves become
  collections. Kobo device state, PDF annotations, notes and reader
  preferences are not migrated either.
- OIDC: authorization-code flow with PKCE and a client secret (confidential
  client), redirect URI `https://<host>/oauth2-callback`, configured in
  Settings after first login. Production builds reject issuer and token
  endpoints that resolve to private addresses unless
  `OIDC_ALLOW_LOCAL_ISSUERS=true`.
- First admin is created on a setup page in the web UI that asks for
  `SETUP_BOOTSTRAP_TOKEN`.
- Book Dock is a watched drop folder: files copied into `BOOK_DOCK_PATH`
  are picked up automatically (Rescan button if not), and "Discard" in the
  dock deletes the file from disk.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Rollout | Side by side, then retire booklore in a follow-up PR | The wizard is designed to run against a live BookLore MariaDB |
| Database | Dedicated `bookorbit` database and role on the shared CNPG cluster | Same pattern as paperless, umami, swimstats; Barman WAL backups for free |
| Hostname | `bookorbit.${SECRET_DOMAIN}` from day one | `APP_URL` is baked into Kobo endpoints and emails |
| Secrets | New 1Password item `bookorbit` in HomeInfra, created with `op` | Matches every other app |
| Covers | Copy BookLore `/app/data/images` to NFS, mount read-only for the migration | The BookLore PVC is RWO Ceph and cannot be shared |
| Chart | bjw-s app-template 5.3.0 | Upstream has no Helm chart; repo standard |
| SSO | Authentik OIDC set up for BookOrbit before the wizard runs | pasha and valia log in through SSO today; accounts must exist for user mapping |
| Accounts | Mirror BookLore: `admin` is the bootstrap account and stays as break-glass local login, pasha and valia auto-provision via OIDC, pasha promoted to admin | Wizard matches by username and email |
| Coexistence | Cutover, not coexistence: no BookLore edits after the cover copy, retirement PR the same day verification passes | Both apps share `/books` and BookLore writes metadata into files |
| Drop folder | BookOrbit Book Dock points at the NAS `incoming` share | Keeps the drop-on-NAS workflow; the 22 pending files get triaged in BookOrbit |
| OPDS | Kept; reader re-pointed with a new OPDS password after cutover | OPDS credentials are not migrated |
| Authentik work | Done by Claude through the Authentik UI in the user's Chrome session, with the user watching; the user pastes secret values into form fields themselves (a browser tool can only type what is in its tool-call arguments) | Not in Git; keeps the runbook executable in one sitting |
| NAS path | `/mnt/tank/nfs/booklore/` keeps its name | Renaming the dataset means export edits and a second NFS cutover for a cosmetic gain |
| BookLore fallback | MariaDB dump plus `/app/data` tarball archived on the NAS, kept indefinitely | Retirement deletes the app, PVC and imports folder; Kopia snapshots stop expiring once the ReplicationSource is gone |

Out of scope: Kokoro TTS sidecar, external exposure, Kobo sync.

## Design

### New app `kubernetes/apps/default/bookorbit/`

```
bookorbit/
├── ks.yaml
└── app/
    ├── externalsecret.yaml
    ├── helmrelease.yaml
    ├── kustomization.yaml
    └── ocirepository.yaml
```

`ks.yaml`: `targetNamespace: default`, `dependsOn` `rook-ceph-cluster`
(rook-ceph-external) and `postgres-cluster` (postgresql-system), volsync
component, `VOLSYNC_CAPACITY: 10Gi`, `VOLSYNC_SCHEDULE: "45 * * * *"`
(unused slot; existing schedules use :10 :15 :20 :30 :40 :50).
Registered in `kubernetes/apps/default/kustomization.yaml` in alphabetical
order.

`ocirepository.yaml`: copy of booklore's, name `bookorbit`.

`externalsecret.yaml`, two ExternalSecrets so the web app never holds the
shared cluster's superuser password:

- `bookorbit-config` -> Secret `bookorbit-secret` (app container), `dataFrom`
  item `bookorbit`:

  ```
  DATABASE_URL: postgres://<user>:<pass>@postgres-rw.postgresql-system.svc.cluster.local:5432/bookorbit  (urlquery-escaped)
  JWT_SECRET, PODCAST_ENCRYPTION_KEY, SETUP_BOOTSTRAP_TOKEN,
  EMAIL_ENCRYPTION_KEY, MIGRATION_ENCRYPTION_KEY
  ```

- `bookorbit-init` -> Secret `bookorbit-init-secret` (init containers only),
  `dataFrom` items `bookorbit` and `postgres`:

  ```
  INIT_POSTGRES_HOST: postgres-rw.postgresql-system.svc.cluster.local
  INIT_POSTGRES_DBNAME: bookorbit
  INIT_POSTGRES_USER / INIT_POSTGRES_PASS
  INIT_POSTGRES_SUPER_PASS: superuser-password from the postgres item
  ```

`helmrelease.yaml`, controller `bookorbit`, `strategy: Recreate`,
reloader annotation:

- initContainers
  - `01-init-db`: `ghcr.io/home-operations/postgres-init:18.6.0` (digest
    pinned, same image authentik uses), `envFrom` `bookorbit-init-secret`.
    Creates role and database (idempotent).
  - `02-init-extensions`: the same postgres-init image with a custom
    command (it ships `psql`), `envFrom`
    `bookorbit-init-secret`, runs `psql` as
    `postgres` (password from `INIT_POSTGRES_SUPER_PASS`) against the
    `bookorbit` database:
    `CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; ... "pg_trgm"; ... "unaccent"; ... "vector";`
    followed by `ALTER EXTENSION ... UPDATE` for each, so a newer extension
    version shipped by a CNPG image bump is applied without a manual
    superuser step. Idempotent, runs on every pod start, so a restored PVC
    or a rebuilt database never crash-loops on a missing extension.
- container `app`
  - image `ghcr.io/bookorbit/bookorbit:3.4.0@sha256:99539be0…` (full digest)
  - env: `TZ=America/Toronto`, `PORT=3000`, `HOME=/tmp`,
    `APP_URL=https://bookorbit.${SECRET_DOMAIN}`, `PUID=1000`, `PGID=1000`,
    `NODE_MAX_OLD_SPACE_SIZE=auto`, `LIBRARY_BROWSE_ROOT=/books`,
    `BOOK_DOCK_PATH=/bookdrop`, `OIDC_ALLOW_LOCAL_ISSUERS=true`
    (`sso.${SECRET_DOMAIN}` resolves to the LAN address of envoy-internal from
    inside the cluster, and BookOrbit's production SSRF guard rejects private
    OIDC endpoints without this flag)
  - `envFrom` `bookorbit-secret`
  - securityContext: runAsUser/Group 1000, runAsNonRoot, no privilege
    escalation, readOnlyRootFilesystem, drop ALL
  - probes: liveness and readiness `httpGet /api/v1/health` port 3000,
    initialDelay 30s, period 10s, timeout 5s, failureThreshold 5
  - resources: requests 100m / 512Mi, limit 2Gi (the entrypoint sizes the
    Node heap from the cgroup limit)
- defaultPodOptions.securityContext: fsGroup 1000, OnRootMismatch
- persistence
  - `data`: existingClaim `${VOLSYNC_CLAIM:=${APP}}` at `/data`
  - `tmp`: emptyDir at `/tmp`
  - `books`: NFS `nas.internal:/mnt/tank/nfs/booklore/library` at `/books`
  - `bookdrop`: NFS `nas.internal:/mnt/tank/nfs/booklore/incoming` at `/bookdrop`
  - `imports`: NFS `nas.internal:/mnt/tank/nfs/booklore/bookorbit-imports`
    at `/imports`, readOnly (removed in the retirement PR; the media root
    path is entered in the wizard, no env var needed)
- service `app` port 3000
- route `app`: hostname `bookorbit.${SECRET_DOMAIN}`, `envoy-internal`
  section `https`, homepage annotations (name BookOrbit, group Media,
  description "Digital library management", icon `bookorbit.png`

### Change to booklore (same PR)

Add a second service port `mariadb` 3306 to the booklore `app` service so the
wizard can reach `booklore.default:3306`. ClusterIP only; the namespace has no
network policies. Removed with the app in the retirement PR.

### Secrets and NAS preparation (not in Git)

- `op item create` in vault HomeInfra, title `bookorbit`, category Database (same as the booklore and swimstats items),
  fields: `POSTGRES_USER=bookorbit`, `POSTGRES_PASSWORD`
  (openssl rand -hex 24), `JWT_SECRET`, `PODCAST_ENCRYPTION_KEY`,
  `EMAIL_ENCRYPTION_KEY`, `MIGRATION_ENCRYPTION_KEY` (each hex 32),
  `SETUP_BOOTSTRAP_TOKEN` (hex 16). Values are never printed.
- On the NAS: `mkdir /mnt/tank/nfs/booklore/bookorbit-imports`, owner
  `kube:builtin_users` like its siblings. It is inside the existing
  `/mnt/tank/nfs/booklore` export.

### Migration runbook `docs/BOOKORBIT_MIGRATION.md`

Pre-flight (BookLore still live, nobody edits metadata in BookLore from here on):

1. Trigger a Volsync backup of the booklore PVC with
   `./scripts/trigger-volsync-backup.sh booklore default` (app first, namespace
   second) and wait for it.
2. `mysqldump` the booklore database from the MariaDB sidecar and a tarball
   of `/app/data` into `/mnt/tank/nfs/booklore/archive-2026-10/` on the NAS.
   This archive is the long-term fallback (about 220 MB) and is not touched
   by the retirement step; delete it by hand whenever you no longer care.
3. Copy covers: `kubectl exec` into booklore `app`, `tar` `/app/data/images`,
   stream to `root@nas.internal` and extract into
   `bookorbit-imports/booklore-data/images` so the media root is
   `/imports/booklore-data` from inside BookOrbit.

Rollout:

4. Merge the PR, let Flux reconcile, check both init containers pass and the
   pod is Ready. Expect the 22 files from the NAS `incoming` share to appear
   in the Book Dock.
5. Open `https://bookorbit.<domain>`, create the first account as `admin`
   with the booklore@ email using `SETUP_BOOTSTRAP_TOKEN` from 1Password.
6. Authentik: create a confidential OAuth2 provider and application
   `bookorbit` (redirect URI `https://bookorbit.<domain>/oauth2-callback`,
   scopes openid profile email, same claim mapping as the booklore provider:
   username from `preferred_username`, email from `email`). Configure OIDC in
   BookOrbit Settings with the new issuer `sso.<domain>/application/o/bookorbit/`,
   client id and client secret, enable auto-provisioning, keep local login
   enabled.
7. pasha and valia each log in once through Authentik so their accounts exist
   with the right usernames and emails. Promote pasha to admin.
8. Create one library on `/books`, scan, expect 270 books. Leave file
   renaming and metadata write-back off.

Migration:

9. Settings > Maintenance > Import from Booklore: host `booklore.default`,
   port 3306, database `booklore`, user `booklore`, password `DATABASE_PASSWORD`
   from the booklore 1Password item, media root `/imports/booklore-data`.
   Save & Validate, confirm the cover warning is absent.
10. Map users admin, pasha, valia to the three BookOrbit accounts. Path
    mapping `/books` to the BookOrbit library folder. Dry run, resolve
    duplicates, run, read the report.
11. Recreate the 5 magic shelves by hand as BookOrbit smart collections.
12. OPDS: set an OPDS password in BookOrbit and re-point the reader app to
    the BookOrbit OPDS URL.

Verification gate (all must pass before retirement):

- Dry run matched all 270 books; unresolved rows explained before the run.
- pasha's reading progress is present on the 7 books that have it.
- All 9 shelves arrived as collections under the right owners; 5 magic
  shelves recreated.
- Covers, including custom-uploaded ones, show on a spot check.
- pasha and valia log in through Authentik; admin logs in locally.
- OPDS feed works from the reader with the new password.
- Volsync completed one backup of the bookorbit PVC; the first CNPG WAL
  archive after the migration is visible in Barman.

Retirement PR (same day the gate passes):

13. Delete `kubernetes/apps/default/booklore` and its entry in the namespace
    kustomization; remove the `imports` mount from bookorbit; drop the old
    `booklore` database and role on the shared Postgres with a superuser
    `psql` (manual, documented); remove the NAS imports folder; archive the
    booklore 1Password item; delete the booklore Authentik application and
    provider. The NAS archive from step 2 stays. Kopia snapshots of the
    booklore PVC do not expire once the ReplicationSource is gone (retention
    is applied only during backup runs); they stay in the repository until
    removed by hand, which is a later housekeeping task, not part of this
    migration.

Rollback: if validation or the dry run fails, BookLore keeps running
untouched. The bookorbit app, its database and PVC can be removed without
affecting BookLore; the `/books` share is never written by the wizard.
After retirement, the NAS archive (MariaDB dump plus `/app/data`) is enough
to stand BookLore back up or re-run the wizard against a temporary MariaDB.

### Validation before commit

- `kubectl kustomize kubernetes/apps/default/bookorbit/app`
- `flux build ks bookorbit --path kubernetes/apps/default/bookorbit/app --kustomization-file kubernetes/apps/default/bookorbit/ks.yaml --dry-run` (substitutions need the cluster, so run against the live cluster read-only)
- `helm template` with app-template 5.3.0 and the HelmRelease values
  (`--api-versions gateway.networking.k8s.io/v1/HTTPRoute`, otherwise the
  chart renders HTTPRoute `v1alpha2`, which the cluster does not serve)
- `kubectl apply --dry-run=server` on the rendered output
- Schema directive placement and URL existence on every new file

### Risks

- The wizard was tested upstream with BookLore v2.2.2; we run v2.4.0. The
  schema has been stable across 2.x, and the dry run reports unresolved rows
  before anything is written. If validation fails, BookLore keeps running.
- Volsync snapshots of BookOrbit `/data` only hold covers and the book
  bucket; the database is protected by CNPG Barman backups, not Volsync.
- `MIGRATION_ENCRYPTION_KEY` encrypts the stored MariaDB credentials; it
  must stay in the secret while the migration source exists.
- BookLore's metadata write-back into files stays enabled until it is
  deleted; the no-edits rule during the window is procedural, not enforced.
- `readOnlyRootFilesystem` is untested upstream for this image. `/tmp` is an
  emptyDir and `HOME=/tmp`; if startup fails on a write elsewhere, the
  fallback is `readOnlyRootFilesystem: false` with a comment, as umami does.
