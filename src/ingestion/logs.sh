#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Show logs for a workflow run
#
# Usage:
#   ./logs.sh <workflow-name>           # all steps
#   ./logs.sh <workflow-name> sync      # only Airbyte sync step
#   ./logs.sh <workflow-name> dbt       # only dbt step
#   ./logs.sh latest                    # latest workflow
#
# Examples:
#   ./logs.sh m365-example-tenant-k6h67
#   ./logs.sh m365-example-tenant-k6h67 dbt
#   ./logs.sh latest
# ---------------------------------------------------------------------------

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"
export KUBECONFIG

workflow="${1:-}"
step="${2:-}"

if [[ -z "$workflow" ]]; then
  echo "Usage: $0 <workflow-name|latest> [sync|dbt|all]" >&2
  echo "" >&2
  echo "Recent workflows:" >&2
  kubectl get workflows -n argo --sort-by=.metadata.creationTimestamp --no-headers | tail -5 | awk '{print "  " $1 "  " $2 "  " $4}' >&2
  exit 1
fi

if [[ "$workflow" == "latest" ]]; then
  workflow=$(kubectl get workflows -n argo --sort-by=.metadata.creationTimestamp --no-headers | tail -1 | awk '{print $1}')
  if [[ -z "$workflow" ]]; then
    echo "No workflows found" >&2
    exit 1
  fi
  echo "Latest workflow: $workflow" >&2
fi

echo "=== Workflow: $workflow ===" >&2
kubectl get workflow "$workflow" -n argo --no-headers 2>/dev/null | awk '{print "Status: " $2 "  Age: " $4}' >&2
echo "" >&2

case "${step}" in
  sync|trigger)
    echo "=== Airbyte Sync ===" >&2
    kubectl logs -n argo -l "workflows.argoproj.io/workflow=$workflow" --all-containers --prefix 2>/dev/null | grep -E "trigger-sync|poll-job"
    ;;
  dbt|run)
    echo "=== dbt Run ===" >&2
    kubectl logs -n argo "$workflow"-run-* -n argo -c main 2>/dev/null || \
      kubectl logs -n argo -l "workflows.argoproj.io/workflow=$workflow" --all-containers --prefix 2>/dev/null | grep "run-"
    ;;
  ""|all)
    echo "=== All Logs ===" >&2
    kubectl logs -n argo -l "workflows.argoproj.io/workflow=$workflow" --all-containers --prefix 2>/dev/null
    ;;
  *)
    echo "Unknown step: $step (use: sync, dbt, all)" >&2
    exit 1
    ;;
esac
