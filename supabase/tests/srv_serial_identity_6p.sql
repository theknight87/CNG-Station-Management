-- srv_serial_identity_6p.sql — regression suite for 20260925020000_srv_serial_identity_6p.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name) SELECT '6c100000-0000-0000-0000-000000000001', id, 'TP ST' FROM regions WHERE name = 'East';
INSERT INTO installed_relief_valves (id, station_id, region_id, mapping_status, serial_number, serial_number_raw, serial_status,
                                     next_calibration_date, next_calibration_precision, next_calibration_raw, source_station_name_raw)
SELECT v.id::uuid, '6c100000-0000-0000-0000-000000000001', r.id, 'needs_unit_mapping', v.sn, v.sn, 'assigned',
       '2025-01-01', 'exact_date', '2025-01-01', 'TP ST'
  FROM (VALUES ('6c500000-0000-0000-0000-000000000001', 'TP-OLD'), ('6c500000-0000-0000-0000-000000000002', 'TP-MOVE')) v(id, sn),
       regions r WHERE r.name = 'East';
-- 6n rewrites the first valve with a new serial
\set p6n '[{"id":"6c500000-0000-0000-0000-000000000001","kind":"serial","serial_number":"TP-NEW","serial_number_raw":"TP-NEW","part_number":null,"serial_status":"assigned","set_pressure_raw":null,"pressure_min":null,"pressure_max":null,"pressure_unit":null,"last_calibration_date":"2026-09-01","last_calibration_precision":"exact_date","last_calibration_raw":"2026-09-01","next_calibration_date":"2027-09-01","next_calibration_precision":"exact_date","next_calibration_raw":"2027-09-01"}]'
SELECT preview_fingerprint AS f6n FROM cng_6n_preview(:'p6n'::jsonb) \gset
SELECT updated FROM cng_6n_commit(:'p6n'::jsonb, :'f6n', 'test') \gset
\set mv '["6c500000-0000-0000-0000-000000000002"]'

SELECT pg_temp.ck('P-1 the 6n serial change is proposed for a split',
  EXISTS (SELECT 1 FROM cng_6p_split_proposal() WHERE id = '6c500000-0000-0000-0000-000000000001' AND serial_now = 'TP-NEW'));
SELECT pg_temp.ck('P-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6p_commit(jsonb, text, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6p_commit('[]', 'Delta', 'wrong', 'x'); RAISE NOTICE 'FAILED: P-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  P-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6p_preview(:'mv'::jsonb, 'Delta') \gset
SELECT split FROM cng_6p_commit(:'mv'::jsonb, 'Delta', :'fp', 'test') \gset
SELECT pg_temp.ck('P-4 old record gets its old serial and date back and is archived',
  (SELECT serial_number = 'TP-OLD' AND next_calibration_date = '2025-01-01' AND archived_at IS NOT NULL
     FROM installed_relief_valves WHERE id = '6c500000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('P-5 a new active record carries the new serial, its dates and the same Station',
  (SELECT count(*) = 1 FROM installed_relief_valves WHERE serial_number = 'TP-NEW' AND archived_at IS NULL
     AND station_id = '6c100000-0000-0000-0000-000000000001' AND next_calibration_date = '2027-09-01'
     AND id <> '6c500000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('P-6 moved valve is in Delta with no Station, raw name kept',
  (SELECT i.station_id IS NULL AND i.mapping_status = 'needs_station_mapping' AND g.name = 'Delta' AND i.source_station_name_raw = 'TP ST'
     FROM installed_relief_valves i JOIN regions g ON g.id = i.region_id WHERE i.id = '6c500000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('P-7 replay: nothing left to split and the move is refused',
  NOT EXISTS (SELECT 1 FROM cng_6p_split_proposal() WHERE id = '6c500000-0000-0000-0000-000000000001')
  AND (SELECT refused > 0 FROM cng_6p_preview(:'mv'::jsonb, 'Delta')));
ROLLBACK;
