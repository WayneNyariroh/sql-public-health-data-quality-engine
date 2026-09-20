-- =============================================================================
-- PUBLIC HEALTH DATA QUALITY ENGINE
-- File: 01_schema.sql
-- Purpose: Core schema definition for Kenya public health reporting system
--          and the data_quality_issue registry that the DQ engine populates.
--
-- Domain coverage:
--   - Facility registry (master reference)
--   - Patient-level ART/HIV program records
--   - TB case notifications and treatment outcomes
--   - Maternal & child health (ANC, delivery, immunization)
--   - Community health worker (CHW) service records
--   - DHIS2-style aggregate period reports
--   - Stock/commodity management (ARV, vaccines)
--
-- The data_quality_issue table is the single sink for all automated checks.
-- Every check inserts a row here; downstream reporting queries this table.
--
-- Author: Wayne Willis Omondi
-- Environment: PostgreSQL 18
-- =============================================================================

-- ---------------------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- for fuzzy duplicate detection

-- ---------------------------------------------------------------------------
-- ENUMERATIONS
-- ---------------------------------------------------------------------------

CREATE TYPE severity_level AS ENUM ('critical', 'high', 'medium', 'low', 'info');

CREATE TYPE issue_status AS ENUM (
    'open', -- newly detected, not yet reviewed
    'confirmed', -- reviewed and confirmed as real issue
    'resolved', -- fix applied, issue closed
    'waived', -- acknowledged but accepted (e.g. data entry constraint)
    'false_positive' -- check fired but data is actually correct
);

CREATE TYPE check_category AS ENUM (
    'completeness', -- missing required fields
    'validity', -- values outside expected ranges/codes
    'consistency', -- logical contradictions between fields
    'timeliness', -- data submitted outside acceptable windows
    'uniqueness', -- duplicate records
    'referential', -- broken foreign-key-style relationships
    'plausibility' -- statistically unlikely but not strictly invalid
);

CREATE TYPE sex_type AS ENUM ('male', 'female', 'intersex', 'unknown');
CREATE TYPE hiv_status AS ENUM ('positive', 'negative', 'unknown', 'not_tested');
CREATE TYPE art_regimen AS ENUM ('TLD', 'TLE', 'AZT_3TC_NVP', 'ABC_3TC_LPV', 'DTG_based_other', 'other');
CREATE TYPE tb_treatment_outcome AS ENUM (
    'cured', 'treatment_completed', 'treatment_failed',
    'died', 'lost_to_follow_up', 'not_evaluated', 'on_treatment'
);
CREATE TYPE tb_case_type AS ENUM ('new', 'relapse', 'treatment_after_failure', 'treatment_after_ltfu', 'other_previously_treated', 'unknown');
CREATE TYPE data_source AS ENUM ('DHIS2', 'KenyaEMR', 'KHIS', 'OpenMRS', 'paper_CIF', 'mobile_CHW', 'lab_LIMS', 'manual_entry');

-- ---------------------------------------------------------------------------
-- REFERENCE TABLES
-- ---------------------------------------------------------------------------

