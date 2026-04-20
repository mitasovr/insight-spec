{{ config(
    materialized='table',
    alias='jira_issue_field_snapshot',
    schema='staging',
    engine='MergeTree()',
    order_by='(insight_source_id, id_readable, field_id)',
    settings={'allow_nullable_key': 1},
    tags=['staging', 'jira']
) }}

-- One row per (issue, field_id) with current value_ids / value_displays.
-- Consumed by `jira-enrich` to populate `IssueSnapshot.current_fields` so
-- synthetic_initial rows can be emitted for every field — even ones that never appear
-- in the changelog.
--
-- Strategy: JOIN bronze lookup tables (jira_statuses, jira_priorities, jira_issuetypes,
-- jira_resolutions, jira_user) against the narrowed jira_issue columns. Zero JSON parsing
-- in the hot path — display names come from the lookup tables, not from per-issue JSON.

WITH issue AS (
    SELECT
        COALESCE(source_id, '')                                       AS insight_source_id,
        COALESCE(toString(jira_id), '')                               AS issue_id,
        COALESCE(toString(id_readable), '')                           AS id_readable,
        COALESCE(parseDateTime64BestEffortOrNull(created, 3),
                 toDateTime64(0, 3))                                  AS created_at,
        -- ID fields are Decimal(38,9) in bronze after Airbyte auto-detect (treated as
        -- numeric because Jira returns them as numeric strings). Cast to String to make
        -- them joinable with lookup tables where IDs remain strings.
        toString(status_id)       AS status_id,
        toString(priority_id)     AS priority_id,
        toString(issuetype_id)    AS issuetype_id,
        toString(resolution_id)   AS resolution_id,
        assignee_id, reporter_id, parent_id, project_key,
        labels_csv,
        -- `story_points` and other per-issue custom fields are absent from bronze schema
        -- when the value is always null in the sampled data (Airbyte auto-detect skips
        -- NULL-only columns). Stub as NULL; future schema fix would declare them explicitly.
        CAST(NULL AS Nullable(String)) AS story_points,
        due_date
    FROM {{ source('bronze_jira', 'jira_issue') }} AS ji FINAL
)

-- CAST to Array(String) forces non-nullable element types so the Rust reader
-- (which expects Vec<String>) can deserialize. dbt-clickhouse otherwise infers
-- Array(Nullable(String)) when inner value expressions reference Nullable source columns.
SELECT insight_source_id, issue_id, id_readable, created_at, field_id,
       CAST(arrayMap(x -> COALESCE(x, ''), value_ids)      AS Array(String)) AS value_ids,
       CAST(arrayMap(x -> COALESCE(x, ''), value_displays) AS Array(String)) AS value_displays,
       toUnixTimestamp64Milli(now64(3))                                      AS _version
FROM (
    -- status
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'status' AS field_id,
           if(i.status_id IS NULL OR i.status_id = '', [], [i.status_id])           AS value_ids,
           if(i.status_id IS NULL OR i.status_id = '', [], [COALESCE(s.name, i.status_id)]) AS value_displays
    FROM issue i
    LEFT JOIN {{ source('bronze_jira', 'jira_statuses') }} s
        ON s.source_id = i.insight_source_id AND toString(s.status_id) = i.status_id

    UNION ALL

    -- priority
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'priority',
           if(i.priority_id IS NULL OR i.priority_id = '', [], [i.priority_id]),
           if(i.priority_id IS NULL OR i.priority_id = '', [], [COALESCE(p.name, i.priority_id)])
    FROM issue i
    LEFT JOIN {{ source('bronze_jira', 'jira_priorities') }} p
        ON p.source_id = i.insight_source_id AND toString(p.priority_id) = i.priority_id

    UNION ALL

    -- issuetype
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'issuetype',
           if(i.issuetype_id IS NULL OR i.issuetype_id = '', [], [i.issuetype_id]),
           if(i.issuetype_id IS NULL OR i.issuetype_id = '', [], [COALESCE(t.name, i.issuetype_id)])
    FROM issue i
    LEFT JOIN {{ source('bronze_jira', 'jira_issuetypes') }} t
        ON t.source_id = i.insight_source_id AND toString(t.issuetype_id) = i.issuetype_id

    UNION ALL

    -- resolution
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'resolution',
           if(i.resolution_id IS NULL OR i.resolution_id = '', [], [i.resolution_id]),
           if(i.resolution_id IS NULL OR i.resolution_id = '', [], [COALESCE(r.name, i.resolution_id)])
    FROM issue i
    LEFT JOIN {{ source('bronze_jira', 'jira_resolutions') }} r
        ON r.source_id = i.insight_source_id AND toString(r.resolution_id) = i.resolution_id

    UNION ALL

    -- assignee (display from jira_user)
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'assignee',
           if(i.assignee_id IS NULL OR i.assignee_id = '', [], [i.assignee_id]),
           if(i.assignee_id IS NULL OR i.assignee_id = '', [], [COALESCE(u.display_name, i.assignee_id)])
    FROM issue i
    LEFT JOIN {{ source('bronze_jira', 'jira_user') }} u
        ON u.source_id = i.insight_source_id AND u.account_id = i.assignee_id

    UNION ALL

    -- reporter
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'reporter',
           if(i.reporter_id IS NULL OR i.reporter_id = '', [], [i.reporter_id]),
           if(i.reporter_id IS NULL OR i.reporter_id = '', [], [COALESCE(u.display_name, i.reporter_id)])
    FROM issue i
    LEFT JOIN {{ source('bronze_jira', 'jira_user') }} u
        ON u.source_id = i.insight_source_id AND u.account_id = i.reporter_id

    UNION ALL

    -- project (already a string key, no lookup needed)
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'project',
           if(i.project_key IS NULL OR i.project_key = '', [], [i.project_key]),
           if(i.project_key IS NULL OR i.project_key = '', [], [i.project_key])
    FROM issue i

    UNION ALL

    -- parent (issue key)
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'parent',
           if(i.parent_id IS NULL OR i.parent_id = '', [], [i.parent_id]),
           if(i.parent_id IS NULL OR i.parent_id = '', [], [i.parent_id])
    FROM issue i

    UNION ALL

    -- labels — CSV split into array (ids == displays since labels are string literals)
    -- splitByChar(',', '') returns [''] — we want []; use COALESCE + length filter instead.
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'labels',
           arrayFilter(x -> x != '', splitByChar(',', COALESCE(i.labels_csv, ''))),
           arrayFilter(x -> x != '', splitByChar(',', COALESCE(i.labels_csv, '')))
    FROM issue i

    UNION ALL

    -- story_points (primitive)
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'story_points',
           if(i.story_points IS NULL OR i.story_points = '', [], [i.story_points]),
           if(i.story_points IS NULL OR i.story_points = '', [], [i.story_points])
    FROM issue i

    UNION ALL

    -- due_date (primitive)
    SELECT i.insight_source_id, i.issue_id, i.id_readable, i.created_at,
           'due_date',
           if(i.due_date IS NULL OR i.due_date = '', [], [toString(i.due_date)]),
           if(i.due_date IS NULL OR i.due_date = '', [], [toString(i.due_date)])
    FROM issue i
)
