-- schema_scenarios.sql
-- Scenario verification for the CNG schema (prompt §35, scenarios A–K).
--
-- Run against a scratch database that has had 0001–0013 applied:
--   psql -d cng_test -v ON_ERROR_STOP=1 -f supabase/tests/schema_scenarios.sql
--
-- Every scenario asserts. A constraint that should reject bad data is proved by
-- attempting the write and requiring it to fail. The whole script runs inside a
-- transaction and rolls back: it never leaves data behind.

BEGIN;

\set ON_ERROR_STOP on
SET client_min_messages = notice;

-- Assert helper: raises if the condition is false.
CREATE OR REPLACE FUNCTION pg_temp.assert(p_ok boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT p_ok THEN RAISE EXCEPTION 'FAILED: %', p_label; END IF;
  RAISE NOTICE 'PASS  %', p_label;
END $$;

-- Assert that a statement is REJECTED by the database.
CREATE OR REPLACE FUNCTION pg_temp.assert_rejected(p_sql text, p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'PASS  % (rejected: %)', p_label, left(SQLERRM, 60);
    RETURN;
  END;
  RAISE EXCEPTION 'FAILED: % — the database ACCEPTED data it should reject', p_label;
END $$;

-- ---------------------------------------------------------------------------
-- Fixtures: minimal hierarchy. Structural test data only; no production values.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE ids AS
SELECT
  (SELECT id FROM regions WHERE code = 'east')  AS region_east,
  (SELECT id FROM regions WHERE code = 'canal') AS region_canal;

INSERT INTO app_users (id, clerk_user_id, role, full_name)
VALUES ('11111111-1111-1111-1111-111111111111', 'user_test_engineer', 'engineer', 'Test Engineer');

INSERT INTO stations (id, region_id, station_name)
SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east, 'TEST-STATION-A' FROM ids;
INSERT INTO stations (id, region_id, station_name)
SELECT 'aaaaaaaa-0000-0000-0000-000000000002', region_canal, 'TEST-STATION-CANAL' FROM ids;

INSERT INTO units (id, station_id, region_id, unit_name)
SELECT 'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', region_east, 'TEST-UNIT-1' FROM ids;
-- A second station's unit, used to prove cross-station parents are rejected.
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT 'bbbbbbbb-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal, 'TEST-UNIT-OTHER' FROM ids;

INSERT INTO compressors (id, station_id, region_id, unit_id, mapping_status, model)
SELECT 'cccccccc-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'bbbbbbbb-0000-0000-0000-000000000001', 'resolved', 'TEST-COMPRESSOR' FROM ids;
INSERT INTO storage_vessels (id, station_id, region_id, unit_id, mapping_status, model)
SELECT 'dddddddd-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'bbbbbbbb-0000-0000-0000-000000000001', 'resolved', 'TEST-VESSEL' FROM ids;
INSERT INTO dispensers (id, station_id, region_id, unit_id, mapping_status, dispenser_name)
SELECT 'eeeeeeee-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'bbbbbbbb-0000-0000-0000-000000000001', 'resolved', 'A-B' FROM ids;
-- Compressor belonging to the OTHER station, for the cross-unit rejection test.
INSERT INTO compressors (id, station_id, region_id, unit_id, mapping_status, model)
SELECT 'cccccccc-0000-0000-0000-000000000099', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'bbbbbbbb-0000-0000-0000-000000000002', 'resolved', 'OTHER-COMPRESSOR' FROM ids;

-- ===========================================================================
-- Scenario A — fully resolved Compressor SRV; strict FK consistency
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, unit_id, compressor_id, mapping_status,
   location_raw, expected_parent_kind, serial_number, serial_status,
   resolved_by, resolved_at)
SELECT 'ffffffff-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'bbbbbbbb-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'resolved',
       'Stage', 'compressor', 'TEST-SRV-A', 'assigned',
       '11111111-1111-1111-1111-111111111111', now()
FROM ids;
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM installed_relief_valves
    WHERE id = 'ffffffff-0000-0000-0000-00000000000a' AND mapping_status = 'resolved'),
  'A: resolved compressor SRV accepted');

