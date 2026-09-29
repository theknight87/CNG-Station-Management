-- srv_issue_undo.sql — regression suite for 20260929150000_srv_issue_undo_and_movements.sql
-- Owner report 2026-09-29: "Back to its station" on a replaced valve reinstated it but left the issued valve
-- installed in the same position (260328 + 255832 at ابو المطامير كتكوت). An issue is now undone as one decision.
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
CREATE FUNCTION pg_temp.issue(p_w uuid, p_old uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', 'iu_admin', 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v := cng_srv_issue(p_w, (SELECT updated_at FROM warehouse_relief_valves WHERE id = p_w), '7c200000-0000-0000-0000-000000000001', p_old);
  EXECUTE 'RESET ROLE';
  RETURN v;
END $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('7c000000-0000-0000-0000-00000000000a','iu_admin','admin',true,'TESTDATA IU Admin'),
  ('7c000000-0000-0000-0000-00000000000b','iu_viewer','viewer',true,'TESTDATA IU Viewer');
INSERT INTO stations (id, region_id, station_name) SELECT '7c100000-0000-0000-0000-000000000001', r.id, 'TIU KATKOUT' FROM regions r WHERE r.name = 'Delta';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT '7c200000-0000-0000-0000-000000000001', '7c100000-0000-0000-0000-000000000001', r.id, 'TIU KATKOUT' FROM regions r WHERE r.name = 'Delta';
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, serial_number, pressure_min, pressure_max, pressure_unit)
SELECT v.id::uuid, r.id, '7c100000-0000-0000-0000-000000000001', '7c200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', v.sn, 18, 18, 'BAR'
  FROM (VALUES ('7c300000-0000-0000-0000-000000000001','TIU-OLD1'), ('7c300000-0000-0000-0000-000000000002','TIU-OLD2'),
               ('7c300000-0000-0000-0000-000000000003','TIU-OLD3'), ('7c300000-0000-0000-0000-000000000004','TIU-OLD4')) v(id,sn), regions r WHERE r.name = 'Delta';
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, warehouse_code, pressure_min, pressure_max, pressure_unit,
                                     last_calibration_date, last_calibration_precision, source_raw) VALUES
  ('7c400000-0000-0000-0000-000000000001','available_calibrated','TIU-NEW1','sbc 87',18,18,'BAR','2026-09-01','exact_date','{}'),
  ('7c400000-0000-0000-0000-000000000002','available_new','TIU-NEW2','sbn 5',18,18,'BAR',NULL,'unknown','{}'),
  ('7c400000-0000-0000-0000-000000000003','available_calibrated','TIU-NEW3','sbc 3',18,18,'BAR','2026-09-01','exact_date','{}'),
  ('7c400000-0000-0000-0000-000000000004','available_calibrated','TIU-NEW4','sbc 4',18,18,'BAR','2026-09-01','exact_date','{}');

CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid);
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON ids, r TO authenticated;
CREATE TEMP VIEW live_at_unit AS
  SELECT serial_number FROM installed_relief_valves WHERE unit_id = '7c200000-0000-0000-0000-000000000001' AND archived_at IS NULL;

-- The owner's sequence: NEW1 replaces OLD1.
INSERT INTO ids VALUES ('i1', pg_temp.issue('7c400000-0000-0000-0000-000000000001', '7c300000-0000-0000-0000-000000000001'));
INSERT INTO ids SELECT 'l1', id FROM srv_field_log WHERE issue_id = (SELECT v FROM ids WHERE k = 'i1');
SELECT pg_temp.ck('IU-1 after the issue: NEW1 installed, OLD1 in the SRV Log at the station, the Issue movement awaits OLD1',
  (SELECT array_agg(serial_number ORDER BY serial_number) FROM live_at_unit WHERE serial_number IN ('TIU-OLD1','TIU-NEW1')) = ARRAY['TIU-NEW1']
  AND (SELECT status FROM v_srv_field_log WHERE id = (SELECT v FROM ids WHERE k = 'l1')) = 'at_station'
  AND (SELECT status FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'i1')) = 'awaiting_replaced');

INSERT INTO r VALUES ('restore', pg_temp.try_as('iu_admin', format('SELECT cng_srv_log_restore_to_station(%L)', (SELECT v FROM ids WHERE k = 'l1'))));
SELECT pg_temp.ck('IU-2 "Back to its station" on an issue''s entry is refused (it would leave NEW1 installed too) and changes nothing',
  (SELECT v FROM r WHERE k = 'restore') = 'PT409'
  AND (SELECT count(*) FROM live_at_unit WHERE serial_number IN ('TIU-OLD1','TIU-NEW1')) = 1);

