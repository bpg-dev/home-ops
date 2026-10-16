# BookOrbit Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy BookOrbit 3.4.0 next to BookLore, migrate BookLore's data through BookOrbit's guided wizard, then retire BookLore.

**Architecture:** A new app-template HelmRelease in `kubernetes/apps/default/bookorbit/` with a Volsync-backed PVC for covers, the same two NAS NFS shares BookLore uses, a read-only NAS mount for the migration source files, and a dedicated database on the shared CloudNative-PG cluster bootstrapped by two init containers (role/database, then superuser-created extensions). BookLore gets one extra Service port so the wizard can reach its MariaDB. Everything outside Git (1Password item, NAS folders, Authentik provider, wizard clicks, retirement cleanup) is a numbered runbook in `docs/BOOKORBIT_MIGRATION.md`.

**Tech Stack:** Flux CD, bjw-s app-template 5.3.0, External Secrets Operator with 1Password, Volsync/Kopia, CloudNative-PG (Postgres 18 with pgvector 0.8.1), Envoy Gateway HTTPRoute, Authentik OIDC.

**Spec:** `docs/superpowers/specs/2026-10-14-bookorbit-migration-design.md`

## Global Constraints

- Repo rules from `CLAUDE.md` apply: no `kubectl apply/create/patch/delete`, no `git commit/push` without the user's explicit approval, no raw Secrets or ConfigMaps, no `metadata.namespace` in app resources, images pinned by tag plus digest, rootless containers with `capabilities.drop: [ALL]`, RWO Deployments use `strategy: Recreate`.
- Exception already in use by `scripts/trigger-volsync-backup.sh`: that script patches the ReplicationSource trigger; running the script is allowed, hand-written patches are not.
- Every YAML file starts with `---` followed immediately by the `# yaml-language-server: $schema=...` line; 2-space indentation; kustomization resources alphabetical.
- Image: `ghcr.io/bookorbit/bookorbit:3.4.0@sha256:99539be044c94f10fa5fba616cb08e1b128deb4996c975d181a950818a8632e4`.
- Chart: `oci://ghcr.io/bjw-s-labs/helm/app-template` tag `5.3.0`.
- Database host: `postgres-rw.postgresql-system.svc.cluster.local:5432`, database and role `bookorbit`.
- Extensions required before the app's own migration runs: `uuid-ossp`, `pg_trgm`, `unaccent`, `vector`.
- Hostname `bookorbit.${SECRET_DOMAIN}` on `envoy-internal`; `APP_URL` is the HTTPS form of that hostname.
- Volsync: capacity `10Gi`, schedule `45 * * * *`.
- Secrets are never printed, logged, or pasted into chat or files. `op` output is piped through `jq`/`python3 -I` to show field labels only.
- `KUBECONFIG` and `TALOSCONFIG` are absolute paths: `export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig`.
- Scratch files go in `/private/tmp/claude-501/-Users-pasha-code-home-ops/6b879a6d-f57b-4d88-b334-11009dbcff48/scratchpad` (referred to below as `$SCRATCH`). The app-template 5.3.0 chart is already unpacked at `$SCRATCH/chart/app-template`.

## Review Focus

1. **Extension bootstrap on an already-current database.** Re-running `CREATE EXTENSION IF NOT EXISTS` plus `ALTER EXTENSION ... UPDATE` on a database that already has the latest versions must exit 0 with notices, never an error; a crash here blocks every pod restart. Pinned in Task 3 step 9 by running the exact script twice against the leftover empty `booklore` database.
2. **Read-only root filesystem.** BookOrbit's entrypoint writes only under `/data` and `/tmp` when it runs as a non-root UID, and `HOME=/tmp`. If the pod crash-loops with `EROFS` or `EACCES` outside those paths, the expected behavior is a documented fallback, not a silent retry. Pinned in Task 6 step 4 by reading the first pod's logs for those strings before declaring the rollout healthy.
3. **Book Dock on the shared NFS share.** The `incoming` share holds files owned by UID 3000 with mode 664 in a 775 directory owned by UID 1000. BookOrbit (UID 1000) can read and move them but not rewrite their contents. Expected behavior: files appear in the dock and can be finalized; "Discard" deletes them from the NAS. Pinned in Task 6 step 6 by confirming the 22 files are listed and that no permission error appears in the log.
4. **Wizard against an unreachable or wrong-port MariaDB.** `Save & Validate` must fail with "Could not reach the database server" rather than hang, and the booklore Service must expose 3306 before the wizard runs. Pinned in Task 3 step 6 (service port rendered) and Task 8 step 2 (TCP check from inside the bookorbit pod before opening the wizard).
5. **OIDC issuer resolving to a private address.** Without `OIDC_ALLOW_LOCAL_ISSUERS=true` BookOrbit rejects the Authentik discovery document in production mode. Pinned in Task 3 step 7 (env rendered) and Task 7 step 5 (a successful SSO round-trip for pasha).

---

### Task 1: 1Password item `bookorbit`

**Files:** none in Git.

**Interfaces:**
- Produces: 1Password item `bookorbit` in vault `HomeInfra`, category Database, with fields `POSTGRES_USER`, `POSTGRES_PASSWORD`, `JWT_SECRET`, `PODCAST_ENCRYPTION_KEY`, `SETUP_BOOTSTRAP_TOKEN`, `EMAIL_ENCRYPTION_KEY`, `MIGRATION_ENCRYPTION_KEY`. Task 3's ExternalSecret reads these exact labels.

- [ ] **Step 1: Confirm the item does not exist yet**

Run:
```bash
op item get bookorbit --vault HomeInfra 2>&1 | head -1
```
Expected: an error line containing `isn't an item`. If the item exists, stop and ask the user whether to reuse it.

- [ ] **Step 2: Create the item with generated values**

