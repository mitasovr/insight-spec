{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['bitbucket-cloud', 'silver:class_git_commits']
) }}

SELECT
    tenant_id,
    source_id,
    unique_key,
    COALESCE(workspace, '') AS project_key,
    COALESCE(repo_slug, '') AS repo_slug,
    COALESCE(hash, '') AS commit_hash,
    COALESCE(branch_name, '') AS branch,
    COALESCE(author_name, '') AS author_name,
    COALESCE(author_email, '') AS author_email,
    '' AS committer_name,
    '' AS committer_email,
    COALESCE(message, '') AS message,
    parseDateTimeBestEffortOrNull(date) AS date,
    0 AS files_changed,
    0 AS lines_added,
    0 AS lines_removed,
    if(length(COALESCE(parent_hashes, '')) > 46, 1, 0) AS is_merge_commit,
    'insight_bitbucket_cloud' AS data_source,
    toUnixTimestamp64Milli(now64()) AS _version,
    _airbyte_extracted_at
FROM {{ source('bronze_bitbucket_cloud', 'commits') }}
{% if is_incremental() %}
WHERE _airbyte_extracted_at > (SELECT max(_airbyte_extracted_at) FROM {{ this }})
{% endif %}
