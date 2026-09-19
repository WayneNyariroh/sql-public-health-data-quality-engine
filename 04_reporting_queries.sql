-- =============================================================================
-- PUBLIC HEALTH DATA QUALITY ENGINE
-- File: 04_reporting_queries.sql
-- Purpose: Analytical queries for DQ dashboards, management reports, and
--          drill-down investigations. These are read-only; none modify data.
--
-- Query inventory:
--   SECTION A: Executive / facility management views
--     A01 - Overall DQ score by facility (weighted severity index)
--     A02 - Issue count breakdown by category and severity
--     A03 - Top 10 worst facilities by open critical issues
--     A04 - County-level DQ summary heatmap data
--     A05 - Issue resolution rate by check name
--
--   SECTION B: Trend and time-series
--     B01 - Daily issue detection trend (last 90 days)
--     B02 - Monthly issue burden by facility
--     B03 - Mean time to resolve by severity
--     B04 - Check engine run history (performance over time)
--
--   SECTION C: Domain-specific deep dives
--     C01 - ART program DQ: missing weight + overdue patients by facility
--     C02 - TB cascade DQ: notification delay distribution
--     C03 - Viral load suppression accuracy (flagged mislabels)
--     C04 - Maternal health DQ: ANC completeness per ANC visit number
--     C05 - Stock DQ: facilities with balance errors by commodity
--     C06 - Aggregate reporting: late submission frequency by county
--
--   SECTION D: Operational / triage
--     D01 - All open critical issues (latest run) — action list
--     D02 - Issues by data_source (identify worst data entry channels)
--     D03 - Facilities with zero open issues (DQ clean list)
--     D04 - Stale open issues (open > 30 days without update)
--     D05 - False positive rate by check name
--
-- Run after: 03_dq_engine.sql
-- =============================================================================

SET search_path TO public;

-- =============================================================================
-- SECTION A: EXECUTIVE / FACILITY MANAGEMENT
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A01 | DQ Score by Facility
-- Weighted severity index: critical=10, high=5, medium=2, low=1
-- Lower score = better data quality. Score per 100 records is comparable
-- across facilities of different sizes.
-- ---------------------------------------------------------------------------
SELECT
    f.county_name,
    f.facility_name,
    f.mfl_code,
    f.facility_type,
    COUNT(dqi.issue_id) FILTER (WHERE dqi.severity = 'critical')  AS critical_issues,
    COUNT(dqi.issue_id) FILTER (WHERE dqi.severity = 'high')      AS high_issues,
    COUNT(dqi.issue_id) FILTER (WHERE dqi.severity = 'medium')    AS medium_issues,
    COUNT(dqi.issue_id) FILTER (WHERE dqi.severity = 'low')       AS low_issues,
    COUNT(dqi.issue_id)                                            AS total_open_issues,
    -- weighted DQ burden score
    SUM(
        CASE dqi.severity
            WHEN 'critical' THEN 10
            WHEN 'high'     THEN 5
            WHEN 'medium'   THEN 2
            WHEN 'low'      THEN 1
            ELSE 0
        END
    )                                                              AS weighted_dq_score,
    -- normalised: score per 10 issues (size-adjusted comparison)
    ROUND(
        SUM(
            CASE dqi.severity
                WHEN 'critical' THEN 10
                WHEN 'high'     THEN 5
                WHEN 'medium'   THEN 2
                WHEN 'low'      THEN 1
                ELSE 0
            END
        )::NUMERIC / NULLIF(COUNT(dqi.issue_id), 0), 2
    )                                                              AS avg_severity_weight,
    MIN(dqi.detected_at)                                           AS first_issue_detected,
    MAX(dqi.detected_at)                                           AS latest_issue_detected
FROM vw_facility_full f
LEFT JOIN data_quality_issue dqi
    ON f.facility_id = dqi.facility_id
    AND dqi.status = 'open'
