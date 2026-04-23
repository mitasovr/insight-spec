# Airbyte installation for Insight

Airbyte is installed as a **standalone Helm release** in its own namespace `airbyte`. The Insight umbrella chart only knows about its URL and credentials — see the `airbyte:` block in [`charts/insight/values.yaml`](../../charts/insight/values.yaml).

## Why separate

See the architecture notes for the full discussion. In short:
- Airbyte is heavy (10+ pods) and its release cadence does not match Insight's
- `helm upgrade` on the umbrella must not reinstall Airbyte every time
- Compatibility matrix: Insight X.Y supports Airbyte 1.4.x–1.6.x — the coupling is loose

## Pinned version

| Component   | Version | Status |
|-------------|---------|--------|
| Chart       | 1.5.1   | supported |
| Application | 1.5.1   | matches chart appVersion |

Upgrades happen in a dedicated PR with regression tests over the ingestion workflows.

## Install (quickstart / eval)

```bash
./deploy/scripts/install-airbyte.sh
```

Or manually:
```bash
helm repo add airbyte https://airbytehq.github.io/helm-charts
helm repo update
helm upgrade --install airbyte airbyte/airbyte \
  --namespace airbyte --create-namespace \
  --version 1.5.1 \
  -f deploy/airbyte/values.yaml \
  --wait --timeout 15m
```

## Install (production)

1. Provision external resources:
   - managed Postgres (RDS / CloudSQL / on-prem) for Airbyte state
   - S3-compatible bucket for logs + state
2. Create Secrets in namespace `airbyte`:
   ```bash
   kubectl create namespace airbyte
   kubectl -n airbyte create secret generic airbyte-db-secret \
     --from-literal=password='...'
   kubectl -n airbyte create secret generic airbyte-s3-creds \
     --from-literal=AWS_ACCESS_KEY_ID='...' \
     --from-literal=AWS_SECRET_ACCESS_KEY='...'
   ```
3. Create an overrides file (see the commented blocks in [`values.yaml`](./values.yaml)) and save as `values-prod.yaml`.
4. Install:
   ```bash
   helm upgrade --install airbyte airbyte/airbyte \
     --namespace airbyte --create-namespace \
     --version 1.5.1 \
     -f deploy/airbyte/values.yaml \
     -f deploy/airbyte/values-prod.yaml \
     --wait --timeout 15m
   ```

## Verify

```bash
# Wait for all pods to be ready
kubectl -n airbyte get pods -w

# UI via port-forward
kubectl -n airbyte port-forward svc/airbyte-airbyte-webapp-svc 8080:80
# → http://localhost:8080

# API reachable
kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8001:8001
curl http://localhost:8001/api/v1/health
```

## Integration with Insight

Insight reaches Airbyte via DNS:
```
http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001
```

These values are already wired into:
- [`src/ingestion/airbyte-toolkit/lib/env.sh`](../../src/ingestion/airbyte-toolkit/lib/env.sh) → `AIRBYTE_API`
- [`charts/insight/files/ingestion/airbyte-sync.yaml`](../../charts/insight/files/ingestion/airbyte-sync.yaml) → default arg
- [`charts/insight/values.yaml`](../../charts/insight/values.yaml) → `airbyte.apiUrl`

**Auth**: the bearer token is a server-signed JWT signed with `AB_JWT_SIGNATURE_SECRET` from the `airbyte-server` pod. See `env.sh` for a ready-made node.js signer. This secret is created automatically by the Airbyte chart; Insight needs to:
1. Read it from the airbyte namespace (RBAC + `kubectl get secret`)
2. Mirror it to the Insight namespace as `airbyte-auth-secrets`

Done once at install time — see [`install-airbyte.sh`](../scripts/install-airbyte.sh).

## Uninstall

```bash
helm -n airbyte uninstall airbyte
kubectl delete namespace airbyte
# PVCs are removed with the namespace
```
