-- depends_on: {{ ref('jira__task_comments') }}
{{ config(
    materialized='incremental',
    unique_key='(insight_source_id, data_source, comment_id)',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_task_comments') }}
