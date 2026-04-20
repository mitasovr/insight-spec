{{ config(
    materialized='incremental',
    alias='jira__task_users',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_source_id, data_source, user_id)',
    settings={'allow_nullable_key': 1},
    tags=['jira', 'silver:class_task_users']
) }}

-- Per-source staging model; unioned into `silver.class_task_users` via `union_by_tag`.
-- Anchor for identity resolution.

SELECT
    u.source_id                                 AS insight_source_id,
    CAST('jira' AS String)                      AS data_source,
    u.account_id                                AS user_id,
    u.email                                     AS email,
    u.display_name                              AS display_name,
    CAST(NULL AS Nullable(String))              AS username,
    u.account_type                              AS account_type,
    toUInt8OrNull(toString(u.active))           AS is_active,
    now64(3)                                    AS collected_at,
    toUnixTimestamp64Milli(now64(3))            AS _version
FROM {{ source('bronze_jira', 'jira_user') }} u
-- `jira_user` bronze = MergeTree (full_refresh + overwrite), FINAL not supported and not needed.
