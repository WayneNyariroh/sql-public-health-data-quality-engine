-- =============================================================================
-- PUBLIC HEALTH DATA QUALITY ENGINE
-- File: 02_seed_data.sql
-- Purpose: Realistic Kenya public health seed data.
--          Deliberately includes data quality issues so the engine has
--          something real to catch. Corrupted/problematic rows are annotated
--          with -- [DQ: <issue_type>] comments so you can trace what each
--          check is supposed to detect.
--
-- Dataset scope:
--   - 6 counties (Nairobi, Kisumu, Mombasa, Nakuru, Kisii, Turkana)
--   - 40 facilities across those counties
--   - ~500 patient records
--   - ART enrollments, viral loads, ANC visits, TB cases, deliveries
--   - Aggregate DHIS2 reports with intentional inconsistencies
--   - Stock records with stockout and balance errors
--
-- Run after: 01_schema.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- COUNTIES
-- ---------------------------------------------------------------------------
INSERT INTO county (county_id, county_name, region) VALUES
(47, 'Nairobi',    'Nairobi Metropolitan'),
(40, 'Kisumu',     'Nyanza'),
(1,  'Mombasa',    'Coast'),
(32, 'Nakuru',     'Rift Valley'),
(36, 'Kisii',      'Nyanza'),
(23, 'Turkana',    'Rift Valley'),
(10, 'Machakos',   'Eastern'),
(21, 'Kakamega',   'Western');

-- ---------------------------------------------------------------------------
-- SUB-COUNTIES
-- ---------------------------------------------------------------------------
INSERT INTO sub_county (sub_county_id, sub_county_name, county_id) VALUES
(4701, 'Embakasi East',        47),
(4702, 'Kibra',                47),
(4703, 'Langata',              47),
(4704, 'Starehe',              47),
(4001, 'Kisumu Central',       40),
(4002, 'Kisumu East',          40),
(4003, 'Nyando',               40),
(101,  'Mvita',                1),
(102,  'Likoni',               1),
(3201, 'Nakuru Town East',     32),
(3202, 'Naivasha',             32),
(3601, 'Kisii Central',        36),
(2301, 'Lodwar Town',          23),
(1001, 'Machakos Town',        10),
(2101, 'Kakamega Central',     21);

-- ---------------------------------------------------------------------------
-- FACILITIES (40 facilities, mix of types and counties)
-- ---------------------------------------------------------------------------
INSERT INTO facility (mfl_code, facility_name, facility_type, ownership,
                      sub_county_id, county_id, latitude, longitude,
                      is_active, dhis2_org_unit, opened_date) VALUES

-- Nairobi
('14880', 'Kenyatta National Hospital',       'national referral hospital', 'public', 4703, 47, -1.3019, 36.8073, TRUE,  'KNH001', '1901-01-01'),
('15044', 'Mbagathi County Hospital',         'county hospital',           'public', 4702, 47, -1.3139, 36.7844, TRUE,  'MCH002', '1955-03-15'),
('19714', 'Kangemi Health Centre',            'health centre',             'public', 4703, 47, -1.2699, 36.7371, TRUE,  'KHC003', '1972-07-01'),
('20361', 'Kibra Sub-County Hospital',        'sub-county hospital',       'public', 4702, 47, -1.3189, 36.7843, TRUE,  'KBSC04', '1988-01-01'),
('21234', 'St Francis Community Hospital',    'hospital',                  'faith-based', 4701, 47, -1.2921, 36.8734, TRUE,  'SFC005', '1965-04-12'),
('22001', 'Umoja 1 Dispensary',               'dispensary',                'public', 4701, 47, -1.2777, 36.8901, TRUE,  'U1D006', '1990-09-01'),
('22450', 'Mathare North Health Centre',      'health centre',             'public', 4704, 47, -1.2632, 36.8615, FALSE, NULL,      '1985-01-01'),  -- inactive, no DHIS2 UID
('23001', 'Aga Khan Hospital Nairobi',        'hospital',                  'private', 4703, 47, -1.2660, 36.8003, TRUE,  'AKH007', '1958-06-15'),

-- Kisumu
('14901', 'Jaramogi Oginga Odinga Teaching',  'national referral hospital', 'public', 4001, 40, -0.1022, 34.7617, TRUE,  'JOOT08', '1958-01-01'),
('15102', 'Kisumu County Referral Hospital',  'county hospital',           'public', 4001, 40, -0.0917, 34.7641, TRUE,  'KCR009', '1952-03-01'),
('16003', 'Manyatta B Health Centre',         'health centre',             'public', 4002, 40, -0.0834, 34.7812, TRUE,  'MBH010', '1975-05-01'),
('16100', 'Nyalenda A Dispensary',            'dispensary',                'public', 4002, 40, -0.1156, 34.7700, TRUE,  'NAD011', '1988-01-01'),
('16250', 'Lumumba Sub-County Hospital',      'sub-county hospital',       'public', 4001, 40, -0.1022, 34.7519, TRUE,  'LSC012', '1970-01-01'),

