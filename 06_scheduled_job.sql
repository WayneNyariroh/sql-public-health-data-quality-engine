-- =============================================================================
-- PUBLIC HEALTH DATA QUALITY ENGINE
-- File: 06_scheduled_job.sql
-- Purpose: pg_cron scheduling and maintenance functions.
--          The daily job calls public.run_dq_engine(), which is defined in
--          03_dq_engine.sql.
--
-- Prerequisites:
--   pg_cron extension installed and configured in postgresql.conf:
--     shared_preload_libraries = 'pg_cron'
--     cron.database_name = '<your_db_name>'
--
-- Schedule:
--   - Full engine run:      Daily at 02:00 EAT (23:00 UTC)
--   - Stale issue alert:    Weekly Monday 07:00 EAT
--   - Suppression cleanup:  Daily at 03:00 EAT
--
-- Run after: 05_resolution_procedures.sql
-- =============================================================================

SET search_path TO public;

-- ---------------------------------------------------------------------------
-- EXTENSION: pg_cron (requires superuser)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ---------------------------------------------------------------------------
-- ENGINE ENTRY POINT
-- run_dq_engine() is defined in 03_dq_engine.sql, which must be loaded before
-- this scheduling script. It executes all checks in one database session and
-- is the function invoked by the daily pg_cron job below.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- MAINTENANCE FUNCTION: cleanup_expired_suppressions
-- Deactivates suppression records that have passed their valid_until date.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cleanup_expired_suppressions()
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_deactivated INT;
BEGIN
    UPDATE dq_check_suppression
    SET is_active = FALSE
    WHERE valid_until < CURRENT_DATE
      AND is_active = TRUE;

    GET DIAGNOSTICS v_deactivated = ROW_COUNT;

    IF v_deactivated > 0 THEN
        RAISE NOTICE 'Deactivated % expired check suppressions.', v_deactivated;
    END IF;

    RETURN v_deactivated;
END;
$$;

COMMENT ON FUNCTION cleanup_expired_suppressions IS
'Deactivates DQ check suppressions that have passed their valid_until date. Run daily.';


-- ---------------------------------------------------------------------------
-- MAINTENANCE FUNCTION: archive_resolved_issues
-- Moves issues resolved > 180 days ago to a cold archive table.
-- Keeps data_quality_issue lean for active dashboard queries.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data_quality_issue_archive (
    LIKE data_quality_issue INCLUDING ALL
);

COMMENT ON TABLE data_quality_issue_archive IS
'Cold storage for DQ issues resolved more than 180 days ago. Same schema as data_quality_issue. Archived issues are removed from the live table to keep dashboard queries fast.';

CREATE OR REPLACE FUNCTION archive_old_resolved_issues(
    p_days_threshold INT DEFAULT 180
) RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_archived INT;
BEGIN
    -- Move to archive
    WITH moved AS (
        DELETE FROM data_quality_issue
        WHERE status = 'resolved'
          AND resolved_at < (now() - (p_days_threshold || ' days')::INTERVAL)
        RETURNING *
    )
    INSERT INTO data_quality_issue_archive SELECT * FROM moved;

    GET DIAGNOSTICS v_archived = ROW_COUNT;

    RAISE NOTICE 'Archived % resolved DQ issues older than % days.', v_archived, p_days_threshold;
    RETURN v_archived;
END;
$$;

COMMENT ON FUNCTION archive_old_resolved_issues IS
'Moves resolved DQ issues older than p_days_threshold (default 180 days) to the archive table. Run monthly.';


-- ---------------------------------------------------------------------------
-- MAINTENANCE FUNCTION: stale_issue_alert
-- Logs (and could email, if pg_notify is wired up) a summary of issues
-- open for more than 30 days, grouped by facility.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stale_issue_alert(
    p_days_threshold INT DEFAULT 30
) RETURNS TABLE (
    county_name     VARCHAR,
    facility_name   VARCHAR,
    mfl_code        VARCHAR,
    stale_count     BIGINT,
    oldest_issue_days INT
) LANGUAGE sql STABLE AS $$
    SELECT
        f.county_name::VARCHAR,
        f.facility_name::VARCHAR,
        f.mfl_code::VARCHAR,
        COUNT(dqi.issue_id)                                   AS stale_count,
        MAX(CURRENT_DATE - dqi.detected_at::DATE)::INT        AS oldest_issue_days
    FROM data_quality_issue dqi
    JOIN vw_facility_full f ON dqi.facility_id = f.facility_id
    WHERE dqi.status = 'open'
      AND dqi.detected_at < (CURRENT_TIMESTAMP - (p_days_threshold || ' days')::INTERVAL)
    GROUP BY f.county_name, f.facility_name, f.mfl_code
    ORDER BY stale_count DESC;
$$;

COMMENT ON FUNCTION stale_issue_alert IS
'Returns facilities with DQ issues open longer than p_days_threshold days. Feed this into a notification workflow (email, Slack, DHIS2 message) to alert DQ focal persons.';


