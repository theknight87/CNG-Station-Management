-- srv_issue_sheet_cancelled.sql — regression suite for 20261004090000_srv_issue_sheet_cancelled.sql (owner ruling
-- 2026-10-04): an issue undone as "still at the station" (await_return) left the warehouse and stays on the issue
-- sheet marked cancelled; one undone as "back in the warehouse" (to_stock) never left and is on no sheet.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.as_admin(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', 'isc_admin', 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE || ' ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;
CREATE FUNCTION pg_temp.issue(n int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid; w uuid := ('9b40000' || n || '-0000-0000-0000-000000000001')::uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', 'isc_admin', 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v := cng_srv_issue(w, (SELECT updated_at FROM warehouse_relief_valves WHERE id = w), '9b200000-0000-0000-0000-000000000001',
                     ('9b30000' || n || '-0000-0000-0000-000000000001')::uuid);
  EXECUTE 'RESET ROLE';
  UPDATE srv_issues SET issued_at = '2026-10-05 07:00+00'::timestamptz + make_interval(mins => n) WHERE id = v;
  RETURN v;
END $$;
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('9b000000-0000-0000-0000-00000000000a','isc_admin','admin',true,'TESTDATA ISC Admin');
INSERT INTO stations (id, region_id, station_name) VALUES ('9b100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TISC NASR');
INSERT INTO units (id, station_id, region_id, unit_name) VALUES
  ('9b200000-0000-0000-0000-000000000001', '9b100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TISC NASR 1');
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, location_raw, serial_number, pressure_min, pressure_max, pressure_unit)
SELECT ('9b30000' || n || '-0000-0000-0000-000000000001')::uuid, (SELECT id FROM regions WHERE name = 'East'),
       '9b100000-0000-0000-0000-000000000001', '9b200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', 'Stage', 'TISC-OLD' || n, 18, 18, 'BAR'
  FROM generate_series(1, 5) n;
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, warehouse_code, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
                                     last_calibration_date, last_calibration_precision, source_raw)
SELECT ('9b40000' || n || '-0000-0000-0000-000000000001')::uuid, 'available_calibrated', 'TISC-NEW' || n, 'sbc 87', '18 BAR', 18, 18, 'BAR',
       '2026-09-01', 'exact_date', '{}'
  FROM generate_series(1, 5) n;

-- Before any export: A undone awaiting return, B undone back to stock, E live.
INSERT INTO ids VALUES ('a', pg_temp.issue(1)), ('b', pg_temp.issue(2)), ('e', pg_temp.issue(5));
INSERT INTO r VALUES ('undo_a', pg_temp.as_admin(format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'a'), 'await_return')));
INSERT INTO r VALUES ('undo_b', pg_temp.as_admin(format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'b'), 'to_stock')));
INSERT INTO r VALUES ('x1', pg_temp.as_admin(format('INSERT INTO r VALUES (%L, cng_srv_issue_sheet_assign((SELECT id FROM regions WHERE name = %L), %L)::text)', 'x1:n', 'East', '2026-10-01')));

SELECT pg_temp.ck('ISC-1 an issue undone "still at the station" before the export is placed on the sheet, marked cancelled',
  (SELECT v FROM r WHERE k = 'undo_a') = 'OK' AND (SELECT v FROM r WHERE k = 'x1:n') = '2'
  AND (SELECT sheet_id IS NOT NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'a'))
  AND (SELECT is_cancelled AND cancelled_at IS NOT NULL AND sheet_seq = 1 FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'a'))
  AND (SELECT NOT is_cancelled FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'e')));
SELECT pg_temp.ck('ISC-2 an issue undone "back in the warehouse" before the export is on no sheet and not in the sheet rows',
  (SELECT v FROM r WHERE k = 'undo_b') = 'OK'
  AND (SELECT sheet_id IS NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'b'))
  AND NOT EXISTS (SELECT 1 FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'b')));

-- After the export: C undone awaiting return, D undone back to stock.
INSERT INTO ids VALUES ('c', pg_temp.issue(3)), ('d', pg_temp.issue(4));
INSERT INTO r VALUES ('x2', pg_temp.as_admin(format('INSERT INTO r VALUES (%L, cng_srv_issue_sheet_assign((SELECT id FROM regions WHERE name = %L), %L)::text)', 'x2:n', 'East', '2026-10-01')));
INSERT INTO r VALUES ('undo_c', pg_temp.as_admin(format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'c'), 'await_return')));
INSERT INTO r VALUES ('undo_d', pg_temp.as_admin(format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'd'), 'to_stock')));

SELECT pg_temp.ck('ISC-3 undone "still at the station" after the export: stays on its sheet (2), now marked cancelled',
  (SELECT v FROM r WHERE k = 'x2:n') = '2' AND (SELECT v FROM r WHERE k = 'undo_c') = 'OK'
  AND (SELECT is_cancelled AND sheet_seq = 2 FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'c')));
SELECT pg_temp.ck('ISC-4 undone "back in the warehouse" after the export: leaves the sheet rows (it never left the warehouse)',
  (SELECT v FROM r WHERE k = 'undo_d') = 'OK'
  AND NOT EXISTS (SELECT 1 FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'd'))
  AND (SELECT count(*) FROM v_srv_issue_sheet WHERE sheet_seq = 2) = 1);

INSERT INTO r VALUES ('x3', pg_temp.as_admin(format('INSERT INTO r VALUES (%L, cng_srv_issue_sheet_assign((SELECT id FROM regions WHERE name = %L), %L)::text)', 'x3:n', 'East', '2026-10-01')));
SELECT pg_temp.ck('ISC-5 a later export places nothing: no issue moves sheet and no empty sheet is made',
  (SELECT v FROM r WHERE k = 'x3:n') = '0' AND (SELECT count(*) FROM srv_issue_sheets WHERE region_id = (SELECT id FROM regions WHERE name = 'East')
                                                  AND issue_day = '2026-10-05') = 2);

-- The undone valve arrives back: its return date shows on the cancelled row.
INSERT INTO r VALUES ('recv', pg_temp.as_admin(format('SELECT cng_srv_log_receive(ARRAY[%L]::uuid[])',
  (SELECT id FROM srv_field_log WHERE issue_id = (SELECT v FROM ids WHERE k = 'c') AND reason = 'issue_undone'))));
SELECT pg_temp.ck('ISC-6 once the undone valve is received back, its return date is on the cancelled row',
  (SELECT v FROM r WHERE k = 'recv') = 'OK'
  AND (SELECT cancelled_returned_at IS NOT NULL FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'c'))
  AND (SELECT cancelled_returned_at IS NULL FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'a')));

SELECT pg_temp.ck('ISC-7 the view still runs with the caller''s rights',
  (SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE relname = 'v_srv_issue_sheet'));

ROLLBACK;
