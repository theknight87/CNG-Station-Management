-- srv_admin_manage.sql — regression suite for 20260928110000_srv_admin_manage.sql
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

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('7f000000-0000-0000-0000-00000000000a','sm_admin','admin',true,'TESTDATA SM Admin'),
  ('7f000000-0000-0000-0000-00000000000c','sm_eng','engineer',true,'TESTDATA SM Engineer');
INSERT INTO stations (id, region_id, station_name)
SELECT v.id::uuid, r.id, v.nm FROM (VALUES ('7f100000-0000-0000-0000-000000000001','TSM ALPHA'),('7f100000-0000-0000-0000-000000000002','TSM BETA')) v(id,nm), regions r WHERE r.name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, v.st::uuid, r.id, v.nm FROM (VALUES ('7f200000-0000-0000-0000-000000000001','7f100000-0000-0000-0000-000000000001','TSM ALPHA'),
                                                   ('7f200000-0000-0000-0000-000000000002','7f100000-0000-0000-0000-000000000002','TSM BETA')) v(id,st,nm), regions r WHERE r.name = 'East';
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, serial_number, pressure_min, pressure_max, pressure_unit, archived_at)
SELECT v.id::uuid, r.id, '7f100000-0000-0000-0000-000000000001', '7f200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', v.sn, v.p, v.p, 'BAR', v.arch
  FROM (VALUES ('7f300000-0000-0000-0000-000000000001','TSM-OLD',275,now()), ('7f300000-0000-0000-0000-000000000002','TSM-A',275,NULL),
               ('7f300000-0000-0000-0000-000000000003','TSM-B',90,NULL)) v(id,sn,p,arch), regions r WHERE r.name = 'East';
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, pressure_min, pressure_max, pressure_unit, source_raw)
VALUES ('7f400000-0000-0000-0000-000000000001','available_in_store_uc','TSM-W1',90,90,'BAR','{}'),
       ('7f400000-0000-0000-0000-000000000002','available_new','TSM-W2',90,90,'BAR','{}');
INSERT INTO srv_issues (id, warehouse_valve_id, new_installed_valve_id, replaced_installed_valve_id, region_id, station_id, unit_id, is_emergency, issued_by)
SELECT '7f500000-0000-0000-0000-000000000001','7f400000-0000-0000-0000-000000000002','7f300000-0000-0000-0000-000000000002','7f300000-0000-0000-0000-000000000001',
       region_id, id, '7f200000-0000-0000-0000-000000000001', true, '7f000000-0000-0000-0000-00000000000a' FROM stations WHERE id = '7f100000-0000-0000-0000-000000000001';
INSERT INTO srv_field_log (id, reason, issue_id, installed_valve_id, region_id, station_id, unit_id, is_emergency)
SELECT '7f600000-0000-0000-0000-000000000001','replaced_on_issue','7f500000-0000-0000-0000-000000000001','7f300000-0000-0000-0000-000000000001',
       region_id, id, '7f200000-0000-0000-0000-000000000001', true FROM stations WHERE id = '7f100000-0000-0000-0000-000000000001';
INSERT INTO srv_calibration_jobs (id, warehouse_valve_id, sent_by) VALUES ('7f700000-0000-0000-0000-000000000001','7f400000-0000-0000-0000-000000000001','7f000000-0000-0000-0000-00000000000a');

SELECT pg_temp.ck('SM-1 filtered summary: 275 BAR at the test station counts only that valve',
  (SELECT total = 1 FROM cng_installed_srv_summary_filtered('{"pressure":"275","station":"TSM ALPHA"}'))
  AND (SELECT total = 2 FROM cng_installed_srv_summary_filtered('{"station":"TSM ALPHA"}')));
SELECT pg_temp.ck('SM-2 a non-admin is refused by every admin action',
  pg_temp.try_as('sm_eng', $q$SELECT cng_srv_log_archive('7f600000-0000-0000-0000-000000000001')$q$) = '42501'
  AND pg_temp.try_as('sm_eng', $q$SELECT cng_admin_archive_srv('installed_relief_valves','7f300000-0000-0000-0000-000000000003')$q$) = '42501');
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;
INSERT INTO r VALUES ('move_bad', pg_temp.try_as('sm_admin', $q$SELECT cng_srv_log_move('7f600000-0000-0000-0000-000000000001','7f100000-0000-0000-0000-000000000002','7f200000-0000-0000-0000-000000000001')$q$));
INSERT INTO r VALUES ('move_ok', pg_temp.try_as('sm_admin', $q$SELECT cng_srv_log_move('7f600000-0000-0000-0000-000000000001','7f100000-0000-0000-0000-000000000002','7f200000-0000-0000-0000-000000000002')$q$));
SELECT pg_temp.ck('SM-3 move a log entry to another station (unit must belong to it)',
  (SELECT v FROM r WHERE k='move_bad') = '22023' AND (SELECT v FROM r WHERE k='move_ok') = 'OK'
  AND (SELECT station_id = '7f100000-0000-0000-0000-000000000002' FROM srv_field_log WHERE id = '7f600000-0000-0000-0000-000000000001'));
