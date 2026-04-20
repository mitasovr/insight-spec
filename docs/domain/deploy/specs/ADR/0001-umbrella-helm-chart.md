---
status: proposed
date: 2026-04-20
---

# ADR-0001: Umbrella Helm Chart for the Insight Application Bundle

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Umbrella Helm Chart (backend bundle only)](#umbrella-helm-chart-backend-bundle-only)
  - [Single umbrella covering all platform components](#single-umbrella-covering-all-platform-components)
  - [Status quo (per-service charts + bash orchestrator)](#status-quo-per-service-charts--bash-orchestrator)
  - [Kustomize overlays](#kustomize-overlays)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

The Insight platform currently deploys via three independent Helm releases (`analytics-api`, `identity`, `api-gateway`) plus a frontend release, raw Kubernetes manifests for ClickHouse (`src/ingestion/k8s/clickhouse/`), an inline Deployment/Service embedded in `up.sh` for Redis, and upstream charts for Airbyte and Argo Workflows. A bash orchestrator (`up.sh`) wires all of them together, sourcing per-environment `.env.<env>` files.

SRE review (April 2026) flagged three structural issues:

1. The application bundle lacks a single Helm artifact. Operators cannot install the platform with one `helm install` or one ArgoCD Application — they must run the bash orchestrator or manually replicate its `kubectl`/`helm` sequence.
2. Stateful dependencies (ClickHouse, MariaDB, Redis) are deployed inconsistently — raw manifests, inline YAML, or expected to pre-exist externally — with no unified `enabled: true/false` toggle to switch between bundled and external modes.
3. Repeated values (ClickHouse URL, credential Secret name, database name) are passed as `--set` flags to each chart from `up.sh`. A rename or URL change requires editing multiple places.

The platform needs a packaging model that: (a) enables single-command or GitOps-driven deployment of the application bundle, (b) cleanly supports both bundled-dependencies (local, dev) and external-dependencies (managed clusters) modes, and (c) keeps shared configuration DRY.

## Decision Drivers

- SRE guidance: bundle service + its dependencies in one namespace, expose enable/disable toggles for third-party subcharts, extract repeated values into variables
- GitOps compatibility — deploy via ArgoCD Application or Flux HelmRelease without a bootstrap script
- Dev/prod parity — same chart installs on local Kind, dev k3s, and managed Virtuozzo K8s
- Minimize orchestration code in `up.sh` — replace three `helm upgrade` calls plus raw `kubectl apply` with one `helm upgrade`
- Support external dependencies on managed environments (MariaDB, ClickHouse already exist on Virtuozzo)
- Preserve independent lifecycle for platform-level infra (Airbyte, Argo Workflows, ingress controller) — their security updates and chart versions should not be coupled to application release cadence

## Considered Options

- **Umbrella Helm chart (backend bundle only)** — one chart covering analytics-api, identity, api-gateway, frontend, and bundled stateful deps (ClickHouse, MariaDB, Redis) as conditional subcharts; Airbyte/Argo/ingress remain separate releases
- **Single umbrella covering all platform components** — one chart owning backend, stateful deps, Airbyte, Argo, and ingress
- **Status quo (per-service charts + bash orchestrator)** — no refactor; iterate on `up.sh`
- **Kustomize overlays** — replace Helm with Kustomize base + per-environment overlays

## Decision Outcome

Chosen option: **Umbrella Helm chart (backend bundle only)**.

The bundle (`src/backend/helm/insight/`) is a single Helm chart with the backend services as local subcharts and the stateful dependencies (ClickHouse, MariaDB, Redis) as conditional subcharts. A `global.*` values section carries shared configuration (URLs, credential Secret references, database names) consumed uniformly by all subcharts. Platform infrastructure — Airbyte, Argo Workflows, ingress controller — remains outside the umbrella as independent Helm releases with their own upgrade cadence.

Selected because it matches the SRE recommendation precisely (bundle + toggles + DRY) while preserving lifecycle independence for platform components whose updates should not be gated on application releases. A single `helm upgrade --install insight ./src/backend/helm/insight -f values-<env>.yaml` replaces the three chart installs and raw-manifest applies currently in `up.sh`, making the bundle directly consumable by ArgoCD or Flux.

### Consequences

- Good, because operators can install the application bundle with one Helm command or one ArgoCD Application manifest
- Good, because `<dep>.enabled` toggles give a clean boundary between bundled-dev and external-dep modes
- Good, because `global.*` centralizes shared configuration — one change updates all consumers
- Good, because independent Airbyte/Argo/ingress releases retain upgrade flexibility for security patches
- Good, because removing raw `kubectl apply -f k8s/clickhouse/` eliminates the only non-Helm step in the backend deployment path
- Bad, because the refactor is ~1 week of engineering effort plus ~1–2 days for Virtuozzo data migration (ClickHouse moves from ns `data` to ns `insight`)
- Bad, because introducing Bitnami subcharts adds an external dependency (registry availability, version compatibility)
- Bad, because `helm dependency update` becomes a build-time prerequisite (offline installs need a vendored `charts/` tarball)

### Confirmation

Confirmed when:

- `helm upgrade --install insight ./src/backend/helm/insight -f values.yaml` succeeds on a fresh Kind cluster with all subcharts enabled
- `helm upgrade --install insight ./src/backend/helm/insight -f values-virtuozzo.yaml` succeeds on Virtuozzo with `mariadb.enabled=false` and `clickhouse.enabled=false`, connecting to external services via `global.*` URLs
- `up.sh` contains one `helm upgrade` call for the bundle instead of three plus a raw `kubectl apply`
- `src/backend/services/*/helm/`, `src/ingestion/k8s/clickhouse/`, and the inline Redis YAML in `up.sh` are deleted
- Virtuozzo migration completed with no data loss (ClickHouse restore succeeds, MariaDB restore succeeds, Airbyte connections continue incremental sync)

## Pros and Cons of the Options

### Umbrella Helm Chart (backend bundle only)

Chart depends on local subcharts for application services (analytics-api, identity, api-gateway, frontend, clickhouse) and on Bitnami subcharts for mariadb and redis, all gated by `condition: <dep>.enabled`. Shared configuration (URLs, Secret names) lives under `values.global.*` and is consumed by each subchart via `{{ .Values.global.clickhouse.url }}`. Airbyte, Argo, and ingress stay as independent releases managed by `up.sh` or an operator.

- Good, because it directly implements the SRE recommendation
- Good, because bundle-vs-external is a single values toggle
- Good, because `global.*` removes `--set` duplication from `up.sh`
- Good, because ArgoCD-compatible without additional wrapping
- Neutral, because `up.sh` still exists (orchestrates bundle + Airbyte + Argo + ingress)
- Bad, because Bitnami chart dependency adds external version-compatibility surface

### Single umbrella covering all platform components

One chart depending on the backend bundle plus Airbyte, Argo, and ingress as subcharts. Entire platform installs with one `helm install`.

- Good, because truly one-command platform install
- Bad, because Airbyte/Argo security updates require a platform-release version bump
- Bad, because upstream charts have deep namespace-coupling that conflicts with umbrella release-name conventions
- Bad, because failure in any subchart blocks upgrade of unrelated components
- Bad, because ingress lifecycle is cluster-scoped (shared across tenants) and belongs outside a tenant-level bundle

### Status quo (per-service charts + bash orchestrator)

No refactor. Each service remains an independent chart; `up.sh` orchestrates them with `--set` flags and raw `kubectl apply`.

- Good, because zero migration work
- Bad, because operators cannot install the platform without the bash orchestrator
- Bad, because bundle-vs-external is mixed across chart toggles, env vars, and `up.sh` conditionals
- Bad, because repeated values (ClickHouse URL, Secret names) are maintained in multiple places
- Bad, because ArgoCD / Flux adoption requires re-engineering anyway

### Kustomize overlays

Replace Helm with Kustomize: a base manifest directory plus per-environment overlays patching images, replicas, and config.

- Good, because pure Kubernetes manifests with no templating language
- Good, because overlays compose explicitly
- Bad, because Kustomize has no native support for conditional third-party charts (Bitnami MariaDB/Redis ship as Helm charts only)
- Bad, because the ecosystem around third-party charts (ArgoCD, Renovate, chart-testing) is Helm-centric
- Bad, because Secret templating and value interpolation are weaker than Helm

## More Information

- Chart lives at `src/backend/helm/insight/` in the repository.
- Bitnami charts pulled from `oci://registry-1.docker.io/bitnamicharts` (no Helm repo `helm repo add` required).
- Wrapping existing ClickHouse manifests as a subchart (vs. adopting `altinity/clickhouse-operator`) is deferred — tracked as OQ-DEPLOY-02 in `DESIGN.md`.
- Airbyte/Argo inclusion as subcharts is out of scope — tracked as OQ-DEPLOY-01.
- GitOps (ArgoCD / Flux) adoption is out of scope for the refactor — tracked as OQ-DEPLOY-03. Chart must be GitOps-compatible when that work is picked up.

## Traceability

- **DESIGN**: [../DESIGN.md](../DESIGN.md)
- **Related ADRs**: `docs/domain/ingestion/specs/ADR/0003-k8s-secrets-credentials.md` — K8s Secrets as credential source (consumed by this chart's subcharts)
