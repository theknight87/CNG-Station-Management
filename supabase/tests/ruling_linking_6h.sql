-- ruling_linking_6h.sql — regression suite for 20260924120000_ruling_linking_6h.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- Hierarchy: Canal Station TH ONE with Units "TH ONE 1" and "TH ONE 2"; Canal Station TH TWO (no Unit).
INSERT INTO stations (id, region_id, station_name) SELECT '6a100000-0000-0000-0000-000000000001', id, 'TH ONE' FROM regions WHERE name = 'Canal';
INSERT INTO stations (id, region_id, station_name) SELECT '6a100000-0000-0000-0000-000000000002', id, 'TH TWO' FROM regions WHERE name = 'Canal';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT ('6a200000-0000-0000-0000-00000000000' || n)::uuid, '6a100000-0000-0000-0000-000000000001', r.id, 'TH ONE ' || n
  FROM generate_series(1, 2) n, regions r WHERE r.name = 'Canal';

-- Rulings: "TH ONE 1" -> Unit 1; "TH-ONE" (other spelling "TH ONE X") -> Station only; "TH TWO" -> Station;
-- "TH SPLIT" ruled to two different Stations -> not a target; "TH GHOST 9" names a Unit that does not exist -> not a target.
INSERT INTO owner_station_rulings (ruling_set, region_id, source_name_raw, other_spelling_raw, station_name, unit_name, evidence)
SELECT 'T6H', r.id, v.src, v.oth, v.st, v.un, 'test'
  FROM (VALUES ('TH ONE 1', NULL, 'TH ONE', 'TH ONE 1'),
               ('TH-ONE', 'TH ONE X', 'TH ONE', NULL),
               ('TH TWO', NULL, 'TH TWO', NULL),
               ('TH SPLIT', NULL, 'TH ONE', NULL),
               ('TH GHOST 9', NULL, 'TH ONE', 'TH ONE 9')) v(src, oth, st, un)
  JOIN regions r ON r.name = 'Canal';
INSERT INTO owner_station_rulings (ruling_set, region_id, source_name_raw, station_name, evidence)
SELECT 'T6H-B', id, 'TH SPLIT', 'TH TWO', 'test' FROM regions WHERE name = 'Canal';

INSERT INTO import_runs (id, mode, label, completed_at, summary)
VALUES ('6a300000-0000-0000-0000-000000000001', 'dry_run', 'TESTDATA-6H', now(), '{}');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('6a300000-0000-0000-0000-000000000002', 'T6H.xlsx', 'Sheet1', 'dry_run', '6a300000-0000-0000-0000-000000000001');

-- Staged rows: n=1 vessel "TH ONE 1" (Unit), 2 tank "TH ONE X" (Station only), 3 detector ABSENCE "TH TWO",
-- 4 hose "TH TWO", 5 vessel "TH SPLIT" (ambiguous), 6 vessel "TH GHOST 9", 7 vessel "TH ONE 1" but in Alex (other Region),
-- 8 vessel "TH TWO" that already has a Station decision (untouched).
INSERT INTO import_staging_rows (id, import_run_id, import_batch_id, source_file, source_sheet, source_row, source_raw,
                                 source_row_key, source_row_hash, target_table, outcome, mapping_status, normalized)
