-- station_db_attributes_6j.sql — regression suite for 20260924160000_station_db_attributes_6j.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- Upper Stations: TJ NAMED (Units 1, 2), TJ ONE (one Unit), TJ NONE (no Unit), TJ TWO-ROWS (no Unit, two rows), TJ MULTI (two Units).
INSERT INTO stations (id, region_id, station_name)
SELECT ('6c100000-0000-0000-0000-00000000000' || v.n)::uuid, r.id, v.nm
  FROM (VALUES (1, 'TJ NAMED'), (2, 'TJ ONE'), (3, 'TJ NONE'), (4, 'TJ TWO-ROWS'), (5, 'TJ MULTI')) v(n, nm), regions r WHERE r.name = 'Upper';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, v.st::uuid, r.id, v.nm
  FROM (VALUES ('6c200000-0000-0000-0000-000000000001', '6c100000-0000-0000-0000-000000000001', 'TJ NAMED 1'),
               ('6c200000-0000-0000-0000-000000000002', '6c100000-0000-0000-0000-000000000001', 'TJ NAMED 2'),
               ('6c200000-0000-0000-0000-000000000003', '6c100000-0000-0000-0000-000000000002', 'TJ ONE UNIT'),
               ('6c200000-0000-0000-0000-000000000005', '6c100000-0000-0000-0000-000000000005', 'TJ MULTI 1'),
               ('6c200000-0000-0000-0000-000000000006', '6c100000-0000-0000-0000-000000000005', 'TJ MULTI 2')) v(id, st, nm),
       regions r WHERE r.name = 'Upper';
INSERT INTO owner_station_rulings (ruling_set, region_id, source_name_raw, station_name, unit_name, evidence)
SELECT 'T6J', r.id, v.src, v.st, v.un, 'test'
  FROM (VALUES ('TJ NAMED 2', 'TJ NAMED', 'TJ NAMED 2'), ('TJ ONE', 'TJ ONE', NULL), ('TJ NONE', 'TJ NONE', NULL),
               ('TJ TWO-ROWS A', 'TJ TWO-ROWS', NULL), ('TJ TWO-ROWS B', 'TJ TWO-ROWS', NULL), ('TJ MULTI', 'TJ MULTI', NULL)) v(src, st, un),
       regions r WHERE r.name = 'Upper';

INSERT INTO import_runs (id, mode, label, completed_at, summary) VALUES ('6c300000-0000-0000-0000-000000000001', 'dry_run', 'TESTDATA-6J', now(), '{}');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('6c300000-0000-0000-0000-000000000002', 'TJ.xlsx', 'Sheet1', 'dry_run', '6c300000-0000-0000-0000-000000000001');
INSERT INTO import_staging_rows (id, import_run_id, import_batch_id, source_file, source_sheet, source_row, source_raw,
                                 source_row_key, source_row_hash, target_table, outcome, normalized)
SELECT ('6c400000-0000-0000-0000-00000000000' || v.n)::uuid, '6c300000-0000-0000-0000-000000000001', '6c300000-0000-0000-0000-000000000002',
       'TJ.xlsx', 'Sheet1', v.n, '{}'::jsonb, 'TJ|' || v.n, encode(sha256(convert_to('6j' || v.n, 'UTF8')), 'hex'), 'unit_attributes', 'ready_unresolved',
       jsonb_build_object('region', 'Upper', 'source_name_raw', v.nm, 'dispenser_count_reported_raw', v.disp, 'bay_status_raw', 'OPEN',
                          'compressor_model', v.model, 'total_running_hours', v.hrs)
  FROM (VALUES (1, 'TJ NAMED 2', '3', 'GALLILEO', '1200'), (2, 'TJ ONE', 'x2', NULL, NULL), (3, 'TJ NONE', '4', 'SAFE', '12.5'),
               (4, 'TJ TWO-ROWS A', '1', NULL, NULL), (5, 'TJ TWO-ROWS B', '2', NULL, NULL), (6, 'TJ MULTI', '2', NULL, NULL),
               (7, 'TJ UNKNOWN', '2', NULL, NULL)) v(n, nm, disp, model, hrs);

