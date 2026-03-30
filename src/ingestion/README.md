# Ingestion Stack

Data pipeline: External APIs → Airbyte → ClickHouse Bronze → dbt → Silver.
Everything runs in a Kubernetes cluster (Kind for local development).

## Concepts

### Insight Connector vs Airbyte Connector

An **Airbyte Connector** knows how to extract data from a specific API:
- `connector.yaml` — declarative manifest (or Docker image for CDK connectors)
- Implements Airbyte Protocol: check, discover, read

An **Insight Connector** is a complete pipeline package built around an Airbyte Connector:

```
Insight Connector = Airbyte Connector + descriptor + dbt transformations + credentials template
```

| Component | Purpose | Who manages |
|-----------|---------|-------------|
| `connector.yaml` | Airbyte manifest — how to extract data | Connector developer |
| `descriptor.yaml` | Schedule, streams, dbt_select, workflow type | Connector developer |
| `credentials.yaml.example` | Template listing required credentials | Connector developer |
| `dbt/` | Bronze → Silver transformations | Connector developer |
| `connections/{tenant}.yaml` | Real credentials per tenant | Tenant admin |

Connector developers create the package. Tenant admins only fill in credentials — they never touch the connector code.

### Credential Separation

Credentials are strictly separated from connector code:

```
connectors/collaboration/m365/            # In repo (shared, read-only for tenants)
  connector.yaml                          #   Airbyte manifest
  descriptor.yaml                         #   Metadata + schedule
  credentials.yaml.example                #   Template: which credentials are needed
  dbt/                                    #   Transformations

connections/                              # Per-tenant credentials
  example-tenant.yaml.example             #   Template (tracked in repo)
  example-tenant.yaml                     #   Real credentials (NEVER committed)
```

One tenant = one file with all credentials for all connectors:

```yaml
# connections/acme-corp.yaml (gitignored — never committed)
tenant_id: acme_corp

connectors:
  m365:
    azure_tenant_id: "63b4c45f-..."
    azure_client_id: "309e3a13-..."
    azure_client_secret: "G2x8Q~..."
  bamboohr:
    api_key: "abc123..."
    subdomain: "acme"
  jira:
    domain: "acme.atlassian.net"
    email: "integration@acme.com"
    api_token: "ATATT3x..."
```

Each connector's `credentials.yaml.example` documents what's required:

```yaml
# connectors/collaboration/m365/credentials.yaml.example
# Required credentials for M365 connector
azure_tenant_id: ""       # Azure AD tenant ID
azure_client_id: ""       # App registration client ID
azure_client_secret: ""   # App registration client secret
```

## Prerequisites

```bash
brew install kind kubectl helm
```

## Quick Start

```bash
# 1. Copy tenant config and fill in credentials
cp connections/example-tenant.yaml.example connections/my-tenant.yaml
# Edit my-tenant.yaml with real API keys

# 2. Start the stack
./up.sh

# 3. Run a sync
./run-sync.sh m365 my-tenant
```

## Commands

### Lifecycle

| Command | Description |
|---------|-------------|
| `./up.sh` | Start all services (idempotent, safe to re-run) |
| `./down.sh` | Stop all services. **Data preserved** |
| `./cleanup.sh` | Delete cluster and all data. Asks for confirmation |

### Day-to-day

| Command | Description |
|---------|-------------|
| `./run-sync.sh <connector> <tenant>` | Run sync + dbt pipeline now |
| `./update-connectors.sh` | Re-upload connector manifests to Airbyte |
| `./update-connections.sh [tenant]` | Re-create sources, destinations, connections |
| `./update-workflows.sh [tenant]` | Regenerate CronWorkflow schedules |

### Examples

```bash
# Run M365 sync for example_tenant
./run-sync.sh m365 example-tenant

# Update after editing connector.yaml
./update-connectors.sh

# Update after changing tenant credentials
./update-connections.sh example-tenant

# Update after changing schedule in descriptor.yaml
./update-workflows.sh

# Monitor workflows
open http://localhost:30500
```

## Services

After `./up.sh`:

| Service | URL | Credentials |
|---------|-----|-------------|
| Airbyte | http://localhost:8000 | Printed by `up.sh` |
| Argo UI | http://localhost:30500 | No auth (local) |
| ClickHouse | http://localhost:30123 | `default` / `clickhouse` |

