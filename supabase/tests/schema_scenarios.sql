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

ROLLBACK;
