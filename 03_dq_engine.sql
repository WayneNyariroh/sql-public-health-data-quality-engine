-- =============================================================================
-- PUBLIC HEALTH DATA QUALITY ENGINE
-- File: 03_dq_engine.sql
-- Purpose: The automated check engine. Run as a scheduled job (pg_cron, Airflow, etc or manual execution).
--          Each check runs in its own block and:
--            1. Scans its target table/column
--            2. Inserts issues into data_quality_issue
--            3. Logs execution into dq_check_log
--
-- Architecture:
--   - A new dq_engine_run row is created at the top.
--   - v_run_id captures that UUID for the entire session.
--   - Each check is an independently scoped PL/pgSQL block within the callable engine function, so a scheduled run is atomic and auditable.
--   - public.dq_log_check() writes the audit log for each check.
--
-- Check inventory (36 checks across 7 categories):
--
--   COMPLETENESS (6):
--     C01 - Patient missing date_of_birth
--     C02 - Patient missing sex
--     C03 - TB case missing treatment_start_date
--     C04 - ART enrollment missing weight_at_start
--     C05 - Stock record missing closing_balance
--     C06 - Viral load result missing without an LDL flag
--
--   VALIDITY (8):
--     V01 - Patient date_of_birth in the future
--     V02 - ART start date before patient enrollment date
--     V03 - Negative CD4 count
--     V04 - VL result date before sample date
--     V05 - ANC gestational_age_wks > 44
--     V06 - Aggregate report with negative value
--     V07 - Art visit adherence score out of 0–100 range
--     V08 - Birth weight below 200g
--
--   CONSISTENCY (8):
--     K01 - ANC visit recorded for male patient
--     K02 - VL labeled 'suppressed' but result > 1000 copies/mL
--     K03 - TB outcome = 'cured' without treatment_start
--     K04 - Baby HIV-positive with HIV-negative mother (MTCT)
--     K05 - Stock closing balance ≠ opening + received - dispensed - losses
--     K06 - HTS_TST_POS > HTS_TST in same facility-period
--     K07 - ART start date after patient's recorded date of death
--     K08 - Patient enrollment date before date of birth
--
--   TIMELINESS (4):
--     T01 - TB notification > 56 days after diagnosis
--     T02 - Aggregate report submitted > 60 days after period end
--     T03 - CHW service record created > 30 days after service date
--     T04 - ART visit overdue > 90 days past next_appointment with no follow-on visit
--
--   UNIQUENESS (3):
--     U01 - Duplicate patients (same facility + DOB + sex)
--     U02 - Duplicate TB case numbers within county
--     U03 - Duplicate aggregate report for same facility-period-indicator
--
--   REFERENTIAL (1):
--     R01 - Aggregate report referencing inactive facility
--
--   PLAUSIBILITY (6):
--     P01 - Adult patient weight < 15kg in ART visit
--     P02 - CD4 count > 2500 cells/µL at ART enrollment
--     P03 - TX_CURR jump > 200% month-over-month (same facility)
--     P04 - Viral load > 10,000,000 copies/mL
--     P05 - Stock days_out_of_stock > 31
--     P06 - ANC systolic BP > 200 mmHg (hypertensive crisis, no alert recorded)
--
-- Run after: 01_schema.sql & 02_seed_data.sql

-- ---------------------------------------------------------------------------
-- HELPER: ensure idempotent run by committing session variables
-- ---------------------------------------------------------------------------
SET search_path TO raw, public;

-- ---------------------------------------------------------------------------
-- HELPER FUNCTION: log a check execution and return issue count
-- Creates the check log entry; the caller handles the actual DQ inserts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dq_log_check(
    p_run_id        UUID,
    p_check_name    VARCHAR,
    p_category      check_category,
    p_severity      severity_level,
    p_source_table  VARCHAR,
    p_records       INT,
    p_issues        INT,
    p_sql           TEXT DEFAULT NULL,
    p_error         TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dq_check_log (
        run_id, check_name, check_category, severity, source_table,
        completed_at, records_scanned, issues_raised, sql_query, error_message
    ) VALUES (
        p_run_id, p_check_name, p_category, p_severity, p_source_table,
        now(), p_records, p_issues, p_sql, p_error
    );
END;
$$;
-- ---------------------------------------------------------------------------
-- FUNCTION: run_dq_engine
-- Runs all 36 checks in one database session. This is the callable entry point
-- for pg_cron, Airflow, and manual SQL execution.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_dq_engine(
    p_triggered_by VARCHAR(80) DEFAULT 'manual'
) RETURNS UUID LANGUAGE plpgsql
SET search_path TO raw, public
AS $engine$
DECLARE
    v_run_id UUID;
BEGIN
    -- Function calls may come from pg_cron or another session whose default
    -- path is public. Force all source-table reads to the raw ingest layer.
    PERFORM set_config('search_path', 'raw, public', TRUE);

    INSERT INTO dq_engine_run (triggered_by, run_notes)
    VALUES (p_triggered_by, FORMAT('Full DQ engine run triggered by %s', p_triggered_by))
    RETURNING run_id INTO v_run_id;

    PERFORM set_config('dq.run_id', v_run_id::TEXT, TRUE);
    RAISE NOTICE 'DQ Engine run started. run_id = %', v_run_id;

-- =============================================================================
-- COMPLETENESS CHECKS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- C01 | COMPLETENESS | HIGH
-- Patient records with missing date_of_birth.
-- Age is required for paediatric vs adult regimen decisions and for cascade
-- disaggregation by age band. Any row without a DOB is analytically blind.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM patient;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'C01_patient_missing_dob',
            'completeness',
            'high',
            'patient',
            'date_of_birth',
            p.patient_id::TEXT,
            p.facility_id,
            f.county_id,
            FORMAT('Patient %s has no date_of_birth. Age band disaggregation and paediatric dosing checks will fail.',
                   p.nupi_number),
            NULL,
            'A valid date ≤ today',
            v_run_id,
            p.data_source
        FROM patient p
        JOIN facility f ON p.facility_id = f.facility_id
        WHERE p.date_of_birth IS NULL
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'C01_patient_missing_dob', 'completeness', 'high', 'patient', v_scanned, v_issues);
    RAISE NOTICE 'C01 | patient missing DOB: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- C02 | COMPLETENESS | MEDIUM
