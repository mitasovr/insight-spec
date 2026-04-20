-- Drop gold views that referenced the removed silver.class_comms_events model.
-- After this migration, re-run 20260417000000_gold-views.sql to recreate them
-- pointing at staging.m365__collab_email_activity instead.

DROP VIEW IF EXISTS insight.email_daily;
DROP VIEW IF EXISTS insight.comms_daily;

-- Recreate comms_daily without class_comms_events dependency
CREATE VIEW IF NOT EXISTS insight.comms_daily AS
SELECT
    person_id,
    toString(metric_date) AS metric_date,
    sum(emails_sent)      AS emails_sent,
    sum(zoom_calls)       AS zoom_calls,
    sum(meeting_hours)    AS meeting_hours,
    sum(teams_messages)   AS teams_messages,
    sum(teams_meetings)   AS teams_meetings,
    sum(files_shared)     AS files_shared
FROM (
    SELECT
        lower(person_key) AS person_id,
        date AS metric_date,
        toFloat64(sent_count) AS emails_sent,
        toFloat64(0) AS zoom_calls,
        toFloat64(0) AS meeting_hours,
        toFloat64(0) AS teams_messages,
        toFloat64(0) AS teams_meetings,
        toFloat64(0) AS files_shared
    FROM staging.m365__collab_email_activity
    UNION ALL
    SELECT
        lower(p.email) AS person_id,
        toDate(parseDateTimeBestEffort(p.join_time)) AS metric_date,
        toFloat64(0) AS emails_sent,
        toFloat64(1) AS zoom_calls,
        dateDiff('second', parseDateTimeBestEffort(p.join_time), parseDateTimeBestEffort(p.leave_time)) / 3600.0 AS meeting_hours,
        toFloat64(0) AS teams_messages,
        toFloat64(0) AS teams_meetings,
        toFloat64(0) AS files_shared
    FROM bronze_zoom.participants p
    WHERE p.email IS NOT NULL AND p.email != ''
    UNION ALL
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(0) AS emails_sent,
        toFloat64(0) AS zoom_calls,
        toFloat64(0) AS meeting_hours,
        toFloat64(ifNull(teamChatMessageCount, 0)) + toFloat64(ifNull(privateChatMessageCount, 0)) AS teams_messages,
        toFloat64(ifNull(meetingsAttendedCount, 0)) AS teams_meetings,
        toFloat64(0) AS files_shared
    FROM bronze_m365.teams_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != '' AND userPrincipalName != '(Unknown)'
    UNION ALL
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0),
        toFloat64(ifNull(sharedInternallyFileCount, 0)) + toFloat64(ifNull(sharedExternallyFileCount, 0))
    FROM bronze_m365.onedrive_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != ''
    UNION ALL
    SELECT
        lower(userPrincipalName) AS person_id,
        toDate(lastActivityDate) AS metric_date,
        toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0), toFloat64(0),
        toFloat64(ifNull(sharedInternallyFileCount, 0)) + toFloat64(ifNull(sharedExternallyFileCount, 0))
    FROM bronze_m365.sharepoint_activity
    WHERE userPrincipalName IS NOT NULL AND userPrincipalName != ''
) sub
GROUP BY person_id, metric_date;

-- Recreate email_daily without class_comms_events dependency
CREATE VIEW IF NOT EXISTS insight.email_daily AS
SELECT
    lower(person_key) AS person_id,
    date              AS metric_date,
    lower(person_key) AS user_email,
    sent_count        AS emails_sent,
    data_source       AS source
FROM staging.m365__collab_email_activity;

-- Drop the old staging table if it exists (leftover from class_comms_events)
DROP TABLE IF EXISTS silver.class_comms_events;
