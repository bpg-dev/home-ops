# home-ops

GitOps-managed homelab Kubernetes cluster built on Talos Linux and Flux CD.

## Tooling

This repo uses [mise](https://mise.jdx.dev/) to pin the CLI toolchain (kubectl, flux, talosctl, sops, kubeconform, etc.).

```sh
mise trust
mise install
```

## Common workflows

### Render and validate generated config

This repo renders Kubernetes + Talos configuration from `cluster.yaml` + `nodes.yaml` using `makejinja`, then validates output.

```sh
task init        # one-time for a fresh repo clone
task configure   # re-render + (re-)encrypt *.sops.* + validate
```

### Bootstrap a fresh cluster

```sh
task bootstrap:talos
task bootstrap:apps
```

### Day-2 operations

```sh
task reconcile
flux get all -A
flux logs --all-namespaces --follow
kubectl get pods -A
```

### Talos operations

```sh
task talos:generate-config
task talos:apply-node IP=<node-ip> MODE=auto
task talos:upgrade-node IP=<node-ip>
task talos:upgrade-k8s
task talos:reset
```

## Repository layout

```text
.
├── bootstrap/        # initial cluster bootstrap (helmfile, sops)
├── docs/             # runbooks and operational notes
├── kubernetes/       # Flux + apps (Kustomize/HelmRelease/HTTPRoute/etc.)
├── scripts/          # operational scripts (backups, restores, utilities)
├── talos/            # Talos config inputs + patches (generated configs under talos/clusterconfig/)
├── cluster.yaml      # cluster inputs (rendered by makejinja)
├── nodes.yaml        # node inventory (rendered by makejinja)
└── Taskfile.yaml     # repo automation entrypoints
```

## Conventions (high-level)

- GitOps first: changes land via manifests in `kubernetes/` and get applied by Flux.
- Secrets: use SOPS (`*.sops.*`) and/or External Secrets Operator; don’t commit plaintext secrets.
- Routing: use Gateway API `HTTPRoute` (no Ingress).

More detailed guidance lives in:

- `AGENTS.md` (ops commands + architecture notes)
- `docs/` (runbooks, especially restore procedures)
