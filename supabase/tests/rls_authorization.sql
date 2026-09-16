-- rls_authorization.sql
-- Authorization test suite: role x region x operation, executed as the real
-- `authenticated` Postgres role with synthetic Clerk claims.
--
-- These are DATABASE-LEVEL authorization tests. They exercise the exact RLS and
-- GRANT path a Clerk-authenticated request takes, by setting the same
-- `request.jwt.claims` GUC that Supabase populates from a verified Clerk token.
-- They do NOT prove the Clerk -> Supabase token exchange itself; that is a
-- separate end-to-end test and is reported separately.
--
-- Everything runs in one transaction that is deliberately aborted at the end, so
-- the suite leaves no data behind.
--
--   psql -d <db> -f supabase/tests/rls_authorization.sql

BEGIN;
SET client_min_messages = notice;

CREATE OR REPLACE FUNCTION pg_temp.ok(p_cond boolean, p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT p_cond THEN RAISE EXCEPTION 'FAILED: %', p_label; END IF;
  RAISE NOTICE 'PASS  %', p_label;
END $$;

-- Becomes the given persona for subsequent statements in this transaction.
CREATE OR REPLACE FUNCTION pg_temp.become(p_sub text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  IF p_sub IS NULL THEN
    PERFORM set_config('request.jwt.claims', '', true);
  ELSE
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.as_anon()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE anon';
  PERFORM set_config('request.jwt.claims', '', true);
END $$;

-- Runs SQL as the current persona and reports whether it was DENIED.
-- "Denied" means an error was raised (privilege or policy violation).
CREATE OR REPLACE FUNCTION pg_temp.denied(p_sql text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN true;
END $$;

-- ===========================================================================
-- Fixtures, created with RLS bypassed (superuser).
-- ===========================================================================
CREATE TEMP TABLE f AS
SELECT
  (SELECT id FROM regions WHERE code='east') AS r_east,
  (SELECT id FROM regions WHERE code='west') AS r_west;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('a0000000-0000-0000-0000-00000000000a','clerk_admin',    'admin',    true,  'TESTDATA Admin'),
  ('a0000000-0000-0000-0000-00000000000b','clerk_manager',  'manager',  true,  'TESTDATA Manager'),
  ('a0000000-0000-0000-0000-00000000000c','clerk_eng_east', 'engineer', true,  'TESTDATA Eng East'),
  ('a0000000-0000-0000-0000-00000000000d','clerk_eng_west', 'engineer', true,  'TESTDATA Eng West'),
  ('a0000000-0000-0000-0000-00000000000e','clerk_view_east','viewer',   true,  'TESTDATA Viewer East'),
  ('a0000000-0000-0000-0000-00000000000f','clerk_pending',  'viewer',   false, 'TESTDATA Pending');

INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT 'a0000000-0000-0000-0000-00000000000c'::uuid, r_east, true  FROM f
UNION ALL SELECT 'a0000000-0000-0000-0000-00000000000d'::uuid, r_west, true  FROM f
UNION ALL SELECT 'a0000000-0000-0000-0000-00000000000e'::uuid, r_east, false FROM f;

INSERT INTO stations (id, region_id, station_name)
SELECT 'e5700000-0000-0000-0000-0000000000e1'::uuid, r_east, 'TESTDATA-EAST-STATION' FROM f;
INSERT INTO stations (id, region_id, station_name)
SELECT 'e5700000-0000-0000-0000-0000000000f1'::uuid, r_west, 'TESTDATA-WEST-STATION' FROM f;

INSERT INTO units (id, station_id, region_id, unit_name)
SELECT 'e5700000-0000-0000-0000-0000000000e2', 'e5700000-0000-0000-0000-0000000000e1', r_east, 'TESTDATA-EAST-UNIT' FROM f;
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT 'e5700000-0000-0000-0000-0000000000f2', 'e5700000-0000-0000-0000-0000000000f1', r_west, 'TESTDATA-WEST-UNIT' FROM f;

INSERT INTO compressors (id, station_id, region_id, unit_id, mapping_status, model)
SELECT 'e5700000-0000-0000-0000-0000000000e3', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       'e5700000-0000-0000-0000-0000000000e2', 'resolved', 'TESTDATA-EAST-COMP' FROM f;
INSERT INTO compressors (id, station_id, region_id, unit_id, mapping_status, model)
SELECT 'e5700000-0000-0000-0000-0000000000f3', 'e5700000-0000-0000-0000-0000000000f1', r_west,
       'e5700000-0000-0000-0000-0000000000f2', 'resolved', 'TESTDATA-WEST-COMP' FROM f;

INSERT INTO storage_vessels (id, station_id, region_id, unit_id, mapping_status, model)
SELECT 'e5700000-0000-0000-0000-0000000000f4', 'e5700000-0000-0000-0000-0000000000f1', r_west,
       'e5700000-0000-0000-0000-0000000000f2', 'resolved', 'TESTDATA-WEST-VESSEL' FROM f;

-- SRV in East, station confirmed, awaiting equipment mapping
INSERT INTO installed_relief_valves (id, station_id, region_id, unit_id, mapping_status, location_raw, expected_parent_kind)
SELECT 'e5700000-0000-0000-0000-0000000000e5', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       'e5700000-0000-0000-0000-0000000000e2', 'needs_equipment_mapping', 'Stage', 'compressor' FROM f;
-- SRV in West, station confirmed
INSERT INTO installed_relief_valves (id, station_id, region_id, unit_id, mapping_status, location_raw, expected_parent_kind)
SELECT 'e5700000-0000-0000-0000-0000000000f5', 'e5700000-0000-0000-0000-0000000000f1', r_west,
       'e5700000-0000-0000-0000-0000000000f2', 'needs_equipment_mapping', 'Stage', 'compressor' FROM f;
-- SRV with NO confirmed station; region_id says East, raw text names an East-looking station.
-- This is the record an East engineer must NOT be able to see or claim.
INSERT INTO installed_relief_valves (id, station_id, region_id, mapping_status, source_station_name_raw, source_region_raw, location_raw, expected_parent_kind)
SELECT 'e5700000-0000-0000-0000-0000000000e6', NULL, r_east, 'needs_station_mapping',
       'TESTDATA-EAST-STATION', 'East', 'Storage', 'storage_vessel' FROM f;


-- Gas detectors (Prompt 13). East and West, resolved and unit-unresolved, plus
-- presence EVIDENCE rows that carry no detector asset at all.
INSERT INTO gas_detectors (id, station_id, region_id, unit_id, mapping_status, manufacturer, model, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000e7', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       'e5700000-0000-0000-0000-0000000000e2', 'resolved', 'Honeywell', 'XNX', 'TESTDATA-EAST-GD', 'assigned' FROM f;
INSERT INTO gas_detectors (id, station_id, region_id, unit_id, mapping_status, manufacturer, model, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000f7', 'e5700000-0000-0000-0000-0000000000f1', r_west,
       'e5700000-0000-0000-0000-0000000000f2', 'resolved', 'Draeger', 'PIR', 'TESTDATA-WEST-GD', 'assigned' FROM f;
-- Station proven, Unit NOT. No unit is guessed for it anywhere.
INSERT INTO gas_detectors (id, station_id, region_id, unit_id, mapping_status, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000e8', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       NULL, 'needs_unit_mapping', 'TESTDATA-EAST-GD-NOUNIT', 'assigned' FROM f;

-- Presence evidence: the source states no detector exists. NO gas_detectors
-- row is created to represent that absence.
INSERT INTO gas_detector_presence (station_id, region_id, unit_id, detector_presence, presence_raw, area_type, area_type_raw)
SELECT 'e5700000-0000-0000-0000-0000000000e1', r_east, 'e5700000-0000-0000-0000-0000000000e2',
       'installed', 'Exist in the station', 'closed', 'Close Area' FROM f;
INSERT INTO gas_detector_presence (station_id, region_id, unit_id, detector_presence, presence_raw, area_type, area_type_raw)
SELECT 'e5700000-0000-0000-0000-0000000000f1', r_west, 'e5700000-0000-0000-0000-0000000000f2',
       'not_installed', 'Not exist in the station', 'open', 'Open Area' FROM f;


-- Hoses (Prompt 14). East and West, resolved and unit-unresolved, plus a
-- duplicated serial that spans the region boundary on purpose.
INSERT INTO hoses (id, station_id, region_id, unit_id, mapping_status, description, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000e9', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       'e5700000-0000-0000-0000-0000000000e2', 'resolved', 'TESTDATA east hose', 'TESTDATA-EAST-HOSE', 'assigned' FROM f;
INSERT INTO hoses (id, station_id, region_id, unit_id, mapping_status, description, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000f9', 'e5700000-0000-0000-0000-0000000000f1', r_west,
       'e5700000-0000-0000-0000-0000000000f2', 'resolved', 'TESTDATA west hose', 'TESTDATA-WEST-HOSE', 'assigned' FROM f;
-- Station proven, Unit NOT. No unit is guessed for it anywhere.
INSERT INTO hoses (id, station_id, region_id, unit_id, mapping_status, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000ea', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       NULL, 'needs_unit_mapping', 'TESTDATA-EAST-HOSE-NOUNIT', 'assigned' FROM f;
-- No serial at all.
INSERT INTO hoses (id, station_id, region_id, unit_id, mapping_status, serial_number)
SELECT 'e5700000-0000-0000-0000-0000000000eb', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       NULL, 'needs_unit_mapping', NULL FROM f;
-- THE CROSS-REGION SERIAL COLLISION. One copy in East, one in West. Neither
-- region's reader may learn of the other's existence through the duplicate flag.
INSERT INTO hoses (id, station_id, region_id, unit_id, mapping_status, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000ec', 'e5700000-0000-0000-0000-0000000000e1', r_east,
       NULL, 'needs_unit_mapping', 'TESTDATA-CROSS-DUP', 'assigned' FROM f;
INSERT INTO hoses (id, station_id, region_id, unit_id, mapping_status, serial_number, serial_status)
SELECT 'e5700000-0000-0000-0000-0000000000fc', 'e5700000-0000-0000-0000-0000000000f1', r_west,
       NULL, 'needs_unit_mapping', 'TESTDATA-CROSS-DUP', 'assigned' FROM f;


-- Alerts (Prompt 15). East and West, plus one on a station-unconfirmed SRV,
-- which is the sensitive case: its raw source context must reach admins and
-- managers only.
INSERT INTO alerts (id, alert_rule_id, subject, threshold, asset_type, asset_id,
                    region_id, station_id, unit_id, due_date, days_left, needs_mapping)
SELECT 'e5700000-0000-0000-0000-0000000000d1',
       (SELECT id FROM alert_rules WHERE subject='srv_calibration' AND threshold='due_30'),
       'srv_calibration', 'due_30', 'installed_relief_valve',
       'e5700000-0000-0000-0000-0000000000e5', r_east,
       'e5700000-0000-0000-0000-0000000000e1', 'e5700000-0000-0000-0000-0000000000e2',
       DATE '2026-10-16', 30, false FROM f;
INSERT INTO alerts (id, alert_rule_id, subject, threshold, asset_type, asset_id,
                    region_id, station_id, unit_id, due_date, days_left, needs_mapping)
SELECT 'e5700000-0000-0000-0000-0000000000d2',
       (SELECT id FROM alert_rules WHERE subject='srv_calibration' AND threshold='overdue'),
       'srv_calibration', 'overdue', 'installed_relief_valve',
       'e5700000-0000-0000-0000-0000000000f5', r_west,
       'e5700000-0000-0000-0000-0000000000f1', 'e5700000-0000-0000-0000-0000000000f2',
       DATE '2026-08-02', -45, false FROM f;
-- THE SENSITIVE ONE. No confirmed Station; region_id says East and the raw text
-- names an East-looking station. An East engineer must NOT be able to see it.
INSERT INTO alerts (id, alert_rule_id, subject, threshold, asset_type, asset_id,
                    region_id, station_id, unit_id, due_date, days_left,
                    needs_mapping, needs_station_mapping, source_station_name_raw)
SELECT 'e5700000-0000-0000-0000-0000000000d3',
       (SELECT id FROM alert_rules WHERE subject='srv_calibration' AND threshold='due_15'),
       'srv_calibration', 'due_15', 'installed_relief_valve',
       'e5700000-0000-0000-0000-0000000000e6', r_east,
       NULL, NULL, DATE '2026-10-01', 15, true, true, 'TESTDATA-EAST-STATION' FROM f;

-- Per-user read state and a delivery record, both belonging to the VIEWER.
INSERT INTO alert_reads (alert_id, app_user_id)
VALUES ('e5700000-0000-0000-0000-0000000000d1', 'a0000000-0000-0000-0000-00000000000e');
INSERT INTO notification_deliveries (alert_id, app_user_id, channel, status, error_detail)
VALUES ('e5700000-0000-0000-0000-0000000000d1', 'a0000000-0000-0000-0000-00000000000e',
        'email', 'failed', 'TESTDATA provider rejected');

INSERT INTO warehouse_relief_valves (id, availability_status, serial_number)
VALUES ('e5700000-0000-0000-0000-0000000000a5', 'available_calibrated', 'TESTDATA-WH-1');

INSERT INTO import_batches (id, source_file, status, rows_read)
VALUES ('e5700000-0000-0000-0000-0000000000b5', 'TESTDATA.xlsx', 'dry_run', 1);
INSERT INTO import_issues (import_batch_id, source_file, issue_type, severity)
VALUES ('e5700000-0000-0000-0000-0000000000b5', 'TESTDATA.xlsx', 'unmatched_station', 'warning');

INSERT INTO alerts (alert_rule_id, subject, threshold, asset_type, asset_id, region_id, station_id, due_date, needs_mapping)
SELECT (SELECT id FROM alert_rules WHERE subject='srv_calibration' AND threshold='due_30'),
       'srv_calibration','due_30','installed_relief_valve','e5700000-0000-0000-0000-0000000000f5',
       r_west, 'e5700000-0000-0000-0000-0000000000f1', cng_business_date()+20, false FROM f;
INSERT INTO alerts (alert_rule_id, subject, threshold, asset_type, asset_id, region_id, station_id, source_station_name_raw, due_date, needs_mapping, needs_station_mapping)
SELECT (SELECT id FROM alert_rules WHERE subject='srv_calibration' AND threshold='due_15'),
       'srv_calibration','due_15','installed_relief_valve','e5700000-0000-0000-0000-0000000000e6',
       r_east, NULL, 'TESTDATA-EAST-STATION', cng_business_date()+10, true, true FROM f;

-- ===========================================================================
-- 1. ANONYMOUS — must see and do nothing
-- ===========================================================================
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM stations'),      'ANON-1 cannot read stations');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM installed_relief_valves'), 'ANON-2 cannot read SRVs');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM app_users'),     'ANON-3 cannot read users');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM audit_logs'),    'ANON-4 cannot read audit');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM regions'),       'ANON-5 cannot enumerate regions');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM alerts'),        'ANON-6 cannot read alerts');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM import_issues'), 'ANON-7 cannot read data quality');
  PERFORM pg_temp.ok(pg_temp.denied($q$INSERT INTO stations (region_id, station_name)
      SELECT id,'anon-hack' FROM regions LIMIT 1$q$),                      'ANON-8 cannot write');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT cng_current_role()'),          'ANON-9 cannot execute authz helpers');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 2. PENDING USER — authenticated but not yet activated
-- ===========================================================================
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.become('clerk_pending');
  SELECT count(*) INTO n FROM stations;
  PERFORM pg_temp.ok(n = 0, 'PENDING-1 sees no stations');
  SELECT count(*) INTO n FROM installed_relief_valves;
  PERFORM pg_temp.ok(n = 0, 'PENDING-2 sees no SRVs');
  SELECT count(*) INTO n FROM app_users WHERE clerk_user_id = 'clerk_pending';
  PERFORM pg_temp.ok(n = 1, 'PENDING-3 CAN read own app_users row (to show "awaiting approval")');
  SELECT count(*) INTO n FROM app_users;
  PERFORM pg_temp.ok(n = 1, 'PENDING-4 sees only their own row, not the directory');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE app_users SET role='admin' WHERE clerk_user_id='clerk_pending'$q$)
                     OR (SELECT role FROM app_users WHERE clerk_user_id='clerk_pending') = 'viewer',
                     'PENDING-5 cannot self-activate or self-promote');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 3. VIEWER (East) — read-only, region-scoped
-- ===========================================================================
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1';
  PERFORM pg_temp.ok(n = 1, 'VIEWER-1 can read granted region (East)');
  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok(n = 0, 'VIEWER-2 IDOR: direct West station id returns nothing');
  SELECT count(*) INTO n FROM compressors WHERE id='e5700000-0000-0000-0000-0000000000f3';
  PERFORM pg_temp.ok(n = 0, 'VIEWER-3 IDOR: direct West compressor id returns nothing');
  SELECT count(*) INTO n FROM regions;
  PERFORM pg_temp.ok(n = 1, 'VIEWER-4 sees only granted regions');

  PERFORM pg_temp.ok(pg_temp.denied($q$INSERT INTO stations (region_id, station_name)
      SELECT region_id,'viewer-insert' FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1'$q$),
      'VIEWER-5 cannot INSERT even in granted region');
  UPDATE stations SET notes='viewer-edit' WHERE id='e5700000-0000-0000-0000-0000000000e1';
  PERFORM pg_temp.ok((SELECT notes FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1')
                     IS DISTINCT FROM 'viewer-edit',
      'VIEWER-6 UPDATE affects zero rows (viewer can read the row, so this check is honest)');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1'$q$),
      'VIEWER-7 cannot DELETE (no grant)');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE installed_relief_valves SET mapping_status='conflict'
      WHERE id='e5700000-0000-0000-0000-0000000000e5'$q$)
      OR (SELECT mapping_status FROM installed_relief_valves WHERE id='e5700000-0000-0000-0000-0000000000e5')
         = 'needs_equipment_mapping',
      'VIEWER-8 cannot map assets');
  SELECT count(*) INTO n FROM import_issues;
  PERFORM pg_temp.ok(n = 0, 'VIEWER-9 no import/data-quality access');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 4. ENGINEER (East) — write within region only; the IDOR and cross-region core
-- ===========================================================================
DO $$
DECLARE n int; v_west_region uuid; v_east_region uuid;
BEGIN
  SELECT r_west, r_east INTO v_west_region, v_east_region FROM f;
  PERFORM pg_temp.become('clerk_eng_east');

  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1';
  PERFORM pg_temp.ok(n = 1, 'ENG-1 can read own region');
  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok(n = 0, 'ENG-2 IDOR: West station by id -> no row');
  SELECT count(*) INTO n FROM units WHERE id='e5700000-0000-0000-0000-0000000000f2';
  PERFORM pg_temp.ok(n = 0, 'ENG-3 IDOR: West unit by id -> no row');
  SELECT count(*) INTO n FROM compressors WHERE id='e5700000-0000-0000-0000-0000000000f3';
  PERFORM pg_temp.ok(n = 0, 'ENG-4 IDOR: West compressor by id -> no row');
  SELECT count(*) INTO n FROM storage_vessels WHERE id='e5700000-0000-0000-0000-0000000000f4';
  PERFORM pg_temp.ok(n = 0, 'ENG-5 IDOR: West vessel by id -> no row');
  SELECT count(*) INTO n FROM installed_relief_valves WHERE id='e5700000-0000-0000-0000-0000000000f5';
  PERFORM pg_temp.ok(n = 0, 'ENG-6 IDOR: West SRV by id -> no row');

  -- permitted write inside own region
  UPDATE stations SET notes='eng-east-ok' WHERE id='e5700000-0000-0000-0000-0000000000e1';
  PERFORM pg_temp.ok((SELECT notes FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1')='eng-east-ok',
      'ENG-7 CAN update within own region');

  -- cross-region UPDATE by known UUID
  -- Attempt only; verified below from a privileged context, because an engineer
  -- cannot see West at all and so cannot honestly verify its own failure.
  UPDATE stations SET notes='eng-east-hack' WHERE id='e5700000-0000-0000-0000-0000000000f1';

  -- cross-region INSERT
  PERFORM pg_temp.ok(pg_temp.denied(format(
      $q$INSERT INTO stations (region_id, station_name) VALUES (%L,'eng-east-west-insert')$q$, v_west_region)),
      'ENG-9 cannot INSERT a station into West');

  -- THE ESCAPE TEST: move an East station into West using WITH CHECK
  PERFORM pg_temp.ok(pg_temp.denied(format(
      $q$UPDATE stations SET region_id=%L WHERE id='e5700000-0000-0000-0000-0000000000e1'$q$, v_west_region)),
      'ENG-10 cannot move an East station into West (WITH CHECK)');

  -- DELETE anywhere
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1'$q$),
      'ENG-11 cannot DELETE (no grant)');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM installed_relief_valves WHERE id='e5700000-0000-0000-0000-0000000000e5'$q$),
      'ENG-12 cannot DELETE SRVs');

  -- mapping inside own region is allowed
  UPDATE installed_relief_valves SET compressor_id='e5700000-0000-0000-0000-0000000000e3',
         mapping_status='resolved', resolved_by='a0000000-0000-0000-0000-00000000000c', resolved_at=now()
   WHERE id='e5700000-0000-0000-0000-0000000000e5';
  PERFORM pg_temp.ok((SELECT mapping_status FROM installed_relief_valves
                       WHERE id='e5700000-0000-0000-0000-0000000000e5')='resolved',
      'ENG-13 CAN map an SRV inside own region');

  -- UNRESOLVED SRV: invisible, and cannot be claimed
  SELECT count(*) INTO n FROM installed_relief_valves WHERE id='e5700000-0000-0000-0000-0000000000e6';
  PERFORM pg_temp.ok(n = 0,
      'ENG-14 cannot see a needs_station_mapping SRV even though its region_id and raw name look like East');
  UPDATE installed_relief_valves
     SET station_id='e5700000-0000-0000-0000-0000000000e1', mapping_status='needs_unit_mapping'
   WHERE id='e5700000-0000-0000-0000-0000000000e6';   -- verified below, privileged

  -- audit forging
  PERFORM pg_temp.ok(pg_temp.denied($q$INSERT INTO asset_mapping_audit
      (asset_type, asset_id, new_mapping_status, changed_by)
      VALUES ('installed_relief_valve','e5700000-0000-0000-0000-0000000000e5','resolved',
              'a0000000-0000-0000-0000-00000000000a')$q$),
      'ENG-16 cannot forge changed_by as another user');
  INSERT INTO asset_mapping_audit (asset_type, asset_id, new_mapping_status, changed_by)
  VALUES ('installed_relief_valve','e5700000-0000-0000-0000-0000000000e5','resolved',
          'a0000000-0000-0000-0000-00000000000c');
  PERFORM pg_temp.ok(true, 'ENG-17 CAN write an audit row attributed to themselves');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE asset_mapping_audit SET reason='tamper'$q$),
      'ENG-18 cannot UPDATE audit history');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM asset_mapping_audit$q$),
      'ENG-19 cannot DELETE audit history');

  -- self-escalation
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE app_users SET role='manager' WHERE clerk_user_id='clerk_eng_east'$q$)
      OR (SELECT role FROM app_users WHERE clerk_user_id='clerk_eng_east')='engineer',
      'ENG-20 cannot promote self to manager');
  PERFORM pg_temp.ok(pg_temp.denied(format(
      $q$INSERT INTO user_region_access (app_user_id, region_id) VALUES ('a0000000-0000-0000-0000-00000000000c',%L)$q$,
      v_west_region)),
      'ENG-21 cannot grant self access to West');
  DELETE FROM user_region_access WHERE app_user_id='a0000000-0000-0000-0000-00000000000d';
  -- verified below, privileged
  SELECT count(*) INTO n FROM app_users;
  PERFORM pg_temp.ok(n = 1, 'ENG-23 sees only own user row, not the directory');

  -- warehouse is global but read-only for engineers
  SELECT count(*) INTO n FROM warehouse_relief_valves;
  PERFORM pg_temp.ok(n = 1, 'ENG-24 CAN read global warehouse stock');
  UPDATE warehouse_relief_valves SET notes='eng-edit' WHERE id='e5700000-0000-0000-0000-0000000000a5';
  PERFORM pg_temp.ok((SELECT notes FROM warehouse_relief_valves
                       WHERE id='e5700000-0000-0000-0000-0000000000a5') IS DISTINCT FROM 'eng-edit',
      'ENG-25 cannot update warehouse stock');

  -- alerts
  --
  -- Asserted by INTENT rather than by a blanket zero. The original `= 0` held
  -- only because no East alert existed in the fixtures; Prompt 15 adds one that
  -- an East engineer is legitimately entitled to see. Naming the two forbidden
  -- rows explicitly is strictly stronger than counting, and it cannot silently
  -- pass again just because the fixture set changed.
  SELECT count(*) INTO n FROM alerts WHERE region_id = v_west_region;
  PERFORM pg_temp.ok(n = 0, 'ENG-26 sees no West alert');

  SELECT count(*) INTO n FROM alerts WHERE station_id IS NULL;
  PERFORM pg_temp.ok(n = 0, 'ENG-26b sees no station-unconfirmed SRV alert, whatever its region_id claims');

  -- owner-confirmed rules readable, never writable
  SELECT count(*) INTO n FROM owner_confirmed_part_numbers;
  PERFORM pg_temp.ok(n = 1, 'ENG-27 CAN read owner-confirmed rules');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE owner_confirmed_part_numbers SET source_value='HACKED'$q$),
      'ENG-28 cannot modify owner-confirmed part numbers');
  PERFORM pg_temp.ok(pg_temp.denied($q$INSERT INTO owner_confirmed_station_aliases
      (source_name_raw, canonical_name_raw) VALUES ('x','y')$q$),
      'ENG-29 cannot add an owner-confirmed alias');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 4b. PRIVILEGED VERIFICATION of the engineer's attempts.