-- Patient records with sex = 'unknown'.
-- Sex disaggregation is mandatory for PEPFAR MER, DHIS2, and KHIS reporting.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM patient;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'C02_patient_sex_unknown',
            'completeness',
            'medium',
            'patient',
            'sex',
            p.patient_id::TEXT,
            p.facility_id,
            f.county_id,
            FORMAT('Patient %s has sex = ''unknown''. Required for disaggregated reporting.', p.nupi_number),
            p.sex::TEXT,
            'male | female | intersex',
            v_run_id,
            p.data_source
        FROM patient p
        JOIN facility f ON p.facility_id = f.facility_id
        WHERE p.sex = 'unknown'
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'C02_patient_sex_unknown', 'completeness', 'medium', 'patient', v_scanned, v_issues);
    RAISE NOTICE 'C02 | patient sex unknown: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- C03 | COMPLETENESS | CRITICAL
-- TB cases missing treatment_start_date.
-- Treatment start is the anchor for cohort analysis and treatment success
-- rate calculations. Missing it invalidates the entire outcome record.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM tb_case;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year
        )
        SELECT
            'C03_tb_missing_treatment_start',
            'completeness',
            'critical',
            'tb_case',
            'treatment_start',
            tb.tb_case_id::TEXT,
            tb.facility_id,
            f.county_id,
            FORMAT('TB case %s notified %s has no treatment_start_date. Outcome = %s. Cohort analysis blocked.',
                   tb.case_number, tb.notification_date, tb.treatment_outcome),
            NULL,
            'A date ≥ notification_date',
            v_run_id,
            tb.data_source,
            EXTRACT(YEAR FROM tb.notification_date)::SMALLINT
        FROM tb_case tb
        JOIN facility f ON tb.facility_id = f.facility_id
        WHERE tb.treatment_start IS NULL
          AND tb.treatment_outcome != 'on_treatment'  -- on_treatment may legitimately lack a start yet
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'C03_tb_missing_treatment_start', 'completeness', 'critical', 'tb_case', v_scanned, v_issues);
    RAISE NOTICE 'C03 | TB missing treatment start: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- C04 | COMPLETENESS | MEDIUM
-- ART enrollments missing weight_at_start.
-- Required for paediatric dosing and nutritional status assessment.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM art_enrollment;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'C04_art_missing_weight',
            'completeness',
            'medium',
            'art_enrollment',
            'weight_at_start',
            ae.enrollment_id::TEXT,
            ae.facility_id,
            f.county_id,
            FORMAT('ART enrollment %s (patient %s, started %s) has no weight_at_start.',
                   ae.enrollment_id, ae.patient_id, ae.art_start_date),
            NULL,
            'Weight in kg (expected range: 5–150)',
            v_run_id,
            'KenyaEMR'
        FROM art_enrollment ae
        JOIN facility f ON ae.facility_id = f.facility_id
        WHERE ae.weight_at_start IS NULL
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'C04_art_missing_weight', 'completeness', 'medium', 'art_enrollment', v_scanned, v_issues);
    RAISE NOTICE 'C04 | ART missing weight_at_start: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- C05 | COMPLETENESS | HIGH
-- Stock records with NULL closing_balance and no stockout flag.
-- Closing balance is needed to compute months of stock remaining.
-- A NULL with days_out_of_stock = 0 means the entry is simply incomplete.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM stock_record;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'C05_stock_missing_closing_balance',
            'completeness',
            'high',
            'stock_record',
            'closing_balance',
            sr.stock_id::TEXT,
            sr.facility_id,
            f.county_id,
            FORMAT('Stock record for commodity_id=%s at facility %s on %s has NULL closing_balance with no stockout indicator.',
                   sr.commodity_id, f.facility_name, sr.record_date),
            NULL,
            'Non-negative numeric value',
            v_run_id,
            sr.data_source
        FROM stock_record sr
        JOIN facility f ON sr.facility_id = f.facility_id
        WHERE sr.closing_balance IS NULL
          AND sr.days_out_of_stock = 0
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'C05_stock_missing_closing_balance', 'completeness', 'high', 'stock_record', v_scanned, v_issues);
    RAISE NOTICE 'C05 | Stock missing closing_balance: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- C06 | COMPLETENESS | HIGH
-- Viral-load results that are NULL without the low-detectable-level flag.
-- A missing result must be distinguished from an intentionally unquantified
-- LDL result before suppression and treatment decisions are reported.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM viral_load;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'C06_vl_result_missing_without_ldl',
            'completeness',
            'high',
            'viral_load',
            'vl_result',
            vl.vl_id::TEXT,
            vl.facility_id,
            f.county_id,
            FORMAT('Viral-load record %s for patient %s has no result and is not marked as LDL.',
                   vl.vl_id, vl.patient_id),
            NULL,
            'A numeric vl_result or is_ldl = TRUE',
            v_run_id,
            vl.data_source
        FROM viral_load vl
        JOIN facility f ON vl.facility_id = f.facility_id
        WHERE vl.vl_result IS NULL
          AND COALESCE(vl.is_ldl, FALSE) = FALSE
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'C06_vl_result_missing_without_ldl', 'completeness', 'high', 'viral_load', v_scanned, v_issues);
    RAISE NOTICE 'C06 | VL result missing without LDL flag: % issues', v_issues;
END;

-- =============================================================================
-- VALIDITY CHECKS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- V01 | VALIDITY | CRITICAL
-- Patient date_of_birth is in the future.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM patient WHERE date_of_birth IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'V01_patient_dob_future',
            'validity',
            'critical',
            'patient',
            'date_of_birth',
            p.patient_id::TEXT,
            p.facility_id,
            f.county_id,
            FORMAT('Patient %s has date_of_birth %s which is in the future (today = %s). Likely data entry error.',
                   p.nupi_number, p.date_of_birth, CURRENT_DATE),
            p.date_of_birth::TEXT,
            'Date ≤ ' || CURRENT_DATE::TEXT,
            v_run_id,
            p.data_source
        FROM patient p
        JOIN facility f ON p.facility_id = f.facility_id
        WHERE p.date_of_birth > CURRENT_DATE
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V01_patient_dob_future', 'validity', 'critical', 'patient', v_scanned, v_issues);
    RAISE NOTICE 'V01 | Patient DOB in future: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- V02 | VALIDITY | CRITICAL
-- ART start date is before the patient's enrollment date.
-- A patient cannot be on ART before they exist in the system.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM art_enrollment;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'V02_art_start_before_enrollment',
            'validity',
            'critical',
            'art_enrollment',
            'art_start_date',
            ae.enrollment_id::TEXT,
            ae.facility_id,
            f.county_id,
            FORMAT('ART enrollment %s: art_start_date (%s) is before patient enrollment_date (%s). Delta = %s days.',
                   ae.enrollment_id, ae.art_start_date, p.date_enrolled,
                   (p.date_enrolled - ae.art_start_date)),
            ae.art_start_date::TEXT,
            'Date ≥ patient.date_enrolled (' || p.date_enrolled::TEXT || ')',
            v_run_id,
            'KenyaEMR'
        FROM art_enrollment ae
        JOIN patient p ON ae.patient_id = p.patient_id
        JOIN facility f ON ae.facility_id = f.facility_id
        WHERE ae.art_start_date < p.date_enrolled
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V02_art_start_before_enrollment', 'validity', 'critical', 'art_enrollment', v_scanned, v_issues);
    RAISE NOTICE 'V02 | ART start before enrollment: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- V03 | VALIDITY | CRITICAL
