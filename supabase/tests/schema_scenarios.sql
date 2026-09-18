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
-- Guard: every table in the schema must have RLS enabled. This fails loudly if
-- a future migration adds a table and forgets — the exact gap that let
-- owner_confirmed_* ship without RLS on the first attempt.
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND NOT rowsecurity),
  'X10: every table has RLS enabled');

-- ===========================================================================
-- Scenario L — owner-confirmed station alias (corrections §1 and §6.1–6.2)
-- ===========================================================================

-- L1: the owner-confirmed pair resolves.
SELECT pg_temp.assert(
  cng_owner_confirmed_canonical('ابنوب') = 'ابنوب اسيوط',
  'L1: ابنوب resolves to canonical ابنوب اسيوط through the owner-confirmed alias');

-- L2: THE CRITICAL NEGATIVE. Confirming one pair must NOT make governorate-suffix
-- stripping valid in general. These names differ from a canonical name only by a
-- governorate qualifier and must NOT resolve, because the owner has not ruled on
-- them.
SELECT pg_temp.assert(
  cng_owner_confirmed_canonical('ابو القمصان') IS NULL
  AND cng_owner_confirmed_canonical('ابو تيج- اسيوط') IS NULL
  AND cng_owner_confirmed_canonical('الادبيه - السويس') IS NULL,
  'L2: other governorate-suffixed names do NOT resolve — no generic suffix stripping');

-- L3: the lookup is exact, not a prefix or substring match.
SELECT pg_temp.assert(
  cng_owner_confirmed_canonical('ابنوب اسيوط الجديدة') IS NULL,
  'L3: a longer name containing the confirmed one does not resolve');

-- L4: a confirmed alias may be recorded against a canonical station and used to
-- resolve, with its owner provenance retained.
INSERT INTO stations (id, region_id, station_name)
SELECT 'aaaaaaaa-0000-0000-0000-0000000000a1', region_east, 'ابنوب اسيوط' FROM ids;
INSERT INTO station_aliases
  (region_id, station_id, source_name_raw, source_name_normalized, source_file,
   alias_status, alias_source, confirmed_by, confirmed_at, notes)
SELECT region_east, 'aaaaaaaa-0000-0000-0000-0000000000a1', 'ابنوب',
       cng_normalize_name('ابنوب'), 'Warehouse Relief Data.xlsx',
       'confirmed', 'owner_confirmed',
       '11111111-1111-1111-1111-111111111111', now(),
       'Owner-confirmed pair; not a general suffix rule'
FROM ids;
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM station_aliases a
     JOIN stations st ON st.id = a.station_id
    WHERE a.source_name_raw = 'ابنوب' AND a.alias_status = 'confirmed'
      AND a.alias_source = 'owner_confirmed' AND st.station_name = 'ابنوب اسيوط'),
  'L4: owner-confirmed alias stored as confirmed, pointing at the canonical station');

-- ===========================================================================
-- Scenario M — SS-4R3A normalizes to part_number (corrections §2 and §6.3)
-- ===========================================================================

-- M1: the classifier puts the confirmed value in part_number, not serial_number.
SELECT pg_temp.assert(
  (SELECT part_number FROM cng_classify_identifier('SS-4R3A', 'installed_relief_valve')) = 'SS-4R3A'
  AND (SELECT serial_number FROM cng_classify_identifier('SS-4R3A', 'installed_relief_valve')) IS NULL,
  'M1: SS-4R3A classified as part_number with serial_number NULL');

-- M2: an ordinary serial is untouched — no shape-based guessing.
SELECT pg_temp.assert(
  (SELECT serial_number FROM cng_classify_identifier('0003262609', 'installed_relief_valve')) = '0003262609'
  AND (SELECT part_number FROM cng_classify_identifier('0003262609', 'installed_relief_valve')) IS NULL,
  'M2: an unlisted value stays a serial number');

-- M3: another part-number-LOOKING value is NOT reclassified.
SELECT pg_temp.assert(
  (SELECT serial_number FROM cng_classify_identifier('SS-9X1B', 'installed_relief_valve')) = 'SS-9X1B'
  AND (SELECT part_number FROM cng_classify_identifier('SS-9X1B', 'installed_relief_valve')) IS NULL,
  'M3: a similar-looking unconfirmed value is NOT moved to part_number');

-- M4: an imported row stores the classification while keeping raw evidence.
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, serial_number, part_number,
   serial_number_raw, serial_status, source_file, source_sheet, source_row, source_raw, needs_review)
SELECT 'ffffffff-0000-0000-0000-00000000ea01', 'aaaaaaaa-0000-0000-0000-000000000001', region_east,
       'needs_unit_mapping',
       (SELECT serial_number FROM cng_classify_identifier('SS-4R3A', 'installed_relief_valve')),
       (SELECT part_number   FROM cng_classify_identifier('SS-4R3A', 'installed_relief_valve')),
       'SS-4R3A', 'not_yet_assigned',
       'Warehouse Relief Data.xlsx', 'رصيد المحطات', 1234,
       jsonb_build_object('Serial Number', 'SS-4R3A', 'Set Pressure', '330 BAR'),
       true
FROM ids;
SELECT pg_temp.assert(
  (SELECT serial_number IS NULL AND part_number = 'SS-4R3A'
          AND serial_number_raw = 'SS-4R3A'
          AND source_raw ->> 'Serial Number' = 'SS-4R3A'
          AND source_file = 'Warehouse Relief Data.xlsx' AND source_row = 1234
          AND serial_status = 'not_yet_assigned'
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-00000000ea01'),
  'M4: stored as part_number, serial NULL, raw cell and file/sheet/row provenance preserved');

-- ===========================================================================
-- Scenario N — needs_station_mapping (corrections §3 and §6.4–6.7)
-- ===========================================================================

-- N1: an SRV with no confirmed station is still an installed SRV record.
INSERT INTO installed_relief_valves
  (id, station_id, region_id, mapping_status, source_station_name_raw, source_region_raw,
   location_raw, expected_parent_kind, serial_number,
   next_calibration_raw, next_calibration_date, next_calibration_precision,
   source_file, source_sheet, source_row, source_raw)
SELECT 'ffffffff-0000-0000-0000-00000000eb01', NULL, region_east,
       'needs_station_mapping', 'الخمائل 1', 'East', 'Storage', 'storage_vessel', 'TEST-SRV-N',
       to_char(cng_business_date() + 10, 'YYYY-MM-DD'), cng_business_date() + 10, 'exact_date',
       'Warehouse Relief Data.xlsx', 'رصيد المحطات', 4321,
       jsonb_build_object('Station', 'الخمائل 1', 'Area', 'East')
FROM ids;
SELECT pg_temp.assert(
  (SELECT station_id IS NULL AND unit_id IS NULL
          AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
          AND source_station_name_raw = 'الخمائل 1'
          AND source_raw ->> 'Station' = 'الخمائل 1'
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'N1: SRV stored with NULL station as needs_station_mapping, raw station name preserved');

-- N2: needs_station_mapping may not carry a unit.
SELECT pg_temp.assert_rejected($ins$
  INSERT INTO installed_relief_valves
    (station_id, region_id, unit_id, mapping_status, source_station_name_raw)
  SELECT NULL, region_east, 'bbbbbbbb-0000-0000-0000-000000000001',
         'needs_station_mapping', 'X' FROM ids;
$ins$, 'N2: needs_station_mapping with a unit rejected');

-- N3: needs_station_mapping may not carry an equipment parent.
SELECT pg_temp.assert_rejected($ins$
  INSERT INTO installed_relief_valves
    (station_id, region_id, compressor_id, mapping_status, source_station_name_raw)
  SELECT NULL, region_east, 'cccccccc-0000-0000-0000-000000000001',
         'needs_station_mapping', 'X' FROM ids;
$ins$, 'N3: needs_station_mapping with an equipment parent rejected');

-- N4: a station-less SRV must still say where the source placed it.
SELECT pg_temp.assert_rejected($ins$
  INSERT INTO installed_relief_valves (station_id, region_id, mapping_status)
  SELECT NULL, region_east, 'needs_station_mapping' FROM ids;
$ins$, 'N4: needs_station_mapping without the raw source station name rejected');

-- N5: every other state still requires a confirmed station.
SELECT pg_temp.assert_rejected($ins$
  INSERT INTO installed_relief_valves (station_id, region_id, mapping_status, source_station_name_raw)
  SELECT NULL, region_east, 'needs_unit_mapping', 'X' FROM ids;
$ins$, 'N5: needs_unit_mapping with a NULL station rejected');

-- N6: it IS visible in Global SRV Management, showing the raw name and label.
SELECT pg_temp.assert(
  (SELECT station_display = 'الخمائل 1' AND needs_station_mapping
          AND mapping_label = 'Needs Station Mapping' AND station_name IS NULL
     FROM v_installed_srv_management WHERE id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'N6: visible in Global SRV Management as "Needs Station Mapping" with the raw source name');

-- N7: it is NOT in any Unit SRV view.
SELECT pg_temp.assert(
  (SELECT count(*) = 0 FROM v_unit_srvs WHERE id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'N7: never appears in a Unit SRV tab');

-- N8: the asset lives in installed_relief_valves; the ISSUE lives in
-- import_issues. Both exist; import_issues is not the only home.
INSERT INTO import_batches (id, source_file, source_sheet, status, rows_read)
VALUES ('cafe0000-0000-0000-0000-000000000001', 'Warehouse Relief Data.xlsx', 'رصيد المحطات', 'dry_run', 1);
INSERT INTO import_issues
  (import_batch_id, source_file, source_sheet, source_row, source_value,
   entity_type, entity_id, region_id, issue_type, severity, detail)
SELECT 'cafe0000-0000-0000-0000-000000000001', 'Warehouse Relief Data.xlsx', 'رصيد المحطات', 4321,
       'الخمائل 1', 'installed_relief_valve', 'ffffffff-0000-0000-0000-00000000eb01',
       region_east, 'unmatched_station', 'warning',
       'Station name has no confirmed alias' FROM ids;
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-00000000eb01')
  AND (SELECT count(*) = 1 FROM import_issues
        WHERE entity_id = 'ffffffff-0000-0000-0000-00000000eb01' AND issue_type = 'unmatched_station'),
  'N8: asset in installed_relief_valves AND issue in import_issues — not issue-only storage');

-- ===========================================================================
-- Scenario O — due tracking without mapping (corrections §4, §6.8)
-- ===========================================================================
SELECT pg_temp.assert(
  (SELECT days_left = 10 AND due_status = 'due_15'
     FROM v_installed_srv_management WHERE id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'O1: exact due date still calculates Days Left and status with NO station mapping');

-- O2: an alert can be raised for it, naming the raw station and flagging the gap.
INSERT INTO alerts (alert_rule_id, subject, threshold, asset_type, asset_id,
                    region_id, station_id, unit_id, source_station_name_raw,
                    due_date, days_left, needs_mapping, needs_station_mapping)
SELECT (SELECT id FROM alert_rules WHERE subject = 'srv_calibration' AND threshold = 'due_15'),
       'srv_calibration', 'due_15', 'installed_relief_valve',
       'ffffffff-0000-0000-0000-00000000eb01', region_east, NULL, NULL, 'الخمائل 1',
       cng_business_date() + 10, 10, true, true
FROM ids;
SELECT pg_temp.assert(
  (SELECT station_id IS NULL AND source_station_name_raw = 'الخمائل 1' AND needs_station_mapping
     FROM alerts WHERE asset_id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'O2: alert raised with NULL station, carrying the raw source name — no Station fabricated');

-- ===========================================================================
-- Scenario P — lifecycle transitions (corrections §5, §6.9–6.10)
-- ===========================================================================

-- P1: confirming the station moves the row to needs_unit_mapping.
UPDATE installed_relief_valves
   SET station_id = 'aaaaaaaa-0000-0000-0000-0000000000a1',
       mapping_status = 'needs_unit_mapping',
       station_alias_id = (SELECT id FROM station_aliases WHERE source_name_raw = 'ابنوب')
 WHERE id = 'ffffffff-0000-0000-0000-00000000eb01';
SELECT pg_temp.assert(
  (SELECT mapping_status = 'needs_unit_mapping' AND station_id IS NOT NULL
          AND unit_id IS NULL AND source_station_name_raw = 'الخمائل 1'
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'P1: station confirmed -> needs_unit_mapping; raw source name still preserved');

-- P2: every transition is auditable.
INSERT INTO asset_mapping_audit
  (asset_type, asset_id, previous_station_id, new_station_id,
   previous_mapping_status, new_mapping_status, changed_by, reason)
VALUES ('installed_relief_valve', 'ffffffff-0000-0000-0000-00000000eb01',
        NULL, 'aaaaaaaa-0000-0000-0000-0000000000a1',
        'needs_station_mapping', 'needs_unit_mapping',
        '11111111-1111-1111-1111-111111111111', 'Owner-confirmed alias applied');
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM asset_mapping_audit
    WHERE asset_id = 'ffffffff-0000-0000-0000-00000000eb01'
      AND previous_mapping_status = 'needs_station_mapping'
      AND new_mapping_status = 'needs_unit_mapping' AND changed_by IS NOT NULL),
  'P2: the station-confirmation transition is recorded in asset_mapping_audit');

-- P3: an invalid transition is still rejected — jumping to resolved without a
-- unit or a parent.
SELECT pg_temp.assert_rejected($upd$
  UPDATE installed_relief_valves SET mapping_status = 'resolved'
   WHERE id = 'ffffffff-0000-0000-0000-00000000eb01';
$upd$, 'P3: needs_unit_mapping -> resolved without unit/parent rejected');

-- P4: and skipping straight from station-confirmed to an equipment parent
-- without a unit is rejected.
SELECT pg_temp.assert_rejected($upd$
  UPDATE installed_relief_valves
     SET mapping_status = 'needs_equipment_mapping'
   WHERE id = 'ffffffff-0000-0000-0000-00000000eb01';
$upd$, 'P4: needs_equipment_mapping without a confirmed unit rejected');

-- P5: the full happy path completes — unit then equipment then resolved.
UPDATE installed_relief_valves
   SET station_id = 'aaaaaaaa-0000-0000-0000-000000000001',
       unit_id = 'bbbbbbbb-0000-0000-0000-000000000001',
       mapping_status = 'needs_equipment_mapping'
 WHERE id = 'ffffffff-0000-0000-0000-00000000eb01';
UPDATE installed_relief_valves
   SET storage_vessel_id = 'dddddddd-0000-0000-0000-000000000001',
       mapping_status = 'resolved',
       resolved_by = '11111111-1111-1111-1111-111111111111',
       resolved_at = now()
 WHERE id = 'ffffffff-0000-0000-0000-00000000eb01';
SELECT pg_temp.assert(
  (SELECT mapping_status = 'resolved' AND storage_vessel_id IS NOT NULL AND resolved_by IS NOT NULL
     FROM installed_relief_valves WHERE id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'P5: full lifecycle station -> unit -> equipment -> resolved completes');

-- P6: and it now appears in the Unit SRV tab, where before it did not.
SELECT pg_temp.assert(
  (SELECT count(*) = 1 FROM v_unit_srvs WHERE id = 'ffffffff-0000-0000-0000-00000000eb01'),
  'P6: once resolved, the SRV appears in the Unit SRV tab');

-- P7: the mapping queue orders station work ahead of unit and equipment work.
SELECT pg_temp.assert(
  (SELECT min(queue_order) FROM v_srv_mapping_queue) >= 1,
  'P7: SRV mapping queue is populated and ordered by lifecycle stage');

-- ===========================================================================
-- NAME NORMALIZATION (0028)
-- ===========================================================================
-- cng_normalize_name backs stations_region_norm_uq and units_station_norm_uq —
-- it decides canonical Station and Unit IDENTITY. The original 0001 version
-- passed translate() 14 source characters against 5 replacements, so Arabic
-- diacritics and tatweel were REPLACED by ا (inserting letters that were never
-- written) while أ إ آ ى ة were DELETED outright. At the Prompt 21 import that
-- would have silently split or merged real stations. These assertions exist so
-- the folding rules can never regress unnoticed.

-- N1: taa marbuta folds to haa, so the two common spellings are one station.
SELECT pg_temp.assert(
  cng_normalize_name('الماظة') = cng_normalize_name('الماظه'),
  'N1: taa marbuta and haa spellings normalize to the same station identity');

-- N2: alef forms fold together WITHOUT dropping the letter.
SELECT pg_temp.assert(
  cng_normalize_name('إبراهيم') = cng_normalize_name('ابراهيم')
  AND cng_normalize_name('آمال') = cng_normalize_name('امال')
  AND length(cng_normalize_name('إبراهيم')) = length('ابراهيم'),
  'N2: hamzated alef folds to bare alef and is never deleted');

-- N3: alef maqsura folds to yaa rather than vanishing.
SELECT pg_temp.assert(
  cng_normalize_name('مصطفى') = cng_normalize_name('مصطفي'),
  'N3: alef maqsura folds to yaa');

-- N4: tatweel is STRIPPED, never turned into a letter. This was the defect
-- that turned طاليــا into طاليااا.
SELECT pg_temp.assert(
  cng_normalize_name('طاليــا') = cng_normalize_name('طاليا'),
  'N4: tatweel is removed and never substituted with a letter');

-- N5: diacritics are removed, not substituted.
SELECT pg_temp.assert(
  cng_normalize_name('شَبرا') = cng_normalize_name('شبرا'),
  'N5: Arabic diacritics are removed without inserting characters');

-- N6: case and whitespace folding still hold for Latin names.
SELECT pg_temp.assert(
  cng_normalize_name('  East   Station ') = 'east station',
  'N6: case folded, edges trimmed, internal whitespace collapsed');

-- N7: a name that is only whitespace normalizes to NULL, so it can never
-- become a canonical identity.
SELECT pg_temp.assert(
  cng_normalize_name('   ') IS NULL AND cng_normalize_name(NULL) IS NULL,
  'N7: an empty or whitespace-only name normalizes to NULL, never to a key');

-- N8: distinct stations must NOT be merged by folding. Identity rules that
-- over-merge are as damaging as ones that over-split.
SELECT pg_temp.assert(
  cng_normalize_name('ابنوب') <> cng_normalize_name('ابنوب اسيوط')
  AND cng_normalize_name('شبرا 1') <> cng_normalize_name('شبرا 2'),
  'N8: folding never merges genuinely different names — that is the alias table''s job');

-- N9: the generated columns actually carry the fixed folding, not a stale
-- value from before the function was replaced.
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM stations
               WHERE normalized_name IS DISTINCT FROM cng_normalize_name(station_name))
  AND NOT EXISTS (SELECT 1 FROM units
                   WHERE normalized_name IS DISTINCT FROM cng_normalize_name(unit_name)),
  'N9: stored normalized_name matches the current folding function');


-- ---------------------------------------------------------------------------
-- Gas detector constraints (Prompt 13).
--
-- These defend the data principles the registry depends on: a date and its
-- precision cannot disagree, an unresolved detector cannot masquerade as
-- resolved, and absence is evidence rather than a fabricated device.
-- ---------------------------------------------------------------------------

-- GDS1: a year-only next-calibration date cannot also carry a real date, so it
-- can never leak into an exact countdown.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO gas_detectors (station_id, region_id, mapping_status,
                             next_calibration_date, next_calibration_precision)
  SELECT s.id, s.region_id, 'needs_unit_mapping', DATE '2027-01-01', 'year_only'
    FROM stations s LIMIT 1$q$,
  'GDS1: a year_only next calibration cannot carry an exact date');

-- GDS2: nor the reverse — an exact precision with no date at all.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO gas_detectors (station_id, region_id, mapping_status,
                             next_calibration_date, next_calibration_precision)
  SELECT s.id, s.region_id, 'needs_unit_mapping', NULL, 'exact_date'
    FROM stations s LIMIT 1$q$,
  'GDS2: an exact_date precision cannot stand without a date');

-- GDS3: the same rule holds for the LAST calibration date.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO gas_detectors (station_id, region_id, mapping_status,
                             last_calibration_date, last_calibration_precision)
  SELECT s.id, s.region_id, 'needs_unit_mapping', NULL, 'exact_date'
    FROM stations s LIMIT 1$q$,
  'GDS3: last calibration precision and date cannot disagree either');

