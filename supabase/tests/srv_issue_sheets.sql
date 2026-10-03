-- srv_issue_sheets.sql — regression suite for 20261003130000_srv_issue_sheets.sql (owner request 2026-10-03:
-- the warehouse issue workbook, one sheet per day, a second export the same day becomes "<date> (2)").
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.try_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;
-- Issue a stock valve in place of an installed one, then date the issue as given.
CREATE FUNCTION pg_temp.issue(p_w uuid, p_old uuid, p_at timestamptz) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', 'iss_admin', 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v := cng_srv_issue(p_w, (SELECT updated_at FROM warehouse_relief_valves WHERE id = p_w),
                     (SELECT unit_id FROM installed_relief_valves WHERE id = p_old), p_old);
  EXECUTE 'RESET ROLE';
  UPDATE srv_issues SET issued_at = p_at WHERE id = v;
  RETURN v;
END $$;
-- The n-th assign of a test, its result kept so checks run in their own statements.
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;
CREATE FUNCTION pg_temp.assign(p_k text, p_sub text, p_region text, p_month date) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO r VALUES (p_k, pg_temp.try_as(p_sub, format(
    'INSERT INTO r VALUES (%L, cng_srv_issue_sheet_assign((SELECT id FROM regions WHERE name = %L), %L::date)::text)',
    p_k || ':n', p_region, p_month)));
END $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('9a000000-0000-0000-0000-00000000000a','iss_admin','admin',true,'TESTDATA ISS Admin'),
  ('9a000000-0000-0000-0000-00000000000b','iss_viewer','viewer',true,'TESTDATA ISS Viewer');
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT '9a000000-0000-0000-0000-00000000000b'::uuid, id, false FROM regions WHERE name = 'West';
INSERT INTO stations (id, region_id, station_name) VALUES
  ('9a100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TISS SHOBRA'),
  ('9a100000-0000-0000-0000-000000000002', (SELECT id FROM regions WHERE name = 'West'), 'TISS WARRAQ');
INSERT INTO units (id, station_id, region_id, unit_name) VALUES
  ('9a200000-0000-0000-0000-000000000001', '9a100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TISS SHOBRA 1'),
  ('9a200000-0000-0000-0000-000000000002', '9a100000-0000-0000-0000-000000000002', (SELECT id FROM regions WHERE name = 'West'), 'TISS WARRAQ 1');
-- Eight installed valves at East (Stage) and one at West.
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, location_raw, expected_parent_kind,
                                     serial_number, pressure_min, pressure_max, pressure_unit)
SELECT ('9a30000' || n || '-0000-0000-0000-000000000001')::uuid, (SELECT id FROM regions WHERE name = 'East'),
       '9a100000-0000-0000-0000-000000000001', '9a200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', 'Stage', 'compressor',
       'TISS-OLD' || n, 18, 18, 'BAR'
  FROM generate_series(1, 8) n;
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, location_raw, serial_number, pressure_min, pressure_max, pressure_unit)
SELECT '9a309000-0000-0000-0000-000000000001', id, '9a100000-0000-0000-0000-000000000002', '9a200000-0000-0000-0000-000000000002',
       'needs_equipment_mapping', 'Storage', 'TISS-WOLD', 300, 300, 'BAR' FROM regions WHERE name = 'West';
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, warehouse_code, manufacturer, size_type, inlet_size, outlet_size,
                                     set_pressure_raw, pressure_min, pressure_max, pressure_unit, last_calibration_date, last_calibration_precision, source_raw)
SELECT ('9a40000' || n || '-0000-0000-0000-000000000001')::uuid, 'available_calibrated', 'TISS-NEW' || n, 'sbc 87', 'Technical', 'Male', '1/2"', '1"',
       '18 BAR', 18, 18, 'BAR', '2026-09-01', 'exact_date', '{}'
  FROM generate_series(1, 9) n;
UPDATE warehouse_relief_valves SET set_pressure_raw = '300 BAR', pressure_min = 300, pressure_max = 300
 WHERE id = '9a400009-0000-0000-0000-000000000001';