-- Negative CD4 count at ART enrollment.
-- CD4 < 0 is biologically impossible.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM art_enrollment WHERE cd4_at_start IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'V03_negative_cd4_count',
            'validity',
            'critical',
            'art_enrollment',
            'cd4_at_start',
            ae.enrollment_id::TEXT,
            ae.facility_id,
            f.county_id,
            FORMAT('ART enrollment %s has cd4_at_start = %s. CD4 count cannot be negative.',
                   ae.enrollment_id, ae.cd4_at_start),
            ae.cd4_at_start::TEXT,
            'Non-negative number (0–2000 cells/µL typical)',
            v_run_id,
            'KenyaEMR'
        FROM art_enrollment ae
        JOIN facility f ON ae.facility_id = f.facility_id
        WHERE ae.cd4_at_start < 0
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V03_negative_cd4_count', 'validity', 'critical', 'art_enrollment', v_scanned, v_issues);
    RAISE NOTICE 'V03 | Negative CD4 count: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- V04 | VALIDITY | HIGH
-- Viral load result_date is before sample_date.
-- A lab cannot report a result before receiving the sample.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM viral_load WHERE result_date IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'V04_vl_result_before_sample',
            'validity',
            'high',
            'viral_load',
            'result_date',
            vl.vl_id::TEXT,
            vl.facility_id,
            f.county_id,
            FORMAT('Viral load %s: result_date (%s) is %s days before sample_date (%s).',
                   vl.vl_id, vl.result_date, (vl.sample_date - vl.result_date), vl.sample_date),
            vl.result_date::TEXT,
            'Date ≥ sample_date (' || vl.sample_date::TEXT || ')',
            v_run_id,
            vl.data_source
        FROM viral_load vl
        JOIN facility f ON vl.facility_id = f.facility_id
        WHERE vl.result_date < vl.sample_date
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V04_vl_result_before_sample', 'validity', 'high', 'viral_load', v_scanned, v_issues);
    RAISE NOTICE 'V04 | VL result before sample: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- V05 | VALIDITY | HIGH
-- ANC gestational age > 44 weeks. Human pregnancy does not exceed ~44 weeks.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM anc_visit WHERE gestational_age_wks IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'V05_anc_gestational_age_impossible',
            'validity',
            'high',
            'anc_visit',
            'gestational_age_wks',
            av.anc_visit_id::TEXT,
            av.facility_id,
            f.county_id,
            FORMAT('ANC visit %s recorded gestational_age_wks = %s which exceeds the maximum possible human gestation of 44 weeks.',
                   av.anc_visit_id, av.gestational_age_wks),
            av.gestational_age_wks::TEXT,
            '4–44 weeks',
            v_run_id,
            av.data_source
        FROM anc_visit av
        JOIN facility f ON av.facility_id = f.facility_id
        WHERE av.gestational_age_wks > 44
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V05_anc_gestational_age_impossible', 'validity', 'high', 'anc_visit', v_scanned, v_issues);
    RAISE NOTICE 'V05 | ANC impossible gestational age: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- V06 | VALIDITY | HIGH
-- Aggregate report with a negative value.
-- Counts and rates cannot be negative.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM aggregate_report WHERE value IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year, period_month
        )
        SELECT
            'V06_aggregate_negative_value',
            'validity',
            'high',
            'aggregate_report',
            'value',
            ar.report_id::TEXT,
            ar.facility_id,
            f.county_id,
            FORMAT('Aggregate report for %s at %s (%s-%s) has value = %s. Counts cannot be negative.',
                   ar.indicator_code, f.facility_name, ar.period_year, ar.period_month, ar.value),
            ar.value::TEXT,
            '≥ 0',
            v_run_id,
            ar.data_source,
            ar.period_year,
            ar.period_month
        FROM aggregate_report ar
        JOIN facility f ON ar.facility_id = f.facility_id
        WHERE ar.value < 0
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V06_aggregate_negative_value', 'validity', 'high', 'aggregate_report', v_scanned, v_issues);
    RAISE NOTICE 'V06 | Aggregate negative value: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- V07 | VALIDITY | MEDIUM
-- ART visit adherence score outside 0–100 range.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM art_visit WHERE adherence_score IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'V07_adherence_score_out_of_range',
            'validity',
            'medium',
            'art_visit',
            'adherence_score',
            v.visit_id::TEXT,
            v.facility_id,
            f.county_id,
            FORMAT('ART visit %s has adherence_score = %s, which is outside the valid range 0–100.',
                   v.visit_id, v.adherence_score),
            v.adherence_score::TEXT,
            '0 to 100 inclusive',
            v_run_id,
            v.data_source
        FROM art_visit v
        JOIN facility f ON v.facility_id = f.facility_id
        WHERE v.adherence_score NOT BETWEEN 0 AND 100
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V07_adherence_score_out_of_range', 'validity', 'medium', 'art_visit', v_scanned, v_issues);
    RAISE NOTICE 'V07 | Adherence score out of range: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- V08 | VALIDITY | HIGH
-- Birth weight below 200g. The CHECK constraint in the schema enforces ≥ 200g,
-- but legacy/migrated data may pre-date the constraint. This check catches
-- anything that bypasses it (e.g. direct table copies, bulk inserts).
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM delivery WHERE birth_weight_g IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'V08_birth_weight_below_minimum',
            'validity',
            'high',
            'delivery',
            'birth_weight_g',
            d.delivery_id::TEXT,
            d.facility_id,
            f.county_id,
            FORMAT('Delivery %s on %s has birth_weight_g = %sg. Minimum clinically viable weight is 200g.',
                   d.delivery_id, d.delivery_date, d.birth_weight_g),
            d.birth_weight_g::TEXT,
            '200g – 8000g',
            v_run_id,
            d.data_source
        FROM delivery d
        JOIN facility f ON d.facility_id = f.facility_id
        WHERE d.birth_weight_g < 200
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'V08_birth_weight_below_minimum', 'validity', 'high', 'delivery', v_scanned, v_issues);
    RAISE NOTICE 'V08 | Birth weight below minimum: % issues', v_issues;
END;

