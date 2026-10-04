-- srv_serial_whereabouts.sql — regression suite for 20261004120000_srv_serial_whereabouts.sql (owner request 2026-10-04):
-- a serial already somewhere in the system is refused when adding a relief valve, saying where it is; a store-sheet row
-- that only says the valve was sent to a station (with no live installed valve) does not block and is closed on add.
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
  ('9d000000-0000-0000-0000-00000000000a', 'sw_admin', 'admin', true, 'TESTDATA SW Admin');
INSERT INTO stations (id, region_id, station_name) VALUES
  ('9d100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TSW NASR');
INSERT INTO units (id, station_id, region_id, unit_name) VALUES
  ('9d200000-0000-0000-0000-000000000001', '9d100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TSW NASR 1');

-- Installed at a Station; in the store; at calibration; a sheet row "AT STATION" whose valve was removed (stale);
-- and a sheet row "AT STATION" whose valve is still installed (the same valve twice).
INSERT INTO installed_relief_valves (id, region_id, station_id, mapping_status, serial_number, serial_number_raw, serial_status) VALUES
  ('9d300000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), '9d100000-0000-0000-0000-000000000001',
   'needs_unit_mapping', 'TSW-INST', 'TSW-INST', 'assigned'),
  ('9d300000-0000-0000-0000-000000000002', (SELECT id FROM regions WHERE name = 'East'), '9d100000-0000-0000-0000-000000000001',
   'needs_unit_mapping', 'TSW-BOTH', 'TSW-BOTH', 'assigned');
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, target_station_id, target_region_id, source_raw) VALUES
  ('9d400000-0000-0000-0000-000000000001', 'available_calibrated', 'TSW-STORE', NULL, NULL, '{}'),
  ('9d400000-0000-0000-0000-000000000002', 'available_in_store_uc', 'TSW-CAL', NULL, NULL, '{}'),
  ('9d400000-0000-0000-0000-000000000003', 'sent_to_station_received', 'TSW-STALE', '9d100000-0000-0000-0000-000000000001',
   (SELECT id FROM regions WHERE name = 'East'), '{}'),
  ('9d400000-0000-0000-0000-000000000004', 'sent_to_station_received', 'TSW-BOTH', '9d100000-0000-0000-0000-000000000001',
   (SELECT id FROM regions WHERE name = 'East'), '{}');
INSERT INTO srv_calibration_jobs (warehouse_valve_id, status, sent_by)
VALUES ('9d400000-0000-0000-0000-000000000002', 'sent', '9d000000-0000-0000-0000-00000000000a');

CREATE TEMP TABLE w AS SELECT * FROM cng_srv_serial_whereabouts(ARRAY['TSW-INST', ' tsw-store ', 'TSW-CAL', 'TSW-STALE', 'TSW-BOTH', 'TSW-NONE']);
SELECT pg_temp.ck('SW-1 an installed serial is found, blocks, and says where (Station · Region)',
  (SELECT blocking AND kind = 'installed' AND place = 'installed at TSW NASR · East' FROM w WHERE serial = 'TSW-INST'));
SELECT pg_temp.ck('SW-2 a store valve (trimmed, any case) and one at the calibration company block, each with its place',
  (SELECT blocking AND place = 'in the warehouse (CALIBRATED)' FROM w WHERE serial = 'tsw-store')
  AND (SELECT blocking AND kind = 'calibration' AND place = 'at the calibration company' FROM w WHERE serial = 'TSW-CAL'));
SELECT pg_temp.ck('SW-3 a sheet row AT STATION with no live installed valve does not block; one whose valve is installed is reported once, as installed',
  (SELECT NOT blocking AND kind = 'sheet_sent' AND place = 'store sheet: AT STATION — TSW NASR' FROM w WHERE serial = 'TSW-STALE')
  AND (SELECT count(*) = 1 AND bool_and(kind = 'installed') FROM w WHERE serial = 'TSW-BOTH')
  AND NOT EXISTS (SELECT 1 FROM w WHERE serial = 'TSW-NONE'));

INSERT INTO r VALUES ('wh_blocked', pg_temp.try_as('sw_admin', $q$SELECT cng_admin_add_warehouse_srvs('{
  "availability": "available_new", "serials": ["TSW-INST", "TSW-STORE", "TSW-NEW"]}'::jsonb)$q$));
SELECT pg_temp.ck('SW-4 adding to the warehouse refuses known serials with where they are, and adds nothing',
  (SELECT v FROM r WHERE k = 'wh_blocked') LIKE '23505 already recorded: TSW-INST — installed at TSW NASR · East; TSW-STORE — in the warehouse (CALIBRATED)'
  AND NOT EXISTS (SELECT 1 FROM warehouse_relief_valves WHERE serial_number = 'TSW-NEW'));

INSERT INTO r VALUES ('wh_stale', pg_temp.try_as('sw_admin', $q$SELECT cng_admin_add_warehouse_srvs('{
  "availability": "available_calibrated", "serials": ["TSW-STALE"]}'::jsonb)$q$));
SELECT pg_temp.ck('SW-5 a serial only on a stale AT STATION sheet row is added; the old row is archived (kept) and recorded in the audit',
  (SELECT v FROM r WHERE k = 'wh_stale') = 'OK'
  AND (SELECT archived_at IS NOT NULL FROM warehouse_relief_valves WHERE id = '9d400000-0000-0000-0000-000000000003')
  AND (SELECT count(*) = 1 FROM warehouse_relief_valves WHERE serial_number = 'TSW-STALE' AND archived_at IS NULL
         AND availability_status = 'available_calibrated')
  AND EXISTS (SELECT 1 FROM audit_logs WHERE actor_label = 'admin_add_warehouse_srvs'
                AND after_data->'closed_sheet_rows'->0->>'id' = '9d400000-0000-0000-0000-000000000003'));

INSERT INTO r VALUES ('unit_blocked', pg_temp.try_as('sw_admin', $q$SELECT cng_admin_add_unit_asset('srv',
  '9d200000-0000-0000-0000-000000000001', '{"serial_number": "TSW-STALE"}'::jsonb)$q$));
INSERT INTO r VALUES ('unit_ok', pg_temp.try_as('sw_admin', $q$SELECT cng_admin_add_unit_asset('srv',
  '9d200000-0000-0000-0000-000000000001', '{"serial_number": "TSW-FRESH"}'::jsonb)$q$));
SELECT pg_temp.ck('SW-6 the Unit window''s add refuses a serial now in the warehouse, and still adds a new one',
  (SELECT v FROM r WHERE k = 'unit_blocked') LIKE '23505 already recorded: TSW-STALE — in the warehouse (CALIBRATED)'
  AND (SELECT v FROM r WHERE k = 'unit_ok') = 'OK'
  AND EXISTS (SELECT 1 FROM installed_relief_valves WHERE serial_number = 'TSW-FRESH' AND archived_at IS NULL));

SELECT pg_temp.ck('SW-7 the lookup runs with the caller''s rights and is callable by the browser; the refusing helper is not',
  NOT (SELECT prosecdef FROM pg_proc WHERE proname = 'cng_srv_serial_whereabouts')
  AND has_function_privilege('authenticated', 'cng_srv_serial_whereabouts(text[])', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_srv_serial_whereabouts(text[])', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'cng_srv_serials_refuse_known(text[])', 'EXECUTE'));

ROLLBACK;