--
-- Runs with RLS bypassed, because a caller who is correctly denied visibility
-- cannot be trusted to confirm its own denial: "I see nothing" and "nothing
-- happened" are different claims, and only this block can prove the second.
-- ===========================================================================
DO $$
BEGIN
  PERFORM pg_temp.ok((SELECT notes FROM stations WHERE id='e5700000-0000-0000-0000-0000000000f1')
                     IS DISTINCT FROM 'eng-east-hack',
      'ENG-8 cross-region UPDATE of West station really changed nothing');
  PERFORM pg_temp.ok((SELECT station_id FROM installed_relief_valves
                       WHERE id='e5700000-0000-0000-0000-0000000000e6') IS NULL,
      'ENG-15 unmapped SRV really was NOT claimed into the engineer region');
  PERFORM pg_temp.ok((SELECT count(*) FROM user_region_access
                       WHERE app_user_id='a0000000-0000-0000-0000-00000000000d') = 1,
      'ENG-22 another user region grant really still exists');
  PERFORM pg_temp.ok((SELECT role FROM app_users WHERE clerk_user_id='clerk_eng_east') = 'engineer',
      'ENG-20b engineer role really unchanged after self-promotion attempt');
  PERFORM pg_temp.ok((SELECT count(*) FROM user_region_access
                       WHERE app_user_id='a0000000-0000-0000-0000-00000000000c') = 1,
      'ENG-21b engineer really did not gain a second region');
  PERFORM pg_temp.ok((SELECT notes FROM warehouse_relief_valves
                       WHERE id='e5700000-0000-0000-0000-0000000000a5') IS DISTINCT FROM 'eng-edit',
      'ENG-25b warehouse stock really unchanged by engineer');
END $$;

-- ===========================================================================
-- 5. ENGINEER (West) — mirror check, proving scoping is per-user not global
-- ===========================================================================
DO $$
DECLARE n int; v_west_region uuid;
BEGIN
  -- Read from the fixture table BEFORE assuming a role: `regions` is itself
  -- RLS-scoped, so resolving it afterwards would beg the question.
  SELECT r_west INTO v_west_region FROM f;
  PERFORM pg_temp.become('clerk_eng_west');
  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok(n = 1, 'ENGW-1 West engineer CAN read West');
  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1';
  PERFORM pg_temp.ok(n = 0, 'ENGW-2 West engineer cannot read East');
  -- Again by intent, not by a fixture-count. What matters is that EVERY alert
  -- the West engineer can see is a West alert, and that none is station-
  -- unconfirmed -- both of which stay true however many fixtures are added.
  SELECT count(*) INTO n FROM alerts WHERE region_id IS DISTINCT FROM v_west_region;
  PERFORM pg_temp.ok(n = 0, 'ENGW-3 West engineer sees West alerts only');
  SELECT count(*) INTO n FROM alerts WHERE region_id = v_west_region;
  PERFORM pg_temp.ok(n > 0, 'ENGW-3b and does see their own region''s alerts');
  SELECT count(*) INTO n FROM alerts WHERE station_id IS NULL;
  PERFORM pg_temp.ok(n = 0, 'ENGW-3c and no station-unconfirmed alert reaches them');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 6. MANAGER — company-wide technical authority, but not an administrator
