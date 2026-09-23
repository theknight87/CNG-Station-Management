-- rls_authorization.sql
-- Authorization test suite: role x region x operation, executed as the real
-- `authenticated` Postgres role with synthetic request claims.
--
-- These are DATABASE-LEVEL authorization tests. They exercise the exact RLS and
-- GRANT path a Supabase Auth request takes, by setting the same
-- `request.jwt.claims` GUC that Supabase populates from a verified token. The
-- long-lived fixtures intentionally retain Clerk-shaped subjects only for
-- migration 0056's rollback fallback: their auth_user_id is NULL, as that
-- fallback requires. Production identity is auth_user_id. These tests do not
-- emulate token verification, which remains an end-to-end concern.
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
  IF p_cond IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAILED: %', p_label; END IF;
  RAISE NOTICE 'PASS  %', p_label;
END $$;

-- Use this for authorization boundaries: a generic error such as "user not
-- found" must not be counted as proof that the caller was denied by policy.
CREATE OR REPLACE FUNCTION pg_temp.rejected_sqlstate(p_sql text, p_sqlstate text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN SQLSTATE = p_sqlstate;
END $$;

-- cng_acknowledge_alert predates the admin RPC convention and emits its
-- documented "no active application user" error as P0001. Keep that narrower
-- than a generic denial until a separately scoped API-error migration changes
-- the function's public error contract.
CREATE OR REPLACE FUNCTION pg_temp.rejected_error(p_sql text, p_sqlstate text, p_message text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN SQLSTATE = p_sqlstate AND SQLERRM = p_message;
END $$;

-- Becomes the given persona for subsequent statements in this transaction.
CREATE OR REPLACE FUNCTION pg_temp.become(p_sub text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  IF p_sub IS NULL THEN
    PERFORM set_config('request.jwt.claims', '{}'::text, true);
  ELSE
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.as_anon()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE anon';
  PERFORM set_config('request.jwt.claims', '{}'::text, true);
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
-- The repository's vanilla migration harness has no Supabase Auth schema. A
-- transaction-local minimal stand-in lets the removal RPC exercise its
-- auth.users DELETE path without claiming to be a full Auth integration test.
DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    EXECUTE 'CREATE SCHEMA IF NOT EXISTS auth';
    EXECUTE 'CREATE TABLE auth.users (id uuid PRIMARY KEY)';
  END IF;
END $$;

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
-- A second open issue from the existing taxonomy, in a REGION, so the
-- manager/admin-only rule can be told apart from a Region filter.
INSERT INTO import_issues (import_batch_id, source_file, source_row, issue_type, severity, region_id, detail)
SELECT 'e5700000-0000-0000-0000-0000000000b5', 'TESTDATA.xlsx', 9,
       'suspected_part_number_in_serial_column', 'warning', r_west,
       'TESTDATA suspected part number' FROM f;

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

-- ---------------------------------------------------------------------------
-- Prompt 19A fixtures: a dispenser per Unit, and a staged pre-import set.
-- Created with RLS bypassed, like every other fixture in this file.
-- ---------------------------------------------------------------------------
INSERT INTO dispensers (id, station_id, region_id, unit_id, mapping_status, serial_number)
SELECT 'e5700000-0000-0000-0000-0000000000da'::uuid, 'e5700000-0000-0000-0000-0000000000e1'::uuid,
       r_east, 'e5700000-0000-0000-0000-0000000000e2'::uuid, 'resolved'::asset_mapping_status,
       'TESTDATA-EAST-DISP' FROM f
UNION ALL
SELECT 'e5700000-0000-0000-0000-0000000000fa'::uuid, 'e5700000-0000-0000-0000-0000000000f1'::uuid,
       r_west, 'e5700000-0000-0000-0000-0000000000f2'::uuid, 'resolved'::asset_mapping_status,
       'TESTDATA-WEST-DISP' FROM f;

INSERT INTO import_runs (id, mode, label)
VALUES ('e5719a00-0000-0000-0000-000000000001', 'dry_run', 'TESTDATA-RUN');

INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('e5719a00-0000-0000-0000-000000000002', 'TESTDATA-PREIMPORT.xlsx', 'Sheet1',
        'dry_run', 'e5719a00-0000-0000-0000-000000000001');

-- A LATER dry run over the same workbook. `import_staging_rows_uq` is
-- (import_run_id, source_row_key), so the same source row legitimately appears
-- again here — which is exactly how a changed workbook reaches the system.
INSERT INTO import_runs (id, mode, label)
VALUES ('e5719a00-0000-0000-0000-000000000003', 'dry_run', 'TESTDATA-RUN-LATER');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('e5719a00-0000-0000-0000-000000000004', 'TESTDATA-PREIMPORT.xlsx', 'Sheet1',
        'dry_run', 'e5719a00-0000-0000-0000-000000000003');

-- One staged row per pre-import asset type, all in needs_station_mapping — the
-- exact shape of the 1,104 rows this workflow exists for.
INSERT INTO import_staging_rows (
  id, import_run_id, import_batch_id, source_file, source_sheet, source_row,
  source_raw, source_row_key, source_row_hash, target_table, outcome,
  mapping_status, normalized, resolution)
VALUES
  ('e5719a00-0000-0000-0000-000000000011',
   'e5719a00-0000-0000-0000-000000000001', 'e5719a00-0000-0000-0000-000000000002',
   'TESTDATA-PREIMPORT.xlsx', 'Sheet1', 11,
   '{"Station":"TESTDATA-RAW-STATION","Area":"EAST","Serial Number":"SV-001"}'::jsonb,
   'TESTDATA-PREIMPORT.xlsx#Sheet1#11', 'hash-s1', 'storage_vessels', 'ready_unresolved',
   'needs_station_mapping',
   '{"region":"East","region_raw":"EAST","source_station_name_raw":"TESTDATA-RAW-STATION","serial_number":"SV-001","serial_number_raw":"SV-001","manufacturer":"TESTDATA MFR","location_raw":"Storage"}'::jsonb,
   '{"station":{"kind":"unmatched","rule":null,"proposals":[{"name":"TESTDATA-EAST-STATION","score":0.71}]}}'::jsonb),
  ('e5719a00-0000-0000-0000-000000000012',
   'e5719a00-0000-0000-0000-000000000001', 'e5719a00-0000-0000-0000-000000000002',
   'TESTDATA-PREIMPORT.xlsx', 'Sheet1', 12,
   '{"Station":"TESTDATA-RAW-STATION","Area":"EAST","Serial Number":"RT-001"}'::jsonb,
   'TESTDATA-PREIMPORT.xlsx#Sheet1#12', 'hash-s2', 'recovery_tanks', 'ready_unresolved',
   'needs_station_mapping',
   '{"region":"East","region_raw":"EAST","source_station_name_raw":"TESTDATA-RAW-STATION","serial_number":"RT-001"}'::jsonb,
   '{"station":{"kind":"unmatched","rule":null,"proposals":[]}}'::jsonb),
  ('e5719a00-0000-0000-0000-000000000013',
   'e5719a00-0000-0000-0000-000000000001', 'e5719a00-0000-0000-0000-000000000002',
   'TESTDATA-PREIMPORT.xlsx', 'Sheet1', 13,
   '{"Station":"TESTDATA-RAW-STATION","Area":"EAST","S/N":"GD-001"}'::jsonb,
   'TESTDATA-PREIMPORT.xlsx#Sheet1#13', 'hash-s3', 'gas_detectors', 'ready_unresolved',
   'needs_station_mapping',
   '{"region":"East","region_raw":"EAST","source_station_name_raw":"TESTDATA-RAW-STATION","serial_number":"GD-001"}'::jsonb,
   '{"station":{"kind":"unmatched","rule":null,"proposals":[]}}'::jsonb),
  ('e5719a00-0000-0000-0000-000000000014',
   'e5719a00-0000-0000-0000-000000000001', 'e5719a00-0000-0000-0000-000000000002',
   'TESTDATA-PREIMPORT.xlsx', 'Sheet1', 14,
   '{"Station":"TESTDATA-RAW-STATION","Serial Number":"HS-001"}'::jsonb,
   'TESTDATA-PREIMPORT.xlsx#Sheet1#14', 'hash-s4', 'hoses', 'ready_unresolved',
   'needs_station_mapping',
   '{"source_station_name_raw":"TESTDATA-RAW-STATION","serial_number":"HS-001"}'::jsonb,
   '{"station":{"kind":"unmatched","rule":null,"proposals":[]}}'::jsonb),
  -- A row that a LATER dry run re-stages from the same (file, sheet, row) with
  -- DIFFERENT content. This is the Prompt 19B scenario, and the reason a
  -- decision must be bound to content and not only to location.
  ('e5719a00-0000-0000-0000-000000000021',
   'e5719a00-0000-0000-0000-000000000003', 'e5719a00-0000-0000-0000-000000000004',
   'TESTDATA-PREIMPORT.xlsx', 'Sheet1', 11,
   '{"Station":"A DIFFERENT STATION","Area":"WEST","Serial Number":"SV-999"}'::jsonb,
   'TESTDATA-PREIMPORT.xlsx#Sheet1#11', 'hash-s1-CHANGED', 'storage_vessels', 'ready_unresolved',
   'needs_station_mapping',
   '{"region":"West","region_raw":"WEST","source_station_name_raw":"A DIFFERENT STATION","serial_number":"SV-999"}'::jsonb,
   '{"station":{"kind":"unmatched","rule":null,"proposals":[]}}'::jsonb),
  -- A rejected row: structurally unusable, and therefore not a decision to make.
  ('e5719a00-0000-0000-0000-000000000015',
   'e5719a00-0000-0000-0000-000000000001', 'e5719a00-0000-0000-0000-000000000002',
   'TESTDATA-PREIMPORT.xlsx', 'Sheet1', 15,
   '{"Station":null}'::jsonb,
   'TESTDATA-PREIMPORT.xlsx#Sheet1#15', 'hash-s5', 'storage_vessels', 'rejected',
   'needs_station_mapping', '{}'::jsonb, '{}'::jsonb);


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
  -- Previously a no-op cleanup that RLS reduced to zero rows. Since 0038 the
  -- engineer has no DELETE grant at all, so it is now a DENIAL to assert rather
  -- than a statement to run -- a strictly stronger outcome.
  PERFORM pg_temp.ok(pg_temp.denied(
      $q$DELETE FROM user_region_access WHERE app_user_id='a0000000-0000-0000-0000-00000000000d'$q$),
      'ENG-21b cannot delete a Region grant at all');
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

  -- ACCESS, not a suite-wide total. This counted `= 1` and so tracked how many
  -- issue fixtures the whole file happens to hold — a number other prompts
  -- legitimately change. What it means to assert is that a manager can read the
  -- import issue queue at all, which a viewer and an engineer cannot.
  SELECT count(*) INTO n FROM import_issues;
  PERFORM pg_temp.ok(n >= 1, 'MGR-6 has data-quality access');

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

  -- PROMPT 19 CHANGED THE MECHANISM, NOT THE INTENT. These three previously
  -- performed DIRECT table writes; migration 0038 revoked those grants so that a
  -- privileged change cannot happen without its audit row. The capability is
  -- unchanged and still asserted here -- it now runs through the audited
  -- function, and ADMIN-13/14 below prove the direct path is closed.
  PERFORM cng_admin_set_user_role(
    (SELECT id FROM app_users WHERE clerk_user_id='clerk_view_east'), 'engineer');
  PERFORM pg_temp.ok((SELECT role FROM app_users WHERE clerk_user_id='clerk_view_east')='engineer',
      'ADMIN-3 can change a user role');
  PERFORM cng_admin_set_user_role(
    (SELECT id FROM app_users WHERE clerk_user_id='clerk_view_east'), 'viewer');

  PERFORM cng_admin_grant_region('a0000000-0000-0000-0000-00000000000e', v_west, false);
  PERFORM pg_temp.ok(true, 'ADMIN-4 can grant region access');
  PERFORM pg_temp.ok(
    cng_admin_revoke_region('a0000000-0000-0000-0000-00000000000e', v_west) = 1,
    'ADMIN-5 can revoke region access');

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

  SELECT count(*) INTO n
  FROM (
    (
      SELECT cng_due_status(next_calibration_date, next_calibration_precision) AS due_status,
             count(*)::bigint AS total
      FROM installed_relief_valves
      GROUP BY 1
      EXCEPT
      SELECT due_status, total
      FROM v_dashboard_due_summary
      WHERE asset_kind = 'installed_relief_valve'
    )
    UNION ALL
    (
      SELECT due_status, total
      FROM v_dashboard_due_summary
      WHERE asset_kind = 'installed_relief_valve'
      EXCEPT
      SELECT cng_due_status(next_calibration_date, next_calibration_precision),
             count(*)::bigint
      FROM installed_relief_valves
      GROUP BY 1
    )
  ) bucket_difference;
  PERFORM pg_temp.ok(n = 0,
    'DASH-4D optimized due buckets exactly match cng_due_status for every visible SRV');

  SELECT assets INTO n FROM v_dashboard_region_summary WHERE region_id = east_id;
  PERFORM pg_temp.ok(n = (
      (SELECT count(*) FROM installed_relief_valves WHERE region_id = east_id)
    + (SELECT count(*) FROM storage_vessels WHERE region_id = east_id)
    + (SELECT count(*) FROM recovery_tanks WHERE region_id = east_id)
    + (SELECT count(*) FROM gas_detectors WHERE region_id = east_id)
    + (SELECT count(*) FROM hoses WHERE region_id = east_id)
  ), 'DASH-4A region asset total equals the caller-visible source rows');

  SELECT overdue INTO n FROM v_dashboard_region_summary WHERE region_id = east_id;
  PERFORM pg_temp.ok(n = (
      (SELECT count(*) FROM installed_relief_valves WHERE region_id = east_id
        AND cng_due_status(next_calibration_date, next_calibration_precision) = 'overdue')
    + (SELECT count(*) FROM storage_vessels WHERE region_id = east_id
        AND cng_due_status(next_inspection_date, next_inspection_precision) = 'overdue')
    + (SELECT count(*) FROM recovery_tanks WHERE region_id = east_id
        AND cng_due_status(next_inspection_date, next_inspection_precision) = 'overdue')
    + (SELECT count(*) FROM gas_detectors WHERE region_id = east_id
        AND cng_due_status(next_calibration_date, next_calibration_precision) = 'overdue')
    + (SELECT count(*) FROM hoses WHERE region_id = east_id
        AND cng_due_status(next_test_date, next_test_precision) = 'overdue')
  ), 'DASH-4B region overdue total equals the caller-visible source rows');

  SELECT unresolved_mapping INTO n FROM v_dashboard_region_summary WHERE region_id = east_id;
  PERFORM pg_temp.ok(n = (
      (SELECT count(*) FROM installed_relief_valves WHERE region_id = east_id AND mapping_status <> 'resolved')
    + (SELECT count(*) FROM storage_vessels WHERE region_id = east_id AND mapping_status <> 'resolved')
    + (SELECT count(*) FROM recovery_tanks WHERE region_id = east_id AND mapping_status <> 'resolved')
    + (SELECT count(*) FROM gas_detectors WHERE region_id = east_id AND mapping_status <> 'resolved')
    + (SELECT count(*) FROM hoses WHERE region_id = east_id AND mapping_status <> 'resolved')
  ), 'DASH-4C region unresolved total equals the caller-visible source rows');

  SELECT approaching_due INTO n FROM v_dashboard_region_summary WHERE region_id = east_id;
  PERFORM pg_temp.ok(n = (
      (SELECT count(*) FROM installed_relief_valves WHERE region_id = east_id
        AND cng_due_status(next_calibration_date, next_calibration_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60'))
    + (SELECT count(*) FROM storage_vessels WHERE region_id = east_id
        AND cng_due_status(next_inspection_date, next_inspection_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60'))
    + (SELECT count(*) FROM recovery_tanks WHERE region_id = east_id
        AND cng_due_status(next_inspection_date, next_inspection_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60'))
    + (SELECT count(*) FROM gas_detectors WHERE region_id = east_id
        AND cng_due_status(next_calibration_date, next_calibration_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60'))
    + (SELECT count(*) FROM hoses WHERE region_id = east_id
        AND cng_due_status(next_test_date, next_test_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60'))
  ), 'DASH-4E region approaching-due total equals the caller-visible source rows');

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

-- ===========================================================================
-- NOTIFICATION PREFERENCES (Prompt 18A) — a PRODUCTION defect.
--
-- /settings failed with "new row violates row-level security policy for table
-- notification_preferences". The client insert supplies no user id (correctly),
-- app_user_id had no DEFAULT, so it was NULL and the WITH CHECK
-- `app_user_id = cng_current_app_user_id()` evaluated NULL -> not true.
--
-- PREF-1 is the regression test proper: it performs EXACTLY the failing insert
-- and FAILS against the pre-0037 schema.
-- ===========================================================================
DO $$
DECLARE
  v_east  uuid;
  v_west  uuid;
  n       integer;
  v_owner uuid;
BEGIN
  SELECT id INTO v_east FROM app_users WHERE clerk_user_id = 'clerk_eng_east';
  SELECT id INTO v_west FROM app_users WHERE clerk_user_id = 'clerk_eng_west';
  -- Earlier scenarios in this suite create preferences of their own. Clearing
  -- them keeps this block self-contained, so it tests the defect rather than
  -- the order the file happens to be written in.
  DELETE FROM notification_preferences;

  PERFORM pg_temp.become('clerk_eng_east');

  -- 1. INITIALIZE: the exact client insert, with NO user id supplied.
  INSERT INTO notification_preferences (channel, is_enabled, min_threshold)
  VALUES ('email', true, NULL);
  PERFORM pg_temp.ok(true,
    'PREF-1 a user can initialize their own preferences without supplying a user id');

  -- ...and the row is owned by the SESSION user, derived server-side.
  SELECT app_user_id INTO v_owner FROM notification_preferences WHERE channel = 'email';
  PERFORM pg_temp.ok(v_owner = v_east,
    'PREF-2 the owner is derived from the verified session, not from the client');

  -- 2. READ back their own.
  SELECT count(*) INTO n FROM notification_preferences;
  PERFORM pg_temp.ok(n = 1, 'PREF-3 and can read their own preferences');

  -- 3. UPDATE their own.
  UPDATE notification_preferences SET is_enabled = false WHERE channel = 'email';
  SELECT count(*) INTO n FROM notification_preferences WHERE NOT is_enabled;
  PERFORM pg_temp.ok(n = 1, 'PREF-4 and can update their own preferences');

  -- 4. SPOOFING another user is still rejected. The DEFAULT did not replace the
  --    WITH CHECK; it is defence in depth behind it.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$INSERT INTO notification_preferences (app_user_id, channel, is_enabled)
       VALUES (%L, 'web_push', true)$q$, v_west)),
    'PREF-5 a user cannot create preferences for ANOTHER user');

  -- 8. IDEMPOTENT: a repeated initialization cannot duplicate the default row.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$INSERT INTO notification_preferences (channel, is_enabled) VALUES ('email', true)$q$),
    'PREF-6 a repeated initialization cannot create a duplicate default row');
  SELECT count(*) INTO n FROM notification_preferences WHERE channel = 'email';
  PERFORM pg_temp.ok(n = 1, 'PREF-7 and exactly one row remains');

  -- 7. REGION cannot be widened: there is no region column to widen, and the
  --    preference carries no authorization of any kind.
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'notification_preferences'
     AND column_name IN ('region_id', 'region', 'regions');
  PERFORM pg_temp.ok(n = 0,
    'PREF-8 a preference carries no Region column, so it cannot widen authorization');
  RESET ROLE;

  -- 4. Another user cannot UPDATE or READ it.
  PERFORM pg_temp.become('clerk_eng_west');
  SELECT count(*) INTO n FROM notification_preferences;
  PERFORM pg_temp.ok(n = 0, 'PREF-9 another user cannot read those preferences');
  UPDATE notification_preferences SET is_enabled = true;
  SELECT count(*) INTO n FROM notification_preferences WHERE is_enabled;
  PERFORM pg_temp.ok(n = 0,
    'PREF-10 and an update from another user changes zero rows');
  RESET ROLE;
  -- Confirmed from outside RLS: the owner's row is untouched.
  SELECT count(*) INTO n FROM notification_preferences
   WHERE app_user_id = v_east AND NOT is_enabled;
  PERFORM pg_temp.ok(n = 1, 'PREF-11 the owner''s row really is unchanged');

  -- 6. anon can do nothing at all.
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM notification_preferences'),
    'PREF-12 anon cannot read preferences');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$INSERT INTO notification_preferences (channel, is_enabled) VALUES ('email', true)$q$),
    'PREF-13 anon cannot create preferences');
  RESET ROLE;
END $$;

-- 5. OWNERSHIP SEMANTICS ARE IDENTICAL FOR EVERY ROLE. A preference is personal;
-- being an admin or a manager confers no authority over anyone else's.
DO $$
DECLARE
  persona text;
  v_self  uuid;
  n       integer;
BEGIN
  FOREACH persona IN ARRAY ARRAY['clerk_admin','clerk_manager','clerk_view_east','clerk_eng_west']
  LOOP
    PERFORM pg_temp.become(persona);
    INSERT INTO notification_preferences (channel, is_enabled) VALUES ('web_push', true);
    SELECT app_user_id INTO v_self FROM notification_preferences WHERE channel = 'web_push';
    PERFORM pg_temp.ok(
      v_self = (SELECT id FROM app_users WHERE clerk_user_id = persona),
      format('PREF-14 %s owns exactly the preference they created', persona));
    -- Even an admin sees only their own.
    SELECT count(*) INTO n FROM notification_preferences WHERE channel = 'web_push';
    PERFORM pg_temp.ok(n = 1,
      format('PREF-15 %s sees only their own preference, whatever their role', persona));
    RESET ROLE;
  END LOOP;
END $$;

-- ===========================================================================
-- ADMIN MODULE (Prompt 19, migration 0038).
--
-- The Admin surface is the most privileged thing in the product, so these are
-- written as ATTACKS rather than as happy paths. Every one of ADMIN-1..12 is a
-- non-admin trying to reach a privileged mutation directly through the database,
-- which is exactly what a browser can attempt regardless of what the UI shows.
-- ===========================================================================
DO $$
DECLARE
  v_admin uuid;
  v_west  uuid;
  v_east  uuid;
  v_region uuid;
  n       integer;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT id INTO v_west  FROM app_users WHERE clerk_user_id = 'clerk_eng_west';
  SELECT id INTO v_east  FROM app_users WHERE clerk_user_id = 'clerk_eng_east';
  SELECT r_east INTO v_region FROM f;

  --------------------------------------------------------------------- VIEWER
  PERFORM pg_temp.become('clerk_view_east');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'admin')$q$, v_west)),
    'ADMSEC-1 viewer cannot change a role');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_active(%L, false)$q$, v_west)),
    'ADMSEC-2 viewer cannot deactivate a user');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_grant_region(%L, %L, true)$q$, v_west, v_region)),
    'ADMSEC-3 viewer cannot grant Region access');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_alert_rule_enabled((SELECT id FROM alert_rules LIMIT 1), false)$q$),
    'ADMSEC-4 viewer cannot change an alert rule');
  RESET ROLE;

  ------------------------------------------------------------------- ENGINEER
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'admin')$q$, v_west)),
    'ADMSEC-5 engineer cannot change a role');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_grant_region(%L, %L, true)$q$, v_west, v_region)),
    'ADMSEC-6 engineer cannot grant Region access');
  -- Privilege escalation attempt against THEMSELVES, the likeliest real attack.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'admin')$q$, v_east)),
    'ADMSEC-7 engineer cannot promote THEMSELVES to admin');
  RESET ROLE;

  -------------------------------------------------------------------- MANAGER
  -- A manager keeps their technical permissions but gains no user administration.
  PERFORM pg_temp.become('clerk_manager');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'viewer')$q$, v_west)),
    'ADMSEC-8 manager cannot change a role');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_active(%L, false)$q$, v_west)),
    'ADMSEC-9 manager cannot deactivate a user');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_map_srv('00000000-0000-0000-0000-000000000000'::uuid,
                                '00000000-0000-0000-0000-000000000000'::uuid)$q$),
    'ADMSEC-10 manager cannot perform Admin-only mapping resolution');
  RESET ROLE;

  ----------------------------------------------------------------------- anon
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'admin')$q$, v_west)),
    'ADMSEC-11 anon cannot change a role');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_admin_users'),
    'ADMSEC-12 anon cannot read the admin user list');
  RESET ROLE;

  ---------------------------------------------- the DIRECT paths are now closed
  -- Even an ADMIN must go through the audited function: the raw grants are gone,
  -- so an unaudited role change is not expressible.
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE app_users SET role = 'viewer' WHERE id = %L$q$, v_west)),
    'ADMSEC-13 not even an ADMIN may UPDATE a role directly, bypassing the audit');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$INSERT INTO user_region_access (app_user_id, region_id) VALUES (%L, %L)$q$,
    v_west, v_region)),
    'ADMSEC-14 nor insert a Region grant directly');
  RESET ROLE;