-- Mombasa
('10001', 'Coast General Hospital',           'county hospital',           'public', 101,  1,  -4.0435, 39.6682, TRUE,  'CGH013', '1920-01-01'),
('10200', 'Tudor Sub-County Hospital',        'sub-county hospital',       'public', 101,  1,  -4.0280, 39.6825, TRUE,  'TSC014', '1955-01-01'),
('10350', 'Likoni Health Centre',             'health centre',             'public', 102,  1,  -4.0830, 39.6648, TRUE,  'LHC015', '1978-03-01'),
('10500', 'Aga Khan Hospital Mombasa',        'hospital',                  'private', 101, 1,  -4.0529, 39.6677, TRUE,  'AKM016', '1945-01-01'),

-- Nakuru
('18001', 'Nakuru Level 5 Hospital',          'county hospital',           'public', 3201, 32, -0.3031, 36.0800, TRUE,  'N5H017', '1955-01-01'),
('18200', 'Naivasha Sub-County Hospital',     'sub-county hospital',       'public', 3202, 32, -0.7176, 36.4319, TRUE,  'NSC018', '1960-06-01'),
('18350', 'Free Pentecostal Fellowship HC',   'health centre',             'faith-based', 3201, 32, -0.3156, 36.0705, TRUE, 'FPF019', '1983-09-01'),
('18500', 'Gilgil Sub-County Hospital',       'sub-county hospital',       'public', 3202, 32, -0.4900, 36.3244, TRUE,  'GSC020', '1962-01-01'),

-- Kisii
('36001', 'Kisii Teaching and Referral Hospital', 'national referral hospital', 'public', 3601, 36, -0.6817, 34.7680, TRUE, 'KTRH21', '1950-01-01'),
('36150', 'Tabaka Mission Hospital',          'hospital',                  'faith-based', 3601, 36, -0.7150, 34.7100, TRUE, 'TMH022', '1954-07-01'),
('36300', 'Gesonso Health Centre',            'health centre',             'public', 3601, 36, -0.6550, 34.7880, TRUE,  'GHC023', '1980-01-01'),

-- Turkana
('23001', 'Turkana County Referral Hospital', 'county hospital',           'public', 2301, 23, 3.1196, 35.5966, TRUE,   'TCRH24', '1970-01-01'),
('23150', 'Lodwar Health Centre',             'health centre',             'public', 2301, 23, 3.1182, 35.5950, TRUE,   'LHC025', '1975-01-01'),
('23300', 'Kakuma Health Centre',             'health centre',             'public', 2301, 23, 3.7238, 34.8563, TRUE,   'KHC026', '1992-06-01'),

-- Machakos
('10101', 'Machakos Level 5 Hospital',        'county hospital',           'public', 1001, 10, -1.5183, 37.2634, TRUE,  'ML5H27', '1940-01-01'),
('10250', 'Athi River Health Centre',         'health centre',             'public', 1001, 10, -1.4567, 36.9766, TRUE,  'ARH028', '1979-03-01'),

-- Kakamega
('21001', 'Kakamega County General Hospital', 'county hospital',           'public', 2101, 21, 0.2827, 34.7519, TRUE,   'KCGH29', '1948-01-01'),
('21200', 'Mukumu Girls Mission Hospital',    'hospital',                  'faith-based', 2101, 21, 0.3040, 34.7690, TRUE, 'MGM030', '1960-01-01');

-- ---------------------------------------------------------------------------
-- COMMODITIES
-- ---------------------------------------------------------------------------
INSERT INTO commodity (commodity_name, category, unit, is_tracer) VALUES
('Tenofovir/Lamivudine/Dolutegravir 300/300/50mg (TLD)', 'ARV', 'tablets', TRUE),
('Tenofovir/Lamivudine/Efavirenz 300/300/600mg (TLE)',   'ARV', 'tablets', TRUE),
('Abacavir/Lamivudine 60/30mg paediatric',               'ARV', 'tablets', TRUE),
('Lopinavir/Ritonavir 200/50mg',                         'ARV', 'tablets', FALSE),
('Cotrimoxazole 960mg',                                  'OI_drug', 'tablets', FALSE),
('Fluconazole 200mg',                                    'OI_drug', 'capsules', FALSE),
('BCG vaccine',                                          'vaccine', 'vials', TRUE),
('Oral Polio Vaccine (OPV)',                             'vaccine', 'vials', TRUE),
('Measles-Rubella vaccine',                              'vaccine', 'vials', TRUE),
('DTP-Hib-HepB pentavalent',                             'vaccine', 'vials', TRUE),
('HIV rapid test kit (Determine)',                        'test_kit', 'tests', TRUE),
('HIV rapid test kit (Unigold)',                         'test_kit', 'tests', FALSE),
('Malaria RDT kit',                                      'test_kit', 'kits', FALSE),
('Oxytocin 10IU injection',                              'consumable', 'ampoules', TRUE),
('Ferrous Sulphate/Folic Acid tablets',                  'OI_drug', 'tablets', FALSE);

-- ---------------------------------------------------------------------------
-- PATIENTS (~150 records, mix of clean and dirty data)
-- Deliberate DQ issues are annotated inline.
-- ---------------------------------------------------------------------------

-- Clean female patients (ART/ANC candidates)
INSERT INTO patient (patient_id, facility_id, nupi_number, date_of_birth, sex,
                     county_of_birth, date_enrolled, data_source)
