# Observability Migration Plan: Loki (Logs) + Thanos (Metrics) with 90d Retention

This document tracks the execution of migrating:

- **Logs**: VictoriaLogs → **Loki** (90 days retention), with **Loki ruler → Alertmanager**
- **Metrics**: Prometheus local hot window **14 days** + **Thanos on Garage S3** for **90 days retention**
- **Grafana**: seamless metrics↔logs experience (Explore, dashboards, alerts) using consistent labels

---

## Background / Current State (Repo-Observed)

- **Prometheus**: `kube-prometheus-stack` sets `prometheus.prometheusSpec.retention: 14d` and `retentionSize: 50GB` on a Ceph RBD PVC.
- **Logs**: `victoria-logs-single` is deployed with `retentionPeriod: 14d` on a Ceph RBD PVC.
- **Log collection**: `fluent-bit` tails Kubernetes container logs and also receives Proxmox syslog on UDP/5514 (via NodePort).
- **Grafana**: managed by `grafana-operator`; datasources are provisioned via `GrafanaDatasource` CRs (currently Prometheus + Alertmanager).

---

## Target Architecture

### Metrics (90d) — Option A (Selected)

- **Hot metrics (14d)**: Prometheus (existing) remains the primary scrape/eval engine.
- **Long-range metrics (90d)**: Thanos stores and serves historical blocks from object storage.

Components:

- **Prometheus + Thanos Sidecar**: uploads TSDB blocks to object storage.
- **Thanos Query**: Grafana queries this for long-range metrics.
- **Thanos Store Gateway**: reads blocks from object storage.
- **Thanos Compactor**: compacts blocks and enforces **90d retention**.

### Logs (90d)

- **Ingestion**: Fluent Bit outputs to Loki.
- **Storage**: Loki uses Garage S3 for durability and retention scalability.
- **Retention**: enforced by Loki compactor with retention deletes enabled (**90d**).
- **Alerting**: Loki ruler evaluates log alerts and sends notifications to existing Alertmanager.

### Grafana “Seamless” Metrics↔Logs

To correlate metrics and logs reliably:

- Standardize these Loki labels for Kubernetes logs:
  - `cluster`, `namespace`, `pod`, `container`, `app`
- Ensure dashboard variables and Explore queries use the same labels.
- Configure Grafana datasource “derived fields” / links so users can jump from a log line → relevant Prometheus/Thanos metrics.

### Grafana Datasources: Prometheus vs Thanos (What to Use Where)

Important distinction: **applications never “use a Grafana datasource”**. Applications only **expose `/metrics`**; Prometheus scrapes those metrics
and (in our setup) the **Thanos sidecar** uploads TSDB blocks to object storage for long-range querying.

We keep **two** Prometheus-compatible datasources in Grafana:

- **`prometheus`** (default): `http://prometheus-operated.observability.svc.cluster.local:9090`
- **`thanos`** (long-range): `http://thanos-thanos-query.observability.svc.cluster.local:9090`

#### Rule of thumb (dashboards)

- **Use `prometheus`** for “live”/fast dashboards:
  - high refresh rate (e.g., 5s–30s)
  - troubleshooting last minutes/hours
  - alert debugging / near-real-time signal
- **Use `thanos`** for long-range dashboards:
  - trends over days/weeks (especially > Prometheus retention window)
  - capacity planning and historical comparisons
  - any view that needs the full 90d history

You can query “recent” data via Thanos too, but it’s usually not worth switching everything globally because it can be slower/heavier.

#### GitOps pattern: keep dashboards flexible via datasource variables

Most upstream dashboards (Grafana.com) use a datasource **variable** like `DS_PROMETHEUS`.
Instead of manually editing dashboards in the Grafana UI, we bind that variable in Git using `GrafanaDashboard.spec.datasources`.

Example:

```yaml
spec:
  datasources:
    - datasourceName: thanos
      inputName: DS_PROMETHEUS
```

This makes the same JSON dashboard work with either `prometheus` or `thanos` by changing only the `GrafanaDashboard` CR.

#### Should we “change all dashboards to Thanos”?

No. Prefer:

- Dashboards intended for **long-range history** → bind `DS_PROMETHEUS` to **`thanos`**
- Dashboards intended for **live operations** → keep using **`prometheus`** (default), or explicitly bind to it if needed

#### House rule (for PR reviews)

- If a dashboard is primarily used for **operational/live** views (fast refresh, “what’s happening right now?”): default it to **`prometheus`**.
- If a dashboard is primarily used for **historical/trend** views (days/weeks, capacity, “how did this change over time?”): default it to **`thanos`**.

---

## Prerequisites

### Object Storage (Garage)

Create buckets:

- `thanos` (metrics blocks)
- `loki` (logs chunks/index)

Create distinct credentials (least privilege) and store in 1Password:

- `thanos`
- `loki`

Notes:

- Garage typically works best with **path-style** S3 access.
- Internal endpoint (from existing repo conventions):
  - `http://garage.storage:3900`

### Secrets (GitOps-compliant)