-- ===========================================================================
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.become('clerk_manager');
  SELECT count(*) INTO n FROM stations
   WHERE id IN ('e5700000-0000-0000-0000-0000000000e1','e5700000-0000-0000-0000-0000000000f1');
  PERFORM pg_temp.ok(n = 2, 'MGR-1 reads all regions');
  SELECT count(*) INTO n FROM regions;
  PERFORM pg_temp.ok(n = 6, 'MGR-2 sees all six regions');

  UPDATE stations SET notes='mgr-edit' WHERE id='e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok((SELECT notes FROM stations WHERE id='e5700000-0000-0000-0000-0000000000f1')='mgr-edit',
      'MGR-3 can write in any region');

  SELECT count(*) INTO n FROM installed_relief_valves WHERE id='e5700000-0000-0000-0000-0000000000e6';
  PERFORM pg_temp.ok(n = 1, 'MGR-4 CAN see the needs_station_mapping SRV');
  UPDATE installed_relief_valves
     SET station_id='e5700000-0000-0000-0000-0000000000e1', mapping_status='needs_unit_mapping'
   WHERE id='e5700000-0000-0000-0000-0000000000e6';
  PERFORM pg_temp.ok((SELECT station_id FROM installed_relief_valves
                       WHERE id='e5700000-0000-0000-0000-0000000000e6') IS NOT NULL,
      'MGR-5 CAN resolve the station of an unmapped SRV');

  SELECT count(*) INTO n FROM import_issues;
  PERFORM pg_temp.ok(n = 1, 'MGR-6 has data-quality access');

  UPDATE warehouse_relief_valves SET notes='mgr-wh' WHERE id='e5700000-0000-0000-0000-0000000000a5';
  PERFORM pg_temp.ok((SELECT notes FROM warehouse_relief_valves
                       WHERE id='e5700000-0000-0000-0000-0000000000a5')='mgr-wh',
      'MGR-7 can update warehouse technical data');
  PERFORM pg_temp.ok(pg_temp.denied($q$INSERT INTO warehouse_relief_valves (availability_status)
      VALUES ('available_new')$q$),
      'MGR-8 cannot create warehouse stock (admin only)');

  -- privilege boundaries
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE app_users SET role='admin' WHERE clerk_user_id='clerk_manager'$q$)
      OR (SELECT role FROM app_users WHERE clerk_user_id='clerk_manager')='manager',
      'MGR-9 cannot promote self to admin');
  PERFORM pg_temp.ok(pg_temp.denied($q$INSERT INTO user_region_access (app_user_id, region_id)
      SELECT 'a0000000-0000-0000-0000-00000000000b', id FROM regions LIMIT 1$q$),
      'MGR-10 cannot manage region access (admin only)');
  SELECT count(*) INTO n FROM app_users;
  PERFORM pg_temp.ok(n = 1, 'MGR-11 no user directory access');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE owner_confirmed_part_numbers SET note='x'$q$),
      'MGR-12 cannot modify owner-confirmed rules');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM stations WHERE id='e5700000-0000-0000-0000-0000000000f1'$q$),
      'MGR-13 cannot hard-delete');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 7. ADMIN — full administrative authority, still bound by immutability
-- ===========================================================================
DO $$
DECLARE n int; v_west uuid;
BEGIN
  SELECT r_west INTO v_west FROM f;
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM app_users;
  PERFORM pg_temp.ok(n = 6, 'ADMIN-1 can read the full user directory');
  SELECT count(*) INTO n FROM audit_logs;
  PERFORM pg_temp.ok(n >= 0, 'ADMIN-2 can read audit logs');

  UPDATE app_users SET role='engineer' WHERE clerk_user_id='clerk_view_east';
  PERFORM pg_temp.ok((SELECT role FROM app_users WHERE clerk_user_id='clerk_view_east')='engineer',
      'ADMIN-3 can change a user role');
  UPDATE app_users SET role='viewer' WHERE clerk_user_id='clerk_view_east';

  INSERT INTO user_region_access (app_user_id, region_id, can_map)
  VALUES ('a0000000-0000-0000-0000-00000000000e', v_west, false);
  PERFORM pg_temp.ok(true, 'ADMIN-4 can grant region access');
  DELETE FROM user_region_access
   WHERE app_user_id='a0000000-0000-0000-0000-00000000000e' AND region_id=v_west;
  PERFORM pg_temp.ok(true, 'ADMIN-5 can revoke region access');

  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE app_users SET clerk_user_id='stolen'
      WHERE clerk_user_id='clerk_view_east'$q$),
      'ADMIN-6 cannot re-point a Clerk identity (no column grant)');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1'$q$),
      'ADMIN-7 cannot hard-delete a station (history preserved by design)');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE audit_logs SET summary='tamper'$q$),
      'ADMIN-8 cannot alter audit history');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE owner_confirmed_part_numbers SET source_value='X'$q$),
      'ADMIN-9 owner rules are migration-controlled, not API-editable');
  SELECT count(*) INTO n FROM installed_relief_valves;
  PERFORM pg_temp.ok(n = 3, 'ADMIN-10 sees every SRV including unmapped');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 8. PERSONAL DATA ISOLATION
-- ===========================================================================
DO $$
DECLARE n int;
BEGIN
  PERFORM pg_temp.become('clerk_eng_east');
  INSERT INTO push_subscriptions (app_user_id, endpoint, p256dh, auth)
  VALUES ('a0000000-0000-0000-0000-00000000000c','https://example.invalid/testdata-east','k','a');
  PERFORM pg_temp.ok(true, 'PERSONAL-1 can register own push subscription');
  PERFORM pg_temp.ok(pg_temp.denied($q$INSERT INTO push_subscriptions (app_user_id, endpoint, p256dh, auth)
      VALUES ('a0000000-0000-0000-0000-00000000000d','https://example.invalid/testdata-other','k','a')$q$),
      'PERSONAL-2 cannot create a subscription for another user');
  RESET ROLE;

  PERFORM pg_temp.become('clerk_eng_west');
  SELECT count(*) INTO n FROM push_subscriptions;
  PERFORM pg_temp.ok(n = 0, 'PERSONAL-3 cannot read another user device subscription');
  UPDATE push_subscriptions SET endpoint='https://example.invalid/stolen';
  PERFORM pg_temp.ok((SELECT count(*) FROM push_subscriptions
                      WHERE endpoint='https://example.invalid/stolen') = 0,
      'PERSONAL-4 cannot replace another user push endpoint');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 9. UNRESOLVED-SRV ALERT VISIBILITY
-- ===========================================================================
DO $$
DECLARE n int; v_total int;
BEGIN
  -- The privileged truth, taken before any role is assumed, so the assertions
  -- below compare against reality rather than a hard-coded fixture count.
  SELECT count(*) INTO v_total FROM alerts WHERE needs_station_mapping;

  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM alerts WHERE needs_station_mapping;
  PERFORM pg_temp.ok(n = 0, 'ALERT-1 viewer gains nothing from raw station text on an unmapped alert');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_manager');
  SELECT count(*) INTO n FROM alerts WHERE needs_station_mapping;
  PERFORM pg_temp.ok(n = v_total AND v_total > 0,
    'ALERT-2 manager CAN see every unmapped-SRV alert');
  RESET ROLE;
END $$;

-- ===========================================================================
-- 10. SERVICE ROLE (the Clerk user-sync webhook)
-- ===========================================================================
-- The webhook runs as `service_role`, which has BYPASSRLS on hosted Supabase.
-- RLS therefore protects nothing against it and the GRANT layer is the ONLY
-- thing standing between a leaked service-role key and the database. These
-- assertions test that layer directly, which is why they do not use
-- pg_temp.become (that helper sets a JWT claim, which service_role ignores).
DO $$
BEGIN
  SET LOCAL ROLE service_role;

  BEGIN
    UPDATE app_users SET role = 'admin' WHERE clerk_user_id = 'clerk_view_east';
    PERFORM pg_temp.ok(false, 'SR-1 service_role must NOT be able to write role');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.ok(true, 'SR-1 service_role cannot write role -- no UPDATE(role) grant');
  END;

  BEGIN
    INSERT INTO user_region_access (app_user_id, region_id)
    SELECT id, (SELECT id FROM regions LIMIT 1) FROM app_users WHERE clerk_user_id = 'clerk_view_east';
    PERFORM pg_temp.ok(false, 'SR-2 service_role must NOT be able to grant region access');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.ok(true, 'SR-2 service_role cannot grant region access');
  END;

  BEGIN
    DELETE FROM app_users WHERE clerk_user_id = 'clerk_view_east';
    PERFORM pg_temp.ok(false, 'SR-3 service_role must NOT be able to delete an account');
  EXCEPTION WHEN insufficient_privilege THEN
    PERFORM pg_temp.ok(true, 'SR-3 service_role cannot delete an account -- no hard deletes');
  END;

  RESET ROLE;
END $$;

-- The privilege BOUNDARY, asserted from the catalogue rather than by attempting
-- each forbidden statement: this is the layer that actually constrains a
-- BYPASSRLS role, and a single stock default privilege silently re-granted
-- TRUNCATE on all 35 objects once already (migration 0024).
DO $$
DECLARE
  n         int;
  leaked    text;
  app_privs text;
BEGIN
  -- SR-4..SR-6: nothing destructive or schema-modifying, anywhere in public.
  FOR leaked IN SELECT unnest(ARRAY['TRUNCATE', 'REFERENCES', 'TRIGGER'])
  LOOP
    SELECT count(*) INTO n
      FROM information_schema.role_table_grants
     WHERE grantee = 'service_role' AND table_schema = 'public'
       AND privilege_type = leaked;
    PERFORM pg_temp.ok(n = 0,
      format('SR-%s service_role holds no %s in public (found %s)',
             CASE leaked WHEN 'TRUNCATE' THEN 4 WHEN 'REFERENCES' THEN 5 ELSE 6 END,
             leaked, n));
  END LOOP;

  -- SR-7: app_users is the ONLY object it can touch at all.
  SELECT count(DISTINCT table_name) INTO n
    FROM information_schema.role_table_grants
   WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name <> 'app_users';
  PERFORM pg_temp.ok(n = 0,
    format('SR-7 service_role reaches no table but app_users (found %s others)', n));

  -- SR-8: and on app_users, exactly SELECT at table level -- no DELETE, no
  -- table-wide INSERT or UPDATE that would cover every column including role.
  SELECT array_to_string(array_agg(DISTINCT privilege_type ORDER BY privilege_type), ',')
    INTO app_privs
    FROM information_schema.role_table_grants
   WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name = 'app_users';
  PERFORM pg_temp.ok(app_privs = 'SELECT',
    format('SR-8 service_role table privileges on app_users are exactly SELECT (found %s)',
           coalesce(app_privs, 'none')));

  -- SR-9: the column grants the webhook genuinely needs are still present.
  SELECT count(*) INTO n
    FROM information_schema.role_column_grants
   WHERE grantee = 'service_role' AND table_schema = 'public' AND table_name = 'app_users'
     AND ((privilege_type = 'INSERT' AND column_name IN ('clerk_user_id','email','full_name','role','is_active'))
       OR (privilege_type = 'UPDATE' AND column_name IN ('email','full_name','is_active')));
  PERFORM pg_temp.ok(n = 8, format('SR-9 webhook column grants intact, 5 INSERT + 3 UPDATE (found %s)', n));

  -- SR-10: no future table can inherit the destructive privileges again.
  SELECT count(*) INTO n
    FROM pg_default_acl d
    JOIN pg_namespace ns ON ns.oid = d.defaclnamespace
   WHERE ns.nspname = 'public'
     AND d.defaclobjtype = 'r'
     AND pg_get_userbyid(d.defaclrole) = current_user
     AND d.defaclacl::text ~ 'service_role=[^/]*[Dxt]';
  PERFORM pg_temp.ok(n = 0,
    'SR-10 default privileges cannot re-grant service_role TRUNCATE/REFERENCES/TRIGGER');
END $$;

-- ===========================================================================
-- 11. DASHBOARD AGGREGATION VIEWS (0027)
-- ===========================================================================
-- An aggregate is an authorization surface. A COUNT that includes rows the
-- caller may not read leaks exactly the fact the policy exists to hide, so
-- these assert that the summaries are scoped by the SAME RLS as the detail.
DO $$
DECLARE
  n           bigint;
  regions_seen int;
  east_id     uuid;
  west_id     uuid;
BEGIN
  SELECT id INTO east_id FROM regions WHERE code = 'east';
  SELECT id INTO west_id FROM regions WHERE code = 'west';

  -- The engineer in this suite is authorized for East only.
  PERFORM pg_temp.become('clerk_eng_east');

  SELECT count(*) INTO regions_seen FROM v_dashboard_region_summary;
  PERFORM pg_temp.ok(regions_seen = 1,
    format('DASH-1 region summary shows ONLY authorized regions (saw %s)', regions_seen));

  SELECT count(*) INTO n FROM v_dashboard_region_summary WHERE region_id = west_id;
  PERFORM pg_temp.ok(n = 0, 'DASH-2 an unauthorized region produces NO row, so its size cannot be inferred');

  -- Asset counts must equal what the caller can actually SELECT, not the table total.
  SELECT total INTO n FROM v_dashboard_asset_counts WHERE asset_kind = 'installed_relief_valve';
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM installed_relief_valves),
    'DASH-3 asset counts match the caller''s own visible rows exactly');

  SELECT coalesce(sum(total), 0) INTO n FROM v_dashboard_due_summary
   WHERE asset_kind = 'installed_relief_valve';
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM installed_relief_valves),
    'DASH-4 due buckets partition the caller''s rows: they sum to the visible total, no double counting');

  RESET ROLE;

  -- An admin sees every region.
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO regions_seen FROM v_dashboard_region_summary;
  PERFORM pg_temp.ok(regions_seen = (SELECT count(*) FROM regions),
    format('DASH-5 admin sees every region in the summary (saw %s)', regions_seen));
  RESET ROLE;

  -- A viewer with no region grant aggregates nothing, rather than everything.
  PERFORM pg_temp.become('clerk_view_none');
  SELECT count(*) INTO regions_seen FROM v_dashboard_region_summary;
  PERFORM pg_temp.ok(regions_seen = 0,
    format('DASH-6 an unscoped viewer aggregates NOTHING, not everything (saw %s)', regions_seen));
  RESET ROLE;
END $$;

-- The views must never be SECURITY DEFINER, and anon must never reach them.
DO $$
DECLARE definer_views int; anon_grants int;
BEGIN
  SELECT count(*) INTO definer_views
    FROM pg_class c
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relname LIKE 'v_dashboard_%'
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer_views = 0,
    format('DASH-7 every dashboard view is security_invoker (found %s that are not)', definer_views));

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public' AND table_name LIKE 'v_dashboard_%';
  PERFORM pg_temp.ok(anon_grants = 0, 'DASH-8 anon holds no grant on any dashboard view');