Run (values are generated inside the shell and never echoed):
```bash
op item create --vault HomeInfra --category Database --title bookorbit \
  "POSTGRES_USER[text]=bookorbit" \
  "POSTGRES_PASSWORD[concealed]=$(openssl rand -hex 24)" \
  "JWT_SECRET[concealed]=$(openssl rand -hex 32)" \
  "PODCAST_ENCRYPTION_KEY[concealed]=$(openssl rand -hex 32)" \
  "SETUP_BOOTSTRAP_TOKEN[concealed]=$(openssl rand -hex 16)" \
  "EMAIL_ENCRYPTION_KEY[concealed]=$(openssl rand -hex 32)" \
  "MIGRATION_ENCRYPTION_KEY[concealed]=$(openssl rand -hex 32)" \
  --format json | python3 -I -c "import sys,json; d=json.load(sys.stdin); print(d['vault']['name'], d['category'], sorted(f['label'] for f in d['fields'] if f.get('label')))"
```
Expected output line: `HomeInfra DATABASE [...]` where the list contains the seven labels above (1Password adds its own default Database fields such as `notesPlain`, `server`, `port`; those are harmless).

- [ ] **Step 3: Verify the labels the ExternalSecret will read**

Run:
```bash
op item get bookorbit --vault HomeInfra --format json | python3 -I -c "
import sys,json
want={'POSTGRES_USER','POSTGRES_PASSWORD','JWT_SECRET','PODCAST_ENCRYPTION_KEY','SETUP_BOOTSTRAP_TOKEN','EMAIL_ENCRYPTION_KEY','MIGRATION_ENCRYPTION_KEY'}
have={f['label'] for f in json.load(sys.stdin)['fields'] if f.get('label')}
print('missing:', sorted(want-have))"
```
Expected: `missing: []`

---

### Task 2: NAS folders for the migration source and the BookLore archive

**Files:** none in Git.

**Interfaces:**
- Produces: `/mnt/tank/nfs/booklore/bookorbit-imports/` (mounted read-only into BookOrbit at `/imports` by Task 3) and `/mnt/tank/nfs/booklore/archive-2026-10/` (long-term BookLore fallback, filled by Task 5).

- [ ] **Step 1: Create both folders with the same owner as their siblings**

Run:
```bash
ssh root@nas.internal 'mkdir -p /mnt/tank/nfs/booklore/bookorbit-imports /mnt/tank/nfs/booklore/archive-2026-10 && chown kube:builtin_users /mnt/tank/nfs/booklore/bookorbit-imports /mnt/tank/nfs/booklore/archive-2026-10 && chmod 775 /mnt/tank/nfs/booklore/bookorbit-imports /mnt/tank/nfs/booklore/archive-2026-10 && ls -la /mnt/tank/nfs/booklore/'
```
Expected: listing shows `archive-2026-10`, `bookorbit-imports`, `incoming`, `library`, all `drwxrwxr-x kube builtin_users`.

- [ ] **Step 2: Confirm the new folders sit inside the existing NFS export**

Run:
```bash
ssh root@nas.internal 'grep -n "/mnt/tank/nfs/booklore" /etc/exports'
```
Expected: one export line for `/mnt/tank/nfs/booklore` (the parent of both new folders), so no export change is needed. The real mount check from inside BookOrbit is Task 6 step 5.

---

### Task 3: BookOrbit manifests and the booklore Service port

**Files:**
- Create: `kubernetes/apps/default/bookorbit/ks.yaml`
- Create: `kubernetes/apps/default/bookorbit/app/kustomization.yaml`
- Create: `kubernetes/apps/default/bookorbit/app/ocirepository.yaml`
- Create: `kubernetes/apps/default/bookorbit/app/externalsecret.yaml`
- Create: `kubernetes/apps/default/bookorbit/app/helmrelease.yaml`
- Modify: `kubernetes/apps/default/kustomization.yaml` (resources list)
- Modify: `kubernetes/apps/default/booklore/app/helmrelease.yaml` (`service.app.ports`)

**Interfaces:**
- Consumes: 1Password item `bookorbit` (Task 1) and item `postgres` field `superuser-password`; 1Password item `volsync-template` through the volsync component.
- Produces: Flux Kustomization `bookorbit`; Secret `bookorbit-secret` (app container only) with keys `DATABASE_URL`, `JWT_SECRET`, `PODCAST_ENCRYPTION_KEY`, `SETUP_BOOTSTRAP_TOKEN`, `EMAIL_ENCRYPTION_KEY`, `MIGRATION_ENCRYPTION_KEY`; Secret `bookorbit-init-secret` (init containers only) with keys `INIT_POSTGRES_HOST`, `INIT_POSTGRES_DBNAME`, `INIT_POSTGRES_USER`, `INIT_POSTGRES_PASS`, `INIT_POSTGRES_SUPER_PASS`; Service `bookorbit` port 3000; Service `booklore` port 3306; HTTPRoute `bookorbit`.
- The superuser password is deliberately kept out of the app container's environment: the web app must never hold credentials for the other databases on the shared cluster.

- [ ] **Step 1: Write `ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app bookorbit
spec:
  targetNamespace: default
  dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph-external
    - name: postgres-cluster
      namespace: postgresql-system
  components:
    - ../../../../components/volsync
  interval: 1h
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/default/bookorbit/app
  postBuild:
    substitute:
      APP: *app
      VOLSYNC_CLAIM: *app
      # Covers and Book Dock staging only; the database lives on the shared CNPG cluster
      VOLSYNC_CAPACITY: 10Gi
      VOLSYNC_SCHEDULE: "45 * * * *"
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  wait: false
```

- [ ] **Step 2: Write `app/kustomization.yaml` and `app/ocirepository.yaml`**

`app/kustomization.yaml`:
```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./externalsecret.yaml
  - ./helmrelease.yaml
  - ./ocirepository.yaml
```

