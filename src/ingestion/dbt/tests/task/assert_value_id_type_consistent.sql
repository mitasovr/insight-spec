-- value_id_type must be stable per (data_source, field_id). A field's identifier kind
-- doesn't change — if we observe two different value_id_types for the same field_id,
-- the classifier is non-deterministic or the field metadata diverged across runs.

SELECT
    data_source,
    field_id,
    groupArray(DISTINCT value_id_type) AS observed_types
FROM silver.class_task_field_history FINAL
GROUP BY data_source, field_id
HAVING length(observed_types) > 1
LIMIT 100