GROUP BY f.county_name, f.facility_name, f.mfl_code, f.facility_type
ORDER BY weighted_dq_score DESC NULLS LAST;


-- ---------------------------------------------------------------------------
-- A02 | Issue Breakdown by Category and Severity
-- High-level summary for the DQ management dashboard header cards.
-- ---------------------------------------------------------------------------
SELECT
    check_category,
    severity,
    COUNT(*)                                                   AS issue_count,
    COUNT(*) FILTER (WHERE status = 'open')                    AS open_count,
    COUNT(*) FILTER (WHERE status = 'resolved')                AS resolved_count,
    COUNT(*) FILTER (WHERE status = 'false_positive')          AS false_positive_count,
    ROUND(
        COUNT(*) FILTER (WHERE status = 'resolved')::NUMERIC /
        NULLIF(COUNT(*), 0) * 100, 1
    )                                                          AS resolution_rate_pct,
    COUNT(DISTINCT facility_id)                                AS facilities_affected
FROM data_quality_issue
GROUP BY check_category, severity
ORDER BY
    CASE severity
        WHEN 'critical' THEN 1
        WHEN 'high'     THEN 2
        WHEN 'medium'   THEN 3
        WHEN 'low'      THEN 4
        ELSE 5
    END,
    check_category;


-- ---------------------------------------------------------------------------
-- A03 | Top 10 Worst Facilities by Open Critical Issues
-- Direct input for county DQ focal person action lists.
-- ---------------------------------------------------------------------------
SELECT
    ROW_NUMBER() OVER (ORDER BY critical_open DESC)            AS rank,
    f.county_name,
    f.facility_name,
    f.mfl_code,
    f.ownership,
    f.facility_type,
    critical_open,
    high_open,
    total_open,
    latest_detection,
    -- Days since last detection: stale = facility stopped submitting data
    CURRENT_DATE - latest_detection::DATE                      AS days_since_last_detection
FROM (
    SELECT
        facility_id,
        COUNT(*) FILTER (WHERE severity = 'critical' AND status = 'open') AS critical_open,
        COUNT(*) FILTER (WHERE severity = 'high'     AND status = 'open') AS high_open,
        COUNT(*) FILTER (WHERE status = 'open')                           AS total_open,
        MAX(detected_at)                                                   AS latest_detection
    FROM data_quality_issue
    GROUP BY facility_id
) ranked
JOIN vw_facility_full f ON ranked.facility_id = f.facility_id
ORDER BY critical_open DESC, high_open DESC
LIMIT 10;


-- ---------------------------------------------------------------------------
-- A04 | County-Level DQ Summary (Heatmap data)
-- One row per county with aggregated issue metrics.
-- Feed this into Power BI or a Leaflet choropleth.
-- ---------------------------------------------------------------------------
SELECT
    c.county_id,
    c.county_name,
    c.region,
    COUNT(DISTINCT f.facility_id)                              AS total_facilities,
    COUNT(DISTINCT dqi.facility_id)
        FILTER (WHERE dqi.status = 'open')                     AS facilities_with_issues,
    COUNT(dqi.issue_id) FILTER (WHERE dqi.status = 'open')    AS total_open_issues,
    COUNT(dqi.issue_id) FILTER (WHERE dqi.severity = 'critical'
                                  AND dqi.status = 'open')    AS critical_issues,
    -- DQ coverage rate: proportion of facilities with at least one open issue
    ROUND(
        COUNT(DISTINCT dqi.facility_id) FILTER (WHERE dqi.status = 'open')::NUMERIC /
        NULLIF(COUNT(DISTINCT f.facility_id), 0) * 100, 1
    )                                                          AS pct_facilities_affected,
    SUM(
        CASE dqi.severity
            WHEN 'critical' THEN 10
            WHEN 'high'     THEN 5
            WHEN 'medium'   THEN 2
            WHEN 'low'      THEN 1
            ELSE 0
        END
    )                                                          AS county_dq_burden_score
