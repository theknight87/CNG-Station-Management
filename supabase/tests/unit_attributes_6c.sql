-- unit_attributes_6c.sql — regression suite for 20260923180000_unit_attributes_6c.sql
-- Self-contained fixture; everything is rolled back.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

CREATE FUNCTION pg_temp.sqlstate(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END; RETURN s; END $$;

-- ---------------------------------------------------------------- fixture
-- East: "ONE" (single Unit named like its Station = SU), "TWO" with Units
-- "TWO" and "TWO 2" (SU2 + U1), "ADDR" whose only Unit has another name (S1),
-- "FULL" whose Unit already carries a value (never overwritten).
-- West: a Unit with the SAME name as East "TWO 2" (Region is identity).
INSERT INTO stations (id, region_id, station_name)
SELECT ('6c100000-0000-0000-0000-00000000000' || n)::uuid, r.id, nm
  FROM (VALUES (1,'East','T6C ONE'),(2,'East','T6C TWO'),(3,'East','T6C ADDR'),(4,'East','T6C FULL'),(5,'West','T6C WEST')) v(n,reg,nm)
  JOIN regions r ON r.name = v.reg;
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT ('6c200000-0000-0000-0000-00000000000' || n)::uuid, ('6c100000-0000-0000-0000-00000000000' || s)::uuid, r.id, nm
  FROM (VALUES (1,1,'East','T6C ONE'),(2,2,'East','T6C TWO'),(3,2,'East','T6C TWO 2'),
               (4,3,'East','T6C some street address'),(5,4,'East','T6C FULL'),(6,5,'West','T6C TWO 2')) v(n,s,reg,nm)
  JOIN regions r ON r.name = v.reg;
UPDATE units SET bay_status_raw = 'OPEN', bay_status = 'open' WHERE id = '6c200000-0000-0000-0000-000000000005';

INSERT INTO import_runs (id, mode, label, completed_at, summary)
VALUES ('6c300000-0000-0000-0000-000000000001', 'dry_run', 'TESTDATA-6C', now(), '{"manifest_fingerprint":"6cmanifest"}');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('6c300000-0000-0000-0000-000000000002', 'Station data base.xlsx', 'Sheet1', 'dry_run', '6c300000-0000-0000-0000-000000000001');

CREATE TEMP TABLE fx (n int, region text, raw text, disp text, hose text, stor text, bay text);
INSERT INTO fx VALUES
  (1, 'East', 'T6C ONE',     '3',     '6',  '4',  'Open Area'),   -- SU
  (2, 'East', 't6c  two',    '2',     '4',  NULL, 'CLOSED'),      -- SU2 -> Unit "T6C TWO"
  (3, 'East', 'T6C TWO 2',   '2 / 4', '4',  '2',  'Close Area'),  -- U1; non-integer count kept raw
  (4, 'East', 'T6C ADDR',    '1',     '2',  '1',  'open'),        -- S1: Station only -> held
  (5, 'East', 'T6C FULL',    '1',     '2',  '1',  'open'),        -- Unit already holds a value -> held
  (6, 'East', 'T6C NOWHERE', '1',     '2',  '1',  'open'),        -- N1 -> held
  (7, 'East', NULL,          NULL,    NULL, NULL, NULL),          -- X: blank row
  (8, NULL,   '  ',          NULL,    NULL, NULL, NULL),          -- X: blank row
  (9, 'Upper','T6C TWO 2',   '1',     '1',  '1',  'open');        -- Z Region: no match -> held
INSERT INTO import_staging_rows (
  id, import_run_id, import_batch_id, source_file, source_sheet, source_row,
  source_raw, source_row_key, source_row_hash, target_table, outcome, mapping_status, normalized)
SELECT ('6c400000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       '6c300000-0000-0000-0000-000000000001', '6c300000-0000-0000-0000-000000000002',
       'Station data base.xlsx', 'Sheet1', n, jsonb_build_object('Name', raw),
       'SDB::Sheet1::' || n, encode(sha256(convert_to('6crow' || n, 'UTF8')), 'hex'),
       'unit_attributes', 'ready_unresolved', 'needs_station_mapping',
       jsonb_strip_nulls(jsonb_build_object('region', region, 'source_name_raw', raw,
         'dispenser_count_reported_raw', disp, 'hose_count_reported_raw', hose,
         'storage_count_reported_raw', stor, 'bay_status_raw', bay, 'station_id', md5('s' || n)))
  FROM fx;

CREATE TEMP TABLE pv AS SELECT * FROM cng_6c_unit_attribute_preview('6c300000-0000-0000-0000-000000000001');
CREATE TEMP TABLE pr AS SELECT * FROM cng_6c_unit_attribute_proposal('6c300000-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------- proposal
SELECT pg_temp.ck('6C-1 exactly SU, SU2 and U1 are proposed (3 rows)', (SELECT count(*) FROM pr) = 3);
SELECT pg_temp.ck('6C-2 SU attaches to the single Unit sharing the Station name',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 1 AND unit_id = '6c200000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('6C-3 SU2: plain name "TWO" is Unit "TWO", not "TWO 2"',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 2 AND unit_id = '6c200000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('6C-4 U1 "TWO 2" attaches to the EAST Unit, never the West namesake',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 3 AND unit_id = '6c200000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('6C-5 a Station-only name is NOT pushed down to its only Unit (S1 held)',
  NOT EXISTS (SELECT 1 FROM pr WHERE source_row = 4));
SELECT pg_temp.ck('6C-6 a Unit already holding a value is not proposed', NOT EXISTS (SELECT 1 FROM pr WHERE source_row = 5));
SELECT pg_temp.ck('6C-7 unmatched and zero-Station-Region names are held', NOT EXISTS (SELECT 1 FROM pr WHERE source_row IN (6, 9)));
SELECT pg_temp.ck('6C-8 non-integer count stays NULL with its raw text kept',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 3 AND dispenser_count IS NULL AND dispenser_count_raw = '2 / 4'));
SELECT pg_temp.ck('6C-9 bay text maps deterministically (Open Area->open, CLOSED/Close Area->closed)',
  (SELECT array_agg(bay_status::text ORDER BY source_row) FROM pr) = ARRAY['open','closed','closed']);
SELECT pg_temp.ck('6C-10 NULL source cells stay NULL (no fabricated storage count)',
  EXISTS (SELECT 1 FROM pr WHERE source_row = 2 AND storage_count IS NULL AND storage_count_raw IS NULL));
SELECT pg_temp.ck('6C-11 preview counts: 3 rows, 3 Units, 2 blank rows',
  (SELECT (rows_to_attach, units_affected, blank_rows_to_reject) = (3, 3, 2) FROM pv));
SELECT pg_temp.ck('6C-12 fingerprint is 6C-bound 64-hex and stable across calls',
  (SELECT preview_fingerprint ~ '^[0-9a-f]{64}$' FROM pv)
  AND (SELECT preview_fingerprint FROM pv) = (SELECT preview_fingerprint FROM cng_6c_unit_attribute_preview('6c300000-0000-0000-0000-000000000001')));

-- ---------------------------------------------------------------- security
SELECT pg_temp.ck('6C-13 no browser role can execute any 6c function',
  NOT EXISTS (SELECT 1 FROM pg_proc p, unnest(ARRAY['anon','authenticated']) r
               WHERE p.proname LIKE 'cng_6c_%' AND has_function_privilege(r, p.oid, 'EXECUTE')));
SELECT pg_temp.ck('6C-14 commit is SECURITY DEFINER with pinned search_path; read paths are not definer',
  (SELECT bool_and(CASE WHEN proname LIKE '%commit' THEN prosecdef ELSE NOT prosecdef END
                   AND proconfig::text LIKE '%search_path%') FROM pg_proc WHERE proname LIKE 'cng_6c_%'));
SELECT pg_temp.ck('6C-15 no dynamic SQL and no DELETE in the commit',
  (SELECT prosrc !~* '(\mexecute\M\s|\mdelete\M)' FROM pg_proc WHERE proname = 'cng_6c_unit_attribute_commit'));

-- ---------------------------------------------------------------- refusals write nothing
SELECT pg_temp.ck('6C-16 NULL fingerprint refused (22023)',
  pg_temp.sqlstate($q$SELECT cng_6c_unit_attribute_commit('6c300000-0000-0000-0000-000000000001', NULL, 'x')$q$) = '22023');
SELECT pg_temp.ck('6C-17 stale fingerprint refused (22023)',
  pg_temp.sqlstate($q$SELECT cng_6c_unit_attribute_commit('6c300000-0000-0000-0000-000000000001', repeat('0',64), 'x')$q$) = '22023');
SELECT pg_temp.ck('6C-18 refusals changed no Unit and no staging row',
  (SELECT count(*) FROM units WHERE id::text LIKE '6c2%' AND bay_status_raw IS NOT NULL) = 1
  AND (SELECT count(*) FROM import_staging_rows WHERE import_run_id = '6c300000-0000-0000-0000-000000000001'
         AND (committed_entity_id IS NOT NULL OR outcome = 'rejected')) = 0);

-- ---------------------------------------------------------------- drift lapses the approval
UPDATE import_staging_rows SET source_row_hash = encode(sha256('changed'::bytea), 'hex')
 WHERE id = '6c400000-0000-0000-0000-000000000001';
SELECT pg_temp.ck('6C-19 changed evidence changes the fingerprint',
  (SELECT preview_fingerprint FROM cng_6c_unit_attribute_preview('6c300000-0000-0000-0000-000000000001'))
  <> (SELECT preview_fingerprint FROM pv));
UPDATE import_staging_rows SET source_row_hash = encode(sha256(convert_to('6crow1', 'UTF8')), 'hex')
 WHERE id = '6c400000-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------- commit
CREATE TEMP TABLE cr AS
SELECT * FROM cng_6c_unit_attribute_commit('6c300000-0000-0000-0000-000000000001',
  (SELECT preview_fingerprint FROM pv), 'TESTDATA 6c');
SELECT pg_temp.ck('6C-20 commit returns 3 Units, 3 rows linked, 2 blank rows rejected',
  (SELECT (units_updated, rows_linked, blank_rows_rejected) = (3, 3, 2) FROM cr));
SELECT pg_temp.ck('6C-21 values written exactly as proposed',
  (SELECT (dispenser_count_reported, hose_count_reported, storage_count_reported, bay_status::text, bay_status_raw)
          = (3, 6, 4, 'open', 'Open Area') FROM units WHERE id = '6c200000-0000-0000-0000-000000000001')
  AND (SELECT (dispenser_count_reported IS NULL, dispenser_count_raw) = (true, '2 / 4')
         FROM units WHERE id = '6c200000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('6C-22 held Units untouched (S1 address Unit, FULL Unit, West namesake)',
  (SELECT count(*) FROM units WHERE id IN ('6c200000-0000-0000-0000-000000000004','6c200000-0000-0000-0000-000000000006')
     AND (bay_status_raw IS NOT NULL OR dispenser_count_raw IS NOT NULL)) = 0
  AND (SELECT (bay_status_raw, dispenser_count_raw IS NULL) = ('OPEN', true) FROM units WHERE id = '6c200000-0000-0000-0000-000000000005'));
SELECT pg_temp.ck('6C-23 lineage: 3 rows point at their Unit with kind unit and one timestamp',
  (SELECT count(*) FROM import_staging_rows s JOIN pr ON pr.staging_row_id = s.id
    WHERE s.committed_entity_id = pr.unit_id AND s.committed_entity_kind = 'unit') = 3
  AND (SELECT count(DISTINCT committed_at) FROM import_staging_rows WHERE import_run_id = '6c300000-0000-0000-0000-000000000001' AND committed_at IS NOT NULL) = 1);
SELECT pg_temp.ck('6C-24 blank rows are rejected with a reason, never deleted, source_raw intact',
  (SELECT count(*) FROM import_staging_rows WHERE source_row IN (7, 8) AND import_run_id = '6c300000-0000-0000-0000-000000000001'
     AND outcome = 'rejected' AND resolution ? 'rejected' AND source_raw ? 'Name') = 2);
SELECT pg_temp.ck('6C-25 held rows stay staged and unlinked',
  (SELECT count(*) FROM import_staging_rows WHERE import_run_id = '6c300000-0000-0000-0000-000000000001'
     AND source_row IN (4, 5, 6, 9) AND committed_entity_id IS NULL AND outcome = 'ready_unresolved') = 4);
SELECT pg_temp.ck('6C-26 one audit row, service_role label, no forged actor',
  (SELECT count(*) FROM audit_logs WHERE actor_label = 'service_role:unit_attributes_6c'
     AND entity_id = '6c300000-0000-0000-0000-000000000001' AND actor_id IS NULL) = 1);
SELECT pg_temp.ck('6C-27 no Station, Unit or alias was created',
  (SELECT count(*) FROM stations WHERE station_name LIKE 'T6C%') = 5 AND (SELECT count(*) FROM units WHERE unit_name LIKE 'T6C%') = 6);

-- ---------------------------------------------------------------- replay
SELECT pg_temp.ck('6C-28 after commit nothing is left to attach', (SELECT rows_to_attach FROM cng_6c_unit_attribute_preview('6c300000-0000-0000-0000-000000000001')) = 0);
SELECT pg_temp.ck('6C-29 replaying the approved fingerprint is refused',
  pg_temp.sqlstate(format($q$SELECT cng_6c_unit_attribute_commit('6c300000-0000-0000-0000-000000000001', %L, 'x')$q$,
                   (SELECT preview_fingerprint FROM pv))) = '22023');

ROLLBACK;
