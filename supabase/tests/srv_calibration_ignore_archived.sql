-- srv_calibration_ignore_archived.sql — regression suite for 20260929090000_srv_calibration_ignore_archived.sql
-- Owner report 2026-09-29: a valve sent to 3rd party calibration and then removed from that list could never be
-- sent again, because the send check still counted the removed (archived) entry as open.
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
  ('7e000000-0000-0000-0000-00000000000a','ca_admin','admin',true,'TESTDATA CA Admin');
INSERT INTO stations (id, region_id, station_name) SELECT '7e100000-0000-0000-0000-000000000001', r.id, 'TCA ALPHA' FROM regions r WHERE r.name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT '7e200000-0000-0000-0000-000000000001', '7e100000-0000-0000-0000-000000000001', r.id, 'TCA ALPHA' FROM regions r WHERE r.name = 'East';
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, pressure_min, pressure_max, pressure_unit, source_raw) VALUES
  ('7e400000-0000-0000-0000-000000000001','available_in_store_uc','TCA-W1',90,90,'BAR','{}'),
  ('7e400000-0000-0000-0000-000000000002','available_calibrated','TCA-W2',90,90,'BAR','{}'),
  ('7e400000-0000-0000-0000-000000000003','available_in_store_uc','TCA-W3',90,90,'BAR','{}');
-- W2: a calibration entry that was sent and then removed (the production shape); W3: one still genuinely open.
INSERT INTO srv_calibration_jobs (id, warehouse_valve_id, sent_by, archived_at, archived_by) VALUES
  ('7e700000-0000-0000-0000-000000000002','7e400000-0000-0000-0000-000000000002','7e000000-0000-0000-0000-00000000000a', now(), '7e000000-0000-0000-0000-00000000000a'),
  ('7e700000-0000-0000-0000-000000000003','7e400000-0000-0000-0000-000000000003','7e000000-0000-0000-0000-00000000000a', NULL, NULL);

CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;

-- The owner's sequence: send, remove the entry, send again.
INSERT INTO r VALUES ('send1', pg_temp.try_as('ca_admin', $q$SELECT cng_srv_calibration_send(ARRAY['7e400000-0000-0000-0000-000000000001']::uuid[])$q$));
UPDATE r SET v = v || ':' || pg_temp.try_as('ca_admin', format('SELECT cng_srv_calibration_archive(%L)',
  (SELECT id FROM srv_calibration_jobs WHERE warehouse_valve_id = '7e400000-0000-0000-0000-000000000001' AND archived_at IS NULL))) WHERE k = 'send1';
INSERT INTO r VALUES ('send2', pg_temp.try_as('ca_admin', $q$SELECT cng_srv_calibration_send(ARRAY['7e400000-0000-0000-0000-000000000001']::uuid[])$q$));
SELECT pg_temp.ck('CIA-1 send, remove the entry, send again: the second send succeeds (the removed entry no longer blocks)',
  (SELECT v FROM r WHERE k='send1') = 'OK:OK' AND (SELECT v FROM r WHERE k='send2') = 'OK'
  AND (SELECT count(*) = 1 FROM srv_calibration_jobs WHERE warehouse_valve_id = '7e400000-0000-0000-0000-000000000001' AND archived_at IS NULL AND status = 'sent')
  AND (SELECT count(*) = 1 FROM srv_calibration_jobs WHERE warehouse_valve_id = '7e400000-0000-0000-0000-000000000001' AND archived_at IS NOT NULL));

INSERT INTO r VALUES ('send_open', pg_temp.try_as('ca_admin', $q$SELECT cng_srv_calibration_send(ARRAY['7e400000-0000-0000-0000-000000000003']::uuid[])$q$));
SELECT pg_temp.ck('CIA-2 a valve with a LIVE open entry is still refused (nothing is sent twice)',
  (SELECT v FROM r WHERE k='send_open') = 'PT409'
  AND (SELECT count(*) = 1 FROM srv_calibration_jobs WHERE warehouse_valve_id = '7e400000-0000-0000-0000-000000000003'));

INSERT INTO r VALUES ('issue', pg_temp.try_as('ca_admin', format(
  'SELECT cng_srv_issue(%L, %L, %L)', '7e400000-0000-0000-0000-000000000002',
  (SELECT updated_at FROM warehouse_relief_valves WHERE id = '7e400000-0000-0000-0000-000000000002'), '7e200000-0000-0000-0000-000000000001')));
SELECT pg_temp.ck('CIA-3 a calibrated valve whose old entry was removed can be issued',
  (SELECT v FROM r WHERE k='issue') = 'OK');

INSERT INTO r VALUES ('ret', pg_temp.try_as('ca_admin', $q$SELECT cng_srv_calibration_returned(ARRAY['7e700000-0000-0000-0000-000000000002']::uuid[])$q$));
INSERT INTO r VALUES ('cert', pg_temp.try_as('ca_admin', format('SELECT cng_srv_calibration_certify(ARRAY[%L]::uuid[], %L::date)',
  '7e700000-0000-0000-0000-000000000002', cng_business_date())));
SELECT pg_temp.ck('CIA-4 a removed entry can be neither marked returned nor certified (a stale screen changes nothing)',
  (SELECT v FROM r WHERE k='ret') = 'PT409' AND (SELECT v FROM r WHERE k='cert') = 'PT409'
  AND (SELECT status = 'sent' AND archived_at IS NOT NULL FROM srv_calibration_jobs WHERE id = '7e700000-0000-0000-0000-000000000002'));

SELECT pg_temp.ck('CIA-5 only the check changed: all four functions are still SECURITY DEFINER with a pinned search_path',
  (SELECT count(*) = 4 FROM pg_proc WHERE proname IN ('cng_srv_calibration_send','cng_srv_issue','cng_srv_calibration_returned','cng_srv_calibration_certify')
     AND prosecdef AND proconfig::text LIKE '%search_path%'));
SELECT pg_temp.ck('CIA-6 grants unchanged: authenticated may execute, anon may not',
  (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
     FROM pg_proc p WHERE proname IN ('cng_srv_calibration_send','cng_srv_issue','cng_srv_calibration_returned','cng_srv_calibration_certify')));

ROLLBACK;