FROM county c
LEFT JOIN facility f ON c.county_id = f.county_id AND f.is_active = TRUE
LEFT JOIN data_quality_issue dqi ON f.facility_id = dqi.facility_id
GROUP BY c.county_id, c.county_name, c.region
ORDER BY county_dq_burden_score DESC NULLS LAST;


-- ---------------------------------------------------------------------------
-- A05 | Resolution Rate by Check Name
-- Tells you which checks produce actionable findings vs. chronic false alarms.
-- ---------------------------------------------------------------------------
SELECT
    check_name,
    check_category,
    severity,
    COUNT(*)                                                   AS total_issues,
    COUNT(*) FILTER (WHERE status = 'open')                    AS still_open,
    COUNT(*) FILTER (WHERE status = 'resolved')                AS resolved,
    COUNT(*) FILTER (WHERE status = 'false_positive')          AS false_positives,
    COUNT(*) FILTER (WHERE status = 'waived')                  AS waived,
    ROUND(
        COUNT(*) FILTER (WHERE status = 'resolved')::NUMERIC /
        NULLIF(COUNT(*), 0) * 100, 1
    )                                                          AS resolution_rate_pct,
    ROUND(
        COUNT(*) FILTER (WHERE status = 'false_positive')::NUMERIC /
        NULLIF(COUNT(*), 0) * 100, 1
    )                                                          AS false_positive_rate_pct,
    AVG(
        CASE WHEN status = 'resolved'
             THEN EXTRACT(DAY FROM (resolved_at - detected_at))
        END
    )::INT                                                     AS avg_days_to_resolve
FROM data_quality_issue
GROUP BY check_name, check_category, severity
ORDER BY total_issues DESC;


-- =============================================================================
-- SECTION B: TREND AND TIME-SERIES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- B01 | Daily Issue Detection Trend (Last 90 Days)
-- ---------------------------------------------------------------------------
SELECT
    DATE(detected_at)                                          AS detection_date,
    check_category,
    COUNT(*)                                                   AS issues_detected,
    COUNT(*) FILTER (WHERE severity = 'critical')              AS critical,
    COUNT(*) FILTER (WHERE severity = 'high')                  AS high_severity
FROM data_quality_issue
WHERE detected_at >= CURRENT_TIMESTAMP - INTERVAL '90 days'
GROUP BY DATE(detected_at), check_category
ORDER BY detection_date DESC, check_category;


-- ---------------------------------------------------------------------------
-- B02 | Monthly Issue Burden by Facility (rolling 12 months)
-- ---------------------------------------------------------------------------
SELECT
    TO_CHAR(DATE_TRUNC('month', dqi.detected_at), 'YYYY-MM')  AS month,
    f.county_name,
    f.facility_name,
    COUNT(*)                                                   AS issues_detected,
    COUNT(*) FILTER (WHERE dqi.severity IN ('critical','high')) AS high_priority_issues,
    COUNT(*) FILTER (WHERE dqi.status = 'resolved')            AS resolved_in_month
FROM data_quality_issue dqi
JOIN vw_facility_full f ON dqi.facility_id = f.facility_id
WHERE dqi.detected_at >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '12 months'
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 4 DESC;


-- ---------------------------------------------------------------------------
-- B03 | Mean Time to Resolve (MTTR) by Severity
-- How fast is the system responding to different issue severities?
-- ---------------------------------------------------------------------------
SELECT
    severity,
    COUNT(*) FILTER (WHERE status = 'resolved')                AS resolved_count,
    ROUND(
        AVG(
            EXTRACT(DAY FROM (resolved_at - detected_at))
        ) FILTER (WHERE status = 'resolved'), 1
    )                                                          AS avg_days_to_resolve,
    ROUND(
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY EXTRACT(DAY FROM (resolved_at - detected_at))
        ) FILTER (WHERE status = 'resolved'), 1
    )                                                          AS median_days_to_resolve,
    MIN(
        EXTRACT(DAY FROM (resolved_at - detected_at))
    ) FILTER (WHERE status = 'resolved')                       AS min_days,
    MAX(
        EXTRACT(DAY FROM (resolved_at - detected_at))
    ) FILTER (WHERE status = 'resolved')                       AS max_days
