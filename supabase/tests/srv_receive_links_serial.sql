-- srv_receive_links_serial.sql — regression suite for 20260929110000_srv_receive_links_serial.sql
-- Owner report 2026-09-29: valves received back from ابو المطامير had no P/N and no warehouse code, because a NEW
-- warehouse record was built from the installed record while the same valve's warehouse record (same serial, with
-- P/N and code) stayed "sent to station". Owner ruling 6p: a valve is its serial.
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

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('7d000000-0000-0000-0000-00000000000a','rl_admin','admin',true,'TESTDATA RL Admin');
INSERT INTO stations (id, region_id, station_name) SELECT '7d100000-0000-0000-0000-000000000001', r.id, 'TRL ALPHA' FROM regions r WHERE r.name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT '7d200000-0000-0000-0000-000000000001', '7d100000-0000-0000-0000-000000000001', r.id, 'TRL ALPHA' FROM regions r WHERE r.name = 'East';

-- Warehouse records. W1: the valve sent to the station (P/N + code). W2a/W2b: two records share serial TRL-2 (ambiguous).
-- WX: the valve issued in each replacement (its own serial), needed only to make the issues well-formed.
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, part_number, warehouse_code, pressure_min, pressure_max, pressure_unit, source_raw) VALUES
  ('7d400000-0000-0000-0000-000000000001','sent_to_station_not_received','TRL-1','PN-1','sbc 87',18,18,'BAR','{}'),
  ('7d400000-0000-0000-0000-00000000002a','sent_to_station_received','TRL-2','PN-2A','acc 1',18,18,'BAR','{}'),
  ('7d400000-0000-0000-0000-00000000002b','sent_to_station_not_received','TRL-2','PN-2B','acc 2',18,18,'BAR','{}'),
  ('7d400000-0000-0000-0000-0000000000ff','sent_to_station_received','TRL-X','PN-X','acc 9',18,18,'BAR','{}');
-- Installed records at the station (from the installed workbook: no P/N, no code). I3 has no serial.
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, serial_number, pressure_min, pressure_max, pressure_unit, archived_at)
SELECT v.id::uuid, r.id, '7d100000-0000-0000-0000-000000000001', '7d200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', v.sn, 18, 18, 'BAR', now()
  FROM (VALUES ('7d300000-0000-0000-0000-000000000001','TRL-1'), ('7d300000-0000-0000-0000-000000000002','TRL-2'),
               ('7d300000-0000-0000-0000-000000000003',NULL)) v(id,sn), regions r WHERE r.name = 'East';
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, serial_number)
SELECT '7d300000-0000-0000-0000-0000000000ff', r.id, '7d100000-0000-0000-0000-000000000001', '7d200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', 'TRL-X'
  FROM regions r WHERE r.name = 'East';
INSERT INTO srv_issues (id, warehouse_valve_id, new_installed_valve_id, replaced_installed_valve_id, region_id, station_id, unit_id, is_emergency, issued_by)
SELECT v.iss::uuid, '7d400000-0000-0000-0000-0000000000ff', '7d300000-0000-0000-0000-0000000000ff', v.inst::uuid, s.region_id, s.id, '7d200000-0000-0000-0000-000000000001', false,
       '7d000000-0000-0000-0000-00000000000a'
  FROM (VALUES ('7d500000-0000-0000-0000-000000000001','7d300000-0000-0000-0000-000000000001'),
               ('7d500000-0000-0000-0000-000000000002','7d300000-0000-0000-0000-000000000002'),
               ('7d500000-0000-0000-0000-000000000003','7d300000-0000-0000-0000-000000000003')) v(iss,inst), stations s
 WHERE s.id = '7d100000-0000-0000-0000-000000000001';
-- The replaced valves in the SRV Log, and W1's own open "sent to this station" entry.
INSERT INTO srv_field_log (id, reason, issue_id, installed_valve_id, region_id, station_id, unit_id, is_emergency)
SELECT v.id::uuid, 'replaced_on_issue', v.iss::uuid, v.inst::uuid, s.region_id, s.id, '7d200000-0000-0000-0000-000000000001', false
  FROM (VALUES ('7d600000-0000-0000-0000-000000000001','7d500000-0000-0000-0000-000000000001','7d300000-0000-0000-0000-000000000001'),
               ('7d600000-0000-0000-0000-000000000002','7d500000-0000-0000-0000-000000000002','7d300000-0000-0000-0000-000000000002'),
               ('7d600000-0000-0000-0000-000000000003','7d500000-0000-0000-0000-000000000003','7d300000-0000-0000-0000-000000000003')) v(id,iss,inst), stations s
 WHERE s.id = '7d100000-0000-0000-0000-000000000001';
