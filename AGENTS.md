# AGENTS.md

This file provides guidance to any coding agent (Claude, Cursor, Copilot, etc.) when working with code in this repository.

## Repository Overview

This is a home-ops GitOps repository managing a production Kubernetes cluster using Talos Linux, Flux CD, and declarative configuration. The cluster runs on 3 control plane nodes with a high-availability setup using a shared VIP (Virtual IP).

## Technology Stack

- **Cluster OS**: Talos Linux (immutable, API-driven)
- **GitOps**: Flux CD v2 with Flux Operator
- **CNI**: Cilium (with BGP disabled, no LoadBalancer)
- **Ingress**: Envoy Gateway with HTTPRoutes
- **DNS**: CoreDNS (cluster), k8s-gateway (internal), cloudflare-dns (external)
- **Certificates**: cert-manager with Let's Encrypt
- **External Access**: Cloudflare Tunnel (cloudflared)
- **Secrets**: SOPS with Age encryption + External Secrets Operator (1Password)
- **Storage**: OpenEBS, Rook-Ceph (external), NFS CSI Driver, VolumeSnapshots
- **Databases**: CloudNative-PG (PostgreSQL operator) with Barman Cloud backup
- **Backup**: Volsync with Kopia backend (S3-compatible storage)
- **Monitoring**: Kube-Prometheus-Stack, Grafana, Victoria Logs, Fluent-bit, Gatus
- **Configuration Reloading**: Reloader (Stakater)
- **Container Registry Mirror**: Spegel (P2P distribution)

## Directory Structure

```text
.
├── bootstrap/                    # Initial cluster bootstrap with Helmfile
├── docs/                         # Operational documentation and runbooks
├── kubernetes/
│   ├── apps/                     # Application deployments organized by namespace
│   │   ├── cert-manager/        # Certificate management
│   │   ├── default/             # User applications (actual-budget, paperless-ngx, etc.)
│   │   ├── dragonfly-system/    # Dragonfly operator (in-memory datastore)
│   │   ├── flux-system/         # Flux CD components
│   │   ├── kube-system/         # Core cluster components (cilium, coredns, etc.)
│   │   ├── network/             # Networking (envoy-gateway, cloudflare, k8s-gateway)
│   │   ├── observability/       # Monitoring stack (victoria-logs, fluent-bit)
│   │   ├── postgresql-system/   # PostgreSQL operator and clusters
│   │   ├── rook-ceph-external/  # External Ceph storage
│   │   └── security/            # Security services (authentik)
│   ├── components/              # Reusable Kustomize components
│   └── flux/                    # Flux configuration and root Kustomization
├── scripts/                      # Operational bash scripts
├── talos/                        # Talos Linux configuration
│   ├── clusterconfig/           # Generated machine configs (gitignored)
│   ├── patches/                 # Machine config patches
│   ├── talconfig.yaml           # Talhelper configuration (main source)
│   └── talsecret.sops.yaml      # Encrypted cluster secrets
├── .sops.yaml                    # SOPS encryption rules
├── kubeconfig                    # Cluster access config (gitignored)
├── age.key                       # SOPS encryption key (gitignored)
└── Taskfile.yaml                 # Task automation definitions
```

### Application Structure

Each application follows this standard pattern:

```text
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml                      # Flux Kustomization (targets namespace)
└── app/
    ├── kustomization.yaml       # Lists resources alphabetically
    ├── helmrelease.yaml         # Main deployment (Helm chart)
    ├── ocirepository.yaml       # OCI registry source (if using OCI charts)
    ├── externalsecret.yaml      # External Secrets Operator config
    ├── pvc.yaml                 # Persistent Volume Claim
    ├── httproute.yaml           # HTTPRoute for ingress
    ├── servicemonitor.yaml      # Prometheus metrics scraping
    └── config/                  # ConfigMap files
```

## Essential Commands

### Cluster Access

```bash
export KUBECONFIG=./kubeconfig
export SOPS_AGE_KEY_FILE=./age.key
export TALOSCONFIG=./talos/clusterconfig/talosconfig
```

### Task Automation

```bash
task --list                          # List all available tasks
task reconcile                       # Force Flux to sync from Git
task bootstrap:talos                 # Bootstrap Talos cluster
task bootstrap:apps                  # Bootstrap apps into cluster
task talos:generate-config           # Regenerate Talos configs
task talos:apply-node IP=X.X.X.X MODE=auto  # Apply config to node
task talos:upgrade-node IP=X.X.X.X   # Upgrade Talos version
task talos:upgrade-k8s               # Upgrade Kubernetes version
```

### Flux Operations

```bash
flux reconcile kustomization flux-system --with-source
flux reconcile hr <name> -n <namespace> --force
flux reconcile hr <name> -n <namespace> --reset      # Reset retry count
flux get all -A
flux logs --all-namespaces --follow
```

### Kubernetes Operations

