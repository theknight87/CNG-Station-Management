-- equipment_issue_transfer.sql — regression suite for 20261010090000_equipment_issue_transfer.sql (owner request
-- 2026-10-10): an issued hose / gas detector that was not fitted goes straight on to another Station.
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
  ('8e000000-0000-0000-0000-00000000000a','eqt_admin','admin',true,'TESTDATA EQT Admin'),
  ('8e000000-0000-0000-0000-00000000000b','eqt_viewer','viewer',true,'TESTDATA EQT Viewer');
INSERT INTO stations (id, region_id, station_name) SELECT v.id::uuid, r.id, v.n FROM regions r,
  (VALUES ('8e100000-0000-0000-0000-000000000001','TEQT AAA'), ('8e100000-0000-0000-0000-000000000002','TEQT BBB')) v(id, n) WHERE r.name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '8e200000-0000-0000-0000-000000000002', '8e100000-0000-0000-0000-000000000002', id, 'TEQT BBB 1'
  FROM regions WHERE name = 'East';
-- A: an old hose and an old detector; B: an old hose on Unit 1.
INSERT INTO hoses (id, region_id, station_id, unit_id, mapping_status, serial_number, serial_status) SELECT v.id::uuid, r.id, v.s::uuid, v.u::uuid, v.m::asset_mapping_status, v.sn, 'assigned'
  FROM regions r, (VALUES ('8e300000-0000-0000-0000-000000000001','8e100000-0000-0000-0000-000000000001',NULL,'needs_unit_mapping','TEQT-H-A-OLD'),
                          ('8e300000-0000-0000-0000-000000000002','8e100000-0000-0000-0000-000000000002','8e200000-0000-0000-0000-000000000002','resolved','TEQT-H-B-OLD'),
                          ('8e300000-0000-0000-0000-000000000004','8e100000-0000-0000-0000-000000000001',NULL,'needs_unit_mapping','TEQT-H-A-OLD2'))
                   v(id, s, u, m, sn) WHERE r.name = 'East';
INSERT INTO gas_detectors (id, region_id, station_id, mapping_status, serial_number, serial_status, manufacturer, model)
SELECT '8e300000-0000-0000-0000-000000000003', id, '8e100000-0000-0000-0000-000000000001', 'needs_unit_mapping', 'TEQT-G-A-OLD', 'assigned', 'Honeywell', 'XNX'
  FROM regions WHERE name = 'East';
SELECT pg_temp.act('s1', 'eqt_admin', $q$SELECT cng_equipment_stock_add('hose','available_calibrated',ARRAY['TEQT-H-NEW','TEQT-H-NEW2'],NULL,NULL,NULL,'hose',
      350,'BAR',NULL,NULL,'2026-09-01'::date,'2027-09-01'::date,NULL,NULL)$q$);