SELECT ('6a400000-0000-0000-0000-00000000000' || v.n)::uuid, '6a300000-0000-0000-0000-000000000001', '6a300000-0000-0000-0000-000000000002',
       'T6H.xlsx', 'Sheet1', v.n, '{}'::jsonb, 'T6H.xlsx|Sheet1|' || v.n, encode(sha256(convert_to('6h' || v.n, 'UTF8')), 'hex'),
       v.tt, 'ready_unresolved', 'needs_station_mapping',
       jsonb_build_object('region', v.reg, 'source_station_name_raw', v.nm, 'serial_number', 'TH-S' || v.n,
                          'creates_detector_record', v.cdr,
                          'next_due_date', jsonb_build_object('precision', 'exact_date', 'value', '2027-01-01', 'raw', '1/1/2027'))
  FROM (VALUES (1, 'storage_vessels', 'Canal', 'TH ONE 1', 'true'), (2, 'recovery_tanks', 'Canal', 'TH ONE X', 'true'),
               (3, 'gas_detectors', 'Canal', 'TH TWO', 'false'), (4, 'hoses', 'Canal', 'TH TWO', 'true'),
               (5, 'storage_vessels', 'Canal', 'TH SPLIT', 'true'), (6, 'storage_vessels', 'Canal', 'TH GHOST 9', 'true'),
               (7, 'storage_vessels', 'Alex', 'TH ONE 1', 'true'), (8, 'storage_vessels', 'Canal', 'TH TWO', 'true')) v(n, tt, reg, nm, cdr);

-- Installed SRVs: one "TH ONE 1" (Unit), one "TH-ONE" (Station only), one "TH SPLIT" (ambiguous).
INSERT INTO installed_relief_valves (id, region_id, mapping_status, source_station_name_raw, serial_number)
SELECT ('6a500000-0000-0000-0000-00000000000' || v.n)::uuid, r.id, 'needs_station_mapping', v.nm, 'TH-V' || v.n
  FROM (VALUES (1, 'TH ONE 1'), (2, 'TH-ONE'), (3, 'TH SPLIT')) v(n, nm) JOIN regions r ON r.name = 'Canal';

CREATE TEMP TABLE a AS SELECT * FROM cng_6h_asset_proposal() WHERE staging_row_id::text LIKE '6a4%';
CREATE TEMP TABLE s AS SELECT * FROM cng_6h_srv_proposal() WHERE installed_valve_id::text LIKE '6a5%';

