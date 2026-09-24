-- srv_snapshot_add_archive_6o.sql — regression suite for 20260925010000_srv_snapshot_add_archive_6o.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- TO A: a prior valve under raw name 'TO RAW' is on Station TO A / Unit TO A1. TO C: canonical only, no prior valve.
INSERT INTO stations (id, region_id, station_name)
SELECT v.id::uuid, r.id, v.nm FROM (VALUES ('6b100000-0000-0000-0000-000000000001', 'TO A'), ('6b100000-0000-0000-0000-000000000002', 'TO C')) v(id, nm),
       regions r WHERE r.name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '6b200000-0000-0000-0000-000000000001', '6b100000-0000-0000-0000-000000000001', id, 'TO A1' FROM regions WHERE name = 'West';
INSERT INTO installed_relief_valves (id, station_id, unit_id, region_id, mapping_status, serial_number, source_station_name_raw)
SELECT '6b500000-0000-0000-0000-000000000001', '6b100000-0000-0000-0000-000000000001', '6b200000-0000-0000-0000-000000000001', id,
       'needs_equipment_mapping', 'TO-OLD', 'TO RAW' FROM regions WHERE name = 'West';
INSERT INTO installed_relief_valves (id, station_id, unit_id, region_id, mapping_status, serial_number, source_station_name_raw)
SELECT '6b500000-0000-0000-0000-000000000002', '6b100000-0000-0000-0000-000000000001', '6b200000-0000-0000-0000-000000000001', id,
       'needs_equipment_mapping', 'TO-GONE', 'TO RAW' FROM regions WHERE name = 'West';

\set add '[[9001,"West","TO RAW","Stage","TO-NEW","TO-NEW",null,"assigned","Mercer","Male","1/2","1","35 BAR",35,35,"BAR",null,"unknown",null,"2027-01-01","exact_date","2027-01-01",null],[9002,"West","TO C","Storage",null,null,null,"unknown",null,null,null,null,"300 BAR",300,300,"BAR",null,"year_only","2021",null,"unknown",null,null],[9003,"West","TO NOWHERE","Stage",null,null,null,"unknown",null,null,null,null,null,null,null,null,null,"unknown",null,null,"unknown",null,null]]'
\set arc '["6b500000-0000-0000-0000-000000000002"]'

SELECT pg_temp.ck('O-1 Station from prior valves, else the canonical name, else none; Unit only from prior valves',
  (SELECT (station_id, unit_id) = ('6b100000-0000-0000-0000-000000000001'::uuid, '6b200000-0000-0000-0000-000000000001'::uuid) FROM cng_6o_proposal(:'add'::jsonb) WHERE source_row = 9001)
  AND (SELECT station_id = '6b100000-0000-0000-0000-000000000002' AND unit_id IS NULL FROM cng_6o_proposal(:'add'::jsonb) WHERE source_row = 9002)
  AND (SELECT station_id IS NULL FROM cng_6o_proposal(:'add'::jsonb) WHERE source_row = 9003));
SELECT pg_temp.ck('O-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6o_commit(jsonb, jsonb, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6o_commit('[]', '[]', 'wrong', 'x'); RAISE NOTICE 'FAILED: O-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  O-3 a wrong fingerprint is refused'; END $$;
SELECT set_config('cng.t6o_add', :'add', true), set_config('cng.t6o_arc', :'arc', true);
SELECT preview_fingerprint AS fp FROM cng_6o_preview(:'add'::jsonb, :'arc'::jsonb) \gset
SELECT added FROM cng_6o_commit(:'add'::jsonb, :'arc'::jsonb, :'fp', 'test') \gset
SELECT pg_temp.ck('O-4 statuses follow what was resolved; serial and dates stored as given',
  (SELECT mapping_status = 'needs_equipment_mapping' AND expected_parent_kind = 'compressor' AND serial_number = 'TO-NEW'
          AND next_calibration_date = '2027-01-01' FROM installed_relief_valves WHERE source_row = 9001 AND serial_number = 'TO-NEW')
  AND (SELECT mapping_status = 'needs_unit_mapping' AND last_calibration_precision = 'year_only' AND last_calibration_raw = '2021'
         FROM installed_relief_valves WHERE source_row = 9002 AND source_file LIKE 'Warehouse_Relief_Data%')
  AND (SELECT mapping_status = 'needs_station_mapping' AND source_station_name_raw = 'TO NOWHERE'
         FROM installed_relief_valves WHERE source_row = 9003 AND source_file LIKE 'Warehouse_Relief_Data%'));
SELECT pg_temp.ck('O-5 the absent valve is archived, not deleted; the other stays active',
  (SELECT archived_at IS NOT NULL FROM installed_relief_valves WHERE id = '6b500000-0000-0000-0000-000000000002')
  AND (SELECT archived_at IS NULL FROM installed_relief_valves WHERE id = '6b500000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('O-6 one audit row lists the archived ids',
  (SELECT count(*) = 1 FROM audit_logs WHERE actor_label = 'service_role:srv_snapshot_add_archive_6o'
     AND after_data->'archived' ? '6b500000-0000-0000-0000-000000000002'));
DO $$ BEGIN PERFORM cng_6o_commit(a, x, (SELECT preview_fingerprint FROM cng_6o_preview(a, x)), 'x')
  FROM (SELECT current_setting('cng.t6o_add')::jsonb a, current_setting('cng.t6o_arc')::jsonb x) q; RAISE NOTICE 'FAILED: O-7';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  O-7 replay with the current fingerprint is refused'; END $$;
ROLLBACK;