END $$;

-- ===========================================================================
-- 12. HIERARCHY SUMMARY VIEWS (0029)
-- ===========================================================================
-- These back the Stations list and the Unit listing. Browsing is the surface an
-- attacker actually has: search, sort and pagination all run through them, so
-- each must prove a station outside the caller's region scope is ABSENT, not
-- merely zeroed. A total row count is itself a disclosure.
DO $$
DECLARE
  n         bigint;
  seen      int;
  west_stn  uuid := 'e5700000-0000-0000-0000-0000000000f1';
  east_stn  uuid := 'e5700000-0000-0000-0000-0000000000e1';
BEGIN
  -- Engineer authorized for East only.
  PERFORM pg_temp.become('clerk_eng_east');

  SELECT count(*) INTO n FROM v_station_summary WHERE station_id = west_stn;
  PERFORM pg_temp.ok(n = 0,
    'HIER-1 an unauthorized region''s station produces NO row in v_station_summary');

  -- Search must not become a side channel: querying the exact foreign name
  -- still returns nothing, so existence cannot be probed string by string.
  SELECT count(*) INTO n FROM v_station_summary
   WHERE normalized_name = cng_normalize_name('TESTDATA-WEST-STATION');
  PERFORM pg_temp.ok(n = 0,
    'HIER-2 searching an unauthorized station by exact name returns nothing');

  -- Pagination metadata is computed from the same view, so the total the client
  -- pages through must equal only what the caller may read.
  SELECT count(*) INTO n FROM v_station_summary;
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM stations WHERE archived_at IS NULL),
    'HIER-3 the paginated total equals the caller''s own visible stations, never the table total');

  SELECT count(*) INTO n FROM v_unit_summary WHERE station_id = west_stn;
  PERFORM pg_temp.ok(n = 0,
    'HIER-4 an unauthorized region''s units produce NO row in v_unit_summary');

  -- The counts on a station the caller CAN read must match their own visible
  -- detail rows, so the summary neither inflates nor hides.
  SELECT units INTO n FROM v_station_summary WHERE station_id = east_stn;
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM units
                           WHERE station_id = east_stn AND archived_at IS NULL),
    'HIER-5 station unit count matches the caller''s visible units exactly');

  SELECT assets INTO n FROM v_station_summary WHERE station_id = east_stn;
  PERFORM pg_temp.ok(n = (
      (SELECT count(*) FROM installed_relief_valves WHERE station_id = east_stn) +
      (SELECT count(*) FROM storage_vessels       WHERE station_id = east_stn) +
      (SELECT count(*) FROM recovery_tanks        WHERE station_id = east_stn) +
      (SELECT count(*) FROM gas_detectors         WHERE station_id = east_stn) +
      (SELECT count(*) FROM hoses                 WHERE station_id = east_stn) +
      (SELECT count(*) FROM compressors           WHERE station_id = east_stn) +
      (SELECT count(*) FROM dispensers            WHERE station_id = east_stn)),
    'HIER-6 station asset count matches the caller''s visible asset rows exactly');

  -- A station-scoped SRV with no confirmed unit must not be attributed to one.
  SELECT coalesce(sum(installed_srvs), 0) INTO n FROM v_unit_summary
   WHERE station_id = east_stn;
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM installed_relief_valves
                           WHERE station_id = east_stn AND unit_id IS NOT NULL),
    'HIER-7 unit SRV counts include only unit-confirmed valves, never unresolved ones');

  RESET ROLE;

  -- An unscoped viewer browses nothing, rather than everything.
  PERFORM pg_temp.become('clerk_view_none');
  SELECT count(*) INTO seen FROM v_station_summary;
  PERFORM pg_temp.ok(seen = 0,
    format('HIER-8 an unscoped viewer sees no stations at all (saw %s)', seen));
  SELECT count(*) INTO seen FROM v_unit_summary;
  PERFORM pg_temp.ok(seen = 0,
    format('HIER-9 an unscoped viewer sees no units at all (saw %s)', seen));
  RESET ROLE;

  -- An admin browses every region.
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO seen FROM v_station_summary WHERE station_id = west_stn;
  PERFORM pg_temp.ok(seen = 1, 'HIER-10 an admin sees stations in every region');
  RESET ROLE;
END $$;

-- Same structural guarantees the dashboard views carry.
DO $$
DECLARE definer_views int; anon_grants int; write_grants int;
BEGIN
  SELECT count(*) INTO definer_views
    FROM pg_class c
    JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relname IN ('v_station_summary','v_unit_summary')
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer_views = 0,
    format('HIER-11 both hierarchy views are security_invoker (found %s that are not)', definer_views));

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public'
     AND table_name IN ('v_station_summary','v_unit_summary');
  PERFORM pg_temp.ok(anon_grants = 0, 'HIER-12 anon holds no grant on either hierarchy view');

  -- A browsing surface is read-only. A writable view would be a second,
  -- unpoliced write path into stations and units. The object OWNER's implicit
  -- privileges are excluded deliberately: they are inherent to ownership and
  -- cannot be revoked; the boundary that matters is the application roles.
  SELECT count(*) INTO write_grants
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND table_name IN ('v_station_summary','v_unit_summary')
     AND grantee IN ('anon','authenticated','service_role','PUBLIC')
     AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
  PERFORM pg_temp.ok(write_grants = 0,
    format('HIER-13 no role may write through a hierarchy view (found %s grants)', write_grants));
END $$;

-- ===========================================================================
-- 13. UNIT WORKSPACE EQUIPMENT ISOLATION (Prompt 10)
-- ===========================================================================
-- The Unit workspace reads seven sources, each narrowed by `unit_id`. That
-- filter is a LOOKUP, not an authorization check: the boundary is RLS on the
-- underlying tables. These assert the boundary actually holds, because a Unit
-- id is guessable from a URL and an engineer in East must not learn a West
-- Unit's equipment, serials, due dates or even its existence.
DO $$
DECLARE
  n          bigint;
  east_unit  uuid := 'e5700000-0000-0000-0000-0000000000e2';
  west_unit  uuid := 'e5700000-0000-0000-0000-0000000000f2';
BEGIN
  PERFORM pg_temp.become('clerk_eng_east');

  -- Every tab, against a Unit in a Region the caller cannot read.
  SELECT count(*) INTO n FROM compressors WHERE unit_id = west_unit;
  PERFORM pg_temp.ok(n = 0, 'UNIT-1 compressors of an unauthorized Unit are invisible');

  SELECT count(*) INTO n FROM dispensers WHERE unit_id = west_unit;
  PERFORM pg_temp.ok(n = 0, 'UNIT-2 dispensers of an unauthorized Unit are invisible');

  SELECT count(*) INTO n FROM v_vessel_management WHERE unit_id = west_unit;
  PERFORM pg_temp.ok(n = 0, 'UNIT-3 vessels and recovery tanks of an unauthorized Unit are invisible');

  SELECT count(*) INTO n FROM v_gas_detector_management WHERE unit_id = west_unit;
  PERFORM pg_temp.ok(n = 0, 'UNIT-4 gas detectors of an unauthorized Unit are invisible');

  SELECT count(*) INTO n FROM v_hose_management WHERE unit_id = west_unit;
  PERFORM pg_temp.ok(n = 0, 'UNIT-5 hoses of an unauthorized Unit are invisible');

  SELECT count(*) INTO n FROM v_unit_srvs WHERE unit_id = west_unit;
  PERFORM pg_temp.ok(n = 0, 'UNIT-6 relief valves of an unauthorized Unit are invisible');

  -- The Unit itself produces no row either, so its name cannot be read.
  SELECT count(*) INTO n FROM v_unit_summary WHERE unit_id = west_unit;
  PERFORM pg_temp.ok(n = 0, 'UNIT-7 an unauthorized Unit produces NO summary row, so it cannot be named');

  -- The counts the workspace shows must equal the rows the caller can list.
  -- A summary that counted more than the tabs can show would leak a total.
  SELECT storage_vessels INTO n FROM v_unit_summary WHERE unit_id = east_unit;
  PERFORM pg_temp.ok(
    n = (SELECT count(*) FROM v_vessel_management
          WHERE unit_id = east_unit AND asset_type = 'storage_vessel'),
    'UNIT-8 the Storage count equals the rows the Storage tab can actually list');

  SELECT installed_srvs INTO n FROM v_unit_summary WHERE unit_id = east_unit;
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM installed_relief_valves WHERE unit_id = east_unit),
    'UNIT-9 the SRV count equals the caller''s unit-confirmed valves');

  RESET ROLE;
END $$;

-- The Unit SRV tab's visibility rule, asserted as an AUTHORIZATION property
-- rather than only a schema one. Whatever a caller can see through v_unit_srvs
-- must already satisfy the lifecycle rule; no role, not even admin, may reach a
-- valve whose Unit is unproven through this view.
DO $$
DECLARE bad bigint;
BEGIN
  PERFORM pg_temp.become('clerk_admin');

  SELECT count(*) INTO bad FROM v_unit_srvs WHERE unit_id IS NULL;
  PERFORM pg_temp.ok(bad = 0, 'UNIT-10 no valve without a confirmed Unit is reachable through v_unit_srvs');

  SELECT count(*) INTO bad FROM v_unit_srvs
   WHERE mapping_status NOT IN ('resolved', 'needs_equipment_mapping');
  PERFORM pg_temp.ok(bad = 0,
    'UNIT-11 needs_station_mapping, needs_unit_mapping and conflict never reach a Unit tab');

  -- A resolved valve has exactly ONE equipment parent. Two would make the
  -- hierarchy ambiguous; none would make "resolved" meaningless.
  SELECT count(*) INTO bad FROM installed_relief_valves
   WHERE mapping_status = 'resolved'
     AND (compressor_id IS NOT NULL)::int + (storage_vessel_id IS NOT NULL)::int
       + (dispenser_id IS NOT NULL)::int <> 1;
  PERFORM pg_temp.ok(bad = 0, 'UNIT-12 a resolved valve has exactly one equipment parent');

  -- Warehouse stock has no Station or Unit at all, so it cannot be attributed
  -- to one even by a query that tried.
  SELECT count(*) INTO bad
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'warehouse_relief_valves'
     AND column_name IN ('unit_id', 'station_id');
  PERFORM pg_temp.ok(bad = 0,
    'UNIT-13 warehouse valves carry no unit_id or station_id, so they cannot leak into a Unit');

  RESET ROLE;
END $$;

-- Structural guarantees for every source the Unit workspace reads.
DO $$
DECLARE definer int; anon_grants int; write_grants int;
BEGIN
  SELECT count(*) INTO definer
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public'
     AND c.relname IN ('v_unit_srvs','v_vessel_management','v_gas_detector_management','v_hose_management')
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer = 0,
    format('UNIT-14 every Unit workspace view is security_invoker (found %s that are not)', definer));

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public'
     AND table_name IN ('v_unit_srvs','v_vessel_management','v_gas_detector_management','v_hose_management');
  PERFORM pg_temp.ok(anon_grants = 0, 'UNIT-15 anon holds no grant on any Unit workspace view');

  -- Browsing is read-only. A writable aggregation view would be a second,
  -- unpoliced write path into the equipment tables.
  SELECT count(*) INTO write_grants
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND table_name IN ('v_unit_srvs','v_vessel_management','v_gas_detector_management','v_hose_management')
     AND grantee IN ('anon','authenticated','service_role','PUBLIC')
     AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
  PERFORM pg_temp.ok(write_grants = 0,
    format('UNIT-16 no application role may write through a Unit workspace view (found %s)', write_grants));
END $$;

-- ===========================================================================
-- 14. GLOBAL SRV MANAGEMENT (Prompt 11)
-- ===========================================================================
-- The global screen deliberately shows EVERY mapping state, which makes it the
-- widest SRV surface in the product. These assert the widening is safe: it is
-- the database that decides what a caller may see, through search, through
-- filters, through counts and through a direct id.
DO $$
DECLARE
  n         bigint;
  east_srv  uuid;
  west_srv  uuid;
BEGIN
  -- An SRV in each region, both fully station-mapped.
  SELECT id INTO east_srv FROM installed_relief_valves
   WHERE station_id = 'e5700000-0000-0000-0000-0000000000e1' LIMIT 1;
  SELECT id INTO west_srv FROM installed_relief_valves
   WHERE station_id = 'e5700000-0000-0000-0000-0000000000f1' LIMIT 1;

  PERFORM pg_temp.become('clerk_eng_east');

  -- Region scope, through the management view the screen actually reads.
  SELECT count(*) INTO n FROM v_installed_srv_management
   WHERE station_id = 'e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok(n = 0, 'SRV-1 another Region''s installed valves are absent from the global view');

  -- Direct id access: the id is a lookup key, never authorization (IDOR).
  IF west_srv IS NOT NULL THEN
    SELECT count(*) INTO n FROM v_installed_srv_management WHERE id = west_srv;
    PERFORM pg_temp.ok(n = 0, 'SRV-2 fetching another Region''s valve by its id returns nothing');
  END IF;

  -- Search is retrieval, not a side channel: querying the exact foreign
  -- station name still returns nothing.
  SELECT count(*) INTO n FROM v_installed_srv_management
   WHERE station_name ILIKE '%TESTDATA-WEST-STATION%';
  PERFORM pg_temp.ok(n = 0, 'SRV-3 searching a foreign Station name leaks no valve');

  -- Counts drive the summary strip and pagination. They must be the caller's.
  SELECT count(*) INTO n FROM v_installed_srv_management;
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM installed_relief_valves),
    'SRV-4 the global count equals the caller''s own visible valves, never the table total');

  -- Filtering by mapping state must not widen visibility either.
  SELECT count(*) INTO n FROM v_installed_srv_management
   WHERE mapping_status = 'needs_station_mapping'
     AND id IN (SELECT id FROM installed_relief_valves WHERE station_id IS NOT NULL);
  PERFORM pg_temp.ok(n = 0, 'SRV-5 a mapping-status filter cannot surface a row the caller may not read');

  RESET ROLE;
END $$;

-- An unconfirmed Station name is EVIDENCE, never permission (CLAUDE.md §10).
-- A Region-scoped engineer must not read station-less valves at all, because
-- their raw source name would otherwise disclose a Station they have no claim
-- to; admin and manager may, and that asymmetry is the policy's whole point.
DO $$
DECLARE eng bigint; adm bigint;
BEGIN
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO eng FROM installed_relief_valves WHERE station_id IS NULL;
  RESET ROLE;

  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO adm FROM installed_relief_valves WHERE station_id IS NULL;
  RESET ROLE;

  PERFORM pg_temp.ok(eng = 0,
    'SRV-6 a Region-scoped engineer reads NO station-unconfirmed valve, so raw source names cannot leak');
  PERFORM pg_temp.ok(adm >= eng,
    'SRV-7 admin reaches at least what the engineer can, so the asymmetry is the policy and not an accident');