-- =============================================================================
-- CONSISTENCY CHECKS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- K01 | CONSISTENCY | HIGH
-- ANC visit recorded against a male patient.
-- ANC services are for pregnant women only.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM anc_visit;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'K01_anc_on_male_patient',
            'consistency',
            'high',
            'anc_visit',
            'patient_id',
            av.anc_visit_id::TEXT,
            av.facility_id,
            f.county_id,
            FORMAT('ANC visit %s (date: %s) is recorded for patient %s whose sex = ''male''. ANC services apply only to female patients.',
                   av.anc_visit_id, av.visit_date, p.nupi_number),
            p.sex::TEXT,
            'female',
            v_run_id,
            av.data_source
        FROM anc_visit av
        JOIN patient p ON av.patient_id = p.patient_id
        JOIN facility f ON av.facility_id = f.facility_id
        WHERE p.sex = 'male'
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K01_anc_on_male_patient', 'consistency', 'high', 'anc_visit', v_scanned, v_issues);
    RAISE NOTICE 'K01 | ANC on male patient: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- K02 | CONSISTENCY | CRITICAL
-- Viral load labeled 'suppressed' but result > 1000 copies/mL.
-- WHO defines virological suppression as VL < 1000 copies/mL.
-- This mislabeling directly corrupts VL suppression rate indicators.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM viral_load WHERE vl_category IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'K02_vl_suppressed_mislabeled',
            'consistency',
            'critical',
            'viral_load',
            'vl_category',
            vl.vl_id::TEXT,
            vl.facility_id,
            f.county_id,
            FORMAT('Viral load %s has vl_result = %s copies/mL but vl_category = ''suppressed''. WHO threshold is <1000 copies/mL.',
                   vl.vl_id, vl.vl_result),
            FORMAT('result=%s, category=suppressed', vl.vl_result),
            'vl_category = ''unsuppressed'' for result ≥ 1000',
            v_run_id,
            vl.data_source
        FROM viral_load vl
        JOIN facility f ON vl.facility_id = f.facility_id
        WHERE vl.vl_category = 'suppressed'
          AND vl.vl_result >= 1000
          AND vl.is_ldl = FALSE
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K02_vl_suppressed_mislabeled', 'consistency', 'critical', 'viral_load', v_scanned, v_issues);
    RAISE NOTICE 'K02 | VL suppressed mislabeled: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- K03 | CONSISTENCY | HIGH
-- TB treatment outcome = 'cured' or 'treatment_completed' but treatment_start is NULL.
-- You cannot be cured from treatment you never started.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM tb_case;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'K03_tb_cured_no_treatment_start',
            'consistency',
            'high',
            'tb_case',
            'treatment_start',
            tb.tb_case_id::TEXT,
            tb.facility_id,
            f.county_id,
            FORMAT('TB case %s has outcome = ''%s'' but treatment_start is NULL. A successful outcome requires a treatment start date.',
                   tb.case_number, tb.treatment_outcome),
            NULL,
            'treatment_start must be populated when outcome ≠ on_treatment',
            v_run_id,
            tb.data_source
        FROM tb_case tb
        JOIN facility f ON tb.facility_id = f.facility_id
        WHERE tb.treatment_start IS NULL
          AND tb.treatment_outcome IN ('cured', 'treatment_completed', 'treatment_failed', 'died', 'lost_to_follow_up')
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K03_tb_cured_no_treatment_start', 'consistency', 'high', 'tb_case', v_scanned, v_issues);
    RAISE NOTICE 'K03 | TB cured/outcome without treatment start: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- K04 | CONSISTENCY | HIGH
-- Baby HIV-positive but mother HIV-negative in same delivery record.
-- Mother-to-child transmission cannot occur if the mother is HIV-negative.
-- (Note: 'unknown' status is allowed.)
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM delivery;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'K04_mtct_inconsistency',
            'consistency',
            'high',
            'delivery',
            'baby_hiv_status',
            d.delivery_id::TEXT,
            d.facility_id,
            f.county_id,
            FORMAT('Delivery %s (%s): baby_hiv_status = ''positive'' but mother_hiv_status = ''negative''. MTCT cannot occur if mother is HIV-negative.',
                   d.delivery_id, d.delivery_date),
            FORMAT('baby=positive, mother=negative'),
            'If baby is HIV-positive, mother must be HIV-positive or unknown',
            v_run_id,
            d.data_source
        FROM delivery d
        JOIN facility f ON d.facility_id = f.facility_id
        WHERE d.baby_hiv_status = 'positive'
          AND d.mother_hiv_status = 'negative'
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K04_mtct_inconsistency', 'consistency', 'high', 'delivery', v_scanned, v_issues);
    RAISE NOTICE 'K04 | MTCT inconsistency: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- K05 | CONSISTENCY | HIGH
-- Stock closing balance ≠ opening + received - dispensed - losses_adjustments.
-- Arithmetic must hold. A discrepancy > 1 unit (rounding tolerance) is flagged.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned
    FROM stock_record
    WHERE closing_balance IS NOT NULL
      AND opening_balance IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'K05_stock_balance_arithmetic',
            'consistency',
            'high',
            'stock_record',
            'closing_balance',
            sr.stock_id::TEXT,
            sr.facility_id,
            f.county_id,
            FORMAT('Stock record %s: closing_balance = %s but arithmetic gives %s (delta = %s). Facility: %s, commodity_id: %s, date: %s.',
                   sr.stock_id, sr.closing_balance,
                   ROUND((sr.opening_balance + sr.received_qty - sr.dispensed_qty - COALESCE(sr.losses_adjustments,0))::NUMERIC, 2),
                   ROUND(ABS(sr.closing_balance - (sr.opening_balance + sr.received_qty - sr.dispensed_qty - COALESCE(sr.losses_adjustments,0)))::NUMERIC, 2),
                   f.facility_name, sr.commodity_id, sr.record_date),
            sr.closing_balance::TEXT,
            ROUND((sr.opening_balance + sr.received_qty - sr.dispensed_qty - COALESCE(sr.losses_adjustments,0))::NUMERIC, 2)::TEXT,
            v_run_id,
            sr.data_source
        FROM stock_record sr
        JOIN facility f ON sr.facility_id = f.facility_id
        WHERE sr.closing_balance IS NOT NULL
          AND sr.opening_balance IS NOT NULL
          AND ABS(sr.closing_balance - (sr.opening_balance + sr.received_qty
                  - sr.dispensed_qty - COALESCE(sr.losses_adjustments, 0))) > 1
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K05_stock_balance_arithmetic', 'consistency', 'high', 'stock_record', v_scanned, v_issues);
    RAISE NOTICE 'K05 | Stock balance arithmetic error: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- K06 | CONSISTENCY | CRITICAL
