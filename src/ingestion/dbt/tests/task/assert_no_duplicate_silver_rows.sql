-- After ReplacingMergeTree merge there must be at most one row per primary key.
-- (FINAL forces merge — if >1 row appears, our key is wrong or writes race something we missed.)

SELECT
    insight_source_id,
    data_source,
    issue_id,
    field_id,
    event_id,
    count() AS n
FROM silver.class_task_field_history FINAL
GROUP BY insight_source_id, data_source, issue_id, field_id, event_id
HAVING n > 1
LIMIT 100
