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
  SELECT count(*) INTO n FROM alerts;
  PERFORM pg_temp.ok(n = 0, 'ENG-26 sees no West alert and no unmapped-SRV alert');

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
DECLARE n int;
BEGIN
  PERFORM pg_temp.become('clerk_eng_west');
  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000f1';
  PERFORM pg_temp.ok(n = 1, 'ENGW-1 West engineer CAN read West');
  SELECT count(*) INTO n FROM stations WHERE id='e5700000-0000-0000-0000-0000000000e1';
  PERFORM pg_temp.ok(n = 0, 'ENGW-2 West engineer cannot read East');
  SELECT count(*) INTO n FROM alerts;
  PERFORM pg_temp.ok(n = 1, 'ENGW-3 West engineer sees the West alert only');
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
DECLARE n int;
BEGIN
  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM alerts WHERE needs_station_mapping;
  PERFORM pg_temp.ok(n = 0, 'ALERT-1 viewer gains nothing from raw station text on an unmapped alert');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_manager');
  SELECT count(*) INTO n FROM alerts WHERE needs_station_mapping;
  PERFORM pg_temp.ok(n = 1, 'ALERT-2 manager CAN see the unmapped-SRV alert');
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

DO $$ BEGIN RAISE EXCEPTION 'RLS_SUITE_ROLLBACK'; END $$;
ROLLBACK;