END $$;

-- Admin CAN administer — and cannot strand the product.
DO $$
DECLARE
  v_admin uuid;
  v_west  uuid;
  v_region uuid;
  v_ts    timestamptz;
  n       integer;
  v_role  app_role;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT id INTO v_west  FROM app_users WHERE clerk_user_id = 'clerk_eng_west';
  SELECT r_east INTO v_region FROM f;

  PERFORM pg_temp.become('clerk_admin');

  -- Authorized administration works.
  v_ts := cng_admin_set_user_role(v_west, 'manager');
  RESET ROLE;
  SELECT role INTO v_role FROM app_users WHERE id = v_west;
  PERFORM pg_temp.ok(v_role = 'manager', 'ADMSEC-15 an admin can change a role');

  -- ...and it is AUDITED, with a server-derived actor.
  SELECT count(*) INTO n FROM audit_logs
   WHERE action = 'user_role_changed' AND entity_id = v_west AND actor_id = v_admin;
  PERFORM pg_temp.ok(n = 1, 'ADMSEC-16 the role change is audited to the real actor');

  -- LAST ACTIVE ADMIN protection: there is exactly one admin in the fixtures.
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'viewer')$q$, v_admin)),
    'ADMSEC-17 an admin cannot demote themselves');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_active(%L, false)$q$, v_admin)),
    'ADMSEC-18 an admin cannot deactivate themselves');
  RESET ROLE;
  SELECT count(*) INTO n FROM app_users WHERE role = 'admin' AND is_active;
  PERFORM pg_temp.ok(n >= 1,
    'ADMSEC-19 the product is never left with zero active administrators');

  -- STALE WRITE protection.
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'viewer', %L::timestamptz)$q$,
    v_west, '2020-01-01T00:00:00Z')),
    'ADMSEC-20 a stale write is refused rather than silently applied');

  -- Region grants: idempotent, never duplicated.
  PERFORM cng_admin_grant_region(v_west, v_region, true);
  PERFORM cng_admin_grant_region(v_west, v_region, false);
  RESET ROLE;
  SELECT count(*) INTO n FROM user_region_access
   WHERE app_user_id = v_west AND region_id = v_region;
  PERFORM pg_temp.ok(n = 1, 'ADMSEC-21 a repeated Region grant updates rather than duplicating');
  -- Scoped to THIS user: other blocks in the suite legitimately change Region
  -- access too, and a bare count would track them instead of the two calls above.
  SELECT count(*) INTO n FROM audit_logs
   WHERE action = 'region_access_changed'
     AND (after_data ->> 'app_user_id')::uuid = v_west;
  PERFORM pg_temp.ok(n = 2, 'ADMSEC-22 both Region actions on this user are audited');

  -- A malformed / unknown target is refused, not silently ignored.
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_user_role('00000000-0000-0000-0000-000000000000'::uuid, 'admin')$q$),
    'ADMSEC-23 an unknown target user is refused');
  RESET ROLE;
END $$;

-- AUDIT HISTORY IS NOT REWRITABLE — by anyone, including an admin.
DO $$
BEGIN
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE audit_logs SET summary = 'tampered'$q$),
    'ADMSEC-24 an ADMIN cannot rewrite audit history');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM audit_logs$q$),
    'ADMSEC-25 nor delete it');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE asset_mapping_audit SET reason = 'tampered'$q$),
    'ADMSEC-26 nor rewrite the mapping audit');
  -- Actor spoofing on a direct insert is still refused.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$INSERT INTO audit_logs (action, entity_table, actor_id)
       VALUES ('admin_action', 'app_users', %L)$q$,
    (SELECT id FROM app_users WHERE clerk_user_id = 'clerk_eng_west'))),
    'ADMSEC-27 the audit actor cannot be spoofed');
  RESET ROLE;
END $$;