END $$;

-- Warehouse isolation, from both directions.
DO $$
DECLARE n bigint; cols int;
BEGIN
  PERFORM pg_temp.become('clerk_admin');

  -- Warehouse stock carries no physical position, so it cannot be rendered as
  -- hierarchy however the UI queries it.
  SELECT count(*) INTO cols FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'warehouse_relief_valves'
     AND column_name IN ('unit_id', 'station_id', 'compressor_id', 'storage_vessel_id', 'dispenser_id');
  PERFORM pg_temp.ok(cols = 0,
    'SRV-8 warehouse valves carry no station, unit or equipment column at all');

  -- target_station is a DESTINATION and is deliberately a different column
  -- from any installed position; it must never be confused with station_id.
  SELECT count(*) INTO cols FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'v_warehouse_srv_management'
     AND column_name IN ('mapping_status', 'unit_id', 'parent_kind');
  PERFORM pg_temp.ok(cols = 0,
    'SRV-9 the warehouse view exposes no mapping status, unit or equipment parent');

  -- The two datasets are never unioned: an id from one cannot appear in the
  -- other's view.
  SELECT count(*) INTO n FROM v_warehouse_srv_management w
   WHERE EXISTS (SELECT 1 FROM v_installed_srv_management i WHERE i.id = w.id);
  PERFORM pg_temp.ok(n = 0, 'SRV-10 no record appears in both the installed and the warehouse view');

  -- And the Unit tab's narrower rule is untouched by the global widening.
  SELECT count(*) INTO n FROM v_unit_srvs
   WHERE mapping_status NOT IN ('resolved', 'needs_equipment_mapping') OR unit_id IS NULL;
  PERFORM pg_temp.ok(n = 0,
    'SRV-11 Prompt 10 Unit SRV visibility is unchanged by the global SRV screen');

  RESET ROLE;
END $$;

-- Structural guarantees for the two views the global screen reads.
DO $$
DECLARE definer int; anon_grants int; write_grants int;
BEGIN
  SELECT count(*) INTO definer
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public'
     AND c.relname IN ('v_installed_srv_management', 'v_warehouse_srv_management')
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer = 0,
    format('SRV-12 both SRV management views are security_invoker (found %s that are not)', definer));

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public'
     AND table_name IN ('v_installed_srv_management', 'v_warehouse_srv_management');
  PERFORM pg_temp.ok(anon_grants = 0, 'SRV-13 anon holds no grant on either SRV management view');

  -- The screen is read-only, and so is its data path.
  SELECT count(*) INTO write_grants
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public'
     AND table_name IN ('v_installed_srv_management', 'v_warehouse_srv_management')
     AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
     AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  PERFORM pg_temp.ok(write_grants = 0,
    format('SRV-14 no application role may write through an SRV management view (found %s)', write_grants));
END $$;

-- The mapping hierarchy constraints that a future mapping workflow will rely
-- on. Asserted here because the global screen is where that workflow will
-- live: if these ever weaken, the deferred write UI must not be built.
DO $$
DECLARE missing int;
BEGIN
  SELECT count(*) INTO missing FROM (
    SELECT unnest(ARRAY['irv_station_region_fk','irv_unit_station_fk','irv_compressor_unit_fk',
                        'irv_storage_vessel_unit_fk','irv_dispenser_unit_fk']) AS want
  ) w WHERE NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'installed_relief_valves'::regclass AND contype = 'f' AND conname = w.want
  );
  PERFORM pg_temp.ok(missing = 0,
    format('SRV-15 composite FKs still force unit-in-station and equipment-in-unit (%s missing)', missing));
END $$;

-- ===========================================================================
-- 15. VESSELS MANAGEMENT (Prompt 12)
-- ===========================================================================
-- Storage Vessels and Recovery Tanks are separate asset types sharing one
-- management view. These assert the boundary holds through every path the
-- global registry offers: list, direct id, search, counts and filters.
DO $$
DECLARE
  n         bigint;
  west_sv   uuid;
  west_rt   uuid;
BEGIN
  SELECT id INTO west_sv FROM storage_vessels
   WHERE station_id = 'e5700000-0000-0000-0000-0000000000f1' LIMIT 1;
  SELECT id INTO west_rt FROM recovery_tanks
   WHERE station_id = 'e5700000-0000-0000-0000-0000000000f1' LIMIT 1;

  PERFORM pg_temp.become('clerk_eng_east');

  SELECT count(*) INTO n FROM v_vessel_management
   WHERE asset_type = 'storage_vessel' AND station_id = 'e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok(n = 0, 'VES-1 another Region''s Storage Vessels are absent from the registry');

  SELECT count(*) INTO n FROM v_vessel_management
   WHERE asset_type = 'recovery_tank' AND station_id = 'e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok(n = 0, 'VES-2 another Region''s Recovery Tanks are absent from the registry');

  -- Direct id lookup: the id is a key, never authorization (IDOR).
  IF west_sv IS NOT NULL THEN
    SELECT count(*) INTO n FROM v_vessel_management WHERE id = west_sv;
    PERFORM pg_temp.ok(n = 0, 'VES-3 fetching a foreign Region''s vessel by id returns nothing');
  END IF;
  IF west_rt IS NOT NULL THEN
    SELECT count(*) INTO n FROM v_vessel_management WHERE id = west_rt;
    PERFORM pg_temp.ok(n = 0, 'VES-4 fetching a foreign Region''s recovery tank by id returns nothing');
  END IF;

  -- Search must not become a side channel.
  SELECT count(*) INTO n FROM v_vessel_management
   WHERE station_name ILIKE '%TESTDATA-WEST-STATION%';
  PERFORM pg_temp.ok(n = 0, 'VES-5 searching a foreign Station name leaks no vessel');

  -- The count behind the summary strip and pagination is the caller's own.
  SELECT count(*) INTO n FROM v_vessel_management WHERE asset_type = 'storage_vessel';
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM storage_vessels),
    'VES-6 the Storage count equals the caller''s own visible rows, never the table total');
  SELECT count(*) INTO n FROM v_vessel_management WHERE asset_type = 'recovery_tank';
  PERFORM pg_temp.ok(n = (SELECT count(*) FROM recovery_tanks),
    'VES-7 the Recovery count equals the caller''s own visible rows');

  -- A mapping filter cannot widen visibility.
  SELECT count(*) INTO n FROM v_vessel_management
   WHERE mapping_status = 'needs_unit_mapping'
     AND region_id NOT IN (SELECT region_id FROM user_region_access ura
                            JOIN app_users u ON u.id = ura.app_user_id
                           WHERE u.clerk_user_id = 'clerk_eng_east');
  PERFORM pg_temp.ok(n = 0, 'VES-8 a mapping filter cannot surface a row outside the caller''s Regions');

  RESET ROLE;
END $$;

-- The two asset types must not bleed into one another, and the schema must
-- still forbid the relationships the UI refuses to draw.
DO $$
DECLARE n bigint; cols int;
BEGIN
  PERFORM pg_temp.become('clerk_admin');

  -- The discriminator genuinely partitions the view.
  SELECT count(*) INTO n FROM v_vessel_management
   WHERE asset_type NOT IN ('storage_vessel', 'recovery_tank');
  PERFORM pg_temp.ok(n = 0, 'VES-9 the vessel view contains only the two vessel asset types');

  SELECT count(*) INTO n FROM v_vessel_management v
   WHERE v.asset_type = 'storage_vessel' AND EXISTS (SELECT 1 FROM recovery_tanks r WHERE r.id = v.id);
  PERFORM pg_temp.ok(n = 0, 'VES-10 no row appears under both asset types');

  -- A RECOVERY TANK CANNOT OWN AN SRV. The UI refuses to draw the
  -- relationship; this proves the schema refuses to hold it, so the refusal is
  -- a fact rather than a UI convention.
  SELECT count(*) INTO cols FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'installed_relief_valves'
     AND column_name LIKE '%recovery%';
  PERFORM pg_temp.ok(cols = 0,
    'VES-11 installed_relief_valves has no recovery-tank column, so a tank cannot own a valve');

  SELECT count(*) INTO cols FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
   WHERE t.typname = 'srv_parent_kind' AND e.enumlabel = 'recovery_tank';
  PERFORM pg_temp.ok(cols = 0, 'VES-12 srv_parent_kind does not include recovery_tank');

  -- A storage vessel CAN own one, and only through the composite key that
  -- forces the valve and the vessel into the same Unit.
  SELECT count(*) INTO cols FROM pg_constraint
   WHERE conrelid = 'installed_relief_valves'::regclass AND contype = 'f'
     AND conname = 'irv_storage_vessel_unit_fk';
  PERFORM pg_temp.ok(cols = 1,
    'VES-13 a valve reaches its Storage Vessel only through the composite unit-scoped FK');

  -- A vessel cannot be station-unconfirmed: station_id is NOT NULL on both
  -- tables, so `needs_station_mapping` is unreachable for these asset types.
  SELECT count(*) INTO cols FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name IN ('storage_vessels', 'recovery_tanks')
     AND column_name = 'station_id' AND is_nullable = 'YES';
  PERFORM pg_temp.ok(cols = 0,
    'VES-14 station_id is NOT NULL on both vessel tables, so no vessel can be station-unconfirmed');

  RESET ROLE;
END $$;

-- Structural guarantees for the view the registry reads.
DO $$
DECLARE definer int; anon_grants int; write_grants int;
BEGIN
  SELECT count(*) INTO definer
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relname = 'v_vessel_management'
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer = 0, 'VES-15 the vessel management view is security_invoker');

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public' AND table_name = 'v_vessel_management';
  PERFORM pg_temp.ok(anon_grants = 0, 'VES-16 anon holds no grant on the vessel management view');

  SELECT count(*) INTO write_grants
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'v_vessel_management'
     AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
     AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  PERFORM pg_temp.ok(write_grants = 0,
    format('VES-17 no application role may write through the vessel view (found %s)', write_grants));
END $$;

-- The Prompt-10 Unit tabs must keep their Unit scoping: the global registry
-- widening must not have relaxed them.
DO $$
DECLARE n bigint;
BEGIN
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM v_vessel_management WHERE unit_id IS NULL AND mapping_status = 'resolved';
  PERFORM pg_temp.ok(n = 0,
    'VES-18 a resolved vessel always carries a confirmed Unit, so a Unit tab cannot show an unresolved one');
  RESET ROLE;
END $$;


-- ---------------------------------------------------------------------------
-- Gas Detector Management (Prompt 13)
--
-- The registry widens WHAT is listed, never WHO may see it. Every assertion
-- below runs as a real role through the real policies.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n bigint; cols int;
BEGIN
  ---------------------------------------------------------------- viewer, East
  PERFORM pg_temp.become('clerk_view_east');

  SELECT count(*) INTO n FROM v_gas_detector_management WHERE detector_id IS NOT NULL;
  PERFORM pg_temp.ok(n = 2, 'GD-1 an East viewer sees only East detectors (2 of 3)');

  -- Naming the West row directly changes nothing: RLS filters, it does not hide.
  SELECT count(*) INTO n FROM v_gas_detector_management
   WHERE detector_id = 'e5700000-0000-0000-0000-0000000000f7';
  PERFORM pg_temp.ok(n = 0, 'GD-2 a West detector cannot be named directly by an East viewer (IDOR)');

  -- The same through the base table, in case a later view is added.
  SELECT count(*) INTO n FROM gas_detectors WHERE id = 'e5700000-0000-0000-0000-0000000000f7';
  PERFORM pg_temp.ok(n = 0, 'GD-3 nor through the gas_detectors table itself');

  -- Search is retrieval, not an authorization bypass.
  SELECT count(*) INTO n FROM v_gas_detector_management WHERE serial_number ILIKE '%TESTDATA-WEST-GD%';
  PERFORM pg_temp.ok(n = 0, 'GD-4 search cannot surface an unauthorized detector by serial');

  SELECT count(*) INTO n FROM v_gas_detector_management WHERE manufacturer ILIKE '%Draeger%';
  PERFORM pg_temp.ok(n = 0, 'GD-5 nor by manufacturer');

  SELECT count(*) INTO n FROM v_gas_detector_management WHERE station_name ILIKE '%WEST%';
  PERFORM pg_temp.ok(n = 0, 'GD-6 nor by station name');

  -- The count behind pagination is RLS-scoped too, so a total cannot leak the
  -- existence of a row the caller may not read.
  -- 2 East detector assets. The East presence row says 'installed', and the
  -- view's evidence branch emits only NON-installed presence, so it adds no
  -- second row for a station that already has a detector.
  SELECT count(*) INTO n FROM v_gas_detector_management;
  PERFORM pg_temp.ok(n = 2,
    'GD-7 the pagination total counts only authorized rows, and never double-counts an installed presence row');

  -- Filters narrow an authorized set; they never widen it.
  SELECT count(*) INTO n FROM v_gas_detector_management WHERE area_type = 'open';
  PERFORM pg_temp.ok(n = 0, 'GD-8 an Area Type filter cannot reach the West open-area row');

  SELECT count(*) INTO n FROM v_gas_detector_management WHERE detector_presence = 'not_installed';
  PERFORM pg_temp.ok(n = 0, 'GD-9 a Presence filter cannot reach West presence evidence');

  SELECT count(*) INTO n FROM v_gas_detector_management WHERE mapping_status = 'needs_unit_mapping';
  PERFORM pg_temp.ok(n = 1, 'GD-10 an unresolved East detector is visible to an authorized East reader');

  -- Detail expansion is the same query, so it leaks nothing extra.
  SELECT count(*) INTO n FROM v_gas_detector_management
   WHERE detector_id = 'e5700000-0000-0000-0000-0000000000f7' AND area_type_raw IS NOT NULL;
  PERFORM pg_temp.ok(n = 0, 'GD-11 expanding a detail cannot expose an unauthorized record');

  -- A viewer is read-only: hiding a control is not protection.
  --
  -- NOTE the shape. `authenticated` HOLDS the UPDATE grant on gas_detectors,
  -- so this raises no privilege error; the row simply fails the policy's
  -- USING clause and the statement matches nothing. Zero rows changed IS the
  -- security property, so that is what is asserted — an exception-only test
  -- here would have reported a false PASS for the wrong reason.
  UPDATE gas_detectors SET mapping_status = 'resolved'
   WHERE id = 'e5700000-0000-0000-0000-0000000000e8';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0,
    'GD-12 a viewer changes no row when resolving a mapping in their own region');

  RESET ROLE;

  --------------------------------------------------------------- engineer, East
  PERFORM pg_temp.become('clerk_eng_east');

  -- Same shape as GD-12: the West row fails the UPDATE policy's USING clause,
  -- so nothing is touched. Zero rows changed is the property that matters.
  UPDATE gas_detectors SET unit_id = 'e5700000-0000-0000-0000-0000000000f2'
   WHERE id = 'e5700000-0000-0000-0000-0000000000f7';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0, 'GD-13 an East engineer changes no row on a West detector');

  -- And the West detector is genuinely untouched, not merely invisible.
  RESET ROLE;
  SELECT count(*) INTO n FROM gas_detectors
   WHERE id = 'e5700000-0000-0000-0000-0000000000f7'
     AND unit_id = 'e5700000-0000-0000-0000-0000000000f2';
  PERFORM pg_temp.ok(n = 1,
    'GD-13b the West detector still carries its own Unit, unchanged by the attempt');
  PERFORM pg_temp.become('clerk_eng_east');

  SELECT count(*) INTO n FROM v_gas_detector_management WHERE region_name = 'West';
  PERFORM pg_temp.ok(n = 0, 'GD-14 an East engineer sees no West row through the management view');

  RESET ROLE;

  ------------------------------------------------------------------------ anon
  PERFORM pg_temp.become(NULL);
  SET LOCAL ROLE anon;
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM gas_detectors'),
    'GD-15 anon cannot read gas_detectors');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM gas_detector_presence'),
    'GD-16 anon cannot read gas_detector_presence');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_gas_detector_management'),
    'GD-17 anon cannot read the gas detector management view');
  RESET ROLE;