-- HTS_TST_POS > HTS_TST for the same facility-period.
-- Positives cannot exceed total tests.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned
    FROM aggregate_report
    WHERE indicator_code IN ('HTS_TST', 'HTS_TST_POS');

    WITH pair AS (
        SELECT
            tst.facility_id,
            tst.period_year,
            tst.period_month,
            tst.value        AS total_tested,
            pos.value        AS total_positive,
            tst.report_id    AS tst_report_id,
            pos.report_id    AS pos_report_id
        FROM aggregate_report tst
        JOIN aggregate_report pos
          ON tst.facility_id   = pos.facility_id
         AND tst.period_year   = pos.period_year
         AND COALESCE(tst.period_month,0) = COALESCE(pos.period_month,0)
        WHERE tst.indicator_code = 'HTS_TST'
          AND pos.indicator_code = 'HTS_TST_POS'
          AND pos.value > tst.value
    ),
    bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year, period_month
        )
        SELECT
            'K06_pos_exceeds_total_tests',
            'consistency',
            'critical',
            'aggregate_report',
            'HTS_TST_POS',
            pr.pos_report_id::TEXT,
            pr.facility_id,
            f.county_id,
            FORMAT('Facility %s in %s-%s: HTS_TST_POS (%s) exceeds HTS_TST (%s). Positives cannot exceed total tests.',
                   f.facility_name, pr.period_year, pr.period_month,
                   pr.total_positive, pr.total_tested),
            pr.total_positive::TEXT,
            '≤ HTS_TST (' || pr.total_tested::TEXT || ')',
            v_run_id,
            'DHIS2',
            pr.period_year,
            pr.period_month
        FROM pair pr
        JOIN facility f ON pr.facility_id = f.facility_id
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K06_pos_exceeds_total_tests', 'consistency', 'critical', 'aggregate_report', v_scanned, v_issues);
    RAISE NOTICE 'K06 | HTS_TST_POS exceeds HTS_TST: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- K07 | CONSISTENCY | CRITICAL
-- ART start date is after the patient's recorded date of death.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned
    FROM art_enrollment ae
    JOIN patient p ON ae.patient_id = p.patient_id
    WHERE p.date_of_death IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'K07_art_after_death',
            'consistency',
            'critical',
            'art_enrollment',
            'art_start_date',
            ae.enrollment_id::TEXT,
            ae.facility_id,
            f.county_id,
            FORMAT('ART enrollment %s: art_start_date (%s) is after patient date_of_death (%s).',
                   ae.enrollment_id, ae.art_start_date, p.date_of_death),
            ae.art_start_date::TEXT,
            'Date ≤ patient.date_of_death (' || p.date_of_death::TEXT || ')',
            v_run_id,
            'KenyaEMR'
        FROM art_enrollment ae
        JOIN patient p ON ae.patient_id = p.patient_id
        JOIN facility f ON ae.facility_id = f.facility_id
        WHERE p.date_of_death IS NOT NULL
          AND ae.art_start_date > p.date_of_death
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K07_art_after_death', 'consistency', 'critical', 'art_enrollment', v_scanned, v_issues);
    RAISE NOTICE 'K07 | ART after patient death: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- K08 | CONSISTENCY | HIGH
-- A patient cannot be enrolled before their recorded date of birth.
-- This corrupts age-at-enrolment calculations and cohort disaggregation.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM patient WHERE date_of_birth IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'K08_patient_enrolled_before_birth',
            'consistency',
            'high',
            'patient',
            'date_enrolled',
            p.patient_id::TEXT,
            p.facility_id,
            f.county_id,
            FORMAT('Patient %s was enrolled on %s before recorded date_of_birth %s.',
                   p.nupi_number, p.date_enrolled, p.date_of_birth),
            p.date_enrolled::TEXT,
            'date_enrolled >= date_of_birth',
            v_run_id,
            p.data_source
        FROM patient p
        JOIN facility f ON p.facility_id = f.facility_id
        WHERE p.date_of_birth IS NOT NULL
          AND p.date_enrolled < p.date_of_birth
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'K08_patient_enrolled_before_birth', 'consistency', 'high', 'patient', v_scanned, v_issues);
    RAISE NOTICE 'K08 | Patient enrolled before birth: % issues', v_issues;
END;

-- =============================================================================
-- TIMELINESS CHECKS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- T01 | TIMELINESS | HIGH
-- TB notification > 56 days (8 weeks) after diagnosis date.
-- Kenya NTLD-P guidelines require notification within 2 weeks of diagnosis.
-- 56 days (WHO threshold) is used as the outer bound.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM tb_case WHERE diagnosis_date IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year
        )
        SELECT
            'T01_tb_notification_delay',
            'timeliness',
            'high',
            'tb_case',
            'notification_date',
            tb.tb_case_id::TEXT,
            tb.facility_id,
            f.county_id,
            FORMAT('TB case %s: notification_date (%s) is %s days after diagnosis_date (%s). Threshold is 56 days.',
                   tb.case_number, tb.notification_date,
                   (tb.notification_date - tb.diagnosis_date), tb.diagnosis_date),
            FORMAT('%s days', tb.notification_date - tb.diagnosis_date),
            '≤ 56 days from diagnosis',
            v_run_id,
            tb.data_source,
            EXTRACT(YEAR FROM tb.notification_date)::SMALLINT
        FROM tb_case tb
        JOIN facility f ON tb.facility_id = f.facility_id
        WHERE tb.diagnosis_date IS NOT NULL
          AND (tb.notification_date - tb.diagnosis_date) > 56
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'T01_tb_notification_delay', 'timeliness', 'high', 'tb_case', v_scanned, v_issues);
    RAISE NOTICE 'T01 | TB notification delay: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- T02 | TIMELINESS | HIGH
-- Aggregate report submitted > 60 days after the reporting period end.
-- KHIS/DHIS2 deadline is typically the 15th of the following month.
-- 60 days catches chronic late submitters.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned
    FROM aggregate_report
    WHERE period_type = 'monthly' AND submission_date IS NOT NULL;

    WITH period_ends AS (
        SELECT
            ar.report_id,
            ar.facility_id,
            ar.period_year,
            ar.period_month,
            ar.indicator_code,
            ar.submission_date,
            ar.data_source,
            -- End of the reporting month
            (MAKE_DATE(ar.period_year, ar.period_month, 1) + INTERVAL '1 month - 1 day')::DATE AS period_end_date
        FROM aggregate_report ar
        WHERE ar.period_type = 'monthly'
          AND ar.submission_date IS NOT NULL
    ),
    bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year, period_month
        )
        SELECT
            'T02_aggregate_late_submission',
            'timeliness',
            'high',
            'aggregate_report',
            'submission_date',
            pe.report_id::TEXT,
            pe.facility_id,
            f.county_id,
            FORMAT('Aggregate report for %s at %s: submitted %s days after period end (%s). Threshold = 60 days.',
                   pe.indicator_code, f.facility_name,
                   EXTRACT(DAY FROM pe.submission_date - pe.period_end_date::TIMESTAMPTZ)::INT,
                   pe.period_end_date),
            FORMAT('%s days late', EXTRACT(DAY FROM pe.submission_date - pe.period_end_date::TIMESTAMPTZ)::INT),
            '≤ 60 days after period end',
            v_run_id,
            pe.data_source,
            pe.period_year,
            pe.period_month
        FROM period_ends pe
        JOIN facility f ON pe.facility_id = f.facility_id
        WHERE pe.submission_date > (pe.period_end_date + INTERVAL '60 days')
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'T02_aggregate_late_submission', 'timeliness', 'high', 'aggregate_report', v_scanned, v_issues);
    RAISE NOTICE 'T02 | Aggregate late submission: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- T03 | TIMELINESS | MEDIUM