## Project Structure

```
src/ingestion/
│
├── up.sh / down.sh / cleanup.sh    # Cluster lifecycle
├── run-sync.sh                      # Manual pipeline run
├── update-connectors.sh             # Re-upload manifests
├── update-connections.sh            # Re-apply connections
├── update-workflows.sh              # Regenerate schedules
│
├── connectors/                      # Insight Connector packages
│   └── collaboration/m365/
│       ├── connector.yaml           #   Airbyte declarative manifest
│       ├── descriptor.yaml          #   Schedule, streams, dbt_select
│       ├── credentials.yaml.example #   Credential template (tracked)
│       ├── .env.local               #   Test credentials (gitignored)
│       └── dbt/
│           ├── to_comms_events.sql  #   Bronze → Silver model
│           └── schema.yml           #   Source + tests
│
├── connections/                     # Tenant credential files
│   ├── example-tenant.yaml.example  #   Template (tracked)
│   ├── example-tenant.yaml          #   Real credentials (gitignored)
│   └── .state/                      #   Generated IDs (gitignored)
│
├── dbt/                             # Shared dbt project
│   ├── dbt_project.yml
│   ├── profiles.yml
│   ├── silver/                      #   Union models (class_*)
│   └── macros/                      #   union_by_tag
│
├── workflows/
│   ├── templates/                   #   Argo WorkflowTemplates (tracked)
│   │   ├── airbyte-sync.yaml        #     Trigger sync + poll
│   │   ├── dbt-run.yaml             #     Run dbt in container
│   │   └── ingestion-pipeline.yaml  #     DAG: sync → dbt
│   └── schedules/
│       └── sync.yaml.tpl            #   CronWorkflow template (tracked)
│
├── k8s/                             # Kubernetes manifests
│   ├── kind-config.yaml             #   Kind cluster config
│   ├── airbyte/                     #   Helm values (local + production)
│   ├── argo/                        #   Helm values + RBAC
│   └── clickhouse/                  #   Deployment, Service, PVC, ConfigMap
│
├── scripts/                         # Internal scripts (run inside toolbox)
│   ├── init.sh                      #   Full initialization
│   ├── resolve-airbyte-env.sh       #   JWT token + workspace resolution
│   ├── upload-manifests.sh          #   Register connectors via API
│   ├── apply-connections.sh         #   Create sources/destinations/connections
│   ├── sync-flows.sh               #   Generate + apply CronWorkflows
│   └── wait-for-services.sh        #   kubectl wait for pods
│
└── tools/
    ├── toolbox/                     # insight-toolbox Docker image
    │   ├── Dockerfile               #   python + dbt + kubectl + yq
    │   └── build.sh                 #   Build + load into Kind
    └── declarative-connector/       # Local connector debugging
        └── source.sh               #   check / discover / read
```

## Adding a New Connector

1. Create the Insight Connector package:
   ```
   connectors/{category}/{name}/
     connector.yaml            # Airbyte manifest
     descriptor.yaml           # name, schedule, streams, dbt_select, workflow
     credentials.yaml.example  # Required credentials (template)
     dbt/
       to_{domain}.sql         # Transformation
       schema.yml              # Source definition + tests
   ```

2. Add credentials to tenant config:
   ```yaml
   # connections/my-tenant.yaml
   connectors:
     new_connector:
       api_key: "..."
   ```

3. Deploy:
   ```bash
   ./update-connectors.sh
   ./update-connections.sh my-tenant
   ./update-workflows.sh my-tenant
   ```

## Adding a New Tenant

1. Copy example config:
   ```bash
   cp connections/example-tenant.yaml.example connections/acme.yaml
   ```

2. Fill in credentials and set `tenant_id: acme`

3. Deploy:
   ```bash
   ./update-connections.sh acme
   ./update-workflows.sh acme
   ```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `ENV` | `local` | `local` (Kind) or `production` (existing K8s cluster) |
| `KUBECONFIG` | `~/.kube/kind-ingestion` | Path to kubeconfig |
| `TOOLBOX_IMAGE` | `insight-toolbox:local` | Docker image for toolbox |
