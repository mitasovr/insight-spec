# PRD — Orchestrator

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
  - [5.1 DAG & Task Management](#51-dag--task-management)
  - [5.2 Scheduling](#52-scheduling)
  - [5.3 Runner Management](#53-runner-management)
  - [5.4 Task Configuration & Validation](#54-task-configuration--validation)
  - [5.5 Execution Protocol](#55-execution-protocol)
  - [5.6 Secret Management](#56-secret-management)
  - [5.7 Observability API](#57-observability-api)
  - [5.8 Multi-tenancy & Authorization](#58-multi-tenancy--authorization)
  - [5.9 Error Handling](#59-error-handling)
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

The Orchestrator is a centralized task execution engine for the Insight platform that manages scheduling, dependency resolution, and distributed execution of data pipeline tasks. It coordinates connectors (data ingestion), dbt transformations, and other extensible task types across a fleet of runners.

The Orchestrator eliminates manual pipeline coordination by providing DAG-based dependency management, flexible scheduling, secure credential delivery, and a unified observability API for monitoring all pipeline activity across tenants.

### 1.2 Background / Problem Statement

The Insight platform currently lacks a centralized mechanism to coordinate task execution across its data pipeline. Teams manually sequence connector runs and dbt transformations, verify completion before triggering dependent steps, and distribute work to available compute resources without automated matching. This manual coordination consumes significant engineering time and introduces reliability risks when steps are missed or misordered.

Without dependency management, tasks that depend on upstream outputs may execute before their inputs are ready, producing incomplete or incorrect results. There is no centralized scheduling — teams rely on external cron jobs or manual triggers with no visibility into cross-task timing constraints. Runner allocation is ad-hoc, with no mechanism to match tasks to appropriately tagged runners or detect runner failures.

Additionally, the platform serves multiple tenants but has no unified orchestration layer that enforces tenant isolation, provides per-tenant observability, or manages credentials securely. Operators lack a single API to inspect DAG state, review run history, or diagnose failures across the pipeline.

### 1.3 Goals (Business Outcomes)

- **Eliminate manual pipeline coordination**: Reduce daily manual task sequencing effort from ~2 hours/day per team to zero through automated DAG-based dependency resolution.
- **Ensure correct execution order**: Achieve 100% adherence to declared task dependencies — no task executes before all its upstream dependencies have completed successfully.
- **Centralize scheduling**: Consolidate all task schedules (cron, interval, manual) into a single system, replacing scattered external cron jobs within 3 months of deployment.
- **Improve failure visibility**: Provide operators with full run history, failure details, and runner status via API, reducing mean time to diagnose pipeline failures from ~30 minutes to under 5 minutes.
- **Enable secure multi-tenancy**: Support both logical and physical tenant isolation with SSO integration, ensuring zero cross-tenant data leakage from day one.

### 1.4 Glossary

| Term | Definition |
|------|------------|
| DAG | Directed Acyclic Graph — a set of tasks with declared dependencies that define execution order. |
| Task | A unit of work managed by the orchestrator (e.g., a connector run, a dbt transformation). |
| Runner | A long-lived process that connects to the orchestrator, receives task assignments, and executes them. |
| Tenant | An isolated organizational unit within the platform; each tenant has its own tasks, runners, and data. |
| Job | A single execution instance of a task, including its configuration, status, and output. |
| Schedule | A timing rule that determines when a task should execute — either a cron expression or an interval since last completion. |
| Tag | A label applied to both tasks and runners to control affinity — tagged tasks are assigned only to runners with matching tags; untagged tasks go to untagged runners. |
| Execution Protocol | The structured JSON-per-line output format used by runners to communicate results back to the orchestrator (message types: LOG, STATE, METRIC, RESULT, PROGRESS). |

## 2. Actors

### 2.1 Human Actors

#### Platform Operator

**ID**: `cpt-orch-actor-platform-operator`

**Role**: Monitors and manages the orchestrator and its runners. Responsible for operational health, investigating failures, and managing runner infrastructure.
**Needs**: Real-time visibility into DAG execution state, run history, runner health, and failure diagnostics. Ability to manually trigger tasks and inspect detailed run logs.

#### Data Engineer

**ID**: `cpt-orch-actor-data-engineer`

**Role**: Defines and maintains task configurations (connector configs, dbt project references, DAG definitions). Pushes configuration changes via CI pipelines or API.
**Needs**: Ability to declare task dependencies, set schedules, validate configurations before deployment, and verify that changes are applied correctly.

#### Tenant Administrator

**ID**: `cpt-orch-actor-tenant-admin`

**Role**: Manages tenant-level settings, user access, and RBAC policies within their tenant boundary.
**Needs**: Ability to configure tenant isolation mode, manage SSO integration, and assign roles (admin, operator, viewer) to users within the tenant.

### 2.2 System Actors

#### Runner

**ID**: `cpt-orch-actor-runner`

**Role**: A long-lived process that registers with the orchestrator, receives task assignments via the message queue, fetches full task payloads (configuration, secrets, state) via the authenticated API, executes tasks, and reports results using the execution protocol.

#### CI Pipeline

**ID**: `cpt-orch-actor-ci-pipeline`

**Role**: An automated pipeline (e.g., triggered by git push) that pushes task configuration updates to the orchestrator via API, triggering validation and deployment of new or modified task definitions.

#### Message Queue Service

**ID**: `cpt-orch-actor-message-queue`

**Role**: Handles task assignment delivery from the orchestrator to runners. Carries only task identifiers — no secrets or sensitive payloads.

#### Secret Vault

**ID**: `cpt-orch-actor-secret-vault`

**Role**: External credential storage system that the orchestrator integrates with to retrieve secrets on behalf of runners. Secrets are delivered to runners only through the orchestrator's authenticated API.

#### Persistent Storage Service

**ID**: `cpt-orch-actor-storage`

**Role**: Stores all orchestrator state including run history, task state, metrics, and configuration. Provides the data backend for the observability API.

#### SSO Provider

**ID**: `cpt-orch-actor-sso-provider`

**Role**: External identity provider supporting OIDC and SAML protocols. Provides authentication for human actors and enables tenant-level access control.

## 3. Operational Concept & Environment

### 3.1 Module-Specific Environment Constraints

The orchestrator operates as a stateless service that relies on external systems for persistence, message delivery, and credential storage. It is designed for single-instance deployment initially, with high availability deferred to a later phase.

Runners are deployed independently and may be distributed across different environments. Each runner maintains a local log store and communicates with the orchestrator exclusively through the message queue (for task assignment notifications) and the authenticated REST API (for payload retrieval and result reporting).

All inter-service communication carrying sensitive data (secrets, configuration, state) occurs over authenticated API channels — never through the message queue. The message queue is used solely for lightweight task assignment signals.

## 4. Scope

### 4.1 In Scope

- DAG-based task dependency declaration and topological execution ordering
- Task scheduling via cron expressions, interval-since-last-completion, and manual triggers
- Runner registration, tag-based task-to-runner matching, and runner health monitoring
- Task configuration management via API with synchronous validation
- Execution protocol for runner-to-orchestrator result reporting (LOG, STATE, METRIC, RESULT, PROGRESS)
- Secure secret delivery from external vault to runners via authenticated API
- Message queue integration for task assignment signaling (task ID only)
- Run history and task state persistence
- REST API with OpenAPI specification for DAG management, run history, runner status, and configuration validation
- Multi-tenancy with logical and physical isolation, SSO (OIDC/SAML), and RBAC (admin/operator/viewer)
- Error recording with configurable failure handling policies

### 4.2 Out of Scope

- Web UI or dashboard (API-only; UI is a separate component)
- High availability / multi-instance orchestrator deployment (deferred)
- Automatic retry policies beyond configurable record-only behavior (future enhancement)
- ML pipeline orchestration or specialized ML task types
- Runner deployment automation or infrastructure provisioning
- Data transformation logic (owned by dbt and connectors, not the orchestrator)
- Log aggregation and long-term log storage (runners manage their own logs)

## 5. Functional Requirements

> **Testing strategy**: All requirements verified via automated tests (unit, integration, e2e) targeting 90%+ code coverage unless otherwise specified. Document verification method only for non-test approaches (analysis, inspection, demonstration).

### 5.1 DAG & Task Management

#### DAG Construction from Task Definitions

- [ ] `p1` - **ID**: `cpt-orch-fr-dag-construction`

The system **MUST** construct a directed acyclic graph from task definitions and their declared dependencies, rejecting any configuration that would introduce a cycle.

**Rationale**: Correct dependency resolution is the foundation of pipeline reliability — without it, tasks may execute out of order or deadlock.

**Actors**: `cpt-orch-actor-data-engineer`, `cpt-orch-actor-ci-pipeline`

#### Topological Execution Order

- [ ] `p1` - **ID**: `cpt-orch-fr-dag-topological-exec`

The system **MUST** execute tasks in topological order, ensuring that no task begins execution until all of its upstream dependencies have completed successfully.

**Rationale**: Guarantees data correctness by preventing tasks from consuming incomplete upstream outputs.

**Actors**: `cpt-orch-actor-platform-operator`, `cpt-orch-actor-runner`

#### Task Lifecycle Tracking

- [ ] `p1` - **ID**: `cpt-orch-fr-task-lifecycle`

The system **MUST** track each task through its full lifecycle (pending, queued, running, succeeded, failed, cancelled) and persist state transitions with timestamps.

**Rationale**: Enables operators to understand current pipeline state and diagnose issues at any point in execution.

**Actors**: `cpt-orch-actor-platform-operator`

### 5.2 Scheduling

#### Cron-Based Scheduling

- [ ] `p1` - **ID**: `cpt-orch-fr-sched-cron`

The system **MUST** support scheduling tasks using standard cron expressions, evaluating schedules and triggering task execution at the specified times.

**Rationale**: Cron is the industry-standard mechanism for time-based scheduling, required for regular data pipeline cadences (hourly, daily, weekly).

**Actors**: `cpt-orch-actor-data-engineer`

#### Interval-Based Scheduling

- [ ] `p1` - **ID**: `cpt-orch-fr-sched-interval`

The system **MUST** support scheduling tasks based on a configurable interval measured from the completion of the previous run, ensuring consistent spacing between executions regardless of run duration.

**Rationale**: Prevents overlapping runs for long-duration tasks and ensures stable pipeline rhythm when execution time varies.

**Actors**: `cpt-orch-actor-data-engineer`

#### Manual Trigger

- [ ] `p1` - **ID**: `cpt-orch-fr-sched-manual`

The system **MUST** allow authorized users to manually trigger any task or DAG on demand, bypassing the normal schedule while still respecting dependency order.

**Rationale**: Operators need the ability to re-run failed tasks, test new configurations, or trigger ad-hoc data refreshes without waiting for scheduled execution.

**Actors**: `cpt-orch-actor-platform-operator`, `cpt-orch-actor-data-engineer`

### 5.3 Runner Management

#### Runner Registration

- [ ] `p1` - **ID**: `cpt-orch-fr-runner-register`

The system **MUST** allow runners to register with the orchestrator, providing their identity, capabilities, and tags, and **MUST** maintain a registry of all active runners.

**Rationale**: The orchestrator needs to know which runners are available and their capabilities to make correct task assignment decisions.

**Actors**: `cpt-orch-actor-runner`

#### Tag-Based Task Assignment

- [ ] `p1` - **ID**: `cpt-orch-fr-runner-tag-matching`

The system **MUST** assign tagged tasks only to runners with matching tags, and untagged tasks only to untagged runners.

**Rationale**: Tag-based affinity ensures that specialized tasks (e.g., tasks requiring specific network access or hardware) are routed to appropriately provisioned runners.

**Actors**: `cpt-orch-actor-runner`, `cpt-orch-actor-data-engineer`

#### Runner Health Monitoring

- [ ] `p1` - **ID**: `cpt-orch-fr-runner-health`

The system **MUST** monitor runner health via periodic heartbeats and **MUST** mark runners as unavailable when heartbeats are not received within a configurable timeout.

**Rationale**: Detecting runner failures promptly prevents tasks from being assigned to unresponsive runners and enables operators to take corrective action.

**Actors**: `cpt-orch-actor-platform-operator`, `cpt-orch-actor-runner`

### 5.4 Task Configuration & Validation

#### Configuration Push via API

- [ ] `p1` - **ID**: `cpt-orch-fr-config-push`

The system **MUST** accept task configuration updates via API, allowing external systems (CI pipelines, manual API calls) to push new or modified task definitions.

**Rationale**: API-driven configuration enables GitOps workflows where configuration changes are reviewed in version control and deployed automatically.

**Actors**: `cpt-orch-actor-ci-pipeline`, `cpt-orch-actor-data-engineer`

#### Synchronous Configuration Validation

- [ ] `p1` - **ID**: `cpt-orch-fr-config-validate`

The system **MUST** validate task configurations synchronously upon submission, returning detailed validation errors before accepting the configuration, including syntax checks and dependency reference validation.

**Rationale**: Immediate validation feedback prevents invalid configurations from entering the system, reducing debugging time and preventing pipeline failures from misconfiguration.

**Actors**: `cpt-orch-actor-ci-pipeline`, `cpt-orch-actor-data-engineer`

#### Configuration Versioning

- [ ] `p2` - **ID**: `cpt-orch-fr-config-versioning`

The system **SHOULD** maintain a history of configuration changes, allowing operators to identify when and what configuration was active for any given task run.

**Rationale**: Configuration audit trail is essential for diagnosing issues where a pipeline worked previously but fails after a config change.

**Actors**: `cpt-orch-actor-platform-operator`, `cpt-orch-actor-data-engineer`

### 5.5 Execution Protocol

#### Structured Message Protocol

- [ ] `p1` - **ID**: `cpt-orch-fr-exec-protocol`

The system **MUST** define and enforce a structured execution protocol where runners emit JSON-per-line messages with defined types (LOG, STATE, METRIC, RESULT, PROGRESS) and the orchestrator processes each type accordingly.

**Rationale**: A standardized protocol ensures consistent behavior across all task types and enables unified observability regardless of the underlying connector or transformation.

**Actors**: `cpt-orch-actor-runner`

#### State Reporting

- [ ] `p1` - **ID**: `cpt-orch-fr-exec-state-report`

The system **MUST** accept STATE messages from runners and persist the reported state, making it available for subsequent runs of the same task (e.g., incremental sync cursors).

**Rationale**: Stateful tasks (e.g., incremental connectors) require persisted state between runs to avoid full re-processing.

**Actors**: `cpt-orch-actor-runner`, `cpt-orch-actor-storage`

#### Metric and Progress Reporting

- [ ] `p1` - **ID**: `cpt-orch-fr-exec-metrics`

The system **MUST** accept METRIC and PROGRESS messages from runners and persist them for observability, enabling operators to track task throughput and completion progress.

**Rationale**: Real-time progress visibility reduces uncertainty during long-running tasks and provides quantitative data for capacity planning.

**Actors**: `cpt-orch-actor-runner`, `cpt-orch-actor-platform-operator`

### 5.6 Secret Management

#### Secure Secret Retrieval

- [ ] `p1` - **ID**: `cpt-orch-fr-secret-retrieval`

The system **MUST** retrieve task-specific secrets from the external vault and deliver them to the assigned runner exclusively through the authenticated API — never through the message queue.

**Rationale**: Secrets must traverse only authenticated, encrypted channels to prevent credential leakage. The message queue is not designed for secure payload delivery.

**Actors**: `cpt-orch-actor-secret-vault`, `cpt-orch-actor-runner`

#### Secret Scope Isolation

- [ ] `p1` - **ID**: `cpt-orch-fr-secret-isolation`

The system **MUST** ensure that a runner receives only the secrets associated with the specific task it is executing, and **MUST NOT** expose secrets belonging to other tasks or tenants.

**Rationale**: Minimizes blast radius of a compromised runner by limiting secret access to the narrowest necessary scope.

**Actors**: `cpt-orch-actor-runner`, `cpt-orch-actor-secret-vault`

### 5.7 Observability API

#### DAG and Run Status Query

- [ ] `p1` - **ID**: `cpt-orch-fr-api-dag-status`

The system **MUST** provide an API to query current DAG state, including task statuses, dependency relationships, and the status of in-progress and recent runs.

**Rationale**: Operators need a single entry point to understand the current state of all pipelines, enabling rapid triage when issues arise.

**Actors**: `cpt-orch-actor-platform-operator`

#### Run History Query

- [ ] `p2` - **ID**: `cpt-orch-fr-api-run-history`

The system **MUST** provide an API to query historical run data with filtering by task, time range, status, and tenant.

**Rationale**: Historical run data is essential for trend analysis, SLA reporting, and root cause investigation of intermittent failures.

**Actors**: `cpt-orch-actor-platform-operator`, `cpt-orch-actor-data-engineer`

#### Runner Status Query

- [ ] `p1` - **ID**: `cpt-orch-fr-api-runner-status`

The system **MUST** provide an API to query runner status, including registration details, tags, health state, and current task assignment.

**Rationale**: Visibility into runner fleet health enables proactive capacity management and rapid identification of infrastructure issues.

**Actors**: `cpt-orch-actor-platform-operator`

### 5.8 Multi-tenancy & Authorization

#### Tenant Data Isolation

- [ ] `p1` - **ID**: `cpt-orch-fr-mt-isolation`

The system **MUST** enforce strict data isolation between tenants, ensuring that no tenant can access, modify, or observe another tenant's tasks, runs, runners, configurations, or secrets.

**Rationale**: Multi-tenant data isolation is a non-negotiable security requirement — any cross-tenant data leakage would constitute a critical security breach.

**Actors**: `cpt-orch-actor-tenant-admin`, `cpt-orch-actor-platform-operator`

#### SSO Authentication

- [ ] `p1` - **ID**: `cpt-orch-fr-mt-sso`

The system **MUST** authenticate human users via the external SSO provider using OIDC or SAML protocols, delegating identity verification to the tenant's configured identity provider.

**Rationale**: SSO integration is required for enterprise adoption and enables centralized identity management across the platform.

**Actors**: `cpt-orch-actor-sso-provider`, `cpt-orch-actor-tenant-admin`

#### Role-Based Access Control

- [ ] `p1` - **ID**: `cpt-orch-fr-mt-rbac`

The system **MUST** enforce role-based access control within each tenant, supporting at minimum three roles: admin (full access), operator (run management and monitoring), and viewer (read-only access).

**Rationale**: Granular access control prevents accidental or unauthorized changes to pipeline configuration and supports least-privilege security practices.

**Actors**: `cpt-orch-actor-tenant-admin`

#### API Authentication

- [ ] `p1` - **ID**: `cpt-orch-fr-mt-api-auth`

The system **MUST** authenticate all API requests using token-based authentication (API keys) or OAuth2, and **MUST** reject unauthenticated requests.

**Rationale**: API authentication is the first line of defense against unauthorized access to pipeline management and observability endpoints.

**Actors**: `cpt-orch-actor-ci-pipeline`, `cpt-orch-actor-runner`, `cpt-orch-actor-platform-operator`

### 5.9 Error Handling

#### Failure Recording

- [ ] `p2` - **ID**: `cpt-orch-fr-err-record`

The system **MUST** record all task failures with sufficient context (task ID, run ID, timestamp, error category, runner identity) to enable post-mortem investigation.

**Rationale**: Comprehensive failure records are the foundation for diagnosing pipeline issues and improving reliability over time.

**Actors**: `cpt-orch-actor-platform-operator`, `cpt-orch-actor-runner`

#### Configurable Failure Policies

- [ ] `p2` - **ID**: `cpt-orch-fr-err-policy`

The system **MUST** support configurable failure handling policies per task, with the initial default policy being record-only (no automatic retries). The policy framework **MUST** be extensible to support additional strategies in the future.

**Rationale**: Different tasks have different failure characteristics — some are safe to retry, others are not. An extensible policy framework avoids hardcoding assumptions while providing a safe default.

**Actors**: `cpt-orch-actor-data-engineer`, `cpt-orch-actor-platform-operator`

#### Downstream Dependency Handling on Failure

- [ ] `p2` - **ID**: `cpt-orch-fr-err-downstream`

The system **MUST** prevent downstream tasks from executing when an upstream dependency has failed, and **MUST** mark affected downstream tasks with a blocked status indicating the upstream failure.

**Rationale**: Executing tasks with failed dependencies wastes compute resources and may produce incorrect results. Explicit blocked status provides clear signal to operators.

**Actors**: `cpt-orch-actor-platform-operator`

## 6. Non-Functional Requirements

### 6.1 NFR Inclusions

#### Authentication and Authorization Security

- [ ] `p1` - **ID**: `cpt-orch-nfr-authn-authz`

The system **MUST** authenticate all human users via SSO (OIDC/SAML) and all programmatic clients via API tokens or OAuth2, and **MUST** enforce RBAC on every API request, rejecting unauthorized operations within 50ms of receiving the request.

**Threshold**: 100% of API requests authenticated and authorized; authorization decision latency ≤ 50ms at p99.

**Rationale**: The orchestrator manages sensitive credentials and controls pipeline execution across tenants — any authentication bypass or authorization failure could lead to cross-tenant data exposure or unauthorized pipeline modifications.

#### Secret Transport Encryption

- [ ] `p1` - **ID**: `cpt-orch-nfr-secret-transport`

The system **MUST** encrypt all secret payloads in transit between the orchestrator and runners using TLS 1.2 or higher, and **MUST NOT** transmit secrets over unencrypted channels or through the message queue.

**Threshold**: 100% of secret deliveries encrypted with TLS 1.2+; zero secrets transmitted via message queue.

**Rationale**: Secrets include database credentials, API keys, and service tokens — any plaintext exposure in transit would constitute a critical security vulnerability.

#### API Response Latency

- [ ] `p1` - **ID**: `cpt-orch-nfr-api-latency`

The system **MUST** respond to read-only API queries (DAG status, run history, runner status) within 500ms at p95 under normal operating conditions, and configuration validation requests within 2 seconds at p95.

**Threshold**: Read queries ≤ 500ms at p95; validation ≤ 2s at p95; measured with up to 50 concurrent API clients.

**Rationale**: Operators investigating pipeline issues and CI pipelines waiting for validation feedback require low-latency responses to maintain productivity and deployment velocity.

#### Task Scheduling Latency

- [ ] `p1` - **ID**: `cpt-orch-nfr-sched-latency`

The system **MUST** evaluate and trigger scheduled tasks within 30 seconds of their scheduled time under normal operating conditions.

**Threshold**: ≤ 30 seconds scheduling jitter at p99; measured with up to 1,000 active schedules.

**Rationale**: Data pipeline SLAs often depend on timely execution — excessive scheduling delay cascades through the DAG and may cause downstream consumers to miss their own deadlines.

#### Runner Failure Detection

- [ ] `p1` - **ID**: `cpt-orch-nfr-runner-faildetect`

The system **MUST** detect runner unavailability (missed heartbeats) and mark the runner as offline within a configurable timeout, defaulting to no more than 60 seconds after the last successful heartbeat.

**Threshold**: Runner marked offline ≤ 60 seconds (default) after last heartbeat; configurable per deployment.

**Rationale**: Prompt failure detection prevents task assignments to unresponsive runners and enables operators to take corrective action before pipeline delays accumulate.

#### Concurrent Runner Scalability

- [ ] `p2` - **ID**: `cpt-orch-nfr-runner-scale`

The system **MUST** support at least 100 concurrently connected runners per tenant without degradation of task assignment throughput or API response latency.

**Threshold**: ≥ 100 concurrent runners per tenant; task assignment latency ≤ 5 seconds at p95; no increase in API response times beyond normal thresholds.

**Rationale**: Production deployments may require significant runner fleets for parallel task execution — the orchestrator must not become a bottleneck as the fleet scales.

### 6.2 NFR Exclusions

- **Accessibility (WCAG)**: Not applicable — the orchestrator is an API-only service with no user interface. Accessibility requirements apply to the separate UI component.

- **Internationalization / Localization**: Not applicable — all API responses, log messages, and error descriptions are in English only. The orchestrator has no end-user-facing text that requires translation.

- **High Availability**: Deferred — the orchestrator runs as a single instance initially. HA requirements (automatic failover, multi-instance coordination) are explicitly out of scope for this PRD and will be addressed in a future iteration.

- **Offline Operation**: Not applicable — the orchestrator is a server-side service that requires network connectivity to its dependent services (persistent storage, message queue, secret vault) at all times.

## 7. Public Library Interfaces

### 7.1 Public API Surface

#### Management API

- [ ] `p1` - **ID**: `cpt-orch-interface-management-api`

**Type**: REST API

**Stability**: stable

**Description**: The primary interface for all orchestrator management operations. Provides endpoints for DAG CRUD, task configuration submission and validation, run management (trigger, cancel, query status), runner status queries, and run history retrieval. All operations are scoped to the authenticated tenant.

**Breaking Change Policy**: Major version bump required for any breaking change. Minor versions may add new fields or endpoints without breaking existing clients. API versioning via URL path prefix.

#### Runner Communication Protocol

- [ ] `p1` - **ID**: `cpt-orch-interface-runner-protocol`

**Type**: REST API

**Stability**: stable

**Description**: The authenticated API used by runners to fetch task payloads (configuration, secrets, state), report execution results (STATE, METRIC, RESULT, PROGRESS messages), send heartbeats, and manage their registration lifecycle. All payloads containing secrets are transmitted exclusively through this interface.

**Breaking Change Policy**: Major version bump required. Runners and orchestrator must maintain version compatibility — runners on older protocol versions must receive a clear error indicating upgrade is required.

### 7.2 External Integration Contracts

#### Secret Vault Integration

- [ ] `p2` - **ID**: `cpt-orch-contract-vault`

**Direction**: required from client

**Protocol/Format**: Authenticated API calls to the external vault service for secret retrieval. The orchestrator acts as a client to the vault.

**Compatibility**: The orchestrator must support the vault's current API version. Changes to the vault API require corresponding updates to the orchestrator's vault adapter. Adapter pattern allows supporting multiple vault implementations.

#### Message Queue Integration

- [ ] `p1` - **ID**: `cpt-orch-contract-message-queue`

**Direction**: provided by system (producer) and required from client (consumer)

**Protocol/Format**: Message queue protocol for task assignment delivery. The orchestrator publishes task assignment messages (containing only task identifiers) and runners consume them. No secrets or sensitive data is transmitted through this channel.

**Compatibility**: Message format is versioned. Consumers must handle unknown fields gracefully. Schema changes require coordinated deployment of orchestrator and runners.

#### SSO Provider Integration

- [ ] `p2` - **ID**: `cpt-orch-contract-sso`

**Direction**: required from client

**Protocol/Format**: OIDC and SAML protocols for user authentication. The orchestrator delegates identity verification to the tenant's configured SSO provider and receives identity tokens/assertions.

**Compatibility**: Must support OIDC 1.0 and SAML 2.0. SSO provider changes (e.g., provider migration) require tenant-level configuration update only — no orchestrator code changes.

## 8. Use Cases

#### Deploy Task Configuration

- [ ] `p1` - **ID**: `cpt-orch-usecase-deploy-config`

**Actor**: `cpt-orch-actor-data-engineer`

**Preconditions**:
- Data Engineer has prepared task configuration files in the git repository
- CI pipeline is configured to push configurations to the orchestrator API
- Data Engineer has valid API credentials with appropriate permissions

**Main Flow**:
1. Data Engineer merges configuration changes to the repository
2. CI pipeline (`cpt-orch-actor-ci-pipeline`) detects the change and submits the configuration to the orchestrator's Management API
3. The orchestrator validates the configuration synchronously, checking syntax, dependency references, and schedule expressions
4. The orchestrator accepts the valid configuration and updates the active task definitions
5. The orchestrator reconstructs affected DAGs to reflect the new dependency structure
6. CI pipeline receives a success response with validation summary

**Postconditions**:
- New or modified task definitions are active in the orchestrator
- DAG structure reflects updated dependencies
- Subsequent scheduled or manual triggers use the new configuration

**Alternative Flows**:
- **Validation failure**: The orchestrator returns detailed validation errors in the API response. The CI pipeline fails, and the Data Engineer corrects the configuration before re-submitting.
- **Authentication failure**: The orchestrator rejects the request with an authentication error. The CI pipeline reports the credential issue.

#### Execute Scheduled DAG

- [ ] `p1` - **ID**: `cpt-orch-usecase-execute-dag`

**Actor**: `cpt-orch-actor-platform-operator`

**Preconditions**:
- DAG is defined with valid task dependencies and schedules
- At least one runner is registered and healthy with matching tags for each task
- Task configurations and secrets are available

**Main Flow**:
1. The orchestrator's scheduler determines that a DAG's trigger condition is met (cron expression fires or interval elapsed)
2. The orchestrator resolves the DAG's topological order and identifies ready tasks (all upstream dependencies satisfied)
3. For each ready task, the orchestrator selects an available runner with matching tags and publishes a task assignment to the message queue
4. The runner (`cpt-orch-actor-runner`) receives the assignment, fetches the full payload (configuration, secrets, state) from the Runner Communication Protocol API
5. The runner executes the task and reports STATE, METRIC, RESULT, and PROGRESS messages back to the orchestrator via API
6. The orchestrator records results, updates task status, and triggers downstream tasks whose dependencies are now satisfied
7. The process repeats until all tasks in the DAG have completed

**Postconditions**:
- All tasks in the DAG have executed in correct topological order
- Run history is recorded with status, metrics, and timing for each task
- Task state (e.g., incremental sync cursors) is persisted for subsequent runs

**Alternative Flows**:
- **No available runner**: The orchestrator queues the task assignment and waits for a runner with matching tags to become available. The task remains in "queued" status.
- **Task failure**: The orchestrator records the failure, marks downstream tasks as blocked, and applies the configured failure policy (default: record only).
- **Runner disconnects mid-execution**: The orchestrator detects the missed heartbeat, marks the runner as offline and the task as failed, then applies the failure policy.

#### Execute Data Pipeline (Bronze → Silver → Gold)

- [ ] `p1` - **ID**: `cpt-orch-usecase-data-pipeline`

**Actor**: `cpt-orch-actor-platform-operator`

**Preconditions**:
- A data pipeline DAG is defined with connector (Bronze), identity resolution, Silver transformation, and Gold aggregation tasks in correct dependency order
- Runners with appropriate tags are registered for each task type (connector runner, transformation runner)
- Source API credentials and backend API access are configured
- Identity Resolution service is available

**Main Flow**:
1. The orchestrator initiates a data ingestion iteration by assigning a connector task to a runner via the message queue
2. The runner launches the connector as a subprocess. The connector reads data from the source API and emits RECORD and STATE messages to stdout using the JSON-per-line execution protocol
3. The runner reads the connector's stdout stream and forwards RECORD messages as individual API calls to the backend service, which enforces `tenant_id` and persists records into Bronze raw data tables (`{source}_{entity}`)
4. The runner forwards STATE messages (incremental sync cursors) to the orchestrator for persistence and reports PROGRESS/METRIC messages for observability
5. Upon connector completion, the orchestrator receives the final RESULT message, marks the connector task as succeeded, and evaluates downstream dependencies
6. The orchestrator determines that the identity resolution task is now unblocked and assigns it to an available runner. The identity resolution service maps source-native user identifiers to canonical `person_id` values
7. Upon identity resolution completion, the orchestrator triggers the Silver transformation task — a dbt job that unifies source-specific Bronze tables into cross-source `class_{domain}` tables with canonical `person_id` references
8. Upon Silver transformation completion, the orchestrator triggers the Gold aggregation task — a dbt job that produces derived metric tables (e.g., `status_periods`, `throughput`, `wip_snapshots`) from the Silver `class_{domain}` tables
9. The process continues until all downstream tasks in the DAG have completed

**Postconditions**:
- Bronze tables contain the latest raw data from the source API
- Identity resolution mappings are up to date with new source identifiers
- Silver `class_{domain}` tables reflect unified, identity-resolved data from all sources
- Gold metric tables are recomputed from the latest Silver data
- Run history records status, metrics, and timing for each pipeline stage
- Incremental sync cursors are persisted for the next connector run

**Alternative Flows**:
- **Connector failure**: The orchestrator marks the connector task as failed and blocks all downstream tasks (identity resolution, Silver, Gold). The operator investigates via the observability API and re-triggers after fixing the issue.
- **Identity resolution failure**: Silver and Gold tasks remain blocked. The operator can re-trigger identity resolution independently without re-running the connector.
- **Partial source ingestion**: If the connector emits a STATE message before failing, the orchestrator persists the partial cursor. The next run resumes from the last successful checkpoint rather than re-ingesting all data.

#### Manually Trigger a Task

- [ ] `p2` - **ID**: `cpt-orch-usecase-manual-trigger`

**Actor**: `cpt-orch-actor-platform-operator`

**Preconditions**:
- The target task exists in the orchestrator with a valid configuration
- The Platform Operator is authenticated and has operator or admin role
- At least one compatible runner is available

**Main Flow**:
1. Platform Operator sends a manual trigger request for a specific task via the Management API
2. The orchestrator validates that the operator has permission to trigger the task within their tenant
3. The orchestrator creates a new run for the task, bypassing the normal schedule
4. The orchestrator assigns the task to an available runner with matching tags via the message queue
5. The runner fetches the payload and executes the task following the standard execution protocol

**Postconditions**:
- The task has been executed outside its normal schedule
- Run history records the manual trigger with the requesting operator's identity
- Downstream tasks execute if the manually triggered task succeeds and they are ready

**Alternative Flows**:
- **Insufficient permissions**: The orchestrator returns an authorization error. The operator must request elevated permissions from the Tenant Administrator.
- **Task already running**: The orchestrator rejects the trigger to prevent concurrent execution of the same task, returning the current run's status.

#### Runner Registration and Task Execution

- [ ] `p1` - **ID**: `cpt-orch-usecase-runner-lifecycle`

**Actor**: `cpt-orch-actor-runner`

**Preconditions**:
- Runner process is started with valid authentication credentials and orchestrator endpoint configuration
- Runner has declared its tags (if any)

**Main Flow**:
1. Runner sends a registration request to the orchestrator's Runner Communication Protocol API with its identity and tags
2. The orchestrator validates the runner's credentials and registers it in the active runner registry
3. Runner begins sending periodic heartbeats to maintain its active status
4. Runner subscribes to the message queue for task assignments
5. When a task assignment arrives, the runner fetches the full payload (configuration, secrets, state) from the orchestrator API
6. Runner executes the task, streaming PROGRESS and METRIC messages to the orchestrator
7. Upon completion, the runner sends the final RESULT and STATE messages

**Postconditions**:
- Runner is registered and visible in the runner status API
- Task results, metrics, and state are persisted in the orchestrator
- Runner remains connected and available for subsequent task assignments

**Alternative Flows**:
- **Registration rejected**: The orchestrator returns an authentication error. The runner logs the error and exits or retries with backoff.
- **Heartbeat timeout**: If the runner fails to send heartbeats within the configured timeout, the orchestrator marks it as offline and reassigns any in-progress tasks according to the failure policy.

#### Investigate Failed Task

- [ ] `p2` - **ID**: `cpt-orch-usecase-investigate-failure`

**Actor**: `cpt-orch-actor-platform-operator`

**Preconditions**:
- A task run has failed and been recorded in the orchestrator
- The Platform Operator is authenticated with operator or admin role

**Main Flow**:
1. Platform Operator queries the Management API for recent runs with failed status
2. The orchestrator returns a list of failed runs with task IDs, timestamps, error categories, and runner identities
3. Platform Operator queries the detail of a specific failed run to inspect metrics, progress data, and the error context
4. Platform Operator queries the runner status to determine if the failure was runner-related (e.g., runner went offline) or task-related
5. Based on findings, the operator decides to fix the configuration, address the runner issue, or manually re-trigger the task

**Postconditions**:
- The operator has identified the root cause of the failure
- Corrective action has been taken (configuration fix, runner restart, or manual re-trigger)

**Alternative Flows**:
- **Multiple cascading failures**: The operator observes that downstream tasks are blocked. They query the DAG status to identify the root upstream failure and address it first, then re-trigger the DAG from that point.

## 9. Acceptance Criteria

- [ ] Tasks with declared dependencies execute in correct topological order — no task starts before all upstream dependencies have completed successfully
- [ ] Scheduled tasks (cron and interval-based) trigger within 30 seconds of their scheduled time under normal load
- [ ] Runners can register with the orchestrator, receive task assignments via the message queue, and report results via the authenticated API
- [ ] Task configuration changes submitted via API are validated synchronously and rejected with detailed errors if invalid
- [ ] Multi-tenant isolation prevents any tenant from accessing, modifying, or observing another tenant's tasks, runs, runners, configurations, or secrets
- [ ] The Management API provides complete visibility into DAG state, run history, and runner status, with read queries responding within 500ms at p95
- [ ] Secrets are delivered to runners exclusively through the authenticated API over TLS — never through the message queue

## 10. Dependencies

| Dependency | Description | Criticality |
|------------|-------------|-------------|
| Secret Vault | External credential storage service; the orchestrator retrieves task-specific secrets on behalf of runners | p1 |
| Message Queue Service | Delivers task assignment signals (task identifiers only) from the orchestrator to runners | p1 |
| Persistent Storage Service | Stores all orchestrator state: run history, task state, metrics, configuration, and DAG definitions | p1 |
| SSO / Identity Provider | External identity provider (OIDC/SAML) for authenticating human users and enabling tenant-level access control | p1 |
| Git Repository / CI Pipeline | Source of task configuration files; CI pipelines push validated configurations to the orchestrator API | p2 |

## 11. Assumptions

- The external secret vault is available with low latency (< 200ms per retrieval) and supports concurrent access from the orchestrator
- The message queue service provides at-least-once delivery guarantees for task assignment messages
- Runners have network access to both the message queue (for assignment signals) and the orchestrator API (for payload retrieval and result reporting)
- The persistent storage service supports the query patterns required for run history, DAG status, and metric retrieval with acceptable performance
- SSO providers used by tenants conform to standard OIDC 1.0 or SAML 2.0 protocols
- Task configurations are syntactically valid YAML or TOML before being pushed to the orchestrator — the orchestrator validates structure and references, not format parsing of arbitrary content

## 12. Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Runner unavailability during peak load | Tasks queue indefinitely, causing pipeline SLA breaches and cascading delays across the DAG | Monitor runner fleet capacity via the observability API; alert on queue depth thresholds; design runner pool to handle peak concurrency with headroom |
| Message queue failure causing task assignment delays | Runners do not receive assignments; scheduled tasks miss their execution windows | Implement health checks and alerting on message queue availability; design for graceful degradation where the orchestrator can detect delivery failures and surface them via the API |
| Secret vault latency or unavailability impacting task startup | Runners cannot fetch secrets, blocking task execution and causing timeout failures | Cache secret vault availability status; surface vault connectivity issues as clear errors in the API; design timeout and error handling for vault interactions |
| Storage service write performance under high task volume | Run history and metric writes become a bottleneck, causing backpressure on result reporting and delayed status updates | Monitor write latency and queue depth; design result reporting to be asynchronous where possible; alert on storage performance degradation |
| Configuration push during active DAG execution causes inconsistency | Active runs may reference stale or mixed configuration versions, producing incorrect results | Apply configuration changes only between DAG runs; version-lock running tasks to the configuration snapshot active at run start |