-- 5 Oct (Cairo): three issued in the morning; one on 3 Oct; one in September; one issued then undone; one at West.
SELECT pg_temp.issue('9a400001-0000-0000-0000-000000000001', '9a300001-0000-0000-0000-000000000001', '2026-10-05 07:00+00');
SELECT pg_temp.issue('9a400002-0000-0000-0000-000000000001', '9a300002-0000-0000-0000-000000000001', '2026-10-05 07:05+00');
SELECT pg_temp.issue('9a400003-0000-0000-0000-000000000001', '9a300003-0000-0000-0000-000000000001', '2026-10-05 07:10+00');
SELECT pg_temp.issue('9a400004-0000-0000-0000-000000000001', '9a300004-0000-0000-0000-000000000001', '2026-10-03 09:00+00');
SELECT pg_temp.issue('9a400005-0000-0000-0000-000000000001', '9a300005-0000-0000-0000-000000000001', '2026-09-30 09:00+00');
CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
INSERT INTO ids VALUES ('undone', pg_temp.issue('9a400006-0000-0000-0000-000000000001', '9a300006-0000-0000-0000-000000000001', '2026-10-05 08:00+00'));
INSERT INTO r VALUES ('undo', pg_temp.try_as('iss_admin', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'undone'), 'to_stock')));
SELECT pg_temp.issue('9a400009-0000-0000-0000-000000000001', '9a309000-0000-0000-0000-000000000001', '2026-10-05 07:00+00');

SELECT pg_temp.assign('viewer', 'iss_viewer', 'East', '2026-10-01');
SELECT pg_temp.ck('ISS-1 only an admin exports (assigns) issue sheets; a refused export places nothing',
  (SELECT v FROM r WHERE k = 'viewer') = '42501' AND NOT EXISTS (SELECT 1 FROM srv_issue_sheets));

SELECT pg_temp.assign('a1', 'iss_admin', 'East', '2026-10-17');
SELECT pg_temp.ck('ISS-2 the first October export for East places the 4 live October issues: one sheet for 3 Oct, one for 5 Oct (3 valves)',
  (SELECT v FROM r WHERE k = 'a1') = 'OK' AND (SELECT v FROM r WHERE k = 'a1:n') = '4'
  AND (SELECT array_agg(issue_day::text || '#' || seq ORDER BY issue_day, seq) FROM srv_issue_sheets) = ARRAY['2026-10-03#1', '2026-10-05#1']
  AND (SELECT count(*) FROM srv_issues e JOIN srv_issue_sheets s ON s.id = e.sheet_id WHERE s.issue_day = '2026-10-05') = 3);
SELECT pg_temp.ck('ISS-3 an undone issue, a September issue and another Region''s issue are not placed',
  (SELECT sheet_id IS NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'undone'))
  AND (SELECT sheet_id IS NULL FROM srv_issues WHERE warehouse_valve_id = '9a400005-0000-0000-0000-000000000001')
  AND (SELECT sheet_id IS NULL FROM srv_issues WHERE warehouse_valve_id = '9a400009-0000-0000-0000-000000000001'));

SELECT pg_temp.assign('a2', 'iss_admin', 'East', '2026-10-01');
SELECT pg_temp.ck('ISS-4 exporting again with nothing new places nothing and makes no sheet',
  (SELECT v FROM r WHERE k = 'a2:n') = '0' AND (SELECT count(*) FROM srv_issue_sheets) = 2);

-- Later the same day: two more at East.
SELECT pg_temp.issue('9a400007-0000-0000-0000-000000000001', '9a300007-0000-0000-0000-000000000001', '2026-10-05 10:00+00');
SELECT pg_temp.issue('9a400008-0000-0000-0000-000000000001', '9a300008-0000-0000-0000-000000000001', '2026-10-05 10:05+00');
SELECT pg_temp.assign('a3', 'iss_admin', 'East', '2026-10-01');
SELECT pg_temp.ck('ISS-5 the second export of 5 Oct makes sheet (2) with only the 2 new valves; sheet 1 still holds its 3',
  (SELECT v FROM r WHERE k = 'a3:n') = '2'
  AND (SELECT count(*) FROM srv_issues e JOIN srv_issue_sheets s ON s.id = e.sheet_id WHERE s.issue_day = '2026-10-05' AND s.seq = 2) = 2
  AND (SELECT count(*) FROM srv_issues e JOIN srv_issue_sheets s ON s.id = e.sheet_id WHERE s.issue_day = '2026-10-05' AND s.seq = 1) = 3);