- Use **External Secrets Operator** only (no raw Secrets in Git).
- Create `ExternalSecret` resources to materialize:
  - `thanos-objstore` (contains `objstore.yaml`) in `observability`
  - `loki-secret` (contains `S3_*` env vars) in `observability`

---

## Execution Checklist (Phased)

Each phase is designed to be low risk and reversible (Git revert).

### Phase 1 — Deploy Thanos for Metrics 90d

#### 1.1 Update kube-prometheus-stack (Prometheus + sidecar)

- [x] Keep Prometheus hot retention at **14d** (already set).
- [x] Enable/configure **Thanos sidecar** to upload blocks to `s3://thanos`.
- [x] Ensure any required sidecar flags are set for object storage + endpoints.
- [x] Ensure ServiceMonitors/metrics for Thanos components are enabled (observability).

Artifacts (expected repo changes):

- [x] Update: `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml`
- [x] Add: `kubernetes/apps/observability/thanos/` (new app)

#### 1.2 Deploy core Thanos components

Minimum recommended:

- [x] `thanos-query`
- [x] `thanos-storegateway`
- [x] `thanos-compactor` (retention **90d**)

Optional (not required initially):

- [ ] `thanos-ruler` (only if you want long-range rule evaluation)

#### 1.3 Add Grafana Thanos datasource

- [x] Add a `GrafanaDatasource` named `thanos` (type `prometheus` pointing to `thanos-query` service).
- [ ] Decide usage convention:
  - Recent (≤14d): Prometheus datasource
  - Long-range (>14d): Thanos datasource

Artifact:

- [x] Update: `kubernetes/apps/observability/grafana/instance/grafanadatasource.yaml`

#### 1.4 Metrics validation (must pass before moving on)

- [x] Confirm Thanos Query is reachable from Grafana.
- [x] Confirm Prometheus sidecar is running and Thanos Query has live gRPC connections to sidecars.
- [x] Confirm Store Gateway can read blocks.
- [x] Confirm Compactor is running; retention is set to **90d**.

Notes:

- Thanos sidecar is up and Query has a live gRPC connection to it. Initial uploads may still be `0` until the first TSDB block is cut (expected).
- If you don't see `thanos` in Grafana UI (Explore datasource picker), verify you're on the correct Grafana instance/org and hard-refresh; as a fallback, confirm via Grafana API: `GET /api/datasources/name/thanos`.

Operational checks (examples; do not `kubectl apply` anything manually):

- [x] Flux Kustomizations are reconciling cleanly for `kube-prometheus-stack` and `thanos`.
- [x] Grafana Explore: query a metric via Thanos datasource.
- [x] Grafana dashboard: `Thanos / Overview` is provisioned via ConfigMap and renders (UID `xhXVFwJ7z`).

Rollback:

- [ ] Revert Thanos changes; Prometheus continues working with local 14d retention.

---

### Phase 2 — Deploy Loki for Logs 90d

#### 2.1 Deploy Loki (single-binary recommended)

Configuration requirements:

- [x] Storage: Garage S3 bucket `loki`
- [x] Retention: **90d** via Loki compactor retention deletes
- [x] Monitoring: ServiceMonitor enabled
- [x] Security: rootless, drop ALL capabilities, read-only filesystem where feasible
- [x] Ruler enabled; ruler sends to existing Alertmanager:
  - `http://alertmanager-operated.observability.svc.cluster.local:9093`

Artifacts:

- [x] Add: `kubernetes/apps/observability/loki/ks.yaml`
- [x] Add: `kubernetes/apps/observability/loki/app/{kustomization.yaml, ocirepository.yaml, helmrelease.yaml, externalsecret.yaml, config/loki.yaml}`

#### 2.2 Add Grafana Loki datasource

- [x] Add `GrafanaDatasource` for Loki.
- [ ] Configure derived fields / links for:
  - `namespace`, `pod`, `container`, `app`
  - (Optional) `trace_id` / `request_id` if your app logs include them

#### 2.3 Fluent Bit: dual-write to Loki (keep VictoriaLogs during migration)

- [x] Add Fluent Bit Loki outputs for:
  - [x] Kubernetes logs (`kubernetes.*`)
  - [x] Proxmox syslog (`proxmox.*`)
- [x] Keep VictoriaLogs outputs enabled during validation window (easy rollback).

Validation (must pass before cutting over):

- [x] Loki pod is Ready and `GET /ready` returns `ready`.
- [x] Grafana Explore → datasource `loki`:
  - [x] Query shows *new* Kubernetes logs arriving (last 5–15 minutes).
  - [x] Labels exist and look sane (no label explosion).
- [x] Proxmox logs arrive in Loki (labels include `host` and `ident`).

#### 2.4 Loki validation (must pass before cutover)

- [x] Loki ingestion endpoints are reachable internally.
- [x] Loki can execute basic LogQL queries.
- [x] Compactor is running; retention is configured to **90d**.

Rollback:

- [ ] Remove Loki app manifests; no impact on current VictoriaLogs path.

