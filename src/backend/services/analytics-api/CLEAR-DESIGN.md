# Analytics API — Service Design

## 1. What It Does

Read-only API over predefined ClickHouse views (Silver/Gold materialized views). Users query metrics and analytics data scoped to their org unit and membership period. No writes to ClickHouse.

The service does NOT expose raw ClickHouse tables. Instead, it serves **views** — predefined SQL queries stored in MariaDB. Each view has an ID, human-readable name, and a stored ClickHouse query. The frontend references views by ID, never by table name.

## 2. Views

A view is a predefined, admin-configured SQL query against ClickHouse. Stored in MariaDB.

### MariaDB schema: `views`

```sql
id                UUID NOT NULL DEFAULT uuid_v7() PRIMARY KEY,
insight_tenant_id UUID NOT NULL,
name              VARCHAR(255) NOT NULL,          -- "PR Cycle Time", "Commit Activity"
description       TEXT,                           -- human-readable purpose
clickhouse_table  VARCHAR(255) NOT NULL,          -- "gold.pr_cycle_time"
base_query        TEXT NOT NULL,                  -- "SELECT person_id, avg_hours, metric_date FROM gold.pr_cycle_time"
is_enabled        BOOL NOT NULL DEFAULT TRUE,
created_at        DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
updated_at        DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
```

`base_query` is the SELECT statement that the service appends WHERE/ORDER BY/LIMIT to. It defines which columns are available and from which table. The service never constructs the SELECT clause from user input.

### MariaDB schema: `table_columns`

Catalog of available columns in Silver/Gold ClickHouse tables. Seeded by initial migration with known tables. Admins reference this when creating views.

```sql
id                UUID NOT NULL DEFAULT uuid_v7() PRIMARY KEY,
insight_tenant_id UUID NULL,                      -- NULL = available to all tenants, UUID = tenant-specific custom field
clickhouse_table  VARCHAR(255) NOT NULL,          -- "gold.pr_cycle_time", "silver.class_commits"
field_name        VARCHAR(255) NOT NULL,          -- "avg_hours", "person_id", "metric_date"
field_description TEXT,                           -- "Average PR cycle time in hours"
created_at        DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
updated_at        DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),

UNIQUE KEY uq_tenant_table_field (insight_tenant_id, clickhouse_table, field_name)
```

`insight_tenant_id = NULL` — shared columns from standard dbt models, visible to all tenants. Seeded by migration.

`insight_tenant_id = UUID` — tenant-specific custom fields from custom connectors or transforms. Created by Tenant Admin.

When listing columns for a tenant, query: `WHERE insight_tenant_id IS NULL OR insight_tenant_id = ?`.

### No predefined views

Views are created by admins after connectors are configured and dbt models produce Silver/Gold tables. The `views` table starts empty. Admins use the `table_columns` catalog to see what's available when building views.

## 3. Endpoints

All endpoints below are service-local paths. The API Gateway mounts this service at `/api/analytics`, so the full URL is e.g. `/api/analytics/v1/views`.

### List available views

```
GET /v1/views
```

Returns all enabled views for the tenant. No auth scope filtering — just the catalog.

```json
{
  "items": [
    { "id": "uuid", "name": "PR Cycle Time", "description": "..." },
    { "id": "uuid", "name": "Commit Activity", "description": "..." }
  ]
}
```

### Query a view

```
POST /v1/views/{view_id}/query
```

```json
{
  "filters": {
    "date_from": "2026-01-01",
    "date_to": "2026-04-01",
    "person_ids": ["uuid1", "uuid2"]
  },
  "order_by": "metric_date",
  "order_dir": "desc",
  "limit": 25,
  "cursor": null
}
```

**Response**:

```json
{
  "items": [
    { "person_id": "...", "avg_hours": 4.2, "metric_date": "2026-03-15" }
  ],
  "page_info": {
    "has_next": true,
    "cursor": "eyJ..."
  }
}
```

### Available filters

