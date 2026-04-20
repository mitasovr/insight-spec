-- depends_on: {{ ref('jira__task_field_metadata') }}
{{ config(
    materialized='incremental',
    unique_key='(insight_source_id, data_source, field_id, project_key, observed_at)',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_task_field_metadata') }}
