# SQL Data Quality Engine for Kenya Public Health Programmes
## Wayne Willis Omondi

A PostgreSQL data quality engine for Kenyan public-health reporting domains, including PEPFAR/MER, DHIS2/KHIS, KenyaEMR, NASCOP, and NTLD-P.

---

## What This Project Is

This project:

1. Defines a two-layer schema: constrained `public` canonical tables and unconstrained `raw` tables for source extracts. It covers facility registry, patient records, ART/HIV, TB, maternal health, CHW, DHIS2 reports, and commodity stock.
2. Seeds deterministic synthetic raw data with annotated DQ fixtures: 31 facilities, 61 patient rows, 63 ART enrolments, 65 TB cases, 111 ANC visits, 29 deliveries, 306 stock records, 231 aggregate reports, and 121 CHW service records.
3. **Runs 36 automated checks** across 7 DQ categories (completeness, validity, consistency, timeliness, uniqueness, referential, plausibility). Every check populates `data_quality_issue`.
4. Provides reporting queries for scorecards, domain-specific analysis, trends, and triage lists.
5. Provides procedures for resolving, waiving, marking false positives, recording suppression requests, and archiving stale records.
6. Includes `pg_cron` statements for daily engine runs, weekly stale-issue alerts, and monthly archiving when the extension is configured.

---

## File Structure

```
sql_ph_dq_engine/
├── 01_schema.sql                Core schema: all domain tables + DQ registry
├── 02_seed_data.sql             Deterministic synthetic raw data with annotated DQ fixtures
├── 03_dq_engine.sql             36 automated checks + callable engine function
├── 04_reporting_queries.sql     Dashboard + analytical queries
├── 05_resolution_procedures.sql Stored procedures for issue lifecycle management
├── 06_scheduled_job.sql         pg_cron setup + maintenance functions
└── README.md                    What you are currently reading
```

---

## Data Flow

```text
raw source records -> DQ engine -> data_quality_issue -> review / resolution
```

The seed data loads into `raw`, where semantic constraints are intentionally absent so poor source data can be assessed. `public` retains reference data, DQ and audit records, and constrained canonical tables. This repository does not include a process that promotes reviewed raw records into those canonical tables.

## Quick Start

### Prerequisites

- PostgreSQL 14+
- Extensions: `uuid-ossp`, `pg_trgm` (both installed in `01_schema.sql`)
- Optional: `pg_cron` for scheduling (`06_scheduled_job.sql`)

### Run Order

```bash
# 1. Create database
createdb ph_data

# 2. Load schema (creates constrained public tables and unconstrained raw staging tables)
psql -d ph_data -f 01_schema.sql

# 3. Load raw seed data (takes ~10–30 seconds on modest hardware)
psql -d ph_data -f 02_seed_data.sql

# 4. Load the DQ engine function
psql -d ph_data -f 03_dq_engine.sql

# 5. Run the DQ engine (generates issues in data_quality_issue)
psql -d ph_data -c "SELECT public.run_dq_engine('manual');"

# 6. Load resolution procedures
psql -d ph_data -f 05_resolution_procedures.sql

# 7. Optional: set up scheduling
psql -d ph_data -f 06_scheduled_job.sql

# 8. Run reporting queries interactively
psql -d ph_data -f 04_reporting_queries.sql
```

### Verify the Engine Ran

```sql
-- See how many issues were found
SELECT checks_executed, issues_found FROM dq_engine_run ORDER BY run_started_at DESC LIMIT 1;

-- Count open issues by severity
SELECT severity, COUNT(*) FROM data_quality_issue WHERE status = 'open' GROUP BY severity;

-- See all critical issues
SELECT check_name, facility_id, issue_description FROM data_quality_issue
WHERE severity = 'critical' AND status = 'open';
```

---

## Check Inventory

### Completeness (6 checks)

| ID | Check | Severity | Table |
|----|-------|----------|-------|
| C01 | Patient missing `date_of_birth` | High | `patient` |
| C02 | Patient `sex = unknown` | Medium | `patient` |
| C03 | TB case missing `treatment_start` | **Critical** | `tb_case` |
| C04 | ART enrollment missing `weight_at_start` | Medium | `art_enrollment` |
| C05 | Stock record missing `closing_balance` | High | `stock_record` |
| C06 | VL result missing without an LDL flag | High | `viral_load` |

### Validity (8 checks)

