{% macro iso8601_duration_seconds(col) %}
{#- Parse ISO 8601 duration (PT1H30M45S) to seconds. CH 25.x compatible. -#}
toInt64(
    coalesce(nullIf(extractAll({{ col }}, '(\d+)H')[1], ''), '0')
) * 3600
+ toInt64(
    coalesce(nullIf(extractAll({{ col }}, '(\d+)M')[1], ''), '0')
) * 60
+ toInt64(
    coalesce(nullIf(extractAll({{ col }}, '(\d+)S')[1], ''), '0')
)
{% endmacro %}
