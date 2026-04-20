---
status: proposed
date: 2026-04-20
---

# DESIGN -- Deployment Architecture

<!-- toc -->

- [1. Architecture Overview](#1-architecture-overview)
  - [1.1 Vision](#11-vision)
  - [1.2 Drivers](#12-drivers)
- [2. Principles & Constraints](#2-principles--constraints)
- [3. Target Architecture](#3-target-architecture)
  - [3.1 Umbrella Helm Chart](#31-umbrella-helm-chart)
  - [3.2 Namespace Layout](#32-namespace-layout)
  - [3.3 Values Hierarchy](#33-values-hierarchy)
  - [3.4 Dependency Toggles](#34-dependency-toggles)
  - [3.5 Global Values](#35-global-values)
  - [3.6 Secrets](#36-secrets)
- [4. Environment Matrix](#4-environment-matrix)
- [5. Migration Plan](#5-migration-plan)
  - [5.1 Current State (as of 2026-04-20)](#51-current-state-as-of-2026-04-20)
  - [5.2 Refactor Steps](#52-refactor-steps)
  - [5.3 Virtuozzo Data Migration](#53-virtuozzo-data-migration)
- [6. Known Issues & Tech Debt](#6-known-issues--tech-debt)
  - [6.1 up.sh orchestration gaps](#61-upsh-orchestration-gaps)
  - [6.2 Missing bootstrap steps](#62-missing-bootstrap-steps)
  - [6.3 Secrets & credentials](#63-secrets--credentials)
  - [6.4 dev-vhc deviations from target](#64-dev-vhc-deviations-from-target)
- [7. Open Questions](#7-open-questions)
- [8. Traceability](#8-traceability)

<!-- /toc -->

---

## 1. Architecture Overview

### 1.1 Vision

A single Helm release deploys the entire Insight platform (backend services + stateful dependencies) into one Kubernetes namespace. Each stateful dependency (ClickHouse, MariaDB, Redis) can be toggled on (bundled, for local/dev) or off (external, for managed environments). Infrastructure-level components with their own lifecycle (Airbyte, Argo Workflows, ingress controller) remain independent Helm releases in dedicated namespaces.

### 1.2 Drivers

- SRE guidance: bundle service + dependencies in one namespace, expose enable/disable toggles for 3rd-party subcharts, keep repeated values DRY
- Single `helm upgrade --install` replaces three separate releases orchestrated by bash
- Values files per environment replace `.env.*` shell-sourced config
- GitOps compatibility — chart is installable by ArgoCD / Flux without a bootstrap script
- Local development parity with managed deployments (same chart, different values)

## 2. Principles & Constraints

1. **One chart, one release** for backend bundle. Infra (Airbyte, Argo, ingress-nginx) stays separate — their own lifecycles.
2. **Conditional subcharts** for stateful deps (`condition: <dep>.enabled`) so the same chart deploys in both bundled and external-dep modes.
3. **DRY via `global.*`** — URLs, credential secret refs, connection params live once in `values.global.*` and are consumed by every subchart.
4. **Secrets never in values** — templates reference existing K8s Secrets by name. Values only contain Secret **names** and **key names**.
5. **Backwards compatible** — `up.sh` remains the orchestration entrypoint during transition; internally it calls `helm upgrade --install` once per environment.
6. **No data loss during migration** — stateful PVCs adopted into the new chart or data restored from dumps.

## 3. Target Architecture

### 3.1 Umbrella Helm Chart

```
src/backend/helm/insight/
  Chart.yaml                        # umbrella, depends on subcharts
  Chart.lock
  values.yaml                       # defaults (everything bundled, for local)
  values-dev-vhc.yaml               # k3s dev VM
  values-virtuozzo.yaml             # managed, external deps
  charts/
    analytics-api/                  # local subchart (moved from services/*/helm)
    identity/
    api-gateway/
    frontend/
    clickhouse/                     # wrap k8s/clickhouse/*.yaml
  # External subcharts pulled via dependencies:
  #   bitnami/mariadb  (condition: mariadb.enabled)
  #   bitnami/redis    (condition: redis.enabled)
```

`Chart.yaml` dependencies:

```yaml
dependencies:
  - name: mariadb
    version: ~18.0.0
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: mariadb.enabled
  - name: redis
    version: ~19.0.0
    repository: oci://registry-1.docker.io/bitnamicharts
    condition: redis.enabled
  - name: clickhouse
    version: 0.1.0
    repository: "file://charts/clickhouse"
    condition: clickhouse.enabled
  - name: analytics-api
    version: 0.1.0
    repository: "file://charts/analytics-api"
  - name: identity
    version: 0.1.0
    repository: "file://charts/identity"
  - name: api-gateway
    version: 0.1.0
    repository: "file://charts/api-gateway"
  - name: frontend
    version: 0.1.0
    repository: "file://charts/frontend"
```

### 3.2 Namespace Layout

| Namespace | Contents | Lifecycle |
|---|---|---|
| `insight` | analytics-api, identity, api-gateway, frontend, redis, mariadb, clickhouse (when bundled) | Umbrella chart (`helm upgrade --install insight`) |
| `airbyte` | Airbyte (upstream chart) | Separate release (`helm upgrade --install airbyte airbyte/airbyte`) |
| `argo` | Argo Workflows, WorkflowTemplates | Separate release (`helm upgrade --install argo-workflows argo/argo-workflows`) |
| `ingress-nginx` | Ingress controller | Separate release (when `INGRESS_INSTALL=true`) |

Rationale for not putting Airbyte and Argo into `insight` namespace:
- Upstream charts create many sub-resources with hardcoded namespace assumptions
- Different upgrade cadences (security updates for Airbyte don't belong in bundle versioning)
- SRE feedback targets the **application bundle**, not platform-level infra

### 3.3 Values Hierarchy

1. `values.yaml` — defaults (all subcharts enabled, for local Kind)
2. `values-<env>.yaml` — per-environment overrides
3. `--set` flags from `up.sh` — image tags, one-off deploys

Precedence: `--set` > `values-<env>.yaml` > `values.yaml`.

### 3.4 Dependency Toggles

```yaml
# values.yaml (defaults — local)
mariadb:
  enabled: true
redis:
  enabled: true
clickhouse:
  enabled: true
```

```yaml
# values-virtuozzo.yaml (external deps)
mariadb:
  enabled: false
redis:
  enabled: true    # redis is missing on virtuozzo, bundle it
clickhouse:
  enabled: false

global:
  mariadb:
    host: mariadb.insight.svc.cluster.local
    credentialsSecret: mariadb-credentials
  clickhouse:
    url: http://clickhouse.data.svc.cluster.local:8123
    database: insight
    credentialsSecret: clickhouse-credentials
```

### 3.5 Global Values

Repeated values live under `global.*` and are consumed by all subcharts:

```yaml
global:
  namespace: insight
  clickhouse:
    url: ""                      # computed if clickhouse.enabled=true
    database: insight
    credentialsSecret: clickhouse-credentials
    credentialsUserKey: username
    credentialsPasswordKey: password
  mariadb:
    host: ""                     # computed if mariadb.enabled=true
    database: analytics
    credentialsSecret: mariadb-credentials
  redis:
    url: ""                      # computed if redis.enabled=true
  oidc:
    existingSecret: insight-oidc
```

Computed defaults (in `values.yaml` via `tpl`):

```yaml
global:
  clickhouse:
    url: |-
      {{- if .Values.clickhouse.enabled -}}
        http://{{ .Release.Name }}-clickhouse:8123
      {{- end -}}
```

### 3.6 Secrets

No secret values in charts or values files. Convention:

| Secret | Namespace | Keys | Consumed by |
|---|---|---|---|
| `clickhouse-credentials` | `insight` | `username`, `password` | analytics-api, identity, clickhouse subchart |
| `mariadb-credentials` | `insight` | `mariadb-password`, `mariadb-root-password` | analytics-api, mariadb subchart |
| `insight-oidc` | `insight` | `issuer`, `client-id`, `audience`, `redirect-uri` | api-gateway |
| `insight-<connector>-<source-id>` | `airbyte` | per-connector fields | `airbyte-toolkit/connect.sh` (ADR-0003) |

Secrets are created out-of-band:
- Local: `./secrets/apply.sh` with files in `src/ingestion/secrets/` (gitignored)
- Managed: cluster admin provisions via Vault + ESO / Sealed Secrets / manual

## 4. Environment Matrix

| | local (Kind) | dev-vhc (k3s) | virtuozzo |
|---|---|---|---|
| `CLUSTER_MODE` | local | remote | remote |
| Image source | build + `kind load` | build + push to ghcr.io | build + push to ghcr.io |
| `IMAGE_PLATFORM` | native | `linux/amd64` | `linux/amd64` |
| `mariadb.enabled` | true | true | false (external) |
| `redis.enabled` | true | true | true |
| `clickhouse.enabled` | true | true | false (external `data` ns) |
| Airbyte | bundled release in `airbyte` ns | bundled release in `airbyte` ns | pre-existing |
| Argo | bundled release in `argo` ns | bundled release in `argo` ns | pre-existing |
| Ingress | optional | hostPort 80/443 | hostPort 80/443 |
| OIDC | disabled (`AUTH_DISABLED=true`) | Okta SPA | Okta SPA |

## 5. Migration Plan

### 5.1 Current State (as of 2026-04-20)

| | Current | Target |
|---|---|---|
| Backend charts | 3 separate: `analytics-api/helm`, `identity/helm`, `api-gateway/helm` | Subcharts in `src/backend/helm/insight/charts/` |
| Frontend | `src/frontend/helm/` | Subchart in umbrella |
| ClickHouse | raw manifests `src/ingestion/k8s/clickhouse/*.yaml`, ns `data` | Subchart in umbrella, ns `insight` |
| MariaDB | not deployed (expected pre-existing on virtuozzo) | Bitnami subchart, ns `insight`, toggled |
| Redis | inline YAML in `up.sh` when `DEPLOY_REDIS=true` | Bitnami subchart, ns `insight`, toggled |
| Airbyte | upstream chart, ns `airbyte` | Unchanged |
| Argo | upstream chart, ns `argo` | Unchanged |
| Orchestration | `up.sh` with three `helm upgrade` calls + inline Redis YAML + `kubectl apply -f k8s/clickhouse/` | `up.sh` with one `helm upgrade insight ./src/backend/helm/insight -f values-<env>.yaml` + Airbyte + Argo |
| Config | `.env.<env>` | `values-<env>.yaml` (env still used for image/auth flags) |
| ClickHouse namespace | `data` | `insight` |

### 5.2 Refactor Steps

1. **Scaffold umbrella chart** `src/backend/helm/insight/` with `Chart.yaml`, `values.yaml`, `global.*` section, empty `charts/` directory.
2. **Wrap ClickHouse** as subchart `charts/clickhouse/` from existing `src/ingestion/k8s/clickhouse/*.yaml`. Parameterize storage, resources, credentials secret name.
3. **Move service charts** from `src/backend/services/*/helm/` to `charts/*/`. Adjust `image.repository`, `image.tag`, and DB references to read from `.Values.global.*`.
4. **Add bitnami subcharts** (`mariadb`, `redis`) with `condition: <dep>.enabled`. Run `helm dependency update`.
5. **Write per-env values**: `values.yaml` (local defaults), `values-dev-vhc.yaml`, `values-virtuozzo.yaml`.
6. **Rewrite `up.sh`** — replace three `helm upgrade` blocks with one, keep Airbyte/Argo blocks untouched.
7. **Test on Kind** — verify fresh install + upgrade idempotency.
8. **Test on dev-vhc** — fresh install on k3s, end-to-end ingestion through ClickHouse.
9. **Migrate virtuozzo** — see §5.3.
10. **Delete** `src/backend/services/*/helm/`, `src/ingestion/k8s/clickhouse/`, inline Redis YAML from `up.sh`.

Estimated effort: ~1 week for the refactor, ~1–2 days for Virtuozzo migration.

### 5.3 Virtuozzo Data Migration

Virtuozzo already has ClickHouse in ns `data` with data, plus MariaDB, Airbyte, Argo. Refactor moves ClickHouse to ns `insight`, so data migration is required.

**Preconditions**:
- Check `reclaimPolicy` on all PVCs: `kubectl get pv -o jsonpath='{.items[*].spec.persistentVolumeReclaimPolicy}'`. If `Delete`, patch to `Retain` before `helm uninstall`.

**Backup**:
```bash
./dump-clickhouse.sh                                    # script already exists
kubectl exec -n insight mariadb-0 -- mysqldump \
  --all-databases -p"$MARIADB_ROOT_PASS" > mariadb.sql
kubectl exec -n airbyte airbyte-db-0 -- pg_dumpall \
  -U postgres > airbyte-pg.sql
kubectl get secrets -n insight -n data -n airbyte -o yaml > secrets.yaml
```

**Cutover**:
```bash
helm uninstall insight-analytics insight-identity insight-gw insight-fe -n insight
helm uninstall insight-redis -n insight 2>/dev/null || true
kubectl delete -f src/ingestion/k8s/clickhouse/ -n data
kubectl delete namespace data
# Airbyte, Argo stay
./up.sh --env virtuozzo                                 # deploys new chart
```

**Restore**:
```bash
# ClickHouse: for db in bronze_*, silver, identity: INSERT ... FORMAT Native
# MariaDB: mysql < mariadb.sql
# Airbyte PG: restore only if Airbyte version matches (same chart version)
```

**Risks**:
1. `reclaimPolicy: Delete` → data loss before backup completes. **Mitigation**: patch to Retain first.
2. Airbyte PG schema mismatch if Airbyte version changes. **Mitigation**: pin Airbyte chart version; skip PG restore and recreate connections via `connect.sh` (triggers full re-sync).
3. Incremental sync state loss (Airbyte connection cursors) → full re-sync of all sources. **Mitigation**: dump/restore Airbyte PG with matching version.
4. Secret `resourceVersion`/`uid` fields on reapply → strip via `jq` before apply.

## 6. Known Issues & Tech Debt

Everything in this section is a real bug or missing piece uncovered during the dev-vhc bring-up (2026-04-20). Each item is a concrete fix that should land before or as part of the umbrella-chart refactor (§5).

### 6.1 `up.sh` orchestration gaps

**`toolbox/build.sh` hardcoded to Kind**

`src/ingestion/tools/toolbox/build.sh` detects a local Kind cluster named `insight` and runs `kind load docker-image`. In `CLUSTER_MODE=remote`, the toolbox image (`insight-toolbox:local`, used by the `dbt-run` Argo WorkflowTemplate) never reaches the remote cluster's containerd. On dev-vhc this was worked around manually with `docker save | ssh r.mitasov@10.21.14.101 'sudo k3s ctr images import -'`, which is neither idempotent nor reproducible.

Fix: teach `build.sh` the `CLUSTER_MODE` contract. For `remote`, either (a) push the image to `${IMAGE_REGISTRY}/insight-toolbox:${IMAGE_TAG}` and update `dbt-run.yaml` to use the parameterized ref, or (b) `docker save | ssh k3s-node k3s ctr images import -` when a VM host is known. Option (a) is cleaner and aligns with how backend images are shipped.

**`.env.<env>` overrides shell environment**

`up.sh` does `set -a; source "$ENV_FILE"; set +a`, which replaces any variables already set in the invoking shell. Running `BUILD_IMAGES=false ./up.sh --env dev-vhc app` silently rebuilds images because the env file sets `BUILD_IMAGES=true`. Discovered after killing a 30-minute QEMU buildx round-trip that should have been skipped.

Fix: source the env file first, then let shell-exported variables win. Practically: in `up.sh`, replace direct `source` with a loop that only sets keys not already exported, or use `${VAR:-<env_file_value>}` pattern throughout.

**Fallback image build path is single-executor**

When `IMAGE_PLATFORM=linux/amd64` on an arm64 workstation, `up.sh` runs `docker buildx build --push` against the local BuildKit (QEMU-emulated Rust ~30 min per service). There is no built-in way to point buildx at a remote amd64 builder (the VM itself) for 10–15× speedup. On dev-vhc this was unblocked by building directly on the VM via SSH, bypassing `up.sh`.

Fix: support `BUILDER_CONTEXT` / `DOCKER_HOST` override, or auto-detect a remote buildx node from the kubeconfig server URL for `CLUSTER_MODE=remote`.

### 6.2 Missing bootstrap steps

**Identity service crashes on fresh cluster**

`services/identity/src/people.rs` unconditionally queries `bronze_bamboohr.employees` at startup. If the database or table does not exist (fresh cluster with no completed sync), the pod enters `CrashLoopBackOff` with `UNKNOWN_DATABASE`. On dev-vhc this was unblocked by manually creating an empty `bronze_bamboohr.employees` table with the expected schema.

Fix — pick one:
1. Make the identity stub tolerant of missing databases/tables (treat as empty) and retry on a timer.
2. Add a startup init container that ensures all expected bronze databases/tables exist (no-op if populated).
3. Stop treating identity as a zero-data service — it needs at least one successful ingestion pipeline pass before it can claim Ready.

**No bootstrap for ClickHouse `insight` database and schema**

`src/ingestion/k8s/clickhouse/*.yaml` creates the ClickHouse Deployment + Service + PVC but does not initialize the `insight` database or any schema. Analytics queries targeting `insight.*` tables fail until dbt models run at least once. This is hidden on virtuozzo because the cluster has historical data.

Fix: subchart should include an `initContainers` or `postInstall` Job that creates `insight` database and any required baseline DDL. Same Job can own the empty `bronze_*` placeholders needed by the identity stub until Issue 6.2.1 is resolved.

**MariaDB not deployed by any chart**

`up.sh` does not deploy MariaDB. `analytics-api` expects it at `mysql://insight:...@mariadb:3306/analytics`. On virtuozzo it pre-exists; on dev-vhc it was deployed ad-hoc via `kubectl apply -f -` of an inline manifest. Not reproducible, not versioned.

Fix: add Bitnami MariaDB as a conditional subchart of the umbrella (§3.1). Until then, add a `MARIADB_DEPLOY=true` path in `up.sh` mirroring the Redis inline YAML, or keep a versioned manifest under `src/backend/k8s/mariadb/`.

### 6.3 Secrets & credentials

**GHCR PAT plaintext on VM**

To build images natively on the dev-vhc VM, `docker login ghcr.io` was run with a GitHub PAT. The token lands in `~/.docker/config.json` base64-encoded (not encrypted). Anyone with VM access can read it and push to `ghcr.io/cyberfabric`. Token has `write:packages` scope and does not expire automatically.

Fix: rotate PAT after refactor; for the long term, use a GitHub App deploy key scoped to the specific repository, or issue short-lived tokens via OIDC federation. Do not commit the PAT or leave it on any long-lived shared host.

**`ghcr-creds` imagePullSecret manually created**

k3s on dev-vhc pulls private images from `ghcr.io/cyberfabric/insight-*:dev-vhc` using a `ghcr-creds` Secret in namespace `insight`, created manually with the same PAT as above. The secret is not owned by any chart and not documented anywhere that CI or a future operator would discover.

Fix: in the umbrella chart, accept `global.imagePullSecret` as the value and either (a) expect it to pre-exist (document how to create), or (b) template the Secret from `global.imagePullCredentials` when provided. Prefer (a) with External Secrets Operator integration for managed environments.

**`ANALYTICS_DB_URL` with plaintext password in `.env.dev-vhc`**

`.env.dev-vhc` contains `ANALYTICS_DB_URL=mysql://insight:insight-dev-pass@mariadb:3306/analytics`. The value is duplicated in the ad-hoc MariaDB manifest's `mariadb-credentials` secret. Two sources of truth, neither scoped per-deployment.

Fix: once analytics-api chart reads MariaDB creds from a Secret (like it does for ClickHouse with `credentialsSecret`), drop the inline URL from `.env.*` and `up.sh`. Chart composes URL from `global.mariadb.host` + Secret keys.

**Connector K8s Secrets not provisioned on dev-vhc**

Connectors (Jira, M365, BambooHR, etc.) require `insight-{connector}-{source-id}` Secrets per ADR-0003 (`docs/domain/ingestion/specs/ADR/0003-k8s-secrets-credentials.md`). None exist on dev-vhc yet; all syncs will be skipped. Required before smoke-testing the ingestion pipeline on dev-vhc.

Fix: document per-connector required fields in a dev-only `src/ingestion/secrets/connectors/*.yaml.example` set and run `./src/ingestion/secrets/apply.sh` as part of the dev bring-up playbook.

### 6.4 dev-vhc deviations from target

**ClickHouse still in namespace `data`**

Target architecture (§3.2) places ClickHouse in namespace `insight` as a bundled subchart. dev-vhc inherited the current layout (`data` namespace, raw manifests). Will be corrected during the refactor (§5.2 step 3). Until then, `global.clickhouse.url` must explicitly reference `clickhouse.data.svc.cluster.local`.

**Redis still inline YAML in `up.sh`**

`up.sh` embeds Redis Deployment+Service YAML directly. Functional but not versioned as a chart. Target state (§3.1) makes it a Bitnami subchart. Remove the inline YAML in refactor step 10 (§5.2).

**Airbyte/Argo values files must exist per environment**

`src/ingestion/up.sh` loads `k8s/airbyte/values-${ENV}.yaml` and `k8s/argo/values-${ENV}.yaml`. On dev-vhc these were created as copies of `values-local.yaml`. Adding a new environment currently requires two file copies plus touching `.env.<env>`. Low priority but a source of cognitive overhead.

Fix: collapse values files to `values-small.yaml` / `values-prod.yaml` (sized profiles) and select via an env var, not env name.

## 7. Open Questions

### OQ-DEPLOY-01: Airbyte/Argo ownership

Should Airbyte and Argo Workflows become subcharts of the umbrella to achieve single-release deployment, or stay as independent releases? Independent keeps lifecycle separation (security updates, chart version pinning) at the cost of multiple `helm upgrade` calls. Current direction: **stay independent**.

### OQ-DEPLOY-02: ClickHouse operator vs. raw chart

Wrap existing raw manifests as a subchart, or switch to `altinity/clickhouse-operator`? Operator provides cluster macros, backup automation, and schema sync — aligned with production needs. Cost: new dependency, learning curve. Current direction: **wrap existing manifests now**, evaluate operator after migration.

### OQ-DEPLOY-03: GitOps adoption

Once umbrella chart exists, is ArgoCD / Flux in scope? Enables pull-based deployment and drift detection. Requires secret management integration (Sealed Secrets or ESO). Current direction: **out of scope for this refactor**, but chart must be ArgoCD-compatible.

## 8. Traceability

- **ADR-0001**: [ADR/0001-umbrella-helm-chart.md](ADR/0001-umbrella-helm-chart.md)
- **Related**: `ingestion/specs/ADR/0003-k8s-secrets-credentials.md` — credential resolution via K8s Secrets (consumed by this chart)