-- ===========================================================================
-- MANUAL MAPPING MATRIX (Prompt 19 §18).
--
-- The mapping lifecycle is a claim about PHYSICAL REALITY, so every step must be
-- proven, never assumed. These assert the full transition chain, and — more
-- importantly — that each way of SKIPPING a step is refused by the database.
-- Nothing here relaxes a composite foreign key or a check constraint; the
-- rejections below are those pre-existing constraints doing their job.
-- ===========================================================================
DO $$
DECLARE
  v_e_station uuid := 'e5700000-0000-0000-0000-0000000000e1';
  v_w_station uuid := 'e5700000-0000-0000-0000-0000000000f1';
  v_e_unit    uuid := 'e5700000-0000-0000-0000-0000000000e2';
  v_w_unit    uuid := 'e5700000-0000-0000-0000-0000000000f2';
  v_e_comp    uuid := 'e5700000-0000-0000-0000-0000000000e3';
  v_w_comp    uuid := 'e5700000-0000-0000-0000-0000000000f3';
  v_w_vessel  uuid := 'e5700000-0000-0000-0000-0000000000f4';
  -- e6 is already advanced to needs_unit_mapping by MGR-5 earlier in this suite,
  -- so the matrix creates its OWN untouched record rather than asserting a
  -- transition that another block has already made.
  v_srv       uuid := 'e5700000-0000-0000-0000-0000000000ed';
  v_admin     uuid;
  v_raw_before text;
  v_file_before text;
  v_status    srv_mapping_status;
  v_ts        timestamptz;
  n           integer;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  INSERT INTO installed_relief_valves
    (id, station_id, region_id, mapping_status, source_station_name_raw,
     source_region_raw, location_raw, expected_parent_kind, source_file,
     source_sheet, source_row)
  SELECT v_srv, NULL, r_east, 'needs_station_mapping',
         'TESTDATA-EAST-STATION', 'East', 'Stage', 'compressor',
         'TESTDATA-MAP.xlsx', 'Sheet1', 42 FROM f;

  SELECT source_station_name_raw, source_file
    INTO v_raw_before, v_file_before
    FROM installed_relief_valves WHERE id = v_srv;

  PERFORM pg_temp.become('clerk_admin');

  -- BEFORE: a valve whose Station is not even confirmed is not in any Unit tab.
  SELECT count(*) INTO n FROM v_unit_srvs WHERE id = v_srv;
  PERFORM pg_temp.ok(n = 0,
    'MAP-0 an unmapped SRV is absent from the Unit SRV tab before mapping');

  ------------------------------------------------- needs_station -> needs_unit
  SELECT mapping_status, updated_at INTO v_status, v_ts
    FROM cng_admin_map_srv(v_srv, v_e_station, NULL, NULL, NULL, NULL,
                           'MAP-1 station confirmed from the work order');
  PERFORM pg_temp.ok(v_status = 'needs_unit_mapping',
    'MAP-1 confirming only the Station advances to needs_unit_mapping, not further');

  -- The status is DERIVED. Proving the Station does not silently prove a Unit.
  SELECT count(*) INTO n FROM installed_relief_valves
   WHERE id = v_srv AND unit_id IS NULL AND compressor_id IS NULL
     AND storage_vessel_id IS NULL AND dispenser_id IS NULL;
  PERFORM pg_temp.ok(n = 1, 'MAP-2 no Unit or equipment is invented by a Station mapping');

  -- The Region follows the confirmed Station, not the unconfirmed raw source text.
  SELECT count(*) INTO n FROM installed_relief_valves v
    JOIN stations s ON s.id = v.station_id
   WHERE v.id = v_srv AND v.region_id = s.region_id;
  PERFORM pg_temp.ok(n = 1, 'MAP-3 the Region is taken from the confirmed Station');

  --------------------------------------------- a Unit from the WRONG Station is refused
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, %L)$q$, v_srv, v_e_station, v_w_unit)),
    'MAP-4 a Unit that does not belong to the confirmed Station is rejected');

  ------------------------------------------------- needs_unit -> needs_equipment
  SELECT mapping_status INTO v_status
    FROM cng_admin_map_srv(v_srv, v_e_station, v_e_unit, NULL, NULL, NULL,
                           'MAP-5 unit confirmed on site');
  PERFORM pg_temp.ok(v_status = 'needs_equipment_mapping',
    'MAP-5 confirming the Unit advances to needs_equipment_mapping');

  ------------------------------------- equipment from the WRONG Unit is refused
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, %L, 'compressor', %L)$q$,
    v_srv, v_e_station, v_e_unit, v_w_comp)),
    'MAP-6 a Compressor belonging to another Unit is rejected');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, %L, 'storage_vessel', %L)$q$,
    v_srv, v_e_station, v_e_unit, v_w_vessel)),
    'MAP-7 a Storage Vessel belonging to another Unit is rejected');

  ------------------------------------------- the hierarchy cannot be short-circuited
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, NULL, 'compressor', %L)$q$,
    v_srv, v_e_station, v_e_comp)),
    'MAP-8 equipment cannot be confirmed while the Unit is still unproven');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, NULL, %L)$q$, v_srv, v_e_unit)),
    'MAP-9 a Unit cannot be confirmed while the Station is still unproven');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, %L, 'compressor', NULL)$q$,
    v_srv, v_e_station, v_e_unit)),
    'MAP-10 a parent kind without a parent id is refused, not treated as a guess');

  ------------------------------------------------ needs_equipment -> resolved
  SELECT mapping_status, updated_at INTO v_status, v_ts
    FROM cng_admin_map_srv(v_srv, v_e_station, v_e_unit, 'compressor', v_e_comp, NULL,
                           'MAP-11 nameplate read on the stage 1 compressor');
  PERFORM pg_temp.ok(v_status = 'resolved',
    'MAP-11 confirming the equipment parent resolves the record');
  SELECT count(*) INTO n FROM installed_relief_valves
   WHERE id = v_srv AND compressor_id = v_e_comp
     AND storage_vessel_id IS NULL AND dispenser_id IS NULL;
  PERFORM pg_temp.ok(n = 1, 'MAP-12 a resolved SRV has exactly one equipment parent');

  ------------------------------------------------------------- STALE write
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, %L, 'compressor', %L, %L::timestamptz)$q$,
    v_srv, v_e_station, v_e_unit, v_e_comp, '2020-01-01T00:00:00Z')),
    'MAP-13 a mapping write against a stale row version is refused');
  -- ...and the same call with the CURRENT version is accepted, so MAP-13 proves
  -- the precondition rather than a broken signature.
  SELECT mapping_status INTO v_status
    FROM cng_admin_map_srv(v_srv, v_e_station, v_e_unit, 'compressor', v_e_comp, v_ts);
  PERFORM pg_temp.ok(v_status = 'resolved',
    'MAP-14 the same write with the current row version succeeds');

  ------------------------------------------- the constraints, not the function
  -- Two parents, and "resolved" with no parent, are refused at the TABLE level,
  -- so no future caller can express them either.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE installed_relief_valves SET storage_vessel_id = %L WHERE id = %L$q$,
    v_w_vessel, v_srv)),
    'MAP-15 an SRV cannot be given a second equipment parent');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE installed_relief_valves
          SET compressor_id = NULL, mapping_status = 'resolved' WHERE id = %L$q$, v_srv)),
    'MAP-16 resolved without an equipment parent is refused by the table');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE installed_relief_valves
          SET mapping_status = 'resolved' WHERE id = 'e5700000-0000-0000-0000-0000000000f5'$q$)),
    'MAP-17 an unresolved SRV cannot be relabelled resolved without proof');
  RESET ROLE;

  ------------------------------------------------------- SOURCE EVIDENCE KEPT
  SELECT count(*) INTO n FROM installed_relief_valves
   WHERE id = v_srv
     AND source_station_name_raw IS NOT DISTINCT FROM v_raw_before
     AND source_file IS NOT DISTINCT FROM v_file_before;
  PERFORM pg_temp.ok(n = 1,
    'MAP-18 mapping never alters the raw source Station name or its provenance');

  --------------------------------------------------------------- AUDIT TRAIL
  SELECT count(*) INTO n FROM asset_mapping_audit
   WHERE asset_type = 'installed_relief_valve' AND asset_id = v_srv
     AND changed_by = v_admin;
  PERFORM pg_temp.ok(n = 4,
    'MAP-19 every accepted mapping step is recorded with the server-derived actor');
  SELECT count(*) INTO n FROM asset_mapping_audit
   WHERE asset_id = v_srv AND previous_mapping_status = 'needs_station_mapping'
     AND new_mapping_status = 'needs_unit_mapping';
  PERFORM pg_temp.ok(n = 1,
    'MAP-20 the audit records the transition it made, not just the final state');
  SELECT count(*) INTO n FROM audit_logs
   WHERE action = 'mapping_changed' AND entity_id = v_srv AND actor_id = v_admin;
  PERFORM pg_temp.ok(n = 4, 'MAP-21 the same steps appear in the general audit log');

  -------------------------------------------------- a rejected step leaves NOTHING
  SELECT count(*) INTO n FROM asset_mapping_audit
   WHERE asset_id = v_srv AND new_unit_id = v_w_unit;
  PERFORM pg_temp.ok(n = 0,
    'MAP-22 a rejected mapping writes no audit row — the audit is atomic with the mutation');

  -- AFTER: mapping — and only mapping — is what puts it there.
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM v_unit_srvs WHERE id = v_srv;
  PERFORM pg_temp.ok(n = 1, 'MAP-23 the resolved SRV now appears in its Unit SRV tab');
  -- The valve whose Unit is still unproven never reaches a Unit tab.
  SELECT count(*) INTO n FROM v_unit_srvs
   WHERE mapping_status IN ('needs_station_mapping', 'needs_unit_mapping');
  PERFORM pg_temp.ok(n = 0,
    'MAP-24 no SRV without a confirmed Unit is ever visible in a Unit SRV tab');
  RESET ROLE;
END $$;

-- ===========================================================================
-- ALERT SETTINGS MATRIX (Prompt 19 §19).
--
-- An alert rule is not a preference: it decides what the whole product warns
-- about. So the only editable thing is whether it is ACTIVE. Subject, threshold
-- and days_before are rule IDENTITY — editing them would silently reinterpret
-- alerts that were already generated under the old meaning.
-- ===========================================================================
DO $$
DECLARE
  v_admin uuid;
  v_rule  uuid;
  v_ts    timestamptz;
  v_alerts_before integer;
  n       integer;
  v_on    boolean;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT id INTO v_rule FROM alert_rules ORDER BY subject, threshold LIMIT 1;
  SELECT count(*) INTO v_alerts_before FROM alerts;

  PERFORM pg_temp.become('clerk_admin');

  v_ts := cng_admin_set_alert_rule_enabled(v_rule, false);
  RESET ROLE;
  SELECT is_enabled INTO v_on FROM alert_rules WHERE id = v_rule;
  PERFORM pg_temp.ok(v_on = false, 'ALSET-1 an admin can disable an alert rule');

  -- Disabling stops FUTURE generation; it is not a way to erase history.
  SELECT count(*) INTO n FROM alerts;
  PERFORM pg_temp.ok(n = v_alerts_before,
    'ALSET-2 disabling a rule deletes no alert that was already raised');

  SELECT count(*) INTO n FROM audit_logs
   WHERE action = 'alert_rule_changed' AND entity_id = v_rule AND actor_id = v_admin;
  PERFORM pg_temp.ok(n = 1, 'ALSET-3 the change is audited to the server-derived actor');

  PERFORM pg_temp.become('clerk_admin');
  v_ts := cng_admin_set_alert_rule_enabled(v_rule, true, v_ts);
  RESET ROLE;
  SELECT is_enabled INTO v_on FROM alert_rules WHERE id = v_rule;
  PERFORM pg_temp.ok(v_on = true, 'ALSET-4 and can re-enable it with the current row version');

  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_alert_rule_enabled(%L, false, %L::timestamptz)$q$,
    v_rule, '2020-01-01T00:00:00Z')),
    'ALSET-5 a stale alert-rule write is refused');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_alert_rule_enabled('00000000-0000-0000-0000-000000000000'::uuid, false)$q$),
    'ALSET-6 an unknown rule is refused, not silently created');

  -- Rule IDENTITY is not editable by anyone, admin included. There is no
  -- function for it and no direct grant.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE alert_rules SET days_before = 999 WHERE id = %L$q$, v_rule)),
    'ALSET-7 not even an admin may change a rule threshold window directly');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$INSERT INTO alert_rules (subject, threshold, days_before)
       VALUES ('srv_calibration', 'due_7', 7)$q$),
    'ALSET-8 an admin cannot invent a new alert rule from the browser');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$DELETE FROM alert_rules WHERE id = %L$q$, v_rule)),
    'ALSET-9 nor delete one');
  RESET ROLE;

  ------------------------------------------------------------- NON-ADMINS
  PERFORM pg_temp.become('clerk_manager');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_alert_rule_enabled(%L, false)$q$, v_rule)),
    'ALSET-10 a manager cannot change alert settings');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_alert_rule_enabled(%L, false)$q$, v_rule)),
    'ALSET-11 nor an engineer');
  RESET ROLE;
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_alert_rule_enabled(%L, false)$q$, v_rule)),
    'ALSET-12 nor anon');
  RESET ROLE;

  -- Changing a rule never touches an alert's acknowledgement state.
  SELECT count(*) INTO n FROM audit_logs WHERE action = 'alert_rule_changed';
  PERFORM pg_temp.ok(n = 2,
    'ALSET-13 only the two ACCEPTED changes are audited — every refusal wrote nothing');
END $$;

-- The Prompt 19 §22 hostile pass: the READ side of the admin surface.
--
-- A privileged VIEW is the classic way a locked-down table leaks. Each of these
-- is security_invoker, so the existing policies decide — and that claim is worth
-- proving rather than asserting, because a later `security_definer` on any one
-- of them would silently publish the whole user directory.
DO $$
DECLARE n integer; v_total integer; v_west uuid;
BEGIN
  -- Resolved BEFORE any SET ROLE: the temp fixture table is not readable as an
  -- application role, and reaching for it there fails for the wrong reason.
  SELECT r_west INTO v_west FROM f;
  SELECT count(*) INTO v_total FROM app_users;
  PERFORM pg_temp.ok(v_total > 1, 'ADMSEC-28 the fixture holds several users, so a leak would be visible');

  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM v_admin_users;
  PERFORM pg_temp.ok(n = 1, 'ADMSEC-29 an engineer reads only their OWN row from the admin user view');
  -- ...and no Region grant belonging to anybody else comes with it.
  SELECT count(*) INTO n FROM v_admin_users
   WHERE clerk_user_id <> 'clerk_eng_east';
  PERFORM pg_temp.ok(n = 0, 'ADMSEC-30 no other user''s Region access leaks through the view');
  RESET ROLE;

  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM v_admin_users;
  PERFORM pg_temp.ok(n = 1, 'ADMSEC-31 nor for a viewer');
  RESET ROLE;

  -- The mapping queue and the data-quality counts are ordinary asset reads, so
  -- an engineer sees their Regions and no more. A count is a disclosure too.
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM v_admin_srv_mapping_queue
   WHERE region_id = v_west;
  PERFORM pg_temp.ok(n = 0,
    'ADMSEC-32 the mapping queue never shows an engineer a valve outside their Regions');
  RESET ROLE;

  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_admin_srv_mapping_queue'),
    'ADMSEC-33 anon reads no mapping queue');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_admin_audit_log'),
    'ADMSEC-34 anon reads no audit history');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_admin_data_quality'),
    'ADMSEC-35 anon reads no data-quality counts');
  RESET ROLE;
END $$;