-- GDS4: a detector cannot claim to be resolved without a confirmed Unit. This
-- is what keeps the Unit tab honest.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO gas_detectors (station_id, region_id, unit_id, mapping_status)
  SELECT s.id, s.region_id, NULL, 'resolved' FROM stations s LIMIT 1$q$,
  'GDS4: a resolved detector must carry a confirmed Unit');

-- GDS5: and a detector awaiting unit mapping cannot secretly hold one.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO gas_detectors (station_id, region_id, unit_id, mapping_status)
  SELECT u.station_id, u.region_id, u.id, 'needs_unit_mapping' FROM units u LIMIT 1$q$,
  'GDS5: needs_unit_mapping means the Unit really is absent');

-- GDS6: MANDATORY canonical-compatibility check (prompt 13 section 9).
-- station_id is NOT NULL, so needs_station_mapping cannot be stored. Prompt 6
-- staged 219 detector rows in that state: a Prompt-21 import blocker.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO gas_detectors (station_id, region_id, mapping_status)
  SELECT NULL, id, 'needs_station_mapping' FROM regions LIMIT 1$q$,
  'GDS6: BLOCKER - a station-unconfirmed gas detector cannot enter the canonical table');

-- GDS7: a detector's region must be its station's region. The composite FK
-- makes region_id a trustworthy authorization key rather than a loose copy.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO gas_detectors (station_id, region_id, mapping_status)
  SELECT s.id, r.id, 'needs_unit_mapping'
    FROM stations s, regions r WHERE r.id <> s.region_id LIMIT 1$q$,
  'GDS7: a detector cannot be filed under a region its station does not belong to');

-- GDS8: recorded absence is storable as EVIDENCE, and storing it creates no
-- detector row. This insert must be ACCEPTED: absence is worth keeping.
CREATE TEMP TABLE gds8 AS SELECT id AS station_id, region_id FROM stations ORDER BY id DESC LIMIT 1;
INSERT INTO gas_detector_presence (station_id, region_id, detector_presence, presence_raw)
SELECT station_id, region_id, 'not_installed', 'Not exist in the station' FROM gds8;
SELECT pg_temp.assert(
  (SELECT count(*) FROM gas_detector_presence p JOIN gds8 g USING (station_id)
    WHERE p.detector_presence = 'not_installed') = 1
  AND (SELECT count(*) FROM gas_detectors d JOIN gds8 g USING (station_id)) = 0,
  'GDS8: recorded absence is storable as evidence, and fabricates no detector row');

-- GDS9: area_type is recorded on the PRESENCE row, never on the detector.
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'gas_detectors'
                 AND column_name = 'area_type')
  AND EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'gas_detector_presence'
                 AND column_name = 'area_type'),
  'GDS9: area_type classifies the area on the presence row, not the detector');

-- GDS10: only one presence statement per unit, so two sources cannot silently
-- disagree about whether a detector exists there.
SELECT pg_temp.assert(
  EXISTS (SELECT 1 FROM pg_indexes
           WHERE tablename = 'gas_detector_presence' AND indexname = 'gdp_station_unit_uq'),
  'GDS10: presence evidence is unique per station and unit');


-- ---------------------------------------------------------------------------
-- Hose constraints and identity (Prompt 14).
--
-- A hose is an individually traceable item, so these defend IDENTITY as much
-- as hierarchy: what the database will and will not store about a serial.
-- ---------------------------------------------------------------------------

-- HS1: MANDATORY canonical-compatibility check (prompt 14 section 5).
-- station_id is NOT NULL, so a Station-unconfirmed hose cannot be stored.
-- Prompt 6 staged 49 hose rows in that state: a Prompt-21 import blocker.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO hoses (station_id, region_id, mapping_status)
  SELECT NULL, id, 'needs_station_mapping' FROM regions LIMIT 1$q$,
  'HS1: BLOCKER - a station-unconfirmed hose cannot enter the canonical table');

-- HS2: the Unit-mapping model. unit_id IS nullable, so a hose may legitimately
-- belong to a Station with its Unit still unresolved. This is ACCEPTED - it is
-- the normal pending state, not an error.
CREATE TEMP TABLE hs2 AS SELECT id AS station_id, region_id FROM stations ORDER BY id LIMIT 1;
INSERT INTO hoses (station_id, region_id, unit_id, mapping_status, serial_number)
SELECT station_id, region_id, NULL, 'needs_unit_mapping', 'HS-TEST-0001' FROM hs2;
SELECT pg_temp.assert(
  (SELECT count(*) FROM hoses WHERE serial_number = 'HS-TEST-0001' AND unit_id IS NULL) = 1,
  'HS2: a hose may belong to a Station with its Unit unresolved');

-- HS3: but a RESOLVED hose must carry a confirmed Unit. That is what keeps the
-- Prompt-10 Unit tab honest.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO hoses (station_id, region_id, unit_id, mapping_status)
  SELECT station_id, region_id, NULL, 'resolved' FROM hs2$q$,
  'HS3: a resolved hose must carry a confirmed Unit');

-- HS4: and needs_unit_mapping means the Unit really is absent.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO hoses (station_id, region_id, unit_id, mapping_status)
  SELECT u.station_id, u.region_id, u.id, 'needs_unit_mapping' FROM units u LIMIT 1$q$,
  'HS4: needs_unit_mapping means the Unit really is absent');

-- HS5: the hierarchy has a level the other registries do not - a Dispenser -
-- and it cannot be attached before the Unit is known.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO hoses (station_id, region_id, unit_id, dispenser_id, mapping_status)
  SELECT station_id, region_id, NULL, gen_random_uuid(), 'needs_unit_mapping' FROM hs2$q$,
  'HS5: a Dispenser cannot be attached to a hose whose Unit is unknown');

-- HS6: identifiers are TEXT, so a leading zero survives storage verbatim.
INSERT INTO hoses (station_id, region_id, mapping_status, serial_number, serial_number_raw)
SELECT station_id, region_id, 'needs_unit_mapping', '0007412', '0007412' FROM hs2;
SELECT pg_temp.assert(
  (SELECT serial_number FROM hoses WHERE serial_number_raw = '0007412') = '0007412'
  AND (SELECT data_type FROM information_schema.columns
        WHERE table_name = 'hoses' AND column_name = 'serial_number') = 'text',
  'HS6: a hose serial is TEXT and its leading zeros survive exactly');

-- HS7: a missing serial is storable. A hose is never blocked, and never given
-- a generated identifier, because the source recorded none.
INSERT INTO hoses (station_id, region_id, mapping_status, serial_number)
SELECT station_id, region_id, 'needs_unit_mapping', NULL FROM hs2;
SELECT pg_temp.assert(
  (SELECT count(*) FROM hoses WHERE serial_number IS NULL) >= 1,
  'HS7: a hose with no recorded serial is a valid record, not a blocked one');

-- HS8: there is NO UNIQUE constraint on serial_number, and none was added.
-- Uniqueness is operationally desirable but the source does not prove it, and
-- a constraint would reject valid historical rows at the Prompt-21 import.
SELECT pg_temp.assert(
  NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE tablename = 'hoses' AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%serial_number%'),
  'HS8: no UNIQUE constraint on hose serial_number - duplicates are reported, never rejected');

-- HS9: so duplicates are genuinely storable, and both rows are kept.
INSERT INTO hoses (station_id, region_id, mapping_status, serial_number)
SELECT station_id, region_id, 'needs_unit_mapping', 'HS-DUP-77' FROM hs2;
INSERT INTO hoses (station_id, region_id, mapping_status, serial_number)
SELECT station_id, region_id, 'needs_unit_mapping', 'HS-DUP-77' FROM hs2;
SELECT pg_temp.assert(
  (SELECT count(*) FROM hoses WHERE serial_number = 'HS-DUP-77') = 2,
  'HS9: two hoses may carry the same serial and both are retained');

-- HS10: and the registry view REPORTS that condition.
SELECT pg_temp.assert(
  (SELECT count(*) FROM v_hose_registry WHERE serial_number = 'HS-DUP-77' AND serial_duplicate) = 2
  AND (SELECT serial_duplicate FROM v_hose_registry WHERE serial_number = 'HS-TEST-0001') = false,
  'HS10: v_hose_registry flags a duplicated serial and leaves a unique one unflagged');

-- HS11: several NULL serials are several UNKNOWNS, not one repeated value.
-- Conflating them would invent a duplicate the evidence does not support
-- (principle #16).
INSERT INTO hoses (station_id, region_id, mapping_status, serial_number)
SELECT station_id, region_id, 'needs_unit_mapping', NULL FROM hs2;
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM v_hose_registry WHERE serial_number IS NULL AND serial_duplicate),
  'HS11: NULL serials are never duplicates of one another');

-- HS12: missing and duplicate are separate reported conditions.
SELECT pg_temp.assert(
  (SELECT count(*) FROM v_hose_registry WHERE serial_missing AND serial_duplicate) = 0
  AND (SELECT count(*) FROM v_hose_registry WHERE serial_missing) >= 2,
  'HS12: serial_missing and serial_duplicate are distinct and never both true');

-- HS13: a date and its precision cannot disagree, so a year-only next test can
-- never leak into an exact countdown.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO hoses (station_id, region_id, mapping_status, next_test_date, next_test_precision)
  SELECT station_id, region_id, 'needs_unit_mapping', DATE '2027-01-01', 'year_only' FROM hs2$q$,
  'HS13: a year_only next test cannot carry an exact date');

SELECT pg_temp.assert_rejected($q$
  INSERT INTO hoses (station_id, region_id, mapping_status, last_test_date, last_test_precision)
  SELECT station_id, region_id, 'needs_unit_mapping', NULL, 'exact_date' FROM hs2$q$,
  'HS14: an exact_date last-test precision cannot stand without a date');

