-- ruling_target_region_6i.sql — regression suite for 20260924140000_ruling_target_region_6i.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- East Station TI SITE; the source recorded its records under Delta.
INSERT INTO stations (id, region_id, station_name) SELECT '6b100000-0000-0000-0000-000000000001', id, 'TI SITE' FROM regions WHERE name = 'East';
INSERT INTO owner_station_rulings (ruling_set, region_id, target_region_id, source_name_raw, station_name, evidence)
SELECT 'T6I', d.id, e.id, 'TI SITE', 'TI SITE', 'test' FROM regions d, regions e WHERE d.name = 'Delta' AND e.name = 'East';
-- The same spelling ruled WITHOUT a target Region in West must not reach the East Station.
INSERT INTO owner_station_rulings (ruling_set, region_id, source_name_raw, station_name, evidence)
SELECT 'T6I', id, 'TI SITE', 'TI SITE', 'test' FROM regions WHERE name = 'West';

INSERT INTO import_runs (id, mode, label, completed_at, summary) VALUES ('6b300000-0000-0000-0000-000000000001', 'dry_run', 'TESTDATA-6I', now(), '{}');
INSERT INTO import_batches (id, source_file, source_sheet, status, import_run_id)
VALUES ('6b300000-0000-0000-0000-000000000002', 'T6I.xlsx', 'Sheet1', 'dry_run', '6b300000-0000-0000-0000-000000000001');
INSERT INTO import_staging_rows (id, import_run_id, import_batch_id, source_file, source_sheet, source_row, source_raw,
                                 source_row_key, source_row_hash, target_table, outcome, mapping_status, normalized)
SELECT '6b400000-0000-0000-0000-000000000001', '6b300000-0000-0000-0000-000000000001', '6b300000-0000-0000-0000-000000000002',
       'T6I.xlsx', 'Sheet1', 1, '{}'::jsonb, 'T6I.xlsx|Sheet1|1', encode(sha256('6i1'::bytea), 'hex'), 'recovery_tanks',
       'ready_unresolved', 'needs_station_mapping', jsonb_build_object('region', 'Delta', 'source_station_name_raw', 'TI SITE', 'serial_number', 'TI-S1');
INSERT INTO installed_relief_valves (id, region_id, mapping_status, source_station_name_raw, source_region_raw, serial_number)
SELECT '6b500000-0000-0000-0000-000000000001', id, 'needs_station_mapping', 'TI SITE', 'Delta', 'TI-V1' FROM regions WHERE name = 'Delta';
INSERT INTO installed_relief_valves (id, region_id, mapping_status, source_station_name_raw, serial_number)
SELECT '6b500000-0000-0000-0000-000000000002', id, 'needs_station_mapping', 'TI SITE', 'TI-V2' FROM regions WHERE name = 'West';

SELECT pg_temp.ck('XREG-1 a Delta-recorded asset is proposed for the East Station, with the East Region',
  (SELECT (station_id, region_id) = ('6b100000-0000-0000-0000-000000000001'::uuid, (SELECT id FROM regions WHERE name = 'East'))
     FROM cng_6h_asset_proposal() WHERE staging_row_id = '6b400000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('XREG-2 the same spelling in West, ruled without a target Region, finds no East Station',
  NOT EXISTS (SELECT 1 FROM cng_6h_srv_proposal() WHERE installed_valve_id = '6b500000-0000-0000-0000-000000000002'));

SELECT preview_fingerprint AS fp FROM cng_6h_preview() \gset
SELECT srvs_linked FROM cng_6h_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('XREG-3 the SRV takes the Station''s Region; the source Region stays in source_region_raw',
  (SELECT (station_id, region_id, source_region_raw) = ('6b100000-0000-0000-0000-000000000001'::uuid, (SELECT id FROM regions WHERE name = 'East'), 'Delta')
     FROM installed_relief_valves WHERE id = '6b500000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('XREG-4 the asset was created in East and keeps its source Region in source_raw',
  (SELECT (r.name, t.source_raw->>'source_region') = ('East', 'Delta') FROM recovery_tanks t JOIN regions r ON r.id = t.region_id WHERE t.serial_number = 'TI-S1'));

ROLLBACK;
