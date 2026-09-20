-- PUBLIC HEALTH DATA QUALITY ENGINE
-- File: 05_resolution_procedures.sql
-- Purpose: Stored procedures and functions for managing the DQ issue lifecycle.
--          These functions let data managers and automated pipelines act on
--          issues found by the engine.
--
-- Procedures:
--   resolve_issue()         - Mark a single issue resolved
--   bulk_resolve_by_check() - Batch-resolve all issues from a specific check
--   waive_issue()           - Waive an issue with documented reason
--   mark_false_positive()   - Mark an issue as a false positive
--   reopen_issue()          - Reopen a resolved issue if the fix didn't hold
--   suppress_check()        - Record a temporary suppression request
--
-- Functions (read-only):
--   get_facility_dq_score() - Returns numeric DQ score for a single facility
--   get_open_issues()       - Returns open issues for a facility as a result set
--   check_is_suppressed()   - Tests whether a matching suppression request exists
--
-- Run after: 01_schema.sql

SET search_path TO public;

-- ---------------------------------------------------------------------------
-- SUPPORT TABLE: Check suppression registry
-- Stores a scoped suppression request for a defined period, for example during
-- a known data migration or system outage. The engine does not yet apply it.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dq_check_suppression (
    suppression_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    check_name          VARCHAR(100) NOT NULL,
    facility_id         INT REFERENCES facility(facility_id),
    county_id           SMALLINT REFERENCES county(county_id),
    suppressed_by       VARCHAR(80) NOT NULL,
    suppressed_at       TIMESTAMPTZ DEFAULT now(),
    suppression_reason  TEXT NOT NULL,
    valid_from          DATE NOT NULL DEFAULT CURRENT_DATE,
    valid_until         DATE NOT NULL,
    is_active           BOOLEAN DEFAULT TRUE,

    -- Either facility or county must be specified (not both null)
    CONSTRAINT suppression_scope CHECK (
        facility_id IS NOT NULL OR county_id IS NOT NULL
    ),
    -- valid_until must be after valid_from
    CONSTRAINT suppression_dates CHECK (valid_until > valid_from)
);

COMMENT ON TABLE dq_check_suppression IS
'Registry of requested temporary DQ check suppressions. The current engine does not consult this table, so it does not skip checks. Each request requires a reason.';