`app/ocirepository.yaml`:
```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: bookorbit
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.3.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

- [ ] **Step 3: Write `app/externalsecret.yaml`**

Two ExternalSecrets in one file. The app container gets only its own keys; the shared-cluster superuser password lives in a second Secret that only the init containers mount.

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: bookorbit-config
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: bookorbit-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        DATABASE_URL: "postgres://{{ .POSTGRES_USER | urlquery }}:{{ .POSTGRES_PASSWORD | urlquery }}@postgres-rw.postgresql-system.svc.cluster.local:5432/bookorbit"
        JWT_SECRET: "{{ .JWT_SECRET }}"
        PODCAST_ENCRYPTION_KEY: "{{ .PODCAST_ENCRYPTION_KEY }}"
        SETUP_BOOTSTRAP_TOKEN: "{{ .SETUP_BOOTSTRAP_TOKEN }}"
        EMAIL_ENCRYPTION_KEY: "{{ .EMAIL_ENCRYPTION_KEY }}"
        MIGRATION_ENCRYPTION_KEY: "{{ .MIGRATION_ENCRYPTION_KEY }}"
  dataFrom:
    - extract:
        key: bookorbit
  refreshInterval: 30m
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/external-secrets.io/externalsecret_v1.json
# Init containers only: role + database (01-init-db) and extensions (02-init-extensions).
# Holds the shared CNPG superuser password, so the app container must never mount it.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: bookorbit-init
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: bookorbit-init-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        INIT_POSTGRES_HOST: postgres-rw.postgresql-system.svc.cluster.local
        INIT_POSTGRES_DBNAME: bookorbit
        INIT_POSTGRES_USER: "{{ .POSTGRES_USER }}"
        INIT_POSTGRES_PASS: "{{ .POSTGRES_PASSWORD }}"
        INIT_POSTGRES_SUPER_PASS: "{{ index . \"superuser-password\" }}"
  dataFrom:
    - extract:
        key: bookorbit
    - extract:
        key: postgres
  refreshInterval: 30m
```

- [ ] **Step 4: Write `app/helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app bookorbit
spec:
  chartRef:
    kind: OCIRepository
    name: bookorbit
  interval: 1h
  timeout: 10m
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
  values:
    controllers:
      bookorbit:
        annotations:
          reloader.stakater.com/auto: "true"
        strategy: Recreate
        initContainers:
          # Creates the bookorbit role and database on the shared CNPG cluster (idempotent).
          # Same pinned image as authentik's init-db; it ships psql, so 02 reuses it.
          01-init-db:
            image:
              repository: ghcr.io/home-operations/postgres-init
              tag: 18.6.0@sha256:b6d3af974df781c673d37e49bdddfa14a6f5be28b18d2cb7713f0449bea4057b
            envFrom:
              - secretRef:
                  name: bookorbit-init-secret
            securityContext: &initSecurityContext
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: { drop: ["ALL"] }
          # BookOrbit's own migration runs CREATE EXTENSION as the app user, but
          # pgvector ("vector") is not a trusted extension, so a superuser must
          # create it first. ALTER EXTENSION ... UPDATE keeps the extensions current
          # after CNPG image bumps. Idempotent; runs on every pod start.
          02-init-extensions:
            image:
              repository: ghcr.io/home-operations/postgres-init
              tag: 18.6.0@sha256:b6d3af974df781c673d37e49bdddfa14a6f5be28b18d2cb7713f0449bea4057b
            env:
              HOME: /tmp
            envFrom:
              - secretRef:
                  name: bookorbit-init-secret
            command: ["/bin/sh", "-c"]
            args:
              - |
                set -eu
                export PGPASSWORD="$INIT_POSTGRES_SUPER_PASS"
                psql -v ON_ERROR_STOP=1 -h "$INIT_POSTGRES_HOST" -U postgres -d "$INIT_POSTGRES_DBNAME" <<'SQL'
                CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
                CREATE EXTENSION IF NOT EXISTS "pg_trgm";
                CREATE EXTENSION IF NOT EXISTS "unaccent";
                CREATE EXTENSION IF NOT EXISTS "vector";
                ALTER EXTENSION "uuid-ossp" UPDATE;
                ALTER EXTENSION "pg_trgm" UPDATE;
                ALTER EXTENSION "unaccent" UPDATE;
                ALTER EXTENSION "vector" UPDATE;
                SELECT extname, extversion FROM pg_extension WHERE extname IN ('uuid-ossp', 'pg_trgm', 'unaccent', 'vector');
                SQL
            securityContext: *initSecurityContext
        containers:
          app:
            image:
              repository: ghcr.io/bookorbit/bookorbit
              tag: 3.4.0@sha256:99539be044c94f10fa5fba616cb08e1b128deb4996c975d181a950818a8632e4
            env:
              TZ: "America/Toronto"
              PORT: &port 3000
              # The entrypoint runs as the pod UID (no su-exec) and uses HOME for caches
              HOME: /tmp
              PUID: "1000"
              PGID: "1000"
              APP_URL: "https://bookorbit.${SECRET_DOMAIN}"
              TRUST_PROXY: "true"
              # Node heap sized from the cgroup memory limit
              NODE_MAX_OLD_SPACE_SIZE: auto
              LIBRARY_BROWSE_ROOT: /books
              # Book Dock watches the NAS incoming share (same folder BookLore used as bookdrop)
              BOOK_DOCK_PATH: /bookdrop
              # sso.${SECRET_DOMAIN} resolves to envoy-internal's LAN address from inside the
              # cluster; BookOrbit's production SSRF guard rejects private OIDC endpoints otherwise
              OIDC_ALLOW_LOCAL_ISSUERS: "true"
            envFrom:
              - secretRef:
                  name: bookorbit-secret
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /api/v1/health
                    port: *port
                  initialDelaySeconds: 30
                  periodSeconds: 10
                  timeoutSeconds: 5
                  failureThreshold: 5
              readiness: *probes
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: { drop: ["ALL"] }
            resources:
              requests:
                cpu: 100m
                memory: 512Mi
              limits:
                memory: 2Gi
    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
    service:
      app:
        controller: bookorbit
        ports:
          http:
            port: *port
    route:
      app:
        annotations:
          gethomepage.dev/enabled: "true"
          gethomepage.dev/name: "BookOrbit"
          gethomepage.dev/description: "Digital library management"
          gethomepage.dev/group: "Media"
          gethomepage.dev/icon: "bookorbit.png"
        hostnames: ["bookorbit.${SECRET_DOMAIN}"]
        parentRefs:
          - name: envoy-internal
            namespace: network
            sectionName: https
        rules:
          - backendRefs:
              - identifier: app
                port: *port
    persistence:
      # Covers and Book Dock staging on a Volsync-backed PVC
      data:
        existingClaim: "${VOLSYNC_CLAIM:=${APP}}"
        advancedMounts:
          bookorbit:
            app:
              - path: /data
      tmp:
        type: emptyDir
        globalMounts:
          - path: /tmp
      # Book library on NFS (computer-books/ and novels/ collections inside)
      books:
        type: nfs
        server: nas.internal
        path: /mnt/tank/nfs/booklore/library
        advancedMounts:
          bookorbit:
            app:
              - path: /books
      # Book Dock drop folder on NFS
      bookdrop:
        type: nfs
        server: nas.internal
        path: /mnt/tank/nfs/booklore/incoming
        advancedMounts:
          bookorbit:
            app:
              - path: /bookdrop
      # BookLore cover images for the guided migration (media root /imports/booklore-data).
      # Remove together with the booklore app once the migration is verified.
      imports:
        type: nfs
        server: nas.internal
        path: /mnt/tank/nfs/booklore/bookorbit-imports
        advancedMounts:
          bookorbit:
            app:
              - path: /imports
                readOnly: true
```