-- A2: a parent from a different unit/station must be rejected (composite FK).
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves
    (station_id, region_id, unit_id, compressor_id, mapping_status, resolved_by, resolved_at)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'bbbbbbbb-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000099',
         'resolved', '11111111-1111-1111-1111-111111111111', now() FROM ids;
$$, 'A2: compressor from another unit rejected by composite FK');

-- A3: two parents at once must be rejected (num_nonnulls = 1).
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves
    (station_id, region_id, unit_id, compressor_id, storage_vessel_id, mapping_status, resolved_by, resolved_at)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'bbbbbbbb-0000-0000-0000-000000000001',
         'cccccccc-0000-0000-0000-000000000001', 'dddddddd-0000-0000-0000-000000000001',
         'resolved', '11111111-1111-1111-1111-111111111111', now() FROM ids;
$$, 'A3: two equipment parents rejected');

-- A4: resolved with NO parent must be rejected.
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves
    (station_id, region_id, unit_id, mapping_status, resolved_by, resolved_at)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'bbbbbbbb-0000-0000-0000-000000000001', 'resolved',
         '11111111-1111-1111-1111-111111111111', now() FROM ids;
$$, 'A4: resolved without an equipment parent rejected');

-- A5: resolved without attribution must be rejected.
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves
    (station_id, region_id, unit_id, compressor_id, mapping_status)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'bbbbbbbb-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'resolved' FROM ids;
$$, 'A5: resolved without resolved_by/resolved_at rejected');

-- ===========================================================================
-- Scenario B — Station known, Unit unknown
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, location_raw, expected_parent_kind, serial_number)
SELECT 'ffffffff-0000-0000-0000-00000000000b', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'needs_unit_mapping', 'Storage', 'storage_vessel', 'TEST-SRV-B' FROM ids;
SELECT pg_temp.assert(
  (SELECT unit_id IS NULL AND compressor_id IS NULL AND storage_vessel_id IS NULL AND dispenser_id IS NULL
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-00000000000b'),
  'B: needs_unit_mapping SRV stored with station only');

-- B2: needs_unit_mapping may not carry a unit.
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves (station_id, region_id, unit_id, mapping_status)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'bbbbbbbb-0000-0000-0000-000000000001', 'needs_unit_mapping' FROM ids;
$$, 'B2: needs_unit_mapping with a unit rejected');

-- B3: the hint must never be usable as a parent — an equipment FK while
-- unresolved is rejected.
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves (station_id, region_id, compressor_id, mapping_status, expected_parent_kind)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'cccccccc-0000-0000-0000-000000000001', 'needs_unit_mapping', 'compressor' FROM ids;
$$, 'B3: expected_parent_kind cannot leak into an equipment FK');

-- ===========================================================================
-- Scenario C — Station + Unit known, equipment unknown
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, unit_id, mapping_status, location_raw, expected_parent_kind)
SELECT 'ffffffff-0000-0000-0000-00000000000c', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'bbbbbbbb-0000-0000-0000-000000000001', 'needs_equipment_mapping', 'Stage', 'compressor' FROM ids;
SELECT pg_temp.assert(
  (SELECT unit_id IS NOT NULL AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-00000000000c'),
  'C: needs_equipment_mapping SRV stored with unit but no parent');

-- C2: unit must still belong to the stated station.
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves (station_id, region_id, unit_id, mapping_status)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'bbbbbbbb-0000-0000-0000-000000000002', 'needs_equipment_mapping' FROM ids;
$$, 'C2: unit from another station rejected');

-- ===========================================================================
-- Scenario D — conflicting source evidence
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, mapping_note, location_raw)
SELECT 'ffffffff-0000-0000-0000-00000000000d', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'conflict', 'Two sources place this tag on different equipment', 'Stage' FROM ids;
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM installed_relief_valves
    WHERE id = 'ffffffff-0000-0000-0000-00000000000d' AND mapping_status = 'conflict'),
  'D: conflict SRV preserved');