| ID | Check | Severity | Table |
|----|-------|----------|-------|
| V01 | Patient `date_of_birth` in the future | **Critical** | `patient` |
| V02 | ART start before patient enrollment date | **Critical** | `art_enrollment` |
| V03 | Negative CD4 count | **Critical** | `art_enrollment` |
| V04 | VL `result_date` before `sample_date` | High | `viral_load` |
| V05 | ANC `gestational_age_wks` > 44 | High | `anc_visit` |
| V06 | Aggregate report with negative value | High | `aggregate_report` |
| V07 | Adherence score outside 0–100 | Medium | `art_visit` |
| V08 | Birth weight below 200g | High | `delivery` |

### Consistency (8 checks)

| ID | Check | Severity | Table |
|----|-------|----------|-------|
| K01 | ANC visit recorded for male patient | High | `anc_visit` |
| K02 | VL labeled `suppressed` but result ≥ 1000 copies/mL | **Critical** | `viral_load` |
| K03 | TB outcome = `cured` without `treatment_start` | High | `tb_case` |
| K04 | Baby HIV-positive with HIV-negative mother (MTCT) | High | `delivery` |
| K05 | Stock closing balance ≠ arithmetic result | High | `stock_record` |
| K06 | `HTS_TST_POS` > `HTS_TST` in same facility-period | **Critical** | `aggregate_report` |
| K07 | ART start after patient date of death | **Critical** | `art_enrollment` |
| K08 | Patient enrolled before date of birth | High | `patient` |

### Timeliness (4 checks)

| ID | Check | Severity | Table |
|----|-------|----------|-------|
| T01 | TB notification > 56 days after diagnosis | High | `tb_case` |
| T02 | Aggregate report submitted > 60 days after period end | High | `aggregate_report` |
| T03 | CHW record created > 30 days after service date | Medium | `chw_service_record` |
| T04 | ART patient overdue > 90 days (possible LTFU) | Medium | `art_visit` |

### Uniqueness (3 checks)

| ID | Check | Severity | Table |
|----|-------|----------|-------|
| U01 | Duplicate patients (same facility + DOB + sex) | High | `patient` |
| U02 | Duplicate TB case numbers within a county | Medium | `tb_case` |
| U03 | Duplicate aggregate report (facility + period + indicator) | High | `aggregate_report` |

### Referential (1 check)

| ID | Check | Severity | Table |
|----|-------|----------|-------|
| R01 | Aggregate report references an inactive facility | Medium | `aggregate_report` |

### Plausibility (6 checks)

| ID | Check | Severity | Table |
|----|-------|----------|-------|
| P01 | Adult weight < 15kg in ART visit | High | `art_visit` |
| P02 | CD4 count > 2500 cells/µL at enrollment | Medium | `art_enrollment` |
| P03 | TX_CURR month-over-month jump > 200% | High | `aggregate_report` |
| P04 | Viral load > 10,000,000 copies/mL | Medium | `viral_load` |
| P05 | `days_out_of_stock` > 31 in monthly record | High | `stock_record` |
| P06 | ANC systolic BP > 200 mmHg | **Critical** | `anc_visit` |

---

## The `data_quality_issue` Table

Every check writes to this table. It is the central record of DQ findings.

```sql
-- Key columns
issue_id            UUID        -- primary key
check_name          VARCHAR     -- e.g. 'K02_vl_suppressed_mislabeled'
check_category      ENUM        -- completeness | validity | consistency | ...
severity            ENUM        -- critical | high | medium | low | info
source_table        VARCHAR     -- which table the issue is in
source_column       VARCHAR     -- which column triggered the check
record_id           TEXT        -- PK of the offending record
facility_id         INT         -- FK to facility
county_id           SMALLINT    -- FK to county
issue_description   TEXT        -- human-readable description with context
raw_value           TEXT        -- what was actually in the data
expected_value      TEXT        -- what the check expected
status              ENUM        -- open | confirmed | resolved | waived | false_positive
check_run_id        UUID        -- groups all issues from one engine run
detected_at         TIMESTAMPTZ -- when the check fired
```

**Never delete rows from this table.** Use `status` updates to track resolution. The archive function handles cleanup for resolved issues older than 180 days.

---

## Resolution Workflow

