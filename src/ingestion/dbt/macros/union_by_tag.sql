{% macro union_by_tag(tag_name) %}
  {%- if execute -%}
    {%- set models = [] -%}
    {%- for node in graph.nodes.values() -%}
      {%- if tag_name in node.tags and node.resource_type == 'model' and node.unique_id != model.unique_id -%}
        {%- set rel = adapter.get_relation(database=none, schema=node.schema, identifier=node.alias or node.name) -%}
        {%- if rel -%}
          {%- do models.append(node) -%}
        {%- else -%}
          {{ log("union_by_tag: skipping " ~ node.name ~ " (table does not exist yet)", info=True) }}
        {%- endif -%}
      {%- endif -%}
    {%- endfor -%}

    {%- if models | length == 0 -%}
      {{ log("union_by_tag: no models found with tag '" ~ tag_name ~ "' (all source tables missing) — emitting empty result", info=True) }}
      SELECT 1 AS _placeholder WHERE FALSE
    {%- else -%}
      {%- for m in models %}
        SELECT * FROM {{ ref(m.name) }}
        {%- if not loop.last %} UNION ALL {% endif %}
      {%- endfor -%}
    {%- endif -%}
  {%- else -%}
    SELECT 1 AS _placeholder WHERE FALSE
  {%- endif -%}
{% endmacro %}
