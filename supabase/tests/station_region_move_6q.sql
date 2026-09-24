-- station_region_move_6q.sql — regression suite for 20260925030000_station_region_move_6q.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name) SELECT '6d900000-0000-0000-0000-000000000001', id, 'TQ ST' FROM regions WHERE name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '6d900000-0000-0000-0000-000000000002', '6d900000-0000-0000-0000-000000000001', id, 'TQ ST' FROM regions WHERE name = 'East';
INSERT INTO compressors (id, station_id, region_id, unit_id, mapping_status)
SELECT '6d900000-0000-0000-0000-000000000003', '6d900000-0000-0000-0000-000000000001', id, '6d900000-0000-0000-0000-000000000002', 'resolved' FROM regions WHERE name = 'East';
INSERT INTO installed_relief_valves (id, region_id, mapping_status, serial_number, source_station_name_raw)
SELECT '6d900000-0000-0000-0000-000000000004', id, 'needs_station_mapping', 'TQ-1', 'TQ ST' FROM regions WHERE name = 'Delta';

SELECT pg_temp.ck('Q-1 preview counts the tree and the valve to relink',
  (SELECT (units, compressors, srvs_to_relink, refused) = (1, 1, 1, 0) FROM cng_6q_preview('6d900000-0000-0000-0000-000000000001', 'Delta')));
SELECT pg_temp.ck('Q-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6q_commit(uuid, text, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6q_commit('6d900000-0000-0000-0000-000000000001', 'Delta', 'wrong', 'x'); RAISE NOTICE 'FAILED: Q-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  Q-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6q_preview('6d900000-0000-0000-0000-000000000001', 'Delta') \gset
SELECT moved_rows FROM cng_6q_commit('6d900000-0000-0000-0000-000000000001', 'Delta', :'fp', 'test') \gset
SELECT pg_temp.ck('Q-4 Station, Unit and compressor are all in Delta',
  (SELECT count(DISTINCT r) = 1 AND min(r) = 'Delta' FROM (
     SELECT g.name r FROM stations s JOIN regions g ON g.id = s.region_id WHERE s.id = '6d900000-0000-0000-0000-000000000001'
     UNION ALL SELECT g.name FROM units u JOIN regions g ON g.id = u.region_id WHERE u.id = '6d900000-0000-0000-0000-000000000002'
     UNION ALL SELECT g.name FROM compressors c JOIN regions g ON g.id = c.region_id WHERE c.id = '6d900000-0000-0000-0000-000000000003') x));
SELECT pg_temp.ck('Q-5 the Delta valve got the Station and now needs its Unit',
  (SELECT station_id = '6d900000-0000-0000-0000-000000000001' AND mapping_status = 'needs_unit_mapping'
     FROM installed_relief_valves WHERE id = '6d900000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('Q-6 replay is refused (already in Delta)',
  (SELECT refused = 1 FROM cng_6q_preview('6d900000-0000-0000-0000-000000000001', 'Delta')));
ROLLBACK;