-- CHW service record created > 30 days after service_date.
-- CHW mobile tools should sync within 7 days; 30-day threshold catches stale entries.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM chw_service_record;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'T03_chw_late_sync',
            'timeliness',
            'medium',
            'chw_service_record',
            'created_at',
            sr.service_id::TEXT,
            chw.facility_id,
            f.county_id,
            FORMAT('CHW service record %s: created_at (%s) is %s days after service_date (%s). CHW=%s.',
                   sr.service_id, sr.created_at::DATE,
                   (sr.created_at::DATE - sr.service_date),
                   sr.service_date, sr.chw_id),
            FORMAT('%s days lag', sr.created_at::DATE - sr.service_date),
            '≤ 30 days from service_date',
            v_run_id,
            sr.data_source
        FROM chw_service_record sr
        JOIN chw ON sr.chw_id = chw.chw_id
        LEFT JOIN facility f ON chw.facility_id = f.facility_id
        WHERE (sr.created_at::DATE - sr.service_date) > 30
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'T03_chw_late_sync', 'timeliness', 'medium', 'chw_service_record', v_scanned, v_issues);
    RAISE NOTICE 'T03 | CHW late sync: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- T04 | TIMELINESS | MEDIUM
-- ART patient overdue: next_appointment was > 90 days ago with no subsequent visit.
-- This flags patients who may have been lost to follow-up (LTFU).
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(DISTINCT patient_id) INTO v_scanned FROM art_visit WHERE next_appointment IS NOT NULL;

    WITH latest_visit AS (
        SELECT
            patient_id,
            facility_id,
            MAX(visit_date)      AS last_visit_date,
            MAX(next_appointment) AS last_appointment
        FROM art_visit
        GROUP BY patient_id, facility_id
    ),
    bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'T04_art_patient_overdue',
            'timeliness',
            'medium',
            'art_visit',
            'next_appointment',
            lv.patient_id::TEXT,
            lv.facility_id,
            f.county_id,
            FORMAT('Patient %s: last visit %s, next_appointment was %s (%s days ago). No visit recorded since. Possible LTFU.',
                   p.nupi_number, lv.last_visit_date, lv.last_appointment,
                   (CURRENT_DATE - lv.last_appointment)),
            FORMAT('overdue by %s days', CURRENT_DATE - lv.last_appointment),
            'Visit within 90 days of next_appointment',
            v_run_id,
            'KenyaEMR'
        FROM latest_visit lv
        JOIN patient p ON lv.patient_id = p.patient_id
        JOIN facility f ON lv.facility_id = f.facility_id
        WHERE lv.last_appointment < (CURRENT_DATE - INTERVAL '90 days')
          AND p.date_of_death IS NULL
          AND p.is_transferred_out = FALSE
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'T04_art_patient_overdue', 'timeliness', 'medium', 'art_visit', v_scanned, v_issues);
    RAISE NOTICE 'T04 | ART patient overdue (possible LTFU): % issues', v_issues;
END;

-- =============================================================================
-- UNIQUENESS CHECKS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- U01 | UNIQUENESS | HIGH
-- Duplicate patients: same facility + date_of_birth + sex within 14 days of each other.
-- Catches registration of the same person twice (e.g. duplicate CCC numbers).
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM patient WHERE date_of_birth IS NOT NULL;

    WITH dups AS (
        SELECT
            a.patient_id    AS pid_a,
            b.patient_id    AS pid_b,
            a.facility_id,
            a.date_of_birth,
            a.sex
        FROM patient a
        JOIN patient b
          ON a.facility_id     = b.facility_id
         AND a.sex              = b.sex
         AND a.date_of_birth   = b.date_of_birth
         AND a.patient_id      < b.patient_id    -- avoid self-join duplicates
         AND ABS(a.date_enrolled - b.date_enrolled) <= 14  -- enrolled within 2 weeks
        WHERE a.date_of_birth IS NOT NULL
    ),
    bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'U01_duplicate_patient',
            'uniqueness',
            'high',
            'patient',
            'patient_id',
            d.pid_b::TEXT,
            d.facility_id,
            f.county_id,
            FORMAT('Possible duplicate patient: patient %s and %s share facility_id=%s, DOB=%s, sex=%s and enrolled within 14 days.',
                   d.pid_a, d.pid_b, d.facility_id, d.date_of_birth, d.sex),
            FORMAT('pid_a=%s, pid_b=%s', d.pid_a, d.pid_b),
            'Each patient should have a unique NUPI and a single active record',
            v_run_id,
            'KenyaEMR'
        FROM dups d
        JOIN facility f ON d.facility_id = f.facility_id
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'U01_duplicate_patient', 'uniqueness', 'high', 'patient', v_scanned, v_issues);
    RAISE NOTICE 'U01 | Duplicate patient: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- U02 | UNIQUENESS | MEDIUM
-- Duplicate TB case numbers within the same county.
-- Case numbers should be unique per county per NTLD-P protocol.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM tb_case WHERE case_number IS NOT NULL;

    WITH dups AS (
        SELECT
            tb.case_number,
            f.county_id,
            COUNT(*)          AS cnt,
            MIN(tb.tb_case_id::TEXT) AS first_id,
            STRING_AGG(tb.tb_case_id::TEXT, ', ') AS all_ids
        FROM tb_case tb
        JOIN facility f ON tb.facility_id = f.facility_id
        WHERE tb.case_number IS NOT NULL
        GROUP BY tb.case_number, f.county_id
        HAVING COUNT(*) > 1
    ),
    bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'U02_duplicate_tb_case_number',
            'uniqueness',
            'medium',
            'tb_case',
            'case_number',
            d.first_id,
            NULL,
            d.county_id,
            FORMAT('TB case number ''%s'' appears %s times in county_id=%s. IDs: %s',
                   d.case_number, d.cnt, d.county_id, d.all_ids),
            d.case_number,
            'Unique case_number per county',
            v_run_id,
            'DHIS2'
        FROM dups d
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'U02_duplicate_tb_case_number', 'uniqueness', 'medium', 'tb_case', v_scanned, v_issues);
    RAISE NOTICE 'U02 | Duplicate TB case number: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- U03 | UNIQUENESS | HIGH
