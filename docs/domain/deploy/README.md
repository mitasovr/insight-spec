# Deploy Domain

Deployment architecture for the Insight platform: Helm packaging, environment configuration, and multi-environment orchestration (local Kind, dev k3s, Virtuozzo, any managed K8s).

## Status

**Proposed** — spec captures target state (umbrella Helm chart). Current state is three independent per-service charts plus raw manifests, orchestrated by `up.sh`. Migration tracked in DESIGN §5.

## Quick Map

| Environment | Cluster | Dependencies | How |
|---|---|---|---|
| `local` | Kind (single-node, Docker) | all bundled | `./up.sh` |
| `dev-vhc` | k3s on VM `10.21.14.101` | all bundled | `./up.sh --env dev-vhc` |
| `virtuozzo` | managed K8s (OpenStack Magnum) | external MariaDB, external ClickHouse | `./up.sh --env virtuozzo` |

## Known Workarounds (to clean up)

Discovered during dev-vhc bring-up (2026-04-20). Full context and fixes in [DESIGN.md §6](specs/DESIGN.md#6-known-issues--tech-debt).

- **`toolbox/build.sh` hardcoded to Kind** — on `CLUSTER_MODE=remote`, the `insight-toolbox:local` image (used by `dbt-run` WorkflowTemplate) is never shipped to the remote cluster. Worked around manually with `docker save | ssh k3s-node k3s ctr images import -`. [§6.1](specs/DESIGN.md#61-upsh-orchestration-gaps)
- **`.env.<env>` overrides shell env** — `BUILD_IMAGES=false ./up.sh` silently rebuilds because the env file re-sets it. [§6.1](specs/DESIGN.md#61-upsh-orchestration-gaps)
- **No remote buildx executor** — Rust cross-compile arm64→amd64 via local QEMU is ~30 min/service; native on the VM is ~2 min. `up.sh` has no way to point buildx at a remote builder. [§6.1](specs/DESIGN.md#61-upsh-orchestration-gaps)
- **Identity service crashes on a fresh cluster** — `services/identity` unconditionally queries `bronze_bamboohr.employees` at startup; missing database → `CrashLoopBackOff`. Worked around by creating an empty table. [§6.2](specs/DESIGN.md#62-missing-bootstrap-steps)
- **No bootstrap for ClickHouse `insight` DB + schema** — fresh cluster has no `insight` database; queries fail until dbt runs. [§6.2](specs/DESIGN.md#62-missing-bootstrap-steps)
- **MariaDB not in any chart** — deployed ad-hoc via inline `kubectl apply -f -` on dev-vhc; not versioned. [§6.2](specs/DESIGN.md#62-missing-bootstrap-steps)
- **GHCR PAT plaintext on the VM** — required to build images natively; lives in `~/.docker/config.json` base64-encoded. [§6.3](specs/DESIGN.md#63-secrets--credentials)
- **`ghcr-creds` imagePullSecret created manually** — not owned by any chart, undocumented for ops handoff. [§6.3](specs/DESIGN.md#63-secrets--credentials)
- **`ANALYTICS_DB_URL` plaintext in `.env.dev-vhc`** — duplicates `mariadb-credentials` secret contents. [§6.3](specs/DESIGN.md#63-secrets--credentials)
- **Connector K8s Secrets absent on dev-vhc** — per ADR-0003, every connector needs `insight-<connector>-<source-id>`; none provisioned yet, all syncs will be skipped. [§6.3](specs/DESIGN.md#63-secrets--credentials)
- **ClickHouse still in ns `data`, Redis still inline YAML in `up.sh`** — deviations from target (§3.2); corrected by the umbrella refactor. [§6.4](specs/DESIGN.md#64-dev-vhc-deviations-from-target)
- **Per-env Airbyte/Argo values files duplicate** — `values-dev-vhc.yaml` was created as a copy of `values-local.yaml`; should be consolidated into sized profiles. [§6.4](specs/DESIGN.md#64-dev-vhc-deviations-from-target)

## Documents

| Document | Description |
|---|---|
| [specs/DESIGN.md](specs/DESIGN.md) | Target deployment architecture and migration plan |
| [specs/ADR/0001-umbrella-helm-chart.md](specs/ADR/0001-umbrella-helm-chart.md) | Decision: umbrella Helm chart over per-service charts |
