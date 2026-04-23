# Argo Workflows installation for Insight

Argo Workflows is the engine for ingestion pipelines (Airbyte sync → dbt run → enrichment). It is installed as a **standalone Helm release** in namespace `argo`.

Insight services create `CronWorkflow` objects; the Argo controller executes them.

## Pinned version

| Component | Version |
|-----------|---------|
| Chart     | 0.45.x (pinned in the install script) |

## Install (quickstart)

```bash
./deploy/scripts/install-argo.sh
```

Or manually:
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace argo --create-namespace \
  -f deploy/argo/values.yaml \
  --wait --timeout 5m
kubectl apply -f deploy/argo/rbac.yaml
```

## Production overrides

On top of [`values.yaml`](./values.yaml), provide your own `values-prod.yaml`:
- HA: `controller.replicas: 2`, workflow archive in Postgres
- `server.sso` with an OIDC client
- Resource limits sized for your workflow volume
- Restrict `controller.parallelism` if the cluster is shared

```bash
EXTRA_VALUES_FILE=deploy/argo/values-prod.yaml \
  ./deploy/scripts/install-argo.sh
```

## WorkflowTemplates

The WorkflowTemplates (`airbyte-sync`, `dbt-run`, `ingestion-pipeline`) are **content**, not infrastructure. They are shipped by the Insight umbrella chart under the `ingestion.templates.enabled: true` flag. After the umbrella is installed they appear in the `insight` namespace and can be referenced from `CronWorkflow` objects.

## Verify

```bash
kubectl -n argo get pods
kubectl -n argo port-forward svc/argo-workflows-server 2746:2746
# UI: http://localhost:2746

# Submit a test workflow
argo -n argo submit --from workflowtemplate/ingestion-pipeline -p connector=m365
```

## Uninstall

```bash
helm -n argo uninstall argo-workflows
kubectl delete -f deploy/argo/rbac.yaml
kubectl delete namespace argo
```
