-- srv_snapshot_update_6n.sql — regression suite for 20260925000000_srv_snapshot_update_6n.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name) SELECT '6a100000-0000-0000-0000-000000000001', id, 'TN ST' FROM regions WHERE name = 'West';
INSERT INTO installed_relief_valves (id, station_id, region_id, mapping_status, serial_number, serial_number_raw, serial_status,
                                     set_pressure_raw, pressure_min, pressure_max, pressure_unit,
                                     next_calibration_date, next_calibration_precision, next_calibration_raw)
SELECT v.id::uuid, '6a100000-0000-0000-0000-000000000001', r.id, 'needs_unit_mapping', v.sn, v.sn, 'assigned',
       '3976 PSI', 3976, 3976, 'PSI', '2025-01-01', 'exact_date', '2025-01-01'
  FROM (VALUES ('6a500000-0000-0000-0000-000000000001', 'OLD-P'), ('6a500000-0000-0000-0000-000000000002', 'OLD-S')) v(id, sn),
       regions r WHERE r.name = 'West';

\set payload '[{"id":"6a500000-0000-0000-0000-000000000001","kind":"pressure","set_pressure_raw":"4000 PSI","pressure_min":4000,"pressure_max":4000,"pressure_unit":"PSI"},{"id":"6a500000-0000-0000-0000-000000000002","kind":"serial","serial_number":"NEW-S","serial_number_raw":"NEW-S","part_number":null,"serial_status":"assigned","set_pressure_raw":"3976 PSI","pressure_min":3976,"pressure_max":3976,"pressure_unit":"PSI","last_calibration_date":"2026-04-07","last_calibration_precision":"exact_date","last_calibration_raw":"2026-04-07","next_calibration_date":null,"next_calibration_precision":"year_only","next_calibration_raw":"2027"}]'

SELECT pg_temp.ck('N-1 preview counts one pressure and one serial change, nothing missing',
  (SELECT (total, pressure_changes, serial_changes, missing, already_applied) = (2, 1, 1, 0, 0) FROM cng_6n_preview(:'payload'::jsonb)));
SELECT pg_temp.ck('N-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6n_commit(jsonb, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6n_commit('[]'::jsonb, 'wrong', 'x'); RAISE NOTICE 'FAILED: N-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  N-3 a wrong fingerprint is refused'; END $$;
SELECT pg_temp.ck('N-4 an unknown id counts as missing',
  (SELECT missing = 1 FROM cng_6n_preview('[{"id":"6a500000-0000-0000-0000-0000000000ff","kind":"pressure"}]'::jsonb)));
SELECT set_config('cng.t6n', :'payload', true);
SELECT preview_fingerprint AS fp FROM cng_6n_preview(:'payload'::jsonb) \gset
SELECT updated FROM cng_6n_commit(:'payload'::jsonb, :'fp', 'test') \gset
SELECT pg_temp.ck('N-5 pressure change keeps serial and dates',
  (SELECT set_pressure_raw = '4000 PSI' AND pressure_min = 4000 AND serial_number = 'OLD-P' AND next_calibration_date = '2025-01-01'
     FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('N-6 serial change takes serial and the snapshot dates (year-only stays year-only)',
  (SELECT serial_number = 'NEW-S' AND last_calibration_date = '2026-04-07' AND next_calibration_date IS NULL
          AND next_calibration_precision = 'year_only' AND next_calibration_raw = '2027'
     FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('N-7 audit keeps the old values; replay with the old fingerprint is refused',
  EXISTS (SELECT 1 FROM audit_logs WHERE actor_label = 'service_role:srv_snapshot_update_6n'
            AND before_data->'records' @> '[{"serial_number":"OLD-S"}]')
  AND (SELECT already_applied = 2 FROM cng_6n_preview(:'payload'::jsonb)));
DO $$ BEGIN PERFORM cng_6n_commit(p, (SELECT preview_fingerprint FROM cng_6n_preview(p)), 'x')
  FROM (SELECT current_setting('cng.t6n')::jsonb p) q; RAISE NOTICE 'FAILED: N-8';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  N-8 replay with the current fingerprint is refused'; END $$;
ROLLBACK;