INSERT INTO r VALUES ('noaction', pg_temp.try_as('iu_admin', format('SELECT cng_srv_issue_undo(%L, NULL)', (SELECT v FROM ids WHERE k = 'i1'))));
INSERT INTO r VALUES ('viewer', pg_temp.try_as('iu_viewer', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'i1'), 'to_stock')));
SELECT pg_temp.ck('IU-3 undo needs a choice for the issued valve, and only an admin may undo',
  (SELECT v FROM r WHERE k = 'noaction') = '22023' AND (SELECT v FROM r WHERE k = 'viewer') = '42501'
  AND (SELECT cancelled_at IS NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'i1')));

INSERT INTO r VALUES ('undo1', pg_temp.try_as('iu_admin', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'i1'), 'to_stock')));
SELECT pg_temp.ck('IU-4 undo "back to stock": OLD1 alone in its position; NEW1 back in stock as calibrated, same record and code',
  (SELECT v FROM r WHERE k = 'undo1') = 'OK'
  AND (SELECT array_agg(serial_number) FROM live_at_unit WHERE serial_number IN ('TIU-OLD1','TIU-NEW1')) = ARRAY['TIU-OLD1']
  AND (SELECT availability_status = 'available_calibrated' AND target_station_id IS NULL AND warehouse_code = 'sbc 87'
         FROM warehouse_relief_valves WHERE id = '7c400000-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM v_srv_warehouse_stock WHERE id = '7c400000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('IU-5 the issue is cancelled (kept, not deleted), leaves the Issue movement, and OLD1 leaves the SRV Log',
  (SELECT cancel_action = 'to_stock' AND cancelled_by = '7c000000-0000-0000-0000-00000000000a' FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'i1'))
  AND NOT EXISTS (SELECT 1 FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'i1'))
  AND NOT EXISTS (SELECT 1 FROM v_srv_field_log WHERE id = (SELECT v FROM ids WHERE k = 'l1'))
  AND EXISTS (SELECT 1 FROM audit_logs WHERE entity_id = (SELECT v FROM ids WHERE k = 'i1') AND actor_label = 'srv_issue_undo'));
INSERT INTO r VALUES ('undo1b', pg_temp.try_as('iu_admin', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'i1'), 'to_stock')));
SELECT pg_temp.ck('IU-6 an issue cannot be undone twice', (SELECT v FROM r WHERE k = 'undo1b') = 'PT409');

-- NEW2 replaces OLD2, then undone as "still at the station".
INSERT INTO ids VALUES ('i2', pg_temp.issue('7c400000-0000-0000-0000-000000000002', '7c300000-0000-0000-0000-000000000002'));
INSERT INTO r VALUES ('undo2', pg_temp.try_as('iu_admin', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'i2'), 'await_return')));
INSERT INTO ids SELECT 'l2', id FROM srv_field_log WHERE issue_id = (SELECT v FROM ids WHERE k = 'i2') AND reason = 'issue_undone';
SELECT pg_temp.ck('IU-7 undo "awaiting return": OLD2 alone in its position; NEW2 in the SRV Log at the station, from its own stock record',
  (SELECT v FROM r WHERE k = 'undo2') = 'OK'
  AND (SELECT array_agg(serial_number) FROM live_at_unit WHERE serial_number IN ('TIU-OLD2','TIU-NEW2')) = ARRAY['TIU-OLD2']
  AND (SELECT status = 'at_station' AND issue_cancelled AND serial_number = 'TIU-NEW2' AND warehouse_valve_id = '7c400000-0000-0000-0000-000000000002'
         FROM v_srv_field_log WHERE id = (SELECT v FROM ids WHERE k = 'l2')));
INSERT INTO r VALUES ('recv2', pg_temp.try_as('iu_admin', format('SELECT cng_srv_log_receive(ARRAY[%L]::uuid[])', (SELECT v FROM ids WHERE k = 'l2'))));
SELECT pg_temp.ck('IU-8 when it arrives it is received like any valve: the same stock record, under calibration, no second record',
  (SELECT v FROM r WHERE k = 'recv2') = 'OK'
  AND (SELECT availability_status = 'available_in_store_uc' FROM warehouse_relief_valves WHERE id = '7c400000-0000-0000-0000-000000000002')
  AND (SELECT count(*) = 1 FROM warehouse_relief_valves WHERE serial_number = 'TIU-NEW2'));

-- NEW3 replaces OLD3, OLD3 is received back at the warehouse, then an undo is attempted.
INSERT INTO ids VALUES ('i3', pg_temp.issue('7c400000-0000-0000-0000-000000000003', '7c300000-0000-0000-0000-000000000003'));
INSERT INTO r VALUES ('recv3', pg_temp.try_as('iu_admin', format('SELECT cng_srv_log_receive(ARRAY[%L]::uuid[])',
  (SELECT id FROM srv_field_log WHERE issue_id = (SELECT v FROM ids WHERE k = 'i3')))));
