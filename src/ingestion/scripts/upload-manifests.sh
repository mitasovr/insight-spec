#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

AIRBYTE_URL="${AIRBYTE_URL:-http://localhost:8000}"
CONNECTORS_DIR="./connectors"

get_token() {
  local creds
  creds=$(abctl local credentials 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
  local client_id client_secret
  client_id=$(echo "$creds" | grep "Client-Id:" | awk '{print $NF}')
  client_secret=$(echo "$creds" | grep "Client-Secret:" | awk '{print $NF}')

  AIRBYTE_TOKEN=$(curl -sf -X POST "${AIRBYTE_URL}/api/v1/applications/token" \
    -H "Content-Type: application/json" \
    -d "{\"client_id\":\"${client_id}\",\"client_secret\":\"${client_secret}\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
}

api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sf -X "$method" "${AIRBYTE_URL}${path}" -H "Authorization: Bearer ${AIRBYTE_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}"
}

get_workspace_id() {
  api GET "/api/public/v1/workspaces" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['workspaceId'])"
}

upload_connector() {
  local connector="$1"
  local connector_dir="${CONNECTORS_DIR}/${connector}"
  local manifest_path="${connector_dir}/connector.yaml"
  local descriptor_path="${connector_dir}/descriptor.yaml"

  if [[ ! -f "$manifest_path" ]]; then
    echo "  SKIP: no manifest at ${manifest_path}"
    return 0
  fi

  local name
  name=$(yq -r '.name' "${descriptor_path}" 2>/dev/null || basename "$connector")

  local manifest_json
  manifest_json=$(yq -c '.' "${manifest_path}")

  local workspace_id
  workspace_id=$(get_workspace_id)

  local existing
  existing=$(api GET "/api/public/v1/sources?workspaceIds=${workspace_id}" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('data', []):
    if s.get('name') == '${name}':
        print(s['sourceId'])
        break
" 2>/dev/null || true)

  if [[ -n "$existing" ]]; then
    echo "  Updating source '${name}' (${existing})..."
    api PATCH "/api/public/v1/sources/${existing}" "{
      \"name\": \"${name}\",
      \"configuration\": {\"__injected_declarative_manifest\": ${manifest_json}}
    }" >/dev/null
  else
    echo "  Creating source '${name}'..."
    api POST "/api/public/v1/sources" "{
      \"workspaceId\": \"${workspace_id}\",
      \"name\": \"${name}\",
      \"definitionId\": \"64a2f99c-542f-4af8-9a6f-355f1217b436\",
      \"configuration\": {\"__injected_declarative_manifest\": ${manifest_json}}
    }" >/dev/null
  fi
  echo "  Done: ${name}"
}

get_token

if [[ "${1:-}" == "--all" ]]; then
  manifests=$(find "$CONNECTORS_DIR" -name "connector.yaml" 2>/dev/null)
  if [[ -z "$manifests" ]]; then
    echo "  No connector manifests found"
    exit 0
  fi
  for manifest in $manifests; do
    connector_dir=$(dirname "$manifest")
    connector=$(echo "$connector_dir" | sed "s|${CONNECTORS_DIR}/||")
    upload_connector "$connector"
  done
else
  connector="${1:?Usage: $0 <class/connector> | --all}"
  upload_connector "$connector"
fi