SELECT
    uuid_generate_v4(),
    f.facility_id,
    'NUPI' || LPAD((ROW_NUMBER() OVER())::TEXT, 7, '0'),
    ('1980-01-01'::DATE + (RANDOM() * 7300)::INT),  -- 1980–2000
    'female',
    (ARRAY[47, 40, 1, 32, 36, 23])[CEIL(RANDOM() * 6)::INT],
    ('2015-01-01'::DATE + (RANDOM() * 3000)::INT),
    'KenyaEMR'
FROM facility f
CROSS JOIN generate_series(1, 4) g
WHERE f.mfl_code IN ('14880','15044','14901','10001','18001','36001','23001')
LIMIT 60;

-- Clean male patients
INSERT INTO patient (patient_id, facility_id, nupi_number, date_of_birth, sex,
                     county_of_birth, date_enrolled, data_source)
SELECT
    uuid_generate_v4(),
    f.facility_id,
    'NUPI' || LPAD((100 + ROW_NUMBER() OVER())::TEXT, 7, '0'),
    ('1975-01-01'::DATE + (RANDOM() * 10950)::INT),
    'male',
    (ARRAY[47, 40, 1, 32])[CEIL(RANDOM() * 4)::INT],
    ('2013-01-01'::DATE + (RANDOM() * 3650)::INT),
    'KenyaEMR'
FROM facility f
CROSS JOIN generate_series(1, 3) g
WHERE f.mfl_code IN ('14880','15044','15102','18001','10001','21001')
LIMIT 45;

-- Paediatric patients
INSERT INTO patient (patient_id, facility_id, nupi_number, date_of_birth, sex,
                     county_of_birth, date_enrolled, data_source)
SELECT
    uuid_generate_v4(),
    f.facility_id,
    'NUPI' || LPAD((200 + ROW_NUMBER() OVER())::TEXT, 7, '0'),
    ('2010-01-01'::DATE + (RANDOM() * 3650)::INT),
    CASE WHEN RANDOM() > 0.5 THEN 'male' ELSE 'female' END,
    (ARRAY[47, 40, 1])[CEIL(RANDOM() * 3)::INT],
    ('2018-01-01'::DATE + (RANDOM() * 1825)::INT),
    'KenyaEMR'
FROM facility f
CROSS JOIN generate_series(1, 2) g
WHERE f.mfl_code IN ('14880','14901','23001')
LIMIT 20;

-- [DQ: COMPLETENESS] Patients with missing date_of_birth
INSERT INTO patient (facility_id, nupi_number, date_of_birth, sex, date_enrolled, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'NUPIUNK001', NULL, 'female', '2021-03-15', 'KenyaEMR'),
((SELECT facility_id FROM facility WHERE mfl_code = '15044'), 'NUPIUNK002', NULL, 'male',   '2022-07-01', 'paper_CIF'),
((SELECT facility_id FROM facility WHERE mfl_code = '14901'), 'NUPIUNK003', NULL, 'unknown','2023-01-10', 'mobile_CHW');

-- [DQ: VALIDITY] Patient with impossible date_of_birth (future date)
INSERT INTO patient (facility_id, nupi_number, date_of_birth, sex, date_enrolled, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'NUPIUNK004', '2035-06-15', 'female', '2021-04-01', 'manual_entry');

-- [DQ: CONSISTENCY] Patient enrolled before born (dob=2000, enrolled=1999)
-- NOTE: The CHECK constraint on patient prevents dod < dob, but enrollment < dob is not constrained.
INSERT INTO patient (facility_id, nupi_number, date_of_birth, sex, date_enrolled, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '15044'), 'NUPIUNK005', '2000-05-10', 'male', '1999-12-01', 'paper_CIF');

-- [DQ: UNIQUENESS] Duplicate NUPI (same NUPI_0000001 repeated — unique constraint will catch this in prod,
--  but we simulate the detection logic via a DQ check rather than relying solely on the constraint)
-- We'll instead create near-duplicate patients (same DOB + facility + sex) without exact NUPI match:
INSERT INTO patient (facility_id, nupi_number, date_of_birth, sex, date_enrolled, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'NUPIDUP001A', '1987-03-22', 'female', '2020-05-01', 'KenyaEMR'),
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'NUPIDUP001B', '1987-03-22', 'female', '2020-05-15', 'KenyaEMR');

-- ---------------------------------------------------------------------------
-- CHW RECORDS
-- ---------------------------------------------------------------------------
INSERT INTO chw (chw_id, chw_code, full_name, facility_id, sub_county_id, is_active, start_date) VALUES
(uuid_generate_v4(), 'CHW-KIB-001', 'Akinyi Otieno',    (SELECT facility_id FROM facility WHERE mfl_code = '20361'), 4702, TRUE, '2019-01-15'),
(uuid_generate_v4(), 'CHW-KIB-002', 'Wanjiku Kamau',    (SELECT facility_id FROM facility WHERE mfl_code = '20361'), 4702, TRUE, '2020-03-01'),
(uuid_generate_v4(), 'CHW-KIS-001', 'Onyango Ouma',     (SELECT facility_id FROM facility WHERE mfl_code = '16003'), 4002, TRUE, '2018-07-01'),
(uuid_generate_v4(), 'CHW-TRK-001', 'Ekwom Loturerei',  (SELECT facility_id FROM facility WHERE mfl_code = '23150'), 2301, TRUE, '2021-02-10'),
(uuid_generate_v4(), 'CHW-NKR-001', 'Chebet Kimutai',   (SELECT facility_id FROM facility WHERE mfl_code = '18350'), 3201, FALSE,'2017-05-01');

