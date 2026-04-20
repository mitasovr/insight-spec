{{ config(
    materialized='incremental',
    alias='jira__task_field_metadata',
    incremental_strategy='append',
    schema='staging',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_source_id, data_source, field_id, project_key, observed_at)',
    settings={'allow_nullable_key': 1},
    tags=['jira', 'silver:class_task_field_metadata']
) }}

-- Jira field metadata → `staging.jira__task_field_metadata` → unioned into
-- `silver.class_task_field_metadata`. Classifies every field by cardinality / id-ness.
-- Bronze `jira_fields` stores schema as three flat columns: schema_type, schema_items, schema_custom.
--   is_multi  = (schema_type == 'array')
--   has_id    = multi+items!='string' OR single+items is present (structured field)

SELECT
    COALESCE(f.source_id, '')                     AS insight_source_id,
    CAST('jira' AS String)                        AS data_source,
    CAST(NULL AS Nullable(String))                AS project_key,
    COALESCE(f.field_id, '')                      AS field_id,
    COALESCE(f.name, '')                          AS field_name,
    toUInt8(COALESCE(f.schema_type, '') = 'array')  AS is_multi,
    COALESCE(f.schema_type, '')                     AS field_type,
    toUInt8(
        CASE
            WHEN COALESCE(f.schema_type, '') = 'array' AND COALESCE(f.schema_items, '') = 'string' THEN 0
            WHEN COALESCE(f.schema_type, '') IN ('string', 'number', 'date', 'datetime')
                 AND COALESCE(f.schema_items, '') = '' THEN 0
            ELSE 1
        END
    )                                               AS has_id,
    now64(3)                                      AS observed_at,
    toUnixTimestamp64Milli(now64(3))              AS _version
FROM {{ source('bronze_jira', 'jira_fields') }} f
-- `jira_fields` bronze = MergeTree (full_refresh + overwrite), FINAL not supported.