-- HS15: only an exact date drives a countdown; a year-only one yields none.
INSERT INTO hoses (station_id, region_id, mapping_status, serial_number, next_test_raw, next_test_precision)
SELECT station_id, region_id, 'needs_unit_mapping', 'HS-YEAR-1', '2027', 'year_only' FROM hs2;
SELECT pg_temp.assert(
  (SELECT days_left IS NULL AND due_status = 'unknown'
     FROM v_hose_registry WHERE serial_number = 'HS-YEAR-1'),
  'HS15: a year-only next test yields no countdown and never reads as within date');

-- HS16: a hose cannot be filed under a region its station does not belong to.
SELECT pg_temp.assert_rejected($q$
  INSERT INTO hoses (station_id, region_id, mapping_status)
  SELECT s.id, r.id, 'needs_unit_mapping'
    FROM stations s, regions r WHERE r.id <> s.region_id LIMIT 1$q$,
  'HS16: a hose cannot be filed under a foreign region');

-- HS17: the schema says TEST, not calibration. The UI wording follows it.
SELECT pg_temp.assert(
  EXISTS (SELECT 1 FROM information_schema.columns
           WHERE table_name = 'hoses' AND column_name = 'next_test_date')
  AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'hoses' AND column_name ILIKE '%calibration%'),
  'HS17: hoses carry test dates, not calibration dates');

-- HS18: no manufacturer or model column exists, so neither may be displayed.
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'hoses' AND column_name IN ('manufacturer', 'model')),
  'HS18: hoses carry a free-text description, not manufacturer and model');

-- HS19: no hydrostatic-specific column exists anywhere. The alert vocabulary
-- calls the subject hose_hydrotest, but no table names it, so the UI does not
-- claim the source said "hydrostatic".
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public' AND column_name ILIKE '%hydro%'),
  'HS19: no hydrostatic-named column exists; the schema wording is "test"');

-- HS20: there is no authoritative test INTERVAL anywhere, so none may be
-- hard-coded in the UI. alert_rules carries thresholds only.
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND (column_name ILIKE '%interval%' OR column_name ILIKE '%frequency%'
                      OR column_name ILIKE '%period%' OR column_name ILIKE '%months%')),
  'HS20: no authoritative test interval is represented anywhere in the schema');


-- ---------------------------------------------------------------------------
-- Alert engine (Prompt 15).
--
-- These prove the three properties the whole feature rests on: only an exact
-- date can raise an alert, generation is idempotent, and a new due-date cycle
-- is a new event rather than a rewrite of an old one.
-- ---------------------------------------------------------------------------

-- AL1: the rule set is exactly 5 subjects x 6 thresholds, all enabled.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alert_rules) = 30
  AND (SELECT count(DISTINCT subject) FROM alert_rules) = 5
  AND (SELECT count(DISTINCT threshold) FROM alert_rules) = 6
  AND (SELECT count(*) FROM alert_rules WHERE is_enabled) = 30,
  'AL1: 30 alert rules = 5 subjects x 6 thresholds, all enabled');

-- AL2: countdown rules carry their day count; due_today and overdue do not.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alert_rules WHERE threshold = 'due_60'  AND days_before = 60) = 5
  AND (SELECT count(*) FROM alert_rules WHERE threshold = 'due_30' AND days_before = 30) = 5
  AND (SELECT count(*) FROM alert_rules WHERE threshold = 'due_15' AND days_before = 15) = 5
  AND (SELECT count(*) FROM alert_rules WHERE threshold = 'due_7'  AND days_before = 7) = 5
  AND (SELECT count(*) FROM alert_rules WHERE threshold IN ('due_today','overdue') AND days_before IS NULL) = 10,
  'AL2: threshold day counts are stored once in the database, not duplicated in React');

-- AL3: dedupe identity is DATABASE-enforced, not a read-then-write in code.
SELECT pg_temp.assert(
  EXISTS (SELECT 1 FROM pg_constraint
           WHERE conrelid = 'alerts'::regclass AND conname = 'alerts_dedupe_uq' AND contype = 'u'),
  'AL3: alert dedupe is a unique constraint on (asset_type, asset_id, threshold, due_date)');

-- Fixtures for generation.
CREATE TEMP TABLE algen AS SELECT id AS station_id, region_id FROM stations ORDER BY id LIMIT 1;

-- Exactly 30 days out, exact precision -> eligible.
INSERT INTO gas_detectors (id, station_id, region_id, mapping_status, serial_number,
                           next_calibration_raw, next_calibration_date, next_calibration_precision)
SELECT 'b0000000-0000-0000-0000-00000000001a', station_id, region_id, 'needs_unit_mapping', 'AL-GD-30',
       'x', cng_business_date() + 30, 'exact_date' FROM algen;
-- Year-only -> NEVER eligible.
INSERT INTO gas_detectors (id, station_id, region_id, mapping_status, serial_number,
                           next_calibration_raw, next_calibration_precision)
SELECT 'b0000000-0000-0000-0000-00000000001b', station_id, region_id, 'needs_unit_mapping', 'AL-GD-YEAR',
       '2027', 'year_only' FROM algen;
-- Unknown -> NEVER eligible.
INSERT INTO gas_detectors (id, station_id, region_id, mapping_status, serial_number, next_calibration_precision)
SELECT 'b0000000-0000-0000-0000-00000000001c', station_id, region_id, 'needs_unit_mapping', 'AL-GD-UNK',
       'unknown' FROM algen;
-- Already 45 days overdue -> only `overdue`, never a backfill of passed thresholds.
INSERT INTO hoses (id, station_id, region_id, mapping_status, serial_number,
                   next_test_raw, next_test_date, next_test_precision)
SELECT 'b0000000-0000-0000-0000-00000000001d', station_id, region_id, 'needs_unit_mapping', 'AL-HS-OD',
       'x', cng_business_date() - 45, 'exact_date' FROM algen;

-- AL4: run one creates exactly the expected alerts.
CREATE TEMP TABLE algen_run1 AS SELECT * FROM cng_generate_alerts();
SELECT pg_temp.assert(
  (SELECT created FROM algen_run1) = 2,
  'AL4: generation raised exactly two alerts (one 30-day, one overdue)');

SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts WHERE asset_id = 'b0000000-0000-0000-0000-00000000001a'
     AND threshold = 'due_30') = 1,
  'AL5: an asset exactly 30 days out raises the 30-day alert');

-- AL6: the 45-day-overdue asset raises ONLY overdue. This is the rule that
-- stops a first run from back-filling every threshold the asset passed.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts WHERE asset_id = 'b0000000-0000-0000-0000-00000000001d') = 1
  AND (SELECT threshold FROM alerts WHERE asset_id = 'b0000000-0000-0000-0000-00000000001d') = 'overdue',
  'AL6: an already-overdue asset raises only `overdue`, never the thresholds it passed');

-- AL7: a year-only date can never raise an alert.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts WHERE asset_id = 'b0000000-0000-0000-0000-00000000001b') = 0,
  'AL7: a year-only due date raises no alert and is never turned into an exact day');

-- AL8: nor an unknown one.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts WHERE asset_id = 'b0000000-0000-0000-0000-00000000001c') = 0,
  'AL8: an unknown due date raises no alert');

-- AL9/AL10: IDEMPOTENCY. Re-running changes nothing.
CREATE TEMP TABLE algen_run2 AS SELECT * FROM cng_generate_alerts();
CREATE TEMP TABLE algen_run3 AS SELECT * FROM cng_generate_alerts();
SELECT pg_temp.assert(
  (SELECT created FROM algen_run2) = 0 AND (SELECT created FROM algen_run3) = 0,
  'AL9: repeated generation runs create zero additional alerts');
-- Scoped to THIS block's fixtures: earlier scenarios in this suite create
-- their own assets, some of which are legitimately alertable.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts
    WHERE asset_id IN ('b0000000-0000-0000-0000-00000000001a',
                       'b0000000-0000-0000-0000-00000000001d')) = 2,
  'AL10: three runs leave exactly the two original alerts for these assets');

-- AL11: overdue does not accumulate day after day. The dedupe key includes the
-- due date, so one overdue alert exists per CYCLE, not per run.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts
    WHERE asset_id = 'b0000000-0000-0000-0000-00000000001d' AND threshold = 'overdue') = 1,
  'AL11: repeated runs against an overdue asset keep exactly one overdue alert');

-- AL12/AL13: a NEW due-date cycle is a new event, and the old one survives.
UPDATE gas_detectors SET next_calibration_date = cng_business_date() + 395
 WHERE id = 'b0000000-0000-0000-0000-00000000001a';
SELECT created FROM cng_generate_alerts((cng_business_date() + 365)::date) \gset gen_
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts WHERE asset_id = 'b0000000-0000-0000-0000-00000000001a') = 2
  AND (SELECT count(DISTINCT due_date) FROM alerts
        WHERE asset_id = 'b0000000-0000-0000-0000-00000000001a') = 2,
  'AL12: a new due-date cycle raises its own alert');
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts
    WHERE asset_id = 'b0000000-0000-0000-0000-00000000001a'
      AND due_date = (SELECT (cng_business_date() + 30))) = 1,
  'AL13: the historical alert keeps its original due date, unrewritten');

-- AL14: an alert always carries an exact due date. There is no path by which a
-- year-only value reaches the table.
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM alerts WHERE due_date IS NULL),
  'AL14: every alert carries a concrete due date');

-- AL15: an UNRESOLVED-STATION SRV is still alertable. Migration 0015 made
-- alerts.station_id nullable deliberately: an exact due date is enough to track
-- a calibration, and no Station is fabricated to enable the alert. The alert
-- instead carries the RAW source station name, so it names a place without
-- asserting a canonical one.
INSERT INTO installed_relief_valves (id, region_id, station_id, mapping_status,
                                     source_station_name_raw, location_raw, expected_parent_kind,
                                     next_calibration_raw, next_calibration_date, next_calibration_precision)
SELECT 'b0000000-0000-0000-0000-00000000002a', region_id, NULL, 'needs_station_mapping',
       'AL-RAW-STATION', 'Stage', 'compressor', 'x', cng_business_date() + 15, 'exact_date' FROM algen;
SELECT created FROM cng_generate_alerts() \gset gen15_
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts
    WHERE asset_id = 'b0000000-0000-0000-0000-00000000002a'
      AND station_id IS NULL
      AND needs_station_mapping
      AND source_station_name_raw = 'AL-RAW-STATION') = 1,
  'AL15: a station-unconfirmed SRV still raises an alert, carrying raw source context and no invented Station');

-- AL15b: and it surfaces through the inbox view rather than being dropped by a
-- join that assumes a Station row exists.
SELECT pg_temp.assert(
  (SELECT count(*) FROM v_alert_inbox
    WHERE asset_id = 'b0000000-0000-0000-0000-00000000002a') = 1,
  'AL15b: the inbox view LEFT JOINs stations, so an unresolved-station alert is not silently lost');

-- AL15c: vessels, detectors and hoses cannot reach that state at all, because
-- station_id is NOT NULL on each (the Prompt-21 blockers).
SELECT pg_temp.assert(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
      AND column_name = 'station_id' AND is_nullable = 'YES') = 0,
  'AL15c: only SRVs can be station-unconfirmed; the other asset types cannot hold that state');

-- AL16: acknowledgement columns move together or not at all.
SELECT pg_temp.assert_rejected($q$
  UPDATE alerts SET acknowledged_at = now() WHERE acknowledged_at IS NULL$q$,
  'AL16: an acknowledgement timestamp cannot exist without an actor');

-- AL17: delivery is a SEPARATE record. Deleting every delivery leaves the
-- alerts untouched - a failed or missing send never removes an alert.
DELETE FROM notification_deliveries;
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts
    WHERE asset_id IN ('b0000000-0000-0000-0000-00000000001a',
                       'b0000000-0000-0000-0000-00000000001d')) = 3,
  'AL17: alerts persist independently of any delivery record');

-- AL18: a delivery cannot exist without its alert.
SELECT pg_temp.assert(
  EXISTS (SELECT 1 FROM pg_constraint
           WHERE conrelid = 'notification_deliveries'::regclass AND contype = 'f'
             AND confrelid = 'alerts'::regclass),
  'AL18: a delivery record is anchored to a real alert by foreign key');

-- AL19: one delivery per (alert, user, channel) - a retry updates, never duplicates.
SELECT pg_temp.assert(
  EXISTS (SELECT 1 FROM pg_constraint
           WHERE conrelid = 'notification_deliveries'::regclass AND conname = 'notif_delivery_uq'),
  'AL19: delivery is unique per alert, user and channel, so a retry cannot duplicate a send');

-- AL20: read state is PER-USER, keyed by both the alert and the user.
SELECT pg_temp.assert(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_name = 'alert_reads' AND column_name IN ('alert_id','app_user_id')) = 2
  AND EXISTS (SELECT 1 FROM pg_constraint
               WHERE conrelid = 'alert_reads'::regclass AND contype = 'p'),
  'AL20: read state is per-user, so one reader does not mark an alert read for everyone');

-- AL21: Africa/Cairo, proven across BOTH DST offsets at fixed instants, so the
-- result cannot depend on when or where the suite runs.
SELECT pg_temp.assert(
  (TIMESTAMPTZ '2026-06-15 22:30:00+00' AT TIME ZONE 'Africa/Cairo')::date = DATE '2026-06-16'
  AND (TIMESTAMPTZ '2026-06-15 22:30:00+00' AT TIME ZONE 'UTC')::date = DATE '2026-06-15'
  AND (TIMESTAMPTZ '2026-01-15 22:30:00+00' AT TIME ZONE 'Africa/Cairo')::date = DATE '2026-01-16'
  AND (TIMESTAMPTZ '2026-01-15 22:30:00+00' AT TIME ZONE 'UTC')::date = DATE '2026-01-15',
  'AL21: the Cairo calendar date is a day ahead of UTC late in the evening, in both summer and winter');

-- AL22: and cng_business_date() is Cairo regardless of the host timezone.
SET LOCAL TIME ZONE 'America/New_York';
SELECT pg_temp.assert(
  cng_business_date() = (now() AT TIME ZONE 'Africa/Cairo')::date,
  'AL22: cng_business_date() follows Africa/Cairo, not the session timezone');
SET LOCAL TIME ZONE 'UTC';

-- AL23: generation is not exposed to signed-in users. It is a scheduled server
-- task, and letting a browser drive it would be an abuse vector.
SELECT pg_temp.assert(
  NOT has_function_privilege('authenticated', 'cng_generate_alerts(date)', 'EXECUTE')
  AND has_function_privilege('service_role', 'cng_generate_alerts(date)', 'EXECUTE'),
  'AL23: only service_role may run alert generation; authenticated cannot');

-- AL24: acknowledgement is reachable by users, and only through the function.
SELECT pg_temp.assert(
  has_function_privilege('authenticated', 'cng_acknowledge_alert(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_acknowledge_alert(uuid)', 'EXECUTE'),
  'AL24: acknowledgement is granted to authenticated and denied to anon');

-- AL25: the definer functions pin their search_path.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('cng_generate_alerts','cng_acknowledge_alert')
      AND prosecdef
      AND array_to_string(proconfig, ',') LIKE '%search_path%') = 2,
  'AL25: both SECURITY DEFINER alert functions pin search_path');