SELECT pg_temp.ck('LINK-1 a name the ruling gives a Unit -> Station and Unit',
  (SELECT (station_id, unit_id) = ('6a100000-0000-0000-0000-000000000001'::uuid, '6a200000-0000-0000-0000-000000000001'::uuid)
     FROM a WHERE staging_row_id = '6a400000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('LINK-2 the ruling''s OTHER spelling also matches; no Unit when the ruling names none',
  (SELECT station_id = '6a100000-0000-0000-0000-000000000001' AND unit_id IS NULL FROM a WHERE staging_row_id = '6a400000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('LINK-3 detector absence is proposed but never READY',
  (SELECT eligibility FROM a WHERE staging_row_id = '6a400000-0000-0000-0000-000000000003') = 'E_ABSENCE_NOT_A_DEVICE');
SELECT pg_temp.ck('LINK-4 a name ruled to two Stations is not linked',
  NOT EXISTS (SELECT 1 FROM a WHERE staging_row_id = '6a400000-0000-0000-0000-000000000005')
  AND NOT EXISTS (SELECT 1 FROM s WHERE installed_valve_id = '6a500000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('LINK-5 a ruled Unit that does not exist is not linked (no Unit is invented)',
  NOT EXISTS (SELECT 1 FROM a WHERE staging_row_id = '6a400000-0000-0000-0000-000000000006'));
SELECT pg_temp.ck('LINK-6 Region is identity: the same name in another Region is not linked',
  NOT EXISTS (SELECT 1 FROM a WHERE staging_row_id = '6a400000-0000-0000-0000-000000000007'));

-- Row 8 already carries an active Station decision: create it via the existing path's table directly.
INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES ('6a000000-0000-0000-0000-00000000000a', 'th_admin', 'admin', true, 'TESTDATA TH');
INSERT INTO import_mapping_decisions (staging_row_id, source_row_key, reviewed_source_row_hash, target_table, asset_type, region_id,
  confirmed_station_id, previous_mapping_status, resulting_mapping_status, decided_by, source_evidence)
SELECT r.id, r.source_row_key, r.source_row_hash, r.target_table, 'storage_vessel', s.region_id, s.id, 'needs_station_mapping', 'needs_unit_mapping',
       '6a000000-0000-0000-0000-00000000000a', '{}'::jsonb
  FROM import_staging_rows r, stations s WHERE r.id = '6a400000-0000-0000-0000-000000000008' AND s.id = '6a100000-0000-0000-0000-000000000002';
SELECT pg_temp.ck('LINK-7 a row that already has a Station decision is left to that path',
  NOT EXISTS (SELECT 1 FROM cng_6h_asset_proposal() WHERE staging_row_id = '6a400000-0000-0000-0000-000000000008'));

SELECT pg_temp.ck('LINK-8 SRVs: Unit when ruled, Station only otherwise',
  (SELECT unit_id FROM s WHERE installed_valve_id = '6a500000-0000-0000-0000-000000000001') = '6a200000-0000-0000-0000-000000000001'
  AND (SELECT unit_id IS NULL AND station_id = '6a100000-0000-0000-0000-000000000001' FROM s WHERE installed_valve_id = '6a500000-0000-0000-0000-000000000002'));

SELECT preview_fingerprint AS fp FROM cng_6h_preview() \gset
SELECT pg_temp.ck('LINK-9 preview deterministic', (SELECT preview_fingerprint FROM cng_6h_preview()) = :'fp');
SELECT pg_temp.ck('LINK-10 service_role only', NOT has_function_privilege('authenticated', 'cng_6h_commit(text, text)', 'EXECUTE'));
DO $$ BEGIN
  PERFORM cng_6h_commit('wrong', 'test');
  RAISE NOTICE 'FAILED: LINK-11 a wrong fingerprint was accepted';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  LINK-11 a wrong fingerprint is refused';
END $$;

SELECT assets_created, rows_linked, srvs_linked FROM cng_6h_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('LINK-12 commit wrote what was previewed (assets = linked rows)', :assets_created = :rows_linked AND :srvs_linked >= 2);
SELECT pg_temp.ck('LINK-13 the Unit-named vessel is resolved under its Unit; the other is needs_unit_mapping',
  (SELECT (unit_id, mapping_status::text) = ('6a200000-0000-0000-0000-000000000001'::uuid, 'resolved') FROM storage_vessels WHERE serial_number = 'TH-S1')
  AND (SELECT unit_id IS NULL AND mapping_status = 'needs_unit_mapping' FROM recovery_tanks WHERE serial_number = 'TH-S2'));
SELECT pg_temp.ck('LINK-14 no device from recorded absence',
  NOT EXISTS (SELECT 1 FROM gas_detectors WHERE serial_number = 'TH-S3')
  AND (SELECT committed_entity_id IS NULL FROM import_staging_rows WHERE id = '6a400000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('LINK-15 lineage points each staged row at its asset',
  (SELECT committed_entity_id = (SELECT id FROM storage_vessels WHERE serial_number = 'TH-S1') AND committed_entity_kind = 'storage_vessel'
     FROM import_staging_rows WHERE id = '6a400000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('LINK-16 SRVs linked with the right status; the ambiguous one untouched',
  (SELECT mapping_status::text FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000001') = 'needs_equipment_mapping'
  AND (SELECT mapping_status::text FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000002') = 'needs_unit_mapping'
  AND (SELECT station_id IS NULL FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('LINK-17 no equipment parent is ever set',
  (SELECT num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000001') = 0);
SELECT pg_temp.ck('LINK-18 one audit row listing the linked ids',
  (SELECT count(*) FROM audit_logs WHERE actor_label = 'service_role:ruling_linking_6h'
     AND after_data->'installed_valve_ids' ? '6a500000-0000-0000-0000-000000000001') = 1);
SELECT pg_temp.ck('LINK-19 replay: nothing left to link',
  NOT EXISTS (SELECT 1 FROM cng_6h_asset_proposal() WHERE staging_row_id::text LIKE '6a4%' AND eligibility = 'READY')
  AND NOT EXISTS (SELECT 1 FROM cng_6h_srv_proposal() WHERE installed_valve_id::text LIKE '6a5%'));

ROLLBACK;