- [ ] **Step 5: Register the app and open booklore's MariaDB port**

In `kubernetes/apps/default/kustomization.yaml`, insert `  - ./bookorbit/ks.yaml` between `./booklore/ks.yaml` and `./cv-site/ks.yaml`.

In `kubernetes/apps/default/booklore/app/helmrelease.yaml`, change
```yaml
    service:
      app:
        controller: booklore
        ports:
          http:
            port: *port
```
to
```yaml
    service:
      app:
        controller: booklore
        ports:
          http:
            port: *port
          # Reachable as booklore.default:3306 by BookOrbit's "Import from Booklore"
          # wizard. Remove together with the app once the migration is verified.
          mariadb:
            port: 3306
```

- [ ] **Step 6: Validate structure with kustomize and kubeconform**

Run:
```bash
cd /Users/pasha/code/home-ops
kubectl kustomize kubernetes/apps/default/bookorbit/app > /dev/null && echo kustomize-ok
kubectl kustomize kubernetes/apps/default > /dev/null && echo parent-ok
kubectl kustomize kubernetes/apps/default/bookorbit/app | kubeconform -strict -ignore-missing-schemas -skip Gateway,HTTPRoute,Secret -schema-location default -schema-location 'https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -summary
kubectl kustomize kubernetes/apps/default/booklore/app | kubeconform -strict -ignore-missing-schemas -skip Gateway,HTTPRoute,Secret -schema-location default -schema-location 'https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -summary
for f in kubernetes/apps/default/bookorbit/ks.yaml kubernetes/apps/default/bookorbit/app/*.yaml; do sed -n '2p' "$f" | grep -q '^# yaml-language-server: \$schema=' || echo "schema line missing in $f"; url=$(sed -n '2p' "$f" | sed 's/.*\$schema=//'); code=$(curl -s -o /dev/null -w '%{http_code}' "$url"); echo "$code $f"; done
```
Expected: `kustomize-ok`, `parent-ok`, both kubeconform summaries with `Invalid: 0, Errors: 0`, and every schema URL returns `200` (schemastore answers `301` for the kustomization schema, which is fine).

- [ ] **Step 7: Render the chart and check the rendered objects**

Run:
```bash
cd /Users/pasha/code/home-ops
SCRATCH=/private/tmp/claude-501/-Users-pasha-code-home-ops/6b879a6d-f57b-4d88-b334-11009dbcff48/scratchpad
yq '.spec.values' kubernetes/apps/default/bookorbit/app/helmrelease.yaml \
  | sed -e 's/\${SECRET_DOMAIN}/example.test/g' -e 's/\${VOLSYNC_CLAIM:=\${APP}}/bookorbit/g' > "$SCRATCH/bookorbit-values.yaml"
# --api-versions: the chart falls back to HTTPRoute v1alpha2 without cluster capabilities, and the cluster only serves v1/v1beta1
helm template bookorbit "$SCRATCH/chart/app-template" -n default -f "$SCRATCH/bookorbit-values.yaml" --api-versions gateway.networking.k8s.io/v1/HTTPRoute > "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="HTTPRoute") | .apiVersion' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Deployment") | .spec.template.spec.initContainers[].name' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Deployment") | .spec.template.spec.initContainers[] | .name + " tmp=" + ([.volumeMounts[] | select(.mountPath=="/tmp")] | length | tostring)' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.name=="OIDC_ALLOW_LOCAL_ISSUERS" or .name=="BOOK_DOCK_PATH" or .name=="APP_URL") | .name + "=" + .value' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Deployment") | (.spec.template.spec.initContainers[], .spec.template.spec.containers[]) | .name + " envFrom=" + ([.envFrom[].secretRef.name] | join(","))' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].volumeMounts[] | .mountPath + " ro=" + (.readOnly // false | tostring)' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Deployment") | .spec.template.spec.containers[0].securityContext' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Deployment") | .spec.strategy.type' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="Service") | .spec.ports[].port' "$SCRATCH/bookorbit-rendered.yaml"
yq 'select(.kind=="HTTPRoute") | .spec.hostnames[]' "$SCRATCH/bookorbit-rendered.yaml"
yq '.spec.values' kubernetes/apps/default/booklore/app/helmrelease.yaml | sed -e 's/\${SECRET_DOMAIN}/example.test/g' -e 's/\${VOLSYNC_CLAIM:=\${APP}}/booklore/g' > "$SCRATCH/booklore-values.yaml"
helm template booklore "$SCRATCH/chart/app-template" -n default -f "$SCRATCH/booklore-values.yaml" | yq 'select(.kind=="Service") | .spec.ports[] | .name + ":" + (.port|tostring)'
```
Expected: HTTPRoute apiVersion `gateway.networking.k8s.io/v1`; init containers `01-init-db` and `02-init-extensions` in that order, each with `tmp=1` (the `/tmp` emptyDir is a globalMount, so psql in the init container has a writable HOME); envFrom `bookorbit-init-secret` for both init containers and `bookorbit-secret` for `app` only (the superuser password never reaches the web app); the three env values `OIDC_ALLOW_LOCAL_ISSUERS=true`, `BOOK_DOCK_PATH=/bookdrop`, `APP_URL=https://bookorbit.example.test`; mounts `/data ro=false`, `/tmp ro=false`, `/books ro=false`, `/bookdrop ro=false`, `/imports ro=true`; securityContext with `readOnlyRootFilesystem: true` and `drop: [ALL]`; strategy `Recreate`; service port `3000`; hostname `bookorbit.example.test`; booklore service ports `http:6060` and `mariadb:3306`.

