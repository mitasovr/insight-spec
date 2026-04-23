# GitOps deployment (ArgoCD)

For enterprise customers whose stack already runs on ArgoCD. Four `Application` manifests with sync-wave ordering, all consuming the same `deploy/<component>/values.yaml` files used by the imperative installers — no inline values to drift.

**Model**: Git is the source of truth; ArgoCD watches the repo and reconciles. Upgrading a version = a commit to that repo.

## Prerequisites

- ArgoCD **2.6+** (multi-source support is required for the `$values` pattern used below)
- ArgoCD has access to:
  - `https://airbytehq.github.io/helm-charts` (Airbyte chart repo)
  - `https://argoproj.github.io/argo-helm` (Argo Workflows chart repo)
  - `oci://ghcr.io/cyberfabric/charts` (Insight OCI registry) — or to a Git repo with the chart
  - `https://github.com/cyberfabric/insight.git` (or your fork) for values files and supplemental manifests
- An `AppProject` is created (or use `default`)

## Files

| File | Purpose |
|------|---------|
| [`airbyte-application.yaml`](./airbyte-application.yaml) | Airbyte chart. Sync wave 0. |
| [`argo-application.yaml`](./argo-application.yaml) | Argo Workflows chart. Sync wave 0. |
| [`argo-rbac-application.yaml`](./argo-rbac-application.yaml) | Supplemental Argo RBAC (`argo-workflow-executor` Role/Binding in `argo` and `insight` namespaces). Sync wave 0. |
| [`insight-application.yaml`](./insight-application.yaml) | Insight umbrella. Sync wave 1. |
| [`insight-values.yaml`](./insight-values.yaml) | GitOps overlay for Insight — minimal overrides on top of the chart defaults. |
| [`root-app.yaml`](./root-app.yaml) | App-of-Apps: one entry point that manages the four above. |

## Single source of truth

Each infra component has exactly one values file:
- Airbyte: [`deploy/airbyte/values.yaml`](../airbyte/values.yaml)
- Argo Workflows: [`deploy/argo/values.yaml`](../argo/values.yaml)
- Insight: the chart's own [`values.yaml`](../../charts/insight/values.yaml), plus [`insight-values.yaml`](./insight-values.yaml) for ArgoCD-specific overrides (OIDC secret, ingress hosts, TLS)

All four Applications reference these files via multi-source (`$values` pattern), so imperative (`deploy/scripts/install-*.sh`) and declarative (ArgoCD) deploys render **identical** manifests.

## Quickstart: apply the Applications

```bash
kubectl apply -f deploy/gitops/airbyte-application.yaml
kubectl apply -f deploy/gitops/argo-application.yaml
kubectl apply -f deploy/gitops/argo-rbac-application.yaml
kubectl apply -f deploy/gitops/insight-application.yaml
```

ArgoCD brings up Airbyte + Argo + Argo RBAC (wave 0), waits for them to become Healthy, then deploys Insight (wave 1).

## App-of-Apps pattern

A single `root-app.yaml` points at the `deploy/gitops/` directory — ArgoCD then discovers all other Application manifests in it and creates them too.

```bash
kubectl apply -f deploy/gitops/root-app.yaml
```

Benefit: the customer applies ONE manifest and everything else is reconciled from Git.

## Customization

Fork this repo and edit:
- `deploy/airbyte/values.yaml` / `deploy/argo/values.yaml` — for infra overrides
- `deploy/gitops/insight-values.yaml` — for Insight umbrella overrides (ingress, OIDC, sizing)

Then point the `sources[].repoURL` entries of each Application at your fork.

## Upgrade flow

```bash
# 1. In your fork — bump the chart version
sed -i '' 's/targetRevision: 0.1.0/targetRevision: 0.2.0/' insight-application.yaml

# 2. PR → merge → ArgoCD syncs automatically
# (or manual sync via UI / argocd CLI)
```

## Rollback

```bash
# Via the ArgoCD CLI
argocd app rollback insight <REVISION>

# Or git revert
git revert <commit>; git push
```

## Health checks

```bash
argocd app list
argocd app get insight
argocd app get airbyte
argocd app get argo-workflows
argocd app get argo-workflows-rbac
```