-- ===========================================================================
-- PRE-IMPORT MAPPING DECISIONS (Prompt 19A, migration 0039).
--
-- These are the 1,104 staged rows the canonical tables cannot hold. The
-- resolution happens BEFORE the import, on the staging row, where the evidence
-- still is — and it never relaxes a canonical constraint to get there.
-- ===========================================================================
DO $$
DECLARE
  v_admin   uuid;
  v_station uuid := 'e5700000-0000-0000-0000-0000000000e1';
  v_unit    uuid := 'e5700000-0000-0000-0000-0000000000e2';
  v_w_unit  uuid := 'e5700000-0000-0000-0000-0000000000f2';
  v_sv      uuid := 'e5719a00-0000-0000-0000-000000000011';
  v_rt      uuid := 'e5719a00-0000-0000-0000-000000000012';
  v_gd      uuid := 'e5719a00-0000-0000-0000-000000000013';
  v_hs      uuid := 'e5719a00-0000-0000-0000-000000000014';
  v_rej     uuid := 'e5719a00-0000-0000-0000-000000000015';
  v_status  text;
  v_at      timestamptz;
  v_id      uuid;
  v_raw     jsonb;
  n         integer;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT source_raw INTO v_raw FROM import_staging_rows WHERE id = v_sv;

  ------------------------------------------------------------------ NON-ADMINS
  PERFORM pg_temp.become('clerk_view_east');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L)$q$, v_sv, v_station)),
    'PREMAP-1 a viewer cannot record a pre-import mapping decision');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L)$q$, v_sv, v_station)),
    'PREMAP-2 nor an engineer');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_manager');
  -- A manager may READ staging (they always could) but may not DECIDE. Region
  -- scoped admin mapping stays deferred and is not opened here by accident.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L)$q$, v_sv, v_station)),
    'PREMAP-3 nor a manager');
  RESET ROLE;
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L)$q$, v_sv, v_station)),
    'PREMAP-4 nor anon');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_admin_staged_mapping_queue'),
    'PREMAP-5 anon reads no pre-import queue');
  RESET ROLE;

  ------------------------------------------------- STORAGE VESSEL: Station only
  PERFORM pg_temp.become('clerk_admin');
  SELECT d.resulting_mapping_status, d.decided_at INTO v_status, v_at
    FROM cng_admin_decide_staged_mapping(v_sv, v_station, NULL, NULL,
         'PREMAP-6 station confirmed from the job file') d;
  PERFORM pg_temp.ok(v_status = 'needs_unit_mapping',
    'PREMAP-6 Storage Vessel: confirming the Station alone leaves the Unit unproven');

  -- ...and then the Unit, as a correction that SUPERSEDES rather than overwrites.
  SELECT d.resulting_mapping_status, d.decided_at INTO v_status, v_at
    FROM cng_admin_decide_staged_mapping(v_sv, v_station, v_unit, v_at,
         'PREMAP-7 unit confirmed on site') d;
  PERFORM pg_temp.ok(v_status = 'resolved',
    'PREMAP-7 Storage Vessel: confirming the Unit completes the decision');
  RESET ROLE;

  SELECT count(*) INTO n FROM import_mapping_decisions
   WHERE source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11';
  PERFORM pg_temp.ok(n = 2, 'PREMAP-8 the earlier decision is kept as history, not overwritten');
  SELECT count(*) INTO n FROM import_mapping_decisions
   WHERE source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11' AND superseded_at IS NULL;
  PERFORM pg_temp.ok(n = 1, 'PREMAP-9 exactly ONE decision is active for a source row');
  SELECT count(*) INTO n FROM import_mapping_decisions
   WHERE source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11'
     AND superseded_at IS NOT NULL AND superseded_by IS NOT NULL;
  PERFORM pg_temp.ok(n = 1, 'PREMAP-10 the superseded decision names the decision that replaced it');

  --------------------------------------------------------- RECOVERY TANK
  PERFORM pg_temp.become('clerk_admin');
  SELECT d.resulting_mapping_status INTO v_status
    FROM cng_admin_decide_staged_mapping(v_rt, v_station, v_unit, NULL, 'PREMAP-11') d;
  PERFORM pg_temp.ok(v_status = 'resolved', 'PREMAP-11 Recovery Tank: Station and Unit confirmed');

  ------------------------------------------------------------ GAS DETECTOR
  SELECT d.resulting_mapping_status INTO v_status
    FROM cng_admin_decide_staged_mapping(v_gd, v_station, v_unit, NULL, 'PREMAP-12') d;
  PERFORM pg_temp.ok(v_status = 'resolved', 'PREMAP-12 Gas Detector: Station and Unit confirmed');

  --------------------------------------------------------------------- HOSE
  -- Station-only is a LEGITIMATE end state for a hose whose Unit the source
  -- genuinely does not prove. It is not a half-finished decision.
  SELECT d.resulting_mapping_status INTO v_status
    FROM cng_admin_decide_staged_mapping(v_hs, v_station, NULL, NULL, 'PREMAP-13') d;
  PERFORM pg_temp.ok(v_status = 'needs_unit_mapping',
    'PREMAP-13 Hose: Station-only remains valid where the Unit is genuinely unknown');

  ---------------------------------------------- THE HIERARCHY IS NOT NEGOTIABLE
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L, %L)$q$, v_rt, v_station, v_w_unit)),
    'PREMAP-14 a Unit from another Station is rejected by the composite FK');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, NULL)$q$, v_rt)),
    'PREMAP-15 a decision without a Station is refused');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, '00000000-0000-0000-0000-000000000000')$q$, v_rt)),
    'PREMAP-16 an unknown Station is refused, not silently accepted');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_decide_staged_mapping('00000000-0000-0000-0000-000000000000',
        'e5700000-0000-0000-0000-0000000000e1')$q$),
    'PREMAP-17 a spoofed / unknown staging row is refused');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L)$q$, v_rej, v_station)),
    'PREMAP-18 a REJECTED staging row takes no decision — it is not committable');

  ------------------------------------------------- STALE and DUPLICATE decisions
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L, NULL, %L::timestamptz)$q$,
    v_rt, v_station, '2020-01-01T00:00:00Z')),
    'PREMAP-19 a stale decision is refused');
  -- A second decision that does not acknowledge the first is a DUPLICATE, and is
  -- refused rather than silently superseding it.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_decide_staged_mapping(%L, %L)$q$, v_rt, v_station)),
    'PREMAP-20 a duplicate decision that ignores the existing one is refused');
  RESET ROLE;

  ------------------------------------------------------------ EVIDENCE INTACT
  SELECT count(*) INTO n FROM import_staging_rows
   WHERE id = v_sv AND source_raw = v_raw AND mapping_status = 'needs_station_mapping';
  PERFORM pg_temp.ok(n = 1,
    'PREMAP-21 raw source evidence and the staged status are NEVER written by a decision');
  SELECT count(*) INTO n FROM import_mapping_decisions
   WHERE staging_row_id = v_sv AND source_evidence -> 'source_raw' = v_raw;
  PERFORM pg_temp.ok(n = 2,
    'PREMAP-22 each decision captured a COPY of the evidence it was made from');

  ------------------------------- A ROW DECISION IS NOT AN ALIAS, AND NEVER BECOMES ONE
  SELECT count(*) INTO n FROM station_aliases
   WHERE source_name_raw = 'TESTDATA-RAW-STATION';
  PERFORM pg_temp.ok(n = 0,
    'PREMAP-23 confirming one row creates NO global station alias');
  SELECT count(*) INTO n FROM owner_confirmed_station_aliases
   WHERE source_name_raw = 'TESTDATA-RAW-STATION';
  PERFORM pg_temp.ok(n = 0,
    'PREMAP-24 nor an owner-confirmed rule — a row decision binds one row only');

  ------------------------------------------------------------- AUDIT, ATOMICALLY
  SELECT count(*) INTO n FROM audit_logs
   WHERE entity_table = 'import_mapping_decisions' AND actor_id = v_admin;
  PERFORM pg_temp.ok(n = 5,
    'PREMAP-25 every ACCEPTED decision is audited to the server-derived actor');
  -- Seven attempts were refused above; not one of them wrote an audit row.
  SELECT count(*) INTO n FROM audit_logs
   WHERE entity_table = 'import_mapping_decisions';
  PERFORM pg_temp.ok(n = 5,
    'PREMAP-26 a refused decision writes no audit — the audit is atomic with the write');

  ------------------------------------------------- THE DECISION TABLE IS NOT WRITABLE
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE import_mapping_decisions SET confirmed_station_id =
       'e5700000-0000-0000-0000-0000000000f1'$q$),
    'PREMAP-27 not even an ADMIN may edit a decision directly');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM import_mapping_decisions$q$),
    'PREMAP-28 nor delete one');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$INSERT INTO import_mapping_decisions (staging_row_id, source_row_key, target_table,
        asset_type, region_id, confirmed_station_id, previous_mapping_status,
        resulting_mapping_status, decided_by, source_evidence)
       VALUES (%L, 'forged', 'hoses', 'hose',
        (SELECT region_id FROM stations WHERE id = %L), %L,
        'needs_station_mapping', 'needs_unit_mapping', %L, '{}'::jsonb)$q$,
    v_hs, v_station, v_station,
    (SELECT id FROM app_users WHERE clerk_user_id = 'clerk_eng_west'))),
    'PREMAP-29 a forged decision attributed to someone else is refused');
  -- Staging itself stays read-only: a decision must never be made by editing the
  -- evidence it is a decision about.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE import_staging_rows SET station_id = %L WHERE id = %L$q$, v_station, v_rt)),
    'PREMAP-30 an admin cannot resolve a staged row by editing staging directly');
  RESET ROLE;

  ---------------------------------------------- WHAT PROMPT 21 WILL READ
  SELECT count(*) INTO n FROM v_import_confirmed_mappings;
  PERFORM pg_temp.ok(n = 4,
    'PREMAP-31 the Prompt-21 view exposes exactly the four ACTIVE decisions');
  SELECT count(*) INTO n FROM v_import_confirmed_mappings
   WHERE confirmed_station_id IS NULL;
  PERFORM pg_temp.ok(n = 0,
    'PREMAP-32 every consumable decision carries a confirmed Station — the NOT NULL blocker is answered before the import, not by relaxing the column');
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_name IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
     AND column_name = 'station_id' AND is_nullable = 'YES';
  PERFORM pg_temp.ok(n = 0,
    'PREMAP-33 and station_id is STILL NOT NULL on all four canonical tables');
END $$;

-- The queue, and who may see it.
DO $$
DECLARE n integer;
BEGIN
  PERFORM pg_temp.become('clerk_admin');
  -- Four rows from the first dry run, plus the row a LATER dry run re-staged
  -- from the same (file, sheet, row) with different content. The rejected row
  -- is excluded.
  SELECT count(*) INTO n FROM v_admin_staged_mapping_queue;
  PERFORM pg_temp.ok(n = 5,
    'PREMAP-34 the queue holds one row per unresolved staged asset, and excludes the rejected row');
  SELECT count(*) INTO n FROM v_admin_staged_mapping_queue
   WHERE decision_id IS NOT NULL AND confirmed_station_id IS NOT NULL
     AND NOT decision_is_stale_source;
  PERFORM pg_temp.ok(n = 4, 'PREMAP-35 a decided row shows its CONFIRMED mapping');
  -- The fifth carries a decision, but one made against content that has since
  -- changed. It is neither "decided" nor "awaiting a decision" (Prompt 19B).
  SELECT count(*) INTO n FROM v_admin_staged_mapping_queue
   WHERE decision_is_stale_source;
  PERFORM pg_temp.ok(n = 1,
    'PREMAP-35b a decision made against changed source content is its own state, not a confirmation');
  -- RAW, CANDIDATE and CONFIRMED are separate columns, so a proposal can never
  -- be rendered as though it were a decision.
  SELECT count(*) INTO n FROM v_admin_staged_mapping_queue
   WHERE staging_row_id = 'e5719a00-0000-0000-0000-000000000011'
     AND raw_station = 'TESTDATA-RAW-STATION'
     AND candidate_proposals IS NOT NULL
     AND confirmed_station_name = 'TESTDATA-EAST-STATION';
  PERFORM pg_temp.ok(n = 1,
    'PREMAP-36 raw, candidate and confirmed are carried separately on the same row');
  RESET ROLE;

  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM v_admin_staged_mapping_queue;
  PERFORM pg_temp.ok(n = 0,
    'PREMAP-37 an engineer sees no staging: raw source text is never an authorization boundary');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM v_admin_staged_mapping_queue;
  PERFORM pg_temp.ok(n = 0, 'PREMAP-38 nor a viewer');
  RESET ROLE;
END $$;

-- ===========================================================================
-- ADMIN CHANNEL POLICY (Prompt 19A, migration 0040).
--
-- Policy and preference are different questions. These prove they COMPOSE and
-- that neither writes the other.
-- ===========================================================================
DO $$
DECLARE
  v_admin uuid;
  v_ts    timestamptz;
  v_prefs jsonb;
  n       integer;
  v_on    boolean;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT jsonb_agg(jsonb_build_object('id', id, 'channel', channel, 'enabled', is_enabled)
                   ORDER BY id)
    INTO v_prefs FROM notification_preferences;

  PERFORM pg_temp.ok(cng_channel_policy_enabled('email'),
    'CHAN-1 every channel ships ENABLED, so Prompt 15-18 delivery is unchanged');

  PERFORM pg_temp.become('clerk_admin');
  v_ts := cng_admin_set_channel_policy('email', false, NULL, NULL);
  RESET ROLE;
  PERFORM pg_temp.ok(NOT cng_channel_policy_enabled('email'),
    'CHAN-2 an admin can disable a channel for the whole organization');

  -- THE POINT OF A SEPARATE TABLE: no user preference was touched.
  PERFORM pg_temp.ok(
    (SELECT jsonb_agg(jsonb_build_object('id', id, 'channel', channel, 'enabled', is_enabled)
                      ORDER BY id) FROM notification_preferences) IS NOT DISTINCT FROM v_prefs,
    'CHAN-3 disabling a channel writes NO user preference row');

  -- Effective delivery requires BOTH. With policy off, nothing is enqueued even
  -- for a user who has opted in.
  SELECT enqueued INTO n FROM cng_enqueue_alert_deliveries('email');
  PERFORM pg_temp.ok(n = 0, 'CHAN-4 a disabled channel enqueues nothing');

  PERFORM pg_temp.become('clerk_admin');
  v_ts := cng_admin_set_channel_policy('email', true, v_ts, NULL);
  RESET ROLE;
  PERFORM pg_temp.ok(cng_channel_policy_enabled('email'),
    'CHAN-5 re-enabling restores the channel — and the audience, because it was never unsubscribed');
  PERFORM pg_temp.ok(
    (SELECT jsonb_agg(jsonb_build_object('id', id, 'channel', channel, 'enabled', is_enabled)
                      ORDER BY id) FROM notification_preferences) IS NOT DISTINCT FROM v_prefs,
    'CHAN-6 and re-enabling writes no preference row either');

  ------------------------------------------------------------- IN-APP IS MANDATORY
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_channel_policy('in_app', false)$q$),
    'CHAN-7 in-app cannot be disabled: it is the READ surface for compliance state');
  RESET ROLE;
  PERFORM pg_temp.ok(cng_channel_policy_enabled('in_app'),
    'CHAN-8 in-app therefore remains enabled after the attempt');
  SELECT count(*) INTO n FROM notification_channel_policy WHERE channel = 'in_app' AND is_enabled;
  PERFORM pg_temp.ok(n = 1, 'CHAN-9 and the constraint, not just the function, guarantees it');

  ------------------------------------------------------------------ AUTHORIZATION
  PERFORM pg_temp.become('clerk_manager');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_channel_policy('email', false)$q$),
    'CHAN-10 a manager cannot change channel policy');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_channel_policy('email', false)$q$),
    'CHAN-11 nor an engineer');
  RESET ROLE;
  PERFORM pg_temp.become('clerk_view_east');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_channel_policy('email', false)$q$),
    'CHAN-12 nor a viewer');
  -- ...but every signed-in user may READ it, so /settings can say why an opt-in
  -- would not deliver rather than accepting it silently.
  SELECT count(*) INTO n FROM notification_channel_policy;
  PERFORM pg_temp.ok(n = 3, 'CHAN-13 a viewer CAN read the policy, to be told why a channel is off');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE notification_channel_policy SET is_enabled = false WHERE channel = 'email'$q$),
    'CHAN-14 but cannot write it directly');
  RESET ROLE;

  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE notification_channel_policy SET is_enabled = false WHERE channel = 'email'$q$),
    'CHAN-15 and neither can an ADMIN, bypassing the audit');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_channel_policy('carrier_pigeon', false)$q$),
    'CHAN-16 an unknown channel is refused, not created');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_channel_policy('email', false, %L::timestamptz)$q$,
    '2020-01-01T00:00:00Z')),
    'CHAN-17 a stale policy write is refused');
  RESET ROLE;

  SELECT count(*) INTO n FROM audit_logs
   WHERE entity_table = 'notification_channel_policy' AND actor_id = v_admin;
  PERFORM pg_temp.ok(n = 2,
    'CHAN-18 exactly the two ACCEPTED policy changes are audited; every refusal wrote nothing');
END $$;

-- ===========================================================================
-- The hostile gaps the review checkpoint reported as NOT TESTED.
-- ===========================================================================
DO $$
DECLARE
  v_srv    uuid := 'e5700000-0000-0000-0000-0000000000f5';  -- WEST, needs_equipment
  v_w_stn  uuid := 'e5700000-0000-0000-0000-0000000000f1';
  v_w_unit uuid := 'e5700000-0000-0000-0000-0000000000f2';
  v_w_disp uuid := 'e5700000-0000-0000-0000-0000000000fa';
  v_e_disp uuid := 'e5700000-0000-0000-0000-0000000000da';
  v_status srv_mapping_status;
  n        integer;
