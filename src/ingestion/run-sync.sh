#!/usr/bin/env bash
set -euo pipefail

# Submit an ingestion-pipeline Workflow for a single connector + tenant.
#
# All "infrastructure" parameters (toolbox_image, jira_enrich_image, airbyte_url,
# clickhouse_host/port/user) come from the WorkflowTemplate's chart-rendered
# defaults — see `charts/insight/templates/ingestion/ingestion-pipeline.yaml`
# and `access/<env>/values.yaml` `ingestion.toolboxImage` etc. This script
# only passes connection-specific inputs (connection_id, insight_source_id,
# data_source, dbt_select).
#
# Usage:
#   ./run-sync.sh <connector> <tenant_id> [<insight_source_id>]
#
# When <insight_source_id> is omitted, it is read from the connector Secret
# annotation `insight.cyberfabric.com/source-id` (matching tenant + connector).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONNECTOR="${1:?Usage: $0 <connector> <tenant_id> [<insight_source_id>]}"
TENANT="${2:?Usage: $0 <connector> <tenant_id> [<insight_source_id>]}"
SOURCE_ID="${3:-}"

NAMESPACE="${INSIGHT_NAMESPACE:-insight}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
export TOOLKIT_DIR="${SCRIPT_DIR}/airbyte-toolkit"
source "${TOOLKIT_DIR}/lib/state.sh"

# ─── Resolve connection_id from state ───────────────────────────────────
CONNECTION_ID=""
for source_key in $(state_list "tenants.${TENANT}.connectors.${CONNECTOR}"); do
  CONNECTION_ID=$(state_get "tenants.${TENANT}.connectors.${CONNECTOR}.${source_key}.connection_id")
  [[ -n "$CONNECTION_ID" ]] && break
done
[[ -n "$CONNECTION_ID" ]] || {
  echo "ERROR: no connection_id for connector '$CONNECTOR' tenant '$TENANT'." >&2
  echo "       Run update-connections.sh first." >&2
  exit 1
}