-- Kenya administrative units (county/sub-county)
CREATE TABLE county (
    county_id        SMALLINT PRIMARY KEY,
    county_name      VARCHAR(60) NOT NULL,
    region           VARCHAR(40), -- e.g. Nyanza, Coast, Central
    created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE sub_county (
    sub_county_id    SMALLINT PRIMARY KEY,
    sub_county_name  VARCHAR(80) NOT NULL,
    county_id        SMALLINT NOT NULL REFERENCES county(county_id),
    created_at       TIMESTAMPTZ DEFAULT now()
);

-- Master Facility List (MFL), the reference for facility identity.
CREATE TABLE facility (
    facility_id       SERIAL PRIMARY KEY,
    mfl_code          VARCHAR(10) UNIQUE NOT NULL, -- official MFL code e.g. "14880"
    facility_name     VARCHAR(120) NOT NULL,
    facility_type     VARCHAR(40), -- hospital, health centre, dispensary, etc.
    ownership         VARCHAR(30), -- public, faith-based, private, NGO
    sub_county_id     SMALLINT REFERENCES sub_county(sub_county_id),
    county_id         SMALLINT REFERENCES county(county_id),
    latitude          NUMERIC(9,6),
    longitude         NUMERIC(9,6),
    is_active         BOOLEAN DEFAULT TRUE,
    dhis2_org_unit    VARCHAR(20), -- DHIS2 organisation unit UID
    opened_date       DATE,
    closed_date       DATE,
    created_at        TIMESTAMPTZ DEFAULT now(),
    updated_at        TIMESTAMPTZ DEFAULT now()
);

-- ICD-10/SNOMED concept codes used across the domain
CREATE TABLE concept_code (
    code_id      SERIAL PRIMARY KEY,
    code_system  VARCHAR(20) NOT NULL, -- 'ICD10', 'SNOMED', 'CIEL', 'LOINC'
    code         VARCHAR(20) NOT NULL,
    description  TEXT,
    UNIQUE(code_system, code)
);

-- ---------------------------------------------------------------------------
-- PATIENT REGISTRY
-- ---------------------------------------------------------------------------

-- Core patient demographic record (de-identified for this schema)
CREATE TABLE patient (
    patient_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    facility_id       INT NOT NULL REFERENCES facility(facility_id),
    nupi_number       VARCHAR(20) UNIQUE, -- National Unique Patient Identifier
    date_of_birth     DATE,
    sex               sex_type NOT NULL DEFAULT 'unknown',
    county_of_birth   SMALLINT REFERENCES county(county_id),
    date_enrolled     DATE NOT NULL,
    date_of_death     DATE,
    is_transferred_out BOOLEAN DEFAULT FALSE,
    transfer_out_date  DATE,
    data_source        data_source DEFAULT 'KenyaEMR',
    created_at         TIMESTAMPTZ DEFAULT now(),
    updated_at         TIMESTAMPTZ DEFAULT now(),

    -- Basic constraint: can't die before being born
    CONSTRAINT patient_dod_after_dob CHECK (
        date_of_death IS NULL OR date_of_birth IS NULL OR date_of_death >= date_of_birth
    ),
    -- Can't be enrolled after death
    CONSTRAINT enrollment_before_death CHECK (
        date_of_death IS NULL OR date_enrolled <= date_of_death
    )
);

-- ---------------------------------------------------------------------------
-- HIV / ART MODULE
-- ---------------------------------------------------------------------------

CREATE TABLE art_enrollment (
    enrollment_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id          UUID NOT NULL REFERENCES patient(patient_id),
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    art_start_date      DATE NOT NULL,
    entry_point         VARCHAR(60), -- VCT, PMTCT, TB/HIV, inpatient, OPD, VMMC.
    who_stage_at_start  SMALLINT CHECK (who_stage_at_start BETWEEN 1 AND 4),
    cd4_at_start        NUMERIC(6,1), -- cells/µL
    weight_at_start     NUMERIC(5,1), -- kg
    height_at_start     NUMERIC(5,1), -- cm (needed for paediatric weight-for-height)
    initial_regimen     art_regimen,
    is_active           BOOLEAN DEFAULT TRUE,
    created_at          TIMESTAMPTZ DEFAULT now()
);

-- Viral load test results
CREATE TABLE viral_load (
    vl_id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id          UUID NOT NULL REFERENCES patient(patient_id),
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    enrollment_id       UUID REFERENCES art_enrollment(enrollment_id),
    sample_date         DATE NOT NULL,
    result_date         DATE,
    vl_result           NUMERIC(10,2), -- copies/mL; NULL means LDL (below detection)
    is_ldl              BOOLEAN DEFAULT FALSE, -- Low/Detectable Level flag
    vl_category         VARCHAR(20) -- 'suppressed', 'unsuppressed', 'high_vl'
        CHECK (vl_category IN ('suppressed', 'unsuppressed', 'high_vl', NULL)),
    ordering_clinician  VARCHAR(80),
    lab_name            VARCHAR(80),
    data_source         data_source DEFAULT 'lab_LIMS',
    created_at          TIMESTAMPTZ DEFAULT now(),

    -- Result date cannot precede sample date
    CONSTRAINT vl_result_after_sample CHECK (result_date IS NULL OR result_date >= sample_date)
);

-- ART visit records (pharmacy + clinical)
CREATE TABLE art_visit (
    visit_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id          UUID NOT NULL REFERENCES patient(patient_id),
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    visit_date          DATE NOT NULL,
    next_appointment    DATE,
    weight_kg           NUMERIC(5,1),
    current_regimen     art_regimen,
    days_dispensed      SMALLINT, -- number of days of medication dispensed
    adherence_score     SMALLINT CHECK (adherence_score BETWEEN 0 AND 100),
    clinician_notes     TEXT,
    data_source         data_source DEFAULT 'KenyaEMR',
    created_at          TIMESTAMPTZ DEFAULT now(),

    -- Next appointment should be after visit
    CONSTRAINT next_appt_after_visit CHECK (
        next_appointment IS NULL OR next_appointment > visit_date
    ),
    -- Days dispensed should be a plausible pharmacy quantity
    CONSTRAINT plausible_days_dispensed CHECK (
        days_dispensed IS NULL OR days_dispensed BETWEEN 1 AND 365
    )
);

-- ---------------------------------------------------------------------------
-- TB MODULE
-- ---------------------------------------------------------------------------

CREATE TABLE tb_case (
    tb_case_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id          UUID REFERENCES patient(patient_id), -- nullable if not linked
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    case_number         VARCHAR(20), -- district TB number
    notification_date   DATE NOT NULL,
    diagnosis_date      DATE,
    case_type           tb_case_type DEFAULT 'new',
    site                VARCHAR(20) CHECK (site IN ('pulmonary', 'extra_pulmonary', 'both')),
    smear_result        VARCHAR(10) CHECK (smear_result IN ('positive', 'negative', 'not_done', NULL)),
    xpert_result        VARCHAR(30),
    hiv_status_at_dx    hiv_status DEFAULT 'unknown',
    on_art_at_dx        BOOLEAN,
    treatment_start     DATE,
    treatment_outcome   tb_treatment_outcome DEFAULT 'on_treatment',
    outcome_date        DATE,
    data_source         data_source DEFAULT 'DHIS2',
    created_at          TIMESTAMPTZ DEFAULT now(),

    -- Notification cannot precede diagnosis
    CONSTRAINT notification_after_diagnosis CHECK (
        diagnosis_date IS NULL OR notification_date >= diagnosis_date
    ),
    -- Treatment start cannot precede notification
    CONSTRAINT treatment_after_notification CHECK (
        treatment_start IS NULL OR treatment_start >= notification_date
    )
);

-- ---------------------------------------------------------------------------
-- MATERNAL & CHILD HEALTH
-- ---------------------------------------------------------------------------

CREATE TABLE anc_visit (
    anc_visit_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id          UUID NOT NULL REFERENCES patient(patient_id),
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    visit_date          DATE NOT NULL,
    anc_visit_number    SMALLINT CHECK (anc_visit_number BETWEEN 1 AND 12),
    gestational_age_wks SMALLINT CHECK (gestational_age_wks BETWEEN 4 AND 44),
    weight_kg           NUMERIC(5,1),
    muac_cm             NUMERIC(4,1), -- mid-upper arm circumference
    systolic_bp         SMALLINT,
    diastolic_bp        SMALLINT,
    hiv_test_done       BOOLEAN DEFAULT FALSE,
    hiv_result          hiv_status DEFAULT 'unknown',
    syphilis_test_done  BOOLEAN DEFAULT FALSE,
    syphilis_result     VARCHAR(10) CHECK (syphilis_result IN ('reactive', 'non_reactive', 'not_done', NULL)),
    iron_given          BOOLEAN DEFAULT FALSE,
    data_source         data_source DEFAULT 'KenyaEMR',
    created_at          TIMESTAMPTZ DEFAULT now(),

    -- Patient must be female (enforced at application layer; flagged by DQ check)
    CONSTRAINT bp_ranges CHECK (
        (systolic_bp IS NULL OR systolic_bp BETWEEN 50 AND 300) AND
        (diastolic_bp IS NULL OR diastolic_bp BETWEEN 30 AND 200)
    )
);

CREATE TABLE delivery (
    delivery_id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id          UUID NOT NULL REFERENCES patient(patient_id),
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    delivery_date       DATE NOT NULL,
    delivery_mode       VARCHAR(20) CHECK (delivery_mode IN ('SVD', 'C_section', 'assisted', 'unknown')),
    birth_outcome       VARCHAR(20) CHECK (birth_outcome IN ('live_birth', 'stillbirth', 'miscarriage', 'unknown')),
    birth_weight_g      NUMERIC(6,1),   -- grams
    gestational_age_wks SMALLINT CHECK (gestational_age_wks BETWEEN 20 AND 46),
    baby_hiv_status     hiv_status DEFAULT 'unknown',
    mother_hiv_status   hiv_status DEFAULT 'unknown',
    apgar_1min          SMALLINT CHECK (apgar_1min BETWEEN 0 AND 10),
    apgar_5min          SMALLINT CHECK (apgar_5min BETWEEN 0 AND 10),
    data_source         data_source DEFAULT 'KenyaEMR',
    created_at          TIMESTAMPTZ DEFAULT now(),

    CONSTRAINT birth_weight_plausible CHECK (
        birth_weight_g IS NULL OR birth_weight_g BETWEEN 200 AND 8000
    )
);

-- ---------------------------------------------------------------------------
-- COMMUNITY HEALTH WORKERS
-- ---------------------------------------------------------------------------

CREATE TABLE chw (
    chw_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    chw_code        VARCHAR(20) UNIQUE NOT NULL,
    full_name       VARCHAR(100),
    facility_id     INT REFERENCES facility(facility_id), -- linked facility
    sub_county_id   SMALLINT REFERENCES sub_county(sub_county_id),
    is_active       BOOLEAN DEFAULT TRUE,
    start_date      DATE,
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE chw_service_record (
    service_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    chw_id              UUID NOT NULL REFERENCES chw(chw_id),
    patient_id          UUID REFERENCES patient(patient_id),
    service_date        DATE NOT NULL,
    service_type        VARCHAR(40), -- 'household_visit', 'referral', 'defaulter_tracing', etc.
    outcome             VARCHAR(40),
    gps_latitude        NUMERIC(9,6),
    gps_longitude       NUMERIC(9,6),
    data_source         data_source DEFAULT 'mobile_CHW',
    created_at          TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- DHIS2-STYLE AGGREGATE REPORTS
-- ---------------------------------------------------------------------------

-- Period-based aggregate submissions (monthly/quarterly)
CREATE TABLE aggregate_report (
    report_id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    period_type         VARCHAR(10) CHECK (period_type IN ('monthly', 'quarterly', 'annual')),
    period_year         SMALLINT NOT NULL,
    period_month        SMALLINT CHECK (period_month BETWEEN 1 AND 12), -- NULL for quarterly/annual
    period_quarter      SMALLINT CHECK (period_quarter BETWEEN 1 AND 4), -- NULL for monthly
    indicator_code      VARCHAR(40) NOT NULL, -- e.g. 'HTS_TST', 'TX_CURR', 'TB_NOTIF'
    numerator           NUMERIC(10,2),
    denominator         NUMERIC(10,2),
    value               NUMERIC(10,2), -- computed or directly entered
    submission_date     TIMESTAMPTZ,
    submitted_by        VARCHAR(80),
    data_source         data_source DEFAULT 'DHIS2',
    created_at          TIMESTAMPTZ DEFAULT now(),

    -- Can't have both month and quarter set for the same record in monthly mode
    CONSTRAINT period_consistency CHECK (
        NOT (period_month IS NOT NULL AND period_quarter IS NOT NULL)
    ),
    -- Value must be non-negative
    CONSTRAINT non_negative_value CHECK (value IS NULL OR value >= 0)
);

-- ---------------------------------------------------------------------------
-- STOCK / COMMODITY MANAGEMENT
-- ---------------------------------------------------------------------------

CREATE TABLE commodity (
    commodity_id    SERIAL PRIMARY KEY,
    commodity_name  VARCHAR(120) NOT NULL,
    category        VARCHAR(30), -- 'ARV', 'vaccine', 'test_kit', 'OI_drug', 'consumable'
    unit            VARCHAR(20), -- 'tablets', 'vials', 'doses', 'packs'
    is_tracer       BOOLEAN DEFAULT FALSE -- key tracer medicines (e.g. TLD, BCG)
);

CREATE TABLE stock_record (
    stock_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    facility_id         INT NOT NULL REFERENCES facility(facility_id),
    commodity_id        INT NOT NULL REFERENCES commodity(commodity_id),
    record_date         DATE NOT NULL,
    opening_balance     NUMERIC(10,2),
    received_qty        NUMERIC(10,2) DEFAULT 0,
    dispensed_qty       NUMERIC(10,2) DEFAULT 0,
    losses_adjustments  NUMERIC(10,2) DEFAULT 0,
    closing_balance     NUMERIC(10,2),
    days_out_of_stock   SMALLINT DEFAULT 0 CHECK (days_out_of_stock BETWEEN 0 AND 31),
    data_source         data_source DEFAULT 'DHIS2',
    created_at          TIMESTAMPTZ DEFAULT now(),

    -- Closing balance should equal opening + received - dispensed - losses
    -- This is checked by the DQ engine rather than a hard constraint,
    -- because data entry may legitimately lag. A hard constraint would block
    -- partial saves from mobile tools.
    CONSTRAINT non_negative_quantities CHECK (
        (opening_balance IS NULL OR opening_balance >= 0) AND
        (received_qty >= 0) AND
        (dispensed_qty >= 0)
    )
);

-- ---------------------------------------------------------------------------
-- RAW INGESTION LAYER
-- Source extracts land here before validation. These tables deliberately copy
-- the operational columns and defaults but omit PK, FK, UNIQUE, and CHECK
-- constraints so imperfect source records can be assessed by the DQ engine.
-- Master/reference data remains in public.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE raw.patient            (LIKE public.patient INCLUDING DEFAULTS);
CREATE TABLE raw.art_enrollment     (LIKE public.art_enrollment INCLUDING DEFAULTS);
CREATE TABLE raw.viral_load         (LIKE public.viral_load INCLUDING DEFAULTS);
CREATE TABLE raw.art_visit          (LIKE public.art_visit INCLUDING DEFAULTS);
CREATE TABLE raw.tb_case            (LIKE public.tb_case INCLUDING DEFAULTS);
CREATE TABLE raw.anc_visit          (LIKE public.anc_visit INCLUDING DEFAULTS);
CREATE TABLE raw.delivery           (LIKE public.delivery INCLUDING DEFAULTS);
CREATE TABLE raw.chw                (LIKE public.chw INCLUDING DEFAULTS);
CREATE TABLE raw.chw_service_record (LIKE public.chw_service_record INCLUDING DEFAULTS);
CREATE TABLE raw.aggregate_report   (LIKE public.aggregate_report INCLUDING DEFAULTS);
CREATE TABLE raw.stock_record       (LIKE public.stock_record INCLUDING DEFAULTS);

COMMENT ON SCHEMA raw IS
'Landing/staging schema for source extracts. Records are intentionally accepted before semantic validation by the DQ engine.';

-- ---------------------------------------------------------------------------
-- DATA QUALITY ISSUE REGISTRY
-- The central table. Every automated check inserts rows here.
-- ---------------------------------------------------------------------------

CREATE TABLE data_quality_issue (
    issue_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    -- Which check fired
    check_name          VARCHAR(100) NOT NULL,
    check_category      check_category NOT NULL,
    severity            severity_level NOT NULL,

    -- Where the problem lives
    source_table        VARCHAR(60) NOT NULL, -- e.g. 'art_enrollment'
    source_column       VARCHAR(60), -- specific column, if applicable
    record_id           TEXT, -- PK of the offending record (text for flexibility)

    -- Facility / geography context
    facility_id         INT REFERENCES facility(facility_id),
    county_id           SMALLINT REFERENCES county(county_id),

    -- Human-readable description
    issue_description   TEXT NOT NULL, -- templated message from the check
    raw_value           TEXT, -- the actual bad value captured
    expected_value      TEXT, -- what was expected (range, format, etc.)

    -- Resolution tracking
    status              issue_status DEFAULT 'open',
    resolved_by         VARCHAR(80),
    resolved_at         TIMESTAMPTZ,
    resolution_notes    TEXT,

    -- Automated context
    check_run_id        UUID, -- groups all issues from a single engine run
    data_source         data_source,
    period_year         SMALLINT, -- reporting period context, if applicable
    period_month        SMALLINT,

    -- Timestamps
    detected_at         TIMESTAMPTZ DEFAULT now(),
    updated_at          TIMESTAMPTZ DEFAULT now()
);

-- Indexes for common DQ dashboard query patterns
CREATE INDEX idx_dqi_severity      ON data_quality_issue(severity);
CREATE INDEX idx_dqi_status        ON data_quality_issue(status);
CREATE INDEX idx_dqi_category      ON data_quality_issue(check_category);
CREATE INDEX idx_dqi_facility      ON data_quality_issue(facility_id);
CREATE INDEX idx_dqi_source_table  ON data_quality_issue(source_table);
CREATE INDEX idx_dqi_check_run     ON data_quality_issue(check_run_id);
CREATE INDEX idx_dqi_detected      ON data_quality_issue(detected_at DESC);

-- Keep recurring engine runs from creating another open finding for the same
-- check and source record. Resolved, waived, and false-positive findings may
-- be raised again when the underlying condition recurs.
CREATE OR REPLACE FUNCTION dqi_ignore_duplicate_open()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('open', 'confirmed') AND NEW.record_id IS NOT NULL THEN
        -- Serialise concurrent attempts for this logical finding before the
        -- existence check. A hash collision only serialises extra inserts.
        PERFORM pg_advisory_xact_lock(
            hashtext(CONCAT_WS('|', NEW.check_name, NEW.source_table, NEW.record_id))
        );

        IF EXISTS (
            SELECT 1
            FROM data_quality_issue dqi
            WHERE dqi.check_name = NEW.check_name
              AND dqi.source_table = NEW.source_table
              AND dqi.record_id = NEW.record_id
              AND dqi.status IN ('open', 'confirmed')
        ) THEN
            RETURN NULL;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_dqi_ignore_duplicate_open
BEFORE INSERT ON data_quality_issue
FOR EACH ROW EXECUTE FUNCTION dqi_ignore_duplicate_open();

-- ---------------------------------------------------------------------------
-- DQ ENGINE AUDIT LOG
-- Tracks each engine run: which checks ran, how many issues found, duration.
-- ---------------------------------------------------------------------------

CREATE TABLE dq_engine_run (
    run_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    run_completed_at    TIMESTAMPTZ,
    triggered_by        VARCHAR(80) DEFAULT 'scheduled', -- 'manual', 'scheduled', 'pipeline'
    checks_executed     INT DEFAULT 0,
    issues_found        INT DEFAULT 0,
    issues_resolved     INT DEFAULT 0,
    run_notes           TEXT
);

-- Per-check execution log (one row per check per run)
CREATE TABLE dq_check_log (
    log_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id              UUID NOT NULL REFERENCES dq_engine_run(run_id),
    check_name          VARCHAR(100) NOT NULL,
    check_category      check_category NOT NULL,
    severity            severity_level NOT NULL,
    source_table        VARCHAR(60),
    started_at          TIMESTAMPTZ DEFAULT now(),
    completed_at        TIMESTAMPTZ,
    records_scanned     INT DEFAULT 0,
    issues_raised       INT DEFAULT 0,
    error_message       TEXT, -- non-null if the check itself failed
    sql_query           TEXT -- the SQL that was executed (for debugging)
);

-- ---------------------------------------------------------------------------
-- HELPER VIEWS (used by the DQ engine and reporting layer)
-- ---------------------------------------------------------------------------

-- Convenience: full facility context in one place
CREATE VIEW vw_facility_full AS
SELECT
    f.facility_id,
    f.mfl_code,
    f.facility_name,
    f.facility_type,
    f.ownership,
    f.is_active,
    f.dhis2_org_unit,
    f.latitude,
    f.longitude,
    sc.sub_county_name,
    c.county_id,
    c.county_name,
    c.region
FROM facility f
LEFT JOIN sub_county sc ON f.sub_county_id = sc.sub_county_id
LEFT JOIN county c ON f.county_id = c.county_id;

-- Open issues summary by facility and category
CREATE VIEW vw_dq_summary AS
SELECT
    f.county_name,
    f.facility_name,
    f.mfl_code,
    dqi.check_category,
    dqi.severity,
    COUNT(*) AS issue_count,
    MAX(dqi.detected_at) AS latest_detection
FROM data_quality_issue dqi
JOIN vw_facility_full f ON dqi.facility_id = f.facility_id
WHERE dqi.status = 'open'
GROUP BY 1, 2, 3, 4, 5;

-- Trend view: issues detected per day, useful for monitoring dashboards
CREATE VIEW vw_dq_daily_trend AS
SELECT
    DATE(detected_at) AS detection_date,
    check_category,
    severity,
    COUNT(*) AS issues_detected
FROM data_quality_issue
GROUP BY 1, 2, 3
ORDER BY 1 DESC;

-- Check performance: how long checks run and how many issues they find on average
CREATE VIEW vw_check_performance AS
SELECT
    cl.check_name,
    cl.check_category,
    cl.severity,
    COUNT(cl.log_id) AS total_runs,
    AVG(EXTRACT(EPOCH FROM (cl.completed_at - cl.started_at))) AS avg_duration_secs,
    SUM(cl.records_scanned) AS total_records_scanned,
    SUM(cl.issues_raised) AS total_issues_raised,
    ROUND(SUM(cl.issues_raised)::NUMERIC / NULLIF(SUM(cl.records_scanned), 0) * 100, 2) AS issue_rate_pct
FROM dq_check_log cl
GROUP BY 1, 2, 3;

COMMENT ON TABLE data_quality_issue IS
'Central registry for all automated data quality findings. Every check in the DQ engine inserts rows here. Never delete rows; update status to resolved/waived instead.';

COMMENT ON TABLE dq_engine_run IS
'Audit log for each DQ engine execution. Used to track coverage, frequency, and total issue burden over time.';

COMMENT ON TABLE facility IS
'Master Facility List (MFL) - the authoritative reference for facility identity. All transactional tables foreign-key into this.';

COMMENT ON COLUMN data_quality_issue.raw_value IS
'The actual value found in the data that triggered the check. Stored as TEXT for flexibility across all data types.';

COMMENT ON COLUMN data_quality_issue.check_run_id IS
'UUID shared by all issues detected in a single engine run. Allows bulk resolution and run-level analytics.';
