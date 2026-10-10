-- equipment_serial_whereabouts.sql — regression suite for 20261010110000_equipment_serial_whereabouts.sql (owner request
-- 2026-10-10): where is this hose / gas detector serial, and adding several serials at once refuses a known one.
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
CREATE TEMP TABLE outcome (k text PRIMARY KEY, res text);
CREATE FUNCTION pg_temp.act(p_k text, p_sub text, p_sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO outcome VALUES (p_k, pg_temp.try_as(p_sub, p_sql)); END $$;
CREATE FUNCTION pg_temp.res(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT res FROM outcome WHERE k = p_k $$;
CREATE FUNCTION pg_temp.add(p_kind text, p_serials text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.try_as('eqw_admin', format($q$SELECT cng_equipment_stock_add(%L,'available_new',%L::text[],NULL,NULL,NULL,NULL,
    NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)$q$, p_kind, p_serials)) $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('8f000000-0000-0000-0000-00000000000a','eqw_admin','admin',true,'TESTDATA EQW Admin');
INSERT INTO stations (id, region_id, station_name) SELECT '8f100000-0000-0000-0000-000000000001', id, 'TEQW AAA' FROM regions WHERE name = 'West';
INSERT INTO hoses (id, region_id, station_id, mapping_status, serial_number, serial_status) SELECT v.id::uuid, r.id, '8f100000-0000-0000-0000-000000000001', 'needs_unit_mapping', v.sn, 'assigned'
  FROM regions r, (VALUES ('8f300000-0000-0000-0000-000000000001','TEQW-INST'), ('8f300000-0000-0000-0000-000000000002','TEQW-OLD')) v(id, sn) WHERE r.name = 'West';
INSERT INTO outcome VALUES ('s1', pg_temp.add('hose', ARRAY['TEQW-S1', 'TEQW-S3']));
SELECT pg_temp.act('s2', 'eqw_admin', $q$SELECT cng_equipment_stock_add('hose','available_in_store_uc',ARRAY['TEQW-S2'],NULL,NULL,NULL,NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)$q$);
SELECT pg_temp.act('cal', 'eqw_admin', format('SELECT cng_equipment_calibration_send(ARRAY[%L]::uuid[])',
  (SELECT id FROM equipment_stock WHERE serial_number = 'TEQW-S2')));
-- S3 is issued in place of OLD: S3 is now installed, OLD is in the Log awaiting return.
SELECT pg_temp.act('iss', 'eqw_admin', format('SELECT cng_equipment_issue(%L, %L, %L, NULL, %L)',
  (SELECT id FROM equipment_stock WHERE serial_number = 'TEQW-S3'), (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEQW-S3'),
  '8f100000-0000-0000-0000-000000000001', '8f300000-0000-0000-0000-000000000002'));

CREATE TEMP TABLE w AS SELECT * FROM cng_equipment_serial_whereabouts('hose',
  ARRAY[' teqw-inst', 'TEQW-S1', 'TEQW-S2', 'TEQW-OLD', 'TEQW-S3', 'TEQW-NONE']);
SELECT pg_temp.ck('ESW-1 every live place is found (trimmed, case folded): installed, warehouse, 3rd party, Log; an unknown serial has none',
  pg_temp.res('s1') = 'OK' AND pg_temp.res('s2') = 'OK' AND pg_temp.res('cal') = 'OK' AND pg_temp.res('iss') = 'OK'
  AND (SELECT kind = 'installed' AND place LIKE 'installed at TEQW AAA%' FROM w WHERE serial = 'teqw-inst')
  AND (SELECT kind = 'warehouse' AND place = 'in the warehouse (NEW)' FROM w WHERE serial = 'TEQW-S1')
  AND (SELECT kind = 'calibration' FROM w WHERE serial = 'TEQW-S2')
  AND (SELECT kind = 'log' AND place LIKE 'awaiting return from TEQW AAA%' FROM w WHERE serial = 'TEQW-OLD')
  AND (SELECT count(*) = 1 AND bool_and(kind = 'installed') FROM w WHERE serial = 'TEQW-S3')
  AND NOT EXISTS (SELECT 1 FROM w WHERE serial = 'TEQW-NONE')
  AND (SELECT bool_and(blocking) FROM w));
-- Each add is its own statement, so the checks after it read what it wrote.
INSERT INTO outcome VALUES ('det', pg_temp.add('gas_detector', ARRAY['TEQW-INST']));
SELECT pg_temp.ck('ESW-2 kinds are apart: a hose serial is not a gas detector''s, and a detector may carry it',
  NOT EXISTS (SELECT 1 FROM cng_equipment_serial_whereabouts('gas_detector', ARRAY['TEQW-S1']))
  AND pg_temp.res('det') = 'OK'
  AND EXISTS (SELECT 1 FROM equipment_stock WHERE kind = 'gas_detector' AND serial_number = 'TEQW-INST'));

INSERT INTO outcome VALUES ('known', pg_temp.add('hose', ARRAY['TEQW-NEW', 'TEQW-OLD']));
SELECT pg_temp.ck('ESW-3 one serial already recorded refuses the whole batch (23505); nothing is added',
  pg_temp.res('known') = '23505'
  AND NOT EXISTS (SELECT 1 FROM equipment_stock WHERE serial_number = 'TEQW-NEW'));
INSERT INTO outcome VALUES ('twice', pg_temp.add('hose', ARRAY['TEQW-A', ' teqw-a ', 'TEQW-B']));
SELECT pg_temp.ck('ESW-4 a serial typed twice (case and spaces folded) refuses the whole batch (22023); nothing is added',
  pg_temp.res('twice') = '22023'
  AND NOT EXISTS (SELECT 1 FROM equipment_stock WHERE serial_number IN ('TEQW-A', 'TEQW-B')));
INSERT INTO outcome VALUES ('many', pg_temp.add('hose', ARRAY['TEQW-A', 'TEQW-B', 'TEQW-C']));
SELECT pg_temp.ck('ESW-5 several new serials at once: one store record each',
  pg_temp.res('many') = 'OK'
  AND (SELECT count(*) = 3 FROM equipment_stock WHERE kind = 'hose' AND serial_number IN ('TEQW-A', 'TEQW-B', 'TEQW-C')));

SELECT pg_temp.ck('ESW-6 security: whereabouts runs as the caller (not definer), authenticated only; the refusal helper is not callable from the browser',
  (SELECT NOT prosecdef FROM pg_proc WHERE proname = 'cng_equipment_serial_whereabouts')
  AND has_function_privilege('authenticated', 'cng_equipment_serial_whereabouts(text, text[])', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_equipment_serial_whereabouts(text, text[])', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'cng_equipment_serials_refuse_known(text, text[])', 'EXECUTE')
  AND (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc WHERE proname = 'cng_equipment_stock_add'));

ROLLBACK;
