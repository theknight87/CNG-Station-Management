-- one_unit_stations_6k.sql — regression suite for 20260924180000_one_unit_stations_6k.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name)
SELECT ('6d100000-0000-0000-0000-00000000000' || n)::uuid, r.id, 'TK ' || n FROM generate_series(1, 2) n, regions r WHERE r.name = 'Canal';
INSERT INTO units (station_id, region_id, unit_name) SELECT '6d100000-0000-0000-0000-000000000002', id, 'TK 2 A' FROM regions WHERE name = 'Canal';

SELECT pg_temp.ck('K-1 only Stations with no Unit are proposed, named as the Station',
  (SELECT unit_name FROM cng_6k_proposal() WHERE station_id = '6d100000-0000-0000-0000-000000000001') = 'TK 1'
  AND NOT EXISTS (SELECT 1 FROM cng_6k_proposal() WHERE station_id = '6d100000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('K-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6k_commit(text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6k_commit('wrong', 'x'); RAISE NOTICE 'FAILED: K-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  K-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6k_preview() \gset
SELECT units_created FROM cng_6k_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('K-4 the Unit exists under its Station and Region; the other Station is untouched',
  (SELECT count(*) FROM units u JOIN stations s ON s.id = u.station_id AND s.region_id = u.region_id
    WHERE s.id = '6d100000-0000-0000-0000-000000000001' AND u.unit_name = 'TK 1') = 1
  AND (SELECT count(*) FROM units WHERE station_id = '6d100000-0000-0000-0000-000000000002') = 1);
SELECT pg_temp.ck('K-5 replay: every Station now has a Unit', NOT EXISTS (SELECT 1 FROM cng_6k_proposal()));
ROLLBACK;