-- ---------------------------------------------------------------------------
-- Notification delivery (Prompt 15.1).
--
-- The property under test is the SEPARATION: delivery consumes an alert and can
-- never change one. Every assertion here is about what delivery cannot do.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE deliv AS SELECT id AS station_id, region_id FROM stations ORDER BY id LIMIT 1;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name, email) VALUES
  ('d1000000-0000-0000-0000-00000000000a','deliv_admin','admin',   true,'Deliv Admin','admin@testdata.invalid'),
  ('d1000000-0000-0000-0000-00000000000b','deliv_quiet','admin',   true,'Deliv Quiet','quiet@testdata.invalid'),
  ('d1000000-0000-0000-0000-00000000000c','deliv_none', 'admin',   true,'Deliv NoPref','nopref@testdata.invalid');

INSERT INTO alerts (id, alert_rule_id, subject, threshold, asset_type, asset_id,
                    region_id, station_id, due_date, days_left)
SELECT 'd1000000-0000-0000-0000-0000000000a1',
       (SELECT id FROM alert_rules WHERE subject='srv_calibration' AND threshold='due_30'),
       'srv_calibration','due_30','installed_relief_valve', gen_random_uuid(),
       region_id, station_id, DATE '2026-10-16', 30 FROM deliv;

-- DL1: with NO preferences at all, nothing is enqueued. Authorization to read
-- an alert is not consent to be emailed about it, and nobody is auto-subscribed.
SELECT pg_temp.assert(
  (SELECT enqueued FROM cng_enqueue_alert_deliveries('email')) = 0,
  'DL1: no opted-in recipients means no delivery is created - nobody is silently subscribed');

-- DL2: an explicit opt-in produces a delivery for THIS alert.
--
-- Scoped to this block's alert throughout: earlier scenarios in this suite
-- generate alerts of their own, so the enqueue's overall return value is not a
-- stable number to assert on.
INSERT INTO notification_preferences (app_user_id, subject, channel, is_enabled)
VALUES ('d1000000-0000-0000-0000-00000000000a', NULL, 'email', true);
SELECT enqueued FROM cng_enqueue_alert_deliveries('email') \gset dl2_
SELECT pg_temp.assert(
  (SELECT count(*) FROM notification_deliveries
    WHERE alert_id = 'd1000000-0000-0000-0000-0000000000a1'
      AND app_user_id = 'd1000000-0000-0000-0000-00000000000a') = 1,
  'DL2: an explicitly opted-in user receives a delivery row');

-- DL3: and re-running enqueues nothing more. The unique constraint, not a
-- read-then-write, is what guarantees it.
SELECT enqueued FROM cng_enqueue_alert_deliveries('email') \gset dl3_
SELECT pg_temp.assert(
  (SELECT count(*) FROM notification_deliveries
    WHERE alert_id = 'd1000000-0000-0000-0000-0000000000a1') = 1,
  'DL3: re-running the enqueue creates no duplicate delivery');

-- DL4: min_threshold quietens a user below their chosen urgency. A due_30
-- alert must not reach someone who asked for due_7 and more urgent only.
INSERT INTO notification_preferences (app_user_id, subject, channel, is_enabled, min_threshold)
VALUES ('d1000000-0000-0000-0000-00000000000b', NULL, 'email', true, 'due_7');
SELECT enqueued FROM cng_enqueue_alert_deliveries('email') \gset dl4_
SELECT pg_temp.assert(
  (SELECT count(*) FROM notification_deliveries
    WHERE alert_id = 'd1000000-0000-0000-0000-0000000000a1'
      AND app_user_id = 'd1000000-0000-0000-0000-00000000000b') = 0,
  'DL4: a user whose urgency floor is higher than the alert receives nothing');

-- DL5: a DISABLED preference is not an opt-in.
INSERT INTO notification_preferences (app_user_id, subject, channel, is_enabled)
VALUES ('d1000000-0000-0000-0000-00000000000c', NULL, 'email', false);
SELECT enqueued FROM cng_enqueue_alert_deliveries('email') \gset dl5_
SELECT pg_temp.assert(
  (SELECT count(*) FROM notification_deliveries
    WHERE app_user_id = 'd1000000-0000-0000-0000-00000000000c') = 0,
  'DL5: a disabled preference never produces a delivery');

-- DL6: the claim function returns the work with the recipient resolved
-- server-side. The address comes from app_users, never from a caller.
SELECT pg_temp.assert(
  (SELECT count(*) FROM cng_next_pending_deliveries('email', 50)
    WHERE recipient = 'admin@testdata.invalid'
      AND alert_id = 'd1000000-0000-0000-0000-0000000000a1') = 1,
  'DL6: the sender is handed a recipient resolved from the database');

-- DL7: recording a FAILURE leaves the alert completely untouched.
CREATE TEMP TABLE dl_before AS
  SELECT state, acknowledged_by, acknowledged_at, due_date, threshold
    FROM alerts WHERE id = 'd1000000-0000-0000-0000-0000000000a1';
SELECT cng_record_delivery_result(
  (SELECT id FROM notification_deliveries WHERE alert_id='d1000000-0000-0000-0000-0000000000a1'),
  'failed', NULL, 'resend:http_403:sender_or_recipient_not_permitted');
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts a JOIN dl_before b
     ON a.state = b.state AND a.due_date = b.due_date AND a.threshold = b.threshold
      AND a.acknowledged_by IS NOT DISTINCT FROM b.acknowledged_by
      AND a.acknowledged_at IS NOT DISTINCT FROM b.acknowledged_at
    WHERE a.id = 'd1000000-0000-0000-0000-0000000000a1') = 1,
  'DL7: a failed delivery leaves the alert unchanged - not deleted, not acknowledged');

-- DL8: and creates no second alert.
SELECT pg_temp.assert(
  (SELECT count(*) FROM alerts WHERE id = 'd1000000-0000-0000-0000-0000000000a1') = 1
  AND (SELECT count(*) FROM alerts
        WHERE asset_id = (SELECT asset_id FROM alerts WHERE id='d1000000-0000-0000-0000-0000000000a1')) = 1,
  'DL8: a delivery failure never generates a duplicate alert');

-- DL9: a failed delivery stays claimable, so a retry targets the SAME alert.
SELECT pg_temp.assert(
  (SELECT count(*) FROM cng_next_pending_deliveries('email', 50)
    WHERE alert_id = 'd1000000-0000-0000-0000-0000000000a1') = 1,
  'DL9: a failed delivery is retryable, and the retry is bound to the same alert');

-- DL10: retries are BOUNDED. After the cap the row stops being claimed, so a
-- permanently bad address cannot be retried forever.
UPDATE notification_deliveries SET attempt_count = 5
 WHERE alert_id = 'd1000000-0000-0000-0000-0000000000a1';
SELECT pg_temp.assert(
  (SELECT count(*) FROM cng_next_pending_deliveries('email', 50)
    WHERE alert_id = 'd1000000-0000-0000-0000-0000000000a1') = 0,
  'DL10: retry is capped, so a permanently failing recipient stops costing sends');

-- DL11: a successful send stamps delivered_at and still changes no alert.
UPDATE notification_deliveries SET attempt_count = 0
 WHERE alert_id = 'd1000000-0000-0000-0000-0000000000a1';
SELECT cng_record_delivery_result(
  (SELECT id FROM notification_deliveries WHERE alert_id='d1000000-0000-0000-0000-0000000000a1'),
  'sent', 'resend-msg-123', NULL);
SELECT pg_temp.assert(
  (SELECT status = 'sent' AND delivered_at IS NOT NULL AND provider_message_id = 'resend-msg-123'
     FROM notification_deliveries WHERE alert_id='d1000000-0000-0000-0000-0000000000a1')
  AND (SELECT state FROM alerts WHERE id='d1000000-0000-0000-0000-0000000000a1') = 'open',
  'DL11: a successful send records the outcome and still leaves the alert open');

-- DL12: provider error text is truncated, so a large provider body cannot be
-- parked in an operational record.
SELECT cng_record_delivery_result(
  (SELECT id FROM notification_deliveries WHERE alert_id='d1000000-0000-0000-0000-0000000000a1'),
  'failed', NULL, repeat('x', 2000));
SELECT pg_temp.assert(
  (SELECT length(error_detail) FROM notification_deliveries
    WHERE alert_id='d1000000-0000-0000-0000-0000000000a1') = 500,
  'DL12: stored provider error text is bounded');

-- DL13: delivery functions are server-only. A browser that could drive sending
-- would be an open mail relay.
SELECT pg_temp.assert(
  has_function_privilege('service_role','cng_enqueue_alert_deliveries(notification_channel)','EXECUTE')
  AND NOT has_function_privilege('authenticated','cng_enqueue_alert_deliveries(notification_channel)','EXECUTE')
  AND NOT has_function_privilege('authenticated','cng_next_pending_deliveries(notification_channel,integer)','EXECUTE')
  AND NOT has_function_privilege('authenticated','cng_record_delivery_result(uuid,delivery_status,text,text)','EXECUTE'),
  'DL13: only service_role may enqueue, claim or complete a delivery');

SELECT pg_temp.assert(
  NOT has_function_privilege('anon','cng_enqueue_alert_deliveries(notification_channel)','EXECUTE')
  AND NOT has_function_privilege('anon','cng_next_pending_deliveries(notification_channel,integer)','EXECUTE'),
  'DL14: anon may not reach any delivery function');

-- DL15: the push subscription function IS reachable by users, and by nobody else.
SELECT pg_temp.assert(
  has_function_privilege('authenticated','cng_save_push_subscription(text,text,text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','cng_save_push_subscription(text,text,text,text)','EXECUTE'),
  'DL15: saving a push subscription is granted to authenticated only');

-- DL16: it takes NO user parameter, so a caller cannot name another user.
SELECT pg_temp.assert(
  (SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname='cng_save_push_subscription')
    NOT ILIKE '%user%id%',
  'DL16: cng_save_push_subscription accepts no user identifier - the owner comes from the session');

-- DL17: the delivery functions pin search_path, as every definer function must.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('cng_enqueue_alert_deliveries','cng_next_pending_deliveries','cng_record_delivery_result')
      AND prosecdef AND array_to_string(proconfig, ',') LIKE '%search_path%') = 3,
  'DL17: every SECURITY DEFINER delivery function pins search_path');


-- ===========================================================================
-- STAGING COMMIT (Prompt 20F, migration 0044)
--
-- The canonical firewall is asserted from the CATALOG, not from the migration's
-- comment: `prosrc` is read back and checked for any canonical table name and
-- for dynamic SQL. A later edit that reached for `stations` or introduced an
-- EXECUTE would fail here rather than in production.
-- ===========================================================================

-- STG-1: the writer exists, is SECURITY DEFINER and pins search_path.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc
    WHERE proname = 'cng_stage_import_batch'
      AND prosecdef
      AND array_to_string(proconfig, ',') LIKE '%search_path%') = 1,
  'STG-1: cng_stage_import_batch is SECURITY DEFINER with a pinned search_path');

-- STG-2: it contains NO dynamic SQL, so the caller cannot name a destination.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_import_batch')
    NOT ILIKE '%EXECUTE %'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_import_batch')
    NOT ILIKE '%format(%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_import_batch')
    NOT ILIKE '%quote_ident%',
  'STG-2: the staging writer contains no dynamic SQL - target_table is data, never an identifier');

-- STG-3: THE FIREWALL. Its body names no canonical table.
SELECT pg_temp.assert(
  NOT EXISTS (
    SELECT 1 FROM unnest(ARRAY[
      'stations','units','regions','storage_vessels','recovery_tanks',
      'gas_detectors','hoses','installed_relief_valves','warehouse_relief_valves',
      'compressors','dispensers','import_mapping_decisions'
    ]) AS canonical(t)
    WHERE (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_import_batch')
          ~* ('(insert|update|delete)[[:space:]]+(into[[:space:]]+)?' || canonical.t || '\M')
  ),
  'STG-3: the staging writer writes NO canonical table and NO mapping decision');

-- STG-4: replay identity is a DATABASE property, and it is partial so a failed
-- run never blocks a corrected retry of the same sources.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_indexes
    WHERE tablename = 'import_runs'
      AND indexname = 'import_runs_manifest_fingerprint_uq'
      AND indexdef ILIKE '%UNIQUE%'
      AND indexdef ILIKE '%completed_at IS NOT NULL%') = 1,
  'STG-4: one completed staging run per distinct source content, enforced by a partial unique index');

-- STG-5: abandonment is a STATE change, never a delete.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_abandon_import_run')
    NOT ILIKE '%DELETE FROM%',
  'STG-5: abandoning a staging run never deletes a row');

-- STG-6: and it is batch-scoped - it refuses a NULL run id rather than acting broadly.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_abandon_import_run')
    ILIKE '%p_import_run_id IS NULL%',
  'STG-6: abandoning requires an explicit run id');



-- ===========================================================================
-- SEPARATOR NORMALIZATION (Prompt 21B, migration 0045)
--
-- The owner approved ONE rule: whitespace around the literal "/" separator is
-- collapsed for COMPARISON. These assert that it does exactly that and nothing
-- adjacent — a later edit that broadened it into generic punctuation folding
-- would start merging Stations the source distinguishes, and would fail here.
-- ===========================================================================

-- SEP-1: the four approved spellings share one comparison form.
SELECT pg_temp.assert(
  cng_normalize_name('A / B') = cng_normalize_name('A/B')
  AND cng_normalize_name('A/ B') = cng_normalize_name('A/B')
  AND cng_normalize_name('A /B') = cng_normalize_name('A/B'),
  'SEP-1: "A / B", "A/ B", "A /B" and "A/B" all compare equal');

-- SEP-2: and that form is the slash-tight one, not some third spelling.
SELECT pg_temp.assert(
  cng_normalize_name('A / B') = 'a/b',
  'SEP-2: the comparison form is "a/b"');

-- SEP-3: the REAL pair from the production sources now compares equal. This is
-- the entire point of the change; if it ever stops holding, 281 asset rows
-- silently lose their Station candidate again.
SELECT pg_temp.assert(
  cng_normalize_name('أتــريب / بنــها 1') = cng_normalize_name('أتريب/بنها 1'),
  'SEP-3: the structural and asset spellings of a real compound Station name compare equal');

-- SEP-4..7: every pre-existing behaviour is preserved, exactly as 0028 left it.
SELECT pg_temp.assert(cng_normalize_name('الماظة') = 'الماظه',
  'SEP-4: taa marbuta still folds to haa');
SELECT pg_temp.assert(cng_normalize_name('آمال') = 'امال',
  'SEP-5: alef madda still folds to alef');
SELECT pg_temp.assert(cng_normalize_name('إبراهيم') = 'ابراهيم',
  'SEP-6: hamza-under-alef still folds to alef');
SELECT pg_temp.assert(cng_normalize_name('طاليــا') = 'طاليا',
  'SEP-7: tatweel is still removed, not replaced');

-- SEP-8: NOT generic punctuation normalization. A hyphen keeps its spacing, so
-- names the source distinguishes stay distinguished.
SELECT pg_temp.assert(
  cng_normalize_name('ابو تيج - اسيوط') <> cng_normalize_name('ابو تيج-اسيوط'),
  'SEP-8: whitespace around a HYPHEN is NOT collapsed - only "/" was approved');

