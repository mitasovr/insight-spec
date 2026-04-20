-- depends_on: {{ ref('jira__task_field_history') }}
{{ config(
    materialized='incremental',
    unique_key='(insight_source_id, data_source, event_id, field_id)',
    schema='silver',
    tags=['silver']
) }}

-- Event-sourced per-(issue × field × event) history. Source of truth is the Rust
-- `jira-enrich` binary, which writes `staging.jira__task_field_history` — see
-- `jira__task_field_history.sql` for the thin view that exposes it here.

{{ union_by_tag('silver:class_task_field_history') }}
