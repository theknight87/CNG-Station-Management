-- unit_rulings_srv_6v.sql — regression suite for 20260927120000_unit_rulings_srv_6v.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name) SELECT '7c100000-0000-0000-0000-000000000001', id, 'TV ST' FROM regions WHERE name = 'West';
INSERT INTO stations (id, region_id, station_name) SELECT '7c100000-0000-0000-0000-000000000002', id, 'TV OTHER' FROM regions WHERE name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, v.st::uuid, r.id, v.nm FROM (VALUES ('7c200000-0000-0000-0000-000000000001', '7c100000-0000-0000-0000-000000000001', 'TV ST 1'),
                                                   ('7c200000-0000-0000-0000-000000000002', '7c100000-0000-0000-0000-000000000001', 'TV ST 2'),
                                                   ('7c200000-0000-0000-0000-000000000003', '7c100000-0000-0000-0000-000000000002', 'TV OTHER')) v(id, st, nm), regions r WHERE r.name = 'West';
INSERT INTO installed_relief_valves (id, station_id, region_id, mapping_status, source_station_name_raw)
SELECT v.id::uuid, '7c100000-0000-0000-0000-000000000001', r.id, 'needs_unit_mapping', v.raw
  FROM (VALUES ('7c500000-0000-0000-0000-000000000001', 'TV 1 X'), ('7c500000-0000-0000-0000-000000000002', 'TV 1 X'),
               ('7c500000-0000-0000-0000-000000000003', 'TV 2 X'), ('7c500000-0000-0000-0000-000000000004', 'TV X')) v(id, raw), regions r WHERE r.name = 'West';

SELECT jsonb_build_array(jsonb_build_array('7c100000-0000-0000-0000-000000000001', md5('TV 1 X'), '7c200000-0000-0000-0000-000000000001'),
                         jsonb_build_array('7c100000-0000-0000-0000-000000000001', md5('TV 2 X'), '7c200000-0000-0000-0000-000000000002'))::text AS rul \gset
SELECT jsonb_build_array(jsonb_build_array('7c100000-0000-0000-0000-000000000001', md5('TV X'), '7c200000-0000-0000-0000-000000000003'))::text AS bad \gset

SELECT pg_temp.ck('V-1 preview: 3 SRVs, every ruling matches', (SELECT (srvs, rulings_without_srvs) = (3, 0) FROM cng_6v_preview(:'rul'::jsonb)));
SELECT pg_temp.ck('V-2 a Unit of another Station matches nothing', (SELECT srvs = 0 FROM cng_6v_preview(:'bad'::jsonb)));
SELECT pg_temp.ck('V-3 service_role only', NOT has_function_privilege('authenticated', 'cng_6v_commit(jsonb, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6v_commit('[]', 'wrong', 'x'); RAISE NOTICE 'FAILED: V-4';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  V-4 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6v_preview(:'rul'::jsonb) \gset
SELECT srvs_linked FROM cng_6v_commit(:'rul'::jsonb, :'fp', 'test') \gset
SELECT pg_temp.ck('V-5 ruled SRVs get their Unit and await equipment',
  (SELECT count(*) = 2 FROM installed_relief_valves WHERE unit_id = '7c200000-0000-0000-0000-000000000001' AND mapping_status = 'needs_equipment_mapping')
  AND (SELECT count(*) = 1 FROM installed_relief_valves WHERE unit_id = '7c200000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('V-6 an unruled raw name is untouched',
  (SELECT unit_id IS NULL AND mapping_status = 'needs_unit_mapping' FROM installed_relief_valves WHERE id = '7c500000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('V-7 replay: nothing left', (SELECT srvs = 0 FROM cng_6v_preview(:'rul'::jsonb)));
ROLLBACK;