---

### Phase 3 — Cutover: Stop Writing to VictoriaLogs (Loki Only)

Goal: make Loki the source of truth for new logs while keeping VictoriaLogs running temporarily for rollback/forensics.

Steps:

- [x] Update Fluent Bit outputs:
  - [x] Remove VictoriaLogs outputs (Kubernetes + Proxmox).
  - [x] Keep Loki outputs enabled.
- [x] Validate:
  - [x] Loki continues receiving new logs from Kubernetes and Proxmox.
  - [x] Grafana Explore works for common queries (namespace/app/pod).
  - [ ] (Optional) Check Fluent Bit metrics for sustained retries/backpressure.

Rollback:

- [ ] Re-add VictoriaLogs outputs to Fluent Bit.

---

### Phase 4 — Loki Ruler → Alertmanager (Log Alerts)

#### 4.1 Deploy initial Loki rules (start small)

Recommended starter alerts:

- [ ] **Log ingestion failure / no logs** for critical namespaces (if feasible).
- [ ] **Error spike** (e.g., rate of `level=error` or HTTP 5xx log patterns) grouped by `namespace`/`app`.

Requirements:

- [ ] Rules live in Git (no UI-only rules).
- [ ] Route via existing Alertmanager (reuse existing receivers/policies).

Validation:

- [ ] Confirm alerts appear in Alertmanager UI and route correctly.

Rollback:

- [ ] Remove the Loki rules; Loki continues as a log store.

---

### Phase 5 — Cutover and Decommission VictoriaLogs

When to cut over:

- [ ] Loki has been stable under real load for at least 1–2 weeks.
- [ ] Key dashboards and workflows are validated in Grafana.
- [ ] Log alerts are firing correctly (at least one test alert observed end-to-end).

Steps:

- [ ] Switch day-to-day log viewing and dashboards to Loki.
- [ ] Stop Fluent Bit dual-write: remove VictoriaLogs output.
- [ ] Remove VictoriaLogs app manifests (including any HTTPRoute and dashboards).

Status (current):

- [x] Cutover complete: Fluent Bit writes **only** to Loki (no VictoriaLogs outputs).
- [ ] Decommission in progress: remove `victoria-logs` from GitOps so Flux prunes it.

Rollback:

- [ ] Revert Git to re-enable VictoriaLogs output and app.

---

## Acceptance Criteria (Definition of Done)

- **Retention**
  - [ ] Metrics: Thanos retention enforces **90 days**.
  - [ ] Logs: Loki retention enforces **90 days**.
- **Grafana experience**
  - [ ] Users can query logs in Explore using Loki datasource.
  - [ ] Users can query metrics >14d using Thanos datasource.
  - [ ] Logs ↔ metrics correlation works using shared labels (`namespace/pod/container/app/cluster`).
- **Alerting**
  - [ ] At least one Loki ruler alert routes through Alertmanager correctly.
  - [ ] Existing Prometheus alerting remains stable.
- **Operations**
  - [ ] No sustained Fluent Bit backpressure or loss.
  - [ ] No major query regressions for common operational queries.

---

## Validation Workflow (GitOps-safe)

Before committing changes, validate rendered manifests:

- [ ] `kubectl kustomize` (render-only validation) for affected app paths
- [ ] `kubectl --dry-run=server` for rendered resources (schema/server validation)

After user commit (monitor reconciliation):

- [ ] `flux get all -A`
- [ ] Review relevant Kustomizations/HelmReleases become Ready
- [ ] Confirm pods are healthy and ServiceMonitors are scraping

---

## Tracking Notes

Use this section to record execution notes, dates, and outcomes per phase.

### Phase 1 Notes (Thanos)

- Date started: 2025-12-19
- Date completed: 2025-12-19
- Issues encountered:
  - ExternalSecret item/key mismatch in 1Password initially prevented creation of `Secret/thanos-objstore`.
  - Thanos Query crashed due to deprecated `--store` flag (Thanos v0.40 uses `--endpoint`).
  - Compactor initially exited after a single pass (needed `--wait`).
  - HelmRelease got stuck in failed remediation due to missing rollback target after initial install failure; remediation strategy updated to `uninstall`.
  - Garage S3 permissions initially blocked compactor bucket iteration (403 Forbidden); fixed by adjusting key permissions.
- Decisions/changes:
  - Grafana Thanos datasource points to `thanos-thanos-query`.
  - Thanos Query uses SRV discovery for Prometheus sidecar + explicit endpoint for storegateway.

### Phase 2 Notes (Loki)

- Date started: 2025-12-19
- Date completed:
- Issues encountered:
- Decisions/changes:

### Phase 3 Notes (Dual-write)

- Date started:
- Date completed:
- Issues encountered:
- Decisions/changes:

### Phase 4 Notes (Alerts)

- Date started:
- Date completed:
- Issues encountered:
- Decisions/changes:

### Phase 5 Notes (Decommission VictoriaLogs)

- Date started:
- Date completed:
- Issues encountered:
- Decisions/changes:
