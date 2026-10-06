-- srv_issue_transfer.sql — regression suite for 20261006090000_srv_issue_transfer.sql (owner request 2026-10-06):
-- a valve issued to Station A was not fitted (the valve there is still valid) and goes straight on to Station B.
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
CREATE FUNCTION pg_temp.issue(p_w uuid, p_unit uuid, p_old uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', 'tr_admin', 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v := cng_srv_issue(p_w, (SELECT updated_at FROM warehouse_relief_valves WHERE id = p_w), p_unit, p_old);
  EXECUTE 'RESET ROLE';
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.transfer(p_issue uuid, p_unit uuid, p_old uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', 'tr_admin', 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v := cng_srv_issue_transfer(p_issue, p_unit, p_old);
  EXECUTE 'RESET ROLE';
  RETURN v;
END $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('7d000000-0000-0000-0000-00000000000a','tr_admin','admin',true,'TESTDATA TR Admin'),
  ('7d000000-0000-0000-0000-00000000000b','tr_viewer','viewer',true,'TESTDATA TR Viewer');
INSERT INTO stations (id, region_id, station_name) SELECT v.id::uuid, r.id, v.n FROM regions r,
  (VALUES ('7d100000-0000-0000-0000-000000000001','TTR AAA'), ('7d100000-0000-0000-0000-000000000002','TTR BBB')) v(id, n) WHERE r.name = 'Delta';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT v.id::uuid, v.s::uuid, r.id, v.n FROM regions r,
  (VALUES ('7d200000-0000-0000-0000-000000000001','7d100000-0000-0000-0000-000000000001','TTR AAA'),
          ('7d200000-0000-0000-0000-000000000002','7d100000-0000-0000-0000-000000000002','TTR BBB')) v(id, s, n) WHERE r.name = 'Delta';
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, serial_number, pressure_min, pressure_max, pressure_unit)
SELECT v.id::uuid, r.id, v.s::uuid, v.u::uuid, 'needs_equipment_mapping', v.sn, 18, 18, 'BAR' FROM regions r,
  (VALUES ('7d300000-0000-0000-0000-000000000001','7d100000-0000-0000-0000-000000000001','7d200000-0000-0000-0000-000000000001','TTR-A-OLD'),
          ('7d300000-0000-0000-0000-000000000002','7d100000-0000-0000-0000-000000000002','7d200000-0000-0000-0000-000000000002','TTR-B-OLD'),
          ('7d300000-0000-0000-0000-000000000003','7d100000-0000-0000-0000-000000000001','7d200000-0000-0000-0000-000000000001','TTR-A-OLD2'))
  v(id, s, u, sn) WHERE r.name = 'Delta';
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, warehouse_code, pressure_min, pressure_max, pressure_unit,
                                     last_calibration_date, last_calibration_precision, source_raw) VALUES
  ('7d400000-0000-0000-0000-000000000001','available_calibrated','TTR-NEW','sbc 11',18,18,'BAR','2026-09-01','exact_date','{}'),
  ('7d400000-0000-0000-0000-000000000002','available_calibrated','TTR-NEW2','sbc 12',18,18,'BAR','2026-09-01','exact_date','{}');

CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON ids, r TO authenticated;
CREATE TEMP VIEW live AS
  SELECT serial_number, station_id, unit_id FROM installed_relief_valves
   WHERE station_id IN ('7d100000-0000-0000-0000-000000000001','7d100000-0000-0000-0000-000000000002') AND archived_at IS NULL;

-- NEW is issued to A in place of A-OLD, three days ago.
INSERT INTO ids VALUES ('ia', pg_temp.issue('7d400000-0000-0000-0000-000000000001', '7d200000-0000-0000-0000-000000000001', '7d300000-0000-0000-0000-000000000001'));
UPDATE warehouse_relief_valves SET warehouse_issue_date = '2026-10-03' WHERE id = '7d400000-0000-0000-0000-000000000001';

INSERT INTO r VALUES ('viewer', pg_temp.try_as('tr_viewer', format('SELECT cng_srv_issue_transfer(%L, %L)',
  (SELECT v FROM ids WHERE k = 'ia'), '7d200000-0000-0000-0000-000000000002')));
INSERT INTO r VALUES ('same', pg_temp.try_as('tr_admin', format('SELECT cng_srv_issue_transfer(%L, %L)',
  (SELECT v FROM ids WHERE k = 'ia'), '7d200000-0000-0000-0000-000000000001')));
INSERT INTO r VALUES ('wrongp', pg_temp.try_as('tr_admin', format('SELECT cng_srv_issue_transfer(%L, %L, %L)',
  (SELECT v FROM ids WHERE k = 'ia'), '7d200000-0000-0000-0000-000000000002', '7d300000-0000-0000-0000-000000000003')));
SELECT pg_temp.ck('TR-1 only an admin may move; not to the same Unit; the replaced valve must be at the new Station; nothing changed',
  (SELECT v FROM r WHERE k = 'viewer') = '42501' AND (SELECT v FROM r WHERE k = 'same') = '22023'
  AND (SELECT v FROM r WHERE k = 'wrongp') = '22023'
  AND (SELECT cancelled_at IS NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'ia')));

-- Move NEW to B in place of B-OLD.
INSERT INTO ids VALUES ('ib', pg_temp.transfer((SELECT v FROM ids WHERE k = 'ia'), '7d200000-0000-0000-0000-000000000002', '7d300000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('TR-2 at A the old valve is back alone in its position; at B NEW replaced B-OLD',
  (SELECT array_agg(serial_number ORDER BY serial_number) FROM live WHERE station_id = '7d100000-0000-0000-0000-000000000001') = ARRAY['TTR-A-OLD','TTR-A-OLD2']
  AND (SELECT array_agg(serial_number) FROM live WHERE station_id = '7d100000-0000-0000-0000-000000000002') = ARRAY['TTR-NEW']);
SELECT pg_temp.ck('TR-3 the issue at A is cancelled as transferred (kept); the new issue names it; A-OLD left the SRV Log, B-OLD is in it',
  (SELECT cancel_action = 'transferred' FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'ia'))
  AND (SELECT transferred_from_issue_id = (SELECT v FROM ids WHERE k = 'ia') AND replaced_installed_valve_id = '7d300000-0000-0000-0000-000000000002'
         FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'ib'))
  AND NOT EXISTS (SELECT 1 FROM v_srv_field_log WHERE installed_valve_id = '7d300000-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM v_srv_field_log WHERE installed_valve_id = '7d300000-0000-0000-0000-000000000002' AND status = 'at_station'));
SELECT pg_temp.ck('TR-4 the store record follows it to B, still at the station, with its original issue date (it left the warehouse once)',
  (SELECT availability_status = 'sent_to_station_received' AND target_station_id = '7d100000-0000-0000-0000-000000000002'
          AND warehouse_issue_date = '2026-10-03' FROM warehouse_relief_valves WHERE id = '7d400000-0000-0000-0000-000000000001')
  AND (SELECT count(*) = 1 FROM warehouse_relief_valves WHERE serial_number = 'TTR-NEW'));
SELECT pg_temp.ck('TR-5 the Issue movement shows B only; history and audit record the move',
  NOT EXISTS (SELECT 1 FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'ia'))
  AND (SELECT station_name = 'TTR BBB' AND status = 'awaiting_replaced' FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'ib'))
  AND EXISTS (SELECT 1 FROM srv_history WHERE warehouse_valve_id = '7d400000-0000-0000-0000-000000000001' AND event = 'transferred')
  AND EXISTS (SELECT 1 FROM audit_logs WHERE entity_id = (SELECT v FROM ids WHERE k = 'ib') AND actor_label = 'srv_issue_transfer'
                AND actor_id = '7d000000-0000-0000-0000-00000000000a'));