FROM data_quality_issue
GROUP BY severity
ORDER BY
    CASE severity
        WHEN 'critical' THEN 1
        WHEN 'high'     THEN 2
        WHEN 'medium'   THEN 3
        WHEN 'low'      THEN 4
        ELSE 5
    END;


-- ---------------------------------------------------------------------------
-- B04 | Engine Run History
-- Useful for scheduling decisions and performance monitoring.
-- ---------------------------------------------------------------------------
SELECT
    r.run_id,
    r.run_started_at,
    r.run_completed_at,
    ROUND(EXTRACT(EPOCH FROM (r.run_completed_at - r.run_started_at)), 2) AS duration_secs,
    r.triggered_by,
    r.checks_executed,
    r.issues_found,
    -- checks per second throughput
    ROUND(
        r.checks_executed::NUMERIC /
        NULLIF(EXTRACT(EPOCH FROM (r.run_completed_at - r.run_started_at)), 0), 2
    )                                                          AS checks_per_second,
    -- average issues per check
    ROUND(r.issues_found::NUMERIC / NULLIF(r.checks_executed, 0), 2)
                                                               AS avg_issues_per_check
FROM dq_engine_run r
ORDER BY r.run_started_at DESC
LIMIT 20;


-- =============================================================================
-- SECTION C: DOMAIN-SPECIFIC DEEP DIVES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- C01 | ART Program DQ: Missing Weight + Overdue Patients by Facility
-- Two critical ART program indicators combined into one facility scorecard.
-- ---------------------------------------------------------------------------
SELECT
    f.county_name,
    f.facility_name,
    f.mfl_code,

    -- Missing weight at enrollment
    COUNT(ae.enrollment_id)                                    AS total_enrollments,
    COUNT(ae.enrollment_id) FILTER (WHERE ae.weight_at_start IS NULL)
                                                               AS missing_weight_count,
    ROUND(
        COUNT(ae.enrollment_id) FILTER (WHERE ae.weight_at_start IS NULL)::NUMERIC /
        NULLIF(COUNT(ae.enrollment_id), 0) * 100, 1
    )                                                          AS pct_missing_weight,

    -- Overdue patients (no visit in last 90 days from their appointment)
    COUNT(DISTINCT ov.patient_id)                              AS overdue_patients

FROM vw_facility_full f
LEFT JOIN art_enrollment ae ON f.facility_id = ae.facility_id
LEFT JOIN (
    SELECT DISTINCT patient_id, facility_id
    FROM data_quality_issue
    WHERE check_name = 'T04_art_patient_overdue'
      AND status = 'open'
) ov ON f.facility_id = ov.facility_id
GROUP BY f.county_name, f.facility_name, f.mfl_code
HAVING COUNT(ae.enrollment_id) > 0
ORDER BY pct_missing_weight DESC;