END $$;

-- Structural guarantees for the view the detector registry reads.
DO $$
DECLARE definer int; anon_grants int; write_grants int; nullable int; enum_has int;
BEGIN
  SELECT count(*) INTO definer
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relname = 'v_gas_detector_management'
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer = 0, 'GD-18 the gas detector management view is security_invoker');

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public' AND table_name = 'v_gas_detector_management';
  PERFORM pg_temp.ok(anon_grants = 0, 'GD-19 anon holds no grant on the gas detector management view');

  SELECT count(*) INTO write_grants
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'v_gas_detector_management'
     AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
     AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  PERFORM pg_temp.ok(write_grants = 0,
    format('GD-20 the read-only detector view cannot be written through (found %s)', write_grants));

  -- ------------------------------------------------------------------------
  -- MANDATORY canonical-compatibility check (prompt 13 section 9).
  --
  -- `asset_mapping_status` DEFINES needs_station_mapping, but gas_detectors
  -- cannot HOLD it: station_id is NOT NULL. Prompt 6 staged 219 detector rows
  -- in exactly that state, so this is a Prompt-21 import blocker, recorded
  -- here rather than worked around by relaxing the constraint.
  -- ------------------------------------------------------------------------
  SELECT count(*) INTO enum_has FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
   WHERE t.typname = 'asset_mapping_status' AND e.enumlabel = 'needs_station_mapping';
  PERFORM pg_temp.ok(enum_has = 1,
    'GD-21 asset_mapping_status defines needs_station_mapping');

  SELECT count(*) INTO nullable FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'gas_detectors'
     AND column_name = 'station_id' AND is_nullable = 'YES';
  PERFORM pg_temp.ok(nullable = 0,
    'GD-22 BLOCKER: gas_detectors.station_id is NOT NULL, so needs_station_mapping is unreachable (Prompt 21)');

  -- Proven by attempting it, not merely by reading the catalogue.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$INSERT INTO gas_detectors (station_id, region_id, mapping_status)
       SELECT NULL, id, 'needs_station_mapping' FROM regions LIMIT 1$q$),
    'GD-23 a station-unconfirmed detector is rejected by the not-null constraint');

  -- There is no equipment parent to resolve: a detector hangs off a Unit.
  SELECT count(*) INTO nullable FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'gas_detectors'
     AND column_name IN ('compressor_id', 'storage_vessel_id', 'dispenser_id');
  PERFORM pg_temp.ok(nullable = 0,
    'GD-24 a gas detector carries no equipment parent column, so it has no equipment mapping state');

  -- Area type is NOT a detector column. It classifies the AREA and lives on
  -- gas_detector_presence, so it must never be read as a detector attribute.
  SELECT count(*) INTO nullable FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'gas_detectors' AND column_name = 'area_type';
  PERFORM pg_temp.ok(nullable = 0, 'GD-25 area_type is not a column on gas_detectors');

  SELECT count(*) INTO nullable FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'gas_detector_presence' AND column_name = 'area_type';
  PERFORM pg_temp.ok(nullable = 1, 'GD-26 area_type lives on gas_detector_presence, describing the area');

  -- There is no detector location column anywhere, so none can be displayed.
  SELECT count(*) INTO nullable FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name IN ('gas_detectors', 'gas_detector_presence')
     AND column_name IN ('location', 'location_raw', 'position', 'placement');
  PERFORM pg_temp.ok(nullable = 0, 'GD-27 no detector location column exists in the schema');

  -- Live telemetry is not in this schema and must not be invented in the UI.
  SELECT count(*) INTO nullable FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'gas_detectors'
     AND column_name IN ('reading', 'concentration', 'alarm_state', 'is_online',
                         'battery_level', 'sensor_health', 'last_seen_at');
  PERFORM pg_temp.ok(nullable = 0, 'GD-28 gas_detectors stores no live telemetry field');

  -- Mapping attribution is still forgeable and unaudited, which is why the
  -- mapping mutation UI stays deferred (prompt 13 section 26).
  SELECT count(*) INTO nullable FROM pg_trigger
   WHERE tgrelid = 'gas_detectors'::regclass AND NOT tgisinternal
     AND tgname ILIKE '%audit%';
  PERFORM pg_temp.ok(nullable = 0,
    'GD-29 gas_detectors has no audit trigger, so mapping attribution is not yet trustworthy');
END $$;

-- The Prompt-10 Unit tab must keep its Unit scoping: the global registry
-- widening must not have relaxed it.
DO $$
DECLARE n bigint;
BEGIN
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM v_gas_detector_management
   WHERE unit_id IS NULL AND mapping_status = 'resolved';
  PERFORM pg_temp.ok(n = 0,
    'GD-30 a resolved detector always carries a confirmed Unit, so a Unit tab cannot show an unresolved one');
  RESET ROLE;
END $$;


-- ---------------------------------------------------------------------------
-- Hoses Management (Prompt 14)
--
-- The registry widens WHAT is listed, never WHO may see it. Every assertion
-- below runs as a real role through the real policies.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n bigint; cols int;
BEGIN
  ---------------------------------------------------------------- viewer, East
  PERFORM pg_temp.become('clerk_view_east');

  SELECT count(*) INTO n FROM v_hose_registry;
  PERFORM pg_temp.ok(n = 4, 'HOSE-1 an East viewer sees only the 4 East hoses, not the 2 West ones');

  -- Naming the West row directly changes nothing: RLS filters, it does not hide.
  SELECT count(*) INTO n FROM v_hose_registry WHERE id = 'e5700000-0000-0000-0000-0000000000f9';
  PERFORM pg_temp.ok(n = 0, 'HOSE-2 a West hose cannot be named directly by an East viewer (IDOR)');

  SELECT count(*) INTO n FROM hoses WHERE id = 'e5700000-0000-0000-0000-0000000000f9';
  PERFORM pg_temp.ok(n = 0, 'HOSE-3 nor through the hoses table itself');

  -- Search is retrieval, not an authorization bypass.
  SELECT count(*) INTO n FROM v_hose_registry WHERE serial_number ILIKE '%TESTDATA-WEST-HOSE%';
  PERFORM pg_temp.ok(n = 0, 'HOSE-4 search cannot surface an unauthorized hose by serial');

  SELECT count(*) INTO n FROM v_hose_registry WHERE description ILIKE '%west hose%';
  PERFORM pg_temp.ok(n = 0, 'HOSE-5 nor by description');

  SELECT count(*) INTO n FROM v_hose_registry WHERE station_name ILIKE '%WEST%';
  PERFORM pg_temp.ok(n = 0, 'HOSE-6 nor by station name');

  -- The count behind pagination is RLS-scoped too.
  SELECT count(*) INTO n FROM v_hose_registry WHERE mapping_status = 'needs_unit_mapping';
  PERFORM pg_temp.ok(n = 3, 'HOSE-7 a filtered count counts only authorized rows');

  -- Filters narrow an authorized set; they never widen it.
  SELECT count(*) INTO n FROM v_hose_registry WHERE serial_missing;
  PERFORM pg_temp.ok(n = 1, 'HOSE-8 the missing-serial filter reaches only East rows');

  -- THE ONE THAT MATTERS MOST FOR THIS FEATURE.
  --
  -- 'TESTDATA-CROSS-DUP' exists once in East and once in West. If the duplicate
  -- flag were computed over the whole table, an East viewer would be told their
  -- hose is a duplicate - disclosing that a West record they may not read
  -- exists. Because the view is security_invoker, the window function sees only
  -- this caller's rows, so the flag is correctly FALSE. A narrower, honest
  -- signal beats a complete one that leaks.
  SELECT count(*) INTO n FROM v_hose_registry
   WHERE serial_number = 'TESTDATA-CROSS-DUP' AND serial_duplicate;
  PERFORM pg_temp.ok(n = 0,
    'HOSE-9 a cross-region serial collision is NOT reported as a duplicate, so it cannot leak the other region''s row');

  SELECT count(*) INTO n FROM v_hose_registry WHERE serial_number = 'TESTDATA-CROSS-DUP';
  PERFORM pg_temp.ok(n = 1, 'HOSE-10 and the East viewer sees only their own copy of that serial');

  -- Detail expansion is the same query, so it leaks nothing extra.
  SELECT count(*) INTO n FROM v_hose_registry
   WHERE id = 'e5700000-0000-0000-0000-0000000000f9' AND source_file IS NOT NULL;
  PERFORM pg_temp.ok(n = 0, 'HOSE-11 expanding a detail cannot expose an unauthorized record''s provenance');

  -- A viewer is read-only. NOTE: authenticated HOLDS the UPDATE grant, so this
  -- raises no privilege error - the row fails the policy's USING clause and
  -- nothing matches. Zero rows changed IS the security property.
  UPDATE hoses SET mapping_status = 'resolved'
   WHERE id = 'e5700000-0000-0000-0000-0000000000ea';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0,
    'HOSE-12 a viewer changes no row when resolving a mapping in their own region');

  RESET ROLE;

  --------------------------------------------------------------- engineer, East
  PERFORM pg_temp.become('clerk_eng_east');

  UPDATE hoses SET unit_id = 'e5700000-0000-0000-0000-0000000000f2'
   WHERE id = 'e5700000-0000-0000-0000-0000000000f9';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0, 'HOSE-13 an East engineer changes no row on a West hose');

  RESET ROLE;
  SELECT count(*) INTO n FROM hoses
   WHERE id = 'e5700000-0000-0000-0000-0000000000f9'
     AND unit_id = 'e5700000-0000-0000-0000-0000000000f2';
  PERFORM pg_temp.ok(n = 1,
    'HOSE-14 the West hose still carries its own Unit, unchanged by the attempt');

  ---------------------------------------------------------------- viewer, West
  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM v_hose_registry WHERE region_name = 'West';
  PERFORM pg_temp.ok(n = 0, 'HOSE-15 no West row reaches an East reader through the registry view');
  RESET ROLE;

  ------------------------------------------------------------------------ anon
  PERFORM pg_temp.become(NULL);
  SET LOCAL ROLE anon;
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM hoses'),
    'HOSE-16 anon cannot read hoses');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_hose_registry'),
    'HOSE-17 anon cannot read the hose registry view');
  RESET ROLE;
END $$;

-- An admin sees the whole picture, which is what makes HOSE-9 a scoping result
-- rather than an accident of the fixture.
DO $$
DECLARE n bigint;
BEGIN
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM v_hose_registry WHERE serial_number = 'TESTDATA-CROSS-DUP' AND serial_duplicate;
  PERFORM pg_temp.ok(n = 2,
    'HOSE-18 an admin, who may read both regions, DOES see the collision reported as a duplicate');

  -- The Prompt-10 Unit tab must keep its Unit scoping.
  SELECT count(*) INTO n FROM v_hose_registry WHERE unit_id IS NULL AND mapping_status = 'resolved';
  PERFORM pg_temp.ok(n = 0,
    'HOSE-19 a resolved hose always carries a confirmed Unit, so a Unit tab cannot show an unresolved one');
  RESET ROLE;
END $$;

-- Structural guarantees for the view the registry reads.
DO $$
DECLARE definer int; anon_grants int; write_grants int; uniq int;
BEGIN
  SELECT count(*) INTO definer
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relname = 'v_hose_registry'
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer = 0, 'HOSE-20 the hose registry view is security_invoker');

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public' AND table_name = 'v_hose_registry';
  PERFORM pg_temp.ok(anon_grants = 0, 'HOSE-21 anon holds no grant on the hose registry view');

  SELECT count(*) INTO write_grants
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'v_hose_registry'
     AND grantee IN ('anon', 'authenticated', 'service_role', 'PUBLIC')
     AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE');
  PERFORM pg_temp.ok(write_grants = 0,
    format('HOSE-22 the read-only hose view cannot be written through (found %s)', write_grants));

  -- The Prompt-10 view is untouched and still serves the Unit tab.
  PERFORM pg_temp.ok(
    EXISTS (SELECT 1 FROM pg_views WHERE schemaname = 'public' AND viewname = 'v_hose_management'),
    'HOSE-23 v_hose_management still exists unchanged for the Unit Hoses tab');

  -- No UNIQUE constraint was added on serial_number.
  SELECT count(*) INTO uniq FROM pg_indexes
   WHERE tablename = 'hoses' AND indexdef ILIKE '%UNIQUE%' AND indexdef ILIKE '%serial_number%';
  PERFORM pg_temp.ok(uniq = 0,
    'HOSE-24 no UNIQUE constraint was added on hose serial_number');

  -- Mapping attribution is still forgeable and unaudited, which is why the
  -- mapping mutation UI stays deferred (prompt 14 section 24).
  SELECT count(*) INTO uniq FROM pg_trigger
   WHERE tgrelid = 'hoses'::regclass AND NOT tgisinternal AND tgname ILIKE '%audit%';
  PERFORM pg_temp.ok(uniq = 0,
    'HOSE-25 hoses has no audit trigger, so mapping attribution is not yet trustworthy');
END $$;