SELECT pg_temp.ck('TR-6 issue sheet: one row (the warehouse exit to A) saying where it went; the move to B has no row',
  (SELECT transferred_to = 'TTR BBB' AND NOT is_cancelled FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'ia'))
  AND NOT EXISTS (SELECT 1 FROM v_srv_issue_sheet WHERE id = (SELECT v FROM ids WHERE k = 'ib')));
INSERT INTO r VALUES ('assign', pg_temp.try_as('tr_admin', format('SELECT cng_srv_issue_sheet_assign((SELECT id FROM regions WHERE name = %L), %L)',
  'Delta', to_char(now() AT TIME ZONE 'Africa/Cairo', 'YYYY-MM-01'))));
SELECT pg_temp.ck('TR-7 exporting the sheet places the issue at A and never the move',
  (SELECT v FROM r WHERE k = 'assign') = 'OK'
  AND (SELECT sheet_id IS NOT NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'ia'))
  AND (SELECT sheet_id IS NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'ib')));

INSERT INTO r VALUES ('twice', pg_temp.try_as('tr_admin', format('SELECT cng_srv_issue_transfer(%L, %L)',
  (SELECT v FROM ids WHERE k = 'ia'), '7d200000-0000-0000-0000-000000000002')));
SELECT pg_temp.ck('TR-8 the old issue cannot be moved again', (SELECT v FROM r WHERE k = 'twice') = 'PT409');

INSERT INTO r VALUES ('undo', pg_temp.try_as('tr_admin', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'ib'), 'await_return')));
SELECT pg_temp.ck('TR-9 the move can be undone like any issue: B-OLD back, NEW awaiting return from B',
  (SELECT v FROM r WHERE k = 'undo') = 'OK'
  AND (SELECT array_agg(serial_number) FROM live WHERE station_id = '7d100000-0000-0000-0000-000000000002') = ARRAY['TTR-B-OLD']
  AND EXISTS (SELECT 1 FROM v_srv_field_log WHERE warehouse_valve_id = '7d400000-0000-0000-0000-000000000001' AND reason = 'issue_undone'
                AND station_id = '7d100000-0000-0000-0000-000000000002'));

-- NEW2 issued to A in place of A-OLD2; A-OLD2 is received back; the move is refused (A-OLD2 cannot stay at A).
INSERT INTO ids VALUES ('ia2', pg_temp.issue('7d400000-0000-0000-0000-000000000002', '7d200000-0000-0000-0000-000000000001', '7d300000-0000-0000-0000-000000000003'));
INSERT INTO r VALUES ('recv', pg_temp.try_as('tr_admin', format('SELECT cng_srv_log_receive(ARRAY[%L]::uuid[])',
  (SELECT id FROM srv_field_log WHERE issue_id = (SELECT v FROM ids WHERE k = 'ia2')))));
INSERT INTO r VALUES ('back', pg_temp.try_as('tr_admin', format('SELECT cng_srv_issue_transfer(%L, %L)',
  (SELECT v FROM ids WHERE k = 'ia2'), '7d200000-0000-0000-0000-000000000002')));
SELECT pg_temp.ck('TR-10 refused when the replaced valve is already back in the warehouse; nothing changed',
  (SELECT v FROM r WHERE k = 'back') = 'PT409'
  AND (SELECT cancelled_at IS NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'ia2'))
  AND EXISTS (SELECT 1 FROM live WHERE serial_number = 'TTR-NEW2' AND station_id = '7d100000-0000-0000-0000-000000000001'));

SELECT pg_temp.ck('TR-11 security: SECURITY DEFINER, pinned search_path, authenticated only; the sheet view runs as the caller',
  (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc WHERE proname = 'cng_srv_issue_transfer')
  AND has_function_privilege('authenticated', 'cng_srv_issue_transfer(uuid, uuid, uuid, boolean, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_srv_issue_transfer(uuid, uuid, uuid, boolean, text)', 'EXECUTE')
  AND (SELECT reloptions::text LIKE '%security_invoker=true%' FROM pg_class WHERE relname = 'v_srv_issue_sheet'));

ROLLBACK;