-- SEP-9: the owner-confirmed alias is not extended by normalization. These two
-- remain different names; their equivalence is an explicit owner ruling stored
-- as a row, never something the normalizer decides.
SELECT pg_temp.assert(
  cng_normalize_name('ابنوب') <> cng_normalize_name('ابنوب اسيوط'),
  'SEP-9: the owner alias is NOT reproduced by normalization');

-- SEP-10: general whitespace collapsing still works, and leading/trailing space
-- is still trimmed.
SELECT pg_temp.assert(
  cng_normalize_name('  الف    باء  ') = 'الف باء',
  'SEP-10: runs of whitespace still collapse and the result is trimmed');

-- SEP-11: NULL and empty still yield NULL rather than an empty-string identity.
SELECT pg_temp.assert(
  cng_normalize_name(NULL) IS NULL AND cng_normalize_name('   ') IS NULL,
  'SEP-11: NULL and blank normalize to NULL, never to an empty identity');

-- SEP-12: STILL IMMUTABLE. A stored generated column requires it, and losing
-- immutability would break `stations.normalized_name` rather than any test.
SELECT pg_temp.assert(
  (SELECT provolatile FROM pg_proc WHERE proname = 'cng_normalize_name') = 'i',
  'SEP-12: cng_normalize_name is still IMMUTABLE, as the generated column requires');

-- SEP-13: REGION REMAINS PART OF IDENTITY. Two Stations whose names now share a
-- comparison form are still distinct records in different Regions - the unique
-- constraint is Region-scoped, so normalization can never merge across Regions.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_constraint
    WHERE conname = 'stations_region_norm_uq'
      AND pg_get_constraintdef(oid) ILIKE '%region_id%normalized_name%') = 1,
  'SEP-13: Station identity is UNIQUE (region_id, normalized_name) - Region is still part of it');

-- SEP-14: the same holds for Units, scoped to their Station.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_constraint
    WHERE conname = 'units_station_norm_uq'
      AND pg_get_constraintdef(oid) ILIKE '%station_id%normalized_name%') = 1,
  'SEP-14: Unit identity is UNIQUE (station_id, normalized_name)');



-- ===========================================================================
-- STAGE A: the canonical hierarchy pipeline (Prompt 21C, migration 0046)
-- ===========================================================================
-- These are destructive tests. Each one tries to make the pipeline do something
-- it must never do, and requires the database to refuse. The whole block runs
-- inside this script's transaction and rolls back.

CREATE TEMP TABLE sa AS SELECT
  '99999999-0000-0000-0000-00000000000a'::uuid AS run,
  '99999999-0000-0000-0000-00000000000b'::uuid AS batch,
  repeat('a', 64) AS manifest;

INSERT INTO import_runs (id, mode, label, started_at, completed_at, summary)
SELECT run, 'commit', 'stage-a-test', now(), now(),
       jsonb_build_object('manifest_fingerprint', manifest) FROM sa;
INSERT INTO import_batches (id, import_run_id, source_file, source_sheet, file_checksum,
                            header_row, rows_read, rows_flagged, rows_failed, rows_imported)
SELECT batch, run, 'SA.xlsx', 'Sheet1', repeat('b', 64), 1, 0, 0, 0, 0 FROM sa;

-- The fixture deliberately encodes every shape the real source contains.
CREATE OR REPLACE FUNCTION pg_temp.sa_row(
  p_row integer, p_region text, p_station text, p_unit text, p_job text,
  p_hash text DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO import_staging_rows (import_run_id, import_batch_id, source_file, source_sheet,
    source_row, source_raw, source_row_key, source_row_hash, target_table, outcome, normalized)
  SELECT run, batch, 'SA.xlsx', 'Sheet1', p_row, '{}'::jsonb,
         'SA.xlsx::Sheet1::' || p_row,
         coalesce(p_hash, md5(p_row::text) || md5(p_row::text)),
         'stations_units', 'ready',
         jsonb_build_object('region', p_region, 'station_name', p_station,
                            'unit_name', p_unit, 'unit_job_number', p_job)
    FROM sa;
$$;

SELECT pg_temp.sa_row(1, 'East',  'SA ALPHA', 'SA ALPHA 1', 'J1');
SELECT pg_temp.sa_row(2, 'East',  'SA ALPHA', 'SA ALPHA 2', 'J1');  -- job reused
SELECT pg_temp.sa_row(3, 'East',  'SA ALPHA', 'SA ALPHA 1', NULL);  -- repeat identity
SELECT pg_temp.sa_row(4, 'West',  'SA ALPHA', 'SA ALPHA 1', NULL);  -- same name, other Region
SELECT pg_temp.sa_row(5, 'Delta', 'SA LONELY', NULL,        NULL);  -- Station with NO Unit
SELECT pg_temp.sa_row(8, 'Canal', 'محطة الاختبار', 'محطة الاختبار 1', NULL); -- Arabic
SELECT pg_temp.sa_row(9, 'East',  'SA NOJOB', 'SA NOJOB 1', NULL); -- Unit with no job number

CREATE TEMP TABLE sa_fp AS
SELECT pv.preview_fingerprint AS fp, pv.proposed_stations AS st, pv.proposed_units AS un,
       pv.stations_without_unit AS nounit
  FROM sa, cng_stage_a_preview(sa.run) pv;

-- STAGEA-1: the preview is READ-ONLY. Computing a proposal creates nothing.
SELECT pg_temp.assert(
  (SELECT count(*) FROM stations WHERE station_name LIKE 'SA %') = 0
  AND (SELECT count(*) FROM units WHERE unit_name LIKE 'SA %') = 0,
  'STAGEA-1: previewing the hierarchy creates no Station and no Unit');

-- STAGEA-2: the proposal is DETERMINISTIC in identity, not in row count.
-- 7 rows describing 5 Stations (East/SA ALPHA, West/SA ALPHA, Delta/SA LONELY,
-- Canal Arabic, East/SA NOJOB) and 5 Units.
SELECT pg_temp.assert((SELECT st FROM sa_fp) = 5 AND (SELECT un FROM sa_fp) = 5,
  'STAGEA-2: 7 source rows propose 5 Stations and 5 Units - rows are not entities');

-- STAGEA-3: a Station whose rows name no Unit proposes NO Unit (decision D7).
SELECT pg_temp.assert((SELECT nounit FROM sa_fp) = 1,
  'STAGEA-3: the Unit-less Station proposes zero Units - no default Unit is invented');

-- STAGEA-4: a MISSING approval is refused. There is no "approve whatever is current".
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, NULL)', (SELECT run FROM sa), repeat('a',64)),
  'STAGEA-4: commit with no preview fingerprint is refused');

-- STAGEA-5: an EMPTY approval is refused, not treated as "anything".
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', (SELECT run FROM sa), repeat('a',64), '   '),
  'STAGEA-5: commit with a blank preview fingerprint is refused');

-- STAGEA-6: a WRONG proposal fingerprint is refused - this is the drift guard.
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', (SELECT run FROM sa), repeat('a',64), repeat('f',64)),
  'STAGEA-6: commit whose approved proposal does not match the current one is refused');

-- STAGEA-7: a wrong MANIFEST fingerprint is refused - the approval is bound to
-- the source content as well as to the proposal.
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', (SELECT run FROM sa), repeat('9',64), (SELECT fp FROM sa_fp)),
  'STAGEA-7: commit whose approved source content does not match is refused');

-- STAGEA-8: a run that does not exist is refused.
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', gen_random_uuid(), repeat('a',64), (SELECT fp FROM sa_fp)),
  'STAGEA-8: commit against a nonexistent import run is refused');

-- STAGEA-9: an INCOMPLETE run is refused - a half-written staging batch can
-- never be mistaken for an approved one.
INSERT INTO import_runs (id, mode, label, started_at, summary)
VALUES ('99999999-0000-0000-0000-0000000000cc', 'commit', 'sa-incomplete', now(),
        jsonb_build_object('manifest_fingerprint', repeat('c',64)));
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', '99999999-0000-0000-0000-0000000000cc', repeat('c',64), repeat('0',64)),
  'STAGEA-9: commit against an uncompleted staging run is refused');

-- STAGEA-10: NOTHING was written by any of those six refusals.
SELECT pg_temp.assert(
  (SELECT count(*) FROM stations WHERE station_name LIKE 'SA %') = 0
  AND (SELECT count(*) FROM import_staging_rows WHERE import_run_id = (SELECT run FROM sa) AND committed_entity_id IS NOT NULL) = 0,
  'STAGEA-10: every refused commit left zero Stations and zero lineage behind');

-- STAGEA-11: the fingerprint tracks CONTENT. Change a proposed name and the
-- previously approved fingerprint no longer matches.
CREATE TEMP TABLE sa_drift AS
SELECT (SELECT fp FROM sa_fp) AS before,
       (SELECT pv.preview_fingerprint FROM sa, cng_stage_a_preview(sa.run) pv) AS same;
SELECT pg_temp.assert((SELECT before = same FROM sa_drift),
  'STAGEA-11: the same proposal fingerprints identically on every evaluation');

UPDATE import_staging_rows
   SET normalized = jsonb_set(normalized, '{unit_job_number}', '"CHANGED"')
 WHERE import_run_id = (SELECT run FROM sa) AND source_row = 1;
SELECT pg_temp.assert(
  (SELECT pv.preview_fingerprint FROM sa, cng_stage_a_preview(sa.run) pv) <> (SELECT fp FROM sa_fp),
  'STAGEA-12: changing a proposed attribute changes the fingerprint, so the approval lapses');
UPDATE import_staging_rows
   SET normalized = jsonb_set(normalized, '{unit_job_number}', '"J1"')
 WHERE import_run_id = (SELECT run FROM sa) AND source_row = 1;

-- STAGEA-13: the approval is bound to the EVIDENCE, not only to the conclusion.
-- The proposed names are byte-identical here; only the source row hash moved.
UPDATE import_staging_rows SET source_row_hash = repeat('e', 64)
 WHERE import_run_id = (SELECT run FROM sa) AND source_row = 1;
SELECT pg_temp.assert(
  (SELECT pv.preview_fingerprint FROM sa, cng_stage_a_preview(sa.run) pv) <> (SELECT fp FROM sa_fp),
  'STAGEA-13: a changed source_row_hash lapses the approval even when the proposal reads the same');
UPDATE import_staging_rows SET source_row_hash = md5('1') || md5('1')
 WHERE import_run_id = (SELECT run FROM sa) AND source_row = 1;

-- STAGEA-14: an unrecognised Region is REFUSED, never created and never folded
-- into the nearest canonical name.
SELECT pg_temp.sa_row(20, 'Souf', 'SA BADREGION', NULL, NULL);
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', (SELECT run FROM sa), repeat('a',64),
         (SELECT pv.preview_fingerprint FROM sa, cng_stage_a_preview(sa.run) pv)),
  'STAGEA-14: a Region the canonical list does not contain is refused, not guessed');
SELECT pg_temp.assert((SELECT count(*) FROM regions WHERE name = 'Souf') = 0,
  'STAGEA-15: the refused Region was not created as a side effect');
DELETE FROM import_staging_rows WHERE import_run_id = (SELECT run FROM sa) AND source_row = 20;

-- STAGEA-16: two SPELLINGS of one identity are refused, never silently picked.
SELECT pg_temp.sa_row(21, 'East', 'SA  ALPHA', 'SA ALPHA 1', NULL);
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', (SELECT run FROM sa), repeat('a',64),
         (SELECT pv.preview_fingerprint FROM sa, cng_stage_a_preview(sa.run) pv)),
  'STAGEA-16: one identity carrying two source spellings is refused for human reconciliation');
DELETE FROM import_staging_rows WHERE import_run_id = (SELECT run FROM sa) AND source_row = 21;

-- STAGEA-16a: THE "/" RULE IS COMPARISON, NOT A DISPLAY DECISION. Migration
-- 0045 makes "A / B" and "A/B" the same identity, which is exactly why two rows
-- spelling one Station both ways are REFUSED here: the owner approved the
-- equivalence (Prompt 21B) and explicitly did NOT approve changing the canonical
-- name, so choosing which spelling to display is a human decision, not a
-- tie-break. Measured on the real run this never arises - zero identities carry
-- two spellings - and the fold earns its keep at Stage B, where an asset name
-- written "A/B" must match a structural Station written "A / B".
SELECT pg_temp.sa_row(30, 'Delta', 'SA SLASH / B', NULL, NULL);
SELECT pg_temp.sa_row(31, 'Delta', 'SA SLASH/B',   NULL, NULL);
SELECT pg_temp.assert(
  (SELECT count(DISTINCT cng_normalize_name(normalized ->> 'station_name'))
     FROM import_staging_rows WHERE source_row IN (30, 31)) = 1,
  'STAGEA-16a: the two "/" spacings really are ONE identity after 0045');
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', (SELECT run FROM sa), repeat('a',64),
         (SELECT pv.preview_fingerprint FROM sa, cng_stage_a_preview(sa.run) pv)),
  'STAGEA-16b: one identity spelled two ways is refused - the fold never picks a display name');
DELETE FROM import_staging_rows WHERE import_run_id = (SELECT run FROM sa) AND source_row IN (30, 31);

-- ------------------------- the authorized commit ---------------------------
-- This script's earlier scenarios already populated aliases, decisions and
-- assets, so Stage A's effect on them is measured as a DELTA rather than as an
-- absolute count - an absolute assertion here would be tracking the fixture,
-- not the pipeline (the MGR-6 mistake corrected in Prompt 20A).
CREATE TEMP TABLE sa_before AS SELECT
  (SELECT count(*) FROM station_aliases)           AS aliases,
  (SELECT count(*) FROM import_mapping_decisions)  AS decisions,
  (SELECT count(*) FROM installed_relief_valves)   AS isrv,
  (SELECT count(*) FROM warehouse_relief_valves)   AS wsrv,
  (SELECT count(*) FROM hoses)                     AS hoses,
  (SELECT count(*) FROM storage_vessels)           AS vessels,
  (SELECT count(*) FROM recovery_tanks)            AS tanks,
  (SELECT count(*) FROM gas_detectors)             AS detectors,
  (SELECT count(*) FROM compressors)               AS compressors,
  (SELECT count(*) FROM dispensers)                AS dispensers;

SELECT * FROM cng_stage_a_commit((SELECT run FROM sa), repeat('a',64), (SELECT fp FROM sa_fp));

-- STAGEA-17: Region is part of Station identity. The same name in two Regions
-- stays two Stations; it is NEVER matched across Regions.
SELECT pg_temp.assert(
  (SELECT count(*) FROM stations WHERE station_name = 'SA ALPHA') = 2
  AND (SELECT count(DISTINCT region_id) FROM stations WHERE station_name = 'SA ALPHA') = 2,
  'STAGEA-17: one name in two Regions creates two Stations - no cross-Region matching');

-- STAGEA-18: the Unit-less Station exists and has NO Unit.
SELECT pg_temp.assert(
  (SELECT count(*) FROM stations WHERE station_name = 'SA LONELY') = 1
  AND (SELECT count(*) FROM units u JOIN stations s ON s.id = u.station_id WHERE s.station_name = 'SA LONELY') = 0,
  'STAGEA-18: a Station whose source names no Unit is created with zero Units');

