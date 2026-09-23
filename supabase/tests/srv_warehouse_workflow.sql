-- srv_warehouse_workflow.sql — regression suite for 20260925090000_srv_warehouse_workflow.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.become(p_sub text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_sub IS NULL THEN '{"role":"authenticated"}'
          ELSE json_build_object('sub', p_sub, 'role', 'authenticated')::text END, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE FUNCTION pg_temp.try_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM pg_temp.become(p_sub);
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('5f000000-0000-0000-0000-00000000000a','sw_admin','admin',true,'TESTDATA SW Admin'),
  ('5f000000-0000-0000-0000-00000000000b','sw_manager','manager',true,'TESTDATA SW Manager'),
  ('5f000000-0000-0000-0000-00000000000c','sw_eng','engineer',true,'TESTDATA SW Engineer');
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT '5f000000-0000-0000-0000-00000000000c'::uuid, id, true FROM regions WHERE name = 'West';

INSERT INTO stations (id, region_id, station_name) SELECT '5f100000-0000-0000-0000-000000000001', id, 'TSW ALPHA' FROM regions WHERE name = 'East';
INSERT INTO stations (id, region_id, station_name) SELECT '5f100000-0000-0000-0000-000000000002', id, 'TSW BETA' FROM regions WHERE name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '5f200000-0000-0000-0000-000000000001', '5f100000-0000-0000-0000-000000000001', id, 'TSW ALPHA' FROM regions WHERE name = 'East';

-- Installed at ALPHA: two 90 BAR valves (one confirmed Station, one raw-name only) and a 250 BAR valve.
INSERT INTO installed_relief_valves (id, region_id, station_id, mapping_status, serial_number, pressure_min, pressure_max, pressure_unit,
                                     source_station_name_raw, location_raw)
SELECT v.id::uuid, r.id, v.st::uuid, v.ms::srv_mapping_status, v.sn, v.p, v.p, 'BAR', 'TSW ALPHA', 'Stage'
  FROM (VALUES ('5f300000-0000-0000-0000-000000000001','5f100000-0000-0000-0000-000000000001','needs_unit_mapping','TSW-56789',90),
               ('5f300000-0000-0000-0000-000000000002',NULL,'needs_station_mapping','TSW-RAW',90),
               ('5f300000-0000-0000-0000-000000000003','5f100000-0000-0000-0000-000000000001','needs_unit_mapping','TSW-250',250)) v(id,st,ms,sn,p)
  JOIN regions r ON r.name = 'East';

-- Warehouse: stock in each status, plus sent-to-station records for the reconciliation.
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, warehouse_code, pressure_min, pressure_max, pressure_unit,
                                     target_region_id, source_raw)
SELECT v.id::uuid, v.st::warehouse_availability, v.sn, v.code, 90, 90, 'BAR',
       CASE WHEN v.dest IS NOT NULL THEN r.id END,
       CASE WHEN v.dest IS NOT NULL THEN jsonb_build_object('assigned_station_raw', v.dest) ELSE '{}'::jsonb END
  FROM (VALUES
    ('5f400000-0000-0000-0000-000000000001','available_new','TSW-NEW','MB 9',NULL),
    ('5f400000-0000-0000-0000-000000000002','available_calibrated','TSW-CAL','glu 44',NULL),
    ('5f400000-0000-0000-0000-000000000003','available_in_store_uc','TSW-UC','mbc 9',NULL),
    ('5f400000-0000-0000-0000-000000000004','sent_to_station_received','TSW-56789','sbc 1','TSW ALPHA'),
    ('5f400000-0000-0000-0000-000000000005','sent_to_station_received','TSW-123456','sbc 2','TSW ALPHA'),
    ('5f400000-0000-0000-0000-000000000006','sent_to_station_not_received','TSW-777','sbc 3','TSW NOWHERE')) v(id,st,sn,code,dest)
  JOIN regions r ON r.name = 'East';

-- ------------------------------------------------------------------ code rule
SELECT pg_temp.ck('CODE-1 rule: new keeps the base, calibrated adds C, under calibration adds U (case kept)',
  cng_srv_code_for('MB 9','available_new') = 'MB 9' AND cng_srv_code_for('MB 9','available_calibrated') = 'MBC 9'
  AND cng_srv_code_for('mbc 9','available_in_store_uc') = 'mbu 9' AND cng_srv_code_for('kcu 17','available_new') = 'kc 17');
