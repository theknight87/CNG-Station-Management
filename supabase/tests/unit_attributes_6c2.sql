-- unit_attributes_6c2.sql — regression suite for 20260923200000_unit_attributes_6c2.sql
-- Self-contained fixture; everything is rolled back.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.sqlstate(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END; RETURN s; END $$;

-- Stations (Delta unless stated):
--  1 ADDR  one Unit named by address             -> one_unit
--  2 BILA  no Unit                               -> create Unit "BILA"
--  3 FOIL  Units "FOIL 1","FOIL 2", two rows     -> numbered, row order
--  4 PAIR  Units "PAIR A","PAIR B", one row      -> held (not numbered, not one Unit)
--  5 DUP   one Unit, but two rows name it        -> held (ambiguous)
--  6 NAMED Unit "NAMED" (a 6c-1 case)            -> not an S1 row, excluded
--  7 FULL  one Unit already holding a value      -> held
--  8 WEST  in West, one Unit; row is in Delta    -> no match (Region is identity)
INSERT INTO stations (id, region_id, station_name)
SELECT ('6c210000-0000-0000-0000-00000000000' || n)::uuid, r.id, nm
  FROM (VALUES (1,'Delta','T62 ADDR'),(2,'Delta','T62 BILA'),(3,'Delta','T62 FOIL'),(4,'Delta','T62 PAIR'),
               (5,'Delta','T62 DUP'),(6,'Delta','T62 NAMED'),(7,'Delta','T62 FULL'),(8,'West','T62 WEST')) v(n,reg,nm)
  JOIN regions r ON r.name = v.reg;
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT ('6c220000-0000-0000-0000-0000000000' || lpad(n::text,2,'0'))::uuid, ('6c210000-0000-0000-0000-00000000000' || s)::uuid, r.id, nm
  FROM (VALUES (1,1,'Delta','T62 main road next to hospital'),(3,3,'Delta','T62 FOIL 1'),(4,3,'Delta','T62 FOIL 2'),
               (5,4,'Delta','T62 PAIR A'),(6,4,'Delta','T62 PAIR B'),(7,5,'Delta','T62 dup unit'),
               (8,6,'Delta','T62 NAMED'),(9,7,'Delta','T62 full unit'),(10,8,'West','T62 west unit')) v(n,s,reg,nm)
  JOIN regions r ON r.name = v.reg;
UPDATE units SET bay_status = 'open', bay_status_raw = 'OPEN' WHERE id = '6c220000-0000-0000-0000-000000000009';

INSERT INTO import_runs (id, mode, label, completed_at, summary)
VALUES ('6c230000-0000-0000-0000-000000000001', 'dry_run', 'TESTDATA-6C2', now(), '{}');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('6c230000-0000-0000-0000-000000000002', 'Station data base.xlsx', 'Sheet1', 'dry_run', '6c230000-0000-0000-0000-000000000001');

CREATE TEMP TABLE fx (n int, region text, raw text, disp text, bay text);
INSERT INTO fx VALUES
  (1,'Delta','T62 ADDR','2','OPEN'), (2,'Delta','t62  bila','1','OPEN'),
  (3,'Delta','T62 FOIL','3','OPEN'), (4,'Delta','T62 FOIL',NULL,'CLOSED'),
  (5,'Delta','T62 PAIR','1','OPEN'), (6,'Delta','T62 DUP','1','OPEN'), (7,'Delta','T62 DUP','2','OPEN'),
  (8,'Delta','T62 NAMED','1','OPEN'), (9,'Delta','T62 FULL','1','OPEN'), (10,'Delta','T62 WEST','1','OPEN');
INSERT INTO import_staging_rows (id, import_run_id, import_batch_id, source_file, source_sheet, source_row,
  source_raw, source_row_key, source_row_hash, target_table, outcome, mapping_status, normalized)
SELECT ('6c240000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       '6c230000-0000-0000-0000-000000000001', '6c230000-0000-0000-0000-000000000002',
       'Station data base.xlsx', 'Sheet1', n, jsonb_build_object('Name', raw), 'SDB2::' || n,
       encode(sha256(convert_to('6c2row' || n, 'UTF8')), 'hex'), 'unit_attributes', 'ready_unresolved', 'needs_station_mapping',
       jsonb_strip_nulls(jsonb_build_object('region', region, 'source_name_raw', raw,
         'dispenser_count_reported_raw', disp, 'bay_status_raw', bay))
  FROM fx;

CREATE TEMP TABLE pr AS SELECT * FROM cng_6c2_station_row_proposal('6c230000-0000-0000-0000-000000000001');
CREATE TEMP TABLE pv AS SELECT * FROM cng_6c2_station_row_preview('6c230000-0000-0000-0000-000000000001');

SELECT pg_temp.ck('6C2-1 exactly rows 1,2,3,4 are proposed',
  (SELECT array_agg(source_row ORDER BY source_row) FROM pr) = ARRAY[1,2,3,4]);
SELECT pg_temp.ck('6C2-2 one-Unit Station: row goes to its address-named Unit',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 1 AND unit_id = '6c220000-0000-0000-0000-000000000001' AND rule = 'one_unit'));
SELECT pg_temp.ck('6C2-3 zero-Unit Station: a Unit is to be created, none named yet',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 2 AND create_unit AND unit_id IS NULL));
SELECT pg_temp.ck('6C2-4 numbered Units follow row order (row 3 -> FOIL 1, row 4 -> FOIL 2)',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 3 AND unit_id = '6c220000-0000-0000-0000-000000000003')
  AND EXISTS (SELECT 1 FROM pr WHERE source_row = 4 AND unit_id = '6c220000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('6C2-5 unnumbered multi-Unit Station is held', NOT EXISTS (SELECT 1 FROM pr WHERE source_row = 5));
SELECT pg_temp.ck('6C2-6 two rows for a one-Unit Station are held', NOT EXISTS (SELECT 1 FROM pr WHERE source_row IN (6,7)));
SELECT pg_temp.ck('6C2-7 a row naming a Unit is not an S1 row', NOT EXISTS (SELECT 1 FROM pr WHERE source_row = 8));
SELECT pg_temp.ck('6C2-8 a Unit already holding values is not proposed', NOT EXISTS (SELECT 1 FROM pr WHERE source_row = 9));
SELECT pg_temp.ck('6C2-9 Region is identity: the West Station is never used for a Delta row', NOT EXISTS (SELECT 1 FROM pr WHERE source_row = 10));
SELECT pg_temp.ck('6C2-10 preview counts: 4 rows, 1 Unit to create, 1 one-Unit, 2 numbered',
  (SELECT (rows_to_attach, units_to_create, one_unit, numbered) = (4,1,1,2) FROM pv));
SELECT pg_temp.ck('6C2-11 no browser role can execute any 6c-2 function',
  NOT EXISTS (SELECT 1 FROM pg_proc p, unnest(ARRAY['anon','authenticated']) r
               WHERE p.proname LIKE 'cng_6c2_%' AND has_function_privilege(r, p.oid, 'EXECUTE')));
SELECT pg_temp.ck('6C2-12 stale fingerprint refused and nothing written',
  pg_temp.sqlstate($q$SELECT cng_6c2_station_row_commit('6c230000-0000-0000-0000-000000000001', repeat('0',64), 'x')$q$) = '22023'
  AND (SELECT count(*) FROM units WHERE station_id = '6c210000-0000-0000-0000-000000000002') = 0);

CREATE TEMP TABLE cr AS SELECT * FROM cng_6c2_station_row_commit('6c230000-0000-0000-0000-000000000001', (SELECT preview_fingerprint FROM pv), 'TESTDATA');
SELECT pg_temp.ck('6C2-13 commit: 1 created, 4 updated, 4 linked', (SELECT (units_created, units_updated, rows_linked) = (1,4,4) FROM cr));
SELECT pg_temp.ck('6C2-14 created Unit is named exactly as its Station, in its Region, with provenance',
  (SELECT count(*) FROM units u JOIN stations s ON s.id = u.station_id
    WHERE u.station_id = '6c210000-0000-0000-0000-000000000002' AND u.unit_name = s.station_name
      AND u.region_id = s.region_id AND u.source_raw->>'stage' = '6c-2' AND u.bay_status = 'open') = 1);
SELECT pg_temp.ck('6C2-15 numbered Units got their own rows'' values (FOIL 2 closed, no dispenser)',
  (SELECT (bay_status::text, dispenser_count_raw IS NULL) = ('closed', true) FROM units WHERE id = '6c220000-0000-0000-0000-000000000004')
  AND (SELECT dispenser_count_reported FROM units WHERE id = '6c220000-0000-0000-0000-000000000003') = 3);
SELECT pg_temp.ck('6C2-16 no Station value written; held Units untouched',
  (SELECT count(*) FROM stations WHERE station_name LIKE 'T62%' AND bay_status_raw IS NOT NULL) = 0
  AND (SELECT count(*) FROM units WHERE id IN ('6c220000-0000-0000-0000-000000000005','6c220000-0000-0000-0000-000000000006',
        '6c220000-0000-0000-0000-000000000007','6c220000-0000-0000-0000-000000000008','6c220000-0000-0000-0000-000000000010')
        AND bay_status_raw IS NOT NULL) = 0);
SELECT pg_temp.ck('6C2-17 every proposed row links to a Unit of its own Station',
  (SELECT count(*) FROM import_staging_rows s JOIN units u ON u.id = s.committed_entity_id JOIN pr ON pr.staging_row_id = s.id
    WHERE u.station_id = pr.station_id AND s.committed_entity_kind = 'unit') = 4);
SELECT pg_temp.ck('6C2-18 one audit row, no forged actor',
  (SELECT count(*) FROM audit_logs WHERE actor_label = 'service_role:unit_attributes_6c2' AND actor_id IS NULL
     AND entity_id = '6c230000-0000-0000-0000-000000000001') = 1);
SELECT pg_temp.ck('6C2-19 replay refused; nothing left',
  (SELECT rows_to_attach FROM cng_6c2_station_row_preview('6c230000-0000-0000-0000-000000000001')) = 0
  AND pg_temp.sqlstate(format($q$SELECT cng_6c2_station_row_commit('6c230000-0000-0000-0000-000000000001', %L, 'x')$q$,
                       (SELECT preview_fingerprint FROM pv))) = '22023');

ROLLBACK;