# ─── Resolve insight_source_id from Secret annotation ───────────────────
# Annotation `insight.cyberfabric.com/source-id` is set by the connector's
# Secret (e.g. insight-bamboohr-main carries source-id=bamboohr-main).
if [[ -z "$SOURCE_ID" ]]; then
  # Inline VAR=... syntax binds to the next command only; in a pipeline the
  # python3 process is a separate child and sees parent env. Export here so
  # both kubectl and python3 (downstream) see CONNECTOR/TENANT.
  export CONNECTOR TENANT
  SOURCE_ID=$(kubectl get secret -n "$NAMESPACE" -l app.kubernetes.io/part-of=insight -o json \
    | python3 -c "
import json, os, sys
connector = os.environ['CONNECTOR']
tenant    = os.environ['TENANT']
matches = []
for s in json.load(sys.stdin).get('items', []):
    ann = (s.get('metadata') or {}).get('annotations') or {}
    if ann.get('insight.cyberfabric.com/connector') != connector:
        continue
    # tenant annotation is optional — if missing, treat as default tenant 'main'
    sec_tenant = ann.get('insight.cyberfabric.com/tenant', tenant)
    if sec_tenant != tenant:
        continue
    sid = ann.get('insight.cyberfabric.com/source-id', '')
    if sid:
        matches.append(sid)
if len(matches) == 1:
    print(matches[0])
elif len(matches) > 1:
    sys.stderr.write(f'ERROR: multiple Secrets match connector={connector} tenant={tenant}: {matches}\n')
    sys.exit(2)
" 2>/dev/null)
fi
[[ -n "$SOURCE_ID" ]] || {
  echo "ERROR: could not resolve insight_source_id for connector '$CONNECTOR' tenant '$TENANT'." >&2
  echo "       Either pass it explicitly as the third argument, or annotate the connector Secret with" >&2
  echo "       insight.cyberfabric.com/source-id=<id> + insight.cyberfabric.com/connector=$CONNECTOR" >&2
  echo "       (+ optional insight.cyberfabric.com/tenant=$TENANT for multi-tenant clusters)." >&2
  exit 1
}

# ─── Resolve dbt_select from descriptor ─────────────────────────────────
DBT_SELECT=$(python3 -c "
import yaml, pathlib, sys
connector = '${CONNECTOR}'
for p in sorted(pathlib.Path('connectors').rglob('descriptor.yaml')):
    desc = yaml.safe_load(open(p))
    name = desc.get('name', '')
    if name == connector or connector.startswith(name + '-'):
        print(desc.get('dbt_select', '+tag:silver'))
        sys.exit(0)
print('+tag:silver')
" 2>/dev/null)

# data_source = connector base name, drives the jira-vs-non-jira branch in
# the pipeline. Override via env DATA_SOURCE if a connector needs the jira path
# but uses a different name (e.g. 'jira-cloud' should still trigger jira flow).
DATA_SOURCE="${DATA_SOURCE:-${CONNECTOR%%-*}}"

# dbt_select_staging only matters when data_source=jira; chart defaults it to
# empty otherwise. For jira: 'tag:jira' (intermediate staging models).
DBT_SELECT_STAGING="${DBT_SELECT_STAGING:-}"
if [[ "$DATA_SOURCE" == "jira" ]]; then
  DBT_SELECT_STAGING="${DBT_SELECT_STAGING:-tag:jira}"
fi

echo "Submitting ingestion-pipeline:"
echo "  namespace:         $NAMESPACE"
echo "  connector:         $CONNECTOR"
echo "  tenant:            $TENANT"
echo "  connection_id:     $CONNECTION_ID"
echo "  insight_source_id: $SOURCE_ID"
echo "  data_source:       $DATA_SOURCE"
echo "  dbt_select:        $DBT_SELECT"
[[ -n "$DBT_SELECT_STAGING" ]] && echo "  dbt_select_staging: $DBT_SELECT_STAGING"

# Inline Workflow that references the chart-registered ingestion-pipeline
# WorkflowTemplate. We pass only connection-specific parameters; everything
# else (toolbox_image, jira_enrich_image, airbyte_url, clickhouse_host/port/user)
# comes from the WorkflowTemplate's defaults baked at `helm install` time.
{
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ${CONNECTOR}-${TENANT//_/-}-
  namespace: $NAMESPACE
  labels:
    tenant: "$TENANT"
    connector: "$CONNECTOR"
    # Controller picks up workflows by this label — value MUST match
    # the instanceID in the argo-workflows-workflow-controller ConfigMap
    # (set by deploy/scripts/install-argo.sh as argo-workflows-insight).
    workflows.argoproj.io/controller-instanceid: argo-workflows-insight
spec:
  # Workflow steps need write access to argoproj.io/workflowtaskresults.
  # The argo chart creates this ServiceAccount via workflow.serviceAccount.create=true;
  # supplemental Role/Binding (deploy/argo/rbac.yaml) grants the necessary verbs.
  serviceAccountName: argo-workflow
  entrypoint: run
  templates:
    - name: run
      steps:
        - - name: pipeline
            templateRef:
              name: ingestion-pipeline
              template: pipeline
            arguments:
              parameters:
                - name: connection_id
                  value: "$CONNECTION_ID"
                - name: insight_source_id
                  value: "$SOURCE_ID"
                - name: data_source
                  value: "$DATA_SOURCE"
                - name: dbt_select
                  value: "$DBT_SELECT"
EOF
  if [[ -n "$DBT_SELECT_STAGING" ]]; then
    cat <<EOF
                - name: dbt_select_staging
                  value: "$DBT_SELECT_STAGING"
EOF
  fi
} | kubectl create -n "$NAMESPACE" -f -

echo
echo "Monitor:"
echo "  kubectl -n $NAMESPACE get workflows -l connector=$CONNECTOR,tenant=$TENANT --watch"