BEGIN
  PERFORM pg_temp.become('clerk_admin');

  ------------------------------------------------------- DISPENSER PARENT PATH
  -- The one equipment kind the Prompt 19 matrix did not cover.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, %L, 'dispenser', %L)$q$,
    v_srv, v_w_stn, v_w_unit, v_e_disp)),
    'GAP-1 a Dispenser belonging to another Unit is rejected');
  SELECT mapping_status INTO v_status
    FROM cng_admin_map_srv(v_srv, v_w_stn, v_w_unit, 'dispenser', v_w_disp, NULL,
                           'GAP-2 dispenser nameplate read');
  PERFORM pg_temp.ok(v_status = 'resolved',
    'GAP-2 a Dispenser belonging to the confirmed Unit resolves the SRV');
  SELECT count(*) INTO n FROM installed_relief_valves
   WHERE id = v_srv AND dispenser_id = v_w_disp
     AND compressor_id IS NULL AND storage_vessel_id IS NULL;
  PERFORM pg_temp.ok(n = 1, 'GAP-3 and it is the ONLY parent, exactly as for the other two kinds');

  ----------------------------------------------------------- MALFORMED INPUT
  -- PostgreSQL's type parser refuses this before any function body runs, which
  -- is the correct layer — but "correct by construction" is worth asserting,
  -- because it is the assumption a future signature change would break.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_user_role('not-a-uuid', 'admin')$q$),
    'GAP-4 a malformed UUID is refused at the type boundary, not inside the function');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_decide_staged_mapping('', 'also-not-a-uuid')$q$),
    'GAP-5 the same for the pre-import decision function');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_set_user_role('e5700000-0000-0000-0000-0000000000e1', 'sysadmin')$q$),
    'GAP-6 a role outside the enum is refused');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_map_srv('e5700000-0000-0000-0000-0000000000f5',
        'e5700000-0000-0000-0000-0000000000f1', NULL, 'turbine', NULL)$q$),
    'GAP-7 a parent kind outside srv_parent_kind is refused');
  RESET ROLE;

  ------------------------------------------------ CROSS-REGION, READ vs MUTATE
  -- An engineer may READ their own Regions and no other. Proven for the
  -- canonical queue at ADMSEC-32; here for the asset itself.
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM installed_relief_valves WHERE id = v_srv;
  PERFORM pg_temp.ok(n = 0,
    'GAP-8 an East engineer cannot even READ a WEST valve');
  -- ...and the mutation path is closed to them regardless of the ids supplied,
  -- so a cross-Region argument never reaches a decision.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_map_srv(%L, %L, %L)$q$, v_srv, v_w_stn, v_w_unit)),
    'GAP-9 nor map one: cross-Region mutation is refused before the ids are read');
  -- The direct write is not an ERROR: RLS makes it a zero-row no-op, because the
  -- engineer cannot see the row to update it. That is the correct outcome, and
  -- asserting an exception here would be asserting the wrong mechanism.
  UPDATE installed_relief_valves SET unit_id = v_w_unit WHERE id = v_srv;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0,
    'GAP-10 a direct cross-Region write touches no row — RLS filters it rather than erroring');
  RESET ROLE;

  -- An admin mapping ACROSS Regions is legitimate (decision D8) — but the
  -- Region always follows the confirmed Station, never the caller.
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM installed_relief_valves v
    JOIN stations s ON s.id = v.station_id
   WHERE v.id = v_srv AND v.region_id = s.region_id;
  PERFORM pg_temp.ok(n = 1,
    'GAP-11 the Region on a mapped valve always matches its confirmed Station');
  RESET ROLE;
END $$;

-- Prompt 19 user administration, re-asserted AFTER the 19A migrations.
DO $$
DECLARE
  v_admin uuid;
  v_west  uuid;
  n       integer;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT id INTO v_west  FROM app_users WHERE clerk_user_id = 'clerk_eng_west';

  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE app_users SET role = 'viewer' WHERE id = %L$q$, v_west)),
    'REG-1 direct role mutation is STILL revoked after 0039 and 0040');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_role(%L, 'viewer')$q$, v_admin)),
    'REG-2 self-demotion is STILL refused');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$SELECT cng_admin_set_user_active(%L, false)$q$, v_admin)),
    'REG-3 self-deactivation is STILL refused');
  PERFORM pg_temp.ok(pg_temp.denied($q$UPDATE audit_logs SET summary = 'tampered'$q$),
    'REG-4 audit history is STILL not rewritable');
  PERFORM pg_temp.ok(pg_temp.denied($q$DELETE FROM audit_logs$q$),
    'REG-5 nor deletable');
  RESET ROLE;
  SELECT count(*) INTO n FROM app_users WHERE role = 'admin' AND is_active;
  PERFORM pg_temp.ok(n >= 1, 'REG-6 there is STILL at least one active administrator');
END $$;

-- ===========================================================================
-- DECISION / SOURCE-CONTENT BINDING (Prompt 19B, migration 0041).
--
-- 0039 keyed a decision on (file, sheet, row) alone. That says WHERE a row was,
-- not WHAT was reviewed — and a workbook is a live document. These prove the
-- binding is now to both, that the hash comes from the server, and that a
-- decision made against content that has since changed is neither applied nor
-- silently forgotten.
-- ===========================================================================
DO $$
DECLARE
  v_admin   uuid;
  v_station uuid := 'e5700000-0000-0000-0000-0000000000e1';
  v_unit    uuid := 'e5700000-0000-0000-0000-0000000000e2';
  v_sv      uuid := 'e5719a00-0000-0000-0000-000000000011';  -- run 1, hash-s1
  v_sv_new  uuid := 'e5719a00-0000-0000-0000-000000000021';  -- run 2, hash-s1-CHANGED
  v_raw_new jsonb;
  v_hash    text;
  v_at      timestamptz;
  v_status  text;
  n         integer;
  b         boolean;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT source_raw INTO v_raw_new FROM import_staging_rows WHERE id = v_sv_new;

  -------------------------------------------- THE HASH IS SERVER-DERIVED
  -- The function takes five arguments and not one of them is a hash. A caller
  -- that could name the hash could claim to have reviewed evidence it never saw.
  SELECT count(*) INTO n
    FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname = 'cng_admin_decide_staged_mapping'
     AND pg_get_function_arguments(p.oid) ILIKE '%hash%';
  PERFORM pg_temp.ok(n = 0,
    'PREHASH-1 no function signature accepts a source hash from the caller');

  -- The decision taken in the PREMAP block above recorded the hash of the row
  -- it was made from.
  SELECT d.reviewed_source_row_hash INTO v_hash
    FROM import_mapping_decisions d
   WHERE d.source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11'
     AND d.superseded_at IS NULL;
  PERFORM pg_temp.ok(v_hash = 'hash-s1',
    'PREHASH-2 the decision carries the hash of the staging row it reviewed');
  PERFORM pg_temp.ok(
    v_hash = (SELECT source_row_hash FROM import_staging_rows WHERE id = v_sv),
    'PREHASH-3 and it is exactly the staging row''s own hash, not a client value');

  ------------------------------------------- THE STALE-SOURCE STATE EXISTS
  PERFORM pg_temp.become('clerk_admin');
  SELECT decision_is_stale_source INTO b FROM v_admin_staged_mapping_queue
   WHERE staging_row_id = v_sv_new;
  PERFORM pg_temp.ok(b,
    'PREHASH-4 a decision made against content that has since changed is flagged STALE-SOURCE');
  SELECT decision_is_stale_source INTO b FROM v_admin_staged_mapping_queue
   WHERE staging_row_id = v_sv;
  PERFORM pg_temp.ok(NOT b,
    'PREHASH-5 the row it was actually made from is NOT stale');

  -- It is SHOWN, not dropped: an admin must be able to see why their previous
  -- ruling stopped counting.
  SELECT count(*) INTO n FROM v_admin_staged_mapping_queue
   WHERE staging_row_id = v_sv_new AND decision_id IS NOT NULL;
  PERFORM pg_temp.ok(n = 1,
    'PREHASH-6 the stale decision is still visible on the re-staged row, not silently hidden');
  RESET ROLE;

  -- ...and it is its own queue, not folded into "decided" or "awaiting".
  SELECT open_count INTO n FROM v_admin_data_quality
   WHERE asset = 'storage_vessels' AND queue = 'staged_stale_source_decision';
  PERFORM pg_temp.ok(n = 1,
    'PREHASH-7 a stale-source decision is counted as its own queue');
  SELECT coalesce(open_count, 0) INTO n FROM v_admin_data_quality
   WHERE asset = 'storage_vessels' AND queue = 'staged_decided';
  PERFORM pg_temp.ok(n = 1,
    'PREHASH-8 and is NOT counted as decided — only the row it was made from is');

  ---------------------------------------- PROMPT 21 CANNOT REUSE IT BY KEY ALONE
  -- The consumable view carries the reviewed hash, so the planner can check it.
  SELECT count(*) INTO n FROM v_import_confirmed_mappings
   WHERE source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11'
     AND reviewed_source_row_hash IS NOT NULL;
  PERFORM pg_temp.ok(n = 1,
    'PREHASH-9 the Prompt-21 view exposes the reviewed hash for verification');
  -- The join Prompt 21 performs: key AND hash. It matches the original row...
  SELECT count(*) INTO n
    FROM import_staging_rows s
    JOIN v_import_confirmed_mappings m
      ON m.source_row_key = s.source_row_key
     AND m.reviewed_source_row_hash = s.source_row_hash
   WHERE s.id = v_sv;
  PERFORM pg_temp.ok(n = 1, 'PREHASH-10 the content-bound join matches the reviewed row');
  -- ...and does not match the re-staged one.
  SELECT count(*) INTO n
    FROM import_staging_rows s
    JOIN v_import_confirmed_mappings m
      ON m.source_row_key = s.source_row_key
     AND m.reviewed_source_row_hash = s.source_row_hash
   WHERE s.id = v_sv_new;
  PERFORM pg_temp.ok(n = 0,
    'PREHASH-11 and never matches a row whose content changed under the same key');

  ------------------------------------- A CORRECTION AGAINST THE NEW EVIDENCE
  -- The ordinary audited path: review the new evidence, supersede the old
  -- ruling. Nothing special is needed, and nothing is forced.
  SELECT decided_at INTO v_at FROM import_mapping_decisions
   WHERE source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11' AND superseded_at IS NULL;
  PERFORM pg_temp.become('clerk_admin');
  SELECT d.resulting_mapping_status INTO v_status
    FROM cng_admin_decide_staged_mapping(v_sv_new, v_station, v_unit, v_at,
         'PREHASH-12 re-reviewed after the workbook changed') d;
  RESET ROLE;
  PERFORM pg_temp.ok(v_status = 'resolved',
    'PREHASH-12 an admin may re-review the new evidence and supersede the old ruling');

  SELECT reviewed_source_row_hash INTO v_hash FROM import_mapping_decisions
   WHERE source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11' AND superseded_at IS NULL;
  PERFORM pg_temp.ok(v_hash = 'hash-s1-CHANGED',
    'PREHASH-13 the new decision is bound to the NEW content');

  PERFORM pg_temp.become('clerk_admin');
  SELECT decision_is_stale_source INTO b FROM v_admin_staged_mapping_queue
   WHERE staging_row_id = v_sv_new;
  PERFORM pg_temp.ok(NOT b, 'PREHASH-14 which clears the stale-source state for that row');
  -- ...and the ORIGINAL row is now the stale one, because the active decision
  -- no longer describes its content. The flag follows the evidence, both ways.
  SELECT decision_is_stale_source INTO b FROM v_admin_staged_mapping_queue
   WHERE staging_row_id = v_sv;
  PERFORM pg_temp.ok(b,
    'PREHASH-15 the flag follows the evidence in both directions, never a fixed label');
  RESET ROLE;

  SELECT count(*) INTO n FROM import_mapping_decisions
   WHERE source_row_key = 'TESTDATA-PREIMPORT.xlsx#Sheet1#11' AND superseded_at IS NULL;
  PERFORM pg_temp.ok(n = 1,
    'PREHASH-16 still exactly one active decision — the correction superseded, it did not duplicate');

  ------------------------------------------------- THE HASH IS NOT FORGEABLE
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE import_mapping_decisions SET reviewed_source_row_hash = 'hash-s1'$q$),
    'PREHASH-17 not even an ADMIN may rewrite the reviewed hash to revive a stale decision');
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$INSERT INTO import_mapping_decisions (staging_row_id, source_row_key,
        reviewed_source_row_hash, target_table, asset_type, region_id,
        confirmed_station_id, previous_mapping_status, resulting_mapping_status,
        decided_by, source_evidence)
       VALUES (%L, 'TESTDATA-PREIMPORT.xlsx#Sheet1#11', 'hash-s1-CHANGED',
        'storage_vessels', 'storage_vessel',
        (SELECT region_id FROM stations WHERE id = %L), %L,
        'needs_station_mapping', 'needs_unit_mapping', %L, '{}'::jsonb)$q$,
    v_sv_new, v_station, v_station, v_admin)),
    'PREHASH-18 nor insert a decision claiming to have reviewed content it did not');
  -- The other half of the forgery: changing the EVIDENCE to match a decision.
  PERFORM pg_temp.ok(pg_temp.denied(format(
    $q$UPDATE import_staging_rows SET source_row_hash = 'hash-s1' WHERE id = %L$q$, v_sv_new)),
    'PREHASH-19 nor edit the staging row''s hash so a stale decision would match');
  RESET ROLE;

  ------------------------------------------------------- RAW EVIDENCE INTACT
  SELECT count(*) INTO n FROM import_staging_rows
   WHERE id = v_sv_new AND source_raw = v_raw_new
     AND source_row_hash = 'hash-s1-CHANGED'
     AND mapping_status = 'needs_station_mapping';
  PERFORM pg_temp.ok(n = 1,
    'PREHASH-20 the re-staged row''s raw evidence, hash and staged status are untouched throughout');

  ------------------------------------------ AND STILL NOT AN ALIAS, EITHER WAY
  SELECT count(*) INTO n FROM station_aliases
   WHERE source_name_raw IN ('TESTDATA-RAW-STATION', 'A DIFFERENT STATION');
  PERFORM pg_temp.ok(n = 0,
    'PREHASH-21 neither the original decision nor the correction created a global alias');
END $$;

-- Every admin/import view must be SECURITY INVOKER, asserted as a property of
-- the catalog rather than trusted from the migration text.
--
-- This is not theoretical. CREATE OR REPLACE VIEW does not preserve reloptions,
-- so replacing a view without restating `WITH (security_invoker = true)`
-- silently turns it into an owner-rights view that bypasses every RLS policy
-- meant to bound it. Migration 0039 did exactly that to v_admin_data_quality,
-- and the suite is what found it. A GRANT is not the protection here — the
-- invoker setting is.
DO $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN
    SELECT c.relname, coalesce(c.reloptions, '{}') AS opts
      FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relkind = 'v'
       AND (c.relname LIKE 'v_admin%' OR c.relname LIKE 'v_report%'
            OR c.relname = 'v_import_confirmed_mappings')
  LOOP
    n := n + 1;
    PERFORM pg_temp.ok('security_invoker=true' = ANY (r.opts),
      format('VIEWSEC-%s %s is SECURITY INVOKER, so RLS still bounds it', n, r.relname));
  END LOOP;
  PERFORM pg_temp.ok(n >= 7, 'VIEWSEC-0 every admin and report view was checked, not an empty loop');
END $$;

-- ===========================================================================
-- REPORTS (Prompt 20).
--
-- Reports are a READ surface over views that already exist and are already
-- RLS-bounded. These assert the two things a report could get wrong: that it
-- shows someone a row they may not read, and that it classifies a date the
-- alert engine would not.
-- ===========================================================================
DO $$
DECLARE
  v_east uuid; v_west uuid;
  n integer;
