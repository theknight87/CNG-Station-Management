-- station_rulings_srv_6t.sql — regression suite for 20260927100000_station_rulings_srv_6t.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- existing: TT Z (Units TT Z 1, TT Z 2) and TT OLD (one Unit TT OLD, to be renamed)
INSERT INTO stations (id, region_id, station_name)
SELECT v.id::uuid, r.id, v.nm FROM (VALUES ('7a100000-0000-0000-0000-000000000001', 'TT Z'), ('7a100000-0000-0000-0000-000000000002', 'TT OLD')) v(id, nm), regions r WHERE r.name = 'West';
INSERT INTO units (station_id, region_id, unit_name)
SELECT v.st::uuid, r.id, v.nm FROM (VALUES ('7a100000-0000-0000-0000-000000000001', 'TT Z 1'), ('7a100000-0000-0000-0000-000000000001', 'TT Z 2'),
                                         ('7a100000-0000-0000-0000-000000000002', 'TT OLD')) v(st, nm), regions r WHERE r.name = 'West';
INSERT INTO installed_relief_valves (id, region_id, mapping_status, serial_number, source_station_name_raw)
SELECT v.id::uuid, r.id, 'needs_station_mapping', v.id, v.raw
  FROM (VALUES ('7a500000-0000-0000-0000-000000000001', 'TT ZED 2'), ('7a500000-0000-0000-0000-000000000002', 'TT ZED'),
               ('7a500000-0000-0000-0000-000000000003', 'TT NEW'), ('7a500000-0000-0000-0000-000000000004', 'TT RENAMED'),
               ('7a500000-0000-0000-0000-000000000005', 'TT GARDEN 1')) v(id, raw), regions r WHERE r.name = 'West';

\set rul '[["West","TT ZED 2","TT Z",null,null],["West","TT ZED","TT Z",null,null],["West","TT NEW","TT NEW",null,null],["West","TT RENAMED","TT OLD",null,"TT RENAMED"],["West","TT GARDEN 1","TT GARDEN",["TT GARDEN 1","TT GARDEN 2"],null]]'

SELECT pg_temp.ck('T-1 preview: 5 SRVs, 2 Stations to create, 1 rename, every ruling matches',
  (SELECT (srvs, stations_to_create, renames, rulings_without_srvs) = (5, 2, 1, 0) FROM cng_6t_preview(:'rul'::jsonb)));
SELECT pg_temp.ck('T-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6t_commit(jsonb, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6t_commit('[]', 'wrong', 'x'); RAISE NOTICE 'FAILED: T-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  T-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6t_preview(:'rul'::jsonb) \gset
SELECT srvs_linked FROM cng_6t_commit(:'rul'::jsonb, :'fp', 'test') \gset
SELECT pg_temp.ck('T-4 numbered raw name gets the matching Unit; unnumbered stays waiting for its Unit',
  (SELECT u.unit_name = 'TT Z 2' FROM installed_relief_valves i JOIN units u ON u.id = i.unit_id WHERE i.id = '7a500000-0000-0000-0000-000000000001')
  AND (SELECT station_id = '7a100000-0000-0000-0000-000000000001' AND mapping_status = 'needs_unit_mapping'
         FROM installed_relief_valves WHERE id = '7a500000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('T-5 new Station gets one Unit named as itself; the numbered new Station gets its two Units',
  (SELECT u.unit_name = 'TT NEW' FROM installed_relief_valves i JOIN units u ON u.id = i.unit_id WHERE i.id = '7a500000-0000-0000-0000-000000000003')
  AND (SELECT u.unit_name = 'TT GARDEN 1' FROM installed_relief_valves i JOIN units u ON u.id = i.unit_id WHERE i.id = '7a500000-0000-0000-0000-000000000005')
  AND (SELECT count(*) = 2 FROM units u JOIN stations s ON s.id = u.station_id WHERE s.station_name = 'TT GARDEN'));
SELECT pg_temp.ck('T-6 rename: Station and its Unit take the file spelling, and the SRV is linked to them',
  (SELECT s.station_name = 'TT RENAMED' AND u.unit_name = 'TT RENAMED' FROM installed_relief_valves i
     JOIN stations s ON s.id = i.station_id JOIN units u ON u.id = i.unit_id WHERE i.id = '7a500000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('T-7 replay: nothing left to link', (SELECT srvs = 0 FROM cng_6t_preview(:'rul'::jsonb)));
ROLLBACK;
