-- equipment_issue_sheets.sql — regression suite for 20261010100000_equipment_issue_sheets.sql (owner request 2026-10-10):
-- the warehouse issue sheet for hoses and gas detectors, as the relief valves have.
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
CREATE TEMP TABLE outcome (k text PRIMARY KEY, res text);
CREATE FUNCTION pg_temp.act(p_k text, p_sub text, p_sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO outcome VALUES (p_k, pg_temp.try_as(p_sub, p_sql)); END $$;
CREATE FUNCTION pg_temp.res(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT res FROM outcome WHERE k = p_k $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('8d000000-0000-0000-0000-00000000000a','eqs_admin','admin',true,'TESTDATA EQS Admin'),
  ('8d000000-0000-0000-0000-00000000000b','eqs_viewer','viewer',true,'TESTDATA EQS Viewer');
INSERT INTO stations (id, region_id, station_name) SELECT v.id::uuid, r.id, v.n FROM regions r,
  (VALUES ('8d100000-0000-0000-0000-000000000001','TEQS AAA'), ('8d100000-0000-0000-0000-000000000002','TEQS BBB')) v(id, n) WHERE r.name = 'Canal';
INSERT INTO hoses (id, region_id, station_id, mapping_status, serial_number, serial_status) SELECT v.id::uuid, r.id, v.s::uuid, 'needs_unit_mapping', v.sn, 'assigned'
  FROM regions r, (VALUES ('8d300000-0000-0000-0000-000000000001','8d100000-0000-0000-0000-000000000001','TEQS-A-OLD1'),
                          ('8d300000-0000-0000-0000-000000000002','8d100000-0000-0000-0000-000000000001','TEQS-A-OLD2'),
                          ('8d300000-0000-0000-0000-000000000003','8d100000-0000-0000-0000-000000000002','TEQS-B-OLD')) v(id, s, sn) WHERE r.name = 'Canal';
SELECT pg_temp.act('s1', 'eqs_admin', $q$SELECT cng_equipment_stock_add('hose','available_calibrated',ARRAY['TEQS-N1','TEQS-N2','TEQS-N3','TEQS-N4','TEQS-N5'],NULL,NULL,NULL,'hose',
      350,'BAR',NULL,NULL,'2026-09-01'::date,'2027-09-01'::date,'hk 7',NULL)$q$);
CREATE FUNCTION pg_temp.stock(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM equipment_stock WHERE serial_number = p $$;
CREATE FUNCTION pg_temp.issue_of(p text) RETURNS uuid LANGUAGE sql AS $$
  SELECT e.id FROM equipment_issues e JOIN equipment_stock w ON w.id = e.stock_id WHERE w.serial_number = p AND e.transferred_from_issue_id IS NULL ORDER BY e.issued_at LIMIT 1 $$;
CREATE FUNCTION pg_temp.issue(p_serial text, p_station uuid, p_replace uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.try_as('eqs_admin', format('SELECT cng_equipment_issue(%L, %L, %L, NULL, %L)', pg_temp.stock(p_serial),
    (SELECT updated_at FROM equipment_stock WHERE serial_number = p_serial), p_station, p_replace)) $$;
CREATE TEMP VIEW month AS SELECT to_char(now() AT TIME ZONE 'Africa/Cairo', 'YYYY-MM-01') AS m;

-- N1 replaces A-OLD1; N2 is added at A; N3 is issued then undone back to stock; N4 is issued then undone "still at the station".
INSERT INTO outcome VALUES ('i1', pg_temp.issue('TEQS-N1', '8d100000-0000-0000-0000-000000000001', '8d300000-0000-0000-0000-000000000001'));
INSERT INTO outcome VALUES ('i2', pg_temp.issue('TEQS-N2', '8d100000-0000-0000-0000-000000000001', NULL));
INSERT INTO outcome VALUES ('i3', pg_temp.issue('TEQS-N3', '8d100000-0000-0000-0000-000000000001', NULL));
INSERT INTO outcome VALUES ('i4', pg_temp.issue('TEQS-N4', '8d100000-0000-0000-0000-000000000001', NULL));
SELECT pg_temp.act('u3', 'eqs_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'to_stock')$q$, pg_temp.issue_of('TEQS-N3')));
SELECT pg_temp.act('u4', 'eqs_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'await_return')$q$, pg_temp.issue_of('TEQS-N4')));
SELECT pg_temp.ck('EQS-1 the sheet rows: live issues and one undone still at the station (cancelled); one undone back to stock never left',
  (SELECT bool_and(res = 'OK') FROM outcome WHERE k IN ('i1', 'i2', 'i3', 'i4', 'u3', 'u4'))
  AND (SELECT count(*) = 3 FROM v_equipment_issue_sheet WHERE issued_serial LIKE 'TEQS-%')
  AND (SELECT is_cancelled FROM v_equipment_issue_sheet WHERE issued_serial = 'TEQS-N4')
  AND NOT EXISTS (SELECT 1 FROM v_equipment_issue_sheet WHERE issued_serial = 'TEQS-N3')
  AND (SELECT replaced_serial = 'TEQS-A-OLD1' AND place_name = 'TEQS AAA' AND issued_code = 'hk 7' AND NOT is_cancelled
         FROM v_equipment_issue_sheet WHERE issued_serial = 'TEQS-N1'));

SELECT pg_temp.act('viewer', 'eqs_viewer', format($q$SELECT cng_equipment_issue_sheet_assign('hose', (SELECT id FROM regions WHERE name = 'Canal'), %L)$q$, (SELECT m FROM month)));
SELECT pg_temp.act('a1', 'eqs_admin', format($q$SELECT cng_equipment_issue_sheet_assign('hose', (SELECT id FROM regions WHERE name = 'Canal'), %L)$q$, (SELECT m FROM month)));
SELECT pg_temp.ck('EQS-2 only an admin exports; the export puts the three on ONE sheet (seq 1) for their day',
  pg_temp.res('viewer') = '42501' AND pg_temp.res('a1') = 'OK'
  AND (SELECT count(DISTINCT sheet_id) = 1 AND bool_and(sheet_seq = 1) FROM v_equipment_issue_sheet WHERE issued_serial LIKE 'TEQS-%')
  AND (SELECT sheet_id IS NULL FROM equipment_issues WHERE id = pg_temp.issue_of('TEQS-N3')));

-- Later the same day: N5 issued to A in place of A-OLD2, then moved to B in place of B-OLD.
INSERT INTO outcome VALUES ('i5', pg_temp.issue('TEQS-N5', '8d100000-0000-0000-0000-000000000001', '8d300000-0000-0000-0000-000000000002'));
SELECT pg_temp.act('mv', 'eqs_admin', format($q$SELECT cng_equipment_issue_transfer(%L, '8d100000-0000-0000-0000-000000000002', NULL, '8d300000-0000-0000-0000-000000000003')$q$, pg_temp.issue_of('TEQS-N5')));
SELECT pg_temp.ck('EQS-3 a moved item reads as issued straight to B: B''s place and the item it replaced there; the move has no row',
  pg_temp.res('i5') = 'OK' AND pg_temp.res('mv') = 'OK'
  AND (SELECT place_name = 'TEQS BBB' AND replaced_serial = 'TEQS-B-OLD' AND transferred_to = 'TEQS BBB' AND NOT is_cancelled
         FROM v_equipment_issue_sheet WHERE issued_serial = 'TEQS-N5')
  AND (SELECT count(*) = 1 FROM v_equipment_issue_sheet WHERE issued_serial = 'TEQS-N5'));
SELECT pg_temp.act('a2', 'eqs_admin', format($q$SELECT cng_equipment_issue_sheet_assign('hose', (SELECT id FROM regions WHERE name = 'Canal'), %L)$q$, (SELECT m FROM month)));
SELECT pg_temp.ck('EQS-4 the second export the same day makes sheet (2) with only the new issue; sheet 1 is unchanged; the move is never placed',
  pg_temp.res('a2') = 'OK'
  AND (SELECT sheet_seq = 2 FROM v_equipment_issue_sheet WHERE issued_serial = 'TEQS-N5')
  AND (SELECT count(*) = 3 FROM v_equipment_issue_sheet WHERE issued_serial LIKE 'TEQS-%' AND sheet_seq = 1)
  AND (SELECT sheet_id IS NULL FROM equipment_issues WHERE transferred_from_issue_id = pg_temp.issue_of('TEQS-N5')));
SELECT pg_temp.act('a3', 'eqs_admin', format($q$SELECT cng_equipment_issue_sheet_assign('gas_detector', (SELECT id FROM regions WHERE name = 'Canal'), %L)$q$, (SELECT m FROM month)));
SELECT pg_temp.ck('EQS-5 a detector export places no hose; sheets are per kind',
  pg_temp.res('a3') = 'OK' AND NOT EXISTS (SELECT 1 FROM equipment_issue_sheets WHERE kind = 'gas_detector'
                                            AND region_id = (SELECT id FROM regions WHERE name = 'Canal')));

SELECT pg_temp.ck('EQS-6 security: assign is SECURITY DEFINER with a pinned search_path, authenticated only; no browser write on sheets; the view runs as the caller',
  (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc WHERE proname = 'cng_equipment_issue_sheet_assign')
  AND NOT has_function_privilege('anon', 'cng_equipment_issue_sheet_assign(text, uuid, date)', 'EXECUTE')
  AND NOT has_table_privilege('authenticated', 'equipment_issue_sheets', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'equipment_issue_sheets', 'UPDATE')
  AND (SELECT reloptions::text LIKE '%security_invoker=true%' FROM pg_class WHERE relname = 'v_equipment_issue_sheet'));

ROLLBACK;