SELECT pg_temp.ck('IU-9 once the replaced valve is back, the Issue movement says so',
  (SELECT status FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'i3')) = 'replaced_returned');
INSERT INTO r VALUES ('undo3', pg_temp.try_as('iu_admin', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'i3'), 'to_stock')));
SELECT pg_temp.ck('IU-10 undo is refused when the replaced valve is already back in the warehouse (one serial, one place)',
  (SELECT v FROM r WHERE k = 'undo3') = 'PT409'
  AND (SELECT cancelled_at IS NULL FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'i3')));

-- The production shape: NEW4 replaced OLD4, then the old "Back to its station" reinstated OLD4 and archived the entry.
INSERT INTO ids VALUES ('i4', pg_temp.issue('7c400000-0000-0000-0000-000000000004', '7c300000-0000-0000-0000-000000000004'));
UPDATE installed_relief_valves SET archived_at = NULL, archived_by = NULL WHERE id = '7c300000-0000-0000-0000-000000000004';
UPDATE srv_field_log SET archived_at = now(), archived_by = '7c000000-0000-0000-0000-00000000000a' WHERE issue_id = (SELECT v FROM ids WHERE k = 'i4');
SELECT pg_temp.ck('IU-11 the production shape is visible: two valves in one position, the Issue movement flags the removed entry',
  (SELECT count(*) FROM live_at_unit WHERE serial_number IN ('TIU-OLD4','TIU-NEW4')) = 2
  AND (SELECT status FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'i4')) = 'replaced_entry_removed');
INSERT INTO r VALUES ('undo4', pg_temp.try_as('iu_admin', format('SELECT cng_srv_issue_undo(%L, %L)', (SELECT v FROM ids WHERE k = 'i4'), 'to_stock')));
SELECT pg_temp.ck('IU-12 undoing that issue repairs it: OLD4 alone in its position, NEW4 back in stock',
  (SELECT v FROM r WHERE k = 'undo4') = 'OK'
  AND (SELECT array_agg(serial_number) FROM live_at_unit WHERE serial_number IN ('TIU-OLD4','TIU-NEW4')) = ARRAY['TIU-OLD4']
  AND EXISTS (SELECT 1 FROM v_srv_warehouse_stock WHERE id = '7c400000-0000-0000-0000-000000000004'));

-- Six months: a finished issue is hidden, one still awaiting its replaced valve is not.
UPDATE srv_issues SET issued_at = now() - interval '7 months' WHERE id = (SELECT v FROM ids WHERE k = 'i3');
SELECT pg_temp.ck('IU-13 a finished issue older than six months is hidden from the Issue movement, never deleted',
  NOT EXISTS (SELECT 1 FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'i3'))
  AND EXISTS (SELECT 1 FROM srv_issues WHERE id = (SELECT v FROM ids WHERE k = 'i3')));
UPDATE srv_field_log SET returned_at = NULL, returned_by = NULL, returned_warehouse_valve_id = NULL
 WHERE issue_id = (SELECT v FROM ids WHERE k = 'i3');
SELECT pg_temp.ck('IU-14 an old issue still waiting for its replaced valve stays visible',
  EXISTS (SELECT 1 FROM v_srv_issue_log WHERE id = (SELECT v FROM ids WHERE k = 'i3') AND status = 'awaiting_replaced'));

UPDATE srv_issues SET is_emergency = true WHERE id IN ((SELECT v FROM ids WHERE k = 'i1'), (SELECT v FROM ids WHERE k = 'i3'));
SELECT pg_temp.ck('IU-15 a cancelled issue leaves SRV Emergency; a live one stays',
  NOT EXISTS (SELECT 1 FROM v_srv_emergency WHERE id = (SELECT v FROM ids WHERE k = 'i1'))
  AND EXISTS (SELECT 1 FROM v_srv_emergency WHERE id = (SELECT v FROM ids WHERE k = 'i3')));

SELECT pg_temp.ck('IU-16 security: undo is SECURITY DEFINER with a pinned search_path, authenticated only; the views run as the caller',
  (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc WHERE proname = 'cng_srv_issue_undo')
  AND has_function_privilege('authenticated', 'cng_srv_issue_undo(uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_srv_issue_undo(uuid, text, text)', 'EXECUTE')
  AND (SELECT bool_and(reloptions::text LIKE '%security_invoker=true%') FROM pg_class
        WHERE relname IN ('v_srv_issue_log', 'v_srv_field_log', 'v_srv_emergency'))
  AND NOT has_table_privilege('anon', 'v_srv_issue_log', 'SELECT'));

ROLLBACK;