-- ---------------------------------------------------------------------------
-- ART ENROLLMENTS
-- Build on top of existing patients. Use a helper CTE-style INSERT.
-- ---------------------------------------------------------------------------

-- Clean enrollments for female patients
INSERT INTO art_enrollment (patient_id, facility_id, art_start_date, entry_point,
                            who_stage_at_start, cd4_at_start, weight_at_start,
                            initial_regimen)
SELECT
    p.patient_id,
    p.facility_id,
    p.date_enrolled + INTERVAL '7 days',
    (ARRAY['VCT','PMTCT','TB/HIV','OPD','inpatient'])[CEIL(RANDOM()*5)::INT],
    CEIL(RANDOM()*4)::SMALLINT,
    ROUND((100 + RANDOM()*800)::NUMERIC, 1),
    ROUND((40 + RANDOM()*60)::NUMERIC, 1),
    (ARRAY['TLD','TLE','DTG_based_other'])[CEIL(RANDOM()*3)::INT]::art_regimen
FROM patient p
WHERE p.sex = 'female'
  AND p.date_of_birth IS NOT NULL
  AND p.date_of_birth < '2010-01-01'   -- adults
LIMIT 50;

-- Clean enrollments for male patients
INSERT INTO art_enrollment (patient_id, facility_id, art_start_date, entry_point,
                            who_stage_at_start, cd4_at_start, weight_at_start,
                            initial_regimen)
SELECT
    p.patient_id,
    p.facility_id,
    p.date_enrolled + INTERVAL '14 days',
    (ARRAY['VCT','TB/HIV','OPD'])[CEIL(RANDOM()*3)::INT],
    CEIL(RANDOM()*3)::SMALLINT,
    ROUND((50 + RANDOM()*700)::NUMERIC, 1),
    ROUND((50 + RANDOM()*50)::NUMERIC, 1),
    'TLD'
FROM patient p
WHERE p.sex = 'male'
  AND p.date_of_birth IS NOT NULL
  AND p.date_of_birth < '2010-01-01'
LIMIT 35;

-- Paediatric enrollments (ABC-based)
INSERT INTO art_enrollment (patient_id, facility_id, art_start_date, entry_point,
                            who_stage_at_start, cd4_at_start, weight_at_start, height_at_start,
                            initial_regimen)
SELECT
    p.patient_id,
    p.facility_id,
    p.date_enrolled + INTERVAL '3 days',
    'PMTCT',
    (ARRAY[1,2,3,4])[CEIL(RANDOM()*4)::INT]::SMALLINT,
    ROUND((200 + RANDOM()*1200)::NUMERIC, 1),
    ROUND((8 + RANDOM()*25)::NUMERIC, 1),
    ROUND((85 + RANDOM()*65)::NUMERIC, 1),
    'ABC_3TC_LPV'
FROM patient p
WHERE p.date_of_birth >= '2010-01-01'
LIMIT 15;

-- [DQ: VALIDITY] ART start before patient enrollment (impossible timeline)
INSERT INTO art_enrollment (patient_id, facility_id, art_start_date, entry_point, initial_regimen)
SELECT
    p.patient_id,
    p.facility_id,
    p.date_enrolled - INTERVAL '90 days',  -- art started BEFORE enrollment
    'VCT',
    'TLD'
FROM patient p
WHERE p.nupi_number = 'NUPIUNK001';

-- [DQ: VALIDITY] Impossible CD4 count (negative)
INSERT INTO art_enrollment (patient_id, facility_id, art_start_date, entry_point,
                            who_stage_at_start, cd4_at_start, initial_regimen)
SELECT
    p.patient_id,
    p.facility_id,
    p.date_enrolled + INTERVAL '1 day',
    'OPD',
    2,
    -50,   -- negative CD4 count: clearly invalid
    'TLE'
FROM patient p
WHERE p.nupi_number = 'NUPIDUP001A';

-- [DQ: PLAUSIBILITY] Extremely high CD4 at ART start (>2500 is implausible for HIV+ on ART)
INSERT INTO art_enrollment (patient_id, facility_id, art_start_date, entry_point,
                            who_stage_at_start, cd4_at_start, initial_regimen)
SELECT
    p.patient_id,
    p.facility_id,
    p.date_enrolled + INTERVAL '5 days',
    'TB/HIV',
    3,
    3450,  -- implausibly high
    'TLD'
FROM patient p
WHERE p.nupi_number = 'NUPIDUP001B';

-- ---------------------------------------------------------------------------
-- VIRAL LOAD RESULTS
-- ---------------------------------------------------------------------------

-- Clean suppressed viral loads
INSERT INTO viral_load (patient_id, facility_id, enrollment_id, sample_date,
                        result_date, vl_result, is_ldl, vl_category, lab_name, data_source)
