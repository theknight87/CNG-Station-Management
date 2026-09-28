-- admin_create.sql — regression suite for 20260928180000_admin_create_station_and_srv.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.try_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('7e000000-0000-0000-0000-00000000000a','ac_admin','admin',true,'TESTDATA AC Admin'),
  ('7e000000-0000-0000-0000-00000000000c','ac_eng','engineer',true,'TESTDATA AC Engineer');
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;
CREATE TEMP TABLE east AS SELECT id FROM regions WHERE name = 'East';
GRANT SELECT ON east TO authenticated;

INSERT INTO r VALUES ('eng', pg_temp.try_as('ac_eng', $q$SELECT cng_admin_create_station((SELECT id FROM east), 'TAC NEW')$q$));
INSERT INTO r VALUES ('eng_srv', pg_temp.try_as('ac_eng', $q$SELECT cng_admin_add_warehouse_srvs('{"availability":"available_new","serials":["X1"]}')$q$));
SELECT pg_temp.ck('AC-1 a non-admin can create neither a Station nor a valve',
  (SELECT v FROM r WHERE k='eng') = '42501' AND (SELECT v FROM r WHERE k='eng_srv') = '42501');

INSERT INTO r VALUES ('st', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_create_station((SELECT id FROM east), ' TAC NEW ', 'open', 'n',
  '[{"unit_name":"TAC NEW 1","job_number":"J-1","dispensers":2},{"unit_name":"TAC NEW 2"}]')$q$));
SELECT pg_temp.ck('AC-2 an admin creates a Station in the Region with its Units, normalized, audited',
  (SELECT v FROM r WHERE k='st') = 'OK'
  AND EXISTS (SELECT 1 FROM stations s JOIN east e ON e.id = s.region_id WHERE s.station_name = 'TAC NEW' AND s.bay_status = 'open'
              AND s.normalized_name = cng_normalize_name('TAC NEW'))
  AND (SELECT count(*) = 2 FROM units u JOIN stations s ON s.id = u.station_id WHERE s.station_name = 'TAC NEW')
  AND EXISTS (SELECT 1 FROM units WHERE unit_name = 'TAC NEW 1' AND job_number = 'J-1' AND dispenser_count_reported = 2 AND hose_count_reported IS NULL)
  AND EXISTS (SELECT 1 FROM audit_logs WHERE actor_id = '7e000000-0000-0000-0000-00000000000a' AND entity_table = 'stations' AND action = 'record_created'));

INSERT INTO r VALUES ('dup', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_create_station((SELECT id FROM east), 'tac  new')$q$));
INSERT INTO r VALUES ('dupu', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_create_station((SELECT id FROM east), 'TAC OTHER', NULL, NULL, '[{"unit_name":"A"},{"unit_name":"a"}]')$q$));
INSERT INTO r VALUES ('noname', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_create_station((SELECT id FROM east), '  ')$q$));
SELECT pg_temp.ck('AC-3 same name in the Region, duplicate Unit names and a blank name are refused; nothing half-created',
  (SELECT v FROM r WHERE k='dup') = '23505' AND (SELECT v FROM r WHERE k='dupu') = '23505' AND (SELECT v FROM r WHERE k='noname') = '22023'
  AND NOT EXISTS (SELECT 1 FROM stations WHERE station_name = 'TAC OTHER'));

INSERT INTO r VALUES ('w', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_add_warehouse_srvs('{"availability":"available_calibrated","serials":["TAC-S1"," TAC-S2 ",""],
  "manufacturer":"COI","size_type":"Male","inlet_size":"1/2\"","outlet_size":"3/4\"","pressure_min":275,"pressure_unit":"BAR",
  "warehouse_code":"mb 9","last_calibration_date":"2026-09-01"}')$q$));
SELECT pg_temp.ck('AC-4 valves added one per serial; code follows the condition; next calibration one year on',
  (SELECT v FROM r WHERE k='w') = 'OK'
  AND (SELECT count(*) = 2 FROM warehouse_relief_valves WHERE serial_number IN ('TAC-S1','TAC-S2') AND availability_status = 'available_calibrated'
       AND warehouse_code = 'mbc 9' AND set_pressure_raw = '275' AND pressure_max = 275 AND serial_status = 'assigned'
       AND next_calibration_date = '2027-09-01' AND next_calibration_precision = 'exact_date')
  AND EXISTS (SELECT 1 FROM v_srv_warehouse_stock WHERE serial_number = 'TAC-S1'));

INSERT INTO r VALUES ('q', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_add_warehouse_srvs('{"availability":"available_new","quantity":3,"manufacturer":"TACQ"}')$q$));
SELECT pg_temp.ck('AC-5 a quantity without serials adds that many valves, serial left empty, dates unknown',
  (SELECT v FROM r WHERE k='q') = 'OK'
  AND (SELECT count(*) = 3 FROM warehouse_relief_valves WHERE manufacturer = 'TACQ' AND serial_number IS NULL AND serial_status = 'unknown'
       AND last_calibration_precision = 'unknown' AND next_calibration_date IS NULL));

INSERT INTO r VALUES ('again', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_add_warehouse_srvs('{"availability":"available_new","serials":["TAC-S1"]}')$q$));
INSERT INTO r VALUES ('bad', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_add_warehouse_srvs('{"availability":"sent_to_station_received","serials":["TAC-Z"]}')$q$));
INSERT INTO r VALUES ('none', pg_temp.try_as('ac_admin', $q$SELECT cng_admin_add_warehouse_srvs('{"availability":"available_new"}')$q$));
SELECT pg_temp.ck('AC-6 a serial already in stock, a non-stock condition and an empty request are refused',
  (SELECT v FROM r WHERE k='again') = '23505' AND (SELECT v FROM r WHERE k='bad') = '22023' AND (SELECT v FROM r WHERE k='none') = '22023'
  AND NOT EXISTS (SELECT 1 FROM warehouse_relief_valves WHERE serial_number = 'TAC-Z'));

SELECT pg_temp.ck('AC-7 both functions are definer, search_path pinned, no anon execute',
  (SELECT bool_and(prosecdef AND proconfig IS NOT NULL AND NOT has_function_privilege('anon', oid, 'EXECUTE'))
     FROM pg_proc WHERE proname IN ('cng_admin_create_station', 'cng_admin_add_warehouse_srvs')));

ROLLBACK;