-- ---------------------------------------------------------------------------
-- C02 | TB Cascade DQ: Notification Delay Distribution
-- Distribution of days between diagnosis and notification, segmented by
-- delay band. Useful for identifying systematic NTLD-P reporting failures.
-- ---------------------------------------------------------------------------
SELECT
    f.county_name,
    f.facility_name,
    COUNT(*)                                                   AS total_tb_cases,
    COUNT(*) FILTER (WHERE tb.diagnosis_date IS NULL)          AS missing_diagnosis_date,
    COUNT(*) FILTER (
        WHERE tb.diagnosis_date IS NOT NULL
          AND (tb.notification_date - tb.diagnosis_date) <= 14
    )                                                          AS notified_le_14_days,
    COUNT(*) FILTER (
        WHERE tb.diagnosis_date IS NOT NULL
          AND (tb.notification_date - tb.diagnosis_date) BETWEEN 15 AND 56
    )                                                          AS notified_15_56_days,
    COUNT(*) FILTER (
        WHERE tb.diagnosis_date IS NOT NULL
          AND (tb.notification_date - tb.diagnosis_date) > 56
    )                                                          AS notified_gt_56_days,
    ROUND(
        AVG(
            CASE WHEN tb.diagnosis_date IS NOT NULL
                 THEN (tb.notification_date - tb.diagnosis_date)
            END
        ), 1
    )                                                          AS avg_notification_delay_days,
    ROUND(
        COUNT(*) FILTER (
            WHERE tb.diagnosis_date IS NOT NULL
              AND (tb.notification_date - tb.diagnosis_date) <= 14
        )::NUMERIC / NULLIF(COUNT(*) FILTER (WHERE tb.diagnosis_date IS NOT NULL), 0) * 100, 1
    )                                                          AS pct_notified_within_14_days
FROM tb_case tb
JOIN vw_facility_full f ON tb.facility_id = f.facility_id
GROUP BY f.county_name, f.facility_name
HAVING COUNT(*) > 0
ORDER BY avg_notification_delay_days DESC NULLS LAST;


-- ---------------------------------------------------------------------------
-- C03 | VL Suppression Accuracy: Mislabeled Records
-- Clinicians and data managers need to know which labs are producing
-- mislabeled suppression categories, as this distorts TX_PVLS reporting.
-- ---------------------------------------------------------------------------
SELECT
    vl.lab_name,
    f.county_name,
    COUNT(*)                                                   AS total_vl_results,
    COUNT(*) FILTER (WHERE vl.vl_category = 'suppressed' AND vl.vl_result >= 1000)
                                                               AS mislabeled_suppressed,
    COUNT(*) FILTER (WHERE vl.vl_category = 'unsuppressed' AND
                           (vl.vl_result < 1000 OR vl.is_ldl = TRUE))
                                                               AS mislabeled_unsuppressed,
    COUNT(*) FILTER (WHERE vl.vl_result IS NULL AND vl.is_ldl = FALSE)
                                                               AS missing_result_not_ldl,
    ROUND(
        COUNT(*) FILTER (WHERE vl.vl_category = 'suppressed' AND vl.vl_result >= 1000)::NUMERIC /
        NULLIF(COUNT(*), 0) * 100, 2
    )                                                          AS mislabel_rate_pct
FROM viral_load vl
JOIN vw_facility_full f ON vl.facility_id = f.facility_id
GROUP BY vl.lab_name, f.county_name
ORDER BY mislabeled_suppressed DESC;


-- ---------------------------------------------------------------------------
-- C04 | Maternal Health DQ: ANC Completeness per Visit Number
-- Tracks data completeness across the four standard ANC contacts.
-- Completeness = key fields (HIV test, BP, gestational age) all present.
-- ---------------------------------------------------------------------------
SELECT
    av.anc_visit_number,
    f.county_name,
    COUNT(*)                                                   AS total_visits,
    COUNT(*) FILTER (WHERE av.gestational_age_wks IS NOT NULL) AS has_gestational_age,
    COUNT(*) FILTER (WHERE av.systolic_bp IS NOT NULL
                       AND av.diastolic_bp IS NOT NULL)        AS has_bp,
    COUNT(*) FILTER (WHERE av.hiv_test_done = TRUE)            AS hiv_test_done,
    COUNT(*) FILTER (WHERE av.weight_kg IS NOT NULL)           AS has_weight,
    -- full completeness: all four key fields present
    COUNT(*) FILTER (
        WHERE av.gestational_age_wks IS NOT NULL
          AND av.systolic_bp IS NOT NULL
          AND av.hiv_test_done = TRUE
          AND av.weight_kg IS NOT NULL
    )                                                          AS fully_complete,
    ROUND(
        COUNT(*) FILTER (
            WHERE av.gestational_age_wks IS NOT NULL
              AND av.systolic_bp IS NOT NULL
              AND av.hiv_test_done = TRUE
              AND av.weight_kg IS NOT NULL
        )::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1
    )                                                          AS completeness_pct
