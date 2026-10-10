-- equipment_workflow.sql — regression suite for 20261002120000_equipment_workflow.sql (owner request 2026-10-02:
-- Hoses and Gas Detectors get the relief-valve tabs: Warehouse, Log, Calibration / Hydrotest, Emergency).
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
  ('8e000000-0000-0000-0000-00000000000a','eq_admin','admin',true,'TESTDATA EQ Admin'),
  ('8e000000-0000-0000-0000-00000000000b','eq_viewer','viewer',true,'TESTDATA EQ Viewer');
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT '8e000000-0000-0000-0000-00000000000b'::uuid, id, false FROM regions WHERE name = 'West';
INSERT INTO stations (id, region_id, station_name) SELECT '8e100000-0000-0000-0000-000000000001', id, 'TEQ ALPHA' FROM regions WHERE name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '8e200000-0000-0000-0000-000000000001', '8e100000-0000-0000-0000-000000000001', id, 'TEQ ALPHA 1' FROM regions WHERE name = 'East';
-- Installed at ALPHA: one hose (Unit unknown) and one detector (on Unit 1).
INSERT INTO hoses (id, region_id, station_id, mapping_status, serial_number, serial_status, last_test_date, last_test_precision)
SELECT '8e300000-0000-0000-0000-000000000001', id, '8e100000-0000-0000-0000-000000000001', 'needs_unit_mapping', 'TEQ-H-OLD', 'assigned', '2024-01-10', 'exact_date'
  FROM regions WHERE name = 'East';
INSERT INTO gas_detectors (id, region_id, station_id, unit_id, mapping_status, serial_number, serial_status, manufacturer, model)
SELECT '8e300000-0000-0000-0000-000000000002', id, '8e100000-0000-0000-0000-000000000001', '8e200000-0000-0000-0000-000000000001',
       'resolved', 'TEQ-G-OLD', 'assigned', 'Honeywell', 'XNX' FROM regions WHERE name = 'East';

-- ------------------------------------------------------------------ security shape
SELECT pg_temp.ck('EQ-1 every workflow table has RLS and no browser write grant',
  (SELECT bool_and(c.relrowsecurity) FROM pg_class c WHERE c.relname IN
     ('equipment_stock','equipment_issues','equipment_field_log','equipment_calibration_jobs','equipment_history'))
  AND NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants g
                   WHERE g.grantee IN ('authenticated','anon') AND g.privilege_type IN ('INSERT','UPDATE','DELETE')
                     AND g.table_name IN ('equipment_stock','equipment_issues','equipment_field_log','equipment_calibration_jobs','equipment_history')));
SELECT pg_temp.ck('EQ-2 the four views run with the caller''s rights',
  (SELECT count(*) = 4 FROM pg_class c WHERE c.relname IN ('v_equipment_stock','v_equipment_field_log','v_equipment_emergency','v_equipment_calibration')
      AND 'security_invoker=true' = ANY (c.reloptions)));
SELECT pg_temp.ck('EQ-3 every mutation is SECURITY DEFINER with a pinned search_path; anon cannot run any',
  (SELECT bool_and(p.prosecdef AND p.proconfig IS NOT NULL AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
     FROM pg_proc p WHERE p.proname IN ('cng_equipment_stock_add','cng_equipment_issue','cng_equipment_log_receive',
       'cng_equipment_calibration_send','cng_equipment_calibration_returned','cng_equipment_calibration_certify')));
SELECT pg_temp.act('a1', 'eq_viewer', $q$SELECT cng_equipment_stock_add('hose','available_new',ARRAY['TEQ-X'],NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)$q$);
SELECT pg_temp.ck('EQ-4 a non-admin is refused (42501) and nothing is written',
  (SELECT res FROM outcome WHERE k = 'a1') = '42501'
  AND NOT EXISTS (SELECT 1 FROM equipment_stock WHERE serial_number = 'TEQ-X'));

-- ------------------------------------------------------------------ add
SELECT pg_temp.act('a2', 'eq_admin', $q$SELECT cng_equipment_stock_add('hose','available_calibrated',ARRAY['TEQ-H-NEW'],NULL,NULL,NULL,'1/2" hose',
      350,'BAR',NULL,NULL,'2026-09-01'::date,'2027-09-01'::date,'HS 1',NULL)$q$);
SELECT pg_temp.act('a3', 'eq_admin', $q$SELECT cng_equipment_stock_add('gas_detector','available_new',NULL,2,'Honeywell','XNX',NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)$q$);
SELECT pg_temp.ck('EQ-5 the admin adds a calibrated hose and two un-serialled new detectors; attribution is server-side',
  (SELECT res FROM outcome WHERE k = 'a2') = 'OK'
  AND (SELECT res FROM outcome WHERE k = 'a3') = 'OK'
  AND (SELECT count(*) FROM equipment_stock WHERE created_by = '8e000000-0000-0000-0000-00000000000a') = 3
  AND (SELECT count(*) FROM equipment_stock WHERE kind = 'gas_detector' AND serial_status = 'not_yet_assigned' AND serial_number IS NULL) = 2);
SELECT pg_temp.act('a4', 'eq_admin', $q$SELECT cng_equipment_stock_add('hose','available_new',ARRAY['TEQ-H-NEW'],NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)$q$);
-- 23505 since 20261010110000 (a serial recorded anywhere is refused, as for relief valves); PT409 before.
SELECT pg_temp.ck('EQ-6 a serial already in the store is refused; a detector cannot carry hose pressures',
  (SELECT res FROM outcome WHERE k = 'a4') = '23505'
  AND (SELECT working_pressure_value IS NULL FROM equipment_stock WHERE kind = 'gas_detector' LIMIT 1));
SELECT pg_temp.ck('EQ-7 no next date is invented: a new item added without one has none',
  (SELECT bool_and(next_date IS NULL AND next_precision = 'unknown') FROM equipment_stock WHERE kind = 'gas_detector'));

-- ------------------------------------------------------------------ issue
SELECT pg_temp.act('a5', 'eq_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8e100000-0000-0000-0000-000000000001', NULL,
      '8e300000-0000-0000-0000-000000000001', true, 'burst')$q$,
      (SELECT id FROM equipment_stock WHERE serial_number = 'TEQ-H-NEW'), (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEQ-H-NEW')));
SELECT pg_temp.ck('EQ-8 issuing the hose in place of the old one creates the installed hose, archives and logs the old one',
  (SELECT res FROM outcome WHERE k = 'a5') = 'OK'
  AND (SELECT archived_at IS NOT NULL FROM hoses WHERE id = '8e300000-0000-0000-0000-000000000001')
  AND (SELECT count(*) FROM hoses WHERE serial_number = 'TEQ-H-NEW' AND archived_at IS NULL AND last_test_date = '2026-09-01'
        AND next_test_date = '2027-09-01' AND working_pressure_value = 350) = 1
  AND (SELECT count(*) FROM equipment_field_log WHERE installed_hose_id = '8e300000-0000-0000-0000-000000000001' AND returned_at IS NULL) = 1
  AND (SELECT availability_status = 'sent_to_station_received' FROM equipment_stock WHERE serial_number = 'TEQ-H-NEW'));
SELECT pg_temp.ck('EQ-9 the Unit is never invented: the old hose had none, so the new one is needs_unit_mapping',
  (SELECT mapping_status = 'needs_unit_mapping' AND unit_id IS NULL FROM hoses WHERE serial_number = 'TEQ-H-NEW'));
SELECT pg_temp.ck('EQ-10 an emergency issue appears in the Emergency view; the replaced hose reads "at_station"',
  (SELECT replaced_status = 'at_station' AND replaced_serial = 'TEQ-H-OLD' FROM v_equipment_emergency WHERE kind = 'hose'));
SELECT pg_temp.act('a6', 'eq_admin', format($q$SELECT cng_equipment_issue(%L, '2000-01-01', '8e100000-0000-0000-0000-000000000001')$q$,
      (SELECT id FROM equipment_stock WHERE kind = 'gas_detector' ORDER BY id LIMIT 1)));
SELECT pg_temp.ck('EQ-11 a stale selection is refused (the store row changed since it was read)',
  (SELECT res FROM outcome WHERE k = 'a6') NOT IN ('OK')
  AND NOT EXISTS (SELECT 1 FROM equipment_issues WHERE kind = 'gas_detector'));
SELECT pg_temp.act('a7', 'eq_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8e100000-0000-0000-0000-000000000001', NULL,
      '8e300000-0000-0000-0000-000000000002')$q$,
      (SELECT id FROM equipment_stock WHERE kind = 'gas_detector' ORDER BY id LIMIT 1),
      (SELECT updated_at FROM equipment_stock WHERE kind = 'gas_detector' ORDER BY id LIMIT 1)));
SELECT pg_temp.ck('EQ-12 a detector replacing one on Unit 1 inherits that Unit and is resolved',
  (SELECT res FROM outcome WHERE k = 'a7') = 'OK'
  AND (SELECT count(*) FROM gas_detectors WHERE station_id = '8e100000-0000-0000-0000-000000000001' AND archived_at IS NULL
        AND unit_id = '8e200000-0000-0000-0000-000000000001' AND mapping_status = 'resolved' AND model = 'XNX') = 1);
SELECT pg_temp.act('a8', 'eq_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8e100000-0000-0000-0000-000000000001')$q$,
      (SELECT id FROM equipment_stock WHERE serial_number = 'TEQ-H-NEW'), (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEQ-H-NEW')));
SELECT pg_temp.ck('EQ-13 an issued item cannot be issued again',
  (SELECT res FROM outcome WHERE k = 'a8') = 'PT409');

-- ------------------------------------------------------------------ Log -> store -> 3rd party -> certified
SELECT pg_temp.act('a9', 'eq_admin', format($q$SELECT cng_equipment_log_receive(ARRAY[%L]::uuid[])$q$,
      (SELECT id FROM equipment_field_log WHERE installed_hose_id = '8e300000-0000-0000-0000-000000000001')));
SELECT pg_temp.ck('EQ-14 receiving the old hose puts it in the store as under calibration, with its history',
  (SELECT res FROM outcome WHERE k = 'a9') = 'OK'
  AND (SELECT count(*) FROM v_equipment_stock WHERE kind = 'hose' AND serial_number = 'TEQ-H-OLD' AND availability_status = 'available_in_store_uc') = 1
  AND (SELECT status = 'returned' FROM v_equipment_field_log WHERE installed_hose_id = '8e300000-0000-0000-0000-000000000001'));
SELECT pg_temp.act('a10', 'eq_admin', format($q$SELECT cng_equipment_calibration_send(ARRAY[%L]::uuid[])$q$,
      (SELECT id FROM equipment_stock WHERE serial_number = 'TEQ-H-OLD')));
SELECT pg_temp.ck('EQ-15a sent to the 3rd party: no longer in the store view',
  (SELECT res FROM outcome WHERE k = 'a10') = 'OK'
  AND NOT EXISTS (SELECT 1 FROM v_equipment_stock WHERE serial_number = 'TEQ-H-OLD')
  AND (SELECT status = 'sent' FROM v_equipment_calibration WHERE serial_number = 'TEQ-H-OLD'));
SELECT pg_temp.act('a11', 'eq_admin', format($q$SELECT cng_equipment_calibration_returned(ARRAY[%L]::uuid[])$q$,
      (SELECT id FROM equipment_calibration_jobs WHERE kind = 'hose')));
SELECT pg_temp.act('a12', 'eq_admin', format($q$SELECT cng_equipment_calibration_certify(ARRAY[%L]::uuid[], '2026-09-30', 'C-9', NULL)$q$,
      (SELECT id FROM equipment_calibration_jobs WHERE kind = 'hose')));
SELECT pg_temp.ck('EQ-15 returned, then certified: back in the store as calibrated with the certificate date',
  (SELECT res FROM outcome WHERE k = 'a11') = 'OK'
  AND (SELECT res FROM outcome WHERE k = 'a12') = 'OK'
  AND (SELECT availability_status = 'available_calibrated' AND last_date = '2026-09-30' AND next_date IS NULL
         FROM equipment_stock WHERE serial_number = 'TEQ-H-OLD')
  AND EXISTS (SELECT 1 FROM v_equipment_stock WHERE serial_number = 'TEQ-H-OLD' AND availability_status = 'available_calibrated'));
SELECT pg_temp.act('a13', 'eq_admin', $q$SELECT cng_equipment_calibration_certify(ARRAY[gen_random_uuid()], current_date + 30)$q$);
SELECT pg_temp.ck('EQ-16 a certificate dated in the future is refused',
  (SELECT res FROM outcome WHERE k = 'a13') = '22023');
SELECT pg_temp.ck('EQ-17 the history follows the item from station to store and through certification',
  (SELECT count(*) FROM cng_equipment_history('hose', (SELECT id FROM equipment_stock WHERE serial_number = 'TEQ-H-OLD'))) >= 4);
SELECT pg_temp.ck('EQ-18 every step is audited with the server-derived admin as actor',
  (SELECT count(DISTINCT actor_label) FROM audit_logs WHERE actor_id = '8e000000-0000-0000-0000-00000000000a'
      AND actor_label IN ('equipment_stock_add','equipment_issue','equipment_log_receive','equipment_calibration')) = 4);
SELECT pg_temp.act('a14', 'eq_viewer', $q$SELECT 1 FROM v_equipment_stock LIMIT 1$q$);
-- Raises if the East issue or Log entry is visible to a West-only viewer.
SELECT pg_temp.act('a15', 'eq_viewer', $q$DO $d$ BEGIN
  IF (SELECT count(*) FROM v_equipment_emergency) + (SELECT count(*) FROM v_equipment_field_log)
     + (SELECT count(*) FROM equipment_issues) > 0 THEN RAISE EXCEPTION 'visible outside its Region'; END IF; END $d$$q$);
SELECT pg_temp.ck('EQ-19 a viewer of another Region sees the store but not this Region''s issues or Log',
  (SELECT res FROM outcome WHERE k = 'a14') = 'OK' AND (SELECT res FROM outcome WHERE k = 'a15') = 'OK'
  AND (SELECT count(*) FROM equipment_issues) > 0);
ROLLBACK;
