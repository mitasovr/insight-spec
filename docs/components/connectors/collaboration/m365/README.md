# Microsoft 365 Connector

Extracts per-user daily activity data from Microsoft Graph API Report endpoints: Email, Teams, OneDrive, SharePoint, and Copilot.

## Documents

| Document | Description |
|---|---|
| [`specs/PRD.md`](specs/PRD.md) | Product requirements: 6 streams, identity resolution, data retention constraints, acceptance criteria |
| [`specs/DESIGN.md`](specs/DESIGN.md) | Technical design: Graph API endpoints, OAuth2 auth, Bronze table schemas, incremental sync, Silver/Gold mappings |

## Scope

- 5 activity streams: `email_activity`, `teams_activity`, `onedrive_activity`, `sharepoint_activity`, `copilot_usage`
- 1 monitoring stream: `collection_runs`
- Identity key: `userPrincipalName` (UPN / corporate email)
- Incremental sync via `reportRefreshDate` cursor
- Critical: API returns only 7–30 days of data — connector must run at least weekly

## Source Documents

- `docs/components/connectors/collaboration/README.md` — collaboration domain specification