-- Duplicate aggregate reports: same facility + period + indicator.
-- Double-submission inflates all aggregate indicators.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM aggregate_report;

    WITH dups AS (
        SELECT
            facility_id,
            period_year,
            period_month,
            indicator_code,
            COUNT(*) AS cnt,
            MIN(report_id::TEXT) AS first_id
        FROM aggregate_report
        GROUP BY facility_id, period_year, period_month, indicator_code
        HAVING COUNT(*) > 1
    ),
    bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year, period_month
        )
        SELECT
            'U03_duplicate_aggregate_report',
            'uniqueness',
            'high',
            'aggregate_report',
            'indicator_code',
            d.first_id,
            d.facility_id,
            f.county_id,
            FORMAT('Indicator %s at facility %s for %s-%s has %s submissions. Duplicate submissions inflate aggregate totals.',
                   d.indicator_code, f.facility_name, d.period_year, d.period_month, d.cnt),
            FORMAT('%s submissions', d.cnt),
            '1 submission per facility-period-indicator',
            v_run_id,
            'DHIS2',
            d.period_year,
            d.period_month
        FROM dups d
        JOIN facility f ON d.facility_id = f.facility_id
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'U03_duplicate_aggregate_report', 'uniqueness', 'high', 'aggregate_report', v_scanned, v_issues);
    RAISE NOTICE 'U03 | Duplicate aggregate report: % issues', v_issues;
END;

-- =============================================================================
-- REFERENTIAL CHECKS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- R01 | REFERENTIAL | MEDIUM
-- Aggregate report references an inactive facility.
-- Closed facilities should not generate new reporting periods.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM aggregate_report;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year, period_month
        )
        SELECT
            'R01_report_for_inactive_facility',
            'referential',
            'medium',
            'aggregate_report',
            'facility_id',
            ar.report_id::TEXT,
            ar.facility_id,
            f.county_id,
            FORMAT('Aggregate report for %s at facility ''%s'' (mfl=%s), which is marked inactive (closed). Reporting should have ceased.',
                   ar.indicator_code, f.facility_name, f.mfl_code),
            FORMAT('facility_id=%s (inactive)', ar.facility_id),
            'Only active facilities should submit reports',
            v_run_id,
            ar.data_source,
            ar.period_year,
            ar.period_month
        FROM aggregate_report ar
        JOIN facility f ON ar.facility_id = f.facility_id
        WHERE f.is_active = FALSE
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'R01_report_for_inactive_facility', 'referential', 'medium', 'aggregate_report', v_scanned, v_issues);
    RAISE NOTICE 'R01 | Report for inactive facility: % issues', v_issues;
END;

-- =============================================================================
-- PLAUSIBILITY CHECKS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- P01 | PLAUSIBILITY | HIGH
-- Adult patient (DOB before 2010) with weight < 15kg in ART visit.
-- An adult under 15kg is clinically incompatible with life without critical care.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned
    FROM art_visit av
    JOIN patient p ON av.patient_id = p.patient_id
    WHERE p.date_of_birth < '2010-01-01'
      AND av.weight_kg IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'P01_adult_weight_implausible',
            'plausibility',
            'high',
            'art_visit',
            'weight_kg',
            av.visit_id::TEXT,
            av.facility_id,
            f.county_id,
            FORMAT('ART visit %s: adult patient (DOB=%s) has weight_kg = %s. Minimum plausible adult weight is 15kg.',
                   av.visit_id, p.date_of_birth, av.weight_kg),
            av.weight_kg::TEXT,
            '≥ 15kg for adults (DOB < 2010-01-01)',
            v_run_id,
            av.data_source
        FROM art_visit av
        JOIN patient p ON av.patient_id = p.patient_id
        JOIN facility f ON av.facility_id = f.facility_id
        WHERE p.date_of_birth < '2010-01-01'
          AND av.weight_kg IS NOT NULL
          AND av.weight_kg < 15
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'P01_adult_weight_implausible', 'plausibility', 'high', 'art_visit', v_scanned, v_issues);
    RAISE NOTICE 'P01 | Adult weight implausible: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- P02 | PLAUSIBILITY | MEDIUM
-- CD4 count > 2500 cells/µL at ART enrollment.
-- CD4 > 2500 is extremely rare even in healthy HIV-negative adults and
-- suggests a data entry error (e.g. transposing CD4% as CD4 count).
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM art_enrollment WHERE cd4_at_start IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'P02_cd4_implausibly_high',
            'plausibility',
            'medium',
            'art_enrollment',
            'cd4_at_start',
            ae.enrollment_id::TEXT,
            ae.facility_id,
            f.county_id,
            FORMAT('ART enrollment %s: cd4_at_start = %s cells/µL. Values >2500 are implausible; verify whether a CD4%% was entered as an absolute count.',
                   ae.enrollment_id, ae.cd4_at_start),
            ae.cd4_at_start::TEXT,
            '≤ 2500 cells/µL (typical ART initiation range: 0–1500)',
            v_run_id,
            'KenyaEMR'
        FROM art_enrollment ae
        JOIN facility f ON ae.facility_id = f.facility_id
        WHERE ae.cd4_at_start > 2500
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'P02_cd4_implausibly_high', 'plausibility', 'medium', 'art_enrollment', v_scanned, v_issues);
    RAISE NOTICE 'P02 | CD4 implausibly high: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- P03 | PLAUSIBILITY | HIGH