-- ---------------------------------------------------------------------------
-- FUNCTION: resolve_issue
-- Marks a single issue as resolved and records who resolved it and why.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_issue(
    p_issue_id          UUID,
    p_resolved_by       VARCHAR(80),
    p_resolution_notes  TEXT
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_current_status    issue_status;
    v_check_name        VARCHAR(100);
BEGIN
    -- Validate the issue exists and get current state
    SELECT status, check_name
    INTO v_current_status, v_check_name
    FROM data_quality_issue
    WHERE issue_id = p_issue_id;

    IF NOT FOUND THEN
        RETURN FORMAT('ERROR: issue_id %s not found.', p_issue_id);
    END IF;

    -- Only open or confirmed issues can be resolved
    IF v_current_status NOT IN ('open', 'confirmed') THEN
        RETURN FORMAT('ERROR: Issue %s has status ''%s'' and cannot be resolved. Only open/confirmed issues can be resolved.',
                      p_issue_id, v_current_status);
    END IF;

    -- Require a resolution note
    IF p_resolution_notes IS NULL OR TRIM(p_resolution_notes) = '' THEN
        RETURN 'ERROR: resolution_notes is required. Document what fix was applied.';
    END IF;

    UPDATE data_quality_issue
    SET
        status              = 'resolved',
        resolved_by         = p_resolved_by,
        resolved_at         = now(),
        resolution_notes    = p_resolution_notes,
        updated_at          = now()
    WHERE issue_id = p_issue_id;

    RETURN FORMAT('OK: Issue %s (%s) resolved by %s at %s.',
                  p_issue_id, v_check_name, p_resolved_by, now()::TIMESTAMPTZ(0));
END;
$$;

COMMENT ON FUNCTION resolve_issue IS
'Mark a single DQ issue as resolved. Requires a non-empty resolution_notes to ensure the fix is documented. Returns a status message.';


-- ---------------------------------------------------------------------------
-- FUNCTION: bulk_resolve_by_check
-- Batch-resolve all open issues from a specific check, optionally scoped
-- to a facility or county. Useful after a data migration or system fix
-- that addresses a known systematic error.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bulk_resolve_by_check(
    p_check_name        VARCHAR(100),
    p_resolved_by       VARCHAR(80),
    p_resolution_notes  TEXT,
    p_facility_id       INT DEFAULT NULL,   -- NULL = all facilities
    p_county_id         SMALLINT DEFAULT NULL
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_rows_updated INT;
BEGIN
    IF p_resolution_notes IS NULL OR TRIM(p_resolution_notes) = '' THEN
        RETURN 'ERROR: resolution_notes is required for bulk resolution.';
    END IF;

    UPDATE data_quality_issue
    SET
        status              = 'resolved',
        resolved_by         = p_resolved_by,
        resolved_at         = now(),
        resolution_notes    = p_resolution_notes,
        updated_at          = now()
    WHERE check_name   = p_check_name
      AND status       IN ('open', 'confirmed')
      AND (p_facility_id IS NULL OR facility_id = p_facility_id)
      AND (p_county_id  IS NULL OR county_id    = p_county_id);

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    RETURN FORMAT('OK: %s issues for check ''%s'' resolved by %s. Scope: facility=%s, county=%s.',
                  v_rows_updated, p_check_name, p_resolved_by,
                  COALESCE(p_facility_id::TEXT, 'all'),
                  COALESCE(p_county_id::TEXT, 'all'));
END;
$$;

COMMENT ON FUNCTION bulk_resolve_by_check IS
'Batch-resolve all open issues matching a check name. Optionally scoped to a specific facility or county. Always requires documented resolution notes.';


-- ---------------------------------------------------------------------------
-- FUNCTION: waive_issue
-- Marks an issue as waived (acknowledged but accepted).
-- Use when the data is a known limitation (e.g. paper records with missing DOB)
-- that cannot be retrospectively fixed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION waive_issue(
    p_issue_id          UUID,
    p_waived_by         VARCHAR(80),
    p_waiver_reason     TEXT
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_current_status    issue_status;
BEGIN
    SELECT status INTO v_current_status
    FROM data_quality_issue
    WHERE issue_id = p_issue_id;

    IF NOT FOUND THEN
        RETURN FORMAT('ERROR: issue_id %s not found.', p_issue_id);
    END IF;

    IF v_current_status = 'resolved' THEN
        RETURN FORMAT('ERROR: Issue %s is already resolved. Cannot waive a resolved issue.', p_issue_id);
    END IF;

    IF v_current_status = 'waived' THEN
        RETURN FORMAT('WARNING: Issue %s is already waived.', p_issue_id);
    END IF;

    IF p_waiver_reason IS NULL OR TRIM(p_waiver_reason) = '' THEN
        RETURN 'ERROR: waiver_reason is required.';
    END IF;

    UPDATE data_quality_issue
    SET
        status              = 'waived',
        resolved_by         = p_waived_by,
        resolved_at         = now(),
        resolution_notes    = 'WAIVED: ' || p_waiver_reason,
        updated_at          = now()
    WHERE issue_id = p_issue_id;

    RETURN FORMAT('OK: Issue %s waived by %s.', p_issue_id, p_waived_by);
END;
$$;

COMMENT ON FUNCTION waive_issue IS
'Mark a DQ issue as waived. A waiver acknowledges the issue exists but accepts it due to documented constraints. Waived issues remain visible in reporting.';


-- ---------------------------------------------------------------------------
-- FUNCTION: mark_false_positive
-- Marks an issue as a false positive.
-- Records this to inform the false positive rate calculation in A05/D05.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_false_positive(
    p_issue_id          UUID,
    p_marked_by         VARCHAR(80),
    p_explanation       TEXT
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_current_status    issue_status;
    v_check_name        VARCHAR(100);
BEGIN
    SELECT status, check_name
    INTO v_current_status, v_check_name
    FROM data_quality_issue
    WHERE issue_id = p_issue_id;

    IF NOT FOUND THEN
        RETURN FORMAT('ERROR: issue_id %s not found.', p_issue_id);
    END IF;

    IF p_explanation IS NULL OR TRIM(p_explanation) = '' THEN
        RETURN 'ERROR: explanation is required. Why is this a false positive?';
    END IF;

    UPDATE data_quality_issue
    SET
        status              = 'false_positive',
        resolved_by         = p_marked_by,
        resolved_at         = now(),
        resolution_notes    = 'FALSE POSITIVE: ' || p_explanation,
        updated_at          = now()
    WHERE issue_id = p_issue_id;

    -- Alert if this check has a high FP rate (informational only)
    DECLARE
        v_fp_rate NUMERIC;
    BEGIN
        SELECT
            ROUND(
                COUNT(*) FILTER (WHERE status = 'false_positive')::NUMERIC /
                NULLIF(COUNT(*), 0) * 100, 1
            )
        INTO v_fp_rate
        FROM data_quality_issue
        WHERE check_name = v_check_name;

        IF v_fp_rate > 20 THEN
            RAISE NOTICE 'ALERT: Check % now has a false positive rate of % percent. Consider reviewing check logic.',
                v_check_name, v_fp_rate;
        END IF;
    END;

    RETURN FORMAT('OK: Issue %s marked as false positive by %s. Check: %s.',
                  p_issue_id, p_marked_by, v_check_name);
END;
$$;

COMMENT ON FUNCTION mark_false_positive IS
'Mark a DQ issue as a false positive. Increments the check-level FP rate. If FP rate exceeds 20%, a NOTICE is raised to prompt check logic review.';


-- ---------------------------------------------------------------------------
-- FUNCTION: reopen_issue
-- Reopens a resolved issue. Used when a fix was applied but the problem
-- recurred (e.g. upstream system sent bad data again).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reopen_issue(
    p_issue_id      UUID,
    p_reopened_by   VARCHAR(80),
    p_reason        TEXT
) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_current_status issue_status;
BEGIN
    SELECT status INTO v_current_status
    FROM data_quality_issue
    WHERE issue_id = p_issue_id;

    IF NOT FOUND THEN
        RETURN FORMAT('ERROR: issue_id %s not found.', p_issue_id);
    END IF;

    IF v_current_status = 'open' THEN
        RETURN FORMAT('WARNING: Issue %s is already open.', p_issue_id);
    END IF;

    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RETURN 'ERROR: reason is required to reopen an issue.';
    END IF;

    UPDATE data_quality_issue
    SET
        status              = 'open',
        resolved_by         = NULL,
        resolved_at         = NULL,
        resolution_notes    = FORMAT('REOPENED by %s at %s: %s', p_reopened_by, now()::TIMESTAMPTZ(0), p_reason),
        updated_at          = now()
    WHERE issue_id = p_issue_id;

    RETURN FORMAT('OK: Issue %s reopened by %s.', p_issue_id, p_reopened_by);
END;
$$;

COMMENT ON FUNCTION reopen_issue IS
'Reopen a previously resolved issue. Clears the resolver fields and resets status to open. Requires a documented reason.';


-- ---------------------------------------------------------------------------
-- FUNCTION: suppress_check
-- Records a suppression request for a facility or county for a defined period.
-- The current DQ engine does not consult this registry.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION suppress_check(
    p_check_name        VARCHAR(100),
    p_suppressed_by     VARCHAR(80),
    p_reason            TEXT,
    p_valid_until       DATE,
    p_facility_id       INT DEFAULT NULL,
    p_county_id         SMALLINT DEFAULT NULL
) RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
    IF p_facility_id IS NULL AND p_county_id IS NULL THEN
        RETURN 'ERROR: Either facility_id or county_id must be specified for a suppression.';
    END IF;

    IF p_valid_until <= CURRENT_DATE THEN
        RETURN 'ERROR: valid_until must be a future date.';
    END IF;

    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RETURN 'ERROR: suppression_reason is required.';
    END IF;

    INSERT INTO dq_check_suppression (
        check_name, facility_id, county_id,
        suppressed_by, suppression_reason,
        valid_from, valid_until
    ) VALUES (
        p_check_name, p_facility_id, p_county_id,
        p_suppressed_by, p_reason,
        CURRENT_DATE, p_valid_until
    );

    RETURN FORMAT('OK: Suppression request for check ''%s'' recorded for facility=%s / county=%s until %s by %s.',
                  p_check_name,
                  COALESCE(p_facility_id::TEXT, 'n/a'),
                  COALESCE(p_county_id::TEXT, 'n/a'),
                  p_valid_until, p_suppressed_by);
END;
$$;

COMMENT ON FUNCTION suppress_check IS
'Record a DQ check suppression request for a facility or county until a given date. It does not bypass engine checks until the engine is integrated with this registry. Requires a reason.';


-- ---------------------------------------------------------------------------
-- FUNCTION: get_facility_dq_score
-- Returns a single numeric DQ burden score for a facility.
-- Suitable for use in KPI cards and dashboards.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_facility_dq_score(
    p_facility_id INT
) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(
        CASE severity
            WHEN 'critical' THEN 10
            WHEN 'high'     THEN 5
            WHEN 'medium'   THEN 2
            WHEN 'low'      THEN 1
            ELSE 0
        END
    ), 0)
    FROM data_quality_issue
    WHERE facility_id = p_facility_id
      AND status = 'open';
$$;

COMMENT ON FUNCTION get_facility_dq_score IS
'Returns the weighted DQ burden score for a single facility. critical=10, high=5, medium=2, low=1. A score of 0 means no open issues.';


-- ---------------------------------------------------------------------------
-- FUNCTION: check_is_suppressed
-- Returns TRUE if a matching active suppression request exists for the facility.
-- The current DQ engine does not call this function.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_is_suppressed(
    p_check_name  VARCHAR(100),
    p_facility_id INT
) RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM dq_check_suppression cs
        JOIN facility f ON f.facility_id = p_facility_id
        WHERE cs.check_name  = p_check_name
          AND cs.is_active   = TRUE
          AND cs.valid_from  <= CURRENT_DATE
          AND cs.valid_until >= CURRENT_DATE
          AND (
              cs.facility_id = p_facility_id
              OR cs.county_id = f.county_id
          )
    );
$$;

COMMENT ON FUNCTION check_is_suppressed IS
'Returns TRUE when the given check has an active facility-level or county-level suppression request. The current engine does not call this function.';


-- ---------------------------------------------------------------------------
-- FUNCTION: get_open_issues
-- Returns all open issues for a facility as a table result.
-- Designed for use in reporting tools and application integration.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_open_issues(
    p_facility_id       INT,
    p_severity_filter   severity_level DEFAULT NULL,   -- NULL = all severities
    p_category_filter   check_category DEFAULT NULL    -- NULL = all categories
)
RETURNS TABLE (
    issue_id          UUID,
    check_name        VARCHAR(100),
    check_category    check_category,
    severity          severity_level,
    source_table      VARCHAR(60),
    source_column     VARCHAR(60),
    record_id         TEXT,
    issue_description TEXT,
    raw_value         TEXT,
    expected_value    TEXT,
    detected_at       TIMESTAMPTZ,
    days_open         INT
) LANGUAGE sql STABLE AS $$
    SELECT
        dqi.issue_id,
        dqi.check_name,
        dqi.check_category,
        dqi.severity,
        dqi.source_table,
        dqi.source_column,
        dqi.record_id,
        dqi.issue_description,
        dqi.raw_value,
        dqi.expected_value,
        dqi.detected_at,
        (CURRENT_DATE - dqi.detected_at::DATE)::INT AS days_open
    FROM data_quality_issue dqi
    WHERE dqi.facility_id = p_facility_id
      AND dqi.status = 'open'
      AND (p_severity_filter IS NULL OR dqi.severity = p_severity_filter)
      AND (p_category_filter IS NULL OR dqi.check_category = p_category_filter)
    ORDER BY
        CASE dqi.severity
            WHEN 'critical' THEN 1
            WHEN 'high'     THEN 2
            WHEN 'medium'   THEN 3
            WHEN 'low'      THEN 4
            ELSE 5
        END,
        dqi.detected_at DESC;
$$;

COMMENT ON FUNCTION get_open_issues IS
'Returns open DQ issues for a given facility, optionally filtered by severity or category. Ordered by severity (critical first), then by detection time.';


-- ---------------------------------------------------------------------------
-- TRIGGER: auto-update updated_at on data_quality_issue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dqi_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_dqi_updated_at ON data_quality_issue;
CREATE TRIGGER trg_dqi_updated_at
    BEFORE UPDATE ON data_quality_issue
    FOR EACH ROW EXECUTE FUNCTION dqi_set_updated_at();

-- ---------------------------------------------------------------------------
-- TRIGGER: auto-update updated_at on patient
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION patient_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_patient_updated_at ON patient;
CREATE TRIGGER trg_patient_updated_at
    BEFORE UPDATE ON patient
    FOR EACH ROW EXECUTE FUNCTION patient_set_updated_at();


-- ---------------------------------------------------------------------------
-- USAGE CASES uncomment to test
-- ---------------------------------------------------------------------------

/*
-- Resolve a specific issue:
SELECT resolve_issue(
    '<uuid-from-data_quality_issue>',
    'wayne.omondi',
    'Corrected DOB in KenyaEMR from 2035 to 1993. System entry error confirmed with CCC card.'
);

-- Waive all missing DOB issues for Turkana County (retrospective paper records):
SELECT bulk_resolve_by_check(
    'C01_patient_missing_dob',
    'dr.ekwom',
    'Paper CIF records from 2010–2015 pre-date DOB capture requirement. Cannot be retrospectively obtained.',
    NULL,
    23   -- county_id = Turkana
);

-- Record a notification-delay suppression request for Turkana during NTLD-P data migration:
SELECT suppress_check(
    'T01_tb_notification_delay',
    'data.manager',
    'NTLD-P data migration in progress for Turkana Q1 2022 historical records. Check will fire on legacy data.',
    CURRENT_DATE + 30,
    NULL,
    23
);

-- Get DQ score for KNH:
SELECT get_facility_dq_score(
    (SELECT facility_id FROM facility WHERE mfl_code = '14880')
);

-- Get all critical issues for Jaramogi:
SELECT * FROM get_open_issues(
    (SELECT facility_id FROM facility WHERE mfl_code = '14901'),
    'critical'::severity_level
);
*/