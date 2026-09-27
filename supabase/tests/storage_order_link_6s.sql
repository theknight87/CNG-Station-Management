-- storage_order_link_6s.sql — regression suite for 20260927090000_storage_order_link_6s.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO app_users (id, auth_user_id, email, role, is_active, full_name)
VALUES ('6f900000-0000-0000-0000-0000000000aa', gen_random_uuid(), 'ts-owner@example.test', 'admin', true, 'TS owner');
INSERT INTO stations (id, region_id, station_name) SELECT '6f900000-0000-0000-0000-000000000001', id, 'TS ST' FROM regions WHERE name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '6f900000-0000-0000-0000-000000000002', '6f900000-0000-0000-0000-000000000001', id, 'TS ST' FROM regions WHERE name = 'West';
INSERT INTO storage_vessels (id, station_id, region_id, unit_id, mapping_status, serial_number)
SELECT v.id::uuid, '6f900000-0000-0000-0000-000000000001', r.id, '6f900000-0000-0000-0000-000000000002', 'resolved', v.sn
  FROM (VALUES ('6f900000-0000-0000-0000-0000000000b1', 'V-A'), ('6f900000-0000-0000-0000-0000000000b2', 'V-B')) v(id, sn), regions r WHERE r.name = 'West';
INSERT INTO installed_relief_valves (id, station_id, unit_id, region_id, mapping_status, expected_parent_kind, serial_number)
SELECT v.id::uuid, '6f900000-0000-0000-0000-000000000001', '6f900000-0000-0000-0000-000000000002', r.id, 'needs_equipment_mapping', 'storage_vessel', v.sn
  FROM (VALUES ('6f900000-0000-0000-0000-0000000000c1', 'S-2'), ('6f900000-0000-0000-0000-0000000000c2', 'S-1'),
               ('6f900000-0000-0000-0000-0000000000c3', 'S-3')) v(id, sn), regions r WHERE r.name = 'West';

SELECT pg_temp.ck('S-1 SRVs pair with vessels in serial order, wrapping',
  (SELECT string_agg(i.serial_number || '>' || v.serial_number, ',' ORDER BY i.serial_number)
     FROM cng_6s_proposal() p JOIN installed_relief_valves i ON i.id = p.srv_id JOIN storage_vessels v ON v.id = p.vessel_id
    WHERE p.unit_id = '6f900000-0000-0000-0000-000000000002') = 'S-1>V-A,S-2>V-B,S-3>V-A');
SELECT pg_temp.ck('S-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6s_commit(text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6s_commit('wrong', 'x'); RAISE NOTICE 'FAILED: S-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  S-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6s_preview() \gset
SELECT linked FROM cng_6s_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('S-4 all three resolved, no note written on the records',
  (SELECT count(*) = 3 FROM installed_relief_valves WHERE unit_id = '6f900000-0000-0000-0000-000000000002'
     AND mapping_status = 'resolved' AND storage_vessel_id IS NOT NULL AND mapping_note IS NULL));
SELECT pg_temp.ck('S-5 replay: nothing left in the Unit',
  NOT EXISTS (SELECT 1 FROM cng_6s_proposal() WHERE unit_id = '6f900000-0000-0000-0000-000000000002'));
ROLLBACK;
