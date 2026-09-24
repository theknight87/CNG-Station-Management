-- owner_station_rulings_6g.sql — regression suite for 20260924100000_owner_station_rulings_6g.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- Rulings: a Station with two Units (two spellings of Unit 1), a Station with no Unit, and a Unit-less
-- spelling of the two-Unit Station.
INSERT INTO owner_station_rulings (ruling_set, region_id, source_name_raw, other_spelling_raw, station_name, unit_name, evidence)
SELECT 'T6G', r.id, v.src, v.oth, v.st, v.un, 'test'
  FROM (VALUES ('TG ALPHA 1', 'TG ALPHA1', 'TG ALPHA', 'TG ALPHA 1'),
               ('TG  ALPHA 1', NULL, 'TG ALPHA', 'TG ALPHA 1'),
               ('TG ALPHA 2', NULL, 'TG ALPHA', 'TG ALPHA 2'),
               ('TG ALPHA', NULL, 'TG ALPHA', NULL),
               ('TG BETA', NULL, 'TG BETA', NULL)) v(src, oth, st, un)
  JOIN regions r ON r.name = 'Alex';

CREATE TEMP TABLE p AS SELECT * FROM cng_6g_proposal('T6G');
SELECT pg_temp.ck('G6-1 one Station per normalized name; two Stations proposed',
  (SELECT count(*) FROM p WHERE kind = 'station') = 2);
SELECT pg_temp.ck('G6-2 Units only where a ruling names one; spellings of one Unit fold to one (2 Units)',
  (SELECT count(*) FROM p WHERE kind = 'unit') = 2);
SELECT pg_temp.ck('G6-3 no Unit for a Station whose rulings name none (D7)',
  NOT EXISTS (SELECT 1 FROM p WHERE kind = 'unit' AND station_name = 'TG BETA'));

SELECT preview_fingerprint AS fp, stations_to_create, units_to_create FROM cng_6g_preview('T6G') \gset
SELECT pg_temp.ck('G6-4 preview counts', :stations_to_create = 2 AND :units_to_create = 2);
SELECT pg_temp.ck('G6-5 preview is deterministic', (SELECT preview_fingerprint FROM cng_6g_preview('T6G')) = :'fp');
DO $$ BEGIN
  PERFORM cng_6g_commit('T6G', 'wrong', 'test');
  RAISE NOTICE 'FAILED: G6-6 a wrong fingerprint was accepted';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  G6-6 a wrong fingerprint is refused';
END $$;
SELECT pg_temp.ck('G6-7 not callable by authenticated',
  NOT has_function_privilege('authenticated', 'cng_6g_commit(text, text, text)', 'EXECUTE'));

SELECT stations_created, units_created FROM cng_6g_commit('T6G', :'fp', 'test') \gset
SELECT pg_temp.ck('G6-8 commit creates exactly what was previewed', :stations_created = 2 AND :units_created = 2);
SELECT pg_temp.ck('G6-9 Units sit under their Station in the same Region',
  (SELECT count(*) FROM units u JOIN stations s ON s.id = u.station_id AND s.region_id = u.region_id
    WHERE s.station_name = 'TG ALPHA') = 2
  AND (SELECT count(*) FROM units u JOIN stations s ON s.id = u.station_id WHERE s.station_name = 'TG BETA') = 0);
SELECT pg_temp.ck('G6-10 provenance names the source spellings',
  (SELECT source_raw->'source_names' @> '["TG ALPHA", "TG ALPHA 1"]'::jsonb FROM stations WHERE station_name = 'TG ALPHA'));
SELECT pg_temp.ck('G6-11 audited once', (SELECT count(*) FROM audit_logs WHERE actor_label = 'service_role:owner_station_rulings_6g') = 1);
SELECT pg_temp.ck('G6-12 after commit nothing is left to create',
  (SELECT stations_to_create + units_to_create FROM cng_6g_preview('T6G')) = 0);
DO $$ BEGIN
  PERFORM cng_6g_commit('T6G', (SELECT preview_fingerprint FROM cng_6g_preview('T6G')), 'test');
  RAISE NOTICE 'FAILED: G6-13 replay created something';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  G6-13 replay is refused';
END $$;

-- A Station identity spelled two ways in the rulings is refused, not tie-broken.
INSERT INTO owner_station_rulings (ruling_set, region_id, source_name_raw, station_name, evidence)
SELECT 'T6G-X', r.id, v.src, v.st, 'test'
  FROM (VALUES ('TG GAMMA', 'TG GAMMA'), ('TG  GAMMA', 'TG  GAMMA')) v(src, st) JOIN regions r ON r.name = 'Canal';
SELECT pg_temp.ck('G6-14 a two-spelling Station identity is reported',
  (SELECT spelling_conflicts FROM cng_6g_preview('T6G-X')) = 1);
DO $$ BEGIN
  PERFORM cng_6g_commit('T6G-X', (SELECT preview_fingerprint FROM cng_6g_preview('T6G-X')), 'test');
  RAISE NOTICE 'FAILED: G6-15 a two-spelling identity was committed';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  G6-15 a two-spelling identity is refused';
END $$;
SELECT pg_temp.ck('G6-16 rulings are readable only by manager/admin; no browser write grant',
  NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_name = 'owner_station_rulings'
               AND grantee IN ('authenticated', 'anon') AND privilege_type <> 'SELECT'));

ROLLBACK;