SELECT pg_temp.assert(
  (SELECT count(*) = 0 FROM v_unit_srvs WHERE id = 'ffffffff-0000-0000-0000-00000000000d'),
  'D2: conflict SRV never appears in a Unit SRV tab');

-- ===========================================================================
-- Scenario E — Storage Vessel, Station known, Unit unknown
-- ===========================================================================
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, manufacturer, serial_number)
SELECT 'dddddddd-0000-0000-0000-00000000e001', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', 'TEST-MFR', 'TEST-VESSEL-E' FROM ids;
SELECT pg_temp.assert(
  (SELECT unit_id IS NULL FROM storage_vessels WHERE id = 'dddddddd-0000-0000-0000-00000000e001'),
  'E: storage vessel preserved with unknown unit');
SELECT pg_temp.assert(
  (SELECT needs_mapping FROM v_vessel_management WHERE id = 'dddddddd-0000-0000-0000-00000000e001'),
  'E2: appears in vessel management flagged needs_mapping');

-- ===========================================================================
-- Scenario F — Gas Detector explicitly NOT installed
-- ===========================================================================
INSERT INTO gas_detector_presence
  (station_id, region_id, detector_presence, presence_raw, area_type, area_type_raw)
SELECT 'aaaaaaaa-0000-0000-0000-000000000002', region_canal, 'not_installed',
       'Not exist in the station', 'closed', 'Closed Area' FROM ids;
SELECT pg_temp.assert(
  (SELECT count(*) = 0 FROM gas_detectors WHERE station_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'F: no gas_detectors row created for a not-installed station');
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM v_gas_detector_management
    WHERE station_id = 'aaaaaaaa-0000-0000-0000-000000000002'
      AND detector_presence = 'not_installed' AND detector_id IS NULL),
  'F2: absence visible in the management view with detector_id NULL');

-- ===========================================================================
-- Scenario G — Hose, Station known, Unit unknown
-- ===========================================================================
INSERT INTO hoses (id, station_id, region_id, mapping_status, description,
                   serial_number, working_pressure_raw, working_pressure_value, working_pressure_unit,
                   test_pressure_raw, test_pressure_value, test_pressure_unit)
SELECT '99999999-0000-0000-0000-000000000071', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', 'TEST-HOSE', 'TEST-HOSE-G',
       '1000 PSI', 1000, 'PSI', '1500 PSI', 1500, 'PSI' FROM ids;
SELECT pg_temp.assert(
  (SELECT unit_id IS NULL AND dispenser_id IS NULL FROM hoses WHERE serial_number = 'TEST-HOSE-G'),
  'G: hose preserved with unknown unit and no dispenser');

-- G2: a dispenser may not be attached while the unit is unknown.
SELECT pg_temp.assert_rejected($$
  INSERT INTO hoses (station_id, region_id, dispenser_id, mapping_status)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
         'eeeeeeee-0000-0000-0000-000000000001', 'needs_unit_mapping' FROM ids;
$$, 'G2: dispenser without a unit rejected');

-- ===========================================================================
-- Scenario H — year-only calibration date
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status,
   next_calibration_raw, next_calibration_date, next_calibration_precision)
SELECT 'ffffffff-0000-0000-0000-0000000000e8', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'needs_unit_mapping', '2021', NULL, 'year_only' FROM ids;
SELECT pg_temp.assert(
  (SELECT next_calibration_date IS NULL AND next_calibration_precision = 'year_only'
          AND next_calibration_raw = '2021'
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-0000000000e8'),
  'H: year-only date kept raw, exact date NULL');
SELECT pg_temp.assert(
  (SELECT days_left IS NULL AND due_status = 'unknown'
     FROM v_installed_srv_management WHERE id = 'ffffffff-0000-0000-0000-0000000000e8'),
  'H2: year-only yields NULL Days Left and unknown status — never 0, never overdue');

-- H3: claiming exact precision with no date must be rejected.
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves (station_id, region_id, mapping_status, next_calibration_precision)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east, 'needs_unit_mapping', 'exact_date' FROM ids;
$$, 'H3: exact_date precision without a date rejected');

