-- depends_on: {{ ref('jira__task_projects') }}
{{ config(
    materialized='incremental',
    unique_key='(insight_source_id, data_source, project_id)',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_task_projects') }}