SELECT pg_temp.assign('sep', 'iss_admin', 'East', '2026-09-01');
SELECT pg_temp.ck('ISS-6 the September export places the September issue in its own month',
  (SELECT v FROM r WHERE k = 'sep:n') = '1'
  AND (SELECT s.issue_day FROM srv_issues e JOIN srv_issue_sheets s ON s.id = e.sheet_id
        WHERE e.warehouse_valve_id = '9a400005-0000-0000-0000-000000000001') = '2026-09-30');

SELECT pg_temp.ck('ISS-7 the issue day is the Cairo date: 22:30 UTC on 31 Oct is 1 Nov in Cairo',
  (SELECT ('2026-10-31 22:30+00'::timestamptz AT TIME ZONE 'Africa/Cairo')::date) = '2026-11-01'
  AND (SELECT issue_day FROM v_srv_issue_sheet WHERE issued_at = '2026-10-05 07:00+00' AND region_name = 'East') = '2026-10-05');

SELECT pg_temp.ck('ISS-8 a sheet row carries the place (Unit), Stage, the issued valve and the valve it replaced',
  (SELECT place_name = 'TISS SHOBRA 1' AND location = 'Stage' AND issued_serial = 'TISS-NEW1' AND issued_code = 'sbc 87'
          AND manufacturer = 'Technical' AND set_pressure_raw = '18 BAR' AND replaced_serial = 'TISS-OLD1'
          AND replaced_returned_at IS NULL AND sheet_seq = 1
     FROM v_srv_issue_sheet WHERE warehouse_valve_id = '9a400001-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'undone')));

SELECT pg_temp.ck('ISS-9 every sheet is audited with its exporter',
  (SELECT count(*) FROM audit_logs WHERE entity_table = 'srv_issue_sheets' AND actor_id = '9a000000-0000-0000-0000-00000000000a') = 4);

INSERT INTO r VALUES ('write', pg_temp.try_as('iss_admin', format(
  'INSERT INTO srv_issue_sheets (region_id, issue_day, seq, exported_by) VALUES ((SELECT id FROM regions WHERE name = %L), %L, 9, %L)',
  'East', '2026-10-05', '9a000000-0000-0000-0000-00000000000a')));
INSERT INTO r VALUES ('move', pg_temp.try_as('iss_admin', 'UPDATE srv_issues SET sheet_id = NULL'));
SELECT pg_temp.ck('ISS-10 not even an admin writes a sheet or moves an issue between sheets directly',
  (SELECT v FROM r WHERE k = 'write') = '42501' AND (SELECT v FROM r WHERE k = 'move') = '42501'
  AND (SELECT count(*) FROM srv_issues WHERE sheet_id IS NOT NULL) = 7);

INSERT INTO r SELECT 'viewer_rows', pg_temp.try_as('iss_viewer',
  'INSERT INTO r SELECT ''viewer_rows:n'', count(*)::text || ''/'' || (SELECT count(*) FROM srv_issue_sheets)::text FROM v_srv_issue_sheet');
SELECT pg_temp.ck('ISS-11 a West viewer reads only West rows and no East sheet',
  (SELECT v FROM r WHERE k = 'viewer_rows:n') = '1/0');

SELECT pg_temp.ck('ISS-12 the view runs with the caller''s rights and the sheet table has RLS',
  (SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE relname = 'v_srv_issue_sheet')
  AND (SELECT relrowsecurity FROM pg_class WHERE relname = 'srv_issue_sheets'));

ROLLBACK;