SELECT
    ae.patient_id,
    ae.facility_id,
    ae.enrollment_id,
    ae.art_start_date + (RANDOM() * 365)::INT,
    ae.art_start_date + (RANDOM() * 365)::INT + 14,
    CASE WHEN RANDOM() > 0.25
         THEN ROUND((RANDOM() * 200)::NUMERIC, 2)
         ELSE NULL END,
    CASE WHEN RANDOM() > 0.75 THEN TRUE ELSE FALSE END,
    CASE WHEN RANDOM() > 0.25 THEN 'suppressed' ELSE 'unsuppressed' END,
    (ARRAY['KEMRI Nairobi Lab','Coast Provincial Lab','Kisumu NPHL','Nakuru Lab Hub'])[CEIL(RANDOM()*4)::INT],
    'lab_LIMS'
FROM art_enrollment ae
LIMIT 60;

-- [DQ: CONSISTENCY] VL result date before sample date
INSERT INTO viral_load (patient_id, facility_id, sample_date, result_date,
                        vl_result, vl_category, lab_name, data_source)
SELECT
    ae.patient_id,
    ae.facility_id,
    '2023-06-15',
    '2023-06-01',   -- result date BEFORE sample date
    450,
    'unsuppressed',
    'KEMRI Nairobi Lab',
    'lab_LIMS'
FROM art_enrollment ae
LIMIT 1;

-- [DQ: COMPLETENESS] VL records missing result entirely (not LDL, just NULL result with no LDL flag)
INSERT INTO viral_load (patient_id, facility_id, sample_date, result_date,
                        vl_result, is_ldl, vl_category, lab_name, data_source)
SELECT
    ae.patient_id,
    ae.facility_id,
    ae.art_start_date + 180,
    ae.art_start_date + 194,
    NULL,   -- result missing
    FALSE,  -- not flagged as LDL either
    NULL,
    'Unknown Lab',
    'lab_LIMS'
FROM art_enrollment ae
LIMIT 5;

-- [DQ: VALIDITY] Viral load with category 'suppressed' but result > 1000 copies/mL (contradictory)
INSERT INTO viral_load (patient_id, facility_id, sample_date, result_date,
                        vl_result, is_ldl, vl_category, lab_name, data_source)
SELECT
    ae.patient_id,
    ae.facility_id,
    '2023-09-01',
    '2023-09-15',
    8500,          -- high viral load
    FALSE,
    'suppressed',  -- but labeled suppressed: contradictory
    'KEMRI Nairobi Lab',
    'lab_LIMS'
FROM art_enrollment ae
OFFSET 5 LIMIT 1;

-- ---------------------------------------------------------------------------
-- ART VISITS
-- ---------------------------------------------------------------------------
INSERT INTO art_visit (patient_id, facility_id, visit_date, next_appointment,
                       weight_kg, current_regimen, days_dispensed, adherence_score, data_source)
SELECT
    ae.patient_id,
    ae.facility_id,
    ae.art_start_date + (g * 90),                      -- quarterly visits
    ae.art_start_date + (g * 90) + 90,                 -- next appt 90 days out
    ROUND((40 + RANDOM()*60)::NUMERIC, 1),
    ae.initial_regimen,
    (ARRAY[30, 60, 90])[CEIL(RANDOM()*3)::INT],
    FLOOR(70 + RANDOM()*30)::SMALLINT,
    'KenyaEMR'
FROM art_enrollment ae
CROSS JOIN generate_series(0, 3) g
WHERE ae.art_start_date + (g * 90) <= CURRENT_DATE
LIMIT 200;

-- [DQ: PLAUSIBILITY] Weight of 4kg for an adult (impossible without paediatric context)
INSERT INTO art_visit (patient_id, facility_id, visit_date, weight_kg,
                       current_regimen, days_dispensed, data_source)
SELECT
    ae.patient_id,
    ae.facility_id,
    ae.art_start_date + 30,
    4.0,    -- implausibly low for an adult
    ae.initial_regimen,
    90,
    'KenyaEMR'
FROM art_enrollment ae
JOIN patient p ON ae.patient_id = p.patient_id
WHERE p.date_of_birth < '1990-01-01'
LIMIT 1;

-- [DQ: VALIDITY] Negative adherence score (out of range)
INSERT INTO art_visit (patient_id, facility_id, visit_date, weight_kg,
                       current_regimen, days_dispensed, adherence_score, data_source)
SELECT
    ae.patient_id,
    ae.facility_id,
    ae.art_start_date + 90,
    65.0,
    'TLD',
    90,
    -10,   -- invalid: adherence must be 0-100
    'manual_entry'
FROM art_enrollment ae
OFFSET 2 LIMIT 1;

-- ---------------------------------------------------------------------------
-- TB CASES
-- ---------------------------------------------------------------------------