-- STAGEA-19: the display name stored is the SOURCE text, never the comparison
-- form. Normalization decides identity; it never decides how a name is written.
SELECT pg_temp.assert(
  (SELECT station_name FROM stations WHERE normalized_name = 'sa alpha' LIMIT 1) = 'SA ALPHA',
  'STAGEA-19: the canonical display name is the source spelling, not the normalized key');

-- STAGEA-20: a job number reused across two Units does NOT merge them.
SELECT pg_temp.assert(
  (SELECT count(*) FROM units WHERE job_number = 'J1') = 2,
  'STAGEA-20: a job number shared by two Units leaves them two Units - it is not identity');

-- STAGEA-21: a Unit with no job number is still created, with job_number NULL.
SELECT pg_temp.assert(
  (SELECT count(*) FROM units WHERE unit_name = 'SA NOJOB 1' AND job_number IS NULL) = 1,
  'STAGEA-21: a missing job number does not block Unit creation and is stored as NULL');

-- STAGEA-22: Arabic survives byte-for-byte into the canonical name.
SELECT pg_temp.assert(
  (SELECT count(*) FROM stations WHERE station_name = 'محطة الاختبار') = 1,
  'STAGEA-22: an Arabic Station name is stored exactly as the source holds it');

-- STAGEA-23: every Unit's Region equals its Station's Region.
SELECT pg_temp.assert(
  (SELECT count(*) FROM units u JOIN stations s ON s.id = u.station_id WHERE u.region_id <> s.region_id) = 0,
  'STAGEA-23: no Unit was created in a Region other than its Station''s');

-- STAGEA-24: LINEAGE in both directions, without a false one-row-one-entity model.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_staging_rows WHERE import_run_id = (SELECT run FROM sa) AND committed_entity_id IS NULL) = 0
  AND (SELECT count(*) FROM import_staging_rows WHERE import_run_id = (SELECT run FROM sa) AND committed_entity_kind = 'station') = 1
  AND (SELECT count(*) FROM import_staging_rows WHERE import_run_id = (SELECT run FROM sa) AND committed_entity_kind = 'unit') = 6,
  'STAGEA-24: every row is linked to its finest entity - 6 to a Unit, the Unit-less row to its Station');

SELECT pg_temp.assert(
  (SELECT count(*) FROM stations WHERE station_name LIKE 'SA %' AND (source_file IS NULL OR source_row IS NULL)) = 0,
  'STAGEA-25: every created Station carries the file/sheet/row it was created from');

-- STAGEA-26: two rows may name one entity. The pipeline does not deduplicate
-- the source, and does not pretend 9 rows are 9 records.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_staging_rows
    WHERE import_run_id = (SELECT run FROM sa)
      AND committed_entity_id = (SELECT u.id FROM units u JOIN stations s ON s.id = u.station_id
                                  JOIN regions g ON g.id = s.region_id
                                 WHERE u.unit_name = 'SA ALPHA 1' AND g.name = 'East')) = 2,
  'STAGEA-26: two source rows describing one Unit both point at that one Unit');

-- STAGEA-27: REPLAY. A second commit of the same run is refused.
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_a_commit(%L, %L, %L)', (SELECT run FROM sa), repeat('a',64), (SELECT fp FROM sa_fp)),
  'STAGEA-27: committing an already-committed run is refused');

-- STAGEA-28: Stage A DECIDES nothing. No alias, no mapping decision.
SELECT pg_temp.assert(
  (SELECT count(*) FROM station_aliases) = (SELECT aliases FROM sa_before)
  AND (SELECT count(*) FROM import_mapping_decisions) = (SELECT decisions FROM sa_before),
  'STAGEA-28: the hierarchy commit creates no station alias and no mapping decision');

-- STAGEA-29: Stage A IMPORTS no asset. Stage B has not begun.
SELECT pg_temp.assert(
  (SELECT count(*) FROM installed_relief_valves)  = (SELECT isrv        FROM sa_before)
  AND (SELECT count(*) FROM warehouse_relief_valves) = (SELECT wsrv     FROM sa_before)
  AND (SELECT count(*) FROM hoses)                = (SELECT hoses       FROM sa_before)
  AND (SELECT count(*) FROM storage_vessels)      = (SELECT vessels     FROM sa_before)
  AND (SELECT count(*) FROM recovery_tanks)       = (SELECT tanks       FROM sa_before)
  AND (SELECT count(*) FROM gas_detectors)        = (SELECT detectors   FROM sa_before)
  AND (SELECT count(*) FROM compressors)          = (SELECT compressors FROM sa_before)
  AND (SELECT count(*) FROM dispensers)           = (SELECT dispensers  FROM sa_before),
  'STAGEA-29: the hierarchy commit creates no canonical asset of any kind');

-- STAGEA-30: THE CANONICAL SCOPE, re-derived from the catalog rather than from
-- the migration comment. No dynamic SQL, and no asset, alias or decision table.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_a_commit') !~* '\mexecute\M'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_a_commit') !~* 'quote_ident|format\s*\(',
  'STAGEA-30: cng_stage_a_commit contains no dynamic SQL, so a caller cannot name a destination');

SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_a_commit')
    !~* '(insert\s+into|update|delete\s+from)\s+(station_aliases|unit_aliases|import_mapping_decisions|installed_relief_valves|warehouse_relief_valves|storage_vessels|recovery_tanks|gas_detectors|hoses|compressors|dispensers|regions)\M',
  'STAGEA-31: cng_stage_a_commit writes no alias, decision, asset or Region table');

-- STAGEA-32: no caller-supplied actor. The act cannot be attributed to someone
-- who did not perform it.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc WHERE proname IN ('cng_stage_a_commit','cng_stage_a_preview','cng_stage_a_proposal')
     AND pg_get_function_arguments(oid) ~* '(actor|app_user|user_id|clerk)') = 0,
  'STAGEA-32: no Stage A function accepts an actor identity from its caller');

-- STAGEA-33: pinned search_path on the definer function.
SELECT pg_temp.assert(
  (SELECT proconfig FROM pg_proc WHERE proname = 'cng_stage_a_commit') @> ARRAY['search_path=pg_catalog, public'],
  'STAGEA-33: cng_stage_a_commit pins its search_path');

-- STAGEA-34: the additive lineage column is an explicit allowlist, not free text.
SELECT pg_temp.assert_rejected(
  'UPDATE import_staging_rows SET committed_entity_kind = ''anything'' WHERE source_row = 5',
  'STAGEA-34: committed_entity_kind rejects a value outside the canonical allowlist');

-- STAGEA-35: a committed run can no longer be abandoned - Stage A lineage makes
-- the 0044 abandonment guard bite, so history is never quietly erased.
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_abandon_import_run(%L, %L)', (SELECT run FROM sa), 'test'),
  'STAGEA-35: a run whose rows are committed cannot be abandoned');



-- ===========================================================================
-- STAGE B: the batch STATION mapping mechanism (Prompt 22A, migration 0047)
-- ===========================================================================
-- Destructive tests. Each tries to make the batch record something the source
-- does not prove, or to slip a changed row past an approval, and requires the
-- database to refuse the WHOLE batch.

INSERT INTO app_users (id, clerk_user_id, role, full_name, is_active)
VALUES ('11111111-1111-1111-1111-1111111111ad', 'user_test_admin_b', 'admin', 'Test Admin B', true);
SELECT set_config('request.jwt.claims',
  json_build_object('sub', 'user_test_admin_b', 'role', 'authenticated')::text, true);

CREATE TEMP TABLE sb AS SELECT
  '88888888-0000-0000-0000-00000000000a'::uuid AS run,
  '88888888-0000-0000-0000-00000000000b'::uuid AS batch,
  repeat('7', 64) AS manifest;

INSERT INTO import_runs (id, mode, label, started_at, completed_at, summary)
SELECT run, 'commit', 'stage-b-test', now(), now(),
       jsonb_build_object('manifest_fingerprint', manifest) FROM sb;
INSERT INTO import_batches (id, import_run_id, source_file, source_sheet, file_checksum,
                            header_row, rows_read, rows_flagged, rows_failed, rows_imported)
SELECT batch, run, 'SB.xlsx', 'Sheet1', repeat('8', 64), 1, 0, 0, 0, 0 FROM sb;

CREATE OR REPLACE FUNCTION pg_temp.sb_row(
  p_row integer, p_target text, p_region text, p_raw text,
  p_status text DEFAULT 'needs_station_mapping')
RETURNS uuid LANGUAGE sql AS $$
  INSERT INTO import_staging_rows (import_run_id, import_batch_id, source_file, source_sheet,
    source_row, source_raw, source_row_key, source_row_hash, target_table, outcome,
    mapping_status, normalized)
  SELECT run, batch, 'SB.xlsx', 'Sheet1', p_row, '{}'::jsonb,
         'SB.xlsx::Sheet1::' || p_row, md5(p_row::text) || md5(p_row::text),
         p_target, 'ready_unresolved', p_status,
         jsonb_build_object('region', p_region, 'source_station_name_raw', p_raw)
    FROM sb
  RETURNING id;
$$;

-- Four candidates, one per family, all resolving to TEST-STATION-A in East.
SELECT pg_temp.sb_row(1, 'storage_vessels', 'East', 'TEST-STATION-A');
SELECT pg_temp.sb_row(2, 'recovery_tanks',  'East', 'TEST-STATION-A');
SELECT pg_temp.sb_row(3, 'gas_detectors',   'East', 'TEST-STATION-A');
SELECT pg_temp.sb_row(4, 'hoses',           'East', 'TEST-STATION-A');
-- NOT candidates, and each for a different reason:
SELECT pg_temp.sb_row(5, 'storage_vessels', 'West',  'TEST-STATION-A');      -- other Region only
SELECT pg_temp.sb_row(6, 'storage_vessels', 'East',  'NO SUCH STATION');     -- no match
SELECT pg_temp.sb_row(7, 'storage_vessels', 'East',  'TEST-STATION-A', 'needs_unit_mapping'); -- past this step
SELECT pg_temp.sb_row(8, 'installed_relief_valves', 'East', 'TEST-STATION-A'); -- not a pre-import family

CREATE TEMP TABLE sb_fp AS
SELECT pv.preview_fingerprint AS fp, pv.candidate_rows AS rows, pv.candidate_groups AS groups,
       pv.storage_vessels AS sv, pv.recovery_tanks AS rt, pv.gas_detectors AS gd, pv.hoses AS ho
  FROM sb, cng_stage_b_station_preview(sb.run) pv;

-- STAGEB-1: the candidate set is DERIVED, and only the four true candidates qualify.
SELECT pg_temp.assert((SELECT rows FROM sb_fp) = 4 AND (SELECT groups FROM sb_fp) = 1,
  'STAGEB-1: 4 candidate rows in 1 Region-aware Station group');

-- STAGEB-2: one row per family, proving no family is silently skipped.
SELECT pg_temp.assert(
  (SELECT sv FROM sb_fp) = 1 AND (SELECT rt FROM sb_fp) = 1
  AND (SELECT gd FROM sb_fp) = 1 AND (SELECT ho FROM sb_fp) = 1,
  'STAGEB-2: all four pre-import families are represented exactly once');

-- STAGEB-3: the OTHER-REGION row is excluded. Region is identity, so a name
-- matching only in another Region is not a match at all.
SELECT pg_temp.assert(
  (SELECT count(*) FROM sb, cng_stage_b_station_candidates(sb.run) c
    WHERE c.region_name = 'West') = 0,
  'STAGEB-3: a Station name matching only in ANOTHER Region is never a candidate');

-- STAGEB-4: an unmatched name is excluded rather than guessed at.
SELECT pg_temp.assert(
  (SELECT count(*) FROM sb, cng_stage_b_station_candidates(sb.run) c
    WHERE c.source_raw_name = 'NO SUCH STATION') = 0,
  'STAGEB-4: a source name with no canonical Station is excluded, never fuzzy-matched');

-- STAGEB-5: a row already past this lifecycle step is excluded.
SELECT pg_temp.assert(
  (SELECT count(*) FROM sb, cng_stage_b_station_candidates(sb.run) c
    WHERE c.mapping_status <> 'needs_station_mapping') = 0,
  'STAGEB-5: only needs_station_mapping rows are candidates');

-- STAGEB-6: installed SRVs are NOT in this path - their canonical station_id is
-- nullable and they are mapped in the canonical table instead.
SELECT pg_temp.assert(
  (SELECT count(*) FROM sb, cng_stage_b_station_candidates(sb.run) c
    WHERE c.target_table NOT IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')) = 0,
  'STAGEB-6: only the four pre-import families are candidates - never an installed SRV');

-- STAGEB-7: the preview WRITES NOTHING.
SELECT pg_temp.assert((SELECT count(*) FROM import_mapping_decisions) = 0,
  'STAGEB-7: previewing the batch records no mapping decision');

-- --------------------------- refusals, before any write -------------------
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, NULL)', (SELECT run FROM sb), repeat('7',64)),
  'STAGEB-8: commit with no preview fingerprint is refused');

SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('7',64), '  '),
  'STAGEB-9: commit with a blank preview fingerprint is refused');

SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('0',64), (SELECT fp FROM sb_fp)),
  'STAGEB-10: commit with a wrong manifest fingerprint is refused');

SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('7',64), repeat('f',64)),
  'STAGEB-11: commit with a wrong preview fingerprint is refused');

-- STAGEB-12: A CHANGED SOURCE ROW lapses the approval. The conclusion is
-- unchanged - the same Station, the same Region - but the evidence moved, which
-- is exactly the 0041 rule applied to a batch.
UPDATE import_staging_rows SET source_row_hash = repeat('d', 64)
 WHERE import_run_id = (SELECT run FROM sb) AND source_row = 1;
SELECT pg_temp.assert(
  (SELECT pv.preview_fingerprint FROM sb, cng_stage_b_station_preview(sb.run) pv) <> (SELECT fp FROM sb_fp),
  'STAGEB-12: a changed source_row_hash lapses the batch approval');
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('7',64), (SELECT fp FROM sb_fp)),
  'STAGEB-13: a stale source hash refuses the ENTIRE batch, not just that row');
UPDATE import_staging_rows SET source_row_hash = md5('1') || md5('1')
 WHERE import_run_id = (SELECT run FROM sb) AND source_row = 1;

-- STAGEB-14: A CHANGED LIFECYCLE STATUS refuses the whole batch.
UPDATE import_staging_rows SET mapping_status = 'needs_unit_mapping'
 WHERE import_run_id = (SELECT run FROM sb) AND source_row = 2;
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('7',64), (SELECT fp FROM sb_fp)),
  'STAGEB-14: a row whose mapping_status moved refuses the entire batch');
UPDATE import_staging_rows SET mapping_status = 'needs_station_mapping'
 WHERE import_run_id = (SELECT run FROM sb) AND source_row = 2;

-- STAGEB-15: A CHANGED STATION IDENTITY refuses the whole batch - here the
-- canonical Station is renamed, so the candidate silently disappears.
UPDATE stations SET station_name = 'TEST-STATION-A-RENAMED'
 WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('7',64), (SELECT fp FROM sb_fp)),
  'STAGEB-15: a renamed or vanished canonical Station refuses the entire batch');