FROM anc_visit av
JOIN vw_facility_full f ON av.facility_id = f.facility_id
GROUP BY av.anc_visit_number, f.county_name
ORDER BY av.anc_visit_number, f.county_name;


-- ---------------------------------------------------------------------------
-- C05 | Stock DQ: Balance Errors by Commodity and Facility
-- Identifies which commodity-facility combinations have systematic
-- arithmetic errors in their monthly stock records.
-- ---------------------------------------------------------------------------
SELECT
    c.commodity_name,
    c.category,
    f.county_name,
    f.facility_name,
    COUNT(sr.stock_id)                                         AS total_records,
    COUNT(sr.stock_id) FILTER (
        WHERE sr.closing_balance IS NOT NULL
          AND sr.opening_balance IS NOT NULL
          AND ABS(
                sr.closing_balance -
                (sr.opening_balance + sr.received_qty - sr.dispensed_qty
                 - COALESCE(sr.losses_adjustments, 0))
              ) > 1
    )                                                          AS balance_error_count,
    ROUND(
        COUNT(sr.stock_id) FILTER (
            WHERE sr.closing_balance IS NOT NULL
              AND sr.opening_balance IS NOT NULL
              AND ABS(
                    sr.closing_balance -
                    (sr.opening_balance + sr.received_qty - sr.dispensed_qty
                     - COALESCE(sr.losses_adjustments, 0))
                  ) > 1
        )::NUMERIC / NULLIF(COUNT(sr.stock_id), 0) * 100, 1
    )                                                          AS error_rate_pct,
    MAX(ABS(
        sr.closing_balance -
        (sr.opening_balance + sr.received_qty - sr.dispensed_qty
         - COALESCE(sr.losses_adjustments, 0))
    )) FILTER (WHERE sr.closing_balance IS NOT NULL)           AS max_discrepancy
FROM stock_record sr
JOIN commodity c ON sr.commodity_id = c.commodity_id
JOIN vw_facility_full f ON sr.facility_id = f.facility_id
GROUP BY c.commodity_name, c.category, f.county_name, f.facility_name
HAVING COUNT(sr.stock_id) > 0
ORDER BY balance_error_count DESC, error_rate_pct DESC;


-- ---------------------------------------------------------------------------
-- C06 | Aggregate Reporting: Late Submission Frequency by County
-- County-level view of DHIS2 reporting timeliness.
-- ---------------------------------------------------------------------------
SELECT
    f.county_name,
    COUNT(DISTINCT ar.facility_id)                             AS reporting_facilities,
    COUNT(ar.report_id)                                        AS total_reports,
    COUNT(ar.report_id) FILTER (
        WHERE ar.submission_date >
              (MAKE_DATE(ar.period_year, COALESCE(ar.period_month,3), 1) +
               INTERVAL '1 month' + INTERVAL '60 days')
    )                                                          AS late_reports,
    ROUND(
        COUNT(ar.report_id) FILTER (
            WHERE ar.submission_date >
                  (MAKE_DATE(ar.period_year, COALESCE(ar.period_month,3), 1) +
                   INTERVAL '1 month' + INTERVAL '60 days')
        )::NUMERIC / NULLIF(COUNT(ar.report_id), 0) * 100, 1
    )                                                          AS late_submission_rate_pct,
    ROUND(
        AVG(
            EXTRACT(DAY FROM (
                ar.submission_date -
                (MAKE_DATE(ar.period_year, COALESCE(ar.period_month,3), 1) +
                 INTERVAL '1 month')::TIMESTAMPTZ
            ))
        ), 1
    )                                                          AS avg_days_after_period_end
