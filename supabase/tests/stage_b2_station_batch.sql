-- stage_b2_station_batch.sql — regression suite for 20260923150000_stage_b2_station_batch.sql
-- Self-contained fixture; everything is rolled back.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- Become an authenticated caller with the given subject (NULL = no subject).
CREATE FUNCTION pg_temp.become(p_sub text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    CASE WHEN p_sub IS NULL THEN '{"role":"authenticated"}'
         ELSE json_build_object('sub', p_sub, 'role', 'authenticated')::text END, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;

-- SQLSTATE of a statement run as p_sub, or 'OK'. Always resets the role.
CREATE FUNCTION pg_temp.try_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM pg_temp.become(p_sub);
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;

-- ---------------------------------------------------------------- fixture
INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('b2000000-0000-0000-0000-00000000000a','b2_admin',   'admin',   true,  'TESTDATA B2 Admin'),
  ('b2000000-0000-0000-0000-00000000000b','b2_manager', 'manager', true,  'TESTDATA B2 Manager'),
  ('b2000000-0000-0000-0000-00000000000c','b2_eng',     'engineer',true,  'TESTDATA B2 Engineer'),
  ('b2000000-0000-0000-0000-00000000000f','b2_off',     'admin',   false, 'TESTDATA B2 Inactive Admin');
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT 'b2000000-0000-0000-0000-00000000000c'::uuid, id, true FROM regions WHERE name = 'East';

-- Two East Stations: ONE-UNIT (the forbidden-inference shape) and TWO-UNIT.
-- One West Station sharing the ONE-UNIT name, to prove Region is identity.
INSERT INTO stations (id, region_id, station_name)
SELECT 'b2100000-0000-0000-0000-000000000001'::uuid, id, 'TESTB2 ONE' FROM regions WHERE name = 'East'
UNION ALL SELECT 'b2100000-0000-0000-0000-000000000002'::uuid, id, 'TESTB2 TWO' FROM regions WHERE name = 'East'
UNION ALL SELECT 'b2100000-0000-0000-0000-000000000003'::uuid, id, 'TESTB2 WESTONLY' FROM regions WHERE name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT 'b2200000-0000-0000-0000-000000000001'::uuid, 'b2100000-0000-0000-0000-000000000001'::uuid, id, 'TESTB2 ONE' FROM regions WHERE name = 'East'
UNION ALL SELECT 'b2200000-0000-0000-0000-000000000002'::uuid, 'b2100000-0000-0000-0000-000000000002'::uuid, id, 'TESTB2 TWO 1' FROM regions WHERE name = 'East'
UNION ALL SELECT 'b2200000-0000-0000-0000-000000000003'::uuid, 'b2100000-0000-0000-0000-000000000002'::uuid, id, 'TESTB2 TWO 2' FROM regions WHERE name = 'East';

INSERT INTO import_runs (id, mode, label, completed_at, summary)
VALUES ('b2300000-0000-0000-0000-000000000001', 'dry_run', 'TESTDATA-B2', now(),
        '{"manifest_fingerprint":"b2manifest"}');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('b2300000-0000-0000-0000-000000000002', 'TESTB2.xlsx', 'Sheet1', 'dry_run',
        'b2300000-0000-0000-0000-000000000001');

-- Staged rows. `hex` gives a 64-char hash; synthetic dry-run ids are 32-hex.
CREATE TEMP TABLE fx (n int, tbl text, status text, outcome text, region text, raw text, extra jsonb);
INSERT INTO fx VALUES
  (1, 'storage_vessels', 'resolved',              'ready',            'East', 'TESTB2 ONE',      '{}'),
  (2, 'recovery_tanks',  'resolved',              'ready',            'East', 'testb2  one',     '{}'),
  (3, 'hoses',           'resolved',              'ready',            'East', 'TESTB2 ONE',      '{}'),
  (4, 'storage_vessels', 'needs_unit_mapping',    'ready_unresolved', 'East', 'TESTB2 TWO',      '{}'),
  (5, 'gas_detectors',   'resolved',              'ready',            'East', 'TESTB2 ONE',      '{"creates_detector_record":"false","presence":"not_installed"}'),
  (6, 'gas_detectors',   'resolved',              'ready',            'East', 'TESTB2 ONE',      '{"creates_detector_record":"true","presence":"installed"}'),
  -- NOT candidates:
  (7, 'storage_vessels', 'needs_station_mapping', 'ready_unresolved', 'East', 'TESTB2 ONE',      '{}'),  -- Stage B's set, not B2's
  (8, 'storage_vessels', 'resolved',              'ready',            'East', 'TESTB2 WESTONLY', '{}'),  -- other Region only
  (9, 'storage_vessels', 'resolved',              'ready',            'East', 'TESTB2 NOWHERE',  '{}'),  -- no Station
  (10,'storage_vessels', 'resolved',              'rejected',         'East', 'TESTB2 ONE',      '{}');  -- rejected outcome
INSERT INTO import_staging_rows (
  id, import_run_id, import_batch_id, source_file, source_sheet, source_row,
  source_raw, source_row_key, source_row_hash, target_table, outcome, mapping_status, normalized, resolution)
SELECT ('b2400000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'b2300000-0000-0000-0000-000000000001', 'b2300000-0000-0000-0000-000000000002',
       'TESTB2.xlsx', 'Sheet1', n, jsonb_build_object('Station', raw),
       'TESTB2.xlsx::Sheet1::' || n, encode(sha256(convert_to('b2row' || n, 'UTF8')), 'hex'),
       tbl, outcome::staging_outcome, status,
       jsonb_build_object('region', region, 'source_station_name_raw', raw,
                          'station_id', md5('st' || n), 'unit_id', md5('un' || n)) || extra,
       '{"station":{"kind":"exact_canonical"}}'
  FROM fx;

-- ---------------------------------------------------------------- 1. catalog
SELECT pg_temp.ck('B2-1  four functions exist; the commit alone is SECURITY DEFINER; reads are STABLE invoker',
  (SELECT count(*) = 4
          AND bool_and(prosecdef = (proname = 'cng_stage_b2_station_commit'))
          AND bool_and(proname = 'cng_stage_b2_station_commit' OR provolatile = 's')
     FROM pg_proc WHERE proname LIKE 'cng_stage_b2_station_%'));
SELECT pg_temp.ck('B2-2  search_path pinned on all four; EXECUTE authenticated, never anon or PUBLIC',
  (SELECT bool_and(proconfig @> ARRAY['search_path=pg_catalog, public'])
          AND bool_and(has_function_privilege('authenticated', oid, 'EXECUTE'))
          AND NOT bool_or(has_function_privilege('anon', oid, 'EXECUTE'))
     FROM pg_proc WHERE proname LIKE 'cng_stage_b2_station_%'));
SELECT pg_temp.ck('B2-3  no dynamic SQL, no actor parameter, and exactly two literal INSERT targets in the commit',
  (SELECT prosrc !~* '\mEXECUTE\M' AND prosrc !~* 'quote_ident'
          AND pg_get_function_arguments(oid) !~* 'actor|decided_by|user'
          AND (SELECT count(*) FROM regexp_matches(prosrc, 'INSERT INTO (\w+)', 'g')) = 2
          AND prosrc ~ 'INSERT INTO import_mapping_decisions' AND prosrc ~ 'INSERT INTO audit_logs'
     FROM pg_proc WHERE proname = 'cng_stage_b2_station_commit'));
SELECT pg_temp.ck('B2-4  the approved Stage B functions are untouched by this migration (still filter needs_station_mapping only)',
  (SELECT prosrc ~ $re$mapping_status = 'needs_station_mapping'$re$ FROM pg_proc WHERE proname = 'cng_stage_b_station_candidates'));

-- ---------------------------------------------------------------- 2. candidate set
CREATE TEMP TABLE c AS SELECT * FROM cng_stage_b2_station_candidates('b2300000-0000-0000-0000-000000000001');
SELECT pg_temp.ck('B2-5  exactly the six intended rows are candidates (resolved + needs_unit_mapping, one same-Region Station)',
  (SELECT array_agg(right(staging_row_id::text, 1) ORDER BY staging_row_id) = '{1,2,3,4,5,6}' FROM c));
SELECT pg_temp.ck('B2-6  normalization matches a differently spaced/cased spelling to the same Station (row 2)',
  (SELECT station_id = 'b2100000-0000-0000-0000-000000000001' FROM c WHERE right(staging_row_id::text,1) = '2'));
SELECT pg_temp.ck('B2-7  needs_station_mapping, other-Region-only, unmatched and rejected rows are excluded by construction',
  (SELECT count(*) = 0 FROM c WHERE right(staging_row_id::text, 2) IN ('07','08','09','10')));
SELECT pg_temp.ck('B2-8  every candidate targets a Station in its OWN Region',
  (SELECT bool_and(c.region_name = 'East') FROM c));

CREATE TEMP TABLE pv AS SELECT * FROM cng_stage_b2_station_preview('b2300000-0000-0000-0000-000000000001');
SELECT pg_temp.ck('B2-9  preview counts: 6 rows, 2 groups, 5 resolved + 1 needs_unit, 1 detector-absence row',
  (SELECT candidate_rows = 6 AND candidate_groups = 2 AND staged_resolved = 5 AND staged_needs_unit = 1
          AND detector_absence_rows = 1 AND rows_with_existing_decision = 0 AND owner_review_groups = 0 FROM pv));
SELECT pg_temp.ck('B2-10 preview is deterministic and differs from a Stage B fingerprint over the same data',
  (SELECT p.preview_fingerprint = (SELECT preview_fingerprint FROM cng_stage_b2_station_preview('b2300000-0000-0000-0000-000000000001'))
          AND p.preview_fingerprint <> (SELECT preview_fingerprint FROM cng_stage_b_station_preview('b2300000-0000-0000-0000-000000000001'))
          AND length(p.preview_fingerprint) = 64
     FROM pv p));

-- ---------------------------------------------------------------- 3. authorization (refused, nothing written)
SELECT pg_temp.ck(format('B2-%s  %s cannot commit the batch (%s)', 10 + n, who, st),
       pg_temp.try_as(sub, format($q$SELECT * FROM cng_stage_b2_station_commit(%L, 'b2manifest', %L, 'probe')$q$,
         'b2300000-0000-0000-0000-000000000001', (SELECT preview_fingerprint FROM pv))) = st)
  FROM (VALUES (1, 'manager', 'b2_manager', '42501'), (2, 'engineer', 'b2_eng', '42501'),
               (3, 'inactive admin', 'b2_off', '42501'), (4, 'no subject', NULL, '42501')) v(n, who, sub, st);
SELECT pg_temp.ck('B2-15 anon cannot execute the commit at all',
  NOT has_function_privilege('anon', 'cng_stage_b2_station_commit(uuid,text,text,text)', 'EXECUTE'));
SELECT pg_temp.ck('B2-16 admin with a stale preview fingerprint is refused (22023)',
  pg_temp.try_as('b2_admin', $q$SELECT * FROM cng_stage_b2_station_commit('b2300000-0000-0000-0000-000000000001', 'b2manifest', repeat('0',64), 'probe')$q$) = '22023');
SELECT pg_temp.ck('B2-17 admin with a wrong manifest is refused (22023)',
  pg_temp.try_as('b2_admin', format($q$SELECT * FROM cng_stage_b2_station_commit(%L, 'other', %L, 'probe')$q$,
    'b2300000-0000-0000-0000-000000000001', (SELECT preview_fingerprint FROM pv))) = '22023');
SELECT pg_temp.ck('B2-18 every refusal wrote nothing',
  (SELECT count(*) = 0 FROM import_mapping_decisions WHERE source_row_key LIKE 'TESTB2%'));

-- ---------------------------------------------------------------- 4. the authorized commit
SELECT pg_temp.ck('B2-19 the admin commit with both approved fingerprints succeeds',
  pg_temp.try_as('b2_admin', format($q$SELECT * FROM cng_stage_b2_station_commit(%L, 'b2manifest', %L, 'B2 test')$q$,
    'b2300000-0000-0000-0000-000000000001', (SELECT preview_fingerprint FROM pv))) = 'OK');
CREATE TEMP TABLE d AS SELECT * FROM import_mapping_decisions WHERE source_row_key LIKE 'TESTB2%';
SELECT pg_temp.ck('B2-20 exactly six decisions, one per candidate, all active',
  (SELECT count(*) = 6 AND bool_and(superseded_at IS NULL) FROM d));
SELECT pg_temp.ck('B2-21 NO Unit is written on any decision, including the rows the pipeline called resolved under a one-Unit Station',
  (SELECT bool_and(confirmed_unit_id IS NULL AND resulting_mapping_status = 'needs_unit_mapping') FROM d));
SELECT pg_temp.ck('B2-22 the staged status is preserved as previous_mapping_status and the discarded Unit is recorded as evidence',
  (SELECT count(*) FILTER (WHERE previous_mapping_status = 'resolved') = 5
          AND count(*) FILTER (WHERE previous_mapping_status = 'needs_unit_mapping') = 1
          AND bool_and(source_evidence ->> 'staged_unit_discarded' IS NOT NULL)
          AND bool_and(source_evidence -> 'batch' ->> 'stage' = 'B2-station') FROM d));
SELECT pg_temp.ck('B2-23 the Station and the reviewed hash are the server-read ones; the actor is the admin',
  (SELECT bool_and(d.confirmed_station_id = c.station_id AND d.reviewed_source_row_hash = r.source_row_hash
                   AND d.decided_by = 'b2000000-0000-0000-0000-00000000000a')
     FROM d JOIN c ON c.staging_row_id = d.staging_row_id JOIN import_staging_rows r ON r.id = d.staging_row_id));
SELECT pg_temp.ck('B2-24 one audit row per decision, attributed to the admin, with unit_id null',
  (SELECT count(*) = 6 AND bool_and(a.actor_id = 'b2000000-0000-0000-0000-00000000000a' AND a.after_data ->> 'unit_id' IS NULL)
     FROM audit_logs a JOIN d ON a.entity_id = d.id));
SELECT pg_temp.ck('B2-25 staging rows themselves are unchanged (status, hash, no canonical lineage)',
  (SELECT count(*) = 6 FROM import_staging_rows r JOIN d ON d.staging_row_id = r.id
    WHERE r.mapping_status IN ('resolved','needs_unit_mapping') AND r.committed_entity_id IS NULL));
SELECT pg_temp.ck('B2-26 nothing canonical was created by the decision batch',
  (SELECT count(*) = 0 FROM storage_vessels WHERE station_id IN ('b2100000-0000-0000-0000-000000000001','b2100000-0000-0000-0000-000000000002')));

-- ---------------------------------------------------------------- 5. replay
SELECT pg_temp.ck('B2-27 replay with the old fingerprint is refused, and the fingerprint has moved',
  pg_temp.try_as('b2_admin', format($q$SELECT * FROM cng_stage_b2_station_commit(%L, 'b2manifest', %L, 'again')$q$,
      'b2300000-0000-0000-0000-000000000001', (SELECT preview_fingerprint FROM pv))) = '22023'
  AND (SELECT preview_fingerprint FROM cng_stage_b2_station_preview('b2300000-0000-0000-0000-000000000001'))
      <> (SELECT preview_fingerprint FROM pv));
SELECT pg_temp.ck('B2-28 replay with the CURRENT fingerprint is still refused (rows already decided, 23505)',
  pg_temp.try_as('b2_admin', format($q$SELECT * FROM cng_stage_b2_station_commit(%L, 'b2manifest', %L, 'again')$q$,
      'b2300000-0000-0000-0000-000000000001',
      (SELECT preview_fingerprint FROM cng_stage_b2_station_preview('b2300000-0000-0000-0000-000000000001')))) = '23505'
  AND (SELECT count(*) = 6 FROM import_mapping_decisions WHERE source_row_key LIKE 'TESTB2%'));

-- ---------------------------------------------------------------- 6. hand-off to the existing asset import
CREATE TEMP TABLE ap AS SELECT * FROM cng_asset_import_proposal('b2300000-0000-0000-0000-000000000001');
SELECT pg_temp.ck('B2-29 the unchanged asset import sees 5 Station-only rows READY and the absence row BLOCKED',
  (SELECT count(*) FILTER (WHERE eligibility = 'B_READY_NULL_UNIT') = 5
          AND count(*) FILTER (WHERE eligibility = 'E_BLOCKED_BY_TARGET') = 1
          AND bool_and(station_id IS NOT NULL) FROM ap));
SELECT pg_temp.ck('B2-30 no asset-import payload carries a Unit (the staged synthetic unit_id is not propagated)',
  (SELECT bool_and(NOT (payload ? 'unit_id') OR payload ->> 'unit_id' IS NULL) FROM ap));

ROLLBACK;