UPDATE stations SET station_name = 'TEST-STATION-A'
 WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- STAGEB-16: AMBIGUITY refuses the whole batch. A second Station in the SAME
-- Region whose normalized name collides cannot exist (the unique constraint
-- forbids it), so ambiguity is proved the only way it can arise: the row's own
-- Region changing to one where the name resolves differently.
UPDATE import_staging_rows
   SET normalized = jsonb_set(normalized, '{region}', '"Canal"')
 WHERE import_run_id = (SELECT run FROM sb) AND source_row = 3;
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('7',64), (SELECT fp FROM sb_fp)),
  'STAGEB-16: a row whose Region changed refuses the entire batch');
UPDATE import_staging_rows
   SET normalized = jsonb_set(normalized, '{region}', '"East"')
 WHERE import_run_id = (SELECT run FROM sb) AND source_row = 3;

-- STAGEB-17: nothing at all was written by any of those nine refusals.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_mapping_decisions) = 0,
  'STAGEB-17: every refused batch left zero mapping decisions behind');

-- ---------------------------- the authorized batch -------------------------
CREATE TEMP TABLE sb_before AS SELECT
  (SELECT count(*) FROM stations)        AS stations,
  (SELECT count(*) FROM units)           AS units,
  (SELECT count(*) FROM station_aliases) AS aliases,
  (SELECT count(*) FROM storage_vessels) AS sv,
  (SELECT count(*) FROM recovery_tanks)  AS rt,
  (SELECT count(*) FROM gas_detectors)   AS gd,
  (SELECT count(*) FROM hoses)           AS ho,
  (SELECT count(*) FROM audit_logs)      AS audit;

SELECT * FROM cng_stage_b_station_commit((SELECT run FROM sb), repeat('7',64), (SELECT fp FROM sb_fp));

-- STAGEB-18: exactly the four approved rows were decided.
SELECT pg_temp.assert((SELECT count(*) FROM import_mapping_decisions) = 4,
  'STAGEB-18: the batch wrote exactly one decision per approved row');

-- STAGEB-19: STATION ONLY. Not one Unit was recorded.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_mapping_decisions WHERE confirmed_unit_id IS NOT NULL) = 0,
  'STAGEB-19: the batch wrote ZERO Unit ids - Station confirmation is not Unit confirmation');

-- STAGEB-20: the derived status is the EXISTING lifecycle step, not a new one.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_mapping_decisions WHERE resulting_mapping_status = 'needs_unit_mapping') = 4
  AND (SELECT count(DISTINCT resulting_mapping_status) FROM import_mapping_decisions) = 1,
  'STAGEB-20: every decision advances needs_station_mapping -> needs_unit_mapping');

-- STAGEB-21: NO EQUIPMENT PARENT CAN EXIST HERE. Proved from the catalog: the
-- decision table carries no equipment column, so equipment inference is
-- structurally impossible rather than merely omitted.
SELECT pg_temp.assert(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_name = 'import_mapping_decisions'
      AND column_name IN ('compressor_id','dispenser_id','storage_vessel_id',
                          'recovery_tank_id','gas_detector_id','hose_id')) = 0,
  'STAGEB-21: the decision table has no equipment column - no equipment parent is expressible');

-- STAGEB-22: the Station recorded is the Region-correct one.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_mapping_decisions d
    JOIN stations s ON s.id = d.confirmed_station_id
   WHERE s.region_id <> d.region_id) = 0
  AND (SELECT count(DISTINCT confirmed_station_id) FROM import_mapping_decisions) = 1,
  'STAGEB-22: every decision names the Station in the row''s own Region');

-- STAGEB-23: the reviewed hash is the STAGED row''s own, captured server-side.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_mapping_decisions d
    JOIN import_staging_rows r ON r.id = d.staging_row_id
   WHERE d.reviewed_source_row_hash IS DISTINCT FROM r.source_row_hash) = 0,
  'STAGEB-23: every decision records the source_row_hash of its own staged row');

-- STAGEB-24: the non-candidates were not touched.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_mapping_decisions d
    JOIN import_staging_rows r ON r.id = d.staging_row_id
   WHERE r.source_row IN (5, 6, 7, 8)) = 0,
  'STAGEB-24: no decision was written for any excluded row');

-- STAGEB-25: the actor is a real administrator, derived server-side.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_mapping_decisions
    WHERE decided_by = '11111111-1111-1111-1111-1111111111ad') = 4,
  'STAGEB-25: every decision is attributed to the acting administrator');

-- STAGEB-26: every decision is audited.
SELECT pg_temp.assert(
  (SELECT count(*) FROM audit_logs WHERE action = 'mapping_changed'
     AND entity_table = 'import_mapping_decisions') >= 4,
  'STAGEB-26: the batch wrote one audit row per decision');

-- STAGEB-27: REPLAY. A second identical commit cannot duplicate a decision.
SELECT pg_temp.assert_rejected(
  format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)', (SELECT run FROM sb), repeat('7',64), (SELECT fp FROM sb_fp)),
  'STAGEB-27: re-running the same approved batch is refused');
SELECT pg_temp.assert((SELECT count(*) FROM import_mapping_decisions) = 4,
  'STAGEB-28: the refused replay left the decision count unchanged');

-- STAGEB-29: "exactly one active decision per source row" is a DATABASE
-- property, so even a direct insert cannot duplicate one.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_indexes WHERE indexname = 'imd_one_active_per_source_row') = 1,
  'STAGEB-29: the active-decision uniqueness index still backs replay safety');

-- STAGEB-30: THE FIREWALL. No alias, no Station, no Unit, no canonical asset.
SELECT pg_temp.assert(
  (SELECT count(*) FROM stations)        = (SELECT stations FROM sb_before)
  AND (SELECT count(*) FROM units)       = (SELECT units    FROM sb_before)
  AND (SELECT count(*) FROM station_aliases) = (SELECT aliases FROM sb_before)
  AND (SELECT count(*) FROM storage_vessels) = (SELECT sv FROM sb_before)
  AND (SELECT count(*) FROM recovery_tanks)  = (SELECT rt FROM sb_before)
  AND (SELECT count(*) FROM gas_detectors)   = (SELECT gd FROM sb_before)
  AND (SELECT count(*) FROM hoses)           = (SELECT ho FROM sb_before),
  'STAGEB-30: the batch created no Station, Unit, alias or canonical asset');

-- STAGEB-31: raw staged evidence is never altered by a decision.
SELECT pg_temp.assert(
  (SELECT count(*) FROM import_staging_rows
    WHERE import_run_id = (SELECT run FROM sb) AND mapping_status <> 'needs_station_mapping'
      AND source_row <= 6) = 0,
  'STAGEB-31: the staged rows themselves are unchanged - the decision is the record');

-- STAGEB-32: CANONICAL SCOPE, re-derived from the catalog.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') !~* '\mexecute\M'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') !~* 'quote_ident',
  'STAGEB-32: the batch commit contains no dynamic SQL');

SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit')
    !~* '(insert\s+into|update|delete\s+from)\s+(stations|units|station_aliases|unit_aliases|storage_vessels|recovery_tanks|gas_detectors|hoses|compressors|dispensers|installed_relief_valves|warehouse_relief_valves)\M',
  'STAGEB-33: the batch commit names no hierarchy, alias or canonical asset table');

-- STAGEB-34: no caller-supplied actor.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc WHERE proname LIKE 'cng_stage_b%'
     AND pg_get_function_arguments(oid) ~* '(actor|app_user|user_id|clerk|decided_by)') = 0,
  'STAGEB-34: no Stage B function accepts an actor identity from its caller');

-- STAGEB-35: pinned search_path on the definer function.
SELECT pg_temp.assert(
  (SELECT proconfig FROM pg_proc WHERE proname = 'cng_stage_b_station_commit')
    @> ARRAY['search_path=pg_catalog, public'],
  'STAGEB-35: cng_stage_b_station_commit pins its search_path');



-- STAGEB-36: SAME-REGION AMBIGUITY IS UNREACHABLE, not merely unhandled. Two
-- Stations in one Region cannot share a normalized name, because
-- `stations_region_norm_uq` forbids it — so the candidate function's
-- `n_same_region = 1` test can only ever exclude a row for having ZERO matches.
-- Proved by attempting the duplicate rather than asserting the constraint text.
SELECT pg_temp.assert_rejected(
  $sb$INSERT INTO stations (region_id, station_name)
      SELECT region_id, 'test-station-a' FROM stations
       WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001'$sb$,
  'STAGEB-36: a second Station with the same normalized name in one Region is rejected');

-- STAGEB-37: and the guard is still present, so a future schema change that
-- relaxed that constraint would not silently make ambiguous rows committable.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_candidates')
    LIKE '%n_same_region = 1%',
  'STAGEB-37: the candidate set still requires EXACTLY one same-Region Station');



-- ===========================================================================
-- STAGE B PREVIEW PERFORMANCE (Prompt 22C.2, migration 0048)
-- ===========================================================================
-- The production defect was a TIMEOUT, not a wrong answer, so these assert the
-- two structural properties that made it slow — measured, not guessed:
-- RLS was being evaluated once per staged row, and the candidate set four
-- times per preview. Both are catalog-visible, so a later edit that quietly
-- reverts either one fails here rather than in a browser.

-- STAGEBPERF-1: the candidate CTEs stay MATERIALIZED. Without this the planner
-- inlines them and re-scans RLS-protected `stations` per staged row, which is
-- the 9.7 s measured in production.
SELECT pg_temp.assert(
  (SELECT count(*) FROM regexp_matches(
     (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_candidates'),
     'AS MATERIALIZED', 'g')) >= 2,
  'STAGEBPERF-1: the candidate function materializes both its station and staged CTEs');

-- STAGEBPERF-2: the preview holds its candidate and group sets once each,
-- rather than re-deriving them per output column.
SELECT pg_temp.assert(
  (SELECT count(*) FROM regexp_matches(
     (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_preview'),
     'AS MATERIALIZED', 'g')) >= 2,
  'STAGEBPERF-2: the preview materializes its candidate and group sets');

SELECT pg_temp.assert(
  (SELECT count(*) FROM regexp_matches(
     (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_preview'),
     'cng_stage_b_station_groups', 'g')) = 1,
  'STAGEBPERF-3: the preview calls the grouping function exactly once');

-- STAGEBPERF-4: THE FINGERPRINT EXPRESSION IS UNCHANGED. A performance fix is
-- not allowed to move an approval: the fields, their order, both separators and
-- the sort key are what the owner's approved hash was computed over.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_preview')
    LIKE '%c.staging_row_id::text, c.region_id::text, c.station_id::text,%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_preview')
    LIKE '%c.station_norm, c.station_name, c.source_row_hash,%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_preview')
    LIKE '%chr(30) ORDER BY c.staging_row_id%',
  'STAGEBPERF-4: the preview fingerprint covers the same fields, separators and order');

-- STAGEBPERF-5: the exactly-one-Station test survived the rewrite.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_candidates')
    LIKE '%n_same_region = 1%',
  'STAGEBPERF-5: the candidate set still requires EXACTLY one same-Region Station');

-- STAGEBPERF-6: STILL SECURITY INVOKER AND STABLE. Materializing changes how
-- OFTEN RLS is evaluated, never whether it is — speed must not have been bought
-- by making the read paths definer, which would let them see rows the caller
-- may not.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('cng_stage_b_station_candidates','cng_stage_b_station_preview')
      AND (prosecdef OR provolatile <> 's')) = 0,
  'STAGEBPERF-6: the optimized read paths are still SECURITY INVOKER and STABLE');

-- STAGEBPERF-7: the optimization did not touch the commit.
SELECT pg_temp.assert(
  (SELECT prosecdef FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') IS TRUE
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit')
        ILIKE '%cng_require_admin()%',
  'STAGEBPERF-7: the commit is untouched — still SECURITY DEFINER and still admin-gated');

-- ===========================================================================
-- ASSETIMP-*: canonical asset import (Prompt 23A, migration 0049)
-- ===========================================================================

-- ASSETIMP-1: UNIT IS STRUCTURALLY UNWRITABLE. This is the single most
-- important property of the whole import: not one of the four INSERT column
-- lists names `unit_id`, so no caller, payload or code path can set one. It is
-- re-derived from pg_proc.prosrc rather than trusted from a comment.
SELECT pg_temp.assert(
  (SELECT count(*) FROM regexp_matches(
     (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_commit'),
     'INSERT INTO (storage_vessels|recovery_tanks|gas_detectors|hoses) \(([^)]*unit_id[^)]*)\)', 'g')) = 0,
  'ASSETIMP-1: no asset INSERT column list contains unit_id — Unit is unwritable');

-- ASSETIMP-2: THE CANONICAL FIREWALL. The commit may never write hierarchy,
-- aliases or mapping decisions. The allowlist IS the body: four literal asset
-- targets plus the audit row.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_commit')
    !~* 'INSERT INTO (stations|units|station_aliases|unit_aliases|import_mapping_decisions)',
  'ASSETIMP-2: the commit writes no Station, Unit, alias or mapping decision');

-- ASSETIMP-3: NO DYNAMIC SQL, so `target_table` is data in a column and can
-- never name a destination.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_commit') NOT LIKE '%EXECUTE %'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_commit') NOT LIKE '%quote_ident%',
  'ASSETIMP-4: the commit contains no dynamic SQL');

-- ASSETIMP-4: the ASSETIMP-1 pattern is PROVED to detect a violation, so a
-- passing assertion means something. A pattern that can never fail is not a test.
SELECT pg_temp.assert(
  (SELECT count(*) FROM regexp_matches(
     'INSERT INTO storage_vessels (station_id, unit_id, region_id)',
     'INSERT INTO (storage_vessels|recovery_tanks|gas_detectors|hoses) \(([^)]*unit_id[^)]*)\)', 'g')) = 1,
  'ASSETIMP-4: the unit_id detector actually fires on a violating column list');

-- ASSETIMP-5: service_role ONLY. A canonical asset carries no created_by, so
-- there is no actor to attribute and no reason to open a browser path.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc p
    WHERE p.proname LIKE 'cng_asset_import%'
      AND (has_function_privilege('anon', p.oid, 'EXECUTE')
        OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))) = 0,
  'ASSETIMP-5: no browser role may execute any asset import function');

SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc p
    WHERE p.proname LIKE 'cng_asset_import%'
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')) = 3,
  'ASSETIMP-6: all three asset import functions are executable by service_role');

-- ASSETIMP-7: search_path pinned on all three; the two read paths are NOT
-- definer, so they cannot write and RLS still bounds them.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc
    WHERE proname LIKE 'cng_asset_import%' AND proconfig IS NULL) = 0,
  'ASSETIMP-7: every asset import function pins search_path');

SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('cng_asset_import_proposal','cng_asset_import_preview')
      AND (prosecdef OR provolatile <> 's')) = 0,
  'ASSETIMP-8: the asset import read paths are SECURITY INVOKER and STABLE');