INSERT INTO srv_field_log (id, reason, warehouse_valve_id, region_id, station_id, is_emergency)
SELECT '7d600000-0000-0000-0000-0000000000a1', 'reconcile_station_not_found', '7d400000-0000-0000-0000-000000000001', s.region_id, s.id, false
  FROM stations s WHERE s.id = '7d100000-0000-0000-0000-000000000001';

CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;
INSERT INTO r VALUES ('recv', pg_temp.try_as('rl_admin', $q$SELECT cng_srv_log_receive(ARRAY['7d600000-0000-0000-0000-000000000001','7d600000-0000-0000-0000-000000000002','7d600000-0000-0000-0000-000000000003']::uuid[])$q$));

SELECT pg_temp.ck('RLS-1 the receive itself succeeds', (SELECT v FROM r WHERE k='recv') = 'OK');
SELECT pg_temp.ck('RLS-2 same serial, one record sent to the station: THAT record comes back (no second record), with its P/N; code turns under-calibration',
  (SELECT count(*) = 1 FROM warehouse_relief_valves WHERE serial_number = 'TRL-1' AND archived_at IS NULL)
  AND (SELECT availability_status = 'available_in_store_uc' AND part_number = 'PN-1' AND warehouse_code = 'sbu 87'
         FROM warehouse_relief_valves WHERE id = '7d400000-0000-0000-0000-000000000001')
  AND (SELECT returned_warehouse_valve_id = '7d400000-0000-0000-0000-000000000001' FROM srv_field_log WHERE id = '7d600000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('RLS-3 its own open "sent to this station" SRV Log entry is closed, returned to the same record, by the admin',
  (SELECT returned_at IS NOT NULL AND returned_by = '7d000000-0000-0000-0000-00000000000a' AND returned_warehouse_valve_id = '7d400000-0000-0000-0000-000000000001'
     FROM srv_field_log WHERE id = '7d600000-0000-0000-0000-0000000000a1'));
SELECT pg_temp.ck('RLS-4 ambiguous serial (two records) is never guessed: a new record, both old ones untouched',
  (SELECT count(*) = 3 FROM warehouse_relief_valves WHERE serial_number = 'TRL-2' AND archived_at IS NULL)
  AND (SELECT bool_and(availability_status::text LIKE 'sent_to_station%') FROM warehouse_relief_valves WHERE id IN ('7d400000-0000-0000-0000-00000000002a','7d400000-0000-0000-0000-00000000002b')));
SELECT pg_temp.ck('RLS-5 no serial: a new record as before',
  (SELECT returned_warehouse_valve_id NOT IN ('7d400000-0000-0000-0000-000000000001') AND returned_warehouse_valve_id IS NOT NULL
     FROM srv_field_log WHERE id = '7d600000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('RLS-6 history records the serial link',
  EXISTS (SELECT 1 FROM srv_history WHERE warehouse_valve_id = '7d400000-0000-0000-0000-000000000001' AND event = 'received' AND (details->>'linked_by_serial')::boolean));

-- The production shape the repair fixes: a returned record K4 built from the installed valve (no P/N, no code) while the
-- same valve's record S4 still says "sent to station" with an open SRV Log entry.
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, part_number, warehouse_code, pressure_min, pressure_max, pressure_unit, source_raw) VALUES
  ('7d400000-0000-0000-0000-000000000004','sent_to_station_received','TRL-4','PN-4','acc 196',18,18,'BAR','{"source_row":7}');
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, pressure_min, pressure_max, pressure_unit, notes) VALUES
  ('7d400000-0000-0000-0000-0000000000c4','available_in_store_uc','TRL-4',18,18,'BAR','Returned from the station (SRV Log)');
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, serial_number, archived_at)
SELECT '7d300000-0000-0000-0000-000000000004', r.id, '7d100000-0000-0000-0000-000000000001', '7d200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', 'TRL-4', now()
  FROM regions r WHERE r.name = 'East';