-- ---------------------------------------------------------------------------
-- Alerts (Prompt 15)
--
-- Three separate things are proved here: region scoping of alerts, the
-- admin/manager-only rule for station-unconfirmed rows, and the fact that
-- per-user state (read, delivery) is genuinely per-user.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n bigint; v_ack timestamptz; v_by uuid;
BEGIN
  ---------------------------------------------------------------- viewer, East
  PERFORM pg_temp.become('clerk_view_east');

  SELECT count(*) INTO n FROM v_alert_inbox;
  PERFORM pg_temp.ok(n = 1,
    'ALRT-1 an East viewer sees only the East alert - not West, and not the station-unconfirmed one');

  SELECT count(*) INTO n FROM v_alert_inbox WHERE id = 'e5700000-0000-0000-0000-0000000000d2';
  PERFORM pg_temp.ok(n = 0, 'ALRT-2 a West alert cannot be named directly by an East viewer (IDOR)');

  SELECT count(*) INTO n FROM alerts WHERE id = 'e5700000-0000-0000-0000-0000000000d2';
  PERFORM pg_temp.ok(n = 0, 'ALRT-3 nor through the alerts table itself');

  -- THE INFORMATION-LEAK CASE. The raw source name looks like an East station
  -- and region_id says East, but neither is permission: raw source text is
  -- evidence (CLAUDE.md §10). An engineer or viewer must not see it.
  SELECT count(*) INTO n FROM v_alert_inbox WHERE id = 'e5700000-0000-0000-0000-0000000000d3';
  PERFORM pg_temp.ok(n = 0,
    'ALRT-4 a station-unconfirmed alert is invisible to a regional viewer, despite its East region_id');

  SELECT count(*) INTO n FROM v_alert_inbox WHERE source_station_name_raw IS NOT NULL;
  PERFORM pg_temp.ok(n = 0, 'ALRT-5 and its raw source station name never leaks through the view');

  SELECT count(*) INTO n FROM v_alert_inbox WHERE station_name ILIKE '%WEST%';
  PERFORM pg_temp.ok(n = 0, 'ALRT-6 search by station name cannot surface an unauthorized alert');

  SELECT count(*) INTO n FROM v_alert_inbox WHERE threshold = 'overdue';
  PERFORM pg_temp.ok(n = 0, 'ALRT-7 a threshold filter cannot reach the West overdue alert');

  -- Counts are RLS-scoped, so a total cannot betray a row the caller may not read.
  SELECT count(*) INTO n FROM v_alert_inbox WHERE due_date IS NOT NULL;
  PERFORM pg_temp.ok(n = 1, 'ALRT-8 the pagination total counts only authorized alerts');

  -- Per-user state really is per-user.
  SELECT count(*) INTO n FROM v_alert_inbox WHERE is_read;
  PERFORM pg_temp.ok(n = 1, 'ALRT-9 the viewer sees their OWN read state');

  SELECT count(*) INTO n FROM v_alert_inbox WHERE email_status = 'failed';
  PERFORM pg_temp.ok(n = 1, 'ALRT-10 and their own delivery failure, which does not remove the alert');

  -- A delivery failure never deletes or alters the alert it belongs to.
  SELECT count(*) INTO n FROM v_alert_inbox
   WHERE id = 'e5700000-0000-0000-0000-0000000000d1' AND email_status = 'failed';
  PERFORM pg_temp.ok(n = 1,
    'ALRT-11 an alert whose delivery failed is still fully present - failure is not absence');

  -- Direct table writes are impossible. This is NOT free: migration 0019 had
  -- granted UPDATE on (state, acknowledged_by, acknowledged_at, resolved_at) at
  -- COLUMN level, which `information_schema.role_table_grants` does not show,
  -- and an engineer could attribute an acknowledgement to an admin with a
  -- backdated timestamp. Migration 0033 revoked it, so the definer function is
  -- now the only path. This assertion is what stops that regressing.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE alerts SET acknowledged_by = 'a0000000-0000-0000-0000-00000000000a',
                         acknowledged_at = now()
        WHERE id = 'e5700000-0000-0000-0000-0000000000d1'$q$),
    'ALRT-12 a client cannot write acknowledged_by directly - there is no UPDATE grant on alerts');

  -- A viewer may not acknowledge: the function re-checks WRITE authorization.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_acknowledge_alert('e5700000-0000-0000-0000-0000000000d1')$q$),
    'ALRT-13 a viewer cannot acknowledge, because the function requires write authorization');

  -- Nor can they mark an alert they cannot see as read.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_mark_alert_read('e5700000-0000-0000-0000-0000000000d2')$q$),
    'ALRT-14 marking an unauthorized alert read fails, and reports "not found" rather than confirming it exists');

  RESET ROLE;

  --------------------------------------------------------------- engineer, East
  PERFORM pg_temp.become('clerk_eng_east');

  SELECT count(*) INTO n FROM v_alert_inbox WHERE id = 'e5700000-0000-0000-0000-0000000000d3';
  PERFORM pg_temp.ok(n = 0,
    'ALRT-15 an East ENGINEER also cannot see the station-unconfirmed alert');

  -- The engineer CAN acknowledge in their own region, and the actor is stamped
  -- by the server rather than supplied.
  PERFORM cng_acknowledge_alert('e5700000-0000-0000-0000-0000000000d1');
  RESET ROLE;
  SELECT acknowledged_by, acknowledged_at INTO v_by, v_ack
    FROM alerts WHERE id = 'e5700000-0000-0000-0000-0000000000d1';
  PERFORM pg_temp.ok(v_by = 'a0000000-0000-0000-0000-00000000000c' AND v_ack IS NOT NULL,
    'ALRT-16 acknowledgement records the SERVER-derived acting user, not a client-supplied one');

  -- Re-acknowledging by a DIFFERENT user must not reattribute the record.
  PERFORM pg_temp.become('clerk_admin');
  PERFORM cng_acknowledge_alert('e5700000-0000-0000-0000-0000000000d1');
  RESET ROLE;
  SELECT acknowledged_by INTO v_by FROM alerts WHERE id = 'e5700000-0000-0000-0000-0000000000d1';
  PERFORM pg_temp.ok(v_by = 'a0000000-0000-0000-0000-00000000000c',
    'ALRT-17 a second acknowledgement does not overwrite the first actor');

  -- An East engineer cannot acknowledge a West alert.
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_acknowledge_alert('e5700000-0000-0000-0000-0000000000d2')$q$),
    'ALRT-18 an East engineer cannot acknowledge a West alert');
  RESET ROLE;

  ------------------------------------------------------- admin sees the unmapped
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM v_alert_inbox WHERE id = 'e5700000-0000-0000-0000-0000000000d3';
  PERFORM pg_temp.ok(n = 1,
    'ALRT-19 an admin DOES see the station-unconfirmed alert, so ALRT-4 is scoping and not an accident');

  SELECT count(*) INTO n FROM v_alert_inbox
   WHERE id = 'e5700000-0000-0000-0000-0000000000d3' AND source_station_name_raw = 'TESTDATA-EAST-STATION';
  PERFORM pg_temp.ok(n = 1,
    'ALRT-20 and the admin sees its raw source station name, which is what makes it resolvable');

  -- An admin's own read state is their own: the viewer's read row is not theirs.
  SELECT count(*) INTO n FROM v_alert_inbox WHERE is_read;
  PERFORM pg_temp.ok(n = 0,
    'ALRT-21 read state is PER-USER: the viewer having read an alert does not mark it read for the admin');

  -- Nor does the admin inherit the viewer's delivery record.
  SELECT count(*) INTO n FROM v_alert_inbox WHERE email_status IS NOT NULL;
  PERFORM pg_temp.ok(n = 0,
    'ALRT-22 one user''s delivery outcome is never visible as another''s');
  RESET ROLE;

  -------------------------------------------------- cross-user state tampering
  PERFORM pg_temp.become('clerk_eng_east');
  -- Writing a read row for ANOTHER user must change nothing. RLS filters the
  -- WITH CHECK, so this is a policy violation rather than a silent success.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$INSERT INTO alert_reads (alert_id, app_user_id)
       VALUES ('e5700000-0000-0000-0000-0000000000d1','a0000000-0000-0000-0000-00000000000a')$q$),
    'ALRT-23 a user cannot create read state on behalf of another user');

  SELECT count(*) INTO n FROM alert_reads;
  PERFORM pg_temp.ok(n = 0,
    'ALRT-24 and cannot READ another user''s read state either');

  DELETE FROM alert_reads WHERE app_user_id = 'a0000000-0000-0000-0000-00000000000e';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0,
    'ALRT-25 deleting another user''s read state changes zero rows');

  SELECT count(*) INTO n FROM notification_deliveries;
  PERFORM pg_temp.ok(n = 0,
    'ALRT-26 a user cannot read another user''s delivery records, including provider error text');

  -- Push subscriptions are per-user too.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$INSERT INTO push_subscriptions (app_user_id, endpoint, p256dh, auth)
       VALUES ('a0000000-0000-0000-0000-00000000000a','https://x.test/1','k','a')$q$),
    'ALRT-27 a user cannot register a push subscription for another user');
  RESET ROLE;

  ------------------------------------------------------------------------ anon
  PERFORM pg_temp.become(NULL);
  SET LOCAL ROLE anon;
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM alerts'),
    'ALRT-28 anon cannot read alerts');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_alert_inbox'),
    'ALRT-29 anon cannot read the alert inbox view');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM alert_reads'),
    'ALRT-30 anon cannot read alert read state');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM notification_deliveries'),
    'ALRT-31 anon cannot read delivery records');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_acknowledge_alert('e5700000-0000-0000-0000-0000000000d1')$q$),
    'ALRT-32 anon cannot acknowledge');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT cng_generate_alerts()'),
    'ALRT-33 anon cannot run alert generation');
  RESET ROLE;
END $$;

-- Structural guarantees.
DO $$
DECLARE definer int; anon_grants int; write_grants int; upd int;
BEGIN
  SELECT count(*) INTO definer
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relname = 'v_alert_inbox'
     AND NOT coalesce((c.reloptions::text LIKE '%security_invoker=true%'), false);
  PERFORM pg_temp.ok(definer = 0, 'ALRT-34 the alert inbox view is security_invoker');

  SELECT count(*) INTO anon_grants
    FROM information_schema.role_table_grants
   WHERE grantee = 'anon' AND table_schema = 'public'
     AND table_name IN ('v_alert_inbox','alerts','alert_reads','notification_deliveries');
  PERFORM pg_temp.ok(anon_grants = 0, 'ALRT-35 anon holds no grant on any alert object');

  SELECT count(*) INTO write_grants
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'v_alert_inbox'
     AND grantee IN ('anon','authenticated','service_role','PUBLIC')
     AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
  PERFORM pg_temp.ok(write_grants = 0,
    format('ALRT-36 the read-only inbox view cannot be written through (found %s)', write_grants));

  -- THE KEY STRUCTURAL FACT behind non-forgeable attribution: there is no
  -- UPDATE grant on `alerts` for `authenticated`, so the definer function is
  -- the ONLY path by which an alert can become acknowledged.
  -- COLUMN grants, not table grants. The table-level view is exactly what hid
  -- the original hole, so this checks the level the hole actually lived at.
  SELECT count(*) INTO upd
    FROM information_schema.role_column_grants
   WHERE table_schema = 'public' AND table_name = 'alerts'
     AND grantee = 'authenticated' AND privilege_type IN ('UPDATE','INSERT','DELETE');
  PERFORM pg_temp.ok(upd = 0,
    format('ALRT-37 authenticated holds no write privilege on ANY alerts column, so acknowledgement can only happen through the audited function (found %s)', upd));

  -- service_role gained EXECUTE on generation and nothing more.
  PERFORM pg_temp.ok(
    has_function_privilege('service_role','cng_generate_alerts(date)','EXECUTE')
    AND NOT has_function_privilege('authenticated','cng_generate_alerts(date)','EXECUTE'),
    'ALRT-38 only service_role may generate alerts');

  -- The generation function reads assets, so it must not be callable by anon.
  PERFORM pg_temp.ok(NOT has_function_privilege('anon','cng_generate_alerts(date)','EXECUTE'),
    'ALRT-39 anon holds no EXECUTE on alert generation');

  -- Read-state functions are reachable by users and nobody else.
  PERFORM pg_temp.ok(
    has_function_privilege('authenticated','cng_mark_alert_read(uuid)','EXECUTE')
    AND NOT has_function_privilege('anon','cng_mark_alert_read(uuid)','EXECUTE'),
    'ALRT-40 read-state functions are granted to authenticated only');
END $$;


-- ---------------------------------------------------------------------------
-- Push subscriptions and delivery isolation (Prompt 15.1)
-- ---------------------------------------------------------------------------
DO $$
DECLARE n bigint; v_id uuid;
BEGIN
  PERFORM pg_temp.become('clerk_eng_east');

  -- Saving a subscription attributes it to the CALLER, with no way to name
  -- another user: the function takes no user parameter at all.
  v_id := cng_save_push_subscription('https://push.test/eng-east', 'P256', 'AUTH', 'test-agent');
  PERFORM pg_temp.ok(v_id IS NOT NULL, 'PUSH-1 a user can register their own push subscription');

  RESET ROLE;
  SELECT count(*) INTO n FROM push_subscriptions
   WHERE endpoint = 'https://push.test/eng-east'
     AND app_user_id = 'a0000000-0000-0000-0000-00000000000c';
  PERFORM pg_temp.ok(n = 1,
    'PUSH-2 the subscription is attributed to the SERVER-derived caller, not a supplied id');

  -- Re-registering the same endpoint updates in place rather than duplicating.
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM cng_save_push_subscription('https://push.test/eng-east', 'P256-NEW', 'AUTH-NEW', 'test-agent-2');
  RESET ROLE;
  SELECT count(*) INTO n FROM push_subscriptions WHERE endpoint = 'https://push.test/eng-east';
  PERFORM pg_temp.ok(n = 1, 'PUSH-3 re-subscribing the same endpoint updates rather than duplicating');

  -- Another user cannot see, hijack or delete it.
  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM push_subscriptions;
  PERFORM pg_temp.ok(n = 0, 'PUSH-4 a user cannot read another user''s push subscription or its key material');

  -- Claiming someone else's endpoint must not reassign it. RLS makes the
  -- UPDATE match nothing, and the INSERT then violates the endpoint unique
  -- constraint, so the attempt fails rather than silently stealing the row.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_save_push_subscription('https://push.test/eng-east','X','Y','ua')$q$),
    'PUSH-5 a user cannot take over another user''s existing push endpoint');

  RESET ROLE;
  SELECT count(*) INTO n FROM push_subscriptions
   WHERE endpoint = 'https://push.test/eng-east'
     AND app_user_id = 'a0000000-0000-0000-0000-00000000000c';
  PERFORM pg_temp.ok(n = 1, 'PUSH-6 and the original owner still holds it');

  PERFORM pg_temp.become('clerk_view_east');
  DELETE FROM push_subscriptions WHERE endpoint = 'https://push.test/eng-east';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0, 'PUSH-7 deleting another user''s subscription changes zero rows');
  RESET ROLE;

  ------------------------------------------------------------------------ anon
  PERFORM pg_temp.become(NULL);
  SET LOCAL ROLE anon;
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_save_push_subscription('https://push.test/anon','X','Y','ua')$q$),
    'PUSH-8 anon cannot register a push subscription');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM push_subscriptions'),
    'PUSH-9 anon cannot read push subscriptions');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_enqueue_alert_deliveries('email')$q$),
    'PUSH-10 anon cannot enqueue deliveries');
  RESET ROLE;