- [ ] **Step 8: Server-side dry run against the live cluster**

Run:
```bash
export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig
SCRATCH=/private/tmp/claude-501/-Users-pasha-code-home-ops/6b879a6d-f57b-4d88-b334-11009dbcff48/scratchpad
kubectl apply --dry-run=server -n default -f "$SCRATCH/bookorbit-rendered.yaml"
kubectl kustomize kubernetes/apps/default/bookorbit/app | yq 'select(.kind!="HelmRelease")' | sed -e 's/\${APP}/bookorbit/g' | kubectl apply --dry-run=server -n default -f -
flux build kustomization bookorbit --path ./kubernetes/apps/default/bookorbit/app --kustomization-file ./kubernetes/apps/default/bookorbit/ks.yaml --dry-run | yq '.kind + "/" + .metadata.name' | sort
```
Expected: every object reports `created (server dry run)` or `configured (server dry run)` with no errors; the flux build lists `ExternalSecret/bookorbit-config`, `ExternalSecret/bookorbit-init`, `ExternalSecret/bookorbit-volsync`, `HelmRelease/bookorbit`, `OCIRepository/bookorbit`, `PersistentVolumeClaim/bookorbit`, `ReplicationDestination/bookorbit-dst`, `ReplicationSource/bookorbit`.

- [ ] **Step 9: Prove the extension script is idempotent (Review Focus 1)**

The leftover empty `booklore` database on the shared cluster is the test bed; it is dropped in Task 9 anyway. Run the init-container SQL twice as the superuser through the CNPG primary pod:
```bash
export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig
PRIMARY=$(kubectl -n postgresql-system get cluster postgres -o jsonpath='{.status.currentPrimary}')
for i in 1 2; do
  echo "--- run $i"
  kubectl -n postgresql-system exec -i "$PRIMARY" -c postgres -- psql -v ON_ERROR_STOP=1 -U postgres -d booklore <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";
CREATE EXTENSION IF NOT EXISTS "vector";
ALTER EXTENSION "uuid-ossp" UPDATE;
ALTER EXTENSION "pg_trgm" UPDATE;
ALTER EXTENSION "unaccent" UPDATE;
ALTER EXTENSION "vector" UPDATE;
SELECT extname, extversion FROM pg_extension WHERE extname IN ('uuid-ossp', 'pg_trgm', 'unaccent', 'vector');
SQL
  echo "exit=$?"
done
```
Expected: both runs print the four-row table (without `-i` kubectl passes no stdin, psql runs nothing and still exits 0, so an empty run is a failed test); the second run prints only `NOTICE: ... already exists` / `already installed` lines and the same four-row table (`vector | 0.8.1`, `pg_trgm | 1.6`, `unaccent | 1.1`, `uuid-ossp | 1.1`).

- [ ] **Step 10: Lint and show the diff for the user**

Run:
```bash
cd /Users/pasha/code/home-ops
yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable, comments: disable, truthy: disable, braces: {max-spaces-inside: 1}}}' kubernetes/apps/default/bookorbit kubernetes/apps/default/booklore kubernetes/apps/default/kustomization.yaml
git status --short
git diff
```
Expected: yamllint prints nothing; status shows the five new files, two modified files, and the spec/plan docs. Do not commit; the user commits after Task 4.

---

### Task 4: Migration runbook and docs index

**Files:**
- Create: `docs/BOOKORBIT_MIGRATION.md`
- Modify: `CLAUDE.md` (Documentation References list, after the Observability Migration line)

**Interfaces:**
- Consumes: resource names from Task 3 (`bookorbit-secret`, Service `booklore` port 3306, mount `/imports`).
- Produces: the runbook Tasks 5 to 9 follow.

- [ ] **Step 1: Write `docs/BOOKORBIT_MIGRATION.md`**

```markdown
# BookLore -> BookOrbit migration

Status: **IN PROGRESS** (started 2026-10-15). Design:
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

## What is in Git

- `kubernetes/apps/default/bookorbit/` - app-template HelmRelease, ExternalSecret,
  Volsync-backed 10Gi PVC at `/data`, NFS mounts `/books` (library), `/bookdrop`
  (Book Dock drop folder = the old BookLore bookdrop share) and `/imports`
  (read-only, migration-only).
- Two init containers: `01-init-db` (onedr0p/postgres-init, role + database) and
  `02-init-extensions` (superuser `CREATE EXTENSION` for `uuid-ossp`, `pg_trgm`,
  `unaccent`, `vector`; pgvector is not a trusted extension, so the app user
  cannot create it). They read `bookorbit-init-secret`, which holds the shared
  CNPG superuser password; the app container reads only `bookorbit-secret`.
- `OIDC_ALLOW_LOCAL_ISSUERS=true`: `sso.<domain>` resolves to envoy-internal's LAN
  address from inside the cluster and BookOrbit's production SSRF guard would
  otherwise reject Authentik's discovery document.
- `booklore` Service exposes port 3306 (`booklore.default:3306`) for the wizard.

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
   Expected file count: 146 (as of 2026-10-14).

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
     `openid profile email`, subject mode same as booklore.
   - Applications > Create: name `BookOrbit`, slug `bookorbit`, provider `bookorbit`.
     Issuer becomes `https://sso.<domain>/application/o/bookorbit/`.
   - BookOrbit Settings > Authentication > OIDC: display name `Authentik`, issuer
     URL as above, client id and client secret from the provider, scopes
     `openid profile email`, claim mapping username `preferred_username`,
     name `name`, email `email`, auto-provision enabled, local login kept enabled.
7. pasha and valia each log in once via "Sign in with Authentik" so their accounts
   exist with the right usernames and emails. Promote `pasha` to admin.
8. Settings > Libraries > create one library on `/books`, scan. Expect 270 books.
   Leave file renaming and metadata write-back off until BookLore is gone.
   Settings > Book Dock: the 22 epubs from the NAS `incoming` share should be
   listed; leave them for triage after the migration.

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
    `https://bookorbit.<domain>/opds` (credentials are not migrated).

## Verification gate (all must pass before retirement)