INSERT INTO srv_issues (id, warehouse_valve_id, new_installed_valve_id, replaced_installed_valve_id, region_id, station_id, unit_id, is_emergency, issued_by)
SELECT '7d500000-0000-0000-0000-000000000004', '7d400000-0000-0000-0000-0000000000ff', '7d300000-0000-0000-0000-0000000000ff', '7d300000-0000-0000-0000-000000000004',
       s.region_id, s.id, '7d200000-0000-0000-0000-000000000001', false, '7d000000-0000-0000-0000-00000000000a' FROM stations s WHERE s.id = '7d100000-0000-0000-0000-000000000001';
INSERT INTO srv_field_log (id, reason, issue_id, installed_valve_id, region_id, station_id, unit_id, is_emergency, returned_at, returned_by, returned_warehouse_valve_id)
SELECT '7d600000-0000-0000-0000-000000000004', 'replaced_on_issue', '7d500000-0000-0000-0000-000000000004', '7d300000-0000-0000-0000-000000000004', s.region_id, s.id,
       '7d200000-0000-0000-0000-000000000001', false, '2026-09-29 10:14:00+00', '7d000000-0000-0000-0000-00000000000a', '7d400000-0000-0000-0000-0000000000c4'
  FROM stations s WHERE s.id = '7d100000-0000-0000-0000-000000000001';
INSERT INTO srv_field_log (id, reason, warehouse_valve_id, region_id, station_id, is_emergency)
SELECT '7d600000-0000-0000-0000-0000000000a4', 'reconcile_other_serial', '7d400000-0000-0000-0000-000000000004', s.region_id, s.id, false
  FROM stations s WHERE s.id = '7d100000-0000-0000-0000-000000000001';

INSERT INTO r VALUES ('rep1', public.cng_srv_receive_serial_repair()::text);
INSERT INTO r VALUES ('rep2', public.cng_srv_receive_serial_repair()::text);
SELECT pg_temp.ck('RLS-7 repair: the returned record gets the P/N and code (under-calibration form); the old record is archived, never deleted',
  (SELECT v FROM r WHERE k='rep1') = '1'
  AND (SELECT part_number = 'PN-4' AND warehouse_code = 'acu 196' AND archived_at IS NULL FROM warehouse_relief_valves WHERE id = '7d400000-0000-0000-0000-0000000000c4')
  AND (SELECT archived_at IS NOT NULL AND source_raw->>'source_row' = '7' FROM warehouse_relief_valves WHERE id = '7d400000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('RLS-8 repair closes the old record''s open SRV Log entry with the real receiver and time, and is audited',
  (SELECT returned_by = '7d000000-0000-0000-0000-00000000000a' AND returned_at = '2026-09-29 10:14:00+00' AND returned_warehouse_valve_id = '7d400000-0000-0000-0000-0000000000c4'
     FROM srv_field_log WHERE id = '7d600000-0000-0000-0000-0000000000a4')
  AND EXISTS (SELECT 1 FROM audit_logs WHERE actor_label = 'migration:srv_receive_links_serial' AND entity_id = '7d400000-0000-0000-0000-0000000000c4'
                AND before_data->'archived'->>'warehouse_code' = 'acc 196'));
SELECT pg_temp.ck('RLS-9 repair is idempotent (a second run changes nothing) and leaves the ambiguous serial alone',
  (SELECT v FROM r WHERE k='rep2') = '0'
  AND (SELECT count(*) = 3 FROM warehouse_relief_valves WHERE serial_number = 'TRL-2' AND archived_at IS NULL));
SELECT pg_temp.ck('RLS-10 security: receive still admin-only SECURITY DEFINER for authenticated; the repair is service_role only',
  (SELECT prosecdef AND proconfig::text LIKE '%search_path%' AND has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE')
     FROM pg_proc WHERE proname = 'cng_srv_log_receive')
  AND (SELECT NOT has_function_privilege('authenticated', oid, 'EXECUTE') AND NOT has_function_privilege('anon', oid, 'EXECUTE') AND has_function_privilege('service_role', oid, 'EXECUTE')
     FROM pg_proc WHERE proname = 'cng_srv_receive_serial_repair'));

ROLLBACK;