FROM aggregate_report ar
JOIN vw_facility_full f ON ar.facility_id = f.facility_id
WHERE ar.period_type = 'monthly'
  AND ar.submission_date IS NOT NULL
GROUP BY f.county_name
ORDER BY late_submission_rate_pct DESC;


-- =============================================================================
-- SECTION D: OPERATIONAL / TRIAGE
-- =============================================================================

-- ---------------------------------------------------------------------------
-- D01 | All Open Critical Issues (latest run) — Action List
-- This is the front-line triage queue for DQ focal persons.
-- ---------------------------------------------------------------------------
SELECT
    dqi.issue_id,
    dqi.check_name,
    dqi.check_category,
    f.county_name,
    f.facility_name,
    f.mfl_code,
    dqi.source_table,
    dqi.source_column,
    dqi.record_id,
    dqi.issue_description,
    dqi.raw_value,
    dqi.expected_value,
    dqi.data_source,
    dqi.period_year,
    dqi.period_month,
    dqi.detected_at,
    CURRENT_DATE - dqi.detected_at::DATE                      AS days_open
FROM data_quality_issue dqi
JOIN vw_facility_full f ON dqi.facility_id = f.facility_id
WHERE dqi.severity = 'critical'
  AND dqi.status   = 'open'
ORDER BY dqi.detected_at DESC;


-- ---------------------------------------------------------------------------
-- D02 | Issues by Data Source
-- Identifies whether paper forms, KenyaEMR, DHIS2, or mobile CHW tools
-- are the weakest link in the data pipeline.
-- ---------------------------------------------------------------------------
SELECT
    dqi.data_source,
    COUNT(*)                                                   AS total_issues,
    COUNT(*) FILTER (WHERE dqi.severity = 'critical')          AS critical,
    COUNT(*) FILTER (WHERE dqi.severity = 'high')              AS high_severity,
    COUNT(*) FILTER (WHERE dqi.check_category = 'completeness') AS completeness_issues,
    COUNT(*) FILTER (WHERE dqi.check_category = 'validity')    AS validity_issues,
    COUNT(*) FILTER (WHERE dqi.check_category = 'consistency') AS consistency_issues,
    COUNT(*) FILTER (WHERE dqi.check_category = 'timeliness')  AS timeliness_issues,
    COUNT(DISTINCT dqi.facility_id)                            AS facilities_affected,
    ROUND(
        COUNT(*) FILTER (WHERE dqi.severity IN ('critical','high'))::NUMERIC /
        NULLIF(COUNT(*), 0) * 100, 1
    )                                                          AS high_priority_pct
FROM data_quality_issue dqi
WHERE dqi.status = 'open'
GROUP BY dqi.data_source
ORDER BY total_issues DESC;


-- ---------------------------------------------------------------------------
-- D03 | Facilities with Zero Open Issues (DQ Clean List)
-- Positive reinforcement: identify high-performing facilities.
-- ---------------------------------------------------------------------------
SELECT
    f.county_name,
    f.facility_name,
    f.mfl_code,
    f.facility_type,
    f.ownership,
    -- Count total records across transactional tables as proxy for data volume
    (SELECT COUNT(*) FROM patient p WHERE p.facility_id = f.facility_id)        AS patient_count,
    (SELECT COUNT(*) FROM art_enrollment ae WHERE ae.facility_id = f.facility_id) AS art_enrollment_count,
    (SELECT COUNT(*) FROM tb_case tb WHERE tb.facility_id = f.facility_id)       AS tb_case_count
FROM vw_facility_full f
WHERE f.is_active = TRUE
  AND NOT EXISTS (
      SELECT 1
      FROM data_quality_issue dqi
      WHERE dqi.facility_id = f.facility_id
        AND dqi.status = 'open'
  )
ORDER BY f.county_name, f.facility_name;