SELECT pg_temp.act('s2', 'eqt_admin', $q$SELECT cng_equipment_stock_add('gas_detector','available_new',ARRAY['TEQT-G-NEW'],NULL,'Honeywell','XNX',NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)$q$);
CREATE FUNCTION pg_temp.stock(p text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM equipment_stock WHERE serial_number = p $$;
CREATE FUNCTION pg_temp.live_issue(p text) RETURNS uuid LANGUAGE sql AS $$
  SELECT e.id FROM equipment_issues e JOIN equipment_stock w ON w.id = e.stock_id WHERE w.serial_number = p AND e.cancelled_at IS NULL $$;
CREATE TEMP VIEW live AS
  SELECT serial_number, station_id, unit_id FROM hoses WHERE serial_number LIKE 'TEQT-%' AND archived_at IS NULL
  UNION ALL SELECT serial_number, station_id, unit_id FROM gas_detectors WHERE serial_number LIKE 'TEQT-%' AND archived_at IS NULL;

-- NEW hose issued to A in place of A-OLD; then moved to B (Unit 1) in place of B-OLD.
SELECT pg_temp.act('i1', 'eqt_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8e100000-0000-0000-0000-000000000001', NULL, '8e300000-0000-0000-0000-000000000001')$q$,
  pg_temp.stock('TEQT-H-NEW'), (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEQT-H-NEW')));
CREATE TEMP TABLE ids AS SELECT pg_temp.live_issue('TEQT-H-NEW') AS ia;

SELECT pg_temp.act('viewer', 'eqt_viewer', format($q$SELECT cng_equipment_issue_transfer(%L, '8e100000-0000-0000-0000-000000000002')$q$, (SELECT ia FROM ids)));
SELECT pg_temp.act('same', 'eqt_admin', format($q$SELECT cng_equipment_issue_transfer(%L, '8e100000-0000-0000-0000-000000000001')$q$, (SELECT ia FROM ids)));
SELECT pg_temp.act('wrongp', 'eqt_admin', format($q$SELECT cng_equipment_issue_transfer(%L, '8e100000-0000-0000-0000-000000000002', NULL, '8e300000-0000-0000-0000-000000000004')$q$, (SELECT ia FROM ids)));
SELECT pg_temp.ck('EQT-1 only an admin may move; not to the same place; the replaced item must be at the new Station; nothing changed',
  pg_temp.res('viewer') = '42501' AND pg_temp.res('same') = '22023' AND pg_temp.res('wrongp') = 'PT409'
  AND (SELECT cancelled_at IS NULL FROM equipment_issues WHERE id = (SELECT ia FROM ids))
  AND EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-H-NEW' AND station_id = '8e100000-0000-0000-0000-000000000001'));

SELECT pg_temp.act('move', 'eqt_admin', format($q$SELECT cng_equipment_issue_transfer(%L, '8e100000-0000-0000-0000-000000000002', NULL, '8e300000-0000-0000-0000-000000000002')$q$, (SELECT ia FROM ids)));
SELECT pg_temp.ck('EQT-2 at A the old hose is back in its position; at B the NEW hose replaced B-OLD and takes its Unit',
  pg_temp.res('move') = 'OK'
  AND EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-H-A-OLD' AND station_id = '8e100000-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-H-NEW' AND station_id = '8e100000-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-H-NEW' AND station_id = '8e100000-0000-0000-0000-000000000002'
                AND unit_id = '8e200000-0000-0000-0000-000000000002')
  AND NOT EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-H-B-OLD'));
SELECT pg_temp.ck('EQT-3 the issue at A is cancelled as transferred (kept); the new issue names it; A-OLD left the Log, B-OLD is in it',
  (SELECT cancel_action = 'transferred' FROM equipment_issues WHERE id = (SELECT ia FROM ids))
  AND (SELECT transferred_from_issue_id = (SELECT ia FROM ids) AND replaced_hose_id = '8e300000-0000-0000-0000-000000000002'
         FROM equipment_issues WHERE id = pg_temp.live_issue('TEQT-H-NEW'))
  AND NOT EXISTS (SELECT 1 FROM v_equipment_field_log WHERE installed_hose_id = '8e300000-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM v_equipment_field_log WHERE installed_hose_id = '8e300000-0000-0000-0000-000000000002' AND status = 'at_station'));
SELECT pg_temp.ck('EQT-4 the store record follows it to B, still at the station; one store record; history and audit record the move',
  (SELECT availability_status = 'sent_to_station_received' AND target_station_id = '8e100000-0000-0000-0000-000000000002'
     FROM equipment_stock WHERE serial_number = 'TEQT-H-NEW')
  AND (SELECT count(*) = 1 FROM equipment_stock WHERE serial_number = 'TEQT-H-NEW')
  AND EXISTS (SELECT 1 FROM equipment_history WHERE stock_id = pg_temp.stock('TEQT-H-NEW') AND event = 'transferred')
  AND EXISTS (SELECT 1 FROM audit_logs WHERE entity_id = pg_temp.live_issue('TEQT-H-NEW') AND actor_label = 'equipment_issue_transfer'
                AND actor_id = '8e000000-0000-0000-0000-00000000000a'));
SELECT pg_temp.ck('EQT-5 the Issued movement shows B only',
  NOT EXISTS (SELECT 1 FROM v_equipment_issue_log WHERE id = (SELECT ia FROM ids))
  AND (SELECT station_name = 'TEQT BBB' FROM v_equipment_issue_log WHERE id = pg_temp.live_issue('TEQT-H-NEW')));

SELECT pg_temp.act('twice', 'eqt_admin', format($q$SELECT cng_equipment_issue_transfer(%L, '8e100000-0000-0000-0000-000000000002')$q$, (SELECT ia FROM ids)));
SELECT pg_temp.act('undo', 'eqt_admin', format($q$SELECT cng_equipment_issue_undo(%L, 'await_return')$q$, pg_temp.live_issue('TEQT-H-NEW')));
SELECT pg_temp.ck('EQT-6 the old issue cannot be moved again; the move can be undone like any issue (B-OLD back, NEW awaiting return from B)',
  pg_temp.res('twice') = 'PT409' AND pg_temp.res('undo') = 'OK'
  AND EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-H-B-OLD')
  AND EXISTS (SELECT 1 FROM v_equipment_field_log l JOIN hoses h ON h.id = l.installed_hose_id
               WHERE h.serial_number = 'TEQT-H-NEW' AND l.reason = 'issue_undone' AND l.station_id = '8e100000-0000-0000-0000-000000000002'));

-- A detector, no replacement at A, moved to B with no Unit: the Unit stays unknown.
SELECT pg_temp.act('i2', 'eqt_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8e100000-0000-0000-0000-000000000001')$q$,
  pg_temp.stock('TEQT-G-NEW'), (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEQT-G-NEW')));
SELECT pg_temp.act('move2', 'eqt_admin', format($q$SELECT cng_equipment_issue_transfer(%L, '8e100000-0000-0000-0000-000000000002')$q$, pg_temp.live_issue('TEQT-G-NEW')));
SELECT pg_temp.ck('EQT-7 a detector moves too; with no Unit chosen and nothing replaced, its Unit stays unknown (never inferred)',
  pg_temp.res('move2') = 'OK'
  AND (SELECT unit_id IS NULL AND station_id = '8e100000-0000-0000-0000-000000000002' FROM gas_detectors
        WHERE serial_number = 'TEQT-G-NEW' AND archived_at IS NULL)
  AND (SELECT mapping_status = 'needs_unit_mapping' FROM gas_detectors WHERE serial_number = 'TEQT-G-NEW' AND archived_at IS NULL)
  AND EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-G-A-OLD'));

-- NEW2 issued to A in place of A-OLD2; A-OLD2 is received back; the move is refused.
SELECT pg_temp.act('i3', 'eqt_admin', format($q$SELECT cng_equipment_issue(%L, %L, '8e100000-0000-0000-0000-000000000001', NULL, '8e300000-0000-0000-0000-000000000004')$q$,
  pg_temp.stock('TEQT-H-NEW2'), (SELECT updated_at FROM equipment_stock WHERE serial_number = 'TEQT-H-NEW2')));
SELECT pg_temp.act('recv', 'eqt_admin', format($q$SELECT cng_equipment_log_receive(ARRAY[%L]::uuid[])$q$,
  (SELECT id FROM equipment_field_log WHERE installed_hose_id = '8e300000-0000-0000-0000-000000000004' AND archived_at IS NULL)));
SELECT pg_temp.act('back', 'eqt_admin', format($q$SELECT cng_equipment_issue_transfer(%L, '8e100000-0000-0000-0000-000000000002')$q$, pg_temp.live_issue('TEQT-H-NEW2')));
SELECT pg_temp.ck('EQT-8 refused when the replaced item is already back in the warehouse; nothing changed',
  pg_temp.res('recv') = 'OK' AND pg_temp.res('back') = 'PT409'
  AND pg_temp.live_issue('TEQT-H-NEW2') IS NOT NULL
  AND EXISTS (SELECT 1 FROM live WHERE serial_number = 'TEQT-H-NEW2' AND station_id = '8e100000-0000-0000-0000-000000000001'));

SELECT pg_temp.ck('EQT-9 security: SECURITY DEFINER, pinned search_path, authenticated only',
  (SELECT prosecdef AND proconfig::text LIKE '%search_path%' FROM pg_proc WHERE proname = 'cng_equipment_issue_transfer')
  AND has_function_privilege('authenticated', 'cng_equipment_issue_transfer(uuid, uuid, uuid, uuid, boolean, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_equipment_issue_transfer(uuid, uuid, uuid, uuid, boolean, text)', 'EXECUTE'));

ROLLBACK;