- [ ] Dry run matched all 270 books; unresolved rows explained before the run.
- [ ] pasha's reading progress present on the 7 books that had it in BookLore.
- [ ] All 9 shelves arrived as collections under the right owners (admin 4,
      pasha 4, valia 1); 5 magic shelves recreated.
- [ ] Covers, including custom-uploaded ones, show on a spot check.
- [ ] pasha and valia log in through Authentik; admin logs in locally.
- [ ] OPDS feed works from the reader with the new password.
- [ ] `kubectl -n default get replicationsource bookorbit` shows a completed
      sync; `kubectl -n postgresql-system get cluster postgres -o jsonpath='{.status.lastSuccessfulArchiveTime}'`
      is later than the migration run.

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
```

- [ ] **Step 2: Add the runbook to the CLAUDE.md documentation index**

In `CLAUDE.md`, after the line
```
- **Observability Migration**: `docs/OBSERVABILITY_MIGRATION_LOKI_THANOS_90D.md`
```
add
```
- **BookLore to BookOrbit migration**: `docs/BOOKORBIT_MIGRATION.md`
```

- [ ] **Step 3: Check the runbook renders and its commands reference real things**

Run:
```bash
cd /Users/pasha/code/home-ops
grep -n "booklore default\|default booklore" docs/BOOKORBIT_MIGRATION.md
sed -n '1,12p' scripts/trigger-volsync-backup.sh | grep -n "APP_NAME=\|NAMESPACE="
grep -n "BOOKORBIT_MIGRATION" CLAUDE.md
```
Expected: the runbook calls the script with `booklore default` (app first, namespace second, matching the script's positional arguments), and CLAUDE.md has the new index line.

- [ ] **Step 4: Hand the diff to the user for commit**

Show `git status --short` and ask the user to review and commit the branch (for example `feat(bookorbit): deploy BookOrbit alongside BookLore for the guided migration`). Do not run `git commit` or `git push` yourself.

---

### Task 5: Pre-flight copies (runbook steps 1 to 3)

**Files:** none in Git. Run only after the user has reviewed Task 3/4 and before or right after the merge; BookLore must still be running.

**Interfaces:**
- Consumes: NAS folders from Task 2.
- Produces: `archive-2026-10/booklore-mariadb.sql`, `archive-2026-10/booklore-app-data.tar`, `bookorbit-imports/booklore-data/images/` (146 files).

- [ ] **Step 1: Volsync backup of the booklore PVC**

Run:
```bash
cd /Users/pasha/code/home-ops && export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig
./scripts/trigger-volsync-backup.sh booklore default
```
Expected: the script reports the backup completed.

- [ ] **Step 2: MariaDB dump and `/app/data` tarball to the NAS archive**

Run the two pipelines from runbook step 2 exactly as written, then the `ls -la` check.
Expected: `booklore-mariadb.sql` well under 100 MB (the 184 MB on the PVC is the InnoDB datadir with redo/undo space, a logical dump of 270 books is far smaller; step 4's table count is the real check), `booklore-app-data.tar` around 35 MB, `tar tf` lists `data/images/...` entries. Both `tar` (busybox) in the booklore `app` container and `mariadb-dump` in the `mariadb` container were confirmed present on 2026-10-15.

- [ ] **Step 3: Covers into the imports folder**

Run the pipeline from runbook step 3.
Expected: printed file count `146`.

- [ ] **Step 4: Confirm the dump is restorable (cheap sanity check)**

Run:
```bash
ssh root@nas.internal 'head -c 400 /mnt/tank/nfs/booklore/archive-2026-10/booklore-mariadb.sql; echo; grep -c "^CREATE TABLE" /mnt/tank/nfs/booklore/archive-2026-10/booklore-mariadb.sql'
```
Expected: a MariaDB dump header and a CREATE TABLE count of 72 (BookLore v2.4.0 has 72 tables in `information_schema.tables`, counted 2026-10-15).

---

### Task 6: Rollout verification (runbook step 4)

**Files:** none. Runs after the user merges the PR.

**Interfaces:**
- Consumes: everything from Task 3.
- Produces: a Ready `bookorbit` pod, Bound PVC, synced ExternalSecrets.

- [ ] **Step 1: Reconcile and watch Flux**

Run:
```bash
cd /Users/pasha/code/home-ops && export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig
flux reconcile kustomization flux-system --with-source
flux get ks bookorbit -n default
flux get hr bookorbit -n default
kubectl -n default get externalsecret bookorbit-config bookorbit-init bookorbit-volsync
```
Expected: Kustomization and HelmRelease `Ready=True`; all three ExternalSecrets `SecretSynced`.

- [ ] **Step 2: PVC and Volsync objects**

Run:
```bash
kubectl -n default get pvc bookorbit
kubectl -n default get replicationdestination bookorbit-dst -o jsonpath='{.status.latestImage}{"\n"}'
kubectl -n default get replicationsource bookorbit
```
Expected: PVC `Bound` 10Gi `ceph-rbd`; the ReplicationDestination has no latestImage yet (fresh repository), which is normal; the ReplicationSource exists with the next sync at :45.

- [ ] **Step 3: Init containers**

Run:
```bash
kubectl -n default get pod -l app.kubernetes.io/name=bookorbit
POD=$(kubectl -n default get pod -l app.kubernetes.io/name=bookorbit -o jsonpath='{.items[0].metadata.name}')
kubectl -n default logs "$POD" -c 01-init-db | tail -5
kubectl -n default logs "$POD" -c 02-init-extensions | tail -8
```
Expected: pod `1/1 Running`; init-db logs mention creating the role/database; init-extensions prints the four extension rows with `vector | 0.8.1`.

- [ ] **Step 4: Read-only root filesystem check (Review Focus 2)**

Run:
```bash
kubectl -n default logs "$POD" -c app | grep -i -E 'erofs|eacces|read-only file system|permission denied' || echo "no rootfs errors"
kubectl -n default logs "$POD" -c app | grep -i -E 'BookOrbit startup|listening|Nest application successfully started' | head -5
```
Expected: `no rootfs errors` and a startup line showing the server is listening. If `EROFS` appears, set `readOnlyRootFilesystem: false` on the `app` container with a comment naming the path that needed writing, re-validate per Task 3 steps 6 to 8, and ask the user to commit.

- [ ] **Step 5: Mounts and health**

Run:
```bash
kubectl -n default exec "$POD" -c app -- sh -c 'df -h /data /books /bookdrop /imports; ls /imports/booklore-data/images | head -3; touch /imports/x 2>&1 || echo "imports is read-only, as intended"'
kubectl -n default exec "$POD" -c app -- wget -q -O - http://127.0.0.1:3000/api/v1/health
HOST=$(kubectl -n default get httproute bookorbit -o jsonpath='{.spec.hostnames[0]}')
curl -s -o /dev/null -w '%{http_code}\n' "https://$HOST/api/v1/health"
```
Expected: four mounts present, three image directories listed, the read-only message, a JSON health body, and HTTP `200` through the gateway.

- [ ] **Step 6: Book Dock on NFS (Review Focus 3)**

After the first login (Task 7 step 1), open Book Dock in the UI and confirm the 22 files are listed. Run:
```bash
kubectl -n default logs "$POD" -c app | grep -i -E 'book.?dock' | grep -i -E 'eacces|eperm|permission' || echo "no book dock permission errors"
```
Expected: `no book dock permission errors`.

---

### Task 7: First login, Authentik, SSO users, library scan (runbook steps 5 to 8)

**Files:** none.

**Interfaces:**
- Consumes: `SETUP_BOOTSTRAP_TOKEN` from the `bookorbit` 1Password item.
- Secret handling in the browser: Claude's browser tools can only type a value by putting it in a tool-call argument, which lands in this session's transcript. So Claude fills every non-secret field and then **the user pastes the secret values** (admin password, bootstrap token, OIDC client secret, later the BookLore database password) from 1Password into the fields Claude points at, and submits. Nothing secret is ever printed in chat or stored in a file. If the user prefers Claude to type a secret, that is their call to make per field, knowing it then appears in the tool-call log.
- Produces: BookOrbit accounts `admin`, `pasha` (admin), `valia`; Authentik provider+application `bookorbit`; one BookOrbit library on `/books` with 270 books.

- [ ] **Step 1: Create the local admin on the setup page**

First store a generated admin password in 1Password (never echoed):
```bash
op item edit bookorbit --vault HomeInfra "ADMIN_PASSWORD[concealed]=$(openssl rand -base64 18)" --format json | python3 -I -c "import sys,json; print(sorted(f['label'] for f in json.load(sys.stdin)['fields'] if f.get('label')))"
```
Expected: the label list now includes `ADMIN_PASSWORD`.

Then in the user's Chrome session (claude-in-chrome tools, loaded per the browser skill) open `https://bookorbit.<domain>`. Claude fills username `admin` and email `booklore@<domain>`; the user pastes the password (1Password `bookorbit` > `ADMIN_PASSWORD`) and the bootstrap token (`SETUP_BOOTSTRAP_TOKEN`) and submits.
Expected: logged in as `admin`, Settings visible.