```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --follow
kubectl get events -n <namespace> --sort-by='.metadata.creationTimestamp'
kubectl apply --dry-run=server -f <file>
kubectl kustomize <directory>
```

### Secret Management

```bash
sops -e secret.yaml > secret.sops.yaml
sops -d secret.sops.yaml
sops secret.sops.yaml  # Edit in-place
```

### Talos Operations

```bash
talosctl health
talosctl dashboard
talosctl get disks -n <ip>
talosctl logs -n <ip> -f
```

### Infrastructure SSH Access

```bash
# Proxmox VE Cluster (3 nodes)
ssh root@pve1.internal
ssh root@pve2.internal
ssh root@pve3.internal

# TrueNAS Scale (NFS storage)
ssh root@nas.internal
```

Note: Actual IPs and hostnames are defined in cluster configuration files.

### Backup and Restore

```bash
export APP_NAME=<workload-name>
./scripts/restore-volsync-populator.sh
./scripts/restore-volsync-populator.sh --timestamp 2025-11-22T21:12:06Z
./scripts/trigger-volsync-backup.sh <namespace> <app-name>
./scripts/verify-volsync-snapshots.sh
```

## Critical Rules

These rules prevent cluster failures, data corruption, or GitOps drift.

### GitOps Enforcement

- **NEVER run `kubectl apply/create/patch/delete`** - All changes via Git manifests only
- **NEVER run `git commit/push`** - Wait for explicit user approval
- **NEVER use `kubectl port-forward`** - Use kubectl exec or temporary HTTPRoute
- **ALWAYS validate before committing** - YAML syntax, dry-run, helm template

### Pattern Discovery

- **NEVER make assumptions** - Always check existing applications first
- **ALWAYS examine similar apps** - Search for apps with similar requirements and follow their patterns
- **Pattern sources (priority order)**:
  1. Existing applications in `kubernetes/apps/`
  2. Components in `kubernetes/components/`
  3. Reference repos: onedr0p/home-ops, bjw-s-labs/home-ops, buroa/k8s-gitops

### Storage Rules

- **RWO Deployments MUST use `strategy: Recreate`** - RollingUpdate causes Multi-Attach errors
- **RWO StatefulSets use `RollingUpdate`** - StatefulSets handle RWO correctly
- **NEVER use Recreate with StatefulSets** - Only Deployments support Recreate

### Resource Rules

- **NEVER specify `metadata.namespace` in app resources** - Breaks inheritance from parent kustomization
- **NEVER use `latest` or non-semantic version tags** - Pin specific versions
- **NEVER share databases between applications** - Dedicated instances per app
- **NEVER create LoadBalancer services** without explicit discussion

### Secrets Rules

- **NEVER use raw Secret resources** - Use External Secrets Operator or SOPS
- **NEVER use raw ConfigMap resources** - Use `configMapGenerator` in kustomization.yaml
- **NEVER use `postBuild.substituteFrom` for secrets** - Timing race with ExternalSecrets
- **NEVER log or print secret values**

### Security Rules

- **ALWAYS use rootless containers** - Never run as root (UID 0)
- **Drop ALL capabilities** - Use `capabilities.drop: [ALL]`

## Architecture Details

### Network Architecture

- **Node Network**: Defined in `talos/talconfig.yaml`
- **Control Plane VIP**: Shared across 3 controllers (see `talos/talconfig.yaml`)
- **Pod CIDR**: Defined in cluster configuration
- **Service CIDR**: Defined in cluster configuration
- **API Server**: Uses the control plane VIP

### Infrastructure

- **Proxmox VE**: 3-node cluster hosting Talos VMs
- **TrueNAS Scale**: NFS storage server for volsync backups

### Storage Classes

- **openebs-hostpath**: Local path storage (RWO)
- **rook-ceph-block**: Ceph RBD block storage (RWO)
- **rook-ceph-filesystem**: CephFS shared storage (RWX)
- **nfs-client**: NFS shared storage (RWX)

### Flux Hierarchy

1. `flux-system` namespace (Flux Operator + Flux Instance)
2. Root Kustomization (`kubernetes/flux/cluster/ks.yaml`)
3. Application Kustomizations (`kubernetes/apps/*/ks.yaml`)

## Configuration Patterns

### Security Contexts

```yaml
# Container level
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]

# Pod level
securityContext:
  fsGroup: 1000
  fsGroupChangePolicy: OnRootMismatch
```

**Exception**: Containers using s6-overlay/gosu cannot use container-level security contexts.

### Health Probes

```yaml
# HTTP health check (use YAML anchors)
liveness: &probes
  enabled: true
  custom: true
  spec:
    httpGet:
      path: /health
      port: 8080
readiness: *probes

# TCP health check (databases)
liveness: &probes
  enabled: true
  custom: true
  spec:
    tcpSocket:
      port: 5432
readiness: *probes
```

### Secrets Management

Priority order for injection:

1. **ExternalSecret with `envFrom`** (recommended)
2. **ExternalSecret with `env.valueFrom`**
3. **HelmRelease `valuesFrom`**

### ConfigMaps

- Store config files in `config/` subdirectory
- Use `configMapGenerator` in kustomization.yaml
- Add annotation: `reloader.stakater.com/auto: "true"`
- Use `disableNameSuffixHash: true` only for cross-resource dependencies

### HTTPRoutes

```yaml
spec:
  parentRefs:
    - name: envoy-internal  # or envoy-external
      namespace: network
  hostnames:
    - "app.${SECRET_DOMAIN}"
  rules:
    - backendRefs:
        - name: app-service-full-name
          port: 8080
```

### Deployment Strategies

```yaml
# Deployments with RWO volumes
spec:
  strategy:
    type: Recreate  # REQUIRED for RWO

# StatefulSets with RWO volumes
spec:
  updateStrategy:
    type: RollingUpdate  # StatefulSets handle RWO correctly
```

### YAML Standards

- Use 2-space indentation
- Start with `---` document separator
- Add yaml-language-server schema directive:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
```

Schema sources (preference order):

1. `kubernetes-schemas.pages.dev`
2. `json.schemastore.org`
3. `raw.githubusercontent.com/datreeio/CRDs-catalog`

### Resource Naming

- Resources in alphabetical order in kustomization.yaml
- Internal hostnames: `service.namespace` format (e.g., `postgres.postgresql-system`)
- Avoid full FQDN with `.svc.cluster.local` unless required

### Domain Hygiene

- Use `${SECRET_DOMAIN}` placeholders for domains in Git
- Flux `postBuild.substitutions` renders at apply time

## Workflow

### Change Workflow

1. **Understand**: Read existing configuration and patterns
2. **Change**: Make minimal, focused changes
3. **Validate**: Run validation checks
   - `kubectl --dry-run=server`
   - `helm template`
   - `kubectl kustomize`
4. **Lint**: Fix all linter errors
5. **Review**: Check against existing applications
6. **User commits**: Wait for explicit approval
7. **Monitor**: Watch Flux reconciliation
8. **Verify**: Confirm deployment health

### Adding a New Application

1. Create namespace in `kubernetes/apps/{namespace}/`
2. Create `kubernetes/apps/{namespace}/{app-name}/app/`
3. Create `ks.yaml` with `spec.targetNamespace`
4. Create `kustomization.yaml` (resources in alphabetical order)
5. Create `pvc.yaml` if persistence needed
6. Create `externalsecret.yaml` for secrets
7. Create `helmrelease.yaml` with probes, security contexts, strategy
8. Create `httproute.yaml` if external access needed
9. Add `ks.yaml` to parent namespace kustomization.yaml
10. Validate before commit

## Troubleshooting

### Debugging Steps

1. Check Flux status: `flux get ks -A` and `flux get hr -A`
2. Check pod status: `kubectl get pods -n <namespace>`
3. Check logs: `kubectl logs <pod> -n <namespace> --follow`
4. Check events: `kubectl get events -n <namespace> --sort-by='.metadata.creationTimestamp'`
5. Describe resources: `kubectl describe <resource> <name> -n <namespace>`
6. Verify ExternalSecret status
7. Check `dependsOn` resources are ready

### Common Issues

**Flux stuck:**

```bash
flux reconcile kustomization flux-system --with-source
flux suspend ks <name> -n <namespace>
flux resume ks <name> -n <namespace>
```

**HelmRelease failures:**

```bash
flux reconcile hr <name> -n <namespace> --reset
```

**Multi-Attach volume errors:**

- Verify RWO Deployments use `strategy: Recreate`
- Ensure old pod terminated before new starts

**Secret decryption failures:**

- Verify `SOPS_AGE_KEY_FILE` is set
- Check `.sops.yaml` rules match file path

## Backup Strategy

### Volsync (Application Data)

- Automated scheduled backups via ReplicationSource
- Volume Populator for point-in-time restores
- Snapshots stored in S3-compatible storage
- Recovery time: 10-20 minutes

### PostgreSQL (Barman Cloud)

- Continuous WAL archiving to S3
- Point-in-time recovery (PITR) capability
- Automated base backups on schedule

## Documentation References

- **Emergency Procedures**: `docs/EMERGENCY_RESTORE_RUNBOOK.md`
- **Backup Restoration**: `docs/VOLSYNC_POPULATOR_RESTORE.md`
- **Storage Setup**: `docs/TRUENAS_NFS_SETUP.md`
- **Talos Patches**: `talos/patches/README.md`

## Key Notes

- 3-node HA control plane with shared VIP (all nodes run workloads)
- Cilium CNI with no LoadBalancer services
- Split DNS: internal via k8s-gateway, external via Cloudflare
- Security-first: rootless containers, minimal privileges
- Renovate handles automated dependency updates