-- TX_CURR month-over-month jump > 200% at the same facility.
-- A tripling of patients on treatment in a single month is almost certainly
-- a data entry error or double-counting, not a real programmatic event.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned
    FROM aggregate_report
    WHERE indicator_code = 'TX_CURR' AND period_type = 'monthly';

    WITH tx_series AS (
        SELECT
            facility_id,
            period_year,
            period_month,
            value AS tx_curr,
            LAG(value) OVER (PARTITION BY facility_id ORDER BY period_year, period_month) AS prev_tx_curr,
            report_id
        FROM aggregate_report
        WHERE indicator_code = 'TX_CURR'
          AND period_type = 'monthly'
    ),
    bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source, period_year, period_month
        )
        SELECT
            'P03_tx_curr_jump',
            'plausibility',
            'high',
            'aggregate_report',
            'TX_CURR',
            ts.report_id::TEXT,
            ts.facility_id,
            f.county_id,
            FORMAT('TX_CURR at %s jumped from %s (%s-%s) to %s (%s-%s): a %s%% increase. Threshold = 200%%.',
                   f.facility_name, ts.prev_tx_curr,
                   ts.period_year, ts.period_month - 1,
                   ts.tx_curr, ts.period_year, ts.period_month,
                   ROUND(((ts.tx_curr - ts.prev_tx_curr) / NULLIF(ts.prev_tx_curr, 0)) * 100, 1)),
            ts.tx_curr::TEXT,
            FORMAT('≤ %s (200%% of previous month)', ts.prev_tx_curr * 2),
            v_run_id,
            'DHIS2',
            ts.period_year,
            ts.period_month
        FROM tx_series ts
        JOIN facility f ON ts.facility_id = f.facility_id
        WHERE ts.prev_tx_curr IS NOT NULL
          AND ts.prev_tx_curr > 0
          AND ts.tx_curr > (ts.prev_tx_curr * 2)  -- >200% of previous month
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'P03_tx_curr_jump', 'plausibility', 'high', 'aggregate_report', v_scanned, v_issues);
    RAISE NOTICE 'P03 | TX_CURR implausible jump: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- P04 | PLAUSIBILITY | MEDIUM
-- Viral load > 10,000,000 copies/mL.
-- Most assays cap at ~10M; values above this are likely transcription errors.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM viral_load WHERE vl_result IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'P04_vl_implausibly_high',
            'plausibility',
            'medium',
            'viral_load',
            'vl_result',
            vl.vl_id::TEXT,
            vl.facility_id,
            f.county_id,
            FORMAT('Viral load %s: vl_result = %s copies/mL exceeds the upper detection limit of most assays (10,000,000). Probable transcription error.',
                   vl.vl_id, vl.vl_result),
            vl.vl_result::TEXT,
            '≤ 10,000,000 copies/mL',
            v_run_id,
            vl.data_source
        FROM viral_load vl
        JOIN facility f ON vl.facility_id = f.facility_id
        WHERE vl.vl_result > 10000000
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'P04_vl_implausibly_high', 'plausibility', 'medium', 'viral_load', v_scanned, v_issues);
    RAISE NOTICE 'P04 | VL implausibly high: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- P05 | PLAUSIBILITY | HIGH
-- Stock record: days_out_of_stock > 31.
-- A monthly stock record cannot have more than 31 stockout days.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM stock_record;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'P05_days_stockout_exceeds_month',
            'plausibility',
            'high',
            'stock_record',
            'days_out_of_stock',
            sr.stock_id::TEXT,
            sr.facility_id,
            f.county_id,
            FORMAT('Stock record %s at %s: days_out_of_stock = %s which exceeds the maximum possible days in a month (31).',
                   sr.stock_id, f.facility_name, sr.days_out_of_stock),
            sr.days_out_of_stock::TEXT,
            '0–31 days',
            v_run_id,
            sr.data_source
        FROM stock_record sr
        JOIN facility f ON sr.facility_id = f.facility_id
        WHERE sr.days_out_of_stock > 31
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'P05_days_stockout_exceeds_month', 'plausibility', 'high', 'stock_record', v_scanned, v_issues);
    RAISE NOTICE 'P05 | Days stockout > 31: % issues', v_issues;
END;

-- ---------------------------------------------------------------------------
-- P06 | PLAUSIBILITY | CRITICAL
-- ANC systolic BP > 200 mmHg (hypertensive crisis territory).
-- This is a clinical red flag. It likely represents a data entry error
-- (e.g. 120 entered as 1200) but must be reviewed.
-- ---------------------------------------------------------------------------
DECLARE
    v_run_id    UUID := current_setting('dq.run_id')::UUID;
    v_issues    INT;
    v_scanned   INT;
BEGIN
    SELECT COUNT(*) INTO v_scanned FROM anc_visit WHERE systolic_bp IS NOT NULL;

    WITH bad AS (
        INSERT INTO data_quality_issue (
            check_name, check_category, severity,
            source_table, source_column, record_id,
            facility_id, county_id,
            issue_description, raw_value, expected_value,
            check_run_id, data_source
        )
        SELECT
            'P06_anc_systolic_bp_extreme',
            'plausibility',
            'critical',
            'anc_visit',
            'systolic_bp',
            av.anc_visit_id::TEXT,
            av.facility_id,
            f.county_id,
            FORMAT('ANC visit %s (%s): systolic_bp = %s mmHg. Values >200 mmHg indicate hypertensive crisis or data entry error. Requires immediate clinical review.',
                   av.anc_visit_id, av.visit_date, av.systolic_bp),
            av.systolic_bp::TEXT,
            '< 200 mmHg (expected normal: 90–140)',
            v_run_id,
            av.data_source
        FROM anc_visit av
        JOIN facility f ON av.facility_id = f.facility_id
        WHERE av.systolic_bp > 200
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_issues FROM bad;

    PERFORM public.dq_log_check(v_run_id, 'P06_anc_systolic_bp_extreme', 'plausibility', 'critical', 'anc_visit', v_scanned, v_issues);
    RAISE NOTICE 'P06 | ANC extreme systolic BP: % issues', v_issues;
END;

-- =============================================================================
-- STEP FINAL: Close the engine run, update totals
-- =============================================================================
DECLARE
    v_run_id        UUID := current_setting('dq.run_id')::UUID;
    v_checks_run    INT;
    v_total_issues  INT;
BEGIN
    SELECT COUNT(*)     INTO v_checks_run  FROM dq_check_log  WHERE run_id = v_run_id;
    SELECT COUNT(*)     INTO v_total_issues FROM data_quality_issue WHERE check_run_id = v_run_id;

    UPDATE dq_engine_run
    SET
        run_completed_at = now(),
        checks_executed  = v_checks_run,
        issues_found     = v_total_issues
    WHERE run_id = v_run_id;

    RAISE NOTICE '====================================================';
    RAISE NOTICE 'DQ Engine run complete.';
    RAISE NOTICE '  run_id         : %', v_run_id;
    RAISE NOTICE '  checks executed: %', v_checks_run;
    RAISE NOTICE '  total issues   : %', v_total_issues;
    RAISE NOTICE '====================================================';
    RAISE NOTICE 'Query data_quality_issue WHERE check_run_id = ''%'' to review findings.', v_run_id;
END;
    RETURN v_run_id;
END;
$engine$;

COMMENT ON FUNCTION public.run_dq_engine(VARCHAR) IS
'Runs all 36 data-quality checks, records a run audit, and returns the run UUID. Safe for pg_cron and external orchestrators.';
