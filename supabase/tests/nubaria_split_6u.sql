-- nubaria_split_6u.sql — regression suite for 20260927110000_nubaria_split_6u.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO app_users (id, auth_user_id, email, role, is_active, full_name)
VALUES ('7b900000-0000-0000-0000-0000000000aa', gen_random_uuid(), 'tu-owner@example.test', 'admin', true, 'TU owner');
INSERT INTO stations (id, region_id, station_name)
SELECT v.id::uuid, r.id, v.nm FROM (VALUES ('7b100000-0000-0000-0000-000000000001', 'TU OLD'), ('7b100000-0000-0000-0000-000000000002', 'TU 81')) v(id, nm), regions r WHERE r.name = 'Alex';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, v.st::uuid, r.id, v.nm FROM (VALUES ('7b200000-0000-0000-0000-000000000001', '7b100000-0000-0000-0000-000000000001', 'TU OLD 81'),
                                                   ('7b200000-0000-0000-0000-000000000002', '7b100000-0000-0000-0000-000000000002', 'TU 81')) v(id, st, nm), regions r WHERE r.name = 'Alex';
INSERT INTO compressors (station_id, region_id, unit_id, mapping_status, model)
SELECT '7b100000-0000-0000-0000-000000000001', id, '7b200000-0000-0000-0000-000000000001', 'resolved', 'SAFE' FROM regions WHERE name = 'Alex';
INSERT INTO storage_vessels (station_id, region_id, unit_id, mapping_status, manufacturer)
SELECT '7b100000-0000-0000-0000-000000000002', id, '7b200000-0000-0000-0000-000000000002', 'resolved', 'EKC' FROM regions WHERE name = 'Alex';
INSERT INTO installed_relief_valves (station_id, region_id, mapping_status, location_raw, expected_parent_kind, manufacturer, serial_number)
SELECT '7b100000-0000-0000-0000-000000000001', r.id, 'needs_unit_mapping', v.loc, v.k::srv_parent_kind, v.m, NULL
  FROM regions r, (VALUES ('Stage', 'compressor', 'DK-LOK', 5), ('Stage', 'compressor', 'Technical', 6), ('Storage', 'storage_vessel', 'EKC', 6)) v(loc, k, m, n),
       generate_series(1, v.n) WHERE r.name = 'Alex';

SELECT pg_temp.ck('U-1 preview finds 8 for 59, 9 for 81, one SAFE compressor, one vessel at 81',
  (SELECT (to_59, to_81, unplaced, safe_compressors, vessels_at_81, units_at_81, name_taken) = (8, 9, 0, 1, 1, 1, 0)
     FROM cng_6u_preview('7b100000-0000-0000-0000-000000000001', '7b100000-0000-0000-0000-000000000002', '7b200000-0000-0000-0000-000000000001', 'TU 59')));
SELECT pg_temp.ck('U-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6u_commit(uuid, uuid, uuid, text, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6u_commit('7b100000-0000-0000-0000-000000000001', '7b100000-0000-0000-0000-000000000002', '7b200000-0000-0000-0000-000000000001', 'TU 59', 'wrong', 'x');
  RAISE NOTICE 'FAILED: U-3'; EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  U-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6u_preview('7b100000-0000-0000-0000-000000000001', '7b100000-0000-0000-0000-000000000002', '7b200000-0000-0000-0000-000000000001', 'TU 59') \gset
SELECT srvs_resolved FROM cng_6u_commit('7b100000-0000-0000-0000-000000000001', '7b100000-0000-0000-0000-000000000002', '7b200000-0000-0000-0000-000000000001', 'TU 59', :'fp', 'test') \gset
SELECT pg_temp.ck('U-4 TU 59 exists with one Unit, a Kwangshin compressor holding the 5 DK-LOK, and a vessel holding 3',
  (SELECT count(*) = 5 FROM installed_relief_valves i JOIN compressors c ON c.id = i.compressor_id JOIN stations s ON s.id = i.station_id
    WHERE s.station_name = 'TU 59' AND c.manufacturer = 'Kwangshin' AND i.manufacturer = 'DK-LOK' AND i.mapping_status = 'resolved')
  AND (SELECT count(*) = 3 FROM installed_relief_valves i JOIN stations s ON s.id = i.station_id WHERE s.station_name = 'TU 59' AND i.storage_vessel_id IS NOT NULL));
SELECT pg_temp.ck('U-5 the SAFE compressor moved to TU 81 and carries the 6 Technical; 3 EKC on TU 81''s vessel',
  (SELECT count(*) = 6 FROM installed_relief_valves i JOIN compressors c ON c.id = i.compressor_id
    WHERE c.model = 'SAFE' AND c.station_id = '7b100000-0000-0000-0000-000000000002' AND i.manufacturer = 'Technical')
  AND (SELECT count(*) = 3 FROM installed_relief_valves i JOIN storage_vessels v ON v.id = i.storage_vessel_id WHERE v.station_id = '7b100000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('U-6 replay is refused (nothing left, name taken)',
  (SELECT to_59 + to_81 = 0 AND name_taken = 1 FROM cng_6u_preview('7b100000-0000-0000-0000-000000000001', '7b100000-0000-0000-0000-000000000002', '7b200000-0000-0000-0000-000000000001', 'TU 59')));
ROLLBACK;
