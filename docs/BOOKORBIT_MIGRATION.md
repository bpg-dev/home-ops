# BookLore -> BookOrbit migration

Status: **DONE 2026-10-16** (deploy commit 96077662; retirement is the commit that removed kubernetes/apps/default/booklore). Design:
`docs/superpowers/specs/2026-10-14-bookorbit-migration-design.md`.

BookOrbit (<https://github.com/bookorbit/bookorbit>) is BookLore's official
successor; BookLore is in maintenance mode. BookOrbit runs on Postgres (dedicated
`bookorbit` database on the shared CNPG cluster) instead of a MariaDB sidecar,
and ships a guided "Import from Booklore" wizard that reads BookLore's MariaDB
over the network and overlays metadata, progress, shelves and covers onto books
BookOrbit has already scanned from the same library folder.

Both apps run side by side only for the migration window. Nobody edits metadata
in BookLore once the pre-flight copies are taken, and BookLore is deleted the
same day the verification gate passes.

## What was in Git during the migration (deploy 96077662)

The retirement commit removed the booklore app, its 3306 Service port and the
`/imports` mount; only the bookorbit app remains.

- `kubernetes/apps/default/bookorbit/` - app-template HelmRelease, ExternalSecret,
  Volsync-backed 10Gi PVC at `/data`, NFS mounts `/books` (library), `/bookdrop`
  (Book Dock drop folder = the old BookLore bookdrop share) and `/imports`
  (read-only, migration-only).
- Two init containers: `01-init-db` (onedr0p/postgres-init, role + database) and
  `02-init-extensions` (superuser `CREATE EXTENSION` for `uuid-ossp`, `pg_trgm`,
  `unaccent`, `vector`; pgvector is not a trusted extension, so the app user
  cannot create it). A CNPG image without pgvector makes this init container
  fail and blocks every bookorbit restart on purpose; check its log first. They read `bookorbit-init-secret`, which holds the shared
  CNPG superuser password; the app container reads only `bookorbit-secret`.
- `OIDC_ALLOW_LOCAL_ISSUERS=true`: `sso.<domain>` resolves to envoy-internal's LAN
  address from inside the cluster and BookOrbit's production SSRF guard would
  otherwise reject Authentik's discovery document.
- `booklore` Service exposed port 3306 (`booklore.default:3306`) for the wizard
  (removed with the app).

## Pre-flight (BookLore live; no more metadata edits in BookLore after this)

1. Volsync backup of the booklore PVC:
   `./scripts/trigger-volsync-backup.sh booklore default`
2. Engine-independent archive on the NAS (kept indefinitely, about 220 MB):
   ```bash
   export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig
   kubectl -n default exec deploy/booklore -c mariadb -- sh -c 'mariadb-dump -ubooklore -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers booklore' \
     | ssh root@nas.internal 'cat > /mnt/tank/nfs/booklore/archive-2026-10/booklore-mariadb.sql'
   kubectl -n default exec deploy/booklore -c app -- tar cf - -C /app data \
     | ssh root@nas.internal 'cat > /mnt/tank/nfs/booklore/archive-2026-10/booklore-app-data.tar'
   ssh root@nas.internal 'ls -la /mnt/tank/nfs/booklore/archive-2026-10/ && tar tf /mnt/tank/nfs/booklore/archive-2026-10/booklore-app-data.tar | head -3'
   ```
3. Covers for the wizard (media root `/imports/booklore-data`; the adapter looks
   for an `images/` directory under it):
   ```bash
   kubectl -n default exec deploy/booklore -c app -- tar cf - -C /app/data images \
     | ssh root@nas.internal 'mkdir -p /mnt/tank/nfs/booklore/bookorbit-imports/booklore-data && tar xf - -C /mnt/tank/nfs/booklore/bookorbit-imports/booklore-data && chown -R kube:builtin_users /mnt/tank/nfs/booklore/bookorbit-imports && find /mnt/tank/nfs/booklore/bookorbit-imports -type f | wc -l'
   ```
   Expected file count: 554 (277 books x cover.jpg + thumbnail.jpg, as of 2026-10-15).

## Rollout

4. Merge the PR. `flux reconcile kustomization flux-system --with-source`, then
   `flux get ks bookorbit -n default`, `flux get hr bookorbit -n default`,
   `kubectl -n default get pod,pvc,externalsecret -l app.kubernetes.io/name=bookorbit`
   (three ExternalSecrets: `bookorbit-config`, `bookorbit-init`, `bookorbit-volsync`).
   Both init containers must complete; the app pod must be Ready.
   `kubectl -n default logs deploy/bookorbit -c 02-init-extensions` shows the four
   extension rows. `kubectl -n default logs deploy/bookorbit -c app | grep -i -E 'erofs|eacces|permission'`
   must be empty (read-only root filesystem risk).
5. Open `https://bookorbit.<domain>`. On the setup page create the first account:
   username `admin`, email `booklore@<domain>` (same as BookLore's admin so the
   wizard matches it), bootstrap token = `SETUP_BOOTSTRAP_TOKEN` from the
   `bookorbit` 1Password item. This account stays as the break-glass local login.
6. Authentik (done by Claude in the user's Chrome session; the user pastes the
   client secret and any other secret value, see the plan's Task 7 note):
   - Providers > Create > OAuth2/OpenID Provider: name `bookorbit`, client type
     Confidential, redirect URI `https://bookorbit.<domain>/oauth2-callback`
     (strict), signing key the same as the booklore provider, scopes
     `openid profile email`, subject mode same as booklore. If the provider is
     created through the Authentik API, `grant_types` defaults to empty; set it
     to `authorization_code` and `refresh_token` or the login fails.
   - Applications > Create: name `BookOrbit`, slug `bookorbit`, provider `bookorbit`.
     Issuer becomes `https://sso.<domain>/application/o/bookorbit/`.
   - BookOrbit Settings > Authentication > OIDC: display name `Authentik`, issuer
     URL as above, client id and client secret from the provider, scopes
     `openid profile email`, claim mapping username `preferred_username`,
     name `name`, email `email`, auto-provision enabled, local login kept enabled.
7. pasha and valia each log in once via "Sign in with Authentik" so their accounts
   exist with the right usernames and emails. Promote `pasha` to superuser.
   (Outcome: valia was skipped; see the gate outcome below.)
8. Settings > Libraries > create one library on `/books` with scan mode
   **File as Book** (irreversible; `/books` is flat plus series folders holding
   several volumes, and "Folder as Book" would merge each series into one book).
   Turn on "Watch folders". Scan. Expect 270 books.
   Leave file renaming and metadata write-back off until BookLore is gone.
   Settings > Book Dock: the 22 epubs from the NAS `incoming` share should be
   listed; leave them for triage after the migration. BookOrbit creates a
   `covers/` directory inside that share for dock thumbnails; it is not clutter.

## Migration

9. From inside the pod, confirm MariaDB is reachable:
   `kubectl -n default exec deploy/bookorbit -c app -- sh -c 'nc -z -w3 booklore.default 3306 && echo open'`
10. Settings > Maintenance > Import from Booklore > Get Started.
    Source: host `booklore.default`, port `3306`, database `booklore`, user
    `booklore`, password = `DATABASE_PASSWORD` from the `booklore` 1Password item,
    SSL off, media root path `/imports/booklore-data`. Save & Validate: expect the
    Validated badge and no `mediaRootPath` warning.
11. User mapping: `admin` -> `admin`, `pasha` -> `pasha`, `valia` -> `valia`.
    Path mapping: source prefix `/books` -> the BookOrbit library folder `/books`.
12. Dry run. Expect 270 matched. Resolve any duplicates, explain any unresolved
    rows before continuing. Run migration. Read the report (Books and User Data
    panels); export it as JSON into the NAS archive folder for the record.
13. Recreate the 5 BookLore magic shelves by hand as BookOrbit smart collections
    (magic shelves are not migrated).
14. OPDS: Settings > OPDS, set a password, re-point the reader app to
    `https://bookorbit.<domain>/api/v1/opds` (`/opds` serves the web app, not
    the feed; credentials are not migrated).

## Verification gate (all must pass before retirement)

- [x] Dry run matched all 270 books; unresolved rows explained before the run.
- [x] pasha's reading progress present on the 7 books that had it in BookLore.
- [x] All 9 shelves arrived as collections under the right owners (admin 4,
      pasha 4, valia 1); 5 magic shelves recreated.
- [x] Covers, including custom-uploaded ones, show on a spot check.
- [x] pasha and valia log in through Authentik; admin logs in locally.
- [x] OPDS feed works from the reader with the new password.
- [x] `kubectl -n default get replicationsource bookorbit` shows a completed
      sync; CNPG `ContinuousArchiving` condition is True (the Barman plugin does
      not populate `lastSuccessfulArchiveTime`).

Outcome (2026-10-15, run #1, 5.9 s, 0 failed):

- valia was skipped at the user's request: no BookOrbit account, her one
  (empty) shelf was not mapped. She auto-provisions on her first Authentik login.
- 8 shelves became collections (admin 4, pasha 4); only pasha's Favorites held
  books (2). 268 of 270 covers imported; the other 2 books have no cover in
  BookLore either. Bookmarks 0 because BookLore has no bookmark table.
- Magic shelves recreated as 5 smart scopes under pasha (Security made visible
  to all users; it matched 0 books in BookLore too).
- OPDS account `pasha` on `/api/v1/opds`.

## Retirement (same day the gate passes)

15. PR: delete `kubernetes/apps/default/booklore/` and its entry in
    `kubernetes/apps/default/kustomization.yaml`; remove the `imports` block from
    `kubernetes/apps/default/bookorbit/app/helmrelease.yaml`. Flux prunes the
    booklore Deployment, Service, HTTPRoute, PVC and Volsync objects.
16. Shared Postgres cleanup (superuser via the CNPG primary pod; the empty
    `booklore` database and role predate the MariaDB sidecar and were only used
    as the test bed for the extension script):
    `DROP DATABASE booklore; DROP OWNED BY booklore; DROP ROLE booklore;`
    (`DROP OWNED` clears any stray grants so `DROP ROLE` cannot fail halfway).
17. NAS: `rm -rf /mnt/tank/nfs/booklore/bookorbit-imports`. Keep `archive-2026-10/`.
18. 1Password: archive the `booklore` item. Authentik: delete the `booklore`
    application and provider.
19. Memory/docs: update this file's status line to DONE with the commit hashes.

Not done by this migration: booklore's Kopia snapshots in the Volsync repository
stop expiring once the ReplicationSource is gone (retention is applied only during
backup runs). Removing them is separate housekeeping.

## Rollback

If validation or the dry run fails, BookLore keeps running untouched; the
bookorbit app, database and PVC can be removed without affecting it. The wizard
never writes to `/books`. After retirement, `archive-2026-10/` (MariaDB dump plus
`/app/data` tarball) is enough to stand BookLore back up or re-run the wizard
against a temporary MariaDB.