-- ASSETIMP-9: the approval is content-bound and fails closed — both
-- fingerprints are required and re-derived inside the commit transaction.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_commit')
    LIKE '%p_expected_preview_fingerprint%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_commit')
    LIKE '%p_expected_manifest_fingerprint%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_commit')
    LIKE '%cng_asset_import_preview(p_import_run_id)%',
  'ASSETIMP-9: the commit re-derives both approval fingerprints itself');

-- ASSETIMP-10: RECORDED ABSENCE IS NOT A DEVICE. A detector row the pipeline
-- marked `creates_detector_record = false` is evidence an area has NO detector;
-- importing it would manufacture a device the source says is absent.
SELECT pg_temp.assert(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_asset_import_proposal')
    LIKE '%creates_detector_record%',
  'ASSETIMP-10: recorded detector absence is excluded from canonical import');

-- ASSETIMP-11: NO IDENTITY IS INVENTED. None of the four tables carries a
-- UNIQUE constraint on serial_number, deliberately (Prompt 14, principle 16):
-- duplicates are reported, never enforced away or merged.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_constraint c
     JOIN pg_class t ON t.oid = c.conrelid
    WHERE t.relname IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
      AND c.contype = 'u'
      AND pg_get_constraintdef(c.oid) LIKE '%serial_number%') = 0,
  'ASSETIMP-11: no serial_number uniqueness was added — duplicates stay reported, not merged');

-- ASSETIMP-12: the lineage kinds this import uses were ALREADY in the 0046
-- allowlist, so no enum or CHECK had to be widened to make assets fit.
SELECT pg_temp.assert(
  (SELECT pg_get_constraintdef(oid) FROM pg_constraint
    WHERE conname = 'isr_committed_entity_kind_ck') LIKE '%storage_vessel%'
  AND (SELECT pg_get_constraintdef(oid) FROM pg_constraint
    WHERE conname = 'isr_committed_entity_kind_ck') LIKE '%gas_detector%',
  'ASSETIMP-12: asset lineage kinds already existed in the staging allowlist');

-- ASSETIMP-13: the schema itself is why unit_id NULL is legal, in all four
-- families — needs_unit_mapping REQUIRES a NULL Unit.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
    WHERE t.relname IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
      AND c.conname = t.relname || '_needs_unit_ck') = 4,
  'ASSETIMP-13: all four families carry the needs_unit_mapping => unit_id IS NULL rule');

-- ASSETIMP-14: station_id stayed NOT NULL in all four families. Nothing was
-- relaxed to make the import possible.
SELECT pg_temp.assert(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
      AND column_name = 'station_id' AND is_nullable = 'NO') = 4,
  'ASSETIMP-14: station_id is still NOT NULL in every asset family');

-- ===========================================================================
-- VDUP — Storage Vessel duplicate SERIAL CANDIDATES (Prompt 24B, migration 0050)
--
-- Data principle 16: repeated values are not duplicates without supporting
-- evidence. These assert that the condition is REPORTED and that nothing is
-- merged, rejected or deduplicated on the strength of a repeated string.
-- ===========================================================================

-- VDUP-1: there is NO UNIQUE constraint on either vessel family's serial, and
-- none was added. Duplicates remain storable.
SELECT pg_temp.assert(
  NOT EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE tablename IN ('storage_vessels','recovery_tanks')
       AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%serial_number%'),
  'VDUP-1: no UNIQUE constraint on vessel serial_number - duplicates are reported, never rejected');

-- Two independent storage vessels recording the same serial, plus one unique,
-- plus two with no serial at all and one blank string.
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, serial_number)
SELECT 'dddddddd-0000-0000-0000-0000000d0001', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', 'SV-DUP-24B' FROM ids;
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, serial_number)
SELECT 'dddddddd-0000-0000-0000-0000000d0002', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', 'SV-DUP-24B' FROM ids;
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, serial_number)
SELECT 'dddddddd-0000-0000-0000-0000000d0003', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', 'SV-UNIQUE-24B' FROM ids;
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, serial_number)
SELECT 'dddddddd-0000-0000-0000-0000000d0004', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', NULL FROM ids;
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, serial_number)
SELECT 'dddddddd-0000-0000-0000-0000000d0005', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', NULL FROM ids;
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, serial_number)
SELECT 'dddddddd-0000-0000-0000-0000000d0006', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', '   ' FROM ids;
-- A RECOVERY TANK carrying the storage vessel's serial. It is a DIFFERENT
-- entity in a different table; the two must not be compared with one another.
INSERT INTO recovery_tanks (id, station_id, region_id, mapping_status, serial_number)
SELECT 'dddddddd-0000-0000-0000-0000000d0007', 'aaaaaaaa-0000-0000-0000-000000000002', region_canal,
       'needs_unit_mapping', 'SV-DUP-24B' FROM ids;

-- VDUP-2: both copies are retained. NOTHING is deduplicated.
SELECT pg_temp.assert(
  (SELECT count(*) FROM storage_vessels WHERE serial_number = 'SV-DUP-24B') = 2,
  'VDUP-2: two storage vessels may carry the same serial and both are retained');

-- VDUP-3: the management view REPORTS the condition, on BOTH members of the
-- pair, so a filtered view can never hide one half of a candidate group.
SELECT pg_temp.assert(
  (SELECT count(*) FROM v_vessel_management
    WHERE asset_type = 'storage_vessel' AND serial_number = 'SV-DUP-24B' AND serial_duplicate) = 2,
  'VDUP-3: both members of a duplicate serial group are flagged');

-- VDUP-4: a unique serial stays unflagged.
SELECT pg_temp.assert(
  (SELECT serial_duplicate FROM v_vessel_management
    WHERE asset_type = 'storage_vessel' AND serial_number = 'SV-UNIQUE-24B') = false,
  'VDUP-4: a unique serial is not reported as a candidate');

-- VDUP-5: several NULL serials are several UNKNOWNS, not one repeated value.
SELECT pg_temp.assert(
  NOT EXISTS (SELECT 1 FROM v_vessel_management WHERE serial_number IS NULL AND serial_duplicate),
  'VDUP-5: NULL serials are never duplicates of one another');

-- VDUP-6: neither is a BLANK serial. A blank source cell and a NULL are the
-- same fact, and two blanks are not evidence of a shared identity.
SELECT pg_temp.assert(
  NOT EXISTS (
    SELECT 1 FROM v_vessel_management
     WHERE nullif(btrim(serial_number), '') IS NULL AND serial_duplicate),
  'VDUP-6: blank serials are never duplicates of one another');

-- VDUP-7: missing and duplicate are separate reported conditions.
SELECT pg_temp.assert(
  (SELECT count(*) FROM v_vessel_management WHERE serial_missing AND serial_duplicate) = 0
  AND (SELECT count(*) FROM v_vessel_management
        WHERE asset_type = 'storage_vessel' AND serial_missing) >= 3,
  'VDUP-7: serial_missing and serial_duplicate are distinct and never both true');

-- VDUP-8: a Storage Vessel and a Recovery Tank sharing a serial are NOT a
-- candidate pair. They are different entities in different tables, and the
-- comparison is partitioned by asset_type.
SELECT pg_temp.assert(
  (SELECT count(*) FROM v_vessel_management
    WHERE serial_number = 'SV-DUP-24B' AND serial_duplicate) = 2
  AND (SELECT serial_duplicate FROM v_vessel_management
        WHERE asset_type = 'recovery_tank' AND serial_number = 'SV-DUP-24B') = false,
  'VDUP-8: the two vessel families are never compared with one another');

-- VDUP-9: the reported count equals the size of the group, and is NULL where
-- the serial is blank - never 0, which would read as a counted absence.
SELECT pg_temp.assert(
  (SELECT DISTINCT serial_duplicate_count FROM v_vessel_management
    WHERE asset_type = 'storage_vessel' AND serial_number = 'SV-DUP-24B') = 2
  AND (SELECT serial_duplicate_count FROM v_vessel_management
        WHERE id = 'dddddddd-0000-0000-0000-0000000d0003') = 1
  AND (SELECT serial_duplicate_count IS NULL FROM v_vessel_management
        WHERE id = 'dddddddd-0000-0000-0000-0000000d0004'),
  'VDUP-9: serial_duplicate_count states the group size and is NULL for a blank serial');

-- VDUP-10: the serial VALUE itself is untouched. The view reports, it never
-- normalizes, trims or rewrites what the source recorded.
SELECT pg_temp.assert(
  (SELECT serial_number FROM v_vessel_management
    WHERE id = 'dddddddd-0000-0000-0000-0000000d0006') = '   ',
  'VDUP-10: a blank-looking serial is reported exactly as stored, never trimmed away');

-- VDUP-11: the view still runs with the CALLER's rights after being replaced.
-- CREATE OR REPLACE VIEW does not preserve reloptions (the Prompt 19B defect),
-- so the duplicate comparison could silently have become owner-rights - which
-- would report a collision whose other half the caller may not read.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_class
    WHERE relname = 'v_vessel_management' AND relkind = 'v'
      AND reloptions @> ARRAY['security_invoker=true']) = 1,
  'VDUP-11: v_vessel_management still runs with the caller''s rights');

-- VDUP-12: the dependent report view survived the replacement intact.
SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_class WHERE relname = 'v_report_due_compliance' AND relkind = 'v') = 1,
  'VDUP-12: v_report_due_compliance still exists after v_vessel_management was replaced');

-- VDUP-13: migration 0050 adds READ-ONLY metadata. It writes nothing, and adds
-- no table, column, constraint or index of its own.
SELECT pg_temp.assert(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name IN ('storage_vessels','recovery_tanks')
      AND column_name IN ('serial_duplicate','serial_missing','serial_duplicate_count')) = 0,
  'VDUP-13: duplicate metadata is derived in the view and stored on no table');


-- ===========================================================================
-- Prompt 25J-B: the Installed SRV attention summary, as ONE row.
-- The strip previously fired seven parallel counts at v_installed_srv_management
-- and reached the authenticated role's 8s statement_timeout in production. These
-- assert the replacement's CONTRACT and its security, and above all that its
-- seven numbers equal what the seven separate queries returned -- the fix must
-- change the number of scans, never a count.
-- ===========================================================================
SELECT pg_temp.assert(
  (SELECT reloptions::text FROM pg_class WHERE relname = 'v_installed_srv_summary')
    LIKE '%security_invoker=true%',
  'SRVSUM-1: the summary view runs with the CALLER''s rights, so counts stay Region-bounded');

SELECT pg_temp.assert(
  (SELECT count(*) FROM information_schema.role_table_grants
    WHERE table_name = 'v_installed_srv_summary' AND grantee = 'anon') = 0,
  'SRVSUM-2: anon holds nothing on the summary view');

SELECT pg_temp.assert(
  (SELECT count(*) FROM information_schema.role_table_grants
    WHERE table_name = 'v_installed_srv_summary' AND grantee = 'authenticated'
      AND privilege_type <> 'SELECT') = 0,
  'SRVSUM-3: authenticated holds SELECT and no write grant on the summary view');

SELECT pg_temp.assert(
  (SELECT count(*) FROM v_installed_srv_summary) = 1,
  'SRVSUM-4: the summary is exactly ONE row, so the screen makes one round trip');

-- A mixed dataset, deliberately shaped like production after the Prompt 25J
-- batch: Station-confirmed rows and Station-unconfirmed rows COEXISTING, which
-- is the state the production failure was first observed in.
INSERT INTO installed_relief_valves
  (region_id, station_id, mapping_status, source_station_name_raw,
   next_calibration_date, next_calibration_precision)
SELECT r.id, s.id, 'needs_unit_mapping', 'SRVSUM confirmed',
       current_date - 10, 'exact_date'
  FROM regions r JOIN stations s ON s.region_id = r.id LIMIT 1;
INSERT INTO installed_relief_valves
  (region_id, mapping_status, source_station_name_raw,
   next_calibration_date, next_calibration_precision)
SELECT r.id, 'needs_station_mapping', 'SRVSUM unconfirmed',
       current_date + 3, 'exact_date'
  FROM regions r LIMIT 1;
INSERT INTO installed_relief_valves
  (region_id, mapping_status, source_station_name_raw, next_calibration_raw, next_calibration_precision)
SELECT r.id, 'needs_station_mapping', 'SRVSUM undated', '2024', 'year_only'
  FROM regions r LIMIT 1;

SELECT pg_temp.assert(
  (SELECT total FROM v_installed_srv_summary)
    = (SELECT count(*) FROM v_installed_srv_management),
  'SRVSUM-5: total equals the row view, with both mapping states present');

SELECT pg_temp.assert(
  (SELECT needs_station_mapping FROM v_installed_srv_summary)
    = (SELECT count(*) FROM v_installed_srv_management WHERE mapping_status = 'needs_station_mapping')
  AND (SELECT needs_unit_mapping FROM v_installed_srv_summary)
    = (SELECT count(*) FROM v_installed_srv_management WHERE mapping_status = 'needs_unit_mapping')
  AND (SELECT needs_equipment_mapping FROM v_installed_srv_summary)
    = (SELECT count(*) FROM v_installed_srv_management WHERE mapping_status = 'needs_equipment_mapping')
  AND (SELECT conflict FROM v_installed_srv_summary)
    = (SELECT count(*) FROM v_installed_srv_management WHERE mapping_status = 'conflict'),
  'SRVSUM-6: every mapping count equals the separate query it replaced');

SELECT pg_temp.assert(
  (SELECT needs_station_mapping + needs_unit_mapping + needs_equipment_mapping + conflict
     FROM v_installed_srv_summary) <= (SELECT total FROM v_installed_srv_summary),
  'SRVSUM-7: the mapping buckets never exceed the total');

SELECT pg_temp.assert(
  (SELECT overdue FROM v_installed_srv_summary)
    = (SELECT count(*) FROM v_installed_srv_management WHERE due_status = 'overdue')
  AND (SELECT attention FROM v_installed_srv_summary)
    = (SELECT count(*) FROM v_installed_srv_management
        WHERE due_status IN ('overdue','due_today','due_7','due_15','due_30','due_60')),
  'SRVSUM-8: overdue and attention equal the separate queries they replaced');

SELECT pg_temp.assert(
  (SELECT attention FROM v_installed_srv_summary) >= (SELECT overdue FROM v_installed_srv_summary),
  'SRVSUM-9: attention INCLUDES overdue, exactly as the screen states');

-- Date precision is not re-derived here: the summary reads due_status from the
-- row view, which reads cng_due_status(). A year_only date must therefore be
-- counted by neither bucket, exactly as principle 17 requires.
SELECT pg_temp.assert(
  (SELECT count(*) FROM v_installed_srv_management
    WHERE next_calibration_precision <> 'exact_date'
      AND due_status IN ('overdue','due_today','due_7','due_15','due_30','due_60')) = 0,
  'SRVSUM-10: a non-exact date enters no due bucket, so it cannot reach the summary');

SELECT pg_temp.assert(
  (SELECT count(*) FROM pg_class WHERE relname = 'v_installed_srv_summary' AND relkind = 'v') = 1
  AND (SELECT count(*) FROM information_schema.columns
        WHERE table_name = 'v_installed_srv_summary') = 7,
  'SRVSUM-11: the summary exposes exactly the seven counts the strip renders');


ROLLBACK;