-- ---------------------------------------------------------------------------
-- MAINTENANCE FUNCTION: get_engine_health_summary
-- Quick health check for the DQ engine itself : called by monitoring tools.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_engine_health_summary()
RETURNS TABLE (
    metric      TEXT,
    value       TEXT
) LANGUAGE sql STABLE AS $$
    SELECT * FROM (VALUES
        ('last_run_at',
            (SELECT run_completed_at::TEXT FROM dq_engine_run
             ORDER BY run_started_at DESC LIMIT 1)),
        ('last_run_duration_secs',
            (SELECT ROUND(EXTRACT(EPOCH FROM (run_completed_at - run_started_at)),2)::TEXT
             FROM dq_engine_run ORDER BY run_started_at DESC LIMIT 1)),
        ('last_run_issues_found',
            (SELECT issues_found::TEXT FROM dq_engine_run
             ORDER BY run_started_at DESC LIMIT 1)),
        ('total_open_issues',
            (SELECT COUNT(*)::TEXT FROM data_quality_issue WHERE status = 'open')),
        ('total_critical_open',
            (SELECT COUNT(*)::TEXT FROM data_quality_issue
             WHERE status = 'open' AND severity = 'critical')),
        ('facilities_with_critical_issues',
            (SELECT COUNT(DISTINCT facility_id)::TEXT FROM data_quality_issue
             WHERE status = 'open' AND severity = 'critical')),
        ('active_suppressions',
            (SELECT COUNT(*)::TEXT FROM dq_check_suppression WHERE is_active = TRUE)),
        ('total_runs',
            (SELECT COUNT(*)::TEXT FROM dq_engine_run)),
        ('issues_resolved_last_30_days',
            (SELECT COUNT(*)::TEXT FROM data_quality_issue
             WHERE status = 'resolved'
               AND resolved_at >= CURRENT_TIMESTAMP - INTERVAL '30 days'))
    ) AS t(metric, value);
$$;

COMMENT ON FUNCTION get_engine_health_summary IS
'Returns a key-value health summary for the DQ engine. Use for monitoring dashboards, Nagios checks, or uptime alerts.';


-- ---------------------------------------------------------------------------
-- pg_cron SCHEDULE SETUP
-- Requires pg_cron installed and the database name set in postgresql.conf.
-- Adjust the database name ('ph_data') to match your environment.
-- ---------------------------------------------------------------------------

-- Full DQ engine run: daily at 02:00 Africa/Nairobi (= 23:00 UTC previous day)
-- The daily job calls the engine function installed by 03_dq_engine.sql.
SELECT cron.schedule(
    'dq_engine_daily_run',
    '0 23 * * *',       -- 23:00 UTC = 02:00 EAT
    $$SELECT public.run_dq_engine('pg_cron_daily');$$
);

-- Expired suppression cleanup: daily at 03:00 EAT (00:00 UTC)
SELECT cron.schedule(
    'dq_suppression_cleanup',
    '0 0 * * *',
    $$SELECT cleanup_expired_suppressions();$$
);

-- Stale issue alert: every Monday at 07:00 EAT (04:00 UTC)
-- Wire the output to your notification system (email, DHIS2, Slack)
SELECT cron.schedule(
    'dq_stale_issue_alert',
    '0 4 * * 1',
    $cron$
        DO $alert$
        DECLARE
            r RECORD;
        BEGIN
            FOR r IN SELECT * FROM stale_issue_alert(30) LOOP
                RAISE NOTICE 'STALE ISSUES | % | % (MFL: %) | % issues | oldest: % days',
                    r.county_name, r.facility_name, r.mfl_code,
                    r.stale_count, r.oldest_issue_days;
            END LOOP;
        END;
        $alert$;
    $cron$
);

-- Monthly archive job: first day of month at 04:00 EAT (01:00 UTC)
SELECT cron.schedule(
    'dq_monthly_archive',
    '0 1 1 * *',
    $$SELECT archive_old_resolved_issues(180);$$
);

-- To view scheduled jobs:
-- SELECT * FROM cron.job;

-- To unschedule a job:
-- SELECT cron.unschedule('dq_engine_daily_run');

-- ---------------------------------------------------------------------------
-- ALTERNATIVE: Shell / Airflow invocation (no pg_cron)
-- If pg_cron is not available, schedule via OS cron or Airflow using psql:
-- ---------------------------------------------------------------------------

/*
-- /etc/cron.d/dq_engine (as postgres user):
-- 0 23 * * * postgres psql -d ph_data -f /opt/dq_engine/03_dq_engine.sql >> /var/log/dq_engine.log 2>&1

-- Airflow DAG excerpt (Python):
-- from airflow.providers.postgres.operators.postgres import PostgresOperator
-- run_dq_engine = PostgresOperator(
--     task_id='run_dq_engine',
--     postgres_conn_id='ph_database',
--     sql='03_dq_engine.sql',
--     dag=dag,
-- )
*/