| Filter | Type | Description |
|--------|------|-------------|
| `date_from` | Date (ISO-8601) | Start of date range (inclusive). Applied to the date column in the view. |
| `date_to` | Date (ISO-8601) | End of date range (exclusive). |
| `person_ids` | Array of UUID | Insight person IDs (from Identity Resolution golden records). Resolved to source-specific identifiers before querying ClickHouse. Optional — if empty, returns all visible persons. |

### Available ordering

| Field | Description |
|-------|-------------|
| `metric_date` | Order by date column |
| `person_id` | Order by person |
| Any aggregated column | e.g., `avg_hours`, `pr_count`, `reviews_count` — validated against view's columns |

Direction: `asc` or `desc`. Default: `desc`.

### Pagination

Cursor-based. Default limit 25, max 200. Response includes `page_info.cursor` for next page.

## 4. Query Execution

The service builds the final ClickHouse query by combining:

1. **Base query** from the view definition (stored in MariaDB)
2. **Security filters** injected automatically (never user-controlled):
   - `insight_tenant_id = ?` — from JWT SecurityContext
   - `org_unit_id IN (?, ?, ?)` — from AuthZ AccessScope
   - Date range from org membership `effective_from`/`effective_to`
3. **User filters** from the request body (validated and parameterized)
4. **ORDER BY** (validated against view's columns)
5. **LIMIT / OFFSET** (cursor-decoded)

### Person ID resolution

When `person_ids` filter is provided, the service resolves Insight person IDs to source-specific identifiers before querying ClickHouse:

```
Frontend sends: person_ids: ["insight-person-uuid-1"]
    → Analytics API calls Identity Resolution: "give me all aliases for person uuid-1"
    → Identity Resolution returns: ["email@company.com", "email@opensource.com", "github-user-42"]
    → Analytics API queries ClickHouse with source-level identifiers
```

This is necessary because Silver tables may not have a unified `person_id` column — they have source-native identifiers (email, username, account ID). Identity Resolution knows the mapping.

Responses are **cached in Redis** (TTL: 5 minutes) to avoid calling Identity Resolution on every query. Cache is invalidated when Identity Resolution publishes merge/split events via Redpanda.

### Final query

```sql
-- base_query from view definition
SELECT person_id, org_unit_id, avg_hours, pr_count, metric_date
FROM gold.pr_cycle_time
-- security filters (always injected)
WHERE insight_tenant_id = ?
  AND (org_unit_id IN (?, ?))
  AND (metric_date >= ? AND metric_date < ?)
-- user filters (person resolved via Identity Resolution)
  AND (source_account_id IN (?, ?, ?))
-- ordering
ORDER BY metric_date DESC
LIMIT 26  -- limit+1 to detect has_next
```

All values are bind parameters. No string interpolation.

**Note**: Gold tables that already have a resolved `person_id` column (from Silver step 2) can be filtered directly by `person_id` without Identity Resolution lookup. The service checks whether the view's table has a `person_id` column or uses source-native identifiers.

## 5. Authentication and Inter-Service Trust

### Browser → Backend auth flow

Frontend is a React SPA. Authentication uses OIDC Authorization Code flow with PKCE:

1. Frontend fetches `/api/analytics/v1/auth/config` → gets Okta issuer, client_id, redirect_uri
2. Frontend redirects user to Okta login page
3. User logs in → Okta redirects back with authorization code
4. Frontend exchanges code for tokens (access_token, id_token, refresh_token)
5. Frontend stores access_token in memory (not localStorage — XSS risk)
6. Frontend sends `Authorization: Bearer <access_token>` on every API call
7. On 401 → frontend uses refresh_token or redirects to Okta again

Okta cookies are on `*.okta.com` — our app can't read them. They only provide SSO (user doesn't re-enter password on next Okta redirect).

**MVP**: Bearer token approach. Stateless backend, standard REST.
**Future**: BFF (Backend For Frontend) pattern — thin proxy handles OIDC flow, sets HTTP-only cookie, tokens never touch JavaScript. More secure for production.

### Inter-service auth

Three separate services (API Gateway, Analytics API, Identity Resolution) run as separate K8s pods.

