-- unit_srv_batch.sql — regression suite for 20261005100000_add_unit_srvs_batch.sql (owner request 2026-10-05):
-- several relief valves added to a Unit at once, all or nothing.
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
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE || ' ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('9e000000-0000-0000-0000-00000000000a', 'ub_admin', 'admin', true, 'TESTDATA UB Admin'),
  ('9e000000-0000-0000-0000-00000000000b', 'ub_viewer', 'viewer', true, 'TESTDATA UB Viewer');
INSERT INTO stations (id, region_id, station_name) VALUES
  ('9e100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TUB SHATA');
INSERT INTO units (id, station_id, region_id, unit_name) VALUES
  ('9e200000-0000-0000-0000-000000000001', '9e100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TUB SHATA 1');
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, source_raw) VALUES
  ('9e400000-0000-0000-0000-000000000001', 'available_calibrated', 'TUB-STORE', '{}');

INSERT INTO r VALUES ('ok', pg_temp.try_as('ub_admin', $q$SELECT cng_admin_add_unit_srvs('9e200000-0000-0000-0000-000000000001',
  '{"manufacturer": "Mercer", "pressure_min": 5500, "pressure_max": 5500, "pressure_unit": "PSI", "part_number": "PN-X", "last_date": "2026-01-10"}'::jsonb,
  ARRAY['TUB-1', ' TUB-2 ', '', 'TUB-3'])$q$));
SELECT pg_temp.ck('UB-1 one valve per serial (blanks ignored, trimmed), each with the shared fields, on the Unit, next calibration a year on',
  (SELECT v FROM r WHERE k = 'ok') = 'OK'
  AND (SELECT count(*) = 3 AND bool_and(unit_id = '9e200000-0000-0000-0000-000000000001' AND manufacturer = 'Mercer'
          AND pressure_min = 5500 AND pressure_unit = 'PSI' AND part_number = 'PN-X' AND next_calibration_date = '2027-01-10'
          AND mapping_status = 'needs_equipment_mapping')
       FROM installed_relief_valves WHERE serial_number IN ('TUB-1', 'TUB-2', 'TUB-3') AND archived_at IS NULL));
SELECT pg_temp.ck('UB-2 every valve has its own audit row with the admin as actor',
  (SELECT count(*) = 3 FROM audit_logs a JOIN installed_relief_valves v ON v.id = a.entity_id
    WHERE v.serial_number IN ('TUB-1', 'TUB-2', 'TUB-3') AND a.actor_label = 'admin_add_unit_asset'
      AND a.actor_id = '9e000000-0000-0000-0000-00000000000a'));

INSERT INTO r VALUES ('known', pg_temp.try_as('ub_admin', $q$SELECT cng_admin_add_unit_srvs('9e200000-0000-0000-0000-000000000001',
  '{}'::jsonb, ARRAY['TUB-NEW', 'TUB-STORE', 'TUB-1'])$q$));
SELECT pg_temp.ck('UB-3 a serial already in the system refuses the whole batch, naming where each is, and adds nothing',
  (SELECT v FROM r WHERE k = 'known') LIKE '23505 already recorded: %TUB-STORE — in the warehouse (CALIBRATED)%'
  AND (SELECT v FROM r WHERE k = 'known') LIKE '%TUB-1 — installed at %'
  AND NOT EXISTS (SELECT 1 FROM installed_relief_valves WHERE serial_number = 'TUB-NEW'));

INSERT INTO r VALUES ('twice', pg_temp.try_as('ub_admin', $q$SELECT cng_admin_add_unit_srvs('9e200000-0000-0000-0000-000000000001',
  '{}'::jsonb, ARRAY['TUB-A', 'tub-a ', 'TUB-B'])$q$));
INSERT INTO r VALUES ('none', pg_temp.try_as('ub_admin', $q$SELECT cng_admin_add_unit_srvs('9e200000-0000-0000-0000-000000000001',
  '{}'::jsonb, ARRAY[' ', ''])$q$));
SELECT pg_temp.ck('UB-4 a serial typed twice (any case/spaces) or no serial at all is refused, adding nothing',
  (SELECT v FROM r WHERE k = 'twice') = '23505 the same serial is typed more than once: tub-a'
  AND (SELECT v FROM r WHERE k = 'none') LIKE '22023 type at least one serial%'
  AND NOT EXISTS (SELECT 1 FROM installed_relief_valves WHERE serial_number IN ('TUB-A', 'TUB-B')));

INSERT INTO r VALUES ('viewer', pg_temp.try_as('ub_viewer', $q$SELECT cng_admin_add_unit_srvs('9e200000-0000-0000-0000-000000000001',
  '{}'::jsonb, ARRAY['TUB-V'])$q$));
SELECT pg_temp.ck('UB-5 a non-admin is refused; the function is definer with a pinned search_path, callable by authenticated, not anon',
  (SELECT v FROM r WHERE k = 'viewer') LIKE '42501%'
  AND NOT EXISTS (SELECT 1 FROM installed_relief_valves WHERE serial_number = 'TUB-V')
  AND (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc WHERE proname = 'cng_admin_add_unit_srvs')
  AND has_function_privilege('authenticated', 'cng_admin_add_unit_srvs(uuid, jsonb, text[])', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_admin_add_unit_srvs(uuid, jsonb, text[])', 'EXECUTE'));

ROLLBACK;
