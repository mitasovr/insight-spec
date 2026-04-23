# GitOps deployment (ArgoCD)

For enterprise customers whose stack already runs on ArgoCD: three `Application` manifests with sync-wave ordering.

**Model**: Git is the source of truth; ArgoCD watches the repo and reconciles. Upgrading a version = a commit to that repo.

## Prerequisites

- ArgoCD is installed in the cluster (namespace `argocd`)
- ArgoCD has access to:
  - `https://airbytehq.github.io/helm-charts` (Airbyte chart repo)
  - `https://argoproj.github.io/argo-helm` (Argo Workflows chart repo)
  - `oci://ghcr.io/cyberfabric/charts` (Insight OCI registry) — or to a Git repo with the chart
- An `AppProject` is created (or use `default`)

## Files

| File | Purpose |
|------|---------|
| [`airbyte-application.yaml`](./airbyte-application.yaml) | Airbyte Application. Sync wave 0. |
| [`argo-application.yaml`](./argo-application.yaml) | Argo Workflows Application. Sync wave 0. |
| [`insight-application.yaml`](./insight-application.yaml) | Insight umbrella Application. Sync wave 1. |
| [`root-app.yaml`](./root-app.yaml) | App-of-Apps: one entry point that manages the three above. |

## Quickstart: apply the three manifests

```bash
kubectl apply -f deploy/gitops/airbyte-application.yaml
kubectl apply -f deploy/gitops/argo-application.yaml
kubectl apply -f deploy/gitops/insight-application.yaml
```

ArgoCD brings up Airbyte and Argo (wave 0), waits for them to become Healthy, then deploys Insight (wave 1).

## App-of-Apps pattern

A single `root-app.yaml` points at the `deploy/gitops/` directory — ArgoCD then discovers all other Application manifests in it and creates them too.

```bash
kubectl apply -f deploy/gitops/root-app.yaml
```

Benefit: the customer applies ONE manifest and everything else is reconciled from Git.

## Customization

**For values customization**, fork the repo or maintain a separate overlay repo and reference the fork in `source.repoURL`. Do not edit these Application manifests in place — you will drift from upstream.

Alternative: use `source.helm.valueFiles` pointing at your own values in a **different** Git repo (multi-`sources[]` is supported).

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
```