-- H4: storing a date while claiming year_only must be rejected.
SELECT pg_temp.assert_rejected($$
  INSERT INTO installed_relief_valves
    (station_id, region_id, mapping_status, next_calibration_date, next_calibration_precision)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_east, 'needs_unit_mapping',
         DATE '2021-01-01', 'year_only' FROM ids;
$$, 'H4: a real date stored as year_only rejected (no silent 1 January)');

-- ===========================================================================
-- Scenario I — serial with leading zeros survives as TEXT
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, serial_number, serial_number_raw, serial_status)
SELECT 'ffffffff-0000-0000-0000-0000000000e9', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'needs_unit_mapping', '0003262609', '0003262609', 'assigned' FROM ids;
SELECT pg_temp.assert(
  (SELECT serial_number = '0003262609' AND length(serial_number) = 10
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-0000000000e9'),
  'I: leading zeros preserved exactly (TEXT, 10 chars)');

-- ===========================================================================
-- Scenario J — part number in the serial column, preserved and not deduplicated
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, serial_number_raw, serial_number,
   serial_status, needs_review, review_reason)
SELECT 'ffffffff-0000-0000-0000-0000000000ea', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'needs_unit_mapping', 'SS-4R3A', 'SS-4R3A', 'unknown', true,
       'suspected_part_number_in_serial_column' FROM ids;
-- A second row with the same value must be accepted: repeats are not duplicates
-- without evidence (principle #16). There is deliberately no unique constraint.
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, serial_number_raw, serial_number,
   serial_status, needs_review, review_reason)
SELECT 'ffffffff-0000-0000-0000-0000000000eb', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'needs_unit_mapping', 'SS-4R3A', 'SS-4R3A', 'unknown', true,
       'suspected_part_number_in_serial_column' FROM ids;
SELECT pg_temp.assert(
  (SELECT count(*) = 2 FROM installed_relief_valves WHERE serial_number_raw = 'SS-4R3A'),
  'J: repeated SS-4R3A rows both preserved, no auto-deduplication');
SELECT pg_temp.assert(
  (SELECT count(*) = 2 FROM v_data_quality_queue
    WHERE asset_type = 'installed_relief_valve' AND needs_review),
  'J2: both flagged into the Data Quality queue');

-- ===========================================================================
-- Scenario K — unresolved SRV with an exact next due date is alertable
-- ===========================================================================
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, location_raw, expected_parent_kind,
   next_calibration_raw, next_calibration_date, next_calibration_precision)
SELECT 'ffffffff-0000-0000-0000-0000000000ec', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'needs_unit_mapping', 'Storage', 'storage_vessel',
       to_char(cng_business_date() + 20, 'YYYY-MM-DD'), cng_business_date() + 20, 'exact_date' FROM ids;
SELECT pg_temp.assert(
  (SELECT days_left = 20 AND due_status = 'due_30' AND needs_mapping
     FROM v_installed_srv_management WHERE id = 'ffffffff-0000-0000-0000-0000000000ec'),
  'K: unresolved SRV has live Days Left and due status, flagged needs_mapping');

-- The alert itself: no unit, no equipment, still alertable.
INSERT INTO alerts (alert_rule_id, subject, threshold, asset_type, asset_id,
                    region_id, station_id, unit_id, due_date, days_left, needs_mapping)
SELECT (SELECT id FROM alert_rules WHERE subject = 'srv_calibration' AND threshold = 'due_30'),
       'srv_calibration', 'due_30', 'installed_relief_valve',
       'ffffffff-0000-0000-0000-0000000000ec', region_east,
       'aaaaaaaa-0000-0000-0000-000000000001', NULL,
       cng_business_date() + 20, 20, true
FROM ids;
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM alerts
    WHERE asset_id = 'ffffffff-0000-0000-0000-0000000000ec' AND unit_id IS NULL AND needs_mapping),
  'K2: alert generated for an unresolved SRV with unit_id NULL');

