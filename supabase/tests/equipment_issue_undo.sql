-- equipment_issue_undo.sql — regression suite for 20261003090000_equipment_issue_undo.sql (owner request 2026-10-03:
-- undo a hose / gas detector issue, as the relief valves can).
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.become(p_sub text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE FUNCTION pg_temp.try_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM pg_temp.become(p_sub);
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;

-- Each action runs in its OWN statement: a check in the same statement would read the snapshot from before it.
CREATE TEMP TABLE outcome (k text PRIMARY KEY, res text);
CREATE FUNCTION pg_temp.act(p_k text, p_sub text, p_sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO outcome VALUES (p_k, pg_temp.try_as(p_sub, p_sql)); END $$;
CREATE FUNCTION pg_temp.ok(p_k text) RETURNS boolean LANGUAGE sql AS $$ SELECT (SELECT res FROM outcome WHERE k = p_k) = 'OK' $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('8f000000-0000-0000-0000-00000000000a','equ_admin','admin',true,'TESTDATA EQU Admin'),
  ('8f000000-0000-0000-0000-00000000000b','equ_viewer','viewer',true,'TESTDATA EQU Viewer');
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT '8f000000-0000-0000-0000-00000000000b'::uuid, id, false FROM regions WHERE name = 'West';
INSERT INTO stations (id, region_id, station_name) SELECT '8f100000-0000-0000-0000-000000000001', id, 'TEU ALPHA' FROM regions WHERE name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '8f200000-0000-0000-0000-000000000001', '8f100000-0000-0000-0000-000000000001', id, 'TEU ALPHA 1' FROM regions WHERE name = 'East';
-- Installed at ALPHA: one hose (Unit unknown) and one detector (on Unit 1).
INSERT INTO hoses (id, region_id, station_id, mapping_status, serial_number, serial_status, last_test_date, last_test_precision)
SELECT '8f300000-0000-0000-0000-000000000001', id, '8f100000-0000-0000-0000-000000000001', 'needs_unit_mapping', 'TEU-H-OLD', 'assigned', '2024-01-10', 'exact_date'
  FROM regions WHERE name = 'East';
INSERT INTO gas_detectors (id, region_id, station_id, unit_id, mapping_status, serial_number, serial_status, manufacturer, model)
SELECT '8f300000-0000-0000-0000-000000000002', id, '8f100000-0000-0000-0000-000000000001', '8f200000-0000-0000-0000-000000000001',
       'resolved', 'TEU-G-OLD', 'assigned', 'Honeywell', 'XNX' FROM regions WHERE name = 'East';

-- Store: two calibrated hoses and one new detector.
SELECT pg_temp.act('s1', 'equ_admin', $q$SELECT cng_equipment_stock_add('hose','available_calibrated',ARRAY['TEU-H-A','TEU-H-B'],NULL,NULL,NULL,'hose',
      350,'BAR',NULL,NULL,'2026-09-01'::date,'2027-09-01'::date,NULL,NULL)$q$);
SELECT pg_temp.act('s2', 'equ_admin', $q$SELECT cng_equipment_stock_add('gas_detector','available_new',ARRAY['TEU-G-A'],NULL,'Honeywell','XNX',NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)$q$);
CREATE FUNCTION pg_temp.stock(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM equipment_stock WHERE serial_number = p $$;
CREATE FUNCTION pg_temp.issue_of(p text) RETURNS uuid LANGUAGE sql AS $$
  SELECT e.id FROM equipment_issues e JOIN equipment_stock w ON w.id = e.stock_id WHERE w.serial_number = p ORDER BY e.issued_at DESC LIMIT 1 $$;

SELECT pg_temp.ck('EQU-1 undo is SECURITY DEFINER with a pinned search_path; anon cannot run it; the issue view runs with the caller''s rights',
  (SELECT bool_and(p.prosecdef AND p.proconfig IS NOT NULL AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
     FROM pg_proc p WHERE p.proname = 'cng_equipment_issue_undo')
  AND (SELECT count(*) = 3 FROM pg_class c WHERE c.relname IN ('v_equipment_issue_log','v_equipment_field_log','v_equipment_emergency')
         AND 'security_invoker=true' = ANY (c.reloptions)));

-- Issue hose A in place of the old hose, then undo it: back in the warehouse.
SELECT pg_temp.act('i1', 'equ_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8f100000-0000-0000-0000-000000000001', NULL,
      '8f300000-0000-0000-0000-000000000001', true, NULL)$q$, pg_temp.stock('TEU-H-A'),
      (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEU-H-A')));
SELECT pg_temp.ck('EQU-2 the issue is listed in the Issued movement with its replaced hose at the station',
  (SELECT res FROM outcome WHERE k = 'i1') = 'OK'
  AND (SELECT status = 'replaced_at_station' AND replaced_serial = 'TEU-H-OLD' FROM v_equipment_issue_log WHERE issued_serial = 'TEU-H-A'));
SELECT pg_temp.act('u0', 'equ_viewer', format($q$SELECT cng_equipment_issue_undo(%L, 'to_stock')$q$, pg_temp.issue_of('TEU-H-A')));
SELECT pg_temp.act('u1', 'equ_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'somewhere')$q$, pg_temp.issue_of('TEU-H-A')));
SELECT pg_temp.ck('EQU-3 a non-admin is refused (42501) and an unknown destination is refused (22023); nothing changed',
  (SELECT res FROM outcome WHERE k = 'u0') = '42501' AND (SELECT res FROM outcome WHERE k = 'u1') = '22023'
  AND (SELECT cancelled_at IS NULL FROM equipment_issues WHERE id = pg_temp.issue_of('TEU-H-A')));
SELECT pg_temp.act('u2', 'equ_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'to_stock', 'wrong station')$q$, pg_temp.issue_of('TEU-H-A')));
SELECT pg_temp.ck('EQU-4 undo to the warehouse: the old hose is back in its position, the issued one left the station',
  (SELECT res FROM outcome WHERE k = 'u2') = 'OK'
  AND (SELECT archived_at IS NULL FROM hoses WHERE id = '8f300000-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM hoses WHERE serial_number = 'TEU-H-A' AND archived_at IS NULL));
SELECT pg_temp.ck('EQU-5 the stock record is back exactly as it was (calibrated, no destination) and in the store view',
  (SELECT availability_status = 'available_calibrated' AND target_station_id IS NULL FROM equipment_stock WHERE serial_number = 'TEU-H-A')
  AND EXISTS (SELECT 1 FROM v_equipment_stock WHERE serial_number = 'TEU-H-A'));
SELECT pg_temp.ck('EQU-6 the issue is cancelled (not deleted), leaves the Issued and Emergency lists; the Log entry is closed, not deleted',
  (SELECT cancelled_at IS NOT NULL AND cancel_action = 'to_stock' AND cancelled_by = '8f000000-0000-0000-0000-00000000000a'
     FROM equipment_issues WHERE id = pg_temp.issue_of('TEU-H-A'))
  AND NOT EXISTS (SELECT 1 FROM v_equipment_issue_log WHERE issued_serial = 'TEU-H-A')
  AND NOT EXISTS (SELECT 1 FROM v_equipment_emergency WHERE issued_serial = 'TEU-H-A')
  AND NOT EXISTS (SELECT 1 FROM v_equipment_field_log WHERE installed_hose_id = '8f300000-0000-0000-0000-000000000001')
  AND (SELECT count(*) = 1 FROM equipment_field_log WHERE installed_hose_id = '8f300000-0000-0000-0000-000000000001' AND archived_at IS NOT NULL));
SELECT pg_temp.act('u3', 'equ_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'to_stock')$q$, pg_temp.issue_of('TEU-H-A')));
SELECT pg_temp.ck('EQU-7 undoing twice is refused (PT409)', (SELECT res FROM outcome WHERE k = 'u3') = 'PT409');

-- The reinstated old hose can be replaced again (its closed Log entry no longer blocks it).
SELECT pg_temp.act('i2', 'equ_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8f100000-0000-0000-0000-000000000001', NULL,
      '8f300000-0000-0000-0000-000000000001')$q$, pg_temp.stock('TEU-H-B'),
      (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEU-H-B')));
SELECT pg_temp.act('r1', 'equ_admin', format($q$SELECT cng_equipment_log_receive(ARRAY[%L]::uuid[])$q$,
      (SELECT id FROM equipment_field_log WHERE installed_hose_id = '8f300000-0000-0000-0000-000000000001' AND archived_at IS NULL)));
SELECT pg_temp.act('u4', 'equ_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'to_stock')$q$, pg_temp.issue_of('TEU-H-B')));
SELECT pg_temp.ck('EQU-8 the old hose can be replaced again; once it is received back, undoing that issue is refused and changes nothing',
  (SELECT res FROM outcome WHERE k = 'i2') = 'OK' AND (SELECT res FROM outcome WHERE k = 'r1') = 'OK'
  AND (SELECT res FROM outcome WHERE k = 'u4') = 'PT409'
  AND (SELECT cancelled_at IS NULL FROM equipment_issues WHERE id = pg_temp.issue_of('TEU-H-B'))
  AND EXISTS (SELECT 1 FROM hoses WHERE serial_number = 'TEU-H-B' AND archived_at IS NULL));

-- Detector A in place of the old detector, undone while it is still at the station.
SELECT pg_temp.act('i3', 'equ_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8f100000-0000-0000-0000-000000000001', NULL,
      '8f300000-0000-0000-0000-000000000002', true, NULL)$q$, pg_temp.stock('TEU-G-A'),
      (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEU-G-A')));
SELECT pg_temp.act('u5', 'equ_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'await_return')$q$, pg_temp.issue_of('TEU-G-A')));
SELECT pg_temp.ck('EQU-9 undo with the item still at the station: old detector back on its Unit, the issued one in the Log awaiting return',
  (SELECT res FROM outcome WHERE k = 'i3') = 'OK' AND (SELECT res FROM outcome WHERE k = 'u5') = 'OK'
  AND (SELECT archived_at IS NULL AND unit_id = '8f200000-0000-0000-0000-000000000001' FROM gas_detectors WHERE id = '8f300000-0000-0000-0000-000000000002')
  AND (SELECT status = 'at_station' AND reason = 'issue_undone' AND serial_number = 'TEU-G-A' FROM v_equipment_field_log WHERE kind = 'gas_detector')
  AND (SELECT availability_status = 'sent_to_station_received' FROM equipment_stock WHERE serial_number = 'TEU-G-A'));
SELECT pg_temp.act('r2', 'equ_admin', format($q$SELECT cng_equipment_log_receive(ARRAY[%L]::uuid[])$q$,
      (SELECT id FROM v_equipment_field_log WHERE reason = 'issue_undone')));
SELECT pg_temp.ck('EQU-10 receiving it returns its OWN store record (no second record), under calibration',
  (SELECT res FROM outcome WHERE k = 'r2') = 'OK'
  AND (SELECT count(*) = 1 FROM equipment_stock WHERE serial_number = 'TEU-G-A')
  AND (SELECT availability_status = 'available_in_store_uc' AND target_station_id IS NULL FROM equipment_stock WHERE serial_number = 'TEU-G-A')
  AND (SELECT returned_stock_id = pg_temp.stock('TEU-G-A') FROM equipment_field_log WHERE reason = 'issue_undone'));
SELECT pg_temp.ck('EQU-11 history and audit name the server-derived admin; nothing was hard-deleted',
  (SELECT count(*) FROM equipment_history WHERE event = 'issue_undone' AND actor_id = '8f000000-0000-0000-0000-00000000000a') = 4
  AND (SELECT count(*) FROM audit_logs WHERE actor_label = 'equipment_issue_undo' AND actor_id = '8f000000-0000-0000-0000-00000000000a') = 2
  AND (SELECT count(*) FROM equipment_issues) = 3);
SELECT pg_temp.act('v1', 'equ_viewer', $q$DO $d$ BEGIN
  IF (SELECT count(*) FROM v_equipment_issue_log) > 0 THEN RAISE EXCEPTION 'visible outside its Region'; END IF; END $d$$q$);
SELECT pg_temp.ck('EQU-12 a viewer of another Region does not see this Region''s issues', (SELECT res FROM outcome WHERE k = 'v1') = 'OK');
ROLLBACK;