- [ ] **Step 2: Create the Authentik provider and application**

Generate the client secret locally and store it first, so it is typed into Authentik rather than read back from the page:
```bash
op item edit bookorbit --vault HomeInfra "OIDC_CLIENT_SECRET[concealed]=$(openssl rand -hex 32)" --format json | python3 -I -c "import sys,json; print('OIDC_CLIENT_SECRET' in {f.get('label') for f in json.load(sys.stdin)['fields']})"
```
Expected: `True`.

In Authentik admin (`https://sso.<domain>/if/admin/`), follow runbook step 6 exactly. Copy the booklore provider's signing key and subject mode choices. In the provider form, the user replaces the generated Client Secret by pasting 1Password `bookorbit` > `OIDC_CLIENT_SECRET`. After saving, record the client id, which is not secret, with `op item edit bookorbit --vault HomeInfra "OIDC_CLIENT_ID[text]=<client id shown by Authentik>"`.
Expected: provider `bookorbit` listed with redirect URI `https://bookorbit.<domain>/oauth2-callback`; application `BookOrbit` with slug `bookorbit`; `curl -s https://sso.<domain>/application/o/bookorbit/.well-known/openid-configuration | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["issuer"])'` prints the issuer.

- [ ] **Step 3: Configure OIDC in BookOrbit**

Settings > Authentication > OIDC: Claude fills every field per runbook step 6 except the client secret, which the user pastes from 1Password. Save, then use the provider's "Test" action if present.
Expected: provider saved and enabled; the login page shows "Sign in with Authentik".

- [ ] **Step 4: SSO logins for pasha and valia, promote pasha**

The user logs in as pasha via Authentik (their own session); valia logs in once or the user does it from valia's Authentik account. Then as `admin`, Settings > Users: confirm three users with the BookLore emails; set `pasha` to admin.
Expected: Users list shows `admin`, `pasha` (admin), `valia`.

- [ ] **Step 5: SSO round trip confirmed (Review Focus 5)**

Run:
```bash
POD=$(kubectl -n default get pod -l app.kubernetes.io/name=bookorbit -o jsonpath='{.items[0].metadata.name}')
kubectl -n default logs "$POD" -c app | grep -i oidc | grep -i -E 'private|local|blocked|ssrf' || echo "no OIDC guard rejections"
```
Expected: `no OIDC guard rejections` and pasha's login succeeded in step 4.

- [ ] **Step 6: Library and scan**

Settings > Libraries > Create: name `Library`, folder `/books`, watch folders on, file renaming off, metadata write-back off. Scan.
Expected: 270 books after the scan completes (compare `kubectl -n default logs "$POD" -c app | grep -i scan | tail -5`).

---

### Task 8: Guided migration, magic shelves, OPDS, verification gate (runbook steps 9 to 14)

**Files:** none.

**Interfaces:**
- Consumes: booklore Service port 3306 (Task 3), covers at `/imports/booklore-data` (Task 5), accounts and library (Task 7).
- Produces: migrated metadata, progress, shelves, covers; a passed verification gate.

- [ ] **Step 1: MariaDB reachability (Review Focus 4)**

