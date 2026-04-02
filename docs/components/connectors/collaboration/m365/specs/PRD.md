# PRD — Microsoft 365 Connector


<!-- toc -->

- [1. Overview](#1-overview)
  - [1.1 Purpose](#11-purpose)
  - [1.2 Background / Problem Statement](#12-background--problem-statement)
  - [1.3 Goals (Business Outcomes)](#13-goals-business-outcomes)
  - [1.4 Glossary](#14-glossary)
- [2. Actors](#2-actors)
  - [2.1 Human Actors](#21-human-actors)
  - [2.2 System Actors](#22-system-actors)
- [3. Operational Concept & Environment](#3-operational-concept--environment)
  - [3.1 Module-Specific Environment Constraints](#31-module-specific-environment-constraints)
- [4. Scope](#4-scope)
  - [4.1 In Scope](#41-in-scope)
  - [4.2 Out of Scope](#42-out-of-scope)
- [5. Functional Requirements](#5-functional-requirements)
  - [5.1 Activity Data Extraction](#51-activity-data-extraction)
  - [5.2 Connector Operations](#52-connector-operations)
  - [5.3 Data Integrity](#53-data-integrity)
  - [5.4 Identity Resolution](#54-identity-resolution)
- [6. Non-Functional Requirements](#6-non-functional-requirements)
  - [6.1 NFR Inclusions](#61-nfr-inclusions)
  - [6.2 NFR Exclusions](#62-nfr-exclusions)
- [7. Public Library Interfaces](#7-public-library-interfaces)
  - [7.1 Public API Surface](#71-public-api-surface)
  - [7.2 External Integration Contracts](#72-external-integration-contracts)
- [8. Use Cases](#8-use-cases)
- [9. Acceptance Criteria](#9-acceptance-criteria)
- [10. Dependencies](#10-dependencies)
- [11. Assumptions](#11-assumptions)
- [12. Risks](#12-risks)

<!-- /toc -->

## 1. Overview

### 1.1 Purpose

The Microsoft 365 Connector extracts per-user, per-day activity data from Microsoft Graph API Report endpoints and loads it into the Insight platform's Bronze layer. It covers five product areas — Email, Teams, OneDrive, SharePoint, and Copilot — providing a comprehensive view of how an organization uses the Microsoft 365 suite.

### 1.2 Background / Problem Statement

Microsoft 365 is the primary collaboration platform for most enterprise organizations. Understanding how employees use Email, Teams, OneDrive, SharePoint, and Copilot is essential for measuring collaboration patterns, identifying engagement trends, and evaluating AI tool adoption.

The Microsoft Graph API provides per-user activity reports through dedicated endpoints. Each endpoint supports two request modes:

- **Per-date** (`date=YYYY-MM-DD`) — returns per-user activity for a specific date. This is the recommended mode and the most granular option. Data is available for dates within the **last 30 days**; older dates return an error.
- **Per-period** (`period=D7|D30|D90|D180`) — returns aggregated activity over a rolling window. Less granular; one row per user for the entire period.

The connector uses the **per-date mode** as recommended by Microsoft for daily-granularity reporting. Since data is available for only the last 30 days, records cannot be re-fetched once they fall outside this window. **Data loss is permanent** if the connector does not run frequently enough.

**Target Users**:

- Platform operators who configure M365 tenant credentials and stream selection
- Data analysts who consume M365 activity data in Silver/Gold layers
- Organization leaders who use communication and collaboration metrics for decision-making

**Key Problems Solved**:

- Continuous extraction of M365 activity data before the API retention window expires
- Unified per-user activity view across five M365 product areas
- Identity-resolved activity data that can be joined with other source systems via `userPrincipalName`

### 1.3 Goals (Business Outcomes)

**Success Criteria**:

- All five activity streams extracted with zero data gaps over a 90-day period (Baseline: no extraction; Target: v1.0)
- Per-user activity records available for identity resolution within 24 hours of report availability (Baseline: N/A; Target: v1.0)
- Copilot usage data captured from day one of tenant enablement (Baseline: N/A; Target: v1.0)

**Capabilities**:

- Extract per-user daily activity for Email, Teams, OneDrive, SharePoint, and Copilot
- Incremental extraction using date-based cursor to avoid re-fetching
- Identity resolution via `userPrincipalName` (UPN / corporate email)

### 1.4 Glossary


| Term                      | Definition                                                                                                                                                 |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Microsoft Graph API       | Microsoft's unified REST API for accessing Microsoft 365 data. Report endpoints under `/reports/get*ActivityUserDetail` provide per-user activity metrics. |
| Report Refresh Date       | The date for which activity data is reported (`reportRefreshDate`). Each record represents one user's activity on one date.                                |
| Data Retention Window     | In per-date mode, the Graph API returns data for dates within the last 30 days only. Older records are permanently unavailable. In per-period mode, aggregated data is available for D7, D30, D90, D180 windows. |
| UPN (User Principal Name) | The `userPrincipalName` field — typically the user's corporate email address. Used as the identity key across all M365 streams.                            |
| Bronze Table              | Raw data table in the destination, preserving source-native field names and types without transformation.                                                  |
| Copilot                   | Microsoft 365 Copilot — AI assistant integrated into Office apps (Teams, Word, Excel, PowerPoint, Outlook, OneNote, Loop).                                 |


## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-insightspec-actor-m365-operator`

**Role**: Registers the M365 Azure AD application, provides tenant credentials (tenant ID, client ID, client secret), selects streams, and monitors extraction runs.
**Needs**: Ability to configure the connector with M365 credentials and verify that data is flowing correctly for all enabled streams.

#### Data Analyst

**ID**: `cpt-insightspec-actor-m365-analyst`

**Role**: Consumes M365 activity data from Silver/Gold layers to build dashboards and reports on collaboration patterns, communication metrics, and AI tool adoption.
**Needs**: Complete, gap-free activity data across all M365 product areas with identity resolution to canonical person IDs.

### 2.2 System Actors

#### Microsoft Graph API

**ID**: `cpt-insightspec-actor-graph-api`

**Role**: External REST API providing per-user activity reports. Enforces rate limits, requires OAuth2 client credentials, and retains data for 7–30 days only.

#### Identity Manager

**ID**: `cpt-insightspec-actor-identity-manager`

**Role**: Resolves `userPrincipalName` from M365 Bronze tables to canonical `person_id` in Silver step 2. Enables cross-system joins (M365 + Jira + GitHub + Slack, etc.).

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

- Requires an Azure AD application registration with `Reports.Read.All` permission (application-level, not delegated)
- The M365 tenant must have the relevant licenses for each product area (e.g., Copilot license for `copilot_usage` stream)
- The connector **MUST** run at least every 7 days to avoid data loss due to the 30-day Graph API retention window. Recommended: daily.
- Microsoft Graph API enforces throttling at approximately 5 requests per second for report endpoints

## 4. Scope

### 4.1 In Scope

- Extraction of per-user daily activity from 5 M365 product areas: Email, Teams, OneDrive, SharePoint, Copilot
- Connector execution monitoring via collection runs stream
- Incremental sync using `reportRefreshDate` as cursor
- Identity resolution via `userPrincipalName`
- Bronze-layer table schemas for all 6 streams

### 4.2 Out of Scope

- Silver/Gold layer transformations — responsibility of the collaboration domain pipeline
- Real-time streaming — this connector operates in batch mode (daily reports)
- Individual message or file content extraction — only aggregate activity counts
- M365 Admin / Compliance / Security center data
- Azure AD user provisioning or directory sync

## 5. Functional Requirements

### 5.1 Activity Data Extraction

#### Extract Email Activity

- [ ] `p1` - **ID**: `cpt-insightspec-fr-m365-email-activity`

The connector **MUST** extract per-user daily email activity from the `getEmailActivityUserDetail` endpoint, including: send count, receive count, read count, meeting interactions, and last activity date.

**Rationale**: Email remains the primary formal communication channel. Send/receive/read counts are core inputs to communication metrics.

**Actors**: `cpt-insightspec-actor-graph-api`, `cpt-insightspec-actor-m365-analyst`

#### Extract Teams Activity

- [ ] `p1` - **ID**: `cpt-insightspec-fr-m365-teams-activity`

The connector **MUST** extract per-user daily Teams activity from the `getTeamsUserActivityUserDetail` endpoint, including: chat messages (team + private), channel posts/replies, call count, meeting counts (organized/attended, ad-hoc/scheduled/recurring), audio/video/screen-share duration, and urgent messages.

**Rationale**: Teams is the primary real-time collaboration tool. Chat, meeting, and call metrics are essential for understanding collaboration intensity and patterns.

**Actors**: `cpt-insightspec-actor-graph-api`, `cpt-insightspec-actor-m365-analyst`

#### Extract OneDrive Activity

- [ ] `p1` - **ID**: `cpt-insightspec-fr-m365-onedrive-activity`

The connector **MUST** extract per-user daily OneDrive activity from the `getOneDriveActivityUserDetail` endpoint, including: files viewed/edited, files synced, files shared internally and externally.

**Rationale**: OneDrive usage indicates individual file management and sharing patterns.

**Actors**: `cpt-insightspec-actor-graph-api`, `cpt-insightspec-actor-m365-analyst`

#### Extract SharePoint Activity

- [ ] `p1` - **ID**: `cpt-insightspec-fr-m365-sharepoint-activity`

The connector **MUST** extract per-user daily SharePoint activity from the `getSharePointActivityUserDetail` endpoint, including: files viewed/edited, pages visited, files synced, files shared internally and externally.

**Rationale**: SharePoint usage indicates team-level document collaboration and knowledge sharing.

**Actors**: `cpt-insightspec-actor-graph-api`, `cpt-insightspec-actor-m365-analyst`

#### Extract Copilot Usage

- [ ] `p2` - **ID**: `cpt-insightspec-fr-m365-copilot-usage`

The connector **MUST** extract per-user daily Copilot usage from the `getMicrosoft365CopilotUsageUserDetail` endpoint, including: per-app last activity dates and per-app action counts for Teams, Word, Excel, PowerPoint, OneNote, Outlook, Loop, and Copilot Chat.

**Rationale**: Copilot adoption is a key metric for organizations investing in AI productivity tools. Per-app granularity enables tracking which Office apps see the most AI-assisted usage.

**Actors**: `cpt-insightspec-actor-graph-api`, `cpt-insightspec-actor-m365-analyst`

**Verification Method**: Requires a tenant with Microsoft 365 Copilot license. Schema proposed from Graph API naming conventions — field names must be verified against the live endpoint.

### 5.2 Connector Operations

#### Track Collection Runs

- [ ] `p2` - **ID**: `cpt-insightspec-fr-m365-collection-runs`

The connector **MUST** produce a collection run log entry for each execution, recording: run ID, start/end time, status, per-stream record counts, API call count, and error count.

**Rationale**: Operational visibility into connector health. Enables alerting on failed runs before the data retention window expires.

**Actors**: `cpt-insightspec-actor-m365-operator`

### 5.3 Data Integrity

#### Prevent Data Loss from Retention Window

- [ ] `p1` - **ID**: `cpt-insightspec-fr-m365-retention-guard`

The connector **MUST** be scheduled to run at least every 7 days. If the time since the last successful run exceeds 7 days, the system **SHOULD** emit a warning. If it exceeds 30 days, the system **MUST** emit an error indicating that the oldest data has been permanently lost.

**Rationale**: In per-date mode, the Graph API returns data for dates within the last 30 days only. Missing the window means permanent data loss with no recovery option. The 7-day warning threshold provides a safety margin.

**Actors**: `cpt-insightspec-actor-m365-operator`

#### Deduplicate by Composite Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-m365-deduplication`

Each stream **MUST** use a composite primary key of `userPrincipalName + reportRefreshDate` (materialized as `unique_key`) to ensure that re-running the connector for an overlapping date range does not produce duplicate records.

**Rationale**: The incremental sync window may overlap with previously fetched dates. Deduplication ensures idempotent extraction.

**Actors**: `cpt-insightspec-actor-graph-api`

### 5.4 Identity Resolution

#### Expose Identity Key

- [ ] `p1` - **ID**: `cpt-insightspec-fr-m365-identity-key`

All activity streams **MUST** include `userPrincipalName` as a non-null identity field. This field is used by the Identity Manager to resolve M365 users to canonical `person_id` values in the Silver layer.

**Rationale**: Cross-system identity resolution is the foundation of the Insight platform's analytics. The UPN (corporate email) is a reliable, stable identifier across M365 and most enterprise systems.

**Actors**: `cpt-insightspec-actor-identity-manager`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Data Freshness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-m365-freshness`

The connector **MUST** deliver activity data to the Bronze layer within 24 hours of the report becoming available in the Graph API.

**Threshold**: Data available in Bronze ≤ 24h after Graph API report date.

**Rationale**: Timely data enables near-real-time dashboards. The Graph API typically publishes reports with a 2–3 day lag; the connector adds at most 24 hours on top.

#### Extraction Completeness

- [ ] `p1` - **ID**: `cpt-insightspec-nfr-m365-completeness`

The connector **MUST** extract 100% of users reported by the Graph API for each enabled stream on each run, with zero record loss.

**Threshold**: Records extracted = records available in API (per stream, per date).

**Rationale**: Partial extraction leads to incorrect per-user and aggregate metrics.

### 6.2 NFR Exclusions

- **Throughput / latency**: Not applicable — Graph API report endpoints are low-volume (one record per user per day). Typical tenants produce < 100K records per run.
- **Availability**: Batch connector — availability is determined by the orchestrator's scheduling, not by this connector.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### M365 Stream Contract

- [ ] `p1` - **ID**: `cpt-insightspec-interface-m365-streams`

**Type**: Data format (Bronze table schemas)

**Stability**: stable

**Description**: Six Bronze streams with defined schemas — `email_activity`, `teams_activity`, `onedrive_activity`, `sharepoint_activity`, `copilot_usage`, `collection_runs`. Each activity stream shares the identity key `userPrincipalName` and cursor field `reportRefreshDate`.

**Breaking Change Policy**: Adding new fields is non-breaking. Removing or renaming fields requires a migration.

### 7.2 External Integration Contracts

#### Microsoft Graph API Reports

- [ ] `p1` - **ID**: `cpt-insightspec-contract-m365-graph-api`

**Direction**: required from external system

**Protocol/Format**: REST / JSON (`GET /reports/get*ActivityUserDetail(date=YYYY-MM-DD)`)

**Compatibility**: Microsoft Graph API v1.0 / beta. Report endpoints return JSON with OData pagination (`@odata.nextLink`). Response format is stable; field additions are non-breaking.

## 8. Use Cases

#### Configure M365 Connection

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-m365-configure`

**Actor**: `cpt-insightspec-actor-m365-operator`

**Preconditions**:

- Azure AD application registered with `Reports.Read.All` permission
- Tenant admin has granted consent

**Main Flow**:

1. Operator provides tenant ID, client ID, client secret
2. System validates credentials against the Graph API
3. System discovers available streams (depends on tenant licenses)
4. Operator selects streams to enable
5. System initializes the connection with empty state

**Postconditions**:

- Connection is ready for first sync run

**Alternative Flows**:

- **Missing Copilot license**: `copilot_usage` stream is not available in the catalog; operator configures only the 4 base streams
- **Invalid credentials**: System reports authentication failure; operator corrects credentials

#### Daily Incremental Sync

- [ ] `p1` - **ID**: `cpt-insightspec-usecase-m365-daily-sync`

**Actor**: `cpt-insightspec-actor-m365-operator`

**Preconditions**:

- Connection configured and credentials valid
- Previous state available (or empty for first run)

**Main Flow**:

1. Orchestrator triggers the connector with current state
2. Connector fetches reports for each enabled stream from the last cursor date to today minus 3 days
3. For each stream: paginate through all users, emit records with `unique_key` = `userPrincipalName + reportRefreshDate`
4. Updated cursor positions captured after successful write
5. Collection run log entry written

**Postconditions**:

- Bronze tables contain new activity records
- State updated with latest `reportRefreshDate` per stream
- Collection run log records success/failure

**Alternative Flows**:

- **First run**: Connector extracts from 27 days ago (maximum lookback)
- **API throttling**: Connector retries with backoff (handled by CDK)
- **Stream failure**: Failed stream does not update its cursor; other streams succeed independently

## 9. Acceptance Criteria

- All 4 base streams (email, teams, onedrive, sharepoint) extract data from a live M365 tenant
- Copilot stream extracts data from a tenant with Copilot license (or is gracefully skipped without)
- Incremental sync on second run extracts only new dates (no duplicates)
- No data gaps over a 30-day continuous operation period
- `userPrincipalName` is present and non-null in every activity record
- Collection run log records success, record counts, and timing for each run

## 10. Dependencies


| Dependency                                  | Description                                           | Criticality |
| ------------------------------------------- | ----------------------------------------------------- | ----------- |
| Microsoft Graph API                         | Report endpoints for activity data                    | `p1`        |
| Azure AD application                        | OAuth2 client credentials for authentication          | `p1`        |
| Airbyte Declarative Connector framework     | Execution model for running the connector             | `p1`        |
| Identity Manager                            | Resolves `userPrincipalName` to `person_id` in Silver | `p2`        |
| Destination store (PostgreSQL / ClickHouse) | Target for Bronze tables                              | `p1`        |


## 11. Assumptions

- The M365 tenant has active user licenses for the product areas being monitored
- Azure AD application consent has been granted by a tenant administrator
- The Graph API report endpoint response format remains stable across minor API versions
- `userPrincipalName` is a stable, non-null field across all report endpoints
- Report data lag is typically 2–3 days (data for today is not yet available)

## 12. Risks


| Risk                                              | Impact                                                | Mitigation                                                        |
| ------------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------------- |
| Data retention window exceeded                    | Permanent loss of activity data for the missed period | Schedule connector to run daily; alert if last run > 5 days ago   |
| Copilot endpoint schema differs from proposed     | `copilot_usage` stream fails or captures wrong fields | Verify schema against live endpoint before enabling; mark as `p2` |
| Microsoft changes report endpoint response format | Extraction breaks silently                            | Pin to specific API version; monitor for deprecation notices      |
| Tenant admin revokes app consent                  | All streams fail                                      | Monitor collection run status; alert on authentication failures   |
| API throttling under large tenants                | Extraction takes longer; risk of timeout              | CDK handles retry with backoff; pagination ensures no data loss   |