**MVP**: API Gateway validates JWT, forwards the original `Authorization: Bearer` header to downstream services. Each downstream service validates the same JWT independently (same OIDC plugin, same JWKS keys). No trust in internal headers — every service verifies the token.

**Why not cyberfabric's gRPC SecurityContext propagation**: cyberfabric's pattern (`x-secctx-bin` via gRPC hub) assumes modules run in the same process or on a trusted Unix domain socket. Our services are separate pods on a K8s network — we can't trust serialized headers without re-validation.

```
Browser → API Gateway (validates JWT, reverse proxy) → Analytics API (validates JWT again)
                                                     → Identity Resolution (validates JWT again)
```

### API Gateway as reverse proxy

The API Gateway is the single entry point for all frontend traffic. It validates JWT, then proxies requests to downstream services by path prefix. Configured in YAML:

```yaml
modules:
  api-gateway:
    config:
      routes:
        - prefix: "/api/analytics"
          upstream: "http://analytics-api:8080"
        - prefix: "/api/identity-resolution"
          upstream: "http://identity-resolution:8080"
```

The gateway strips the prefix, forwards the request with the original `Authorization: Bearer` header, and returns the upstream response. Each downstream service validates the JWT independently.

This design prepares for the BFF pattern: when we add session cookies and server-side OIDC flow, the gateway already handles all inbound traffic — we just extend it with cookie/token management instead of introducing a new proxy layer.

### What Analytics API reads

| Source | Field | Used for |
|--------|-------|----------|
| SecurityContext | `subject_id` | Audit logging |
| SecurityContext | `subject_tenant_id` | `insight_tenant_id` filter |
| AccessScope (from AuthZ) | `visible_org_unit_ids` | `org_unit_id IN (...)` filter |
| AccessScope (from AuthZ) | `effective_from/to per unit` | Date range filter per org membership |

The user's request filters are **ANDed** with security filters. The user can narrow their view but never widen it beyond their org scope.

### Person ID mapping

Frontend works with Insight person IDs (golden records from Identity Resolution). ClickHouse tables may have:
- **Gold tables (step 2)**: already have `person_id` — can filter directly
- **Silver tables (step 1)**: have source-native identifiers only (email, username) — need Identity Resolution lookup to map Insight person ID → source aliases

The Analytics API handles this transparently. Frontend always sends Insight person IDs.

Identity Resolution responses are cached in Redis (key: `person_aliases:{insight_tenant_id}:{person_id}`, TTL: 5 min). Cache invalidated on merge/split events from Redpanda (`insight.identity.resolved` topic).

If frontend needs person details (name, email) for display, it calls the Identity Resolution API directly — not through Analytics API.

## 6. View Management

Views must be created before anything can be queried. RBAC: Viewer/Analyst can list and query views. Only Tenant Admin can create/update/delete.

```
POST   /v1/views          — create view (Tenant Admin)
PUT    /v1/views/{id}     — update view
DELETE /v1/views/{id}     — soft-delete view (sets is_enabled = false)
```

## 7. Multi-Tenant OIDC

Each tenant may use a different OIDC provider (Okta, Keycloak, Auth0, own IdP).

**MVP**: Single issuer in YAML config. All tenants use the same IdP.

**Next**: Multiple issuers in static config. OIDC plugin holds a list of trusted issuers, each mapped to a `insight_tenant_id`:

```yaml
issuers:
  - issuer_url: "https://tenant-a.okta.com/oauth2/default"
    insight_tenant_id: "uuid-tenant-a"
    audience: "api://insight"
  - issuer_url: "https://tenant-b.auth0.com/"
    insight_tenant_id: "uuid-tenant-b"
    jwks_url: "https://tenant-b.auth0.com/.well-known/jwks.json"
```

Flow: decode JWT `iss` claim (unvalidated peek) → find matching issuer → validate with that issuer's JWKS keys → map to `insight_tenant_id`. Each issuer gets its own cached `JwksKeyProvider`.

**Future**: Issuer registry in MariaDB. Tenant Admin configures their IdP through UI. Plugin reloads on change. Enables self-service tenant onboarding without redeployment.