Run:
```bash
export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig
kubectl -n default get svc booklore -o jsonpath='{range .spec.ports[*]}{.name}:{.port}{"\n"}{end}'
kubectl -n default exec deploy/bookorbit -c app -- sh -c 'nc -z -w3 booklore.default 3306 && echo open'
```
Expected: `http:6060`, `mariadb:3306`, and `open` (the BookOrbit image is Alpine based, so busybox `nc` and `wget` exist; Dockerfile checked 2026-10-15).

- [ ] **Step 2: Wizard source and validation**

In the UI follow runbook step 10. Claude fills host, port, database, user and media root; the user pastes the password (1Password `booklore` > `DATABASE_PASSWORD`).
Expected: Validated badge; the warnings panel does not mention `mediaRootPath`; the detected BookLore version shows `v2.4.0`.

- [ ] **Step 3: Mappings and dry run**

Runbook step 11, then Dry run.
Expected: matched 270, unresolved 0 (or each unresolved row explained to the user before continuing), duplicates resolved.

- [ ] **Step 4: Run and report**

Run migration; wait for `completed`. Open the report; export JSON; save it:
```bash
# after downloading the report in the browser to ~/Downloads/bookorbit-migration-report.json
scp ~/Downloads/bookorbit-migration-report.json root@nas.internal:/mnt/tank/nfs/booklore/archive-2026-10/
```
Expected: report shows books overlaid, covers imported, user data imported for pasha (7 progress rows) and shelves for all three users.

- [ ] **Step 5: Magic shelves and OPDS**

Runbook steps 13 and 14. The five magic shelf names come from BookLore:
```bash
kubectl -n default exec deploy/booklore -c mariadb -- sh -c 'mariadb -ubooklore -p"$MYSQL_PASSWORD" booklore -e "select id, name, filter_json from magic_shelf"' | sed 's/\t/ | /g'
```
Expected: five smart collections exist in BookOrbit with equivalent filters; the OPDS feed opens in the reader.

- [ ] **Step 6: Verification gate**

Walk the gate checklist in the runbook with the user. For the backup items run:
```bash
kubectl -n default get replicationsource bookorbit -o jsonpath='{.status.lastSyncTime} {.status.latestMoverStatus.result}{"\n"}'
kubectl -n postgresql-system get cluster postgres -o jsonpath='{.status.lastSuccessfulArchiveTime}{"\n"}'
```
Expected: a sync time after the migration with result `Successful`, and an archive time after the migration run. Every box ticked before Task 9 starts.

---

### Task 9: Retirement PR and cleanup (runbook steps 15 to 19)

**Files:**
- Delete: `kubernetes/apps/default/booklore/` (whole directory)
- Modify: `kubernetes/apps/default/kustomization.yaml` (remove `./booklore/ks.yaml`)
- Modify: `kubernetes/apps/default/bookorbit/app/helmrelease.yaml` (remove the `imports` persistence block)
- Modify: `docs/BOOKORBIT_MIGRATION.md` (status line)
- Modify: `CLAUDE.md` (the `default/` directory comment lists example apps; no change needed unless booklore is named there)

**Interfaces:**
- Consumes: passed verification gate (Task 8).
- Produces: a cluster with no booklore objects, no `/imports` mount, no leftover `booklore` database or role.

- [ ] **Step 1: Git changes**

Run:
```bash
cd /Users/pasha/code/home-ops
git rm -r kubernetes/apps/default/booklore
sed -i '' '/  - .\/booklore\/ks.yaml/d' kubernetes/apps/default/kustomization.yaml
```
Then delete the `imports:` block (from the comment `# BookLore cover images for the guided migration` through `readOnly: true`) in `kubernetes/apps/default/bookorbit/app/helmrelease.yaml`, and change the runbook status line to `Status: **DONE <date>** (deploy <hash>, retirement <hash>)`.

- [ ] **Step 2: Validate**

Run Task 3 steps 6 to 8 again for `bookorbit` (the booklore commands are dropped).
Expected: same results minus the `/imports` mount; `kubectl kustomize kubernetes/apps/default` no longer lists booklore.

- [ ] **Step 3: User commits and merges; watch the prune**

After the user merges:
```bash
export KUBECONFIG=/Users/pasha/code/home-ops/kubeconfig
flux reconcile kustomization flux-system --with-source
kubectl -n default get all,pvc,replicationsource,replicationdestination,externalsecret,httproute -l app.kubernetes.io/name=booklore
kubectl -n default get pod -l app.kubernetes.io/name=bookorbit
kubectl -n default exec deploy/bookorbit -c app -- sh -c 'ls /imports 2>&1 | head -1'
```
Expected: `No resources found` for booklore; the bookorbit pod restarted once (Recreate) and is Ready; `/imports` no longer exists.

- [ ] **Step 4: Shared Postgres cleanup**

Run:
```bash
PRIMARY=$(kubectl -n postgresql-system get cluster postgres -o jsonpath='{.status.currentPrimary}')
kubectl -n postgresql-system exec "$PRIMARY" -c postgres -- psql -U postgres -tAc "select count(*) from pg_stat_activity where datname='booklore'"
kubectl -n postgresql-system exec "$PRIMARY" -c postgres -- psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'DROP DATABASE booklore;' -c 'DROP OWNED BY booklore;' -c 'DROP ROLE booklore;'
kubectl -n postgresql-system exec "$PRIMARY" -c postgres -- psql -U postgres -tAc "select datname from pg_database where datname like 'book%'; select rolname from pg_roles where rolname like 'book%'"
```
Expected: `0` active connections, both DROPs succeed, the final query lists only `bookorbit` for both.

- [ ] **Step 5: NAS, 1Password, Authentik**

Run:
```bash
ssh root@nas.internal 'rm -rf /mnt/tank/nfs/booklore/bookorbit-imports && ls -la /mnt/tank/nfs/booklore/'
op item delete booklore --vault HomeInfra --archive
```
In Authentik admin delete application `BookLore` and provider `booklore`.
Expected: NAS listing shows `archive-2026-10`, `incoming`, `library`; `op item get booklore --vault HomeInfra` reports the item is archived; Authentik no longer lists booklore.

- [ ] **Step 6: Close out**

Update the memory index with a one-line pointer to the runbook (new memory file `bookorbit-migration-2026-10.md`: what moved, the OIDC flag gotcha, the extension bootstrap, the archive location). Report completion to the user with the two commit hashes.