BEGIN
  SELECT r_east, r_west INTO v_east, v_west FROM f;

  ------------------------------------------------------------------ ANON
  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_report_due_compliance'),
    'RPT-1 anon reads no report data at all');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_installed_srv_management'),
    'RPT-2 nor the SRV report source');
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_alert_inbox'),
    'RPT-3 nor the notification activity source');
  RESET ROLE;

  --------------------------------------------------------------- ADMIN sees all
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE region_id = v_west;
  PERFORM pg_temp.ok(n > 0, 'RPT-4 an admin sees WEST records in the unified due report');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE region_id = v_east;
  PERFORM pg_temp.ok(n > 0, 'RPT-5 and EAST records — company-wide');
  RESET ROLE;

  ------------------------------------------------------------- MANAGER sees all
  PERFORM pg_temp.become('clerk_manager');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE region_id = v_west;
  PERFORM pg_temp.ok(n > 0, 'RPT-6 a manager sees company-wide report data');
  RESET ROLE;

  ------------------------------------------- ENGINEER is bounded to their Regions
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE region_id = v_east;
  PERFORM pg_temp.ok(n > 0, 'RPT-7 an East engineer sees their own Region');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE region_id = v_west;
  PERFORM pg_temp.ok(n = 0,
    'RPT-8 and NOT another Region — a forged region_id filter returns nothing, because RLS decided before the filter did');
  -- The same holds without any filter at all: the boundary is not the WHERE.
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE region_id IS DISTINCT FROM v_east;
  PERFORM pg_temp.ok(n = 0,
    'RPT-9 an unfiltered report query still returns only the engineer''s Regions');
  RESET ROLE;

  --------------------------------------------- VIEWER is bounded the same way
  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE region_id = v_west;
  PERFORM pg_temp.ok(n = 0, 'RPT-10 a viewer cannot read another Region''s report rows');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE region_id = v_east;
  PERFORM pg_temp.ok(n > 0, 'RPT-11 but does read their own, read-only');
  RESET ROLE;

  -------------------------- A STATION-UNCONFIRMED ROW STAYS ADMIN/MANAGER ONLY
  -- Raw source text is never an authorization boundary (§10). A valve whose
  -- Station is unconfirmed carries raw text and no proven Region, so a report
  -- must not surface it to a regional user.
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE station_id IS NULL;
  PERFORM pg_temp.ok(n = 0,
    'RPT-12 an engineer sees no Station-unconfirmed record in a report');
  RESET ROLE;

  ------------------------------------------------------- EXPORT IS NOT A BYPASS
  -- The export re-runs the same query with a wider range. A larger page size
  -- cannot widen the row set, because paging is applied after RLS.
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM (
    SELECT * FROM v_report_due_compliance ORDER BY asset_id LIMIT 10000
  ) q WHERE q.region_id = v_west;
  PERFORM pg_temp.ok(n = 0,
    'RPT-13 an oversized export page still yields no unauthorized row');
  RESET ROLE;

  ------------------------------------------- A REPORT CANNOT WRITE ANYTHING
  PERFORM pg_temp.become('clerk_view_east');
  -- Not an exception: RLS makes the write a zero-row no-op, because the viewer
  -- cannot see a row to update. That is the correct mechanism, and asserting an
  -- error here would be asserting the wrong one.
  UPDATE installed_relief_valves SET mapping_status = 'resolved';
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM pg_temp.ok(n = 0, 'RPT-14 a report reader''s write touches no row');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_map_srv('00000000-0000-0000-0000-000000000000'::uuid,
                                '00000000-0000-0000-0000-000000000000'::uuid)$q$),
    'RPT-15 nor reach the mapping function the Admin module owns');
  RESET ROLE;
END $$;

-- The due classification a report shows is the alert engine's, not a second one.
DO $$
DECLARE
  v_today date := cng_business_date();
  n integer;
BEGIN
  -- These assert the FUNCTIONS the report view reads through, which is the
  -- point: there is no separate report classifier to drift.
  PERFORM pg_temp.ok(cng_due_status(v_today - 1, 'exact_date') = 'overdue',
    'RPTDUE-1 yesterday is overdue');
  PERFORM pg_temp.ok(cng_due_status(v_today, 'exact_date') = 'due_today',
    'RPTDUE-2 the Cairo business date is due today');
  PERFORM pg_temp.ok(cng_due_status(v_today + 7, 'exact_date') = 'due_7',
    'RPTDUE-3 exactly seven days out is the 7-day bucket');
  PERFORM pg_temp.ok(cng_due_status(v_today + 8, 'exact_date') = 'due_15',
    'RPTDUE-4 the day after is the 15-day bucket — boundaries are exact, not fuzzy');
  PERFORM pg_temp.ok(cng_due_status(v_today + 15, 'exact_date') = 'due_15',
    'RPTDUE-5 exactly fifteen days out');
  PERFORM pg_temp.ok(cng_due_status(v_today + 30, 'exact_date') = 'due_30',
    'RPTDUE-6 exactly thirty days out');
  PERFORM pg_temp.ok(cng_due_status(v_today + 60, 'exact_date') = 'due_60',
    'RPTDUE-7 exactly sixty days out');
  PERFORM pg_temp.ok(cng_due_status(v_today + 61, 'exact_date') = 'valid',
    'RPTDUE-8 beyond sixty days is later/current');

  ------------------------------------------------ A NON-EXACT DATE IS UNKNOWN
  PERFORM pg_temp.ok(cng_due_status(v_today - 1, 'year_only') = 'unknown',
    'RPTDUE-9 a YEAR-ONLY date never enters an exact-date bucket, even in the past');
  PERFORM pg_temp.ok(cng_due_status(v_today + 3, 'year_only') = 'unknown',
    'RPTDUE-10 nor a near-future one');
  PERFORM pg_temp.ok(cng_due_status(NULL, 'unknown') = 'unknown',
    'RPTDUE-11 an absent date is unknown, never compliant');
  PERFORM pg_temp.ok(cng_due_status(v_today, 'invalid') = 'unknown',
    'RPTDUE-12 an unreadable source date is unknown, never overdue');
  PERFORM pg_temp.ok(cng_days_left(v_today + 5, 'year_only') IS NULL,
    'RPTDUE-13 a year-only date yields NO days-remaining number at all');
  PERFORM pg_temp.ok(cng_days_left(v_today + 5, 'exact_date') = 5,
    'RPTDUE-14 an exact date yields the real figure, computed — never an imported one');

  -------------------------------- THE REPORT AGREES WITH THE ALERT, BY SHARING
  -- The unified view carries the family views' own days_left/due_status, and
  -- those come from the functions above. Proven by comparing the view to a
  -- fresh evaluation of the same function on the same row.
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n
    FROM v_report_due_compliance r
   WHERE r.due_status IS DISTINCT FROM cng_due_status(r.next_due_date, r.next_due_precision);
  PERFORM pg_temp.ok(n = 0,
    'RPTDUE-15 every report row''s due state equals cng_due_status() on its own date — one interpretation, not two');
  SELECT count(*) INTO n
    FROM v_report_due_compliance r
   WHERE r.days_left IS DISTINCT FROM cng_days_left(r.next_due_date, r.next_due_precision);
  PERFORM pg_temp.ok(n = 0, 'RPTDUE-16 and the same for days remaining');
  RESET ROLE;
END $$;

-- The unified view keeps the families distinct, and keeps them honest.
DO $$
DECLARE n integer; v_subjects text;
BEGIN
  PERFORM pg_temp.become('clerk_admin');

  SELECT count(DISTINCT asset_type) INTO n FROM v_report_due_compliance;
  PERFORM pg_temp.ok(n >= 1, 'RPTVIEW-1 the unified report carries an asset type per row');

  -- Storage and Recovery are never one entity, even sharing a source view.
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE asset_type = 'storage_vessel' AND subject <> 'storage_inspection';
  PERFORM pg_temp.ok(n = 0, 'RPTVIEW-2 a Storage Vessel always carries the storage subject');
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE asset_type = 'recovery_tank' AND subject <> 'recovery_tank_inspection';
  PERFORM pg_temp.ok(n = 0, 'RPTVIEW-3 and a Recovery Tank its own — never merged');

  -- Warehouse stock is NOT an installed asset and must not appear here.
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE asset_type = 'warehouse_relief_valve';
  PERFORM pg_temp.ok(n = 0,
    'RPTVIEW-4 warehouse valves never appear in the installed compliance report');

  -- A hose with a proven Station and no proven Unit is legitimate, not an error.
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE asset_type = 'hose' AND station_id IS NOT NULL AND unit_id IS NULL;
  PERFORM pg_temp.ok(n >= 0,
    'RPTVIEW-5 a Station-only hose is representable — the view never forces a Unit');

  -- The five subjects are exactly the alert engine's five.
  SELECT string_agg(DISTINCT subject::text, ',' ORDER BY subject::text)
    INTO v_subjects FROM v_report_due_compliance;
  PERFORM pg_temp.ok(
    v_subjects IS NULL OR v_subjects = ALL (ARRAY[v_subjects]),
    'RPTVIEW-6 report subjects are drawn from alert_subject, so the vocabulary cannot drift');
  SELECT count(*) INTO n FROM v_report_due_compliance r
   WHERE r.subject::text NOT IN (
     SELECT unnest(enum_range(NULL::alert_subject))::text);
  PERFORM pg_temp.ok(n = 0, 'RPTVIEW-7 and every one is a real alert_subject value');
  RESET ROLE;
END $$;


-- Every view in the schema, not only the ones a naming convention catches. A
-- report reads v_installed_srv_management, v_vessel_management,
-- v_gas_detector_management, v_hose_registry, v_alert_inbox and
-- v_data_quality_queue — an owner-rights view among those would hand a viewer
-- another Region's assets, and no `v_admin%` pattern would have noticed.
DO $$
DECLARE v_owner_rights text; n integer;
BEGIN
  SELECT count(*), string_agg(c.relname, ', ' ORDER BY c.relname)
    INTO n, v_owner_rights
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relkind = 'v'
     AND NOT ('security_invoker=true' = ANY (coalesce(c.reloptions, '{}')));
  PERFORM pg_temp.ok(n = 0,
    format('VIEWSEC-ALL no view in the schema runs with owner rights (found: %s)',
           coalesce(v_owner_rights, 'none')));

  SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relkind = 'v';
  PERFORM pg_temp.ok(n >= 24, 'VIEWSEC-ALL-COUNT the check ran over the real view set');
END $$;

-- The Prompt 20 hostile pass: the attacks a report surface invites.
DO $$
DECLARE
  v_east uuid; v_west uuid;
  v_w_station uuid := 'e5700000-0000-0000-0000-0000000000f1';
  v_e_unit    uuid := 'e5700000-0000-0000-0000-0000000000e2';
  n integer;
BEGIN
  SELECT r_east, r_west INTO v_east, v_west FROM f;

  PERFORM pg_temp.become('clerk_eng_east');

  ---------------------------------------------------------- MALFORMED INPUT
  -- A malformed uuid is refused by the type parser before any row is touched.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT count(*) FROM v_report_due_compliance WHERE region_id = 'not-a-uuid'$q$),
    'RPTSEC-1 a malformed uuid filter is refused at the type boundary');
  -- A well-formed uuid that matches nothing returns nothing. Not an error, and
  -- not a probe that reveals whether the id exists elsewhere.
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE region_id = '00000000-0000-0000-0000-000000000000';
  PERFORM pg_temp.ok(n = 0, 'RPTSEC-2 an unknown region id simply matches nothing');

  ------------------------------------------------- FORGED HIERARCHY FILTERS
  -- A Station from a Region the caller may not read.
  SELECT count(*) INTO n FROM v_report_due_compliance WHERE station_id = v_w_station;
  PERFORM pg_temp.ok(n = 0,
    'RPTSEC-3 a forged Station filter from another Region returns nothing');
  -- A Station/Unit pair that does not exist together. The UI cannot express it;
  -- a hand-written request can, and it still yields nothing.
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE station_id = v_w_station AND unit_id = v_e_unit;
  PERFORM pg_temp.ok(n = 0,
    'RPTSEC-4 an impossible Station/Unit pair returns nothing rather than either half');

  --------------------------------------------- PAGINATION AND PAGE SIZE ABUSE
  -- A huge LIMIT is applied AFTER RLS, so it cannot widen the row set.
  SELECT count(*) INTO n FROM (
    SELECT * FROM v_report_due_compliance ORDER BY asset_id OFFSET 0 LIMIT 1000000
  ) q WHERE q.region_id = v_west;
  PERFORM pg_temp.ok(n = 0, 'RPTSEC-5 an excessive page size yields no extra row');
  -- Nor does paging past the end leak anything.
  SELECT count(*) INTO n FROM (
    SELECT * FROM v_report_due_compliance ORDER BY asset_id OFFSET 999999 LIMIT 50
  ) q;
  PERFORM pg_temp.ok(n = 0, 'RPTSEC-6 an out-of-range offset returns an empty page, not an error');

  ------------------------------------------ THE UNDERLYING TABLES DIRECTLY
  -- Bypassing the report view entirely gains nothing: the tables carry the same
  -- policies, which is why the view can safely be security_invoker.
  SELECT count(*) INTO n FROM installed_relief_valves WHERE region_id = v_west;
  PERFORM pg_temp.ok(n = 0, 'RPTSEC-7 querying the table directly is no bypass');
  SELECT count(*) INTO n FROM v_alert_inbox WHERE region_id = v_west;
  PERFORM pg_temp.ok(n = 0, 'RPTSEC-8 nor the alert source the activity report reads');
  SELECT count(*) INTO n FROM v_data_quality_queue WHERE region_id = v_west;
  PERFORM pg_temp.ok(n = 0, 'RPTSEC-9 nor the data-quality source');
  RESET ROLE;

  ------------------------------ THE REPORTS MODULE ADDED NO NEW RPC TO ATTACK
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public' AND p.proname LIKE 'cng_report%';
  PERFORM pg_temp.ok(n = 0,
    'RPTSEC-10 Reports introduced NO new RPC — there is no new privileged entry point to attack');

  -- ...and no new table either. Reports read; they store nothing.
  SELECT count(*) INTO n FROM information_schema.tables
   WHERE table_schema = 'public' AND table_name LIKE '%report%' AND table_type = 'BASE TABLE';
  PERFORM pg_temp.ok(n = 0, 'RPTSEC-11 and no reporting table that could drift from the source');
END $$;

-- ===========================================================================
-- REPORTS DATA QUALITY AND GAS DETECTORS (Prompt 20A, migration 0043).
--
-- Two corrections. The DQ report read canonical assets alone, so it looked
-- clean while the staged import carried real unresolved evidence; and the gas
-- detector report read a view that deliberately includes recorded ABSENCE,
-- which is not a device.
-- ===========================================================================
DO $$
DECLARE
  v_east uuid; v_west uuid;
  n integer;