INSERT INTO r VALUES ('restore', pg_temp.try_as('sm_admin', $q$SELECT cng_srv_log_restore_to_station('7f600000-0000-0000-0000-000000000001')$q$));
SELECT pg_temp.ck('SM-4 restore to station: the replaced valve is installed again and the log entry leaves the list',
  (SELECT v FROM r WHERE k='restore') = 'OK'
  AND (SELECT archived_at IS NULL FROM installed_relief_valves WHERE id = '7f300000-0000-0000-0000-000000000001')
  AND NOT EXISTS (SELECT 1 FROM v_srv_field_log WHERE id = '7f600000-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM srv_field_log WHERE id = '7f600000-0000-0000-0000-000000000001'));
INSERT INTO r VALUES ('stock_before', (SELECT count(*) FROM v_srv_warehouse_stock WHERE id = '7f400000-0000-0000-0000-000000000001')::text);
INSERT INTO r VALUES ('cal_edit', pg_temp.try_as('sm_admin', $q$SELECT cng_srv_calibration_edit('7f700000-0000-0000-0000-000000000001', NULL, 'C-1', NULL)$q$));
INSERT INTO r VALUES ('cal_arch', pg_temp.try_as('sm_admin', $q$SELECT cng_srv_calibration_archive('7f700000-0000-0000-0000-000000000001')$q$));
SELECT pg_temp.ck('SM-5 calibration: edit then remove; the valve is back in stock; the job row is kept',
  (SELECT v FROM r WHERE k='stock_before') = '0' AND (SELECT v FROM r WHERE k='cal_edit') = 'OK' AND (SELECT v FROM r WHERE k='cal_arch') = 'OK'
  AND (SELECT count(*) = 1 FROM v_srv_warehouse_stock WHERE id = '7f400000-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM srv_calibration_jobs WHERE id = '7f700000-0000-0000-0000-000000000001' AND certificate_number = 'C-1'));
INSERT INTO r VALUES ('em_edit', pg_temp.try_as('sm_admin', $q$SELECT cng_srv_emergency_edit('7f500000-0000-0000-0000-000000000001', 'n1')$q$));
INSERT INTO r VALUES ('em_rm', pg_temp.try_as('sm_admin', $q$SELECT cng_srv_emergency_remove('7f500000-0000-0000-0000-000000000001')$q$));
SELECT pg_temp.ck('SM-6 emergency: edit notes, then remove from the list; the issue itself is kept',
  (SELECT v FROM r WHERE k='em_edit') = 'OK' AND (SELECT v FROM r WHERE k='em_rm') = 'OK'
  AND NOT EXISTS (SELECT 1 FROM v_srv_emergency WHERE id = '7f500000-0000-0000-0000-000000000001')
  AND EXISTS (SELECT 1 FROM srv_issues WHERE id = '7f500000-0000-0000-0000-000000000001' AND notes = 'n1'));
INSERT INTO r VALUES ('rm_i', pg_temp.try_as('sm_admin', $q$SELECT cng_admin_archive_srv('installed_relief_valves','7f300000-0000-0000-0000-000000000003')$q$));
INSERT INTO r VALUES ('rm_w', pg_temp.try_as('sm_admin', $q$SELECT cng_admin_archive_srv('warehouse_relief_valves','7f400000-0000-0000-0000-000000000002')$q$));
SELECT pg_temp.ck('SM-7 remove an installed and a warehouse valve: archived with who, never deleted; audited',
  (SELECT v FROM r WHERE k='rm_i') = 'OK' AND (SELECT v FROM r WHERE k='rm_w') = 'OK'
  AND (SELECT archived_by = '7f000000-0000-0000-0000-00000000000a' FROM installed_relief_valves WHERE id = '7f300000-0000-0000-0000-000000000003')
  AND NOT EXISTS (SELECT 1 FROM v_installed_srv_management WHERE id = '7f300000-0000-0000-0000-000000000003')
  AND (SELECT count(*) = 8 FROM audit_logs WHERE actor_id = '7f000000-0000-0000-0000-00000000000a'));
INSERT INTO r VALUES ('rm_again', pg_temp.try_as('sm_admin', $q$SELECT cng_admin_archive_srv('installed_relief_valves','7f300000-0000-0000-0000-000000000003')$q$));
SELECT pg_temp.ck('SM-8 removing twice is refused as stale (PT409)', (SELECT v FROM r WHERE k='rm_again') = 'PT409');
ROLLBACK;
