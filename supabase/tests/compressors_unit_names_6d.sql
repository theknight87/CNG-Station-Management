-- compressors_unit_names_6d.sql — regression suite for 20260923210000_compressors_and_unit_names_6d.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.sqlstate(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END; RETURN s; END $$;

-- Only this fixture's Units should be renamable: park any existing ones by giving the
-- suite its own Region-free view through names (production-equivalent base has none).
-- Stations: A one Unit "street address" -> rename to "T6D A"; B Units "T6D B","T6D B 2" -> "T6D B 1";
-- C Units "T6D C 1","T6D C 2" (already right); D Units "x","y" (ambiguous, reported, not renamed).
INSERT INTO stations (id, region_id, station_name)
SELECT ('6d100000-0000-0000-0000-00000000000' || n)::uuid, r.id, nm
  FROM (VALUES (1,'T6D A'),(2,'T6D B'),(3,'T6D C'),(4,'T6D D')) v(n,nm) JOIN regions r ON r.name = 'Delta';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT ('6d200000-0000-0000-0000-00000000000' || n)::uuid, ('6d100000-0000-0000-0000-00000000000' || s)::uuid, r.id, nm
  FROM (VALUES (1,1,'T6D street address'),(2,2,'T6D B'),(3,2,'T6D B 2'),(4,3,'T6D C 1'),(5,3,'T6D C 2'),(6,4,'T6D x'),(7,4,'T6D y')) v(n,s,nm)
  JOIN regions r ON r.name = 'Delta';

INSERT INTO import_runs (id, mode, label, completed_at, summary) VALUES ('6d300000-0000-0000-0000-000000000001','dry_run','TESTDATA-6D',now(),'{}');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('6d300000-0000-0000-0000-000000000002','Station data base.xlsx','Sheet1','dry_run','6d300000-0000-0000-0000-000000000001');
-- Linked rows (as 6c left them) for Units 1, 2, 4; row for Unit 5 has no compressor evidence.
CREATE TEMP TABLE fx (n int, unit int, model text, hours text, avg text, sales text);
INSERT INTO fx VALUES (1,1,'GALLILEO','1694','3',NULL),(2,2,'Safe','12.5','x','2 / 3'),(3,4,'  kir ',NULL,NULL,'150'),(4,5,NULL,NULL,NULL,NULL);
INSERT INTO import_staging_rows (id, import_run_id, import_batch_id, source_file, source_sheet, source_row, source_raw,
  source_row_key, source_row_hash, target_table, outcome, mapping_status, normalized, committed_entity_id, committed_entity_kind, committed_at)
SELECT ('6d400000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid, '6d300000-0000-0000-0000-000000000001','6d300000-0000-0000-0000-000000000002',
       'Station data base.xlsx','Sheet1', n, jsonb_build_object('Compressor Model', model), 'SDB6D::' || n,
       encode(sha256(convert_to('6drow' || n,'UTF8')),'hex'), 'unit_attributes','ready_unresolved','needs_station_mapping',
       jsonb_strip_nulls(jsonb_build_object('region','Delta','source_name_raw','x','compressor_model',model,
         'total_running_hours',hours,'avg_hours_per_day',avg,'avg_gas_sales_per_day_raw',sales)),
       ('6d200000-0000-0000-0000-00000000000' || unit)::uuid, 'unit', now()
  FROM fx;

-- ------------------------------------------------------------------ 6d
CREATE TEMP TABLE dp AS SELECT * FROM cng_6d_compressor_proposal('6d300000-0000-0000-0000-000000000001');
CREATE TEMP TABLE dv AS SELECT * FROM cng_6d_compressor_preview('6d300000-0000-0000-0000-000000000001');
SELECT pg_temp.ck('6D-1 one compressor per linked Unit with evidence (3), none for the row without', (SELECT count(*) FROM dp) = 3
  AND NOT EXISTS (SELECT 1 FROM dp WHERE unit_id = '6d200000-0000-0000-0000-000000000005'));
SELECT pg_temp.ck('6D-2 model kept as written (GALLILEO not corrected), only trimmed',
  (SELECT array_agg(model ORDER BY model) FROM dp) = ARRAY['GALLILEO','Safe','kir']);
SELECT pg_temp.ck('6D-3 numbers only from plain numeric cells; raw sales text kept',
  EXISTS (SELECT 1 FROM dp WHERE model = 'Safe' AND total_running_hours = 12.5 AND average_hours_per_day IS NULL
            AND average_gas_sales_per_day IS NULL AND average_gas_sales_raw = '2 / 3')
  AND EXISTS (SELECT 1 FROM dp WHERE model = 'kir' AND average_gas_sales_per_day = 150));
SELECT pg_temp.ck('6D-4 no browser role can execute 6d/6e functions',
  NOT EXISTS (SELECT 1 FROM pg_proc p, unnest(ARRAY['anon','authenticated']) r
               WHERE p.proname ~ '^cng_6[de]_' AND has_function_privilege(r, p.oid, 'EXECUTE')));
SELECT pg_temp.ck('6D-5 stale fingerprint refused, nothing created',
  pg_temp.sqlstate($q$SELECT cng_6d_compressor_commit('6d300000-0000-0000-0000-000000000001', repeat('0',64), 'x')$q$) = '22023'
  AND (SELECT count(*) FROM compressors WHERE unit_id::text LIKE '6d2%') = 0);
CREATE TEMP TABLE dc AS SELECT * FROM cng_6d_compressor_commit('6d300000-0000-0000-0000-000000000001', (SELECT preview_fingerprint FROM dv), 'T');
SELECT pg_temp.ck('6D-6 3 compressors created, resolved, on the right Unit/Station/Region, with provenance',
  (SELECT compressors_created FROM dc) = 3
  AND (SELECT count(*) FROM compressors c JOIN units u ON u.id = c.unit_id
        WHERE c.unit_id::text LIKE '6d2%' AND c.mapping_status = 'resolved' AND c.station_id = u.station_id
          AND c.region_id = u.region_id AND c.model_raw = c.model AND c.source_file = 'Station data base.xlsx') = 3);
SELECT pg_temp.ck('6D-7 no serial, manufacturer or job number invented',
  (SELECT count(*) FROM compressors WHERE unit_id::text LIKE '6d2%'
     AND (serial_number IS NOT NULL OR manufacturer IS NOT NULL OR job_number IS NOT NULL)) = 0);
SELECT pg_temp.ck('6D-8 replay: nothing left and approved fingerprint refused',
  (SELECT compressors_to_create FROM cng_6d_compressor_preview('6d300000-0000-0000-0000-000000000001')) = 0
  AND pg_temp.sqlstate(format($q$SELECT cng_6d_compressor_commit('6d300000-0000-0000-0000-000000000001', %L, 'x')$q$,
                       (SELECT preview_fingerprint FROM dv))) = '22023');
SELECT pg_temp.ck('6D-9 one audit row', (SELECT count(*) FROM audit_logs WHERE actor_label = 'service_role:compressors_6d'
  AND entity_id = '6d300000-0000-0000-0000-000000000001' AND actor_id IS NULL) = 1);

-- ------------------------------------------------------------------ 6e
CREATE TEMP TABLE ep AS SELECT * FROM cng_6e_unit_name_proposal() WHERE station_name LIKE 'T6D%';
SELECT pg_temp.ck('6E-1 one-Unit Station: address-named Unit -> Station name',
  EXISTS (SELECT 1 FROM ep WHERE unit_id = '6d200000-0000-0000-0000-000000000001' AND new_name = 'T6D A' AND rule = 'one_unit'));
SELECT pg_temp.ck('6E-2 "X" beside "X 2" -> "X 1"',
  EXISTS (SELECT 1 FROM ep WHERE unit_id = '6d200000-0000-0000-0000-000000000002' AND new_name = 'T6D B 1'));
SELECT pg_temp.ck('6E-3 correct names and ambiguous Stations are not renamed',
  (SELECT count(*) FROM ep) = 2);
SELECT pg_temp.ck('6E-4 ambiguous Station is counted as not following the rule',
  (SELECT stations_not_following_rule_left FROM cng_6e_unit_name_preview()) >= 1);
SELECT pg_temp.ck('6E-5 stale fingerprint refused',
  pg_temp.sqlstate($q$SELECT cng_6e_unit_name_commit(repeat('0',64), 'x')$q$) = '22023');
CREATE TEMP TABLE ec AS SELECT * FROM cng_6e_unit_name_commit((SELECT preview_fingerprint FROM cng_6e_unit_name_preview()), 'T');
SELECT pg_temp.ck('6E-6 renamed; normalized_name follows; ids unchanged',
  (SELECT unit_name FROM units WHERE id = '6d200000-0000-0000-0000-000000000001') = 'T6D A'
  AND (SELECT normalized_name FROM units WHERE id = '6d200000-0000-0000-0000-000000000002') = cng_normalize_name('T6D B 1'));
SELECT pg_temp.ck('6E-7 compressors still attached to the renamed Units',
  (SELECT count(*) FROM compressors WHERE unit_id IN ('6d200000-0000-0000-0000-000000000001','6d200000-0000-0000-0000-000000000002')) = 2);
SELECT pg_temp.ck('6E-8 one audit row per rename with the old and new name',
  (SELECT count(*) FROM audit_logs WHERE actor_label = 'service_role:unit_names_6e' AND entity_id = '6d200000-0000-0000-0000-000000000001'
     AND before_data->>'unit_name' = 'T6D street address' AND after_data->>'unit_name' = 'T6D A') = 1);
SELECT pg_temp.ck('6E-9 ambiguous Units untouched',
  (SELECT array_agg(unit_name ORDER BY unit_name) FROM units WHERE station_id = '6d100000-0000-0000-0000-000000000004') = ARRAY['T6D x','T6D y']);
SELECT pg_temp.ck('6E-10 replay: nothing left in the fixture',
  NOT EXISTS (SELECT 1 FROM cng_6e_unit_name_proposal() WHERE station_name LIKE 'T6D%'));

ROLLBACK;