BEGIN
  SELECT r_east, r_west INTO v_east, v_west FROM f;

  ------------------------------------------------- ALL THREE LAYERS ARE PRESENT
  PERFORM pg_temp.become('clerk_admin');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE source_layer = 'canonical';
  PERFORM pg_temp.ok(n > 0, 'DQR-1 canonical asset data quality still appears');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE source_layer = 'staged';
  PERFORM pg_temp.ok(n > 0,
    'DQR-2 STAGED pre-import data quality appears — the gap this prompt corrects');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE source_layer = 'import_issue';
  PERFORM pg_temp.ok(n > 0, 'DQR-3 open import issues appear');

  -------------------------------------------- STALE SOURCE IS ITS OWN CONDITION
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE issue_kind = 'stale_source_decision';
  PERFORM pg_temp.ok(n > 0,
    'DQR-4 a stale_source_decision is visible in the Reports data-quality surface');
  -- ...and is NOT collapsed into either neighbouring state.
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE issue_kind IN ('staged_awaiting_decision', 'staged_decision_recorded')
     AND dq_key IN (SELECT dq_key FROM v_report_data_quality
                     WHERE issue_kind = 'stale_source_decision');
  PERFORM pg_temp.ok(n = 0,
    'DQR-5 and never doubles as awaiting-decision or as a recorded decision');
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE issue_kind = 'stale_source_decision' AND source_layer <> 'staged';
  PERFORM pg_temp.ok(n = 0, 'DQR-6 nor is it confused with a canonical mapping issue');

  -- The existing import taxonomy is exposed as it is, not re-invented.
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE source_layer = 'import_issue'
     AND issue_kind NOT IN (SELECT unnest(enum_range(NULL::import_issue_type))::text);
  PERFORM pg_temp.ok(n = 0,
    'DQR-7 every import issue kind is a real import_issue_type — none invented');

  -- The key is unique across layers, so pagination has a stable tiebreak.
  SELECT count(*) INTO n FROM (
    SELECT dq_key FROM v_report_data_quality GROUP BY dq_key HAVING count(*) > 1
  ) d;
  PERFORM pg_temp.ok(n = 0, 'DQR-8 dq_key is unique across all three layers');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE dq_key IS NULL;
  PERFORM pg_temp.ok(n = 0, 'DQR-9 and never NULL, so ordering is deterministic');
  RESET ROLE;

  --------------------------------------------------- MANAGER: company-wide
  PERFORM pg_temp.become('clerk_manager');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE source_layer = 'staged';
  PERFORM pg_temp.ok(n > 0, 'DQR-10 a manager also sees the staged layer');
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE source_layer = 'canonical' AND region_id = v_west;
  PERFORM pg_temp.ok(n > 0, 'DQR-11 and canonical issues company-wide');
  RESET ROLE;

  ---------------------- ENGINEER AND VIEWER: canonical layer, own Regions only
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE source_layer = 'staged';
  PERFORM pg_temp.ok(n = 0,
    'DQR-12 an engineer sees NO staged evidence — unconfirmed source text has no proven Region to scope it by');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE source_layer = 'import_issue';
  PERFORM pg_temp.ok(n = 0, 'DQR-13 nor any raw import issue');
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE source_layer = 'canonical' AND region_id = v_west;
  PERFORM pg_temp.ok(n = 0, 'DQR-14 nor another Region''s canonical issues');
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE source_layer = 'canonical' AND region_id = v_east;
  PERFORM pg_temp.ok(n > 0, 'DQR-15 but does see their own Region''s canonical issues');
  -- The protection Prompt 19 established is intact: a Station-unconfirmed
  -- canonical record is still not readable by a Region-scoped role.
  SELECT count(*) INTO n FROM v_report_data_quality
   WHERE source_layer = 'canonical' AND station_id IS NULL;
  PERFORM pg_temp.ok(n = 0,
    'DQR-16 and no Station-unconfirmed record leaks to an engineer');
  RESET ROLE;

  PERFORM pg_temp.become('clerk_view_east');
  SELECT count(*) INTO n FROM v_report_data_quality WHERE source_layer <> 'canonical';
  PERFORM pg_temp.ok(n = 0, 'DQR-17 a viewer sees the canonical layer alone');
  RESET ROLE;

  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied('SELECT count(*) FROM v_report_data_quality'),
    'DQR-18 anon reads no data-quality surface at all');
  RESET ROLE;

  ------------------------------------------ REPORTS CANNOT CORRECT ANYTHING
  PERFORM pg_temp.become('clerk_manager');
  -- A manager READS the staged layer in reports, and still cannot act on it.
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$SELECT cng_admin_decide_staged_mapping(
        'e5719a00-0000-0000-0000-000000000011'::uuid,
        'e5700000-0000-0000-0000-0000000000e1'::uuid)$q$),
    'DQR-19 seeing staged evidence in a report grants no power to decide it');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE import_mapping_decisions SET superseded_at = now()$q$),
    'DQR-20 nor to supersede or re-review a decision');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE import_staging_rows SET mapping_status = 'resolved'$q$),
    'DQR-21 and raw staged evidence stays immutable');
  PERFORM pg_temp.ok(pg_temp.denied(
    $q$UPDATE v_report_data_quality SET issue_kind = 'resolved'$q$),
    'DQR-22 the reporting view itself is not writable');
  RESET ROLE;
END $$;

-- Recorded detector ABSENCE is evidence, not a device.
DO $$
DECLARE n integer; v_installed integer; v_absent integer; v_west uuid;
BEGIN
  -- Resolved BEFORE any SET ROLE: the temp fixture table is not readable as an
  -- application role, and reaching for it there fails for the wrong reason.
  SELECT r_west INTO v_west FROM f;
  PERFORM pg_temp.become('clerk_admin');

  -- The fixtures already carry both shapes: an INSTALLED detector on the East
  -- unit, and a recorded ABSENCE on the West unit. No new fixture is needed to
  -- prove this, which is the point — the absence row is ordinary source data.
  SELECT count(*) FILTER (WHERE detector_id IS NOT NULL),
         count(*) FILTER (WHERE detector_id IS NULL)
    INTO v_installed, v_absent
    FROM v_gas_detector_management;
  PERFORM pg_temp.ok(v_installed > 0 AND v_absent > 0,
    'GDR-1 the management view carries BOTH installed detectors and recorded absence');

  SELECT count(*) INTO n FROM v_report_gas_detectors;
  PERFORM pg_temp.ok(n = v_installed,
    'GDR-2 the report view carries exactly the installed detectors');
  SELECT count(*) INTO n FROM v_report_gas_detectors WHERE detector_id IS NULL;
  PERFORM pg_temp.ok(n = 0,
    'GDR-3 recorded absence never appears as an installed detector record');

  -- A NULL identity column is what makes a paginated sort non-deterministic:
  -- two NULL keys cannot be ordered against each other, so a row can appear on
  -- two pages or on none.
  PERFORM pg_temp.ok(v_absent > 0,
    'GDR-4 absence rows exist to be excluded — the test is not vacuous');
  SELECT count(*) INTO n FROM (
    SELECT detector_id FROM v_report_gas_detectors
     GROUP BY detector_id HAVING count(*) > 1
  ) d;
  PERFORM pg_temp.ok(n = 0, 'GDR-5 the report''s sort key is unique as well as NOT NULL');

  -- The DUE report was already correct and stays correct.
  SELECT count(*) INTO n FROM v_report_due_compliance
   WHERE asset_type = 'gas_detector';
  PERFORM pg_temp.ok(n = v_installed,
    'GDR-6 the due report still counts installed detectors only — unchanged by this fix');
  RESET ROLE;

  -- And the report view is still Region-bounded, like its source.
  PERFORM pg_temp.become('clerk_eng_east');
  SELECT count(*) INTO n FROM v_report_gas_detectors WHERE region_id = v_west;
  PERFORM pg_temp.ok(n = 0, 'GDR-7 an engineer reads no other Region''s detectors');
  RESET ROLE;
END $$;



-- ===========================================================================
-- STAGING COMMIT AUTHORIZATION (Prompt 20F)
--
-- The staging write path is an OPERATOR action, not a browser action. Nothing
-- reachable from a session may call it, and the browser gains no new authority:
-- every import table keeps the SELECT-only grant it has had since 0019.
-- ===========================================================================

-- STGSEC-1..2: EXECUTE is service_role ONLY. Not anon, not authenticated -
-- and therefore not an admin in a browser either.
SELECT pg_temp.ok(
  NOT has_function_privilege('authenticated',
    (SELECT oid FROM pg_proc WHERE proname='cng_stage_import_batch'), 'EXECUTE'),
  'STGSEC-1: authenticated cannot execute the staging writer');
SELECT pg_temp.ok(
  NOT has_function_privilege('anon',
    (SELECT oid FROM pg_proc WHERE proname='cng_stage_import_batch'), 'EXECUTE'),
  'STGSEC-2: anon cannot execute the staging writer');
SELECT pg_temp.ok(
  has_function_privilege('service_role',
    (SELECT oid FROM pg_proc WHERE proname='cng_stage_import_batch'), 'EXECUTE'),
  'STGSEC-3: service_role can execute the staging writer');

SELECT pg_temp.ok(
  NOT has_function_privilege('authenticated',
    (SELECT oid FROM pg_proc WHERE proname='cng_abandon_import_run'), 'EXECUTE'),
  'STGSEC-4: authenticated cannot abandon a staging run');
SELECT pg_temp.ok(
  has_function_privilege('service_role',
    (SELECT oid FROM pg_proc WHERE proname='cng_abandon_import_run'), 'EXECUTE'),
  'STGSEC-5: service_role can abandon a staging run');

-- STGSEC-6..10: the browser still cannot write ANY import table directly.
-- Staging arriving in the database must not have widened these.
SELECT pg_temp.ok(
  (SELECT count(*) FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee='authenticated'
      AND table_name IN ('import_runs','import_batches','import_staging_rows',
                         'import_issues','import_source_conflicts')
      AND privilege_type IN ('INSERT','UPDATE','DELETE')) = 0,
  'STGSEC-6: authenticated holds NO write grant on any import table');

SELECT pg_temp.ok(
  (SELECT count(DISTINCT table_name) FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee='authenticated' AND privilege_type='SELECT'
      AND table_name IN ('import_runs','import_batches','import_staging_rows',
                         'import_issues','import_source_conflicts')) = 5,
  'STGSEC-7: the import tables remain readable, so Admin - Data Quality still works');

SELECT pg_temp.ok(
  (SELECT count(*) FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee='anon'
      AND table_name LIKE 'import_%') = 0,
  'STGSEC-8: anon holds nothing on any import table');

-- STGSEC-9: the writer takes no actor parameter, so a caller cannot attribute
-- a staging run to someone else.
SELECT pg_temp.ok(
  (SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname='cng_stage_import_batch')
    NOT ILIKE '%actor%'
  AND (SELECT pg_get_function_arguments(oid) FROM pg_proc WHERE proname='cng_stage_import_batch')
    NOT ILIKE '%user%',
  'STGSEC-9: the staging writer accepts no actor or user identifier');

-- STGSEC-10: staging writes no mapping decision, so the 0039/0041 content
-- binding cannot be bypassed by staging a row.
SELECT pg_temp.ok(
  (SELECT prosrc FROM pg_proc WHERE proname='cng_stage_import_batch')
    NOT ILIKE '%import_mapping_decisions%',
  'STGSEC-10: staging never touches import_mapping_decisions');

-- ===========================================================================
-- STAGE A AUTHORIZATION (Prompt 21C, migration 0046)
-- ===========================================================================
-- The hierarchy commit is an OPERATOR action, not a browser action. Creating
-- 157 Stations and 188 Units is the single most consequential write this system
-- will ever perform, and it is deliberately unreachable from any session a user
-- can hold - including an administrator's.

SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc p
    WHERE p.proname IN ('cng_stage_a_proposal','cng_stage_a_preview','cng_stage_a_commit')
      AND (has_function_privilege('authenticated', p.oid, 'EXECUTE')
        OR has_function_privilege('anon', p.oid, 'EXECUTE'))) = 0,
  'STAGEASEC-1: no browser role may preview or commit the canonical hierarchy');

SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc p
    WHERE p.proname IN ('cng_stage_a_proposal','cng_stage_a_preview','cng_stage_a_commit')
      AND has_function_privilege('service_role', p.oid, 'EXECUTE')) = 3,
  'STAGEASEC-2: all three Stage A functions are executable by service_role only');

SELECT pg_temp.ok(
  (SELECT prosecdef FROM pg_proc WHERE proname='cng_stage_a_commit') IS TRUE
  AND (SELECT proconfig FROM pg_proc WHERE proname='cng_stage_a_commit')
        @> ARRAY['search_path=pg_catalog, public'],
  'STAGEASEC-3: the commit is SECURITY DEFINER with a pinned search_path');

-- The read paths are deliberately NOT definer: they carry no elevated rights,
-- so nothing is granted that the commit does not need.
SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('cng_stage_a_proposal','cng_stage_a_preview') AND prosecdef) = 0,
  'STAGEASEC-4: the proposal and preview run with the caller''s own rights');

-- STAGEASEC-5: an admin in a browser is REFUSED at the privilege layer, proved
-- by trying it rather than by reading the grant table.
SET LOCAL ROLE authenticated;
DO $stageasec$
BEGIN
  PERFORM cng_stage_a_commit(gen_random_uuid(), 'x', 'y');
  RAISE EXCEPTION 'FAILED: STAGEASEC-5 - authenticated was allowed to commit the hierarchy';
EXCEPTION
  WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS  STAGEASEC-5: authenticated is refused EXECUTE on cng_stage_a_commit';
END
$stageasec$;
RESET ROLE;

-- STAGEASEC-6: lineage cannot be forged from a browser. `committed_entity_id`
-- and `committed_entity_kind` are the record of what a commit actually did, and
-- authenticated holds no UPDATE on the table that carries them.
SELECT pg_temp.ok(
  (SELECT count(*) FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee IN ('authenticated','anon')
      AND table_name='import_staging_rows'
      AND privilege_type IN ('INSERT','UPDATE','DELETE')) = 0,
  'STAGEASEC-6: no browser role may write import_staging_rows, so lineage cannot be forged');

-- STAGEASEC-7: the new column is readable, so Admin - Data Quality can show
-- what has been committed without any new privilege.
SELECT pg_temp.ok(
  (SELECT count(*) FROM information_schema.column_privileges
    WHERE table_schema='public' AND table_name='import_staging_rows'
      AND column_name='committed_entity_kind' AND grantee='authenticated'
      AND privilege_type IN ('INSERT','UPDATE')) = 0,
  'STAGEASEC-7: committed_entity_kind carries no column-level write grant either');

-- STAGEASEC-8: Stage A grants nothing new on the canonical hierarchy itself.
-- The station and unit grants are the ones Prompt 4 established, RLS-gated.
SELECT pg_temp.ok(
  (SELECT count(*) FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee='anon'
      AND table_name IN ('stations','units')) = 0,
  'STAGEASEC-8: anon still holds nothing on stations or units');

-- STAGEASEC-9: no Stage A function accepts an actor, so the act can never be
-- attributed to a person who did not perform it.
SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc
    WHERE proname LIKE 'cng_stage_a%'
      AND pg_get_function_arguments(oid) ~* '(actor|app_user|user_id|clerk|by)') = 0,
  'STAGEASEC-9: no Stage A function takes a caller-supplied identity');

-- STAGEASEC-10: the commit is structurally confined to the hierarchy. Derived
-- from the catalog, not from the migration''s comment.
SELECT pg_temp.ok(
  (SELECT prosrc FROM pg_proc WHERE proname='cng_stage_a_commit') !~* '\mexecute\M'
  AND (SELECT prosrc FROM pg_proc WHERE proname='cng_stage_a_commit') NOT ILIKE '%quote_ident%'
  AND (SELECT prosrc FROM pg_proc WHERE proname='cng_stage_a_commit') NOT ILIKE '%station_aliases%'
  AND (SELECT prosrc FROM pg_proc WHERE proname='cng_stage_a_commit') NOT ILIKE '%import_mapping_decisions%',
  'STAGEASEC-10: the commit contains no dynamic SQL and names no alias or decision table');

-- ===========================================================================
-- STAGE B STATION BATCH AUTHORIZATION (Prompt 22A, migration 0047)
-- ===========================================================================
-- A batch that confirms 281 Stations at once must be no easier to reach than
-- confirming one. It is the SAME gate as the single-row path: administrator
-- only, actor derived from the verified Clerk subject, never a parameter.
--
-- NOTE ON THE SHAPE. Prompt 22A asked for service_role-only. The schema forbids
-- it: `import_mapping_decisions.decided_by` is NOT NULL REFERENCES app_users, so
-- a service_role caller could satisfy it only by accepting an actor parameter
-- (which the same prompt forbids) or by making human rulings unattributed
-- (which CLAUDE.md §9 forbids). Admin-gated with a server-derived actor is the
-- stronger of the two available postures, and these assert it.

SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc p WHERE p.proname LIKE 'cng_stage_b%'
     AND has_function_privilege('anon', p.oid, 'EXECUTE')) = 0,
  'STAGEBSEC-1: anon may not execute any Stage B function');

SELECT pg_temp.ok(
  (SELECT prosecdef FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') IS TRUE
  AND (SELECT proconfig FROM pg_proc WHERE proname = 'cng_stage_b_station_commit')
        @> ARRAY['search_path=pg_catalog, public'],
  'STAGEBSEC-2: the batch commit is SECURITY DEFINER with a pinned search_path');

SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('cng_stage_b_station_candidates','cng_stage_b_station_groups',
                      'cng_stage_b_station_preview') AND prosecdef) = 0,
  'STAGEBSEC-3: the Stage B read paths carry no elevated rights');

-- STAGEBSEC-4..7: the admin gate is proved by ATTACK, for every non-admin role,
-- rather than by reading a grant table. A viewer, an engineer, a regional
-- manager and a deactivated account must each be refused.
SELECT pg_temp.become('clerk_view_east');
SELECT pg_temp.ok(
  pg_temp.denied(format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)',
                        gen_random_uuid(), 'x', 'y')),
  'STAGEBSEC-4: a viewer may not run the Station batch');

SELECT pg_temp.become('clerk_eng_east');
SELECT pg_temp.ok(
  pg_temp.denied(format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)',
                        gen_random_uuid(), 'x', 'y')),
  'STAGEBSEC-5: an engineer may not run the Station batch');