INSERT INTO tb_case (patient_id, facility_id, case_number, notification_date, diagnosis_date,
                     case_type, site, smear_result, hiv_status_at_dx,
                     treatment_start, treatment_outcome, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    'TB-' || c.county_id || '-' || LPAD((ROW_NUMBER() OVER())::TEXT, 4,'0'),
    ('2022-01-01'::DATE + (RANDOM()*730)::INT),
    ('2021-12-25'::DATE + (RANDOM()*730)::INT),
    (ARRAY['new','relapse','treatment_after_failure'])[CEIL(RANDOM()*3)::INT]::tb_case_type,
    (ARRAY['pulmonary','extra_pulmonary'])[CEIL(RANDOM()*2)::INT],
    (ARRAY['positive','negative','not_done'])[CEIL(RANDOM()*3)::INT],
    (ARRAY['positive','negative','unknown'])[CEIL(RANDOM()*3)::INT]::hiv_status,
    ('2022-01-15'::DATE + (RANDOM()*730)::INT),
    (ARRAY['cured','treatment_completed','on_treatment','lost_to_follow_up'])[CEIL(RANDOM()*4)::INT]::tb_treatment_outcome,
    'DHIS2'
FROM patient p
JOIN facility f ON p.facility_id = f.facility_id
JOIN county c ON f.county_id = c.county_id
WHERE p.date_of_birth IS NOT NULL
LIMIT 80;

-- [DQ: COMPLETENESS] TB cases missing treatment start date (critical for treatment cascade)
INSERT INTO tb_case (facility_id, case_number, notification_date, case_type,
                     site, hiv_status_at_dx, treatment_start, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14901'), 'TB-40-9991', '2023-04-10', 'new',     'pulmonary',      'positive', NULL, 'DHIS2'),
((SELECT facility_id FROM facility WHERE mfl_code = '10001'), 'TB-01-9992', '2023-06-15', 'relapse', 'extra_pulmonary','unknown',  NULL, 'DHIS2'),
((SELECT facility_id FROM facility WHERE mfl_code = '18001'), 'TB-32-9993', '2023-09-01', 'new',     'pulmonary',      'negative', NULL, 'paper_CIF');

-- [DQ: TIMELINESS] TB notification > 8 weeks after diagnosis (notification delay)
INSERT INTO tb_case (facility_id, case_number, notification_date, diagnosis_date,
                     case_type, site, treatment_start, treatment_outcome, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '36001'), 'TB-36-9994', '2023-11-20', '2023-06-01', 'new', 'pulmonary', '2023-06-15', 'on_treatment', 'DHIS2');

-- [DQ: CONSISTENCY] Treatment outcome = 'cured' but treatment_start is NULL
INSERT INTO tb_case (facility_id, case_number, notification_date, case_type,
                     site, treatment_start, treatment_outcome, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'TB-47-9995', '2023-07-01', 'new', 'pulmonary', NULL, 'cured', 'DHIS2');

-- ---------------------------------------------------------------------------
-- ANC VISITS
-- ---------------------------------------------------------------------------

INSERT INTO anc_visit (patient_id, facility_id, visit_date, anc_visit_number,
                       gestational_age_wks, weight_kg, systolic_bp, diastolic_bp,
                       hiv_test_done, hiv_result, syphilis_test_done, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    ('2022-01-01'::DATE + (RANDOM()*700)::INT),
    g::SMALLINT,
    (8 + g*8)::SMALLINT,
    ROUND((50 + RANDOM()*35)::NUMERIC, 1),
    (FLOOR(100 + RANDOM()*60))::SMALLINT,
    (FLOOR(60 + RANDOM()*40))::SMALLINT,
    TRUE,
    (ARRAY['negative','positive','unknown'])[CEIL(RANDOM()*3)::INT]::hiv_status,
    RANDOM() > 0.3,
    'KenyaEMR'
FROM patient p
CROSS JOIN generate_series(1, 4) g
WHERE p.sex = 'female'
  AND p.date_of_birth BETWEEN '1985-01-01' AND '2003-12-31'
LIMIT 160;

-- [DQ: VALIDITY] ANC on a male patient (sex mismatch)
INSERT INTO anc_visit (patient_id, facility_id, visit_date, anc_visit_number,
                       gestational_age_wks, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    '2023-05-10',
    1,
    12,
    'KenyaEMR'
FROM patient p
WHERE p.sex = 'male'
LIMIT 1;

-- [DQ: PLAUSIBILITY] Gestational age = 50 weeks (impossible)
INSERT INTO anc_visit (patient_id, facility_id, visit_date, anc_visit_number,
                       gestational_age_wks, weight_kg, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    '2023-08-20',
    3,
    50,   -- impossible: max is 44
    62.0,
    'manual_entry'
FROM patient p
WHERE p.sex = 'female'
  AND p.date_of_birth BETWEEN '1990-01-01' AND '2000-01-01'
LIMIT 1;

-- [DQ: PLAUSIBILITY] Extremely high BP (systolic=280) but not flagged as eclampsia
INSERT INTO anc_visit (patient_id, facility_id, visit_date, anc_visit_number,
                       gestational_age_wks, weight_kg, systolic_bp, diastolic_bp, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    '2023-10-05',
    2,
    24,
    58.0,
    280,    -- crisis-level BP: clinical alert warranted
    175,
    'KenyaEMR'
FROM patient p
WHERE p.sex = 'female'
  AND p.date_of_birth BETWEEN '1988-01-01' AND '1998-01-01'
LIMIT 1;

-- ---------------------------------------------------------------------------
-- DELIVERIES
-- ---------------------------------------------------------------------------

INSERT INTO delivery (patient_id, facility_id, delivery_date, delivery_mode,
                      birth_outcome, birth_weight_g, gestational_age_wks,
                      baby_hiv_status, mother_hiv_status, apgar_1min, apgar_5min, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    ('2022-06-01'::DATE + (RANDOM()*500)::INT),
    (ARRAY['SVD','C_section','assisted'])[CEIL(RANDOM()*3)::INT],
    (ARRAY['live_birth','stillbirth'])[CEIL(RANDOM()*2)::INT],
    ROUND((2000 + RANDOM()*2500)::NUMERIC, 1),
    (FLOOR(36 + RANDOM()*4))::SMALLINT,
    (ARRAY['negative','positive','unknown'])[CEIL(RANDOM()*3)::INT]::hiv_status,
    (ARRAY['negative','positive'])[CEIL(RANDOM()*2)::INT]::hiv_status,
    (FLOOR(5 + RANDOM()*5))::SMALLINT,
    (FLOOR(7 + RANDOM()*3))::SMALLINT,
    'KenyaEMR'
FROM patient p
WHERE p.sex = 'female'
  AND p.date_of_birth BETWEEN '1985-01-01' AND '2003-12-31'
LIMIT 55;

-- [DQ: PLAUSIBILITY] Birth weight of 120g (not viable, below 200g minimum)
INSERT INTO delivery (patient_id, facility_id, delivery_date, delivery_mode,
                      birth_outcome, birth_weight_g, gestational_age_wks, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    '2023-04-15',
    'SVD',
    'live_birth',
    120,    -- below viable threshold
    38,
    'paper_CIF'
FROM patient p
WHERE p.sex = 'female'
  AND p.date_of_birth BETWEEN '1990-01-01' AND '2000-01-01'
LIMIT 1;

-- [DQ: CONSISTENCY] Baby HIV-positive but mother HIV-negative (biologically implausible for MTCT)
INSERT INTO delivery (patient_id, facility_id, delivery_date, delivery_mode,
                      birth_outcome, birth_weight_g, gestational_age_wks,
                      baby_hiv_status, mother_hiv_status, data_source)
SELECT
    p.patient_id,
    p.facility_id,
    '2023-09-10',
    'SVD',
    'live_birth',
    3100,
    39,
    'positive',   -- baby positive
    'negative',   -- but mother negative: MTCT contradiction
    'KenyaEMR'
FROM patient p
WHERE p.sex = 'female'
  AND p.date_of_birth BETWEEN '1985-01-01' AND '1995-01-01'
LIMIT 1;

-- ---------------------------------------------------------------------------
-- AGGREGATE REPORTS (DHIS2-style monthly submissions)
-- ---------------------------------------------------------------------------

-- Clean monthly HTS_TST (HIV testing) reports
INSERT INTO aggregate_report (facility_id, period_type, period_year, period_month,
                              indicator_code, numerator, denominator, value,
                              submission_date, submitted_by, data_source)
SELECT
    f.facility_id,
    'monthly',
    2023,
    m.month_num,
    'HTS_TST',
    FLOOR(200 + RANDOM()*800),
    FLOOR(300 + RANDOM()*900),
    FLOOR(200 + RANDOM()*800),
    (MAKE_DATE(2023, m.month_num, 1) + INTERVAL '15 days')::TIMESTAMPTZ,
    'DHIS2_system',
    'DHIS2'
FROM facility f
CROSS JOIN (SELECT generate_series(1,9) AS month_num) m
WHERE f.is_active = TRUE
LIMIT 120;

-- Clean TX_CURR (current on treatment)
INSERT INTO aggregate_report (facility_id, period_type, period_year, period_month,
                              indicator_code, value, submission_date, data_source)
SELECT
    f.facility_id,
    'monthly',
    2023,
    m.month_num,
    'TX_CURR',
    FLOOR(150 + RANDOM()*600),
    (MAKE_DATE(2023, m.month_num, 1) + INTERVAL '15 days')::TIMESTAMPTZ,
    'DHIS2'
FROM facility f
CROSS JOIN (SELECT generate_series(1,9) AS month_num) m
WHERE f.is_active = TRUE
LIMIT 100;

-- [DQ: TIMELINESS] Reports submitted >60 days after period end
INSERT INTO aggregate_report (facility_id, period_type, period_year, period_month,
                              indicator_code, value, submission_date, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '23001'), 'monthly', 2023, 3, 'HTS_TST', 145, '2023-07-15 09:00:00+03', 'DHIS2'),
((SELECT facility_id FROM facility WHERE mfl_code = '23150'), 'monthly', 2023, 3, 'TX_CURR',  89, '2023-08-22 11:30:00+03', 'DHIS2'),
((SELECT facility_id FROM facility WHERE mfl_code = '23300'), 'monthly', 2023, 2, 'TB_NOTIF', 12, '2023-07-01 08:00:00+03', 'DHIS2');

-- [DQ: VALIDITY] Negative value in aggregate report
INSERT INTO aggregate_report (facility_id, period_type, period_year, period_month,
                              indicator_code, value, submission_date, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'monthly', 2023, 5, 'TX_NEW', -15, '2023-06-12 10:00:00+03', 'DHIS2');

-- [DQ: PLAUSIBILITY] TX_CURR > TX_CURR previous month by >200% (extreme jump)
INSERT INTO aggregate_report (facility_id, period_type, period_year, period_month,
                              indicator_code, value, submission_date, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'monthly', 2023, 6, 'TX_CURR', 9999, '2023-07-10 09:00:00+03', 'DHIS2'),
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 'monthly', 2023, 7, 'TX_CURR', 450,  '2023-08-12 09:00:00+03', 'DHIS2');

-- [DQ: CONSISTENCY] HTS_TST_POS > HTS_TST (more positives than tests)
INSERT INTO aggregate_report (facility_id, period_type, period_year, period_month,
                              indicator_code, value, submission_date, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14901'), 'monthly', 2023, 8, 'HTS_TST',     200, '2023-09-14 08:00:00+03', 'DHIS2'),
((SELECT facility_id FROM facility WHERE mfl_code = '14901'), 'monthly', 2023, 8, 'HTS_TST_POS', 350, '2023-09-14 08:00:00+03', 'DHIS2');

-- ---------------------------------------------------------------------------
-- STOCK RECORDS
-- ---------------------------------------------------------------------------

INSERT INTO stock_record (facility_id, commodity_id, record_date, opening_balance,
                          received_qty, dispensed_qty, losses_adjustments, closing_balance,
                          days_out_of_stock, data_source)
SELECT
    f.facility_id,
    c.commodity_id,
    ('2023-01-01'::DATE + (m * 30)),
    ROUND((500 + RANDOM()*3000)::NUMERIC, 2),
    ROUND((RANDOM()*1000)::NUMERIC, 2),
    ROUND((100 + RANDOM()*800)::NUMERIC, 2),
    ROUND((RANDOM()*50)::NUMERIC, 2),
    ROUND((500 + RANDOM()*2500)::NUMERIC, 2),  -- will have balance errors (DQ check will catch)
    0,
    'DHIS2'
FROM facility f
CROSS JOIN commodity c
CROSS JOIN generate_series(0,8) m
WHERE f.is_active = TRUE AND c.is_tracer = TRUE
LIMIT 300;

-- [DQ: CONSISTENCY] Closing balance doesn't match arithmetic
-- (opening + received - dispensed - losses ≠ closing)
INSERT INTO stock_record (facility_id, commodity_id, record_date, opening_balance,
                          received_qty, dispensed_qty, losses_adjustments,
                          closing_balance, days_out_of_stock, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '14880'), 1, '2023-10-31', 1200, 500, 600, 20, 900,  0, 'DHIS2'),  -- correct is 1080, entered 900
((SELECT facility_id FROM facility WHERE mfl_code = '14901'), 2, '2023-10-31', 800,  300, 400, 10, 1200, 0, 'DHIS2'),  -- correct is 690, entered 1200
((SELECT facility_id FROM facility WHERE mfl_code = '18001'), 1, '2023-10-31', 2000, 0,   950, 50, 500,  0, 'DHIS2');  -- correct is 1000, entered 500

-- [DQ: PLAUSIBILITY] Days out of stock = 45 (impossible for a monthly record)
INSERT INTO stock_record (facility_id, commodity_id, record_date, opening_balance,
                          received_qty, dispensed_qty, closing_balance,
                          days_out_of_stock, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '23001'), 7, '2023-09-30', 0, 0, 0, 0, 45, 'DHIS2');

-- [DQ: COMPLETENESS] Stock records with NULL closing balance (not flagged as known stockout)
INSERT INTO stock_record (facility_id, commodity_id, record_date, opening_balance,
                          received_qty, dispensed_qty, closing_balance, data_source) VALUES
((SELECT facility_id FROM facility WHERE mfl_code = '36001'), 3, '2023-08-31', 300, 100, 250, NULL, 'DHIS2'),
((SELECT facility_id FROM facility WHERE mfl_code = '36150'), 1, '2023-08-31', 150, 0,   150, NULL, 'DHIS2');

-- ---------------------------------------------------------------------------
-- CHW SERVICE RECORDS (sample)
-- ---------------------------------------------------------------------------
INSERT INTO chw_service_record (chw_id, patient_id, service_date, service_type, outcome, data_source)
SELECT
    chw.chw_id,
    p.patient_id,
    ('2023-01-01'::DATE + (RANDOM()*300)::INT),
    (ARRAY['household_visit','defaulter_tracing','referral','health_education'])[CEIL(RANDOM()*4)::INT],
    (ARRAY['client_found','client_absent','referred_facility','completed'])[CEIL(RANDOM()*4)::INT],
    'mobile_CHW'
FROM chw
CROSS JOIN patient p
WHERE chw.is_active = TRUE
  AND p.facility_id IN (SELECT facility_id FROM facility WHERE county_id IN (47, 40))
LIMIT 120;

-- [DQ: TIMELINESS] CHW records submitted > 30 days after service date
INSERT INTO chw_service_record (chw_id, service_date, service_type, outcome, data_source)
SELECT
    chw_id,
    '2023-04-01',    -- service was in April
    'defaulter_tracing',
    'client_found',
    'mobile_CHW'
FROM chw
WHERE chw_code = 'CHW-KIB-001';
-- The created_at will be NOW() which is far past April 2023, triggering the timeliness check.

COMMIT;