SELECT pg_temp.ck('CODE-2 sent-to-station codes and codes of an unknown shape are never changed',
  cng_srv_code_for('sb 43','sent_to_station_received') = 'sb 43' AND cng_srv_code_for('X-1','available_new') = 'X-1'
  AND cng_srv_code_for('abcd 1','available_new') = 'abcd 1' AND cng_srv_code_for(NULL,'available_new') IS NULL);
SELECT pg_temp.ck('CODE-3 the trigger links code to status on insert (glu 44 calibrated -> glc 44, mbc 9 UC -> mbu 9)',
  (SELECT string_agg(warehouse_code, ',' ORDER BY id) FROM warehouse_relief_valves WHERE id IN ('5f400000-0000-0000-0000-000000000001','5f400000-0000-0000-0000-000000000002','5f400000-0000-0000-0000-000000000003'))
  = 'MB 9,glc 44,mbu 9');

-- ------------------------------------------------------------------ stock view
SELECT pg_temp.ck('STOCK-1 the store view holds only the three available statuses',
  (SELECT count(*) FROM v_srv_warehouse_stock WHERE id::text LIKE '5f4%') = 3);

-- ------------------------------------------------------------------ 6F reconciliation
CREATE TEMP TABLE p6 AS SELECT * FROM cng_6f_warehouse_proposal() WHERE warehouse_valve_id::text LIKE '5f4%';
SELECT pg_temp.ck('RECON-1 same serial recorded at the Station it was sent to -> nothing logged',
  NOT EXISTS (SELECT 1 FROM p6 WHERE warehouse_valve_id = '5f400000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('RECON-2 Station records a different valve -> log_other_serial with the canonical Station',
  (SELECT (kind, station_id) = ('log_other_serial', '5f100000-0000-0000-0000-000000000001'::uuid) FROM p6
    WHERE warehouse_valve_id = '5f400000-0000-0000-0000-000000000005'));
SELECT pg_temp.ck('RECON-3 no valves recorded for that Station name -> log_station_not_found, raw name kept',
  (SELECT (kind, station_id IS NULL, station_name_raw) = ('log_station_not_found', true, 'TSW NOWHERE') FROM p6
    WHERE warehouse_valve_id = '5f400000-0000-0000-0000-000000000006'));
SELECT pg_temp.ck('RECON-4 codes already matching their status are not proposed', NOT EXISTS (SELECT 1 FROM p6 WHERE kind = 'code_fix'));
SELECT pg_temp.ck('RECON-5 6F is service_role only',
  pg_temp.try_as('sw_admin', $q$SELECT * FROM cng_6f_warehouse_preview()$q$) = '42501');
DO $$ BEGIN
  PERFORM cng_6f_warehouse_commit('not-the-fingerprint', 'test');
  RAISE NOTICE 'FAILED: RECON-7 a wrong fingerprint was accepted';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  RECON-7 a wrong fingerprint is refused (22023)';
END $$;
SELECT fp AS fp6 FROM (SELECT preview_fingerprint fp FROM cng_6f_warehouse_preview()) x \gset
SELECT codes_corrected, logged FROM cng_6f_warehouse_commit(:'fp6', 'test') \gset
SELECT pg_temp.ck('RECON-8 commit writes the log rows it previewed',
  (SELECT count(*) FROM srv_field_log WHERE warehouse_valve_id::text LIKE '5f4%') = 2 AND :logged >= 2);
SELECT pg_temp.ck('RECON-9 a second preview proposes no further log rows for the same valves',
  NOT EXISTS (SELECT 1 FROM cng_6f_warehouse_proposal() WHERE warehouse_valve_id::text LIKE '5f4%'));
SELECT pg_temp.ck('RECON-10 the Station''s own record is untouched',
  (SELECT archived_at IS NULL FROM installed_relief_valves WHERE id = '5f300000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('RECON-11 log status reads location_unconfirmed for reconciled rows',
  (SELECT bool_and(status = 'location_unconfirmed') FROM v_srv_field_log WHERE warehouse_valve_id::text LIKE '5f4%'));

-- ------------------------------------------------------------------ authorization
SELECT pg_temp.ck('AUTH-1 manager and engineer cannot issue, receive or send to calibration (42501)',
  (SELECT bool_and(pg_temp.try_as(s, q) = '42501') FROM unnest(ARRAY['sw_manager','sw_eng',NULL]) s,
     unnest(ARRAY[
       $q$SELECT cng_srv_issue('5f400000-0000-0000-0000-000000000001', NULL, '5f200000-0000-0000-0000-000000000001')$q$,
       $q$SELECT cng_srv_log_receive(ARRAY[gen_random_uuid()])$q$,
       $q$SELECT cng_srv_calibration_send(ARRAY['5f400000-0000-0000-0000-000000000003'::uuid])$q$]) q));
SELECT pg_temp.ck('AUTH-2 no browser write grant on any workflow table',
  NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE grantee IN ('authenticated','anon')
               AND table_name IN ('srv_issues','srv_field_log','srv_calibration_jobs','srv_history')
               AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')));
SELECT pg_temp.ck('AUTH-3 workflow views run with the caller''s rights',
  (SELECT bool_and(reloptions @> ARRAY['security_invoker=true']) FROM pg_class
    WHERE relname IN ('v_srv_warehouse_stock','v_srv_field_log','v_srv_emergency','v_srv_calibration')));
SELECT pg_temp.ck('AUTH-4 a West engineer cannot read East log rows',
  (SELECT pg_temp.try_as('sw_eng', $q$DO $d$ BEGIN IF (SELECT count(*) FROM srv_field_log WHERE warehouse_valve_id::text LIKE '5f4%') <> 0
     THEN RAISE EXCEPTION 'leak' USING ERRCODE = 'P0009'; END IF; END $d$$q$)) = 'OK');

-- ------------------------------------------------------------------ replacement candidates
SELECT pg_temp.ck('ISSUE-1 candidates: same pressure at the Unit''s Station, including a raw-name match; other pressure excluded',
  (SELECT array_agg(id ORDER BY id) FROM cng_srv_replacement_candidates('5f200000-0000-0000-0000-000000000001', '5f400000-0000-0000-0000-000000000001'))
  = ARRAY['5f300000-0000-0000-0000-000000000001'::uuid, '5f300000-0000-0000-0000-000000000002'::uuid]);

-- ------------------------------------------------------------------ issue
SELECT updated_at AS v_new FROM warehouse_relief_valves WHERE id = '5f400000-0000-0000-0000-000000000001' \gset
SELECT pg_temp.ck('ISSUE-2 a stale version is refused with PT409',
  pg_temp.try_as('sw_admin', $q$SELECT cng_srv_issue('5f400000-0000-0000-0000-000000000001', '2000-01-01', '5f200000-0000-0000-0000-000000000001')$q$) = 'PT409');
SELECT pg_temp.ck('ISSUE-3 an under-calibration valve cannot be issued (PT409)',
  pg_temp.try_as('sw_admin', $q$SELECT cng_srv_issue('5f400000-0000-0000-0000-000000000003', NULL, '5f200000-0000-0000-0000-000000000001')$q$) = 'PT409');
SELECT pg_temp.ck('ISSUE-4 a valve at another Station cannot be named as the one replaced (22023)',
  pg_temp.try_as('sw_admin', $q$SELECT cng_srv_issue('5f400000-0000-0000-0000-000000000001', NULL, '5f200000-0000-0000-0000-000000000001', '5f300000-0000-0000-0000-000000000003')$q$) = '22023');

SELECT pg_temp.become('sw_admin');
SELECT cng_srv_issue('5f400000-0000-0000-0000-000000000001', :'v_new', '5f200000-0000-0000-0000-000000000001',
                     '5f300000-0000-0000-0000-000000000001', true, 'replacement') AS issue_id \gset
RESET ROLE;
SELECT pg_temp.ck('ISSUE-5 the issued valve is installed at the chosen Station and Unit, needs equipment mapping',
  (SELECT (i.station_id, i.unit_id, i.mapping_status::text, i.serial_number, i.location_raw)
          = ('5f100000-0000-0000-0000-000000000001'::uuid, '5f200000-0000-0000-0000-000000000001'::uuid, 'needs_equipment_mapping', 'TSW-NEW', 'Stage')
     FROM srv_issues e JOIN installed_relief_valves i ON i.id = e.new_installed_valve_id WHERE e.id = :'issue_id'));
SELECT pg_temp.ck('ISSUE-6 the warehouse record becomes sent_to_station_received with the destination and today''s issue date',
  (SELECT (availability_status::text, target_station_id, warehouse_issue_date, warehouse_code)
          = ('sent_to_station_received', '5f100000-0000-0000-0000-000000000001'::uuid, cng_business_date(), 'MB 9')
     FROM warehouse_relief_valves WHERE id = '5f400000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('ISSUE-7 the replaced valve is archived (never deleted) and in the SRV Log as at_station, emergency',
  (SELECT i.archived_at IS NOT NULL FROM installed_relief_valves i WHERE i.id = '5f300000-0000-0000-0000-000000000001')
  AND (SELECT (status, is_emergency, serial_number) = ('at_station', true, 'TSW-56789') FROM v_srv_field_log WHERE issue_id = :'issue_id'));
SELECT pg_temp.ck('ISSUE-8 an emergency issue appears in the Emergency view with the replaced valve',
  (SELECT (replaced_serial, replaced_status) = ('TSW-56789', 'at_station') FROM v_srv_emergency WHERE id = :'issue_id'));
SELECT pg_temp.ck('ISSUE-9 issuing is audited with the server-derived actor',
  EXISTS (SELECT 1 FROM audit_logs WHERE entity_id = :'issue_id' AND actor_id = '5f000000-0000-0000-0000-00000000000a'));
SELECT pg_temp.ck('ISSUE-10 the same valve cannot be issued twice (PT409)',
  pg_temp.try_as('sw_admin', $q$SELECT cng_srv_issue('5f400000-0000-0000-0000-000000000001', NULL, '5f200000-0000-0000-0000-000000000001')$q$) = 'PT409');
SELECT pg_temp.try_as('sw_admin', $q$SELECT cng_srv_issue('5f400000-0000-0000-0000-000000000002', NULL, '5f200000-0000-0000-0000-000000000001')$q$) AS iss2 \gset
SELECT pg_temp.ck('ISSUE-11 issuing without a replacement logs nothing',
  :'iss2' = 'OK'
  AND (SELECT count(*) FROM srv_issues WHERE warehouse_valve_id = '5f400000-0000-0000-0000-000000000002') = 1
  AND (SELECT count(*) FROM srv_field_log l JOIN srv_issues e ON e.id = l.issue_id WHERE e.warehouse_valve_id = '5f400000-0000-0000-0000-000000000002') = 0);

-- ------------------------------------------------------------------ receive
SELECT id AS log_replaced FROM srv_field_log WHERE issue_id = :'issue_id' \gset
SELECT id AS log_recon FROM srv_field_log WHERE warehouse_valve_id = '5f400000-0000-0000-0000-000000000005' \gset
SELECT pg_temp.become('sw_admin');
SELECT cng_srv_log_receive(ARRAY[:'log_replaced'::uuid, :'log_recon'::uuid]) AS received \gset
RESET ROLE;
SELECT pg_temp.ck('RECV-1 both received', :received = 2);
SELECT pg_temp.ck('RECV-2 a reconciled warehouse record returns to stock under calibration, code gets U, destination cleared',
  (SELECT (availability_status::text, warehouse_code, target_region_id IS NULL) = ('available_in_store_uc', 'sbu 2', true)
     FROM warehouse_relief_valves WHERE id = '5f400000-0000-0000-0000-000000000005'));
SELECT pg_temp.ck('RECV-3 a replaced valve becomes a new warehouse record under calibration with its serial',
  (SELECT (w.availability_status::text, w.serial_number) = ('available_in_store_uc', 'TSW-56789')
     FROM srv_field_log l JOIN warehouse_relief_valves w ON w.id = l.returned_warehouse_valve_id WHERE l.id = :'log_replaced'));
SELECT pg_temp.ck('RECV-4 receiving twice is refused (PT409)',
  pg_temp.try_as('sw_admin', format('SELECT cng_srv_log_receive(ARRAY[%L::uuid])', :'log_recon')) = 'PT409');
SELECT pg_temp.ck('RECV-5 the emergency row now shows the replaced valve returned',
  (SELECT replaced_status FROM v_srv_emergency WHERE id = :'issue_id') = 'returned');

-- ------------------------------------------------------------------ calibration
SELECT pg_temp.become('sw_admin');
SELECT cng_srv_calibration_send(ARRAY['5f400000-0000-0000-0000-000000000003'::uuid, '5f400000-0000-0000-0000-000000000005'::uuid]) AS sent \gset
RESET ROLE;
SELECT pg_temp.ck('CAL-1 two sent; they leave the store view', :sent = 2
  AND NOT EXISTS (SELECT 1 FROM v_srv_warehouse_stock WHERE id IN ('5f400000-0000-0000-0000-000000000003','5f400000-0000-0000-0000-000000000005')));
SELECT pg_temp.ck('CAL-2 a calibrated valve cannot be sent to calibration (PT409)',
  pg_temp.try_as('sw_admin', $q$SELECT cng_srv_calibration_send(ARRAY['5f400000-0000-0000-0000-000000000004'::uuid])$q$) = 'PT409');
SELECT id AS job3 FROM srv_calibration_jobs WHERE warehouse_valve_id = '5f400000-0000-0000-0000-000000000003' \gset
SELECT id AS job5 FROM srv_calibration_jobs WHERE warehouse_valve_id = '5f400000-0000-0000-0000-000000000005' \gset
SELECT pg_temp.try_as('sw_admin', format('SELECT cng_srv_calibration_returned(ARRAY[%L::uuid])', :'job3')) AS ret3 \gset
SELECT pg_temp.ck('CAL-3 mark returned -> returned_awaiting_certificate',
  :'ret3' = 'OK' AND (SELECT status FROM srv_calibration_jobs WHERE id = :'job3') = 'returned_awaiting_certificate');
SELECT pg_temp.ck('CAL-4 a future certificate date is refused',
  pg_temp.try_as('sw_admin', format('SELECT cng_srv_calibration_certify(ARRAY[%L::uuid], cng_business_date() + 1)', :'job3')) = '22023');
SELECT pg_temp.try_as('sw_admin', format('SELECT cng_srv_calibration_certify(ARRAY[%L::uuid, %L::uuid], %L::date, %L)',
    :'job3', :'job5', '2026-09-01', 'CERT-1')) AS cert \gset
SELECT pg_temp.ck('CAL-5 certifying both (one still "sent") works in one step', :'cert' = 'OK');
SELECT pg_temp.ck('CAL-6 certified valves are back in stock as calibrated, dated by the certificate, codes get C, next due unknown',
  (SELECT string_agg(availability_status::text || '/' || last_calibration_date || '/' || warehouse_code || '/' || next_calibration_precision, ',' ORDER BY id)
     FROM warehouse_relief_valves WHERE id IN ('5f400000-0000-0000-0000-000000000003','5f400000-0000-0000-0000-000000000005'))
  = 'available_calibrated/2026-09-01/mbc 9/unknown,available_calibrated/2026-09-01/sbc 2/unknown'
  AND (SELECT count(*) FROM v_srv_warehouse_stock WHERE id IN ('5f400000-0000-0000-0000-000000000003','5f400000-0000-0000-0000-000000000005')) = 2);

-- ------------------------------------------------------------------ history
SELECT pg_temp.ck('HIST-1 a valve''s history follows it across warehouse and installed records',
  (SELECT array_agg(event ORDER BY occurred_at, event) FROM cng_srv_valve_history('5f300000-0000-0000-0000-000000000001'))
  @> ARRAY['replaced','received']);
SELECT pg_temp.ck('HIST-2 the issued valve''s history reaches the installed record too',
  (SELECT count(*) FROM cng_srv_valve_history((SELECT new_installed_valve_id FROM srv_issues WHERE id = :'issue_id')) WHERE event = 'issued') = 1);
SELECT pg_temp.ck('HIST-3 calibration steps are in the history',
  (SELECT array_agg(DISTINCT event ORDER BY event) FROM cng_srv_valve_history('5f400000-0000-0000-0000-000000000003'))
  = ARRAY['certified','returned_from_calibration','sent_to_calibration']);

ROLLBACK;