END $$;

-- A signed-in user must not be able to drive sending: that would be an open
-- mail relay behind a login.
DO $$
BEGIN
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_enqueue_alert_deliveries('email')$q$),
    'PUSH-11 not even an ADMIN may enqueue deliveries from the client');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_next_pending_deliveries('email', 10)$q$),
    'PUSH-12 nor claim pending deliveries, which would expose recipient addresses');
  RESET ROLE;
END $$;

-- ===========================================================================
-- WEB PUSH DELIVERY (migration 0035).
--
-- The whole security argument for server-side push is that NO browser role can
-- reach any of it. If a signed-in user could execute these, they could
-- enumerate other users' endpoints and key material, or send to them.
-- ===========================================================================
DO $$
DECLARE n integer;
BEGIN
  ---------------------------------------------------------------- authenticated
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_next_pending_push_deliveries(10)$q$),
    'WPUSH-1 a signed-in user cannot claim push deliveries or read endpoint key material');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_test_push_targets('admin@example.test')$q$),
    'WPUSH-2 a signed-in user cannot look up another user''s push targets');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_deactivate_push_subscription('https://push.test/eng-east')$q$),
    'WPUSH-3 a signed-in user cannot deactivate a subscription out of band');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_record_push_endpoint_result('https://push.test/eng-east', false)$q$),
    'WPUSH-4 a signed-in user cannot forge a delivery outcome');
  RESET ROLE;

  ----------------------------------------------------------------------- admin
  -- Being an administrator is not a sending capability.
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_next_pending_push_deliveries(10)$q$),
    'WPUSH-5 not even an ADMIN may claim push deliveries');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_test_push_targets('admin@example.test')$q$),
    'WPUSH-6 not even an ADMIN may resolve push targets');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_deactivate_push_subscription('https://push.test/eng-east')$q$),
    'WPUSH-7 not even an ADMIN may deactivate a subscription');
  RESET ROLE;

  ------------------------------------------------------------------------ anon
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_next_pending_push_deliveries(10)$q$),
    'WPUSH-8 anon cannot claim push deliveries');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_test_push_targets('admin@example.test')$q$),
    'WPUSH-9 anon cannot resolve push targets');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_record_push_endpoint_result('https://push.test/eng-east', true)$q$),
    'WPUSH-10 anon cannot record a push outcome');
  RESET ROLE;
END $$;

-- The sender's own behaviour, as service_role. These are the rules that decide
-- whether a real user silently stops receiving notifications.
--
-- Note the shape of every step: the CALL runs as service_role, the VERIFICATION
-- reads as superuser. That is not test convenience — service_role holds no
-- SELECT on push_subscriptions at all, so the sender can only ever touch
-- subscriptions through the four narrow functions. WPUSH-11 asserts it.
DO $$
DECLARE
  v_user   uuid;
  v_other  uuid;
  n        integer;
  v_active boolean;
  v_fail   integer;
  v_email  text;
BEGIN
  SELECT id INTO v_user  FROM app_users WHERE clerk_user_id = 'clerk_eng_east';
  SELECT id INTO v_other FROM app_users WHERE clerk_user_id = 'clerk_admin';
  -- The shared fixtures carry no email, so give this persona one. It stands in
  -- for CNG_ALERT_TEST_RECIPIENT, which in production is an Edge Function
  -- secret and never a value from a request.
  v_email := 'testdata-push@example.test';
  UPDATE app_users SET email = v_email WHERE id = v_user;

  INSERT INTO push_subscriptions (app_user_id, endpoint, p256dh, auth)
  VALUES (v_user,  'https://push.test/wp-a', 'PA', 'AA'),
         (v_user,  'https://push.test/wp-b', 'PB', 'AB'),
         (v_other, 'https://push.test/wp-c', 'PC', 'AC');

  SET LOCAL ROLE service_role;
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM push_subscriptions'),
    'WPUSH-11 the SENDER role cannot read push_subscriptions directly -- only through the four functions');
  RESET ROLE;

  -- A TRANSIENT failure must never unsubscribe anyone.
  SET LOCAL ROLE service_role;
  PERFORM cng_record_push_endpoint_result('https://push.test/wp-a', false);
  RESET ROLE;
  SELECT is_active, failure_count INTO v_active, v_fail
    FROM push_subscriptions WHERE endpoint = 'https://push.test/wp-a';
  PERFORM pg_temp.ok(v_active AND v_fail = 1,
    'WPUSH-12 a transient failure records itself and leaves the subscription ACTIVE');

  -- A success clears the failure count rather than letting it creep upward.
  SET LOCAL ROLE service_role;
  PERFORM cng_record_push_endpoint_result('https://push.test/wp-a', true);
  RESET ROLE;
  SELECT is_active, failure_count INTO v_active, v_fail
    FROM push_subscriptions WHERE endpoint = 'https://push.test/wp-a';
  PERFORM pg_temp.ok(v_active AND v_fail = 0, 'WPUSH-13 a success resets the failure count');

  -- 404/410 is the only path to deactivation, and it is a soft state change.
  SET LOCAL ROLE service_role;
  PERFORM cng_deactivate_push_subscription('https://push.test/wp-a');
  RESET ROLE;
  SELECT is_active INTO v_active FROM push_subscriptions WHERE endpoint = 'https://push.test/wp-a';
  PERFORM pg_temp.ok(NOT v_active, 'WPUSH-14 a gone subscription is deactivated');
  SELECT count(*) INTO n FROM push_subscriptions WHERE endpoint = 'https://push.test/wp-a';
  PERFORM pg_temp.ok(n = 1, 'WPUSH-15 and is NOT deleted -- the owner keeps the record');

  -- One endpoint at a time. A stale row must not take the user's other browser
  -- down with it.
  SELECT is_active INTO v_active FROM push_subscriptions WHERE endpoint = 'https://push.test/wp-b';
  PERFORM pg_temp.ok(v_active,
    'WPUSH-16 deactivating one endpoint leaves the user''s other browsers active');

  -- The controlled test resolves targets from the stored account only, and
  -- never reaches an inactive subscription or another user's.
  SET LOCAL ROLE service_role;
  -- Asserted by MEMBERSHIP, not by a total: this persona also owns a
  -- subscription created earlier in the suite, and a bare count would silently
  -- track that instead of the rule under test.
  SELECT count(*) INTO n FROM cng_test_push_targets(v_email)
    WHERE endpoint = 'https://push.test/wp-a';
  PERFORM pg_temp.ok(n = 0, 'WPUSH-17 test targets exclude a DEACTIVATED endpoint');
  SELECT count(*) INTO n FROM cng_test_push_targets(v_email)
    WHERE endpoint = 'https://push.test/wp-b';
  PERFORM pg_temp.ok(n = 1, 'WPUSH-17b and include the user''s live one');
  SELECT count(*) INTO n FROM cng_test_push_targets(v_email)
    WHERE endpoint = 'https://push.test/wp-c';
  PERFORM pg_temp.ok(n = 0, 'WPUSH-18 test targets never include another user''s subscription');
  SELECT count(*) INTO n FROM cng_test_push_targets('nobody@example.test');
  PERFORM pg_temp.ok(n = 0,
    'WPUSH-19 an address with no account resolves to nothing rather than erroring open');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_test_push_targets('')$q$),
    'WPUSH-20 an empty test recipient is refused');
  RESET ROLE;
END $$;

-- A push delivery failure must leave the ALERT exactly as it was. This is the
-- Alert/Delivery separation, asserted on the push channel.
DO $$
DECLARE
  v_alert  uuid;
  v_user   uuid;
  v_del    uuid;
  v_state  alert_state;
  v_ack    uuid;
  n        integer;
BEGIN
  SELECT id INTO v_user FROM app_users WHERE clerk_user_id = 'clerk_eng_east';
  SELECT id INTO v_alert FROM alerts LIMIT 1;
  IF v_alert IS NULL THEN
    PERFORM pg_temp.ok(false, 'WPUSH-21 fixture alert missing');
    RETURN;
  END IF;

  INSERT INTO notification_deliveries (alert_id, app_user_id, channel, status)
  VALUES (v_alert, v_user, 'web_push', 'pending')
  ON CONFLICT (alert_id, app_user_id, channel) DO UPDATE SET status = 'pending'
  RETURNING id INTO v_del;

  SET LOCAL ROLE service_role;
  PERFORM cng_record_delivery_result(v_del, 'failed', NULL, 'webpush:http_500');
  RESET ROLE;

  SELECT state, acknowledged_by INTO v_state, v_ack FROM alerts WHERE id = v_alert;
  PERFORM pg_temp.ok(v_state = 'open' AND v_ack IS NULL,
    'WPUSH-21 a failed push leaves the alert open and un-acknowledged');
  SELECT count(*) INTO n FROM alerts WHERE id = v_alert;
  PERFORM pg_temp.ok(n = 1, 'WPUSH-22 and does not delete or duplicate it');

  -- Retry targets the SAME delivery row: web_push cannot duplicate a send.
  SELECT count(*) INTO n FROM notification_deliveries
   WHERE alert_id = v_alert AND app_user_id = v_user AND channel = 'web_push';
  PERFORM pg_temp.ok(n = 1,
    'WPUSH-23 a retry updates the same delivery row rather than creating a second');

  -- And email for the same alert is a SEPARATE delivery, not a shared one.
  INSERT INTO notification_deliveries (alert_id, app_user_id, channel, status)
  VALUES (v_alert, v_user, 'email', 'pending')
  ON CONFLICT (alert_id, app_user_id, channel) DO NOTHING;
  SELECT count(*) INTO n FROM notification_deliveries
   WHERE alert_id = v_alert AND app_user_id = v_user;
  PERFORM pg_temp.ok(n = 2,
    'WPUSH-24 email and web_push are distinct channels for the same alert');
END $$;

-- ===========================================================================
-- PROMPT 16-18 RECONCILIATION (migration 0036).
--
-- "Mark all as read" is the one bulk action in the notification stack, so the
-- two things it must never do are exactly what these assert: reach beyond the
-- caller's Regions, and acknowledge anything.
-- ===========================================================================
DO $$
DECLARE
  v_eng    uuid;
  v_alert  uuid;
  n        integer;
  v_ack_before  integer;
  v_open_before integer;
BEGIN
  SELECT id INTO v_eng FROM app_users WHERE clerk_user_id = 'clerk_eng_east';
  -- Snapshot BEFORE, because earlier scenarios in this suite legitimately
  -- acknowledge alerts. An absolute count would measure the suite, not the
  -- action under test.
  SELECT count(*) INTO v_ack_before FROM alerts WHERE acknowledged_at IS NOT NULL;
  SELECT count(*) INTO v_open_before FROM alerts WHERE state = 'open';

  ----------------------------------------------------------------------- anon
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied('SELECT cng_mark_all_alerts_read()'),
    'RECON-1 anon cannot mark alerts read');
  RESET ROLE;

  -------------------------------------------------------------- authenticated
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM cng_mark_all_alerts_read();
  RESET ROLE;
  -- Verified as superuser: the fixture table and every region are visible here,
  -- so the assertion sees what the ENGINEER could not.
  -- Bounded by alerts_select: an East engineer can only have read East alerts.
  SELECT count(*) INTO n
    FROM alert_reads ar
    JOIN alerts a ON a.id = ar.alert_id
    JOIN stations s ON s.id = a.station_id
   WHERE ar.app_user_id = v_eng
     AND s.region_id <> (SELECT r_east FROM f);
  PERFORM pg_temp.ok(n = 0,
    'RECON-2 mark-all-read never marks an alert outside the caller''s Regions');

  -- READ IS NOT ACKNOWLEDGEMENT. The bulk action must leave every alert
  -- un-acknowledged and in its original state.
  SELECT count(*) INTO n FROM alerts WHERE acknowledged_at IS NOT NULL;
  PERFORM pg_temp.ok(n = v_ack_before, 'RECON-3 mark-all-read acknowledges nothing');
  SELECT count(*) INTO n FROM alerts WHERE state = 'open';
  PERFORM pg_temp.ok(n = v_open_before, 'RECON-4 and changes no alert state');

  -- Another user's read state is untouched and unreadable.
  PERFORM pg_temp.become('clerk_eng_west');
  SELECT count(*) INTO n FROM alert_reads;
  PERFORM pg_temp.ok(n = 0,
    'RECON-5 one user''s bulk read never appears in another user''s read state');
  RESET ROLE;


  -- The widened delivery claim functions stay service_role only: they now carry
  -- serials and Region names, so a browser reaching them would be worse.
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_next_pending_deliveries('email', 5)$q$),
    'RECON-6 not even an ADMIN may claim email deliveries after the widening');
  PERFORM pg_temp.ok(pg_temp.denied($q$SELECT cng_next_pending_push_deliveries(5)$q$),
    'RECON-7 nor push deliveries');
  RESET ROLE;

  -- A user may manage their OWN preferences and nobody else's.
  PERFORM pg_temp.become('clerk_eng_east');
  INSERT INTO notification_preferences (app_user_id, channel, is_enabled)
  VALUES (v_eng, 'email', true);
  SELECT count(*) INTO n FROM notification_preferences;
  PERFORM pg_temp.ok(n = 1, 'RECON-8 a user sees only their own notification preferences');
  PERFORM pg_temp.ok(pg_temp.denied($q$
    INSERT INTO notification_preferences (app_user_id, channel, is_enabled)
    VALUES ((SELECT id FROM app_users WHERE clerk_user_id = 'clerk_admin'), 'email', true)$q$),
    'RECON-9 and cannot create a preference for another user');
  RESET ROLE;
END $$;

DO $$ BEGIN RAISE EXCEPTION 'RLS_SUITE_ROLLBACK'; END $$;
ROLLBACK;