```sql
-- Resolve a single issue
SELECT resolve_issue('<issue_id>', 'wayne.omondi', 'Corrected in KenyaEMR. Confirmed with physical CCC card.');

-- Batch-resolve all issues from one check (e.g. after a system migration)
SELECT bulk_resolve_by_check(
    'C01_patient_missing_dob',
    'dr.akinyi',
    'Historical paper records pre-2015 did not capture DOB. Cannot be retrospectively obtained.',
    NULL,   -- all facilities
    23      -- county_id = Turkana
);

-- Waive an issue (known limitation, accepted)
SELECT waive_issue('<issue_id>', 'dq.focal.person', 'Turkana facility uses paper CIFs; DOB not collected in 2012 intake forms.');

-- Mark as false positive
SELECT mark_false_positive('<issue_id>', 'wayne.omondi', 'CD4 of 3450 confirmed by lab re-check. Patient has rare CD4 lymphocytosis unrelated to HIV.');

-- Record a suppression request during data migration.
-- The current engine does not yet apply suppression records.
SELECT suppress_check(
    'T02_aggregate_late_submission',
    'system.admin',
    'DHIS2 migration delayed Q1 2023 submissions. Backfill in progress.',
    '2024-02-28',
    NULL, 47    -- county_id = Nairobi
);
```

---

## Scheduling

With pg_cron configured:

```
Daily   02:00 EAT: Full engine run (`public.run_dq_engine()`)
Daily   03:00 EAT: Expired suppression cleanup
Weekly  Mon 07:00: Stale issue alert (issues open > 30 days)
Monthly 1st 04:00: Archive resolved issues older than 180 days
```

Without pg_cron, use OS cron:

```bash
# /etc/cron.d/ph_dq_engine
0 23 * * * postgres psql -d ph_data -c "SELECT public.run_dq_engine('os_cron_daily');" >> /var/log/dq_engine.log 2>&1
```

---

## Key Views

| View | Purpose |
|------|---------|
| `vw_facility_full` | Facility with county/sub-county context in one row |
| `vw_dq_summary` | Open issue counts by facility, category, severity |
| `vw_dq_daily_trend` | Issue detection counts per day |
| `vw_check_performance` | Check duration and issue rate over time |

---

## DQ Severity Weights

Used in the weighted DQ burden score (Query A01):

| Severity | Weight | When to use |
|----------|--------|-------------|
| Critical | 10 | Directly corrupts indicator calculations (e.g. VL mislabeled, HTS_POS > HTS_TST) |
| High | 5 | Blocks cohort analysis or clinical decision-making (e.g. missing treatment start) |
| Medium | 2 | Reduces completeness of disaggregated reporting (e.g. missing sex) |
| Low | 1 | Minor data hygiene (rarely assigned; reserved for informational checks) |

---

## Domain Context

This engine covers Kenya's public health reporting domains:

- **PEPFAR MER indicators**: TX_CURR, TX_NEW, TX_PVLS, HTS_TST, HTS_TST_POS
- **NTLD-P (National TB & Lung Disease Program)**: notification timeliness, treatment cascade completeness, and outcome consistency per Kenya TB guidelines.
- **DHIS2/KHIS**: aggregate report submission timeliness and arithmetic validity.
- **KenyaEMR / OpenMRS / IQCare or any other EMR Systems**: patient-level data e.g. ART, VL, and ANC records with cross-field consistency rules.
- **mSupply / KEMSA stock data**: commodity balance arithmetic and stockout plausibility.
- **CHW/CHV mobile tools (ODK/CommCare)**: service record sync timeliness.

---

## Extending this Engine

### Adding a New Check

1. Add a scoped `DECLARE ... BEGIN ... END;` block inside `run_dq_engine()` in `03_dq_engine.sql` following the existing pattern.
2. Give it a unique `check_name` (`<PREFIX><NN>_descriptive_name`).
3. Assign the correct `check_category` and `severity`.
4. The block must: scan the target table, `INSERT INTO data_quality_issue`, then call `dq_log_check()`.

### Adding a New Domain Table

1. Define the table in `01_schema.sql` with appropriate constraints.
2. Add seed data in `02_seed_data.sql` with embedded DQ errors.
3. Write checks targeting the new table in `03_dq_engine.sql`.
4. Add domain-specific reporting queries to `04_reporting_queries.sql`.

---

## Design Decisions

**One issue table.** All 36 checks write to `data_quality_issue`, which supports reporting across checks and domains.

**One callable engine with scoped checks.** The checks run in individual PL/pgSQL blocks inside `run_dq_engine()`, and schedulers can call the same function.

**Text record_id.** The `record_id` column stores primary keys as `TEXT` to accommodate UUID, SERIAL, and composite PKs from different tables without requiring separate columns.

**Plausibility over hard constraints.** Checks like adult weight < 15kg and VL > 10M copies/mL are implemented as DQ checks rather than `CHECK` constraints, because hard constraints block data entry entirely (including legitimate edge cases or bulk imports that need investigation). A DQ issue can be investigated and waived; a constraint violation crashes the insert.

**Suppression registry.** The repository records time-bound suppression requests with a reason. The current engine does not consult this registry, so the requests do not yet bypass checks.

---

*Project built & tested on PostgreSQL 18*