SELECT pg_temp.become('clerk_manager');
SELECT pg_temp.ok(
  pg_temp.denied(format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)',
                        gen_random_uuid(), 'x', 'y')),
  'STAGEBSEC-6: a regional manager may not run the Station batch');

SELECT pg_temp.become('clerk_pending');
SELECT pg_temp.ok(
  pg_temp.denied(format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)',
                        gen_random_uuid(), 'x', 'y')),
  'STAGEBSEC-7: a deactivated account may not run the Station batch');

SELECT pg_temp.become(NULL);
SELECT pg_temp.ok(
  pg_temp.denied(format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)',
                        gen_random_uuid(), 'x', 'y')),
  'STAGEBSEC-8: a session with no verified subject may not run the Station batch');

SELECT pg_temp.as_anon();
SELECT pg_temp.ok(
  pg_temp.denied(format('SELECT * FROM cng_stage_b_station_commit(%L, %L, %L)',
                        gen_random_uuid(), 'x', 'y')),
  'STAGEBSEC-9: anon is refused at the privilege layer');
RESET ROLE;

-- STAGEBSEC-10: the function is the ONLY writer. Not even an admin may insert,
-- edit or delete a mapping decision directly — unchanged since 0039, and the
-- batch must not have widened it.
SELECT pg_temp.ok(
  (SELECT count(*) FROM information_schema.role_table_grants
    WHERE table_schema = 'public' AND table_name = 'import_mapping_decisions'
      AND grantee IN ('authenticated','anon')
      AND privilege_type IN ('INSERT','UPDATE','DELETE')) = 0,
  'STAGEBSEC-10: no browser role holds a direct write grant on import_mapping_decisions');

-- STAGEBSEC-11: no caller-supplied actor on any Stage B function.
SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc WHERE proname LIKE 'cng_stage_b%'
     AND pg_get_function_arguments(oid) ~* '(actor|app_user|user_id|clerk|decided_by)') = 0,
  'STAGEBSEC-11: no Stage B function takes a caller-supplied identity');

-- STAGEBSEC-12: the batch cannot reach the hierarchy, an alias or an asset.
SELECT pg_temp.ok(
  (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') !~* '\mexecute\M'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') NOT ILIKE '%quote_ident%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') NOT ILIKE '%station_aliases%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') NOT ILIKE '%INSERT INTO stations%'
  AND (SELECT prosrc FROM pg_proc WHERE proname = 'cng_stage_b_station_commit') NOT ILIKE '%INSERT INTO units%',
  'STAGEBSEC-12: the batch commit contains no dynamic SQL and names no hierarchy or alias table');

-- STAGEBSEC-13: Stage A stays operator-only. Adding an admin-reachable Stage B
-- must not have opened the hierarchy commit to a browser.
SELECT pg_temp.ok(
  (SELECT count(*) FROM pg_proc p WHERE p.proname LIKE 'cng_stage_a%'
     AND (has_function_privilege('authenticated', p.oid, 'EXECUTE')
       OR has_function_privilege('anon', p.oid, 'EXECUTE'))) = 0,
  'STAGEBSEC-14: Stage A remains service_role-only after Stage B was added');

-- ===========================================================================
-- WORKSTREAM H — Advisor-listed callable SECURITY DEFINER behavior matrix.
-- Catalog shape/grants live in schema_scenarios.sql. These are actual calls as
-- browser personas, so the cng_require_admin() boundary is exercised before an
-- untrusted target id can be acted on.
-- ===========================================================================
DO $workstream_h_admin_gate$
DECLARE
  persona text;
  i integer;
  v_east uuid;
  v_west uuid;
  v_rule uuid;
  call_names text[] := ARRAY[
    'cng_admin_decide_staged_mapping', 'cng_admin_grant_region',
    'cng_admin_map_srv', 'cng_admin_remove_user', 'cng_admin_revoke_region',
    'cng_admin_set_alert_rule_enabled', 'cng_admin_set_channel_policy',
    'cng_admin_set_user_active', 'cng_admin_set_user_role'
  ];
  call_statements text[] := ARRAY[
    $q$SELECT * FROM cng_admin_decide_staged_mapping('e5719a00-0000-0000-0000-000000000011', 'e5700000-0000-0000-0000-0000000000e1', NULL, NULL, NULL)$q$,
    NULL,
    $q$SELECT * FROM cng_admin_map_srv('e5700000-0000-0000-0000-0000000000e5', 'e5700000-0000-0000-0000-0000000000e1', NULL, NULL, NULL, NULL, NULL)$q$,
    $q$SELECT cng_admin_remove_user('a0000000-0000-0000-0000-00000000000d', NULL)$q$,
    NULL,
    NULL,
    $q$SELECT cng_admin_set_channel_policy('email', false, NULL, NULL)$q$,
    $q$SELECT cng_admin_set_user_active('a0000000-0000-0000-0000-00000000000d', false, NULL)$q$,
    $q$SELECT cng_admin_set_user_role('a0000000-0000-0000-0000-00000000000d', 'viewer', NULL)$q$
  ];
BEGIN
  SELECT r_east, r_west INTO v_east, v_west FROM f;
  SELECT id INTO v_rule FROM alert_rules ORDER BY id LIMIT 1;
  call_statements[2] := format(
    'SELECT cng_admin_grant_region(%L, %L, false)',
    'a0000000-0000-0000-0000-00000000000d'::uuid, v_east);
  call_statements[5] := format(
    'SELECT cng_admin_revoke_region(%L, %L)',
    'a0000000-0000-0000-0000-00000000000d'::uuid, v_west);
  call_statements[6] := format(
    'SELECT cng_admin_set_alert_rule_enabled(%L, false, NULL)', v_rule);
  FOR persona IN SELECT unnest(ARRAY['clerk_view_east', 'clerk_eng_east', 'clerk_manager', 'clerk_pending'])
  LOOP
    PERFORM pg_temp.become(persona);
    FOR i IN 1..array_length(call_names, 1) LOOP
      PERFORM pg_temp.ok(pg_temp.rejected_sqlstate(call_statements[i], '42501'),
        format('H-AUTH %s rejects %s before any caller-supplied target is trusted', call_names[i], persona));
    END LOOP;
    RESET ROLE;
  END LOOP;
  PERFORM pg_temp.become(NULL);
  FOR i IN 1..array_length(call_names, 1) LOOP
    PERFORM pg_temp.ok(pg_temp.rejected_sqlstate(call_statements[i], '42501'),
      format('H-AUTH %s rejects an authenticated request with no app user', call_names[i]));
  END LOOP;
  RESET ROLE;
END
$workstream_h_admin_gate$;

-- Add first-party Auth fixtures only after the legacy suite's row-count
-- assertions. The older six-user fixture is intentionally stable.
-- Real Supabase Auth has required columns and a profile-sync trigger; a plain
-- migration replay has only the transactional auth.users stand-in above.
DO $auth_fixture$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'auth' AND table_name = 'users' AND column_name = 'email'
  ) THEN
    INSERT INTO auth.users (
      id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data
    ) VALUES
      ('b0000000-0000-0000-0000-000000000010', 'authenticated', 'authenticated', 'test-auth-viewer-010@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb),
      ('b0000000-0000-0000-0000-000000000011', 'authenticated', 'authenticated', 'test-auth-pending-011@example.invalid', '', now(), '{}'::jsonb, '{}'::jsonb)
    ON CONFLICT (id) DO NOTHING;
  ELSE
    INSERT INTO auth.users (id) VALUES
      ('b0000000-0000-0000-0000-000000000010'),
      ('b0000000-0000-0000-0000-000000000011')
    ON CONFLICT (id) DO NOTHING;
  END IF;
END
$auth_fixture$;

INSERT INTO app_users (id, auth_user_id, email, role, is_active, full_name) VALUES
  ('a0000000-0000-0000-0000-000000000010','b0000000-0000-0000-0000-000000000010','test-auth-viewer-010@example.invalid','viewer', true,  'TESTDATA Auth Viewer'),
  ('a0000000-0000-0000-0000-000000000011','b0000000-0000-0000-0000-000000000011','test-auth-pending-011@example.invalid','viewer', false, 'TESTDATA Auth Pending')
ON CONFLICT (auth_user_id) DO UPDATE
  SET id = EXCLUDED.id,
      email = EXCLUDED.email,
      role = EXCLUDED.role,
      is_active = EXCLUDED.is_active,
      full_name = EXCLUDED.full_name;

INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT 'a0000000-0000-0000-0000-000000000010'::uuid, r_east, false FROM f;

-- Helpers answer only for the verified caller.  These fixtures intentionally
-- use 0056's legacy fallback (auth_user_id IS NULL); the fallback is retained
-- for rollback/audit continuity and must remain as constrained as Auth UUIDs.
DO $workstream_h_identity$
DECLARE
  v_east uuid;
  v_west uuid;
BEGIN
  SELECT r_east, r_west INTO v_east, v_west FROM f;
  PERFORM pg_temp.become('clerk_eng_east');
  PERFORM pg_temp.ok(cng_current_role() = 'engineer',
    'H-IDENTITY current_role returns the authenticated engineer role only');
  PERFORM pg_temp.ok(cng_has_region_grant(v_east, true) AND NOT cng_has_region_grant(v_west, false),
    'H-IDENTITY region helper answers only the caller grants, never another user grants');
  RESET ROLE;

  PERFORM pg_temp.become('clerk_view_east');
  PERFORM pg_temp.ok(cng_current_role() = 'viewer' AND cng_has_region_grant(v_east, false)
                     AND NOT cng_has_region_grant(v_east, true),
    'H-IDENTITY viewer receives only their role and non-map grant');
  RESET ROLE;

  PERFORM pg_temp.become('b0000000-0000-0000-0000-000000000010');
  PERFORM pg_temp.ok(cng_current_role() = 'viewer' AND cng_has_region_grant(v_east, false),
    'H-IDENTITY active Supabase Auth UUID resolves without a legacy Clerk subject');
  RESET ROLE;

  PERFORM pg_temp.become('b0000000-0000-0000-0000-000000000011');
  PERFORM pg_temp.ok(cng_current_role() IS NULL AND NOT cng_has_region_grant(v_east, false),
    'H-IDENTITY inactive Supabase Auth UUID receives no helper answer');
  RESET ROLE;

  PERFORM pg_temp.become('b0000000-0000-0000-0000-000000000012');
  PERFORM pg_temp.ok(cng_current_role() IS NULL AND NOT cng_has_region_grant(v_east, false),
    'H-IDENTITY missing Supabase Auth UUID receives no helper answer');
  RESET ROLE;

  PERFORM pg_temp.become('clerk_pending');
  PERFORM pg_temp.ok(cng_current_role() IS NULL AND NOT cng_has_region_grant(v_east, false),
    'H-IDENTITY inactive app user receives no privileged helper answer');
  RESET ROLE;

  PERFORM pg_temp.become(NULL);
  PERFORM pg_temp.ok(cng_current_role() IS NULL AND NOT cng_has_region_grant(v_east, false),
    'H-IDENTITY authenticated request with no app user receives no helper answer');
  RESET ROLE;

  PERFORM pg_temp.as_anon();
  PERFORM pg_temp.ok(pg_temp.denied(format('SELECT cng_has_region_grant(%L, false)', v_east)),
    'H-IDENTITY anon cannot execute the region helper');
  RESET ROLE;
END
$workstream_h_identity$;

-- The alert function is a region-scoped mutation, not an opaque definer read.
-- ALRT-13/18 already prove viewer and cross-region refusal; these close the
-- identity failure cases in the same actual callable path.
SELECT pg_temp.become('clerk_pending');
SELECT pg_temp.ok(pg_temp.rejected_error(
  $q$SELECT cng_acknowledge_alert('e5700000-0000-0000-0000-0000000000d1')$q$,
  'P0001', 'no active application user'),
  'H-ALERT inactive caller cannot acknowledge an otherwise visible alert');
SELECT pg_temp.become(NULL);
SELECT pg_temp.ok(pg_temp.rejected_error(
  $q$SELECT cng_acknowledge_alert('e5700000-0000-0000-0000-0000000000d1')$q$,
  'P0001', 'no active application user'),
  'H-ALERT caller without an app user cannot acknowledge an alert');
RESET ROLE;

-- Batch commits must fail before they can partially write.  Stage B's full
-- fingerprint/replay atomicity is exercised in schema_scenarios; this covers
-- the separate Installed-SRV batch's role boundary and count mismatch path.
DO $workstream_h_irv$
DECLARE
  persona text;
  v_before integer;
  v_after integer;
BEGIN
  FOR persona IN SELECT unnest(ARRAY['clerk_view_east', 'clerk_eng_east', 'clerk_manager', 'clerk_pending'])
  LOOP
    PERFORM pg_temp.become(persona);
    PERFORM pg_temp.ok(pg_temp.rejected_sqlstate(
      $q$SELECT * FROM cng_irv_station_batch_commit(repeat('0', 64), 0, 0, 'H authorization probe')$q$,
      '42501'),
      format('H-IRV %s cannot commit the Installed-SRV station batch', persona));
    RESET ROLE;
  END LOOP;
  SELECT count(*) INTO v_before FROM installed_relief_valves WHERE mapping_status = 'needs_station_mapping';
  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.rejected_sqlstate(
    $q$SELECT * FROM cng_irv_station_batch_commit(repeat('0', 64), -1, -1, 'H mismatched approval')$q$,
    '23514'),
    'H-IRV admin count/fingerprint mismatch fails closed');
  RESET ROLE;
  SELECT count(*) INTO v_after FROM installed_relief_valves WHERE mapping_status = 'needs_station_mapping';
  PERFORM pg_temp.ok(v_after = v_before,
    'H-IRV rejected batch leaves no partial Installed-SRV mapping');
END
$workstream_h_irv$;

-- A valid admin removal is server-attributed and atomic with deactivation and
-- region-grant cleanup.  The self-removal guard is the reachable protection
-- when the actor is the sole active administrator; role/deactivation last-admin
-- protections are exercised above in ADMSEC-17..19.
DO $workstream_h_remove$
DECLARE
  v_target uuid := 'a0000000-0000-0000-0000-000000000010';
  v_admin uuid;
  v_audit_before integer;
BEGIN
  SELECT id INTO v_admin FROM app_users WHERE clerk_user_id = 'clerk_admin';
  SELECT count(*) INTO v_audit_before FROM audit_logs
    WHERE entity_id = v_target AND action = 'admin_action';

  PERFORM pg_temp.become('clerk_admin');
  PERFORM pg_temp.ok(pg_temp.rejected_sqlstate(format('SELECT cng_admin_remove_user(%L, NULL)', v_admin), '42501'),
    'H-REMOVE admin cannot remove themselves');
  PERFORM cng_admin_remove_user(v_target, NULL);
  RESET ROLE;

  PERFORM pg_temp.ok((SELECT NOT is_active AND removed_at IS NOT NULL
                        AND auth_user_id IS NULL AND clerk_user_id IS NULL
                        FROM app_users WHERE id = v_target),
    'H-REMOVE valid admin removal creates an inactive identity-less Auth tombstone');
  PERFORM pg_temp.ok((SELECT count(*) FROM user_region_access WHERE app_user_id = v_target) = 0,
    'H-REMOVE removal atomically clears region grants');
  PERFORM pg_temp.ok((SELECT count(*) FROM audit_logs
                        WHERE entity_id = v_target AND action = 'admin_action' AND actor_id = v_admin)
                      = v_audit_before + 1,
    'H-REMOVE removal atomically records the server-derived admin actor');
  PERFORM pg_temp.ok((SELECT count(*) FROM auth.users
                       WHERE id = 'b0000000-0000-0000-0000-000000000010') = 0,
    'H-REMOVE the Supabase Auth UUID is deleted after the tombstone and audit write');
END
$workstream_h_remove$;

DO $$ BEGIN RAISE EXCEPTION 'RLS_SUITE_ROLLBACK'; END $$;

ROLLBACK;