CREATE TEMP TABLE p AS SELECT * FROM cng_6j_proposal() WHERE staging_row_id::text LIKE '6c4%';
SELECT pg_temp.ck('J-1 a ruled Unit name -> that Unit', (SELECT (kind, unit_id) = ('named_unit', '6c200000-0000-0000-0000-000000000002'::uuid)
  FROM p WHERE staging_row_id = '6c400000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('J-2 a one-Unit Station -> its Unit', (SELECT (kind, unit_id) = ('one_unit', '6c200000-0000-0000-0000-000000000003'::uuid)
  FROM p WHERE staging_row_id = '6c400000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('J-3 a no-Unit Station with one row -> a Unit named as the Station', (SELECT (kind, unit_id IS NULL, unit_name) = ('create_unit', true, 'TJ NONE')
  FROM p WHERE staging_row_id = '6c400000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('J-4 held: two rows for one no-Unit Station, a multi-Unit Station, and an unknown name',
  NOT EXISTS (SELECT 1 FROM p WHERE staging_row_id IN ('6c400000-0000-0000-0000-000000000004', '6c400000-0000-0000-0000-000000000005',
                                                      '6c400000-0000-0000-0000-000000000006', '6c400000-0000-0000-0000-000000000007')));
SELECT pg_temp.ck('J-5 counts only from plain integers; raw kept', (SELECT dispenser_count IS NULL AND dispenser_count_raw = 'x2'
  FROM p WHERE staging_row_id = '6c400000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('J-6 service_role only', NOT has_function_privilege('authenticated', 'cng_6j_commit(text, text)', 'EXECUTE'));

SELECT preview_fingerprint AS fp FROM cng_6j_preview() \gset
SELECT pg_temp.ck('J-7 preview deterministic', (SELECT preview_fingerprint FROM cng_6j_preview()) = :'fp');
DO $$ BEGIN
  PERFORM cng_6j_commit('wrong', 'test');
  RAISE NOTICE 'FAILED: J-8 wrong fingerprint accepted';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  J-8 a wrong fingerprint is refused';
END $$;
SELECT rows_attached, units_created, compressors_created FROM cng_6j_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('J-9 commit reconciles', :rows_attached >= 3 AND :units_created >= 1 AND :compressors_created >= 2);
SELECT pg_temp.ck('J-10 the created Unit is named as its Station and holds the row',
  (SELECT (u.unit_name, u.dispenser_count_reported, u.bay_status::text) = ('TJ NONE', 4, 'open')
     FROM units u WHERE u.station_id = '6c100000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('J-11 compressors: model as written, numbers only from plain numbers, under the right Unit',
  (SELECT (c.model, c.total_running_hours) = ('GALLILEO', 1200::numeric) FROM compressors c WHERE c.unit_id = '6c200000-0000-0000-0000-000000000002')
  AND (SELECT c.total_running_hours FROM compressors c JOIN units u ON u.id = c.unit_id WHERE u.station_id = '6c100000-0000-0000-0000-000000000003') = 12.5);
SELECT pg_temp.ck('J-12 no Unit created where the rule does not apply',
  (SELECT count(*) FROM units WHERE station_id IN ('6c100000-0000-0000-0000-000000000004', '6c100000-0000-0000-0000-000000000005')) = 2);
SELECT pg_temp.ck('J-13 lineage and replay', (SELECT committed_entity_kind FROM import_staging_rows WHERE id = '6c400000-0000-0000-0000-000000000003') = 'unit'
  AND NOT EXISTS (SELECT 1 FROM cng_6j_proposal() WHERE staging_row_id::text LIKE '6c4%'));

ROLLBACK;