-- K3: alert de-duplication holds.
SELECT pg_temp.assert_rejected($$
  INSERT INTO alerts (alert_rule_id, subject, threshold, asset_type, asset_id,
                      region_id, station_id, due_date, needs_mapping)
  SELECT (SELECT id FROM alert_rules WHERE subject = 'srv_calibration' AND threshold = 'due_30'),
         'srv_calibration', 'due_30', 'installed_relief_valve',
         'ffffffff-0000-0000-0000-0000000000ec', region_east,
         'aaaaaaaa-0000-0000-0000-000000000001', cng_business_date() + 20, true FROM ids;
$$, 'K3: duplicate alert for the same asset/threshold/due date rejected');

-- ===========================================================================
-- Cross-cutting checks
-- ===========================================================================

-- Unit SRV tab contents: only the resolved and needs_equipment_mapping rows.
SELECT pg_temp.assert(
  (SELECT count(*) = 2 FROM v_unit_srvs WHERE unit_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  'X1: Unit SRV tab shows exactly the resolved + needs_equipment_mapping SRVs');
SELECT pg_temp.assert(
  (SELECT bool_and(mapping_status IN ('resolved','needs_equipment_mapping')) FROM v_unit_srvs),
  'X2: Unit SRV tab never contains needs_unit_mapping or conflict');

-- Alias discipline: a confirmed alias must name a station.
SELECT pg_temp.assert_rejected($$
  INSERT INTO station_aliases (region_id, source_name_raw, source_name_normalized, source_file,
                               alias_status, alias_source)
  SELECT region_east, 'X', 'x', 'test.xlsx', 'confirmed', 'human' FROM ids;
$$, 'X3: confirmed alias without a station rejected');

-- A proposed alias is allowed to have no station — that is its purpose.
INSERT INTO station_aliases (region_id, source_name_raw, source_name_normalized, source_file,
                             alias_status, alias_source)
SELECT region_east, 'ابنوب اسيوط', cng_normalize_name('ابنوب اسيوط'), 'Gas detector.xlsx',
       'proposed', 'rule:governorate_suffix' FROM ids;
SELECT pg_temp.assert(
  (SELECT station_id IS NULL AND alias_status = 'proposed'
     FROM station_aliases WHERE source_name_raw = 'ابنوب اسيوط'),
  'X4: rule-derived alias inserted as PROPOSED with no station attached');

-- Region alias normalization is deterministic for the observed values.
SELECT pg_temp.assert(
  cng_normalize_name('  WEST  ') = 'west' AND cng_normalize_name('ابو رواش') IS NOT NULL,
  'X5: name normalization deterministic');

-- Hierarchy integrity: a unit cannot claim a region different from its station's.
SELECT pg_temp.assert_rejected($$
  INSERT INTO units (station_id, region_id, unit_name)
  SELECT 'aaaaaaaa-0000-0000-0000-000000000001', region_canal, 'WRONG-REGION-UNIT' FROM ids;
$$, 'X6: unit region must match its station region');

-- Deletion protection: a station carrying assets cannot be deleted.
SELECT pg_temp.assert_rejected($$
  DELETE FROM stations WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
$$, 'X7: station with dependent records cannot be hard-deleted (RESTRICT)');

-- Decision D7: an asset is never auto-attached to a unit, even when the station
-- happens to have exactly one. The vessel from Scenario E sits at a station that
-- DOES have a unit, and must still have unit_id NULL.
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM units WHERE station_id = 'aaaaaaaa-0000-0000-0000-000000000002')
  AND (SELECT unit_id IS NULL FROM storage_vessels WHERE id = 'dddddddd-0000-0000-0000-00000000e001'),
  'X8: no one-unit-per-station fallback — asset stays unmapped even where a single unit exists');

-- The SRV mapping queue is reachable by station, which is the mapping UI's
-- primary screen.
SELECT pg_temp.assert(
  (SELECT count(*) >= 1 FROM v_data_quality_queue
    WHERE asset_type = 'installed_relief_valve'
      AND station_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'X9: unresolved SRVs reachable from the Data Quality queue by station');

ROLLBACK;