-- ---------------------------------------------------------------------------
-- D04 | Stale Open Issues (Open > 30 Days Without Update)
-- Issues that have sat open for over a month indicate broken resolution workflows.
-- ---------------------------------------------------------------------------
SELECT
    dqi.issue_id,
    dqi.check_name,
    dqi.severity,
    f.county_name,
    f.facility_name,
    dqi.source_table,
    dqi.issue_description,
    dqi.detected_at,
    CURRENT_DATE - dqi.detected_at::DATE                      AS days_open,
    dqi.updated_at,
    CURRENT_DATE - dqi.updated_at::DATE                       AS days_since_update
FROM data_quality_issue dqi
JOIN vw_facility_full f ON dqi.facility_id = f.facility_id
WHERE dqi.status = 'open'
  AND dqi.detected_at < (CURRENT_TIMESTAMP - INTERVAL '30 days')
ORDER BY days_open DESC;


-- ---------------------------------------------------------------------------
-- D05 | False Positive Rate by Check Name
-- Checks with high false positive rates should be reviewed and recalibrated.
-- Threshold: > 20% FP rate is a signal the check logic needs tightening.
-- ---------------------------------------------------------------------------
SELECT
    check_name,
    check_category,
    severity,
    COUNT(*)                                                   AS total_issues,
    COUNT(*) FILTER (WHERE status = 'false_positive')          AS false_positive_count,
    ROUND(
        COUNT(*) FILTER (WHERE status = 'false_positive')::NUMERIC /
        NULLIF(COUNT(*), 0) * 100, 1
    )                                                          AS false_positive_rate_pct,
    COUNT(*) FILTER (WHERE status = 'resolved')                AS resolved_count,
    COUNT(*) FILTER (WHERE status = 'open')                    AS still_open,
    CASE
        WHEN COUNT(*) FILTER (WHERE status = 'false_positive')::NUMERIC /
             NULLIF(COUNT(*), 0) > 0.20
        THEN 'REVIEW CHECK LOGIC'
        ELSE 'OK'
    END                                                        AS recommendation
FROM data_quality_issue
GROUP BY check_name, check_category, severity
HAVING COUNT(*) >= 5   -- minimum 5 instances before calculating FP rate
ORDER BY false_positive_rate_pct DESC;


-- ---------------------------------------------------------------------------
-- BONUS: Full issue export with all context (for Excel/Power BI import)
-- This is the flat export used by DHIS2 data use coordinators.
-- ---------------------------------------------------------------------------
SELECT
    dqi.issue_id,
    dqi.check_run_id,
    dqi.detected_at,
    dqi.check_name,
    dqi.check_category,
    dqi.severity,
    dqi.status,
    f.county_id,
    f.county_name,
    f.region,
    f.facility_id,
    f.facility_name,
    f.mfl_code,
    f.facility_type,
    f.ownership,
    dqi.source_table,
    dqi.source_column,
    dqi.record_id,
    dqi.issue_description,
    dqi.raw_value,
    dqi.expected_value,
    dqi.data_source,
    dqi.period_year,
    dqi.period_month,
    dqi.resolved_by,
    dqi.resolved_at,
    dqi.resolution_notes,
    CURRENT_DATE - dqi.detected_at::DATE                      AS days_open,
    CASE dqi.severity
        WHEN 'critical' THEN 10
        WHEN 'high'     THEN 5
        WHEN 'medium'   THEN 2
        WHEN 'low'      THEN 1
        ELSE 0
    END                                                        AS severity_weight
FROM data_quality_issue dqi
LEFT JOIN vw_facility_full f ON dqi.facility_id = f.facility_id
ORDER BY
    CASE dqi.severity
        WHEN 'critical' THEN 1
        WHEN 'high'     THEN 2
        WHEN 'medium'   THEN 3
        WHEN 'low'      THEN 4
        ELSE 5
    END,
    dqi.detected_at DESC;
